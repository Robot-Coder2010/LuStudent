(async () => {
  const PUB = !!window.LU_PUBLIC, C = LU_CONFIG, sb = PUB ? supabase.createClient(C.url, C.key, { auth: { persistSession: false, autoRefreshToken: false, storageKey: "lu-public" } }) : (window.LUsb || supabase.createClient(C.url, C.key)), $ = id => document.getElementById(id);
  const esc = s => String(s ?? "").replace(/\s*\u2014\s*/g, ", ").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const { data: { session } } = PUB ? { data: { session: null } } : await sb.auth.getSession();
  let pubMax = 5;
  if (PUB) {
    const { data: cfg, error: cfgErr } = await sb.rpc("public_config"); pubMax = cfg?.max || 5;
    if (cfgErr) { console.error(cfgErr); $("current").innerHTML = '<div class="photo-empty-state"><h2>This page couldn\'t load</h2><p>Please refresh and try again in a moment.</p></div>'; $("past").parentElement.hidden = true; return; }
    if (!cfg?.enabled) { $("current").innerHTML = '<div class="photo-empty-state"><h2>This page isn\'t open right now</h2><p>Please check back later, or ask Student Leadership.</p></div>'; $("past").parentElement.hidden = true; return; }
  }
  if (!session && !PUB) {
    $("current").innerHTML = '<div class="gate"><p>Sign in with your <strong>@latterup.org</strong> account to join the photo challenge.</p><button class="auth-btn" id="si">Sign in</button></div>';
    $("past").parentElement.hidden = true;
    return $("si").onclick = () => (location.href = "login.html?next=" + encodeURIComponent(location.pathname.split("/").pop() || "index.html"));
  }
  sb.rpc("is_admin").then(r => {  });
  const uid = session?.user?.id ?? null, now = new Date();
  const { data: themes = [] } = await sb.from("themes").select("*").order("starts_at", { ascending: false });
  const cur = themes.find(t => new Date(t.starts_at) <= now && now < new Date(t.ends_at));
  const past = themes.filter(t => new Date(t.ends_at) <= now);
  const max = PUB ? pubMax : ((await sb.from("settings").select("max_photos_per_theme").eq("id", 1).single()).data?.max_photos_per_theme || 5);
  const sign = async (bucket, paths) => { const m = {}; if (paths.length) (await sb.storage.from(bucket).createSignedUrls(paths, 3600)).data?.forEach(u => m[u.path] = u.signedUrl); return m; };
  const shrink = f => new Promise((ok, no) => { const i = new Image(); i.onload = () => { const s = Math.min(1, 1600 / Math.max(i.width, i.height)), c = document.createElement("canvas"); c.width = i.width * s; c.height = i.height * s; c.getContext("2d").drawImage(i, 0, 0, c.width, c.height); c.toBlob(ok, "image/jpeg", .85); }; i.onerror = no; i.src = URL.createObjectURL(f); });

  async function renderCurrent() {
    const box = $("current");
    if (!cur) return box.innerHTML = `<div class="photo-empty-state"><span class="photo-round-badge">Between rounds</span><h2>No active challenge just yet</h2><p>Check out past themes below, and come back soon for the next prompt.</p></div>`;
    const { data: mine = [] } = PUB ? { data: [] } : await sb.from("submissions").select("*").eq("theme_id", cur.id).eq("user_id", uid).order("created_at");
    const urls = await sign("photos", mine.map(m => m.image_path));
    const label = { approved: "Approved ✓", rejected: "Not approved", pending: "Waiting for review" };
    box.innerHTML = `<div class="photo-round-card"><div class="photo-round-copy"><span class="photo-round-badge"><span class="photo-live-dot"></span> Current round</span><h2>${esc(cur.title)}</h2><p class="photo-round-description">${esc(cur.description || "Share a photo that fits this round's theme.")}</p><div class="photo-deadline"><span aria-hidden="true">${LUIcon("clock", 18)}</span><span><strong>Submit by</strong><br>${new Date(cur.ends_at).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}</span></div><p class="photo-privacy-note">Approved photos will be shared with everyone when the round ends. Your name will appear with your photos.</p></div><div class="photo-upload-panel"><div class="photo-upload-icon" aria-hidden="true">↑</div><h3>Bring your moment to life</h3><p>Choose photos from your device. JPG and PNG work great.</p>${PUB ? '<input id="pname" class="pub-name" maxlength="60" placeholder="Your name (shown with your photos)" autocomplete="name">' : ""}${mine.length < max ? `<label class="photo-upload-button" for="f">Choose photos <span aria-hidden="true">↗</span></label><input class="photo-file-input" type="file" id="f" accept="image/*" multiple><small>${PUB ? `Up to ${max} photos per person` : `${max - mine.length} of ${max} uploads remaining`}</small>` : `<p class="photo-limit-reached">You've reached the ${max}-photo limit for this round.</p>`}<p id="msg" class="photo-upload-message" role="status"></p></div></div>
      ${mine.length ? `<div class="photo-submissions"><div class="photo-section-heading"><div><h3>Your submissions</h3><p>Manage the photos you've sent for this round.</p></div><span class="photo-count">${mine.length} / ${max}</span></div><div class="thumbs">${mine.map(m => `<figure><img src="${urls[m.image_path]}" alt="Your submitted photo"><figcaption><span>${label[m.status]}</span><button class="auth-btn alt" data-del="${m.id}" data-p="${esc(m.image_path)}">Remove</button></figcaption></figure>`).join("")}</div></div>` : ""}`;
    box.querySelectorAll("[data-del]").forEach(b => b.onclick = async () => {
      if (!confirm("Remove this photo?")) return;
      await sb.from("submissions").delete().eq("id", b.dataset.del); await sb.storage.from("photos").remove([b.dataset.p]); renderCurrent();
    });
    const f = $("f"); if (f) f.onchange = async () => {
      const files = [...f.files].slice(0, max - mine.length), msg = $("msg"); let n = 0;
      const nm = PUB ? ($("pname")?.value || "").trim() : "-"; if (!nm) { msg.textContent = "Please type your name first."; f.value = ""; return; }
      for (const file of files) {
        msg.textContent = `Uploading ${++n} of ${files.length}…`;
        try {
          const blob = await shrink(file), path = `${PUB ? "public" : uid}/${crypto.randomUUID()}.jpg`;
          const up = await sb.storage.from("photos").upload(path, blob, { contentType: "image/jpeg" }); if (up.error) throw up.error;
          const ins = await sb.from("submissions").insert({ theme_id: cur.id, user_id: uid, submitted_by: nm, image_path: path }); if (ins.error) throw ins.error;
        } catch (e) { msg.textContent = "Couldn't upload " + file.name + ": " + (e.message || "unsupported photo, try JPG or PNG."); return; }
      }
      await renderCurrent(); if (PUB && $("msg")) $("msg").textContent = "Thank you! Your photo is waiting for review ✓";
    };
  }

  const counts = {}; if (past.length) { const { data: cs = [] } = await sb.from("submissions").select("theme_id").eq("status", "approved").in("theme_id", past.map(t => t.id)); cs.forEach(c => counts[c.theme_id] = (counts[c.theme_id] || 0) + 1); }
  $("past").innerHTML = past.length ? past.map(t => `<button class="theme-card photo-theme-card" data-t="${t.id}"><span class="photo-theme-art" aria-hidden="true">${LUIcon("camera", 22)}</span><strong>${esc(t.title)}</strong><small>${new Date(t.starts_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })} · ${counts[t.id] || 0} photo${(counts[t.id] || 0) === 1 ? "" : "s"}</small><span class="photo-theme-link">View gallery <span aria-hidden="true">↗</span></span></button>`).join("") : `<div class="photo-empty-past"><span aria-hidden="true">${LUIcon("camera", 22)}</span><p>Your gallery is getting ready. Past themes and approved photos will appear here after a round wraps up.</p></div>`;
  $("past").querySelectorAll("[data-t]").forEach(b => b.onclick = () => openTheme(themes.find(t => t.id === b.dataset.t)));

  async function openTheme(t) {
    const v = $("viewer");
    const { data: ph = [] } = await sb.from("submissions").select("*").eq("theme_id", t.id).eq("status", "approved").order("created_at");
    const urls = await sign("photos", ph.map(p => p.image_path));
    const vid = t.video_path ? (await sign("media", [t.video_path]))[t.video_path] : null;
    let i = 0, timer = null;
    v.hidden = false; v.scrollIntoView({ behavior: "smooth" });
    v.innerHTML = `<div class="vh"><h3>${esc(t.title)}</h3><button class="auth-btn alt" id="vc">Close</button></div>${vid ? `<video controls src="${vid}"></video>` : ""}
      ${ph.length ? `<div class="car"><button id="pv" aria-label="Previous">‹</button><figure><img id="im" alt=""><figcaption id="cp"></figcaption></figure><button id="nx" aria-label="Next">›</button></div>
      <div class="vh"><button class="auth-btn" id="pl">Play reel</button><button class="auth-btn alt" id="fs">Full screen</button><button class="auth-btn alt" id="mu">Music: on</button></div><h4 class="all-title">All ${ph.length} photo${ph.length === 1 ? "" : "s"} from this theme</h4><div class="thumbs theme-all">${ph.map((x, k) => `<figure><button type="button" class="thumb-btn" data-k="${k}" aria-label="View photo by ${esc(x.submitted_by)}"><img src="${urls[x.image_path]}" alt=""></button><figcaption>${esc(x.submitted_by)}</figcaption></figure>`).join("")}</div>` : "<p>No approved photos for this theme.</p>"}`;
    const stop = () => { clearInterval(timer); timer = null; LUMusic.stop(); if ($("pl")) $("pl").textContent = "Play reel"; };
    $("vc").onclick = () => { stop(); document.fullscreenElement && document.exitFullscreen(); v.hidden = true; };
    if (!ph.length) return;
    const go = d => { i = (i + d + ph.length) % ph.length; $("im").src = urls[ph[i].image_path]; $("cp").textContent = `${ph[i].submitted_by} · ${i + 1}/${ph.length}`; };
    go(0);
    $("mu").onclick = () => { LUMusic.enabled = !LUMusic.enabled; $("mu").textContent = "Music: " + (LUMusic.enabled ? "on" : "off"); if (timer) LUMusic.enabled ? LUMusic.start() : LUMusic.stop(); };
    v.querySelectorAll("[data-k]").forEach(b => b.onclick = () => { stop(); i = +b.dataset.k; go(0); v.querySelector(".car").scrollIntoView({ behavior: "smooth", block: "center" }); });
    $("pv").onclick = () => { stop(); go(-1); }; $("nx").onclick = () => { stop(); go(1); };
    $("pl").onclick = () => { if (timer) return stop(); LUMusic.start(); timer = setInterval(() => go(1), LUMusic.interval); $("pl").textContent = "Pause reel"; };
    $("fs").onclick = () => v.requestFullscreen?.();
    v.onkeydown = e => { if (e.key === "ArrowRight") $("nx").click(); if (e.key === "ArrowLeft") $("pv").click(); }; v.tabIndex = 0; v.focus();
  }
  renderCurrent();
})();
