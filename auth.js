// Sign-in + loads site content from Supabase, then runs script.js to render it.
(async function () {
  const C = window.LU_CONFIG;
  const sb = (window.LUsb || supabase.createClient(C.url, C.key));
  window.LU = { sb };
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  // Allow only simple formatting + safe links in admin-written HTML (FAQ answers).
  const clean = h => {
    const d = new DOMParser().parseFromString(h || "", "text/html");
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

  let session = null;
  if (window.LU_LOCAL_PREVIEW) {
    window.FAQ_ITEMS = window.LU_PREVIEW_DATA.faq;
    window.ANNOUNCEMENT_ITEMS = window.LU_PREVIEW_DATA.announcements;
    window.VIDEO_ITEMS = window.LU_PREVIEW_DATA.videos;
  } else {
    ({ data: { session } } = await sb.auth.getSession());

    if (authError) { const b = document.createElement("p"); b.className = "auth-error"; b.textContent = "Sign-in failed: " + authError + " (Use your @latterup.org account.)"; document.querySelector("main").prepend(b); }

    // Public content
    const faq = await sb.from("faq").select("*").order("sort_order");
    if (faq.error) console.error("FAQ content could not be loaded:", faq.error);
    window.LU_FAQ_ERROR = faq.error;
    window.FAQ_ITEMS = (faq.data ?? []).map(f => ({ question: esc(f.question), answer: clean(f.answer) }));
    window.ANNOUNCEMENT_ITEMS = []; window.VIDEO_ITEMS = [];

    // Private content (only returned by the database for signed-in @latterup.org users)
    if (session) {
      const nowIso = new Date().toISOString();
      const [a, v] = await Promise.all([sb.from("announcements").select("*").lte("publish_at", nowIso), sb.from("videos").select("*").lte("publish_at", nowIso)]);
      if (a.error) console.error("Announcements could not be loaded:", a.error);
      if (v.error) console.error("Videos could not be loaded:", v.error);
      const paths = [...(a.data || []).map(x => x.pdf_path), ...(v.data || []).map(x => x.video_path)].filter(Boolean);
      const urls = {};
      if (paths.length) {
        let data;
        try {
          const result = await sb.storage.from("media").createSignedUrls(paths, 3600);
          data = result.data;
          if (result.error) console.error("Some announcement/video files could not be signed:", result.error);
        } catch (error) {
          console.error("Announcement/video links could not be requested:", error);
          data = [];
        }
        (data ?? []).forEach(file => {
          if (file.signedUrl) urls[file.path] = file.signedUrl;
          else console.error("Announcement/video file could not be signed:", file.path, file.error);
        });
        const signedPaths = new Set((data ?? []).filter(file => file.signedUrl).map(file => file.path));
        paths.filter(path => !signedPaths.has(path))
          .forEach(path => console.error("Announcement/video file has no signed URL:", path));
      }
      const br = s => esc(s).replace(/(https?:\/\/[^\s<]*[^\s<.,;:!?)])/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>').replace(/\n/g, "<br>");
      window.ANNOUNCEMENT_ITEMS = (a.data || []).map(x => ({
        title: esc(x.title), date: x.date, text: br(x.text), pdfSrc: urls[x.pdf_path],
        pdfUnavailable: !!x.pdf_path && !urls[x.pdf_path]
      }));
      window.VIDEO_ITEMS = (v.data || []).map(x => ({
        title: esc(x.title), date: x.date, description: br(x.description), youtubeId: x.youtube_id, googleDriveId: x.google_drive_id, videoSrc: urls[x.video_path],
        videoUnavailable: !x.youtube_id && !x.google_drive_id && !!x.video_path && !urls[x.video_path]
      }));
      window.LU_CONTENT_ERRORS = { announcements: a.error, videos: v.error };
    }
  }

  await new Promise((ok, no) => { const s = document.createElement("script"); s.src = "script.js"; s.onload = ok; s.onerror = no; document.body.appendChild(s); });

  if (window.LU_FAQ_ERROR) {
    const el = document.getElementById("faq-list");
    if (el) el.textContent = "FAQ content could not be loaded. Please try again later.";
  }

  for (const [kind, ids] of Object.entries({
    announcements: ["announcements-preview-list", "announcements-full-list"],
    videos: ["videos-preview-list", "videos-full-list"],
  })) {
    const error = window.LU_CONTENT_ERRORS?.[kind];
    if (!error) continue;
    ids.forEach(id => {
      const el = document.getElementById(id);
      if (el) el.textContent = `This ${kind} content could not be loaded. Please try again later.`;
    });
  }

  if (!session && !window.LU_LOCAL_PREVIEW) {
    ["announcements-preview-list", "announcements-full-list", "videos-preview-list", "videos-full-list"].forEach(id => {
      const el = document.getElementById(id); if (!el) return;
      el.innerHTML = '<div class="gate"><p>Sign in with your <strong>@latterup.org</strong> account to see this.</p><button class="auth-btn">Sign in</button></div>';
      el.querySelector("button").onclick = signIn;
    });
  }
})();
