const C = LU_CONFIG, sb = supabase.createClient(C.url, C.key), app = document.getElementById("app");
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const T = {
  announcements: { label: "Announcements", order: "date", title: "title", f: [["title", "Title"], ["date", "Date", "date"], ["text", "Text", "textarea"], ["pdf_path", "Flyer (PDF or image)", "file", "application/pdf,image/png,image/jpeg,image/webp"], ["publish_at", "Publish at (leave blank to post right away)", "datetime_opt"]] },
  videos: { label: "Videos", order: "date", title: "title", f: [["title", "Title"], ["date", "Date", "date"], ["description", "Description", "textarea"], ["youtube_id", "YouTube link", "yt"], ["video_path", "…or upload a video file", "file", "video/mp4,video/webm"], ["publish_at", "Publish at (leave blank to post right away)", "datetime_opt"]] },
  faq: { label: "FAQ", order: "sort_order", asc: 1, title: "question", f: [["question", "Question"], ["answer", "Answer (links and line breaks OK)", "textarea"], ["sort_order", "Order (1 = first)", "number"]] },
  themes: { label: "Photo Challenge", order: "starts_at", title: "title", f: [["title", "Theme"], ["description", "Description", "textarea"], ["starts_at", "Starts", "datetime"], ["ends_at", "Ends (next theme starts then)", "datetime"], ["video_path", "Finished video (optional)", "file", "video/mp4,video/webm"]] },
};
let cur = "announcements", ROLE = "student";
const loc = v => { const d = new Date(v); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); };
const ytId = v => (v.match(/(?:v=|youtu\.be\/|shorts\/|embed\/)([\w-]{11})/) || [, v.trim()])[1];

async function boot() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return app.innerHTML = '<p>Please sign in with your admin account.</p><button class="auth-btn" id="g">Sign in</button>',
    document.getElementById("g").onclick = () => (location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() || "index.html"));
  let role = (await sb.rpc("my_role")).data;
  if (!role) role = (await sb.rpc("is_admin")).data ? "admin" : "student";
  ROLE = role;
  if (role !== "admin" && role !== "leader") return app.innerHTML = "<p>This account isn't an admin or on the leadership team. Ask an admin to add your email.</p>";
  show();
}
function tabs() {
  const keys = ROLE === "admin" ? Object.keys(T).filter(k => k !== "faq") : ["announcements", "videos", "themes"];
  const btn = (id, label) => `<button class="auth-btn alt ${cur === id ? "on" : ""}" data-t="${id}">${label}</button>`;
  return "<nav>" + keys.map(k => btn(k, T[k].label)).join("") +
    (ROLE === "admin" ? btn("home", "Home Page") + btn("_i", "Import students") + btn("_s", "Students") + btn("_a", "Admins") + btn("_l", "Leadership team") + btn("_n", "Email alerts") : "") + "</nav>" +
    (ROLE === "leader" ? '<p class="role-note"><small>Leadership access: you can add announcements, videos and photo themes, and approve or reject photos.</small></p>' : "");
}
function wire() { app.querySelectorAll("[data-t]").forEach(b => b.onclick = () => { cur = b.dataset.t; show(); }); }

async function show(editRow) {
  if (ROLE !== "admin" && !["announcements", "videos", "themes"].includes(cur)) cur = "announcements";
  if (cur === "home") return homeTabUI();
  if (cur === "_s") return studentsUI();
  if (cur === "_i") return importUI();
  if (cur === "_a") return peopleUI("admins", "Admins", "Admins can do everything on the site. The person needs a student account first (Import students).", "Give admin access to", "Make admin");
  if (cur === "_l") return peopleUI("leadership", "Leadership team", "Leadership can add announcements, videos and photo themes and approve or reject photos, but can't edit or delete anything, and can't change settings. They get the new-photo emails. They need a student account first (Import students).", "Add a leadership member", "Add to leadership team");
  if (cur === "_n") return alertsUI();
  return listUI(cur, app);
}

