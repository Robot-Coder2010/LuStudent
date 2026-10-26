(() => {
  const C = window.LU_CONFIG;
  const sb = window.LUsb || (window.LUsb = supabase.createClient(C.url, C.key));
  const esc = s => String(s ?? "").replace(/\s*\u2014\s*/g, ", ").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const defaults = [
    {title:"Calendar",description:"Co-op events, activities, and important dates.",url:"https://calendar.google.com",cta:"Open Google Calendar",icon:"calendar",secondary_text:"Open Family Sync",secondary_url:"https://familysync.latterup.org/"},
    {title:"Google Drive",description:"Your files, docs, slides, and sheets.",url:"https://drive.google.com",cta:"Open Google Drive",icon:"drive"},
    {title:"Google Chat",description:"Message teachers, classmates, and friends.",url:"https://mail.google.com/chat",cta:"Open Chat",icon:"chat"},
    {title:"Email",description:"Check your email and message teachers and friends.",url:"https://mail.google.com",cta:"Open Email",icon:"email"},
    {title:"Google Classroom",description:"View assignments, materials, and due dates.",url:"https://classroom.google.com",cta:"Open Classroom",icon:"classroom"},
    {title:"Trackers",description:"Your Success Circle and Homeroom to-do and focus lists.",url:"https://pathwaysandpossibilities.netlify.app/tracker",cta:"Open Tracker",icon:"compass"},
    {title:"Feedback",description:"Give feedback on anything LU.",url:"https://docs.google.com/forms/d/e/1FAIpQLSfwVwucRiMsnTMPcP-LV25BrLkVb_dBFtxDyX0xMIMqguZisQ/viewform",cta:"Open Form",icon:"document"}
  ];
  const icons = {
    calendar:'<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
    drive:'<path d="M8.6 3h6.8l6.1 10.6-3.4 5.9H5.9L2.5 13.6z"/>',
    chat:'<path d="M4 4h16v12H7l-3 3V4z"/><circle cx="9" cy="10" r=".55" fill="currentColor"/><circle cx="12" cy="10" r=".55" fill="currentColor"/><circle cx="15" cy="10" r=".55" fill="currentColor"/>',
    email:'<rect x="3" y="5" width="18" height="14" rx="1.5"/><path d="m3.5 6 8.5 7 8.5-7"/>',
    classroom:'<path d="M3 19 12 4l9 15z"/><path d="M9 19v-5h6v5"/>',
    compass:'<circle cx="12" cy="12" r="10"/><path d="m16.2 7.8-2.1 6.3-6.3 2.1 2.1-6.3z"/>',
    document:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6M9 13h6M9 17h6"/>',
    link:'<path d="M10 13a5 5 0 0 0 7.1 0l3-3A5 5 0 0 0 13 2.9l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.1 0l-3 3A5 5 0 0 0 11 21.1l1.7-1.7"/>',
    photo:'<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/>',
    video:'<rect x="3" y="5" width="13" height="14" rx="2"/><path d="m16 10 5-3v10l-5-3z"/>'
  };
  function safeUrl(value) { const v=String(value||"").trim(); if(!v) return "#"; if(/^(https?:|mailto:|tel:)/i.test(v)) return v; if(v.startsWith("/") || /^[\w.-]+\.html(?:[?#].*)?$/i.test(v) || v.startsWith("#")) return v; return v; }
  function card(t) {
    const url=safeUrl(t.url), external=/^https?:/i.test(url), target=external?' target="_blank" rel="noopener"':'';
    const secondary=t.secondary_text&&t.secondary_url?`<a class="calendar-secondary" href="${esc(safeUrl(t.secondary_url))}" ${/^https?:/i.test(t.secondary_url)?'target="_blank" rel="noopener"':''}>${esc(t.secondary_text)} ↗</a>`:"";
    return `<div class="portal-card portal-card-dynamic" role="link" tabindex="0" aria-label="${esc(t.title)}, ${esc(t.cta||"Open")}" data-card-url="${esc(url)}" data-card-external="${external ? "true" : "false"}"><span class="corner-fold" aria-hidden="true"></span><span class="card-icon" aria-hidden="true"><svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${icons[t.icon]||icons.link}</svg></span><span class="card-title">${esc(t.title)}</span><span class="card-desc">${esc(t.description||"")}</span><span class="card-cta">${esc(t.cta||"Open")} ↗</span>${secondary}</div>`;
  }
  async function run() {
    const grid=document.getElementById("portal-card-grid"); if(!grid) return;
    let banner={enabled:false,text:"",link_text:"Learn more",link_url:""}, tiles=defaults, homeSections=null;
    try { const {data,error}=await sb.from("settings").select("portal_banner,portal_tiles,portal_home_sections").eq("id",1).single(); if(!error&&data){banner={...banner,...(data.portal_banner||{})}; if(Array.isArray(data.portal_tiles)&&data.portal_tiles.length) tiles=data.portal_tiles; if(Array.isArray(data.portal_home_sections)&&data.portal_home_sections.length) homeSections=data.portal_home_sections;} } catch(_) {}
    grid.innerHTML=tiles.map(card).join("");
    const main=document.querySelector("main#main");
    if(main){
      const photo=document.createElement("section"); photo.id="photo-challenge"; photo.className="home-photo-callout";
      photo.innerHTML='<div class="wrap home-photo-callout-inner"><div class="home-photo-mark" aria-hidden="true">' + LUIcon("camera", 36) + '</div><div><p class="eyebrow">Create / Share / Celebrate</p><h2 class="section-title">Join the Photo Challenge</h2><p class="section-sub">Share a favorite moment in this round and explore the community gallery.</p></div><a class="auth-btn" href="photos.html">Submit your photos <span aria-hidden="true">↗</span></a></div>';
      main.appendChild(photo);
      if(homeSections){
        const map={hero:document.getElementById("top"),links:document.getElementById("links"),announcements:document.getElementById("announcements"),videos:document.getElementById("videos"),faq:document.getElementById("faq"),"photo-challenge":photo};
        const ordered=[...homeSections].sort((a,b)=>0);
        ordered.forEach(item=>{const el=map[item.id];if(!el)return;el.hidden=item.enabled===false;main.appendChild(el);});
      }
    }
    grid.querySelectorAll(".portal-card-dynamic").forEach(el=>{
      const open=()=>{const u=el.dataset.cardUrl;if(!u||u==="#")return;if(el.dataset.cardExternal==="true")window.open(u,"_blank","noopener");else location.href=u;};
      el.addEventListener("click",e=>{if(!e.target.closest(".calendar-secondary"))open();});
      el.addEventListener("keydown",e=>{if((e.key==="Enter"||e.key===" ")&&!e.target.closest(".calendar-secondary")){e.preventDefault();open();}});
    });
    const host=document.getElementById("portal-announcement-banner");
    if(host&&banner.enabled&&banner.text){host.hidden=false;host.innerHTML=`<div class="wrap portal-announcement-inner"><span>${esc(banner.text)}</span>${banner.link_text&&banner.link_url?`<a href="${esc(safeUrl(banner.link_url))}" ${/^https?:/i.test(banner.link_url)?'target="_blank" rel="noopener"':''}>${esc(banner.link_text)} ↗</a>`:""}</div>`;}
  }
  if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",run); else run();
})();
