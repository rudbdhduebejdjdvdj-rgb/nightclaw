const sb = window.ncSupabase;
const buttons = document.querySelectorAll(".studio-nav button");
const tabs = document.querySelectorAll(".studio-tab");
const title = document.getElementById("studioTitle");

function fmt(n) { return Number(n || 0).toLocaleString("es-ES"); }
function money(cents) { return (Number(cents || 0) / 100).toLocaleString("es-ES",{style:"currency",currency:"EUR"}); }
function setRows(id, rows) {
  const el=document.getElementById(id);
  if (!el) return;
  el.innerHTML=rows.length ? rows.map(r=>`<div><span>${r[0]}</span><b>${r[1]}</b></div>`).join("") : "<div><span>Sin datos todavía</span><b>0</b></div>";
}

buttons.forEach(btn=>btn.addEventListener("click",()=>{
  buttons.forEach(b=>b.classList.remove("active"));
  tabs.forEach(t=>t.classList.remove("active"));
  btn.classList.add("active");
  document.getElementById("tab-"+btn.dataset.tab)?.classList.add("active");
  title.textContent=btn.textContent;
}));

async function requireAdmin() {
  if (!sb) throw new Error("Supabase no está disponible.");
  const {data:{session}}=await sb.auth.getSession();
  if (!session) { location.href="login.html"; return false; }
  const {data:profile,error}=await sb.from("profiles").select("role,full_name").eq("id",session.user.id).single();
  if (error || profile?.role !== "admin") {
    document.body.innerHTML='<main style="padding:4rem;font-family:system-ui"><h1>Acceso restringido</h1><p>Esta zona requiere una cuenta de administrador.</p><a href="index.html">Volver</a></main>';
    return false;
  }
  return true;
}

async function loadOverview() {
  const [{data:events},{data:profiles},{data:orders}] = await Promise.all([
    sb.from("analytics_events").select("event_name,page,created_at").order("created_at",{ascending:false}).limit(1000),
    sb.from("profiles").select("id"),
    sb.from("orders").select("amount_cents,status")
  ]);
  const ev=events||[], ps=profiles||[], os=orders||[];
  const views=ev.filter(e=>e.event_name==="page_view").length;
  const purchases=os.filter(o=>["paid","completed","succeeded"].includes(o.status));
  const revenue=purchases.reduce((sum,o)=>sum+Number(o.amount_cents||0),0);
  document.getElementById("statViews").textContent=fmt(views);
  document.getElementById("statUsers").textContent=fmt(ps.length);
  document.getElementById("statConversion").textContent=views?((purchases.length/views)*100).toFixed(1)+"%":"0%";
  document.getElementById("statRevenue").textContent=money(revenue);
  const byPage={}; ev.forEach(e=>{if(e.event_name==="page_view")byPage[e.page]=(byPage[e.page]||0)+1;});
  setRows("trafficRows",Object.entries(byPage).sort((a,b)=>b[1]-a[1]).slice(0,8).map(([p,n])=>[p,fmt(n)]));
  const byEvent={}; ev.forEach(e=>byEvent[e.event_name]=(byEvent[e.event_name]||0)+1);
  setRows("eventRows",Object.entries(byEvent).sort((a,b)=>b[1]-a[1]).slice(0,10).map(([p,n])=>[p,fmt(n)]));
  setRows("analyticsRows",Object.entries(byEvent).sort((a,b)=>b[1]-a[1]).map(([p,n])=>[p,fmt(n)]));
}

async function loadEditor() {
  const {data}=await sb.from("site_settings").select("key,value");
  const settings=Object.fromEntries((data||[]).map(x=>[x.key,x.value]));
  document.getElementById("editHero").value=settings.hero?.text || "BUILD AFTER DARK.";
  document.getElementById("editDesc").value=settings.description?.text || "Productos digitales, software y proyectos nacidos de una idea.";
  document.getElementById("editCta").value=settings.cta?.text || "Entrar en la tienda";
}

document.getElementById("savePreview")?.addEventListener("click",async()=>{
  const status=document.getElementById("editorStatus");
  const values={hero:{text:document.getElementById("editHero").value},description:{text:document.getElementById("editDesc").value},cta:{text:document.getElementById("editCta").value}};
  const {error}=await sb.from("site_settings").upsert(Object.entries(values).map(([key,value])=>({key,value,updated_at:new Date().toISOString()})));
  if(error){status.textContent=error.message;return;}
  status.textContent="Guardado correctamente.";
  document.getElementById("sitePreview").contentWindow.postMessage({type:"nightclaw-preview",hero:values.hero.text,desc:values.description.text,cta:values.cta.text},"*");
});

document.getElementById("prepareEmail")?.addEventListener("click",async()=>{
  const status=document.getElementById("emailStatus");
  const raw=document.getElementById("emailTo").value.trim();
  const subject=document.getElementById("emailSubject").value.trim();
  const body=document.getElementById("emailBody").value;
  const recipients=raw.split(",").map(x=>x.trim()).filter(Boolean);
  if(!recipients.length || !subject || !body){status.textContent="Completa destinatarios, asunto y mensaje.";return;}
  const {error}=await sb.from("email_campaigns").insert({subject,content:body,recipients,status:"draft"});
  status.textContent=error?error.message:"Campaña guardada como borrador.";
  if(!error) loadCampaigns();
});

async function loadCampaigns(){
  const {data}=await sb.from("email_campaigns").select("subject,status,created_at").order("created_at",{ascending:false}).limit(10);
  setRows("campaignRows",(data||[]).map(x=>[x.subject,x.status]));
}

async function loadContent(){
  const [{count:products},{count:posts},{count:requests},{data:orders}]=await Promise.all([
    sb.from("products").select("*",{count:"exact",head:true}),
    sb.from("blog_posts").select("*",{count:"exact",head:true}),
    sb.from("project_requests").select("*",{count:"exact",head:true}),
    sb.from("orders").select("id,status,amount_cents,created_at").order("created_at",{ascending:false}).limit(8)
  ]);
  setRows("contentRows",[["Productos",fmt(products)],["Artículos",fmt(posts)],["Solicitudes",fmt(requests)]]);
  setRows("orderRows",(orders||[]).map(o=>[o.status,money(o.amount_cents)]));
}

document.getElementById("logout")?.addEventListener("click",async()=>{await sb.auth.signOut();location.href="login.html";});

(async()=>{
  try {
    if(!await requireAdmin()) return;
    await Promise.all([loadOverview(),loadEditor(),loadCampaigns(),loadContent()]);
  } catch(e) {
    console.error(e);
    document.querySelector(".studio-main").insertAdjacentHTML("afterbegin",`<div class="panel" style="margin-bottom:1rem">Error: ${e.message}</div>`);
  }
})();