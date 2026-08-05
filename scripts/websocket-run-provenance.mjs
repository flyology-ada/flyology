#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { resolve, relative, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const RUN_METADATA_SCHEMA = 1;
export const AUTOBAHN_SUITE_VERSION = "25.10.1";
export const AUTOBAHN_PLATFORM = "linux/amd64";

const fullGitObject = /^[0-9a-f]{40}$/;
const sha256Digest = /^sha256:[0-9a-f]{64}$/;
const isoInstant = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;

function fail(context, message) {
  throw new Error(`${context}: ${message}`);
}

function requireObject(value, context) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(context, "must be an object");
  }
  return value;
}

function requireString(value, context, pattern) {
  if (typeof value !== "string" || value.length === 0) {
    fail(context, "must be a nonempty string");
  }
  if (pattern && !pattern.test(value)) {
    fail(context, `has invalid value ${JSON.stringify(value)}`);
  }
  return value;
}

function requireEqual(actual, expected, context) {
  if (actual !== expected) {
    fail(context, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function git(projectRoot, ...args) {
  return execFileSync("git", args, {
    cwd: projectRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function projectRelative(projectRoot, path) {
  const value = relative(projectRoot, resolve(projectRoot, path));
  if (value === ".." || value.startsWith(`..${sep}`)) {
    throw new Error(`configuration is outside the project: ${path}`);
  }
  return value.split(sep).join("/");
}

export async function captureRunMetadata({
  projectRoot,
  profile,
  lane,
  report,
  config,
  transport,
  containerImage,
  capturedAt = new Date().toISOString(),
}) {
  const imageMatch = containerImage.match(/@(sha256:[0-9a-f]{64})$/);
  if (!imageMatch) {
    throw new Error(
      `Autobahn image must use an immutable sha256 digest: ${containerImage}`
    );
  }

  const configPath = projectRelative(projectRoot, config);
  const configBytes = await readFile(resolve(projectRoot, configPath));
  const dirty = git(projectRoot, "status", "--porcelain", "--untracked-files=normal").length > 0;

  return {
    schema: RUN_METADATA_SCHEMA,
    capturedAt,
    source: {
      revision: git(projectRoot, "rev-parse", "HEAD"),
      tree: git(projectRoot, "rev-parse", "HEAD^{tree}"),
      dirty,
    },
    profile: {
      name: profile,
      lane,
      report,
      config: configPath,
      configSha256: createHash("sha256").update(configBytes).digest("hex"),
    },
    transport,
    autobahn: {
      suiteVersion: AUTOBAHN_SUITE_VERSION,
      containerImage,
      imageDigest: imageMatch[1],
      platform: AUTOBAHN_PLATFORM,
    },
    build: {
      libraryProfile: "release",
      libraryProfileSource: "Alire --release",
      libraryOptimization: "-O3",
      harnessOptimization: "-O3",
      runtimeDefault: "lightweight",
      runtimeLoopPoolSize: 1,
    },
  };
}

export function validateRunMetadata(metadata, expected, context = "run metadata") {
  requireObject(metadata, context);
  requireEqual(metadata.schema, RUN_METADATA_SCHEMA, `${context}.schema`);
  requireString(metadata.capturedAt, `${context}.capturedAt`, isoInstant);

  const source = requireObject(metadata.source, `${context}.source`);
  requireString(source.revision, `${context}.source.revision`, fullGitObject);
  requireString(source.tree, `${context}.source.tree`, fullGitObject);
  if (typeof source.dirty !== "boolean") {
    fail(`${context}.source.dirty`, "must be a boolean");
  }
  if (source.dirty) {
    fail(context, "cannot publish a run captured from a dirty worktree");
  }

  const profile = requireObject(metadata.profile, `${context}.profile`);
  requireString(profile.name, `${context}.profile.name`);
  requireString(profile.lane, `${context}.profile.lane`);
  requireString(profile.report, `${context}.profile.report`);
  requireString(profile.config, `${context}.profile.config`);
  requireString(
    profile.configSha256,
    `${context}.profile.configSha256`,
    /^[0-9a-f]{64}$/
  );

  requireString(metadata.transport, `${context}.transport`);
  const autobahn = requireObject(metadata.autobahn, `${context}.autobahn`);
  requireString(autobahn.suiteVersion, `${context}.autobahn.suiteVersion`);
  requireString(autobahn.containerImage, `${context}.autobahn.containerImage`);
  requireString(autobahn.imageDigest, `${context}.autobahn.imageDigest`, sha256Digest);
  requireString(autobahn.platform, `${context}.autobahn.platform`);
  if (!autobahn.containerImage.endsWith(`@${autobahn.imageDigest}`)) {
    fail(context, "container image and image digest disagree");
  }

  const build = requireObject(metadata.build, `${context}.build`);
  requireEqual(build.libraryProfile, "release", `${context}.build.libraryProfile`);
  requireEqual(
    build.libraryProfileSource,
    "Alire --release",
    `${context}.build.libraryProfileSource`
  );
  requireEqual(
    build.libraryOptimization,
    "-O3",
    `${context}.build.libraryOptimization`
  );
  requireEqual(
    build.harnessOptimization,
    "-O3",
    `${context}.build.harnessOptimization`
  );
  requireEqual(build.runtimeDefault, "lightweight", `${context}.build.runtimeDefault`);
  requireEqual(build.runtimeLoopPoolSize, 1, `${context}.build.runtimeLoopPoolSize`);

  if (expected) {
    requireEqual(profile.name, expected.name, `${context}.profile.name`);
    requireEqual(profile.lane, expected.lane, `${context}.profile.lane`);
    requireEqual(profile.report, expected.report, `${context}.profile.report`);
    requireEqual(profile.config, expected.config, `${context}.profile.config`);
    requireEqual(metadata.transport, expected.transport, `${context}.transport`);
  }
  return metadata;
}

export function requireConsistentRunMetadata(entries) {
  if (!entries.length) throw new Error("no WebSocket run metadata supplied");
  const first = entries[0];
  const fields = [
    ["source.revision", (item) => item.source.revision],
    ["source.tree", (item) => item.source.tree],
    ["autobahn.suiteVersion", (item) => item.autobahn.suiteVersion],
    ["autobahn.containerImage", (item) => item.autobahn.containerImage],
    ["autobahn.imageDigest", (item) => item.autobahn.imageDigest],
    ["autobahn.platform", (item) => item.autobahn.platform],
    ["build", (item) => JSON.stringify(item.build)],
  ];
  for (const [field, read] of fields) {
    const expected = read(first.metadata);
    for (const entry of entries.slice(1)) {
      const actual = read(entry.metadata);
      if (actual !== expected) {
        throw new Error(
          `${entry.report} run metadata is inconsistent for ${field}: ` +
            `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
        );
      }
    }
  }
  return first.metadata;
}

async function main() {
  const [command, output, profile, lane, report, config, transport, containerImage] =
    process.argv.slice(2);
  if (
    command !== "capture" ||
    !output ||
    !profile ||
    !lane ||
    !report ||
    !config ||
    !transport ||
    !containerImage
  ) {
    console.error(
      "usage: websocket-run-provenance.mjs capture OUTPUT PROFILE LANE REPORT CONFIG TRANSPORT IMAGE"
    );
    process.exit(2);
  }
  const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
  const metadata = await captureRunMetadata({
    projectRoot,
    profile,
    lane,
    report,
    config,
    transport,
    containerImage,
  });
  await writeFile(output, `${JSON.stringify(metadata, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