let LT = "announcements";
async function listUI(table, host) {
  LT = table; const t = T[table];
  const { data = [] } = await sb.from(table).select("*").order(t.order, { ascending: !!t.asc });
  let scheduleBlock = "";
  if (table === "themes" && ROLE === "admin") {
    const { data: st } = await sb.from("settings").select("*").eq("id", 1).single();
    if (st) scheduleBlock = `<form id="theme-schedule" class="admin-schedule"><h3>Photo Theme Schedule Settings</h3>
      <label>Days each theme runs <small>Used to suggest dates for new themes. You can still edit each theme's dates individually.</small><input name="theme_length_days" type="number" min="1" value="${st.theme_length_days}"></label>
      <label>Photos per student per theme<input name="max_photos_per_theme" type="number" min="1" value="${st.max_photos_per_theme}"></label>
      <label>Time zone <small>e.g. America/Denver, America/New_York</small><input name="timezone" value="${esc(st.timezone)}"></label>
      <label class="chk"><input type="checkbox" name="public_photo_page" ${st.public_photo_page ? "checked" : ""}> Turn on the public photo page (no sign-in)</label>
      <small>Share this link: <b id="pub-link"></b><br>Anyone with the link can submit photos (you approve each one first) and see approved photos from finished themes. That means photos of students can be seen by anyone who has the link, so only switch this on if families are comfortable with that. Switch it off any time.</small>
      <div><button class="auth-btn" type="submit">Save schedule settings</button></div><small id="schedule-msg"></small></form>`;
  }
  host.innerHTML = (host === app ? tabs() : "") + `<button class="auth-btn" id="new">+ Add new</button><div id="list">` +
    data.map(r => `<div class="row"><span>${esc(r[t.title])} <small>${esc(r.date || (r.starts_at ? new Date(r.starts_at).toLocaleString() : ""))}</small>${r.publish_at && new Date(r.publish_at) > new Date() ? ` <span class="sched-badge">Scheduled for ${esc(new Date(r.publish_at).toLocaleString())}</span>` : ""}</span><span>${table === "themes" ? `<button class="auth-btn alt" data-ph="${r.id}">Photos</button> ` : ""}<button class="auth-btn alt" data-e="${r.id}">Edit</button> <button class="auth-btn alt" data-d="${r.id}">Delete</button></span></div>`).join("") + "</div><div id=\"form\"></div>" + (table === "themes" ? '<div id="photos-section"></div>' : "") + scheduleBlock;
  if (host === app) wire();
  if (ROLE !== "admin") host.querySelectorAll("[data-e],[data-d]").forEach(b => b.remove());
  const scheduleForm = document.getElementById("theme-schedule");
  const pl = document.getElementById("pub-link"); if (pl) pl.textContent = new URL("share-photos.html", location.href).href;
  if (scheduleForm) scheduleForm.onsubmit = async e => {
    e.preventDefault(); const f = e.target.elements, msg = document.getElementById("schedule-msg"); msg.textContent = "Saving…";
    const { error } = await sb.from("settings").update({ theme_length_days: +f.theme_length_days.value, max_photos_per_theme: +f.max_photos_per_theme.value, timezone: f.timezone.value.trim(), public_photo_page: f.public_photo_page.checked }).eq("id", 1);
    msg.textContent = error ? "Error: " + error.message : "Saved";
  };
  if (table === "themes") photosSection();
  document.getElementById("new").onclick = () => form(null);
  host.querySelectorAll("[data-ph]").forEach(b => b.onclick = async () => { sel = b.dataset.ph; await photosSection(); document.getElementById("photos-section").scrollIntoView({ behavior: "smooth" }); });
  host.querySelectorAll("[data-e]").forEach(b => b.onclick = () => form(data.find(r => r.id === b.dataset.e)));
  host.querySelectorAll("[data-d]").forEach(b => b.onclick = async () => {
    if (!confirm("Delete this permanently?")) return;
    const { error } = await sb.from(table).delete().eq("id", b.dataset.d); error ? alert(error.message) : show();
  });
}

async function form(row) {
  const t = T[LT]; let d = row || {};
  if (!row && LT === "themes") { const { data } = await sb.rpc("next_theme_window"); if (data?.[0]) d = { starts_at: data[0].starts_at, ends_at: data[0].ends_at }; }
  const el = document.getElementById("form");
  el.innerHTML = `<form><h3>${row ? "Edit" : "New"} ${t.label}</h3>` + t.f.map(([k, lab, type, acc]) => {
    const v = d[k] ?? "";
    if (type === "textarea") return `<label>${lab}<textarea name="${k}" rows="4">${esc(v)}</textarea></label>`;
    if (type === "file") return `<label>${lab}${v ? ` <small>Current file kept unless you choose a new one</small>` : ""}<input type="file" name="${k}" accept="${acc}"></label>`;
    if (type === "datetime_opt") return `<label>${lab}<input type="datetime-local" name="${k}" value="${v ? loc(v) : ""}"><small>Students see it at this date and time. Blank = visible immediately.</small></label>`;
    if (type === "datetime") return `<label>${lab}<input type="datetime-local" name="${k}" value="${v ? loc(v) : ""}" required></label>`;
    return `<label>${lab}<input name="${k}" type="${type === "yt" ? "text" : type || "text"}" value="${esc(type === "date" && !v ? new Date().toISOString().slice(0, 10) : v)}" ${["title", "question", "answer"].includes(k) ? "required" : ""}></label>`;
  }).join("") + '<div><button class="auth-btn" type="submit">Save</button> <button class="auth-btn alt" type="button" id="x">Cancel</button></div><small id="msg"></small></form>';
  el.querySelector("#x").onclick = () => (el.innerHTML = "");
  el.querySelector("form").onsubmit = async e => {
    e.preventDefault(); const msg = el.querySelector("#msg"); msg.textContent = "Saving…";
    const out = {};
    for (const [k, , type] of t.f) {
      const inp = e.target.elements[k];
      if (type === "file") {
        const f = inp.files[0]; if (!f) continue;
        const path = crypto.randomUUID() + "." + (f.name.split(".").pop() || "bin").toLowerCase();
        const up = await sb.storage.from("media").upload(path, f);
        if (up.error) return (msg.textContent = "Upload failed: " + up.error.message);
        out[k] = path;
      } else if (type === "datetime_opt") out[k] = inp.value ? new Date(inp.value).toISOString() : new Date().toISOString();
      else if (type === "datetime") out[k] = new Date(inp.value).toISOString();
      else if (type === "yt") out[k] = inp.value.trim() ? ytId(inp.value) : null;
      else if (type === "number") out[k] = Number(inp.value) || 0;
      else out[k] = inp.value.trim() || null;
    }
    const q = row ? sb.from(LT).update(out).eq("id", row.id) : sb.from(LT).insert(out);
    const { error } = await q; error ? (msg.textContent = "Error: " + error.message) : show();
  };
}


