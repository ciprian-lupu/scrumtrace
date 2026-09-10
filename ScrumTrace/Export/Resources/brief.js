(() => {
  const box = document.createElement("div");
  box.className = "lightbox";
  box.setAttribute("role", "dialog");
  box.setAttribute("aria-modal", "true");
  box.setAttribute("aria-label", "Screenshot");
  box.setAttribute("tabindex", "-1");
  box.innerHTML = "<img alt=''>";
  document.body.appendChild(box);
  const img = box.querySelector("img");
  let lastOpener = null;
  const isPackMediaHref = (href) => {
    if (!href || href.includes("\\") || href.includes(":") || href.includes("\n") || href.includes("\r") || href.includes("\0")) return false;
    if (href.startsWith("/") || href.startsWith("#")) return false;
    let decoded = href;
    try {
      decoded = decodeURIComponent(href);
    } catch (e) {
      return false;
    }
    if (decoded.includes("\\") || decoded.includes(":") || decoded.includes("\n") || decoded.includes("\r") || decoded.includes("\0")) return false;
    const parts = decoded.split("/").filter((part) => part.length > 0);
    if (parts.length < 2) return false;
    if (parts.some((part) => part === "." || part === "..")) return false;
    return parts[0] === "shots" || parts[0] === "media";
  };
  const isOpen = () => box.classList.contains("open");
  const close = () => {
    if (!isOpen()) return;
    box.classList.remove("open");
    img.removeAttribute("src");
    img.alt = "";
    box.setAttribute("aria-label", "Screenshot");
    const opener = lastOpener;
    lastOpener = null;
    if (opener && typeof opener.focus === "function") {
      opener.focus();
    }
  };
  box.addEventListener("click", (event) => {
    if (event.target === box) close();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && isOpen()) {
      event.preventDefault();
      close();
    }
  });
  document.querySelectorAll("[data-lightbox]").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const href = link.getAttribute("href");
      if (!isPackMediaHref(href)) return;
      img.src = href;
      const thumb = link.querySelector("img");
      img.alt =
        link.getAttribute("aria-label") ||
        (thumb && thumb.getAttribute("alt")) ||
        (link.textContent || "").trim() ||
        "Screenshot";
      box.setAttribute("aria-label", img.alt);
      lastOpener = link;
      box.classList.add("open");
      box.focus();
    });
  });
})();
