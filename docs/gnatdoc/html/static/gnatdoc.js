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
    const searchIndex = window.FlyologyApiSearch || [];
    if (search && searchIndex.length > 0) initializeSearch(search, searchIndex);
  });

  function normalized(value) {
    return value.toLocaleLowerCase().replace(/[._-]+/g, " ").replace(/\s+/g, " ").trim();
  }

  function editDistance(left, right, limit) {
    if (Math.abs(left.length - right.length) > limit) return limit + 1;

    let beforePrevious = null;
    let previous = Array.from({ length: right.length + 1 }, function (_, index) { return index; });

    for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
      const current = [leftIndex];
      for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
        const substitution = previous[rightIndex - 1] +
          (left[leftIndex - 1] === right[rightIndex - 1] ? 0 : 1);
        let distance = Math.min(
          previous[rightIndex] + 1,
          current[rightIndex - 1] + 1,
          substitution
        );

        if (
          beforePrevious &&
          leftIndex > 1 &&
          rightIndex > 1 &&
          left[leftIndex - 1] === right[rightIndex - 2] &&
          left[leftIndex - 2] === right[rightIndex - 1]
        ) {
          distance = Math.min(distance, beforePrevious[rightIndex - 2] + 1);
        }
        current.push(distance);
      }
      beforePrevious = previous;
      previous = current;
    }

    return previous[right.length];
  }

  function fuzzyTermDistance(term, candidates) {
    if (term.length < 3) return null;
    const limit = Math.min(3, Math.max(1, Math.floor(term.length / 3)));
    let best = limit + 1;
    candidates.forEach(function (candidate) {
      best = Math.min(best, editDistance(term, candidate, limit));
    });
    return best <= limit ? best : null;
  }

  function matchScore(entry, query, terms) {
    const name = normalized(entry.name);
    const qualifiedName = normalized(entry.qualifiedName);
    if (terms.every(function (term) { return qualifiedName.includes(term); })) {
      if (name === query) return 0;
      if (name.startsWith(query)) return 1;
      if (name.includes(query)) return 2;
      if (qualifiedName.startsWith(query)) return 3;
      return 4;
    }

    const candidates = [name, name.replaceAll(" ", "")].concat(qualifiedName.split(" "));
    let totalDistance = 0;
    for (const term of terms) {
      if (qualifiedName.includes(term)) continue;
      const distance = fuzzyTermDistance(term, candidates);
      if (distance === null) return null;
      totalDistance += distance;
    }
    return 5 + totalDistance;
  }

  function initializeSearch(container, entries) {
    const input = container.querySelector("[data-api-search-input]");
    const results = container.querySelector("[data-api-search-results]");
    const status = container.querySelector("[data-api-search-status]");
    const maximumResults = 24;

    function closeResults() {
      results.hidden = true;
      input.setAttribute("aria-expanded", "false");
    }

    function render() {
      const query = normalized(input.value);
      results.replaceChildren();
      if (!query) {
        closeResults();
        status.textContent = "";
        return;
      }

      const terms = query.split(" ");
      const matches = entries
        .map(function (entry) { return { entry: entry, score: matchScore(entry, query, terms) }; })
        .filter(function (match) { return match.score !== null; })
        .sort(function (left, right) {
          return left.score - right.score ||
            left.entry.qualifiedName.length - right.entry.qualifiedName.length ||
            left.entry.qualifiedName.localeCompare(right.entry.qualifiedName);
        });

      matches.slice(0, maximumResults).forEach(function (match) {
        const item = document.createElement("li");
        const link = document.createElement("a");
        const name = document.createElement("span");
        const kind = document.createElement("span");
        link.href = match.entry.href;
        name.className = "api-search-result-name";
        name.textContent = match.entry.qualifiedName;
        kind.className = "api-search-result-kind";
        kind.textContent = match.entry.kind;
        link.append(name, kind);
        item.append(link);
        results.append(item);
      });

      if (matches.length === 0) {
        const empty = document.createElement("li");
        empty.className = "api-search-empty";
        empty.textContent = "No matching API names";
        results.append(empty);
      }

      const resultWord = matches.length === 1 ? "result" : "results";
      status.textContent = `${matches.length} ${resultWord} found`;
      results.hidden = false;
      input.setAttribute("aria-expanded", "true");
    }

    input.addEventListener("input", render);
    input.addEventListener("focus", render);
    input.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        input.value = "";
        render();
      } else if (event.key === "ArrowDown") {
        const firstResult = results.querySelector("a");
        if (firstResult) {
          event.preventDefault();
          firstResult.focus();
        }
      }
    });
    results.addEventListener("keydown", function (event) {
      const links = Array.from(results.querySelectorAll("a"));
      const current = links.indexOf(document.activeElement);
      if (event.key === "ArrowDown" && current < links.length - 1) {
        event.preventDefault();
        links[current + 1].focus();
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        if (current > 0) links[current - 1].focus();
        else input.focus();
      } else if (event.key === "Escape") {
        input.focus();
        closeResults();
      }
    });
    document.addEventListener("click", function (event) {
      if (!container.contains(event.target)) closeResults();
    });
  }
})();
