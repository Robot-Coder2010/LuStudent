// Shared banner for every page (except admin): brand mark, menu, theme toggle, profile menu.
(async () => {
  const C = window.LU_CONFIG; window.LUsb = window.LUsb || supabase.createClient(C.url, C.key);
  const sb = window.LUsb, host = document.getElementById("site-header"); if (!host) return;
  const page = location.pathname.split("/").pop() || "index.html";
  const links = [["Home", "index.html"], ["Announcements", "announcements.html"], ["Videos", "videos.html"], ["Photo Challenge", "photos.html"]];
  const mark = '<svg viewBox="0 0 64 64" role="img" aria-label="Latter UP home"><defs><linearGradient id="luNavy" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#263B70"/><stop offset="1" stop-color="#111A44"/></linearGradient></defs><rect x="2" y="2" width="60" height="60" rx="18" fill="url(#luNavy)"/><circle cx="45" cy="17" r="5" fill="#FFC83D"/><path d="M13 42 25 21l9 15 6-9 12 19H13Z" fill="#F6F8FF" opacity=".96"/><path d="M13 46h39" stroke="#FFC83D" stroke-width="4" stroke-linecap="round"/><path d="m25 21 4 7-4 2-4-2Z" fill="#FFC83D"/></svg>';
  const el = document.createElement("header"); el.className = "site-header";
  el.innerHTML = `<div class="wrap header-inner"><a class="brand" href="index.html">${mark}</a>
    <nav class="site-nav" id="nav" aria-label="Primary">${links.map(([t, h]) => `<a href="${h}" ${h === page ? 'aria-current="page"' : ""}>${t}</a>`).join("")}</nav>
    <div class="hdr-right"><div class="menu-wrap" id="pf"></div>
    <button class="icon-btn burger" id="bg" aria-label="Menu" aria-expanded="false">${LUIcon("menu", 22)}</button></div></div>`;
  host.replaceWith(el);
  const $ = id => document.getElementById(id), root = document.documentElement;
  document.querySelectorAll(".calendar-combo").forEach(card => {
    const openCalendar = () => window.open(card.dataset.calendarUrl, "_blank", "noopener");
    card.addEventListener("click", event => { if (!event.target.closest(".calendar-secondary")) openCalendar(); });
    card.addEventListener("keydown", event => { if ((event.key === "Enter" || event.key === " ") && !event.target.closest(".calendar-secondary")) { event.preventDefault(); openCalendar(); } });
  });
  const paint = () => {
    const th = $("th");
    if (th) th.innerHTML = th.classList.contains("theme-standalone") ? (root.dataset.theme === "dark" ? LUIcon("sun", 20) : LUIcon("moon", 20)) : (root.dataset.theme === "dark" ? LUIcon("sun", 18) + " Switch to light mode" : LUIcon("moon", 18) + " Switch to dark mode");
  };
  const toggleTheme = () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
    localStorage.setItem("lu-theme", root.dataset.theme);
    paint();
  };
  $("bg").onclick = () => { const o = $("nav").classList.toggle("open"); $("bg").setAttribute("aria-expanded", o); };
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    $("pf").innerHTML = '<button class="auth-btn" id="si">Sign in</button><button class="icon-btn theme-standalone" id="th" aria-label="Switch light/dark mode"></button>';
    $("si").onclick = () => (location.href = "login.html?next=" + encodeURIComponent(page));
    paint(); $("th").onclick = toggleTheme;
  }
  else {
    const u = session.user, name = u.app_metadata?.full_name || u.email, adm = await (async () => { const r = await sb.rpc("my_role"); return r.data || ((await sb.rpc("is_admin")).data ? "admin" : "student"); })();
    $("pf").innerHTML = `<button class="icon-btn avatar" id="pb" aria-label="Profile menu" aria-haspopup="true">${name[0].toUpperCase()}</button>
      <div class="menu" id="pm"><div class="who"><b>${name.replace(/[<>&]/g, "")}</b><br>${u.email}</div><a href="change-password.html">Change password</a><a href="photos.html">My photos</a>${adm !== "student" ? '<a href="admin.html">' + (adm === "admin" ? "Admin" : "Leadership tools") + '</a>' : ""}<a href="mailto:studentleadership@latterup.org">Contact Student Leadership</a><button id="th" class="theme-menu-toggle" type="button"></button><button id="so">Sign out</button></div>`;
    paint(); $("th").onclick = e => { e.stopPropagation(); toggleTheme(); };
    $("pb").onclick = e => { e.stopPropagation(); $("pm").classList.toggle("open"); };
    document.addEventListener("click", () => $("pm").classList.remove("open"));
    $("so").onclick = async () => { await sb.auth.signOut(); location.href = "index.html"; };
  }
})();
