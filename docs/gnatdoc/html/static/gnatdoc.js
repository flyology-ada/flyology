(function () {
  "use strict";

  const root = document.documentElement;
  const stored = localStorage.getItem("flyology-theme");
  root.dataset.theme = stored || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");

  document.addEventListener("DOMContentLoaded", function () {
    window.FlyologyAda.highlightAll(".api-content pre code, .ada-code-snippet code");

    const themeButton = document.querySelector("[data-theme-toggle]");
    if (themeButton) {
      themeButton.addEventListener("click", function () {
        root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
        localStorage.setItem("flyology-theme", root.dataset.theme);
      });
    }

    const search = document.querySelector("[data-api-search]");
    if (search) {
      const items = Array.from(document.querySelectorAll("[data-filter-item]"));
      search.addEventListener("input", function () {
        const query = search.value.trim().toLocaleLowerCase();
        items.forEach(function (item) {
          item.hidden = query.length > 0 && !item.textContent.toLocaleLowerCase().includes(query);
        });
      });
    }
  });
})();
