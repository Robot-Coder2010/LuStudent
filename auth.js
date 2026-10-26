// Sign-in + loads site content from Supabase, then runs script.js to render it.
(async function () {
  const C = window.LU_CONFIG;
  const sb = (window.LUsb || supabase.createClient(C.url, C.key));
  window.LU = { sb };
  const esc = s => String(s ?? "").replace(/\s*\u2014\s*/g, ", ").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  // Allow only simple formatting + safe links in admin-written HTML (FAQ answers).
  const clean = h => {
    const d = new DOMParser().parseFromString((h || "").replace(/\s*\u2014\s*/g, ", "), "text/html");
    d.body.querySelectorAll("*").forEach(n => {
      if (/^(SCRIPT|STYLE)$/.test(n.tagName)) return n.remove();
      if (!/^(A|BR|B|I|EM|STRONG|P|UL|OL|LI)$/.test(n.tagName)) return n.replaceWith(...n.childNodes);
      [...n.attributes].forEach(a => {
        const ok = n.tagName === "A" && ((a.name === "href" && /^(https?:|mailto:)/i.test(a.value)) || a.name === "target" || a.name === "rel");
        if (!ok) n.removeAttribute(a.name);
      });
    });
    return d.body.innerHTML;
  };
  const signIn = () => (location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() || "index.html"));
  const params = new URLSearchParams(location.search + "&" + location.hash.slice(1));
  const authError = params.get("error_description");

  const { data: { session } } = await sb.auth.getSession();

  if (authError) { const b = document.createElement("p"); b.className = "auth-error"; b.textContent = "Sign-in failed: " + authError + " (Use your @latterup.org account.)"; document.querySelector("main").prepend(b); }

  // Public content
  const faq = await sb.from("faq").select("*").order("sort_order");
  window.FAQ_ITEMS = (faq.data || []).map(f => ({ question: esc(f.question), answer: clean(f.answer) }));
  window.ANNOUNCEMENT_ITEMS = []; window.VIDEO_ITEMS = [];

  // Private content (only returned by the database for signed-in @latterup.org users)
  if (session) {
    const nowIso = new Date().toISOString();
    let [a, v] = await Promise.all([sb.from("announcements").select("*").lte("publish_at", nowIso), sb.from("videos").select("*").lte("publish_at", nowIso)]);
    if (a.error) a = await sb.from("announcements").select("*");
    if (v.error) v = await sb.from("videos").select("*");
    const paths = [...(a.data || []).map(x => x.pdf_path), ...(v.data || []).map(x => x.video_path)].filter(Boolean);
    const urls = {};
    if (paths.length) (await sb.storage.from("media").createSignedUrls(paths, 3600)).data?.forEach(u => { urls[u.path] = u.signedUrl; });
    const br = s => esc(s).replace(/(https?:\/\/[^\s<]*[^\s<.,;:!?)])/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>').replace(/\n/g, "<br>");
    window.ANNOUNCEMENT_ITEMS = (a.data || []).map(x => ({ title: esc(x.title), date: x.date, text: br(x.text), pdfSrc: urls[x.pdf_path] }));
    window.VIDEO_ITEMS = (v.data || []).map(x => ({ title: esc(x.title), date: x.date, description: br(x.description), youtubeId: x.youtube_id, videoSrc: urls[x.video_path] }));
  }

  await new Promise((ok, no) => { const s = document.createElement("script"); s.src = "script.js"; s.onload = ok; s.onerror = no; document.body.appendChild(s); });

  if (!session) {
    ["announcements-preview-list", "announcements-full-list", "videos-preview-list", "videos-full-list"].forEach(id => {
      const el = document.getElementById(id); if (!el) return;
      el.innerHTML = '<div class="gate"><p>Sign in with your <strong>@latterup.org</strong> account to see this.</p><button class="auth-btn">Sign in</button></div>';
      el.querySelector("button").onclick = signIn;
    });
  }
})();
