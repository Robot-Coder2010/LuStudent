(() => {
  const localHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);
  window.LU_LOCAL_HOST = location.protocol === "http:" && localHosts.has(location.hostname);
  try {
    window.LU_LOCAL_PREVIEW = window.LU_LOCAL_HOST && localStorage.getItem("lu-local-preview") === "enabled";
  } catch (error) {
    console.warn("Local preview preference is unavailable.", error);
    window.LU_LOCAL_PREVIEW = false;
  }
  if (!window.LU_LOCAL_PREVIEW) return;

  const photos = [
    { src: "PLACEHOLDER/images/community-landscape-1.jpg", by: "Student volunteer" },
    { src: "PLACEHOLDER/images/community-landscape-2.jpg", by: "Family community" },
    { src: "PLACEHOLDER/images/community-landscape-3.jpg", by: "Student volunteer" },
    { src: "PLACEHOLDER/images/community-landscape-4.jpg", by: "Family community" },
  ];

  window.LU_PREVIEW_DATA = {
    faq: [
      { question: "How do I join my class's Google Meet?", answer: "Open Google Classroom and use the Meet link shared by your teacher." },
      { question: "Where do I find my assignments?", answer: "Your current assignments are posted in Google Classroom." },
      { question: "Who do I contact for technical issues?", answer: "Reach out to Student Leadership at studentleadership@latterup.org." },
    ],
    announcements: [
      { title: "October community update", date: "2026-10-26", text: "A quick roundup of upcoming co-op dates, student activities, and reminders for families.", pdfSrc: "" },
      { title: "Jackbox Games — October 28", date: "2026-10-24", text: "Join Student Leadership for a relaxed afternoon of games and community. Bring your favorite game name ideas!", pdfSrc: "" },
      { title: "November calendar and family reminders", date: "2026-10-20", text: "Take a look at this month's important dates and add the events that matter to your family.", pdfSrc: "" },
    ],
    videos: [
      { title: "A look back at our community week", date: "2026-10-23", description: "A sample video card showing how a featured Student Leadership video appears.", previewImage: photos[1].src },
      { title: "Student Leadership: October update", date: "2026-10-16", description: "A short monthly update with highlights, reminders, and what's coming up next.", previewImage: photos[2].src },
      { title: "Welcome to Latter UP", date: "2026-10-02", description: "A sample archive entry for the video library.", previewImage: photos[3].src },
    ],
    currentTheme: {
      id: "preview-current",
      title: "Little moments, big memories",
      description: "Share a favorite snapshot from a regular day at Latter UP.",
      endsAt: "2026-11-15T23:59:00",
    },
    pastThemes: [
      { id: "preview-past-1", title: "A view from here", startsAt: "2026-09-01", photos: [photos[0], photos[1], photos[2]] },
      { id: "preview-past-2", title: "Color in the everyday", startsAt: "2026-08-01", photos: [photos[1], photos[2], photos[3]] },
      { id: "preview-past-3", title: "Outside together", startsAt: "2026-07-01", photos: [photos[0], photos[2], photos[3]] },
    ],
  };

  const note = document.createElement("aside");
  note.className = "local-preview-notice";
  note.setAttribute("role", "status");
  note.textContent = "Local design preview · sample content · sign-in and uploads are disabled";
  document.body.prepend(note);
})();
