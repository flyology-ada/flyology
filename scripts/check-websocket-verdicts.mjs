#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const [reportDir, profile, lane] = process.argv.slice(2);
if (!reportDir || !profile || !lane) {
  console.error("usage: check-websocket-verdicts.mjs REPORT_DIR PROFILE LANE");
  process.exit(2);
}

const allowed = new Set(["OK", "NON-STRICT", "INFORMATIONAL"]);
const fields = ["behavior", "behaviorClose"];
const counts = Object.fromEntries(fields.map((field) => [field, new Map()]));
let failed = false;

let files;
try {
  files = fs.readdirSync(reportDir)
    .filter((name) => /_case_.*\.json$/.test(name))
    .sort();
} catch (error) {
  console.error(`cannot read Autobahn report directory ${reportDir}: ${error.message}`);
  process.exit(1);
}

if (files.length === 0) {
  console.error(`no Autobahn case reports found in ${reportDir}`);
  process.exit(1);
}

for (const name of files) {
  let report;
  try {
    report = JSON.parse(fs.readFileSync(path.join(reportDir, name), "utf8"));
  } catch (error) {
    console.error(`${name}: invalid JSON: ${error.message}`);
    failed = true;
    continue;
  }

  for (const field of fields) {
    const verdict = report[field];
    if (typeof verdict !== "string" || verdict.length === 0) {
      console.error(`${name}: missing or invalid ${field} verdict`);
      failed = true;
      continue;
    }
    counts[field].set(verdict, (counts[field].get(verdict) ?? 0) + 1);
    if (!allowed.has(verdict)) {
      failed = true;
    }
  }
}

function printCounts(label, values) {
  console.log(`Autobahn ${label} verdicts (${profile}, ${lane}):`);
  for (const [verdict, count] of [...values].sort(([a], [b]) => a.localeCompare(b))) {
    console.log(`${String(count).padStart(7)} ${verdict}`);
  }
}

printCounts("behavior", counts.behavior);
printCounts("close", counts.behaviorClose);
if (failed) {
  process.exit(1);
}
