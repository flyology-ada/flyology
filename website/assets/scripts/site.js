(function () {
  "use strict";

  const root = document.documentElement;
  const storedTheme = localStorage.getItem("flyology-theme");
  const preferredTheme = window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";

  root.dataset.theme = storedTheme || preferredTheme;

  document.addEventListener("DOMContentLoaded", function () {
    const themeButton = document.querySelector("[data-theme-toggle]");
    const themeLabel = document.querySelector("[data-theme-label]");
    const menuButton = document.querySelector("[data-menu-toggle]");
    const navLinks = document.querySelector("[data-nav-links]");
    const navDropdowns = Array.from(document.querySelectorAll("[data-nav-dropdown]"));

    function updateThemeLabel() {
      if (!themeLabel) return;
      const next = root.dataset.theme === "dark" ? "light" : "dark";
      themeLabel.textContent = "Use " + next + " theme";
    }

    if (themeButton) {
      updateThemeLabel();
      themeButton.addEventListener("click", function () {
        root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
        localStorage.setItem("flyology-theme", root.dataset.theme);
        updateThemeLabel();
      });
    }

    if (menuButton && navLinks) {
      menuButton.addEventListener("click", function () {
        const isOpen = navLinks.dataset.open === "true";
        navLinks.dataset.open = String(!isOpen);
        menuButton.setAttribute("aria-expanded", String(!isOpen));
      });

      navLinks.addEventListener("click", function (event) {
        if (event.target.closest("a")) {
          navLinks.dataset.open = "false";
          menuButton.setAttribute("aria-expanded", "false");
          navDropdowns.forEach(function (dropdown) {
            dropdown.open = false;
          });
        }
      });
    }

    navDropdowns.forEach(function (dropdown) {
      dropdown.addEventListener("toggle", function () {
        if (!dropdown.open) return;
        navDropdowns.forEach(function (otherDropdown) {
          if (otherDropdown !== dropdown) otherDropdown.open = false;
        });
      });
    });

    document.addEventListener("click", function (event) {
      navDropdowns.forEach(function (dropdown) {
        if (dropdown.open && !dropdown.contains(event.target)) dropdown.open = false;
      });
    });

    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape") return;
      navDropdowns.forEach(function (dropdown) {
        if (!dropdown.open) return;
        dropdown.open = false;
        dropdown.querySelector("summary").focus();
      });
    });

    document.querySelectorAll("[data-code-preview]").forEach(function (preview) {
      const sampleButtons = Array.from(
        preview.querySelectorAll("[data-preview-sample]")
      );
      const samplePanels = Array.from(
        preview.querySelectorAll("[data-preview-code]")
      );
      const sampleFilename = preview.querySelector("[data-preview-filename]");

      if (!sampleButtons.length || !samplePanels.length || !sampleFilename) return;

      let selectedSample =
        sampleButtons.find(function (button) {
          return button.getAttribute("aria-pressed") === "true";
        })?.dataset.previewSample || sampleButtons[0].dataset.previewSample;

      function previewSample(name) {
        samplePanels.forEach(function (panel) {
          panel.hidden = panel.dataset.previewCode !== name;
        });

        const button = sampleButtons.find(function (item) {
          return item.dataset.previewSample === name;
        });
        if (button) sampleFilename.textContent = button.dataset.previewFile;
      }

      function selectSample(name) {
        selectedSample = name;
        sampleButtons.forEach(function (button) {
          button.setAttribute(
            "aria-pressed",
            String(button.dataset.previewSample === name)
          );
        });
        previewSample(name);
      }

      sampleButtons.forEach(function (button) {
        const name = button.dataset.previewSample;

        button.addEventListener("mouseenter", function () {
          previewSample(name);
        });
        button.addEventListener("mouseleave", function () {
          previewSample(selectedSample);
        });
        button.addEventListener("focus", function () {
          previewSample(name);
        });
        button.addEventListener("blur", function () {
          previewSample(selectedSample);
        });
        button.addEventListener("click", function () {
          selectSample(name);
        });
      });

      selectSample(selectedSample);
    });

    window.FlyologyAda.highlightAll("code.language-ada");
    window.FlyologyAda.highlightAllSQL("code.language-sql");

    document.querySelectorAll("[data-copy]").forEach(function (button) {
      button.addEventListener("click", async function () {
        const code = button.closest("figure").querySelector("code");
        const previous = button.textContent;

        try {
          await navigator.clipboard.writeText(code.textContent.trim());
          button.textContent = "Copied";
        } catch (_error) {
          button.textContent = "Select text";
        }

        window.setTimeout(function () {
          button.textContent = previous;
        }, 1600);
      });
    });

    document.querySelectorAll("[data-case-filter]").forEach(function (browser) {
      const search = browser.querySelector("[data-case-search]");
      const status = browser.querySelector("[data-case-status]");
      const count = browser.querySelector("[data-case-count]");
      const empty = browser.querySelector("[data-case-empty]");
      const cases = Array.from(browser.querySelectorAll("[data-case]"));

      if (!search || !status || !count || !empty || !cases.length) return;

      function applyCaseFilter() {
        const query = search.value.trim().toLowerCase();
        const selectedStatus = status.value;
        let visible = 0;

        cases.forEach(function (item) {
          const matchesQuery = !query || item.dataset.search.includes(query);
          const matchesStatus =
            selectedStatus === "all" || item.dataset.status === selectedStatus;
          item.hidden = !(matchesQuery && matchesStatus);
          if (!item.hidden) visible += 1;
        });

        count.textContent =
          visible === cases.length
            ? "Showing all " + cases.length + " cases"
            : "Showing " + visible + " of " + cases.length + " cases";
        empty.hidden = visible !== 0;
      }

      search.addEventListener("input", applyCaseFilter);
      status.addEventListener("change", applyCaseFilter);
      applyCaseFilter();
    });

    const tocLinks = Array.from(document.querySelectorAll(".toc a[href^='#']"));
    const sections = tocLinks
      .map(function (link) {
        return document.querySelector(link.getAttribute("href"));
      })
      .filter(Boolean);

    if (sections.length && "IntersectionObserver" in window) {
      const observer = new IntersectionObserver(
        function (entries) {
          const visible = entries
            .filter(function (entry) {
              return entry.isIntersecting;
            })
            .sort(function (a, b) {
              return a.boundingClientRect.top - b.boundingClientRect.top;
            })[0];

          if (!visible) return;
          tocLinks.forEach(function (link) {
            const active = link.getAttribute("href") === "#" + visible.target.id;
            if (active) link.setAttribute("aria-current", "true");
            else link.removeAttribute("aria-current");
          });
        },
        { rootMargin: "-20% 0px -65%", threshold: 0 }
      );

      sections.forEach(function (section) {
        observer.observe(section);
      });
    }
  });
})();
