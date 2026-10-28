(() => {
  const sb = window.LUsb || supabase.createClient(LU_CONFIG.url, LU_CONFIG.key);
  const app = document.getElementById("app");
  const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const showError = (host, message) => {
    host.innerHTML = `<p class="auth-error">${esc(message)}</p>`;
  };
  const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

  function cycleIndex(count, weekday) {
    if (!count) return 0;
    const now = new Date();
    const todayUtc = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
    const thisWeekday = new Date(todayUtc).getUTCDay();
    const daysSinceRotation = (thisWeekday - weekday + 7) % 7;
    const lastRotation = new Date(todayUtc - daysSinceRotation * 86400000);
    const firstSunday = Date.UTC(2024, 0, 7);
    const firstRotation = new Date(firstSunday + ((weekday + 7) % 7) * 86400000);
    if (lastRotation < firstRotation) return 0;
    return Math.floor((lastRotation.getTime() - firstRotation.getTime()) / (7 * 86400000)) % count;
  }

  function renderChart(host, members, weekday) {
    const rotating = members.filter(member => member.in_cycle);
    if (!rotating.length) {
      host.innerHTML = '<section class="leadership-card"><h2>Student Leadership</h2><p>The member rotation has not been set up yet.</p></section>';
      return;
    }
    let active = cycleIndex(rotating.length, weekday);
    const paint = () => {
      const member = rotating[active];
      host.innerHTML = `<section class="leadership-card">
        <p class="eyebrow">Student Leadership · Weekly spotlight</p>
        <h2>${esc(member.display_name)}</h2>
        <p class="leadership-member-email">${esc(member.email)}</p>
        <div class="leadership-role-list">${member.roles.length
          ? member.roles.map(role => `<span class="via-badge">${esc(role)}</span>`).join(" ")
          : "<span>Student Leadership member</span>"}</div>
        <div class="leadership-carousel-controls"><button class="auth-btn alt" type="button" data-prev aria-label="Previous member">Previous</button>
          <span>${active + 1} of ${rotating.length}</span>
          <button class="auth-btn alt" type="button" data-next aria-label="Next member">Next</button></div>
      </section>`;
      host.querySelector("[data-prev]").onclick = () => { active = (active + rotating.length - 1) % rotating.length; paint(); };
      host.querySelector("[data-next]").onclick = () => { active = (active + 1) % rotating.length; paint(); };
    };
    paint();
  }

  async function load() {
    const { data: { session }, error: sessionError } = await sb.auth.getSession();
    if (sessionError) return showError(app, "We couldn't check your sign-in. Please refresh and try again.");
    if (!session) {
      location.replace("login.html?next=leadership.html");
      return;
    }
    const { data: role, error: roleError } = await sb.rpc("my_role");
    if (roleError) return showError(app, "Student Leadership access couldn't be verified. Please try again later.");
    if (!["admin", "leader"].includes(role)) {
      app.innerHTML = '<section class="leadership-card"><h1>Student Leadership</h1><p>This page is only available to signed-in Student Leadership members and admins.</p><a class="auth-btn" href="index.html">Back to portal</a></section>';
      return;
    }

    const [settingsResult, membersResult, rolesResult, assignmentsResult] = await Promise.all([
      sb.from("leadership_hub_settings").select("rotation_weekday,approval_points").eq("id", 1).single(),
      sb.from("leadership_chart_members").select("email,display_name,in_cycle,sort_order").order("sort_order").order("display_name"),
      sb.from("leadership_chart_roles").select("id,name,sort_order").order("sort_order").order("name"),
      sb.from("leadership_member_roles").select("member_email,role_id"),
    ]);
    const failed = [settingsResult, membersResult, rolesResult, assignmentsResult].find(result => result.error);
    if (failed) return showError(app, `The Student Leadership hub could not load: ${failed.error.message}. Ask an admin to run update-10-student-leadership-hub.sql.`);
    const roleNames = new Map(rolesResult.data.map(item => [item.id, item.name]));
    const assignments = new Map();
    assignmentsResult.data.forEach(item => {
      if (!assignments.has(item.member_email)) assignments.set(item.member_email, []);
      const name = roleNames.get(item.role_id);
      if (name) assignments.get(item.member_email).push(name);
    });
    const members = membersResult.data.map(member => ({ ...member, roles: assignments.get(member.email) || [] }));

    app.innerHTML = `<section class="page-hero photo-style-hero leadership-hero"><p class="eyebrow">Latter UP · Student community</p>
      <h1 class="page-title">Student Leadership</h1><p>Meet the people serving our community and report your Google Chat conversations.</p></section>
      <div id="leadership-spotlight"></div>
      <section class="leadership-section" id="report-section"><h2>Report My Chats</h2>
        <p>Upload one screenshot of a Google Chat conversation and tell us who you chatted with. Reports are reviewed by an admin. Approved reports earn ${settingsResult.data.approval_points} points.</p>
        <form id="chat-report-form" class="leadership-form">
          <label>Person you chatted with<input name="chatted_with" maxlength="120" required></label>
          <label>Chat screenshot<input name="screenshot" type="file" accept="image/png,image/jpeg,image/webp" required><small>PNG, JPG, or WebP; maximum 10 MB. Screenshots are only visible to you and admins.</small></label>
          <button class="auth-btn" type="submit">Submit chat report</button><p id="chat-report-message" role="status"></p>
        </form></section>
      <section class="leadership-section" id="points-section"><h2>Points and prizes</h2><div id="points-summary">Loading your points…</div>
        <div id="leadership-prizes" class="leadership-prize-grid"></div>
        <h3>My prize claims</h3><div id="my-prize-claims"></div></section>`;
    renderChart(document.getElementById("leadership-spotlight"), members, settingsResult.data.rotation_weekday);
    await wireReports(session.user);
    await loadRewards(session.user.id);
  }

  async function wireReports(user) {
    const form = document.getElementById("chat-report-form");
    const message = document.getElementById("chat-report-message");
    form.onsubmit = async event => {
      event.preventDefault();
      const button = form.querySelector('button[type="submit"]');
      const file = form.elements.screenshot.files[0];
      const chattedWith = form.elements.chatted_with.value.trim();
      if (!chattedWith || !file) return;
      if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) || file.size > 10 * 1024 * 1024) {
        message.textContent = "Choose a PNG, JPG, or WebP screenshot no larger than 10 MB.";
        return;
      }
      button.disabled = true;
      message.textContent = "Uploading your report…";
      const extension = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
      const path = `${user.id}/${crypto.randomUUID()}.${extension}`;
      const upload = await sb.storage.from("leadership-reports").upload(path, file, { contentType: file.type, upsert: false });
      if (upload.error) {
        button.disabled = false;
        message.textContent = `Screenshot upload failed: ${upload.error.message}`;
        return;
      }
      const insert = await sb.from("leadership_chat_reports").insert({
        reporter_id: user.id,
        chatted_with: chattedWith,
        screenshot_path: path,
      });
      if (insert.error) {
        const cleanup = await sb.storage.from("leadership-reports").remove([path]);
        button.disabled = false;
        message.textContent = `Report could not be saved: ${insert.error.message}${cleanup.error ? ` Screenshot cleanup failed: ${cleanup.error.message}` : ""}`;
        return;
      }
      form.reset();
      button.disabled = false;
      message.textContent = "Report submitted for admin review. You can submit another report now.";
    };
  }

  async function loadRewards(userId) {
    const summary = document.getElementById("points-summary");
    const prizeHost = document.getElementById("leadership-prizes");
    const claimsHost = document.getElementById("my-prize-claims");
    const [reports, claims, prizes] = await Promise.all([
      sb.from("leadership_chat_reports").select("points_awarded").eq("reporter_id", userId).eq("status", "approved"),
      sb.from("leadership_prize_claims").select("id,prize_name,points_cost,status,created_at").eq("user_id", userId).order("created_at", { ascending: false }),
      sb.from("leadership_prizes").select("id,name,description,points_cost").eq("active", true).order("created_at"),
    ]);
    const failed = [reports, claims, prizes].find(result => result.error);
    if (failed) {
      summary.innerHTML = `<p class="auth-error">Points and prizes couldn't load: ${esc(failed.error.message)}</p>`;
      return;
    }
    const earned = reports.data.reduce((total, report) => total + report.points_awarded, 0);
    const reserved = claims.data.filter(claim => ["pending", "approved"].includes(claim.status)).reduce((total, claim) => total + claim.points_cost, 0);
    summary.innerHTML = `<p><strong>${earned - reserved}</strong> available points · ${earned} earned</p>`;
    prizeHost.innerHTML = prizes.data.map(prize => `<article class="leadership-prize-card">
      <h3>${esc(prize.name)}</h3><p>${esc(prize.description)}</p><p><strong>${prize.points_cost} points</strong></p>
      <button class="auth-btn" type="button" data-claim="${prize.id}" ${earned - reserved < prize.points_cost ? "disabled" : ""}>Request prize</button></article>`).join("")
      || "<p>No prizes are available right now.</p>";
    prizeHost.querySelectorAll("[data-claim]").forEach(button => button.onclick = async () => {
      button.disabled = true;
      const { error } = await sb.rpc("claim_leadership_prize", { p_prize_id: button.dataset.claim });
      if (error) {
        button.disabled = false;
        summary.insertAdjacentHTML("beforeend", `<p class="auth-error">${esc(error.message)}</p>`);
        return;
      }
      await loadRewards(userId);
    });
    claimsHost.innerHTML = claims.data.map(claim => `<div class="leadership-list-row"><span>${esc(claim.prize_name)} · ${claim.points_cost} points</span><span class="sched-badge">${esc(claim.status)}</span></div>`).join("")
      || "<p>You haven't requested a prize yet.</p>";
  }

  load().catch(error => {
    console.error("Student Leadership hub could not load:", error);
    showError(app, "The Student Leadership hub could not load. Please refresh and try again.");
  });
})();
