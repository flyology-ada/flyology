#!/usr/bin/env node

import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { promisify } from "node:util";
import { loadOrganizationStatus } from "./lib/ci-status.mjs";

const execFileAsync = promisify(execFile);
const output = resolve(process.argv[2] || "build/site/ci/status.json");

function ghEndpoint(path) {
  if (!path.startsWith("https://")) return path;
  const url = new URL(path);
  if (url.hostname !== "api.github.com") throw new Error(`Refusing non-GitHub API URL: ${url.href}`);
  return url.pathname + url.search;
}

async function requestJson(path, signal, quota) {
  quota.requests += 1;
  const { stdout } = await execFileAsync(
    "gh",
    ["api", "--method", "GET", ghEndpoint(path), "--header", "X-GitHub-Api-Version: 2022-11-28"],
    { encoding: "utf8", maxBuffer: 20 * 1024 * 1024, signal }
  );
  return JSON.parse(stdout);
}

const data = await loadOrganizationStatus(new AbortController().signal, { requestJson });
const snapshot = {
  ...data,
  source: "github-cli",
  generatedAt: data.fetchedAt,
};

await mkdir(dirname(output), { recursive: true });
await writeFile(output, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");

console.log(
  `Wrote ${output} with ${snapshot.repositories.length} repositories, ` +
  `${snapshot.pullRequests.length} pull requests, and ${snapshot.quota.requests} GitHub API requests.`
);