const DEFAULT_PORTAL_TILES = [
  { title: "Calendar", description: "Co-op events, activities, and important dates.", url: "https://calendar.google.com", cta: "Open Google Calendar", icon: "calendar", secondary_text: "Open Family Sync", secondary_url: "https://familysync.latterup.org/" },
  { title: "Google Drive", description: "Your files, docs, slides, and sheets.", url: "https://drive.google.com", cta: "Open Google Drive", icon: "drive" },
  { title: "Google Chat", description: "Message teachers, classmates, and friends.", url: "https://mail.google.com/chat", cta: "Open Chat", icon: "chat" },
  { title: "Email", description: "Check your email and message teachers and friends.", url: "https://mail.google.com", cta: "Open Email", icon: "email" },
  { title: "Google Classroom", description: "View assignments, materials, and due dates.", url: "https://classroom.google.com", cta: "Open Classroom", icon: "classroom" },
  { title: "Trackers", description: "Your Success Circle and Homeroom to-do and focus lists.", url: "https://pathwaysandpossibilities.netlify.app/tracker", cta: "Open Tracker", icon: "compass" },
  { title: "Feedback", description: "Give feedback on anything LU.", url: "https://docs.google.com/forms/d/e/1FAIpQLSfwVwucRiMsnTMPcP-LV25BrLkVb_dBFtxDyX0xMIMqguZisQ/viewform", cta: "Open Form", icon: "document" }
];
const DEFAULT_PORTAL_BANNER = { enabled: false, text: "", link_text: "Learn more", link_url: "" };
async function portalLayoutUI(host = app) {
  const { data: st, error } = await sb.from("settings").select("portal_banner,portal_tiles").eq("id", 1).single();
  const banner = { ...DEFAULT_PORTAL_BANNER, ...(st?.portal_banner || {}) };
  let tiles = Array.isArray(st?.portal_tiles) && st.portal_tiles.length ? st.portal_tiles : DEFAULT_PORTAL_TILES;
  host.innerHTML = (host === app ? tabs() : "") + `<section class="portal-admin-section"><h3>Announcement banner</h3><p>Show a message directly below the navigation bar. Link to another page on this site (for example <code>photos.html</code>) or paste a full external URL.</p>
    <form id="portal-banner-form"><label class="inline-check"><input name="enabled" type="checkbox" ${banner.enabled ? "checked" : ""}> Show banner on the main page</label>
    <label>Announcement text<input name="text" maxlength="240" value="${esc(banner.text)}" placeholder="e.g. Photo submissions close Friday!"></label>
    <label>Link text (optional)<input name="link_text" maxlength="60" value="${esc(banner.link_text)}" placeholder="Learn more"></label>
    <label>Link destination (optional)<input name="link_url" value="${esc(banner.link_url)}" placeholder="photos.html or https://example.com"></label>
    <div><button class="auth-btn" type="submit">Save banner</button></div><small id="banner-msg"></small></form></section>
    <section class="portal-admin-section"><h3>Main page tiles</h3><p>Add, remove, or edit the quick-link tiles shown on the home page. Keep destinations to a page on this site or a full URL. On wide screens the tiles use a four-column grid and adapt to smaller screens.</p>
    <div id="portal-tile-editor">${tiles.map((t,i)=>portalTileForm(t,i)).join("")}</div>
    <div class="portal-admin-actions"><button class="auth-btn alt" type="button" id="add-portal-tile">+ Add tile</button> <button class="auth-btn" type="button" id="save-portal-tiles">Save tiles</button></div><small id="tiles-msg"></small></section>`;
  if (host === app) wire();
  const bf = document.getElementById("portal-banner-form");
  bf.onsubmit = async e => { e.preventDefault(); const f=e.target.elements; const out={enabled:f.enabled.checked,text:f.text.value.trim(),link_text:f.link_text.value.trim(),link_url:f.link_url.value.trim()}; const {error}=await sb.from("settings").update({portal_banner:out}).eq("id",1); document.getElementById("banner-msg").textContent=error?"Error: "+error.message:"Saved"; };
  const editor=document.getElementById("portal-tile-editor");
  document.getElementById("add-portal-tile").onclick=()=>{ const i=editor.querySelectorAll(".portal-tile-edit").length; editor.insertAdjacentHTML("beforeend",portalTileForm({title:"New tile",description:"",url:"index.html",cta:"Open",icon:"link"},i)); };
  editor.addEventListener("click",e=>{const b=e.target.closest("[data-remove-tile]");if(b){b.closest(".portal-tile-edit").remove();}});
  document.getElementById("save-portal-tiles").onclick=async()=>{const msg=document.getElementById("tiles-msg"); const rows=[...editor.querySelectorAll(".portal-tile-edit")]; const out=[]; for(const row of rows){const val=n=>row.querySelector(`[name="${n}"]`).value.trim();const title=val("title"),url=val("url");if(!title||!url){msg.textContent="Each tile needs a title and destination URL.";return;}out.push({title,description:val("description"),url,cta:val("cta")||"Open",icon:val("icon")||"link",secondary_text:val("secondary_text"),secondary_url:val("secondary_url")});} msg.textContent="Saving…";const {error}=await sb.from("settings").update({portal_tiles:out}).eq("id",1);msg.textContent=error?"Error: "+error.message:"Saved";};
}
function portalTileForm(t,i){return `<div class="portal-tile-edit"><div class="portal-tile-edit-head"><strong>Tile ${i+1}</strong><button type="button" class="auth-btn alt" data-remove-tile>Remove</button></div><div class="portal-tile-fields">
<label>Title<input name="title" value="${esc(t.title||"")}" required></label><label>Icon<select name="icon">${["calendar","drive","chat","email","classroom","compass","document","link","photo","video"].map(v=>`<option value="${v}" ${t.icon===v?"selected":""}>${v}</option>`).join("")}</select></label>
<label class="wide">Description<input name="description" value="${esc(t.description||"")}"></label><label>Destination URL<input name="url" value="${esc(t.url||"")}" placeholder="photos.html or https://…" required></label><label>Link label<input name="cta" value="${esc(t.cta||"Open")}"></label>
<label>Secondary link text (optional)<input name="secondary_text" value="${esc(t.secondary_text||"")}"></label><label>Secondary link destination (optional)<input name="secondary_url" value="${esc(t.secondary_url||"")}"></label></div></div>`;}


