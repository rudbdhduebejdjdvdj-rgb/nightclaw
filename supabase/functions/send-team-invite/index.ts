import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return new Response(JSON.stringify({error:"Method not allowed"}),{status:405,headers:corsHeaders});
 try{
  const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!serviceKey)throw new Error("La función necesita la configuración segura del proyecto.");
  const jwt=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!jwt)return new Response(JSON.stringify({error:"Authentication required"}),{status:401,headers:corsHeaders});
  const admin=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false}});
  const {data:userResult,error:userError}=await admin.auth.getUser(jwt),user=userResult?.user;
  if(userError||!user)return new Response(JSON.stringify({error:"Invalid session"}),{status:401,headers:corsHeaders});
  const body=await req.json(),inviteId=String(body?.inviteId||""),token=String(body?.token||"");
  if(!inviteId||!token)return new Response(JSON.stringify({error:"Missing invitation data"}),{status:400,headers:corsHeaders});
  const {data:invite,error:inviteError}=await admin.from("organization_invites").select("id,organization_id,email,role,token,expires_at,accepted_at").eq("id",inviteId).eq("token",token).maybeSingle();
  if(inviteError||!invite||invite.accepted_at||new Date(invite.expires_at).getTime()<=Date.now())return new Response(JSON.stringify({error:"La invitación no es válida o ha caducado."}),{status:400,headers:corsHeaders});
  const {data:membership}=await admin.from("organization_members").select("role").eq("organization_id",invite.organization_id).eq("user_id",user.id).maybeSingle();
  if(!membership||!["owner","admin"].includes(membership.role))return new Response(JSON.stringify({error:"No tienes permiso para enviar esta invitación."}),{status:403,headers:corsHeaders});
  const siteUrl=(Deno.env.get("REVORA_SITE_URL")||"https://nightclaw.es").replace(/\/+$/,"");
  const inviteUrl=siteUrl+"/?invite="+encodeURIComponent(invite.token);
  const {error:sendError}=await admin.auth.admin.inviteUserByEmail(invite.email,{redirectTo:inviteUrl,data:{organization_invite_token:invite.token,organization_id:invite.organization_id,revora_invited:true,revora_password_set:false}});
  if(sendError)return new Response(JSON.stringify({ok:true,email_sent:false,invite_url:inviteUrl,message:"La invitación se ha creado, pero Supabase no ha podido enviar el correo. Comparte este enlace con la persona invitada."}),{status:200,headers:corsHeaders});
  return new Response(JSON.stringify({ok:true,email_sent:true,invite_url:inviteUrl,message:"Invitación enviada por correo."}),{status:200,headers:corsHeaders});
 }catch(error){return new Response(JSON.stringify({error:error instanceof Error?error.message:"Unexpected error"}),{status:500,headers:corsHeaders})}
});