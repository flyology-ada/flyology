#!/usr/bin/env node

import { readdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const guideRoot = join(projectRoot, "website", "guide");

const runtimeChapters = [
  "stacks",
  "task-memory",
  "execution-groups",
  "task-aware-io",
  "scoped-operations",
  "resource-budgets",
  "observability",
  "verification",
  "constraints",
  "shared-memory",
  "data-structures",
  "file-watching",
  "file-transfers",
  "subprocesses",
  "supervision",
  "process-upgrades",
  "timers",
];

const libraryChapters = ["benchmarking", "cachelines", "numa"];
const toolChapters = ["cli"];
const compatibilityRedirects = ["http"];
const legacyFragments = [
  "stacks",
  "memory",
  "groups",
  "grow-pool",
  "reduce-pool",
  "io",
  "client-connections",
  "scoped-operations",
  "unix-sockets",
  "budgets",
  "checkpoints",
  "observe",
  "utilization",
  "verify",
  "constraints",
];

const entries = await readdir(guideRoot, { withFileTypes: true });
const chapterDirectories = entries
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();
const categorized = new Set([
  ...runtimeChapters,
  ...libraryChapters,
  ...toolChapters,
  ...compatibilityRedirects,
]);
const failures = [];

for (const chapter of chapterDirectories) {
  if (!categorized.has(chapter)) {
    failures.push(`uncategorized guide chapter: ${chapter}`);
  }
}
for (const chapter of categorized) {
  if (!chapterDirectories.includes(chapter)) {
    failures.push(`categorized guide chapter is missing: ${chapter}`);
  }
}

const guideIndex = await readFile(join(guideRoot, "index.html"), "utf8");
const navigationScript = await readFile(
  join(projectRoot, "website", "assets", "scripts", "guide-navigation.js"),
  "utf8",
);
for (const chapter of runtimeChapters) {
  if (!guideIndex.includes(`href="${chapter}/"`)) {
    failures.push(`runtime chapter is not linked from the guide index: ${chapter}`);
  }
  if (!navigationScript.includes(`["${chapter}",`)) {
    failures.push(`runtime chapter is not linked from the guide menu: ${chapter}`);
  }

  const chapterPage = await readFile(join(guideRoot, chapter, "index.html"), "utf8");
  if (!chapterPage.includes("assets/scripts/guide-navigation.js")) {
    failures.push(`runtime chapter does not load the guide menu: ${chapter}`);
  }
}
if (!guideIndex.includes("assets/scripts/guide-navigation.js")) {
  failures.push("guide start page does not load the guide menu");
}
for (const chapter of toolChapters) {
  if (!guideIndex.includes(`href="${chapter}/"`)) {
    failures.push(`tool chapter is not linked from the guide index: ${chapter}`);
  }

  const chapterPage = await readFile(join(guideRoot, chapter, "index.html"), "utf8");
  if (chapterPage.includes("assets/scripts/guide-navigation.js")) {
    failures.push(`tool chapter incorrectly loads the runtime guide menu: ${chapter}`);
  }
}
for (const fragment of legacyFragments) {
  if (!guideIndex.includes(`id="${fragment}"`)) {
    failures.push(`legacy guide fragment has no moved-link target: #${fragment}`);
  }
}

const libraryIndex = await readFile(
  join(projectRoot, "website", "libraries", "index.html"),
  "utf8",
);
for (const chapter of libraryChapters) {
  if (!libraryIndex.includes(`href="../guide/${chapter}/"`)) {
    failures.push(`library chapter is not linked from Libraries: ${chapter}`);
  }
  if (navigationScript.includes(`["${chapter}",`)) {
    failures.push(`library chapter is incorrectly linked from the runtime guide menu: ${chapter}`);
  }

  const chapterPage = await readFile(join(guideRoot, chapter, "index.html"), "utf8");
  if (chapterPage.includes("assets/scripts/guide-navigation.js")) {
    failures.push(`library chapter incorrectly loads the runtime guide menu: ${chapter}`);
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}

console.log(
  `Guide index check passed: ${runtimeChapters.length} runtime chapters, ` +
    `${libraryChapters.length} library chapters, ` +
    `${toolChapters.length} tool chapter, and ` +
    `${legacyFragments.length} legacy fragments.`,
);