const DEFAULT_HOME_SECTIONS = [
  {id:"hero", label:"Welcome header", enabled:true},
  {id:"links", label:"Quick-link tiles", enabled:true},
  {id:"announcements", label:"Latest announcements", enabled:true},
  {id:"videos", label:"Latest videos", enabled:true},
  {id:"faq", label:"Frequently asked questions", enabled:true},
  {id:"photo-challenge", label:"Photo Challenge shortcut", enabled:true}
];
async function homeLayoutUI(host = app) {
  const {data: st, error} = await sb.from("settings").select("portal_home_sections").eq("id",1).single();
  let sections = Array.isArray(st?.portal_home_sections) && st.portal_home_sections.length ? st.portal_home_sections : DEFAULT_HOME_SECTIONS;
  sections = [...sections.filter(s=>DEFAULT_HOME_SECTIONS.some(d=>d.id===s.id)), ...DEFAULT_HOME_SECTIONS.filter(d=>!sections.some(s=>s.id===d.id))];
  host.innerHTML = (host === app ? tabs() : "") + `<section class="portal-admin-section"><h3>Home page layout</h3><p>Choose which sections appear on the home page and change their order. The Photo Challenge shortcut gives students a clear path to upload photos. Your existing tiles, announcement banner, and content remain intact.</p>${error ? `<p class="auth-error">Couldn't load settings: ${esc(error.message)}</p>` : ""}<div id="home-section-editor" aria-label="Drag sections to reorder">${sections.map((s)=>`<div class="home-section-edit" data-section="${s.id}" draggable="true"><span class="home-drag-handle" aria-hidden="true">Move</span><label class="inline-check"><input type="checkbox" name="enabled" ${s.enabled!==false?"checked":""}> ${esc(s.label)}</label><span class="home-drag-hint">Drag to reorder</span></div>`).join("")}</div><div class="portal-admin-actions"><button class="auth-btn" id="save-home-layout">Save home page</button></div><small id="home-layout-msg"></small></section>`;
  if (host === app) wire();
  const editor=document.getElementById("home-section-editor");
  let dragging=null;
  editor.querySelectorAll(".home-section-edit").forEach(row=>{
    row.addEventListener("dragstart",e=>{dragging=row;row.classList.add("is-dragging");e.dataTransfer.effectAllowed="move";e.dataTransfer.setData("text/plain",row.dataset.section);});
    row.addEventListener("dragend",()=>{row.classList.remove("is-dragging");editor.querySelectorAll(".home-section-edit").forEach(r=>r.classList.remove("drop-target"));dragging=null;});
    row.addEventListener("dragover",e=>{e.preventDefault();if(!dragging||dragging===row)return;row.classList.add("drop-target");e.dataTransfer.dropEffect="move";});
    row.addEventListener("dragleave",()=>row.classList.remove("drop-target"));
    row.addEventListener("drop",e=>{e.preventDefault();row.classList.remove("drop-target");if(!dragging||dragging===row)return;const rect=row.getBoundingClientRect();editor.insertBefore(dragging,e.clientY<rect.top+rect.height/2?row:row.nextSibling);});
  });
  document.getElementById("save-home-layout").onclick = async () => {
    const rows=[...document.querySelectorAll(".home-section-edit")];
    const out=rows.map(r=>({id:r.dataset.section,label:DEFAULT_HOME_SECTIONS.find(s=>s.id===r.dataset.section)?.label,enabled:r.querySelector('[name="enabled"]').checked}));
    const msg=document.getElementById("home-layout-msg"); msg.textContent="Saving…";
    const {error}=await sb.from("settings").update({portal_home_sections:out}).eq("id",1);
    msg.textContent=error?"Error: "+error.message:"Saved Refresh the home page to see your changes.";
  };
}

