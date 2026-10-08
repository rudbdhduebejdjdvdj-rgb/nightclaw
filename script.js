document.querySelectorAll('a[href^="#"]').forEach(a=>a.addEventListener('click',e=>{
  const target=document.querySelector(a.getAttribute('href'));
  if(target){e.preventDefault();target.scrollIntoView({behavior:'smooth'});}
}));

function formatCard(input){
  input.value=input.value.replace(/\D/g,'').replace(/(.{4})/g,'$1 ').trim().slice(0,19);
}
function formatExpiry(input){
  let v=input.value.replace(/\D/g,'').slice(0,4);
  if(v.length>2)v=v.slice(0,2)+' / '+v.slice(2);
  input.value=v;
}

window.addEventListener('message',e=>{
  if(e.data?.type!=='nightclaw-preview')return;
  const f=document.querySelector('.hero h1');
  const p=document.querySelector('.hero-left>p');
  const c=document.querySelector('.hero-buttons .button-lime');
  if(f&&e.data.hero)f.innerHTML=e.data.hero.replace(/\\n/g,'<br>');
  if(p&&e.data.desc)p.textContent=e.data.desc;
  if(c&&e.data.cta)c.childNodes[0].textContent=e.data.cta+' ';
});

(async function(){
  const sb=window.ncSupabase;
  if(!sb)return;
  try{
    const {data}=await sb.from("site_settings").select("key,value");
    const settings=Object.fromEntries((data||[]).map(x=>[x.key,x.value]));
    const hero=document.querySelector('.hero h1');
    const desc=document.querySelector('.hero-left>p');
    const cta=document.querySelector('.hero-buttons .button-lime');
    if(hero&&settings.hero?.text)hero.innerHTML=settings.hero.text.replace(/\\n/g,'<br>');
    if(desc&&settings.description?.text)desc.textContent=settings.description.text;
    if(cta&&settings.cta?.text)cta.childNodes[0].textContent=settings.cta.text+' ';

    const {data:{session}}=await sb.auth.getSession();
    const loginLinks=document.querySelectorAll('a[href="login.html"]');
    if(session?.user){
      loginLinks.forEach(link=>{
        link.textContent='Mi cuenta';
        link.href='account.html';
      });

      const {data:profile}=await sb.from('profiles').select('role,full_name,avatar_url').eq('id',session.user.id).maybeSingle();
      if(profile?.role==='admin'){
        const navActions=document.querySelector('.nav-actions');
        if(navActions && !document.querySelector('.studio-nav-link')){
          const studio=document.createElement('a');
          studio.className='nav-link studio-nav-link';
          studio.href='studio.html';
          studio.textContent='Studio';
          navActions.insertBefore(studio, navActions.firstChild);
        }
      }
    }
  }catch(e){console.debug("NightClaw session:",e);}
})();

(function(){const btn=document.querySelector('.menu-btn'),nav=document.querySelector('.desktop-nav');if(!btn||!nav)return;btn.addEventListener('click',()=>{nav.classList.toggle('mobile-open');btn.setAttribute('aria-expanded',nav.classList.contains('mobile-open'));});nav.querySelectorAll('a').forEach(a=>a.addEventListener('click',()=>nav.classList.remove('mobile-open')));})();
