(() => {
  const box = document.createElement("div");
  box.className = "lightbox";
  box.setAttribute("role", "dialog");
  box.setAttribute("aria-modal", "true");
  box.setAttribute("aria-label", "Screenshot");
  box.innerHTML = "<img alt=''>";
  document.body.appendChild(box);
  const img = box.querySelector("img");
  const close = () => {
    box.classList.remove("open");
    img.removeAttribute("src");
    img.alt = "";
  };
  box.addEventListener("click", close);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") close();
  });
  document.querySelectorAll("[data-lightbox]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const href = link.getAttribute("href");
      if (!href) return;
      img.src = href;
      const thumb = link.querySelector("img");
      img.alt =
        link.getAttribute("aria-label") ||
        (thumb && thumb.getAttribute("alt")) ||
        (link.textContent || "").trim() ||
        "Screenshot";
      box.classList.add("open");
    });
  });
})();
