(function () {
  "use strict";

  const root = document.documentElement;
  const storedTheme = localStorage.getItem("flyology-theme");
  const preferredTheme = window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";

  const adaKeywords = new Set(
    "abort abs abstract accept access aliased all and array at begin body case constant declare delay delta digits do else elsif end entry exception exit for function generic goto if in interface is limited loop mod new not null of or others out overriding package parallel pragma private procedure protected raise range record rem renames requeue return reverse select separate some subtype synchronized tagged task terminate then type until use when while with xor"
      .split(" ")
  );
  const adaTokenPattern = /--[^\n]*|"(?:[^"]|"")*"|\b[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\b|\b[A-Za-z][A-Za-z0-9_]*\b|\b\d[\d_]*(?:\.\d[\d_]*)?\b|=>|:=|\.\./g;

  function escapeHtml(value) {
    return value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  }

  function adaTokenClass(token) {
    if (token.startsWith("--")) return "token-comment";
    if (token.startsWith('"')) return "token-string";
    if (/^\d/.test(token)) return "token-number";
    if (token.includes(".")) return token === ".." ? "token-operator" : "token-type";
    if (adaKeywords.has(token.toLowerCase())) return "token-keyword";
    if (/^(true|false)$/i.test(token)) return "token-number";
    if (/^[A-Za-z]/.test(token)) return "";
    return "token-operator";
  }

  function highlightAda(code) {
    const source = code.textContent;
    let highlighted = "";
    let previousIndex = 0;

    source.replace(adaTokenPattern, function (token, offset) {
      const tokenClass = adaTokenClass(token);
      highlighted += escapeHtml(source.slice(previousIndex, offset));
      highlighted += tokenClass
        ? '<span class="' + tokenClass + '">' + escapeHtml(token) + "</span>"
        : escapeHtml(token);
      previousIndex = offset + token.length;
      return token;
    });

    highlighted += escapeHtml(source.slice(previousIndex));
    code.innerHTML = highlighted;
  }

  root.dataset.theme = storedTheme || preferredTheme;

  document.addEventListener("DOMContentLoaded", function () {
    const themeButton = document.querySelector("[data-theme-toggle]");
    const themeLabel = document.querySelector("[data-theme-label]");
    const menuButton = document.querySelector("[data-menu-toggle]");
    const navLinks = document.querySelector("[data-nav-links]");

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
        }
      });
    }

    document.querySelectorAll("code.language-ada").forEach(highlightAda);

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
