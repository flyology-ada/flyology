#!/usr/bin/env node

import { readdir, readFile, stat } from "node:fs/promises";
import { dirname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";

const requestedRoot = process.argv[2];
if (!requestedRoot) {
  console.error("usage: node scripts/check-site.mjs <site-directory>");
  process.exit(2);
}

const root = resolve(requestedRoot);
const htmlCache = new Map();
const failures = [];

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await walk(path)));
    else files.push(path);
  }
  return files;
}

function insideRoot(path) {
  const fromRoot = relative(root, path);
  return fromRoot === "" || (!fromRoot.startsWith(".." + sep) && fromRoot !== "..");
}

async function htmlFor(path) {
  if (!htmlCache.has(path)) htmlCache.set(path, await readFile(path, "utf8"));
  return htmlCache.get(path);
}

function idsIn(html) {
  return new Set(
    Array.from(
      html.matchAll(/\s(?:id|name)=(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi),
      (match) => match[1] || match[2] || match[3]
    )
  );
}

function localReferences(html) {
  return Array.from(
    html.matchAll(/\s(?:href|src)=(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi),
    (match) => match[1] || match[2] || match[3]
  ).filter(
    (value) =>
      !/^(?:[a-z]+:|\/\/)/i.test(value) &&
      !value.startsWith("data:") &&
      !value.startsWith("javascript:")
  );
}

async function validateReference(source, reference) {
  const [rawPath, fragment] = reference.split("#", 2);
  const decodedPath = decodeURIComponent(rawPath || "");

  if (isAbsolute(decodedPath)) {
    failures.push(`${relative(root, source)}: root-absolute link is not portable: ${reference}`);
    return;
  }

  let target = decodedPath
    ? normalize(resolve(dirname(source), decodedPath))
    : source;
  if (!insideRoot(target)) {
    failures.push(`${relative(root, source)}: link escapes site root: ${reference}`);
    return;
  }

  try {
    const targetStat = await stat(target);
    if (targetStat.isDirectory()) target = join(target, "index.html");
    await stat(target);
  } catch {
    failures.push(`${relative(root, source)}: missing target: ${reference}`);
    return;
  }

  if (fragment && target.endsWith(".html")) {
    const ids = idsIn(await htmlFor(target));
    if (!ids.has(decodeURIComponent(fragment))) {
      failures.push(`${relative(root, source)}: missing fragment target: ${reference}`);
    }
  }
}

const rootStat = await stat(root).catch(() => null);
if (!rootStat?.isDirectory()) {
  console.error(`site directory does not exist: ${root}`);
  process.exit(2);
}

const files = await walk(root);
const htmlFiles = files.filter((path) => path.endsWith(".html"));

for (const htmlFile of htmlFiles) {
  const html = await htmlFor(htmlFile);
  if (!/<html\b[^>]*\blang=(?:"en"|'en'|en)(?:\s|>)/i.test(html)) {
    failures.push(`${relative(root, htmlFile)}: missing html lang="en"`);
  }
  if (!/<meta\b[^>]*\bname=(?:"viewport"|'viewport'|viewport)(?:\s|>)/i.test(html)) {
    failures.push(`${relative(root, htmlFile)}: missing viewport metadata`);
  }
  for (const reference of localReferences(html)) {
    await validateReference(htmlFile, reference);
  }
}

for (const searchIndex of files.filter((path) => path.endsWith("search-index.js"))) {
  const source = await readFile(searchIndex, "utf8");
  const match = source.match(/^window\.FlyologyApiSearch = (\[[\s\S]*\]);\s*$/);
  if (!match) {
    failures.push(`${relative(root, searchIndex)}: invalid API search index wrapper`);
    continue;
  }

  let entries;
  try {
    entries = JSON.parse(match[1]);
  } catch (error) {
    failures.push(`${relative(root, searchIndex)}: invalid API search index JSON: ${error.message}`);
    continue;
  }

  if (entries.length === 0) failures.push(`${relative(root, searchIndex)}: API search index is empty`);
  for (const entry of entries) {
    if (!["name", "qualifiedName", "kind", "href"].every((key) => typeof entry[key] === "string" && entry[key])) {
      failures.push(`${relative(root, searchIndex)}: malformed API search entry`);
      continue;
    }
    await validateReference(searchIndex, entry.href);
  }
}

if (failures.length) {
  failures.forEach((failure) => console.error(failure));
  console.error(`Site check failed with ${failures.length} problem(s).`);
  process.exit(1);
}

console.log(`Site check passed: ${htmlFiles.length} HTML files and ${files.length} total files.`);
