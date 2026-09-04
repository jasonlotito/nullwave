const mobileNavigation = document.querySelector(".mobile-nav");

if (mobileNavigation) {
  const summary = mobileNavigation.querySelector("summary");

  mobileNavigation.addEventListener("toggle", () => {
    summary.setAttribute(
      "aria-label",
      mobileNavigation.open ? "Close navigation menu" : "Open navigation menu"
    );
  });

  mobileNavigation.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => mobileNavigation.removeAttribute("open"));
  });
}
