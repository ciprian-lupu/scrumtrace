(() => {
  const box = document.createElement("div");
  box.className = "lightbox";
  box.setAttribute("role", "dialog");
  box.setAttribute("aria-modal", "true");
  box.setAttribute("aria-label", "Screenshot");
  box.setAttribute("tabindex", "-1");
  box.setAttribute("aria-describedby", "screenshot-help");
  box.innerHTML = "<button type='button' class='lightbox-close'>Close screenshot ×</button><img alt=''><p id='screenshot-help' class='sr-only'>Escape closes the screenshot. In Full size mode, use arrow keys to pan.</p>";
  document.body.appendChild(box);
  const img = box.querySelector("img");
  const closeButton = box.querySelector("button");
  let lastOpener = null;
  let background = [];
  let previousOverflow = "";
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
    background.forEach(([element, wasInert]) => { element.inert = wasInert; });
    background = [];
    document.body.style.overflow = previousOverflow;
    img.removeAttribute("src");
    img.alt = "";
    box.setAttribute("aria-label", "Screenshot");
    const opener = lastOpener;
    lastOpener = null;
    if (opener && typeof opener.focus === "function") {
      opener.focus();
    }
  };
  closeButton.addEventListener("click", close);
  box.addEventListener("click", (event) => {
    if (event.target === box) close();
  });
  document.addEventListener("keydown", (event) => {
    const pan = {ArrowLeft: [-80, 0], ArrowRight: [80, 0], ArrowUp: [0, -80], ArrowDown: [0, 80]}[event.key];
    if (pan && isOpen() && document.body.classList.contains("stills-full")) {
      event.preventDefault();
      box.scrollBy({left: pan[0], top: pan[1], behavior: "auto"});
    }
    if (event.key === "Tab" && isOpen()) {
      event.preventDefault();
      closeButton.focus();
    }
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
      background = Array.from(document.body.children).filter(element => element !== box && element.tagName !== "SCRIPT").map(element => [element, element.inert]);
      background.forEach(([element]) => { element.inert = true; });
      previousOverflow = document.body.style.overflow;
      document.body.style.overflow = "hidden";
      box.classList.add("open");
      box.focus();
      closeButton.focus();
    });
  });
})();
(() => {
  const label = document.createElement("label");
  label.className = "still-size";
  const input = document.createElement("input");
  input.type = "checkbox";
  input.setAttribute("role", "switch");
  input.setAttribute("aria-label", "Show screenshots at full size");
  label.appendChild(input);
  label.appendChild(document.createTextNode(" Full size"));
  const tools = document.querySelector(".image-tools");
  if (!tools || !document.querySelector("[data-lightbox]")) return;
  tools.appendChild(label);
  const apply = () => {
    document.body.classList.toggle("stills-full", input.checked);
  };
  input.addEventListener("change", apply);
  apply();
})();

// Keep printouts complete without changing the reader's disclosure choices.
(() => {
  let closed = [];
  window.addEventListener("beforeprint", () => {
    if (closed.length) return;
    closed = Array.from(document.querySelectorAll("details:not([open])"));
    closed.forEach(detail => { detail.open = true; });
  });
  window.addEventListener("afterprint", () => {
    closed.forEach(detail => { detail.open = false; });
    closed = [];
  });
  const links = Array.from(document.querySelectorAll(".section-nav a"));
  const update = () => {
    let current = links[0];
    links.forEach(link => {
      const target = document.querySelector(link.getAttribute("href"));
      if (target && target.getBoundingClientRect().top < 140) current = link;
    });
    links.forEach(link => {
      if (link === current) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
  };
  let pending = false;
  window.addEventListener("scroll", () => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => { update(); pending = false; });
  }, {passive: true});
  update();
})();

(() => {
  const nav = document.querySelector(".section-nav");
  const wrap = document.querySelector(".nav-wrap");
  if (!nav || !wrap) return;
  const update = () => wrap.classList.toggle("has-more", nav.scrollWidth - nav.clientWidth - nav.scrollLeft > 4);
  nav.addEventListener("scroll", update, {passive: true});
  window.addEventListener("resize", update);
  update();
})();
