const views = {
  library: {
    label: "Class library",
    alt: "LCP class library with Data Structures, World Literature, and Ethics and Technology, plus recent course materials."
  },
  materials: {
    label: "Materials",
    alt: "Data Structures class with its Materials tab open, a course handout, and import and Google Drive folder controls."
  },
  sharing: {
    label: "Sharing",
    alt: "Review Context to Share dialog showing the selected Data Structures class, material scope, and optional time range."
  }
};

const links = [...document.querySelectorAll("[data-view]")];
const thumbnail = document.getElementById("preview-image");
const previewLink = document.getElementById("preview-link");
const expand = document.getElementById("expand");
const stage = document.getElementById("preview-stage");
const lightbox = document.getElementById("lightbox");
const fullSize = document.getElementById("large-preview");
let selection = links[0];

function selectView(link) {
  const view = views[link.dataset.view];
  selection.removeAttribute("aria-current");
  selection = link;
  selection.setAttribute("aria-current", "true");
  thumbnail.src = link.href;
  thumbnail.alt = view.alt;
  previewLink.href = link.href;
  previewLink.setAttribute("aria-label", "Enlarge the " + view.label.toLowerCase() + " preview");
  expand.href = link.href;
  stage.classList.toggle("sheet", link.dataset.view === "sharing");
  document.getElementById("counter").textContent = (links.indexOf(link) + 1) + " / " + links.length;
}

function normalClick(event) {
  return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
}

for (const link of links) {
  link.addEventListener("click", (event) => {
    if (!normalClick(event)) return;
    event.preventDefault();
    selectView(link);
  });
}

for (const link of [previewLink, expand]) {
  link.addEventListener("click", (event) => {
    if (!normalClick(event) || typeof lightbox.showModal !== "function") return;
    event.preventDefault();
    const view = views[selection.dataset.view];
    document.getElementById("lightbox-title").textContent = view.label;
    fullSize.src = selection.href;
    fullSize.alt = view.alt;
    lightbox.showModal();
  });
}

lightbox.addEventListener("click", (event) => {
  if (event.target !== lightbox) return;
  const bounds = lightbox.getBoundingClientRect();
  if (event.clientX < bounds.left || event.clientX > bounds.right ||
      event.clientY < bounds.top || event.clientY > bounds.bottom) lightbox.close();
});
