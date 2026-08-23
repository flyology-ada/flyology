(function () {
  "use strict";

  const coreChapters = [
    ["", "Start here"],
    ["stacks", "Task stack sizing"],
    ["task-memory", "Task memory"],
    ["execution-groups", "Execution groups"],
    ["task-aware-io", "Task-aware I/O"],
    ["scoped-operations", "Scoped operations"],
    ["resource-budgets", "Resource budgets"],
    ["observability", "Runtime observability"],
    ["verification", "Verification"],
    ["constraints", "Execution constraints"],
  ];

  const topicGuides = [
    ["shared-memory", "Shared-memory segments"],
    ["data-structures", "Relocatable data structures"],
    ["file-watching", "File watching"],
    ["file-transfers", "File-to-socket transfers"],
    ["subprocesses", "Native subprocesses"],
    ["supervision", "Structured task supervision"],
    ["process-upgrades", "Process upgrades"],
    ["timers", "Timers and clock changes"],
  ];

  function currentChapter() {
    const canonical = document.querySelector('link[rel="canonical"]');
    const pathname = canonical ? new URL(canonical.href).pathname : window.location.pathname;
    const match = pathname.match(/\/guide(?:\/([^/]+))?\/?$/);
    return match ? match[1] || "" : null;
  }

  function chapterHref(slug, atGuideRoot) {
    const guideRoot = atGuideRoot ? "./" : "../";
    return slug ? guideRoot + slug + "/" : guideRoot;
  }

  function guideSection(title, chapters, activeSlug, atGuideRoot, openActive) {
    const item = document.createElement("li");
    const details = document.createElement("details");
    const summary = document.createElement("summary");
    const links = document.createElement("ul");

    item.className = "guide-nav-section";
    summary.textContent = title;
    chapters.forEach(function (chapter) {
      const row = document.createElement("li");
      const link = document.createElement("a");
      link.href = chapterHref(chapter[0], atGuideRoot);
      link.textContent = chapter[1];
      if (chapter[0] === activeSlug) link.setAttribute("aria-current", "page");
      row.append(link);
      links.append(row);
    });

    if (openActive && chapters.some(function (chapter) { return chapter[0] === activeSlug; })) {
      details.open = true;
    }
    details.append(summary, links);
    item.append(details);
    return item;
  }

  document.addEventListener("DOMContentLoaded", function () {
    const toc = document.querySelector(".toc");
    const activeSlug = currentChapter();
    if (!toc || activeSlug === null) return;

    const existingList = toc.querySelector(":scope > ol");
    const hasLocalLinks = Boolean(existingList && existingList.querySelector('a[href^="#"]'));
    const atGuideRoot = activeSlug === "";
    const menu = document.createElement("ol");
    const title = toc.querySelector(".toc-title");

    toc.classList.add("guide-nav");
    toc.setAttribute("aria-label", "Runtime guide navigation");
    toc.tabIndex = 0;
    if (title) title.textContent = "Runtime guide";

    if (hasLocalLinks) {
      const item = document.createElement("li");
      const details = document.createElement("details");
      const summary = document.createElement("summary");
      item.className = "guide-nav-section guide-nav-local";
      summary.textContent = "On this page";
      details.open = true;
      details.append(summary, existingList);
      item.append(details);
      menu.append(item);
    } else if (existingList) {
      existingList.remove();
    }

    menu.append(guideSection("Core chapters", coreChapters, activeSlug, atGuideRoot, !hasLocalLinks));
    menu.append(guideSection("Topic guides", topicGuides, activeSlug, atGuideRoot, !hasLocalLinks));

    toc.append(menu);

    if (!atGuideRoot) {
      document.querySelectorAll('.nav-links a[aria-current="page"]').forEach(function (link) {
        const pathname = new URL(link.href, window.location.href).pathname;
        if (/\/guide\/$/.test(pathname)) link.setAttribute("aria-current", "location");
      });
    }

    window.setTimeout(function () {
      const toggleLabel = toc.querySelector(".toc-toggle-label");
      const toggleCurrent = toc.querySelector(".toc-toggle-current");
      const activeLink = toc.querySelector('a[aria-current="page"]');
      if (toggleLabel) toggleLabel.textContent = "Runtime guide";
      if (toggleCurrent && activeLink) toggleCurrent.textContent = activeLink.textContent.trim();
    }, 0);
  });
})();