async function settings() {
  const { data: s } = await sb.from("settings").select("*").eq("id", 1).single();
  app.innerHTML = tabs() + `<form><h3>Schedule settings</h3>
  <label>Days each theme runs <small>Used to suggest dates when you add the next theme. You can still edit any theme's dates by hand.</small><input name="theme_length_days" type="number" min="1" value="${s.theme_length_days}"></label>
  <label>Photos per student per theme<input name="max_photos_per_theme" type="number" min="1" value="${s.max_photos_per_theme}"></label>
  <label>Time zone <small>e.g. America/Denver, America/New_York</small><input name="timezone" value="${esc(s.timezone)}"></label>
  <div><button class="auth-btn" type="submit">Save</button></div><small id="msg"></small></form>`;
  wire();
  app.querySelector("form").onsubmit = async e => {
    e.preventDefault(); const f = e.target.elements;
    const { error } = await sb.from("settings").update({ theme_length_days: +f.theme_length_days.value, max_photos_per_theme: +f.max_photos_per_theme.value, timezone: f.timezone.value.trim() }).eq("id", 1);
    app.querySelector("#msg").textContent = error ? "Error: " + error.message : "Saved";
  };
}

let sel = null;
const shrink = f => new Promise((ok, no) => { const i = new Image(); i.onload = () => { const s = Math.min(1, 1600 / Math.max(i.width, i.height)), c = document.createElement("canvas"); c.width = i.width * s; c.height = i.height * s; c.getContext("2d").drawImage(i, 0, 0, c.width, c.height); c.toBlob(ok, "image/jpeg", .85); }; i.onerror = no; i.src = URL.createObjectURL(f); });
async function photosSection() {
  const box = document.getElementById("photos-section"); if (!box) return;
  const { data: th = [] } = await sb.from("themes").select("*").order("starts_at", { ascending: false });
  if (!th.length) { box.innerHTML = "<h3>Photos</h3><p>Add a theme above first. For past themes, just use past dates.</p>"; return; }
  sel = th.find(t => t.id === sel)?.id || th[0].id;
  const { data: subs = [] } = await sb.from("submissions").select("*").eq("theme_id", sel).order("created_at");
  const urls = {}; if (subs.length) (await sb.storage.from("photos").createSignedUrls(subs.map(s => s.image_path), 3600)).data?.forEach(u => urls[u.path] = u.signedUrl);
  const opts = id => th.map(t => `<option value="${t.id}" ${t.id === id ? "selected" : ""}>${esc(t.title)} (${new Date(t.starts_at).toLocaleDateString()})</option>`).join("");
  const grp = st => subs.filter(s => s.status === st), pend = grp("pending"), appr = grp("approved"), rej = grp("rejected");
  const via = s => s.image_path.startsWith("public/") ? ' <span class="via-badge">public page</span>' : "";
  const img = s => `<img src="${urls[s.image_path]}" alt="">`;
  box.innerHTML = `<h3>Photos</h3>
  <label>Theme <select id="ph-ts">${opts(sel)}</select></label>
  <div class="needs-approval ${pend.length ? "has" : ""}"><div class="na-head"><h4>Needs approval</h4><span class="na-count">${pend.length}</span></div>
    ${pend.length ? `<div class="thumbs">${pend.map(s => `<figure>${img(s)}<figcaption><b>${esc(s.submitted_by)}</b>${via(s)}<span><button class="auth-btn" data-s="approved" data-id="${s.id}">Approve</button> <button class="auth-btn alt" data-s="rejected" data-id="${s.id}">Reject</button></span></figcaption></figure>`).join("")}</div>` : "<p><small>Nothing waiting, all caught up</small></p>"}</div>
  <div class="approved-block"><div class="na-head"><h4>Approved</h4><span class="na-count ok">${appr.length}</span></div>
    <div class="thumbs">${appr.map(s => `<figure data-fig="${s.id}">${img(s)}<figcaption><b>${esc(s.submitted_by)}</b>${via(s)}<span><button class="auth-btn alt" data-edit="${s.id}">Edit</button></span></figcaption></figure>`).join("") || "<p><small>No approved photos yet.</small></p>"}</div></div>
  ${rej.length ? `<details class="rej"><summary>Rejected (${rej.length})</summary><div class="thumbs">${rej.map(s => `<figure>${img(s)}<figcaption><b>${esc(s.submitted_by)}</b><span><button class="auth-btn alt" data-s="approved" data-id="${s.id}">Approve</button> <button class="auth-btn alt" data-x="${s.id}" data-p="${esc(s.image_path)}">Delete</button></span></figcaption></figure>`).join("")}</div></details>` : ""}
  <form id="ph-man"><h3>Import photos</h3><small>Adds photos straight into the theme you choose, already approved, good for past Google Form entries. They appear in the gallery with that theme's other photos.</small>
  <label>Theme these photos belong to<select name="th" required>${opts(sel)}</select></label>
  <label>Student name shown<input name="n" required></label>
  <label>Photos<input type="file" name="f" accept="image/*" multiple required></label>
  <div><button class="auth-btn" type="submit">Import as approved</button></div><small id="ph-msg"></small></form>`;
  box.querySelector("#ph-ts").onchange = e => { sel = e.target.value; photosSection(); };
  box.querySelectorAll("[data-s]").forEach(b => b.onclick = async () => { await sb.from("submissions").update({ status: b.dataset.s }).eq("id", b.dataset.id); photosSection(); });
  box.querySelectorAll("[data-x]").forEach(b => b.onclick = async () => { if (!confirm("Delete this photo?")) return; await sb.from("submissions").delete().eq("id", b.dataset.x); await sb.storage.from("photos").remove([b.dataset.p]); photosSection(); });
  box.querySelectorAll("[data-edit]").forEach(b => b.onclick = () => {
    const s = subs.find(x => x.id === b.dataset.edit), fig = box.querySelector(`[data-fig="${s.id}"]`);
    fig.querySelector("figcaption").innerHTML = `<input class="ed-name" value="${esc(s.submitted_by)}" maxlength="60" aria-label="Name shown with this photo"><span><button class="auth-btn" data-save>Save name</button> <button class="auth-btn alt" data-del>Delete photo</button> <button class="auth-btn alt" data-cancel>Cancel</button></span>`;
    fig.querySelector(".ed-name").focus();
    fig.querySelector("[data-save]").onclick = async () => { const nm = fig.querySelector(".ed-name").value.trim(); if (!nm) return; const { error } = await sb.from("submissions").update({ submitted_by: nm }).eq("id", s.id); error ? alert(error.message) : photosSection(); };
    fig.querySelector("[data-del]").onclick = async () => { if (!confirm("Delete this photo permanently?")) return; await sb.from("submissions").delete().eq("id", s.id); await sb.storage.from("photos").remove([s.image_path]); photosSection(); };
    fig.querySelector("[data-cancel]").onclick = () => photosSection();
  });
  box.querySelector("#ph-man").onsubmit = async e => {
    e.preventDefault(); const f = e.target.elements, msg = box.querySelector("#ph-msg"), target = f.th.value, files = [...f.f.files];
    for (const [k, file] of files.entries()) {
      msg.textContent = `Uploading ${k + 1} of ${files.length}…`;
      try {
        const path = `admin/${crypto.randomUUID()}.jpg`, up = await sb.storage.from("photos").upload(path, await shrink(file), { contentType: "image/jpeg" }); if (up.error) throw up.error;
        const ins = await sb.from("submissions").insert({ theme_id: target, user_id: null, submitted_by: f.n.value.trim(), image_path: path, status: "approved" }); if (ins.error) throw ins.error;
      } catch (err) { return (msg.textContent = "Failed on " + file.name + ": " + (err.message || err)); }
    }
    sel = target; await photosSection();
    box.querySelector("#ph-msg").textContent = `Imported ${files.length} photo${files.length === 1 ? "" : "s"}`;
  };
  if (ROLE !== "admin") box.querySelectorAll("[data-edit],[data-x],#ph-man").forEach(e => e.remove());
}

