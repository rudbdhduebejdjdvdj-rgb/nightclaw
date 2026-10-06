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
