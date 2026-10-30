(() => {
  const VERSION = "0.32";
  document.querySelectorAll("[data-site-version]").forEach(element => {
    element.textContent = `Version ${VERSION}`;
  });
})();
