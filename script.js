/* ==========================================================================
   Latter UP, Site Script
   Renders FAQ, Announcements, and Videos from their data files, wherever
   the matching container element exists on the current page. Also sets
   the footer's copyright year.

   No need to edit this file to change content, edit faq-data.js,
   announcements-data.js, or videos-data.js instead.
   ========================================================================== */

(function () {

  // ---------- Helpers ----------

  function formatDate(isoDateStr) {
    if (!isoDateStr) return "";
    // Parse as local date (avoid UTC off-by-one) by splitting manually.
    const parts = isoDateStr.split("-");
    if (parts.length !== 3) return isoDateStr;
    const [year, month, day] = parts.map(Number);
    const d = new Date(year, month - 1, day);
    if (isNaN(d.getTime())) return isoDateStr;
    return d.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
  }

  function sortByDateDesc(items) {
    return [...items].sort((a, b) => (b.date || "").localeCompare(a.date || ""));
  }

  function showLoadError(container, missingGlobalName, fileName) {
    container.innerHTML =
      '<p style="color:#b23; font-weight:600;">Content failed to load. ' +
      'Check that ' + fileName + ' is uploaded and that its &lt;script&gt; tag ' +
      'appears before script.js in this page\'s HTML.</p>';
    console.error("Latter UP: window." + missingGlobalName + " not found. Is " + fileName + " loaded?");
  }

  // ---------- Build one announcement <details> element ----------

  function buildAnnouncementEl(item, index) {
    const details = document.createElement("details");
    details.className = "announcement-item";

    const answerId = `announcement-answer-${index}`;
    let bodyHtml = `<p>${item.text}</p>`;

    if (item.pdfSrc) {
      const safePdfSrc = encodeURI(item.pdfSrc);
      const isImg = /\.(png|jpe?g|gif|webp|avif)(\?|$)/i.test(item.pdfSrc);
      bodyHtml += `
        <div class="pdf-embed">
          ${isImg ? `<a href="${safePdfSrc}" target="_blank" rel="noopener"><img class="flyer-img" src="${safePdfSrc}" alt="Announcement flyer" loading="lazy"></a>` : `<embed src="${safePdfSrc}" type="application/pdf" class="pdf-frame">`}
          <p class="pdf-fallback">
            <a href="${safePdfSrc}" target="_blank" rel="noopener">Open this flyer ${isImg ? "image" : "(PDF)"} →</a>
          </p>
        </div>
      `;
    }

    details.innerHTML = `
      <summary class="announcement-question" aria-controls="${answerId}">
        <span class="announcement-title-row">
          <span class="announcement-title-text">${item.title}</span>
          <span class="announcement-date">${formatDate(item.date)}</span>
        </span>
      </summary>
      <div class="announcement-answer" id="${answerId}">
        ${bodyHtml}
      </div>
    `;

    return details;
  }

  // ---------- Build one video card element ----------

  function buildVideoEl(item) {
    const card = document.createElement("div");
    card.className = "video-card";

    let mediaHtml;
    if (item.youtubeId) {
      mediaHtml = `
        <div class="video-frame-wrap">
          <iframe
            src="https://www.youtube.com/embed/${item.youtubeId}"
            title="${item.title}"
            frameborder="0"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
            allowfullscreen
            loading="lazy">
          </iframe>
        </div>
      `;
    } else if (item.videoSrc) {
      // Encode spaces/special characters in the path so filenames with
      // spaces (e.g. "December 2025 SL Video.mp4") still load correctly.
      const safeSrc = encodeURI(item.videoSrc);
      mediaHtml = `
        <div class="video-frame-wrap">
          <video controls preload="metadata" src="${safeSrc}"></video>
        </div>
      `;
    } else {
      mediaHtml = "";
    }

    card.innerHTML = `
      ${mediaHtml}
      <div class="video-card-body">
        <span class="video-date">${formatDate(item.date)}</span>
        <h3 class="video-title">${item.title}</h3>
        ${item.description ? `<p class="video-desc">${item.description}</p>` : ""}
      </div>
    `;

    return card;
  }

  // ---------- FAQ (index.html only) ----------

  const faqList = document.getElementById("faq-list");
  if (faqList) {
    if (!Array.isArray(window.FAQ_ITEMS)) {
      showLoadError(faqList, "FAQ_ITEMS", "faq-data.js");
    } else {
      window.FAQ_ITEMS.forEach((item, index) => {
        const details = document.createElement("details");
        details.className = "faq-item";
        const answerId = `faq-answer-${index}`;
        details.innerHTML = `
          <summary class="faq-question" aria-controls="${answerId}">${item.question}</summary>
          <div class="faq-answer" id="${answerId}">
            <p>${item.answer}</p>
          </div>
        `;
        faqList.appendChild(details);
      });
    }
  }

  // ---------- Announcements: preview on index.html (2 most recent) ----------

  const announcementsPreview = document.getElementById("announcements-preview-list");
  if (announcementsPreview) {
    if (!Array.isArray(window.ANNOUNCEMENT_ITEMS)) {
      showLoadError(announcementsPreview, "ANNOUNCEMENT_ITEMS", "announcements-data.js");
    } else {
      const sorted = sortByDateDesc(window.ANNOUNCEMENT_ITEMS).slice(0, 2);
      sorted.forEach((item, index) => {
        announcementsPreview.appendChild(buildAnnouncementEl(item, index));
      });
    }
  }

  // ---------- Announcements: full feed on announcements.html ----------

  const announcementsFull = document.getElementById("announcements-full-list");
  if (announcementsFull) {
    if (!Array.isArray(window.ANNOUNCEMENT_ITEMS)) {
      showLoadError(announcementsFull, "ANNOUNCEMENT_ITEMS", "announcements-data.js");
    } else {
      const sorted = sortByDateDesc(window.ANNOUNCEMENT_ITEMS);
      sorted.forEach((item, index) => {
        announcementsFull.appendChild(buildAnnouncementEl(item, index));
      });
    }
  }

  // ---------- Videos: preview on index.html (2 most recent) ----------

  const videosPreview = document.getElementById("videos-preview-list");
  if (videosPreview) {
    if (!Array.isArray(window.VIDEO_ITEMS)) {
      showLoadError(videosPreview, "VIDEO_ITEMS", "videos-data.js");
    } else {
      const sorted = sortByDateDesc(window.VIDEO_ITEMS).slice(0, 2);
      sorted.forEach((item) => {
        videosPreview.appendChild(buildVideoEl(item));
      });
    }
  }

  // ---------- Videos: full archive on videos.html ----------

  const videosFull = document.getElementById("videos-full-list");
  if (videosFull) {
    if (!Array.isArray(window.VIDEO_ITEMS)) {
      showLoadError(videosFull, "VIDEO_ITEMS", "videos-data.js");
    } else {
      const sorted = sortByDateDesc(window.VIDEO_ITEMS);
      sorted.forEach((item) => {
        videosFull.appendChild(buildVideoEl(item));
      });
    }
  }

  // ---------- Footer year (every page) ----------

  const yearEl = document.getElementById("year");
  if (yearEl) {
    yearEl.textContent = new Date().getFullYear();
  }

})();