function importUI() {
  app.innerHTML = tabs() + `<form id="imp"><h3>Import students</h3>
  <label>Student list <small>One per line: email, name (a header row is fine). Or choose a CSV file below.</small><textarea name="list" rows="8" placeholder="jane.doe@latterup.org, Jane Doe"></textarea></label>
  <label>CSV file (optional)<input type="file" name="csv" accept=".csv,.txt"></label>
  <label><span><input type="radio" name="m" value="same" checked> Same starting password for everyone</span><input name="pw" placeholder="At least 8 characters"></label>
  <label><span><input type="radio" name="m" value="random"> A different random password for each student (you'll download the list)</span></label>
  <label><span><input type="checkbox" name="reset"> Also reset the password of students who already have an account</span></label>
  <small>Students are asked to choose their own password the first time they sign in. Existing accounts are left alone unless you tick the box above.</small>
  <div><button class="auth-btn" type="submit">Create accounts</button></div><div id="res"></div></form>`;
  wire();
  const f = document.getElementById("imp").elements, res = document.getElementById("res");
  f.csv.onchange = async () => { f.list.value = await f.csv.files[0].text(); };
  const cells = l => [...l.matchAll(/(?:^|,)\s*(?:"([^"]*)"|([^,]*))/g)].map(m => (m[1] ?? m[2] ?? "").trim());
  document.getElementById("imp").onsubmit = async e => {
    e.preventDefault();
    const students = f.list.value.split(/\r?\n/).filter(l => l.trim()).map(cells).filter(c => c[0].toLowerCase() !== "email").map(c => ({ email: c[0], name: c[1] || "" }));
    const random = f.m.value === "random";
    if (!students.length) return (res.textContent = "Add at least one student.");
    if (!random && f.pw.value.length < 8) return (res.textContent = "The starting password needs at least 8 characters.");
    const all = []; res.textContent = "Working…";
    for (let i = 0; i < students.length; i += 20) {
      const { data, error } = await sb.functions.invoke("import-students", { body: { students: students.slice(i, i + 20), password: f.pw.value, random, reset: f.reset.checked } });
      if (error) { let m = error.message; try { m = (await error.context.json()).error || m; } catch {} return (res.innerHTML = "<p class='auth-error'>" + esc(m) + "</p>"); }
      all.push(...data.results); res.textContent = `Working… ${Math.min(i + 20, students.length)} of ${students.length}`;
    }
    const n = s => all.filter(r => r.status === s).length;
    res.innerHTML = `<p><b>Done.</b> Created ${n("created")}, reset ${n("reset")}, left alone ${n("exists")}, skipped ${n("skipped")}, failed ${n("failed")}.</p>` +
      all.filter(r => r.note).map(r => `<small>${esc(r.email)}: ${esc(r.note)}</small><br>`).join("");
    const pw = all.filter(r => r.password);
    if (random && pw.length) {
      const csv = "email,name,password\n" + pw.map(r => `"${r.email}","${r.name || ""}","${r.password}"`).join("\n");
      const a = document.createElement("a"); a.className = "auth-btn"; a.textContent = "Download passwords (then delete the file after handing them out)";
      a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" })); a.download = "student-passwords.csv"; res.appendChild(a);
    }
  };
}
async function peopleUI(table, heading, blurb, addLabel, btnText) {
  const { data = [], error } = await sb.from(table).select("email").order("email");
  const me = (await sb.auth.getSession()).data.session.user.email.toLowerCase();
  app.innerHTML = tabs() + `<h3>${heading}</h3><p><small>${blurb}</small></p>${error ? `<p class="auth-error">${esc(error.message)}, run the latest SQL update first.</p>` : ""}` +
    data.map(a => `<div class="row"><span>${esc(a.email)}</span>${table === "admins" && a.email === me ? "<small>(you)</small>" : `<button class="auth-btn alt" data-rm="${esc(a.email)}">Remove</button>`}</div>`).join("") +
    `<form id="aa"><label>${addLabel}<input type="email" name="e" placeholder="name@latterup.org" required></label><div><button class="auth-btn" type="submit">${btnText}</button></div><small id="msg"></small></form>`;
  wire();
  app.querySelectorAll("[data-rm]").forEach(b => b.onclick = async () => { if (confirm("Remove " + b.dataset.rm + " from " + heading.toLowerCase() + "?")) { await sb.from(table).delete().eq("email", b.dataset.rm); peopleUI(table, heading, blurb, addLabel, btnText); } });
  document.getElementById("aa").onsubmit = async e => {
    e.preventDefault(); const em = e.target.elements.e.value.trim().toLowerCase(), msg = document.getElementById("msg");
    if (!em.endsWith("@latterup.org")) return (msg.textContent = "Use an @latterup.org address.");
    const { error } = await sb.from(table).insert({ email: em }); error ? (msg.textContent = error.message) : peopleUI(table, heading, blurb, addLabel, btnText);
  };
}

async function alertsUI() {
  const { data: c, error } = await sb.from("notify_config").select("*").eq("id", 1).maybeSingle();
  app.innerHTML = tabs() + `<form id="al" class="admin-schedule"><h3>Email alerts for new photos</h3>
    <p><small>When students or visitors submit photos, everyone on the Leadership team and all Admins get one email (at most every 5 minutes) saying how many are waiting. Setup steps are at the top of <b>email-alerts.gs</b>.</small></p>
    ${error ? `<p class="auth-error">${esc(error.message)}, run update-5b-email-alerts.sql first.</p>` : ""}
    <label class="chk"><input type="checkbox" name="enabled" ${c?.enabled ? "checked" : ""}> Send email alerts</label>
    <label>Google Apps Script web app URL<input name="url" value="${esc(c?.webhook_url || "")}" placeholder="https://script.google.com/macros/s/…/exec"></label>
    <label>Secret phrase <small>Must match the SECRET you set in the script</small><input name="secret" type="password" value="${esc(c?.secret || "")}" autocomplete="off"></label>
    <label>Your site address <small>Used for the link inside the email</small><input name="site" value="${esc(c?.site_url || location.origin)}"></label>
    <div><button class="auth-btn" type="submit">Save</button> <button class="auth-btn alt" type="button" id="al-test">Send a test email</button></div>
    <small id="al-msg">${c?.last_sent_at ? "Last email requested " + esc(new Date(c.last_sent_at).toLocaleString()) + (c.last_status ? ", Google replied " + c.last_status : "") : ""}</small></form>`;
  wire();
  const f = document.getElementById("al").elements, msg = document.getElementById("al-msg");
  const save = async () => { const { error } = await sb.from("notify_config").update({ enabled: f.enabled.checked, webhook_url: f.url.value.trim(), secret: f.secret.value, site_url: f.site.value.trim().replace(/\/$/, "") }).eq("id", 1); if (error) msg.textContent = "Error: " + error.message; return !error; };
  document.getElementById("al").onsubmit = async e => { e.preventDefault(); if (await save()) msg.textContent = "Saved"; };
  document.getElementById("al-test").onclick = async () => {
    msg.textContent = "Sending…"; if (!(await save())) return;
    const { data, error } = await sb.rpc("send_test_alert"); msg.textContent = error ? "Error: " + error.message : data + " Check your inbox in a minute.";
  };
}
async function homeTabUI() {
  app.innerHTML = tabs() + '<div id="hp-portal"></div><div id="hp-home"></div><section class="portal-admin-section"><h3>Frequently asked questions</h3><div id="hp-faq"></div></section>';
  wire();
  await portalLayoutUI(document.getElementById("hp-portal"));
  await homeLayoutUI(document.getElementById("hp-home"));
  await listUI("faq", document.getElementById("hp-faq"));
}

async function studentsUI() {
  const { data = [], error } = await sb.rpc("list_students");
  app.innerHTML = tabs() + `<h3>Students</h3><p><small>Everyone who has a login for the portal. To add more people, use the Import students tab.</small></p>${error ? `<p class="auth-error">${esc(error.message)}, run update-6-students-list.sql first.</p>` : ""}
    <label>Search<input id="st-q" type="search" placeholder="Type a name or email"></label><p><small id="st-count"></small></p><div id="st-list"></div>`;
  wire();
  const list = document.getElementById("st-list"), count = document.getElementById("st-count");
  const paint = () => {
    const q = document.getElementById("st-q").value.trim().toLowerCase();
    const rows = data.filter(s => !q || (s.email + " " + (s.full_name || "")).toLowerCase().includes(q));
    count.textContent = q ? `${rows.length} of ${data.length} people` : `${data.length} people`;
    list.innerHTML = rows.map(s => `<div class="row"><span>${s.full_name ? "<b>" + esc(s.full_name) + "</b> · " : ""}${esc(s.email)}
      ${s.admin_role ? ' <span class="via-badge">Admin</span>' : ""}${s.leader_role ? ' <span class="via-badge">Leadership</span>' : ""}${s.must_change_password ? ' <span class="sched-badge">Hasn\'t chosen a password yet</span>' : ""}</span>
      <small>${s.last_sign_in_at ? "Last sign-in " + esc(new Date(s.last_sign_in_at).toLocaleDateString()) : "Never signed in"}</small></div>`).join("") || "<p><small>No matches.</small></p>";
  };
  document.getElementById("st-q").oninput = paint; paint();
}
boot();
