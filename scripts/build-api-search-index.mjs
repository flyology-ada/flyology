#!/usr/bin/env node

import { readdir, readFile, writeFile } from "node:fs/promises";
import { relative, resolve, sep } from "node:path";

const requestedRoot = process.argv[2];
if (!requestedRoot) {
  console.error("usage: node scripts/build-api-search-index.mjs <api-directory>");
  process.exit(2);
}

const root = resolve(requestedRoot);

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await walk(path)));
    else files.push(path);
  }
  return files;
}

function decodeHtml(value) {
  const named = {
    amp: "&",
    apos: "'",
    gt: ">",
    lt: "<",
    quot: '"',
  };

  return value.replace(/&(#(?:x[0-9a-f]+|[0-9]+)|[a-z]+);/gi, (match, entity) => {
    if (entity[0] !== "#") return named[entity.toLowerCase()] ?? match;
    const hexadecimal = entity[1].toLowerCase() === "x";
    const codePoint = Number.parseInt(entity.slice(hexadecimal ? 2 : 1), hexadecimal ? 16 : 10);
    return Number.isFinite(codePoint) ? String.fromCodePoint(codePoint) : match;
  });
}

function textContent(fragment) {
  return decodeHtml(fragment.replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ").trim();
}

function attribute(fragment, name) {
  const match = fragment.match(
    new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i")
  );
  return match ? decodeHtml(match[1] ?? match[2] ?? match[3]) : null;
}

function entityKinds(html) {
  const aside = html.match(/<aside\b([^>]*)>([\s\S]*?)<\/aside>/i);
  if (!aside || !/\bentity-index\b/.test(attribute(aside[1], "class") ?? "")) return new Map();

  const singular = new Map([
    ["Generic formal parameters", "Generic formal"],
    ["Exceptions", "Exception"],
    ["Simple types", "Simple type"],
    ["Array types", "Array type"],
    ["Record types", "Record type"],
    ["Interface types", "Interface type"],
    ["Tagged types", "Tagged type"],
    ["Tasks", "Task type"],
    ["Protected types", "Protected type"],
    ["Access types", "Access type"],
    ["Subtypes", "Subtype"],
    ["Constants", "Constant"],
    ["Variables", "Variable"],
    ["Entries", "Entry"],
    ["Subprograms", "Subprogram"],
    ["Generic instantiations", "Generic instantiation"],
  ]);
  const kinds = new Map();
  const tags = aside[2].matchAll(/<h3\b[^>]*>([\s\S]*?)<\/h3>|<a\b([^>]*)>([\s\S]*?)<\/a>/gi);
  let currentKind = "API entity";

  for (const tag of tags) {
    if (tag[1] !== undefined) {
      const heading = textContent(tag[1]);
      currentKind = singular.get(heading) ?? heading;
      continue;
    }

    const href = attribute(tag[2], "href");
    if (href?.startsWith("#")) kinds.set(href.slice(1), currentKind);
  }
  return kinds;
}

function entriesFor(html, file) {
  const body = html.match(/<body\b([^>]*)>/i);
  if (!body || !/\bapi-unit-page\b/.test(attribute(body[1], "class") ?? "")) return [];

  const unitHeader = Array.from(html.matchAll(/<header\b([^>]*)>([\s\S]*?)<\/header>/gi)).find(
    (candidate) => /\bapi-unit-header\b/.test(attribute(candidate[1], "class") ?? "")
  );
  const heading = unitHeader?.[2].match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i);
  if (!heading) throw new Error(`${file}: unable to find the compilation-unit heading`);

  const unit = textContent(heading[1]);
  const hrefBase = relative(root, file).split(sep).join("/");
  const entries = [{ name: unit, qualifiedName: unit, kind: "Compilation unit", href: hrefBase }];
  const kinds = entityKinds(html);
  const searchable = html.matchAll(/<h4\b([^>]*)>([\s\S]*?)<\/h4>|<dt\b([^>]*\bdata-search-kind\b[^>]*)>([\s\S]*?)(?=<dd\b|<\/dt>)/gi);
  let parent = null;

  for (const item of searchable) {
    if (item[1] !== undefined) {
      const id = attribute(item[1], "id");
      if (!id) continue;
      const name = textContent(item[2]);
      parent = { name, href: `${hrefBase}#${encodeURIComponent(id)}` };
      entries.push({
        name,
        qualifiedName: `${unit}.${name}`,
        kind: kinds.get(id) ?? "API entity",
        href: parent.href,
      });
      continue;
    }

    const name = textContent(item[4]);
    const kind = attribute(item[3], "data-search-kind") ?? "API name";
    entries.push({
      name,
      qualifiedName: parent ? `${unit}.${parent.name}.${name}` : `${unit}.${name}`,
      kind,
      href: parent?.href ?? hrefBase,
    });
  }

  return entries;
}

const files = (await walk(root)).filter((file) => file.endsWith(".html"));
const entries = [];
for (const file of files) entries.push(...entriesFor(await readFile(file, "utf8"), file));

entries.sort(
  (left, right) =>
    left.qualifiedName.localeCompare(right.qualifiedName, "en", { sensitivity: "base" }) ||
    left.kind.localeCompare(right.kind, "en", { sensitivity: "base" }) ||
    left.href.localeCompare(right.href, "en")
);

const output = `window.FlyologyApiSearch = ${JSON.stringify(entries)};\n`;
await writeFile(resolve(root, "search-index.js"), output, "utf8");
console.log(`API search index generated: ${entries.length} names from ${files.length} HTML files.`);
