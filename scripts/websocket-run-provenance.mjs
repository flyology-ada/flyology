#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import {
  lstat,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import { relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const RUN_METADATA_SCHEMA = 2;
export const AUTOBAHN_SUITE_VERSION = "25.10.1";
export const AUTOBAHN_PLATFORM = "linux/amd64";

const fullGitObject = /^[0-9a-f]{40}$/;
const sha256 = /^[0-9a-f]{64}$/;
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

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function git(projectRoot, ...args) {
  return execFileSync("git", args, {
    cwd: projectRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function optionalGit(projectRoot, ...args) {
  const result = spawnSync("git", args, { cwd: projectRoot, encoding: "utf8" });
  if (result.status === 0) return result.stdout.trim();
  if (result.status === 1) return null;
  throw new Error(result.stderr.trim() || `git ${args.join(" ")} failed`);
}

function projectRelative(projectRoot, path) {
  const value = relative(projectRoot, resolve(projectRoot, path));
  if (value === ".." || value.startsWith(`..${sep}`)) {
    throw new Error(`configuration is outside the project: ${path}`);
  }
  return value.split(sep).join("/");
}

function firstLine(value, label) {
  const line = value.split(/\r?\n/).map((item) => item.trim()).find(Boolean);
  if (!line) throw new Error(`${label} returned no version text`);
  return line.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ");
}

function sourceStatus(projectRoot) {
  const raw = git(
    projectRoot,
    "status",
    "--porcelain=v1",
    "--untracked-files=all",
    "--ignore-submodules=none"
  );
  const entries = raw ? raw.split("\n") : [];
  return {
    clean: entries.length === 0,
    digest: digest(raw),
    entries: entries.length,
    trackedChanges: entries.filter((entry) => !entry.startsWith("??")).length,
    untracked: entries.filter((entry) => entry.startsWith("??")).length,
  };
}

export function captureSourceSnapshot(projectRoot) {
  const submoduleRaw = git(projectRoot, "submodule", "status", "--recursive");
  const source = {
    revision: git(projectRoot, "rev-parse", "HEAD"),
    tree: git(projectRoot, "rev-parse", "HEAD^{tree}"),
    headRef: optionalGit(projectRoot, "symbolic-ref", "--quiet", "--short", "HEAD"),
    status: sourceStatus(projectRoot),
    submodules: {
      digest: digest(submoduleRaw),
      entries: submoduleRaw ? submoduleRaw.split("\n").length : 0,
    },
  };
  if (!source.status.clean) {
    throw new Error(
      `WebSocket run requires a clean worktree ` +
        `(${source.status.trackedChanges} tracked, ${source.status.untracked} untracked)`
    );
  }
  return source;
}

export async function beginRunMetadata({
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
  return {
    schema: RUN_METADATA_SCHEMA,
    phase: "initial",
    capturedAt,
    source: captureSourceSnapshot(projectRoot),
    profile: {
      name: profile,
      lane,
      report,
      config: configPath,
      configSha256: digest(configBytes),
    },
    transport,
    autobahn: {
      suiteVersion: AUTOBAHN_SUITE_VERSION,
      containerImage,
      imageDigest: imageMatch[1],
      platform: AUTOBAHN_PLATFORM,
      digestPinned: true,
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

function actualEnvironment() {
  const cpus = os.cpus();
  return {
    privacy: {
      hostnameRecorded: false,
      pathsRecorded: false,
    },
    os: {
      platform: os.platform(),
      release: os.release(),
      version: os.version().replace(/\s+/g, " ").trim(),
      architecture: os.arch(),
    },
    cpu: {
      model: (cpus[0]?.model || "unknown").replace(/\s+/g, " ").trim(),
      logicalCount: cpus.length,
    },
    memoryBytes: os.totalmem(),
  };
}

function actualToolchain(alrExecutable) {
  const alire = execFileSync(alrExecutable, ["--version"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const gnat = execFileSync(alrExecutable, ["exec", "--", "gnat", "--version"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return {
    alire: firstLine(alire, "Alire"),
    gnat: firstLine(gnat, "GNAT"),
  };
}

async function hashModule(path, expectedName) {
  const link = await lstat(path);
  if (!link.isFile() && !link.isSymbolicLink()) {
    throw new Error(`TLS module is not a file: ${expectedName}`);
  }
  const resolved = await realpath(path);
  const info = await stat(resolved);
  if (!info.isFile()) throw new Error(`TLS module target is not a file: ${expectedName}`);
  return {
    fileName: expectedName,
    bytes: info.size,
    sha256: digest(await readFile(resolved)),
  };
}

async function actualTls(transport, serverLog, libraryDirectory) {
  if (transport === "plain") return null;
  if (!libraryDirectory) {
    throw new Error(
      "TLS conformance runs require FLYOLOGY_OPENSSL_LIBRARY_DIR for module identity"
    );
  }
  const log = await readFile(serverLog, "utf8");
  const provider = log.match(/^TLS_PROVIDER (.+)$/m)?.[1]?.trim();
  const version = log.match(/^TLS_VERSION (.+)$/m)?.[1]?.trim();
  if (!provider || !version) {
    throw new Error("server log lacks observable TLS provider/version identity");
  }
  const names =
    process.platform === "darwin"
      ? ["libcrypto.3.dylib", "libssl.3.dylib"]
      : ["libcrypto.so.3", "libssl.so.3"];
  const modules = [];
  for (const name of names) {
    modules.push(await hashModule(resolve(libraryDirectory, name), name));
  }
  return {
    provider,
    version,
    librarySelection: "explicit-directory",
    modules,
  };
}

function requireSameInitialState(initial, finalSource, finalConfigSha256) {
  const fields = [
    ["source.revision", initial.source.revision, finalSource.revision],
    ["source.tree", initial.source.tree, finalSource.tree],
    ["source.headRef", initial.source.headRef, finalSource.headRef],
    ["source.status", JSON.stringify(initial.source.status), JSON.stringify(finalSource.status)],
    [
      "source.submodules",
      JSON.stringify(initial.source.submodules),
      JSON.stringify(finalSource.submodules),
    ],
    ["profile.configSha256", initial.profile.configSha256, finalConfigSha256],
  ];
  for (const [field, expected, actual] of fields) {
    if (expected !== actual) {
      throw new Error(
        `WebSocket run source changed during execution: ${field} ` +
          `was ${JSON.stringify(expected)}, now ${JSON.stringify(actual)}`
      );
    }
  }
}

export async function finalizeRunMetadata({
  initial,
  projectRoot,
  alrExecutable,
  serverLog,
  tlsLibraryDirectory,
  finalizedAt = new Date().toISOString(),
  observed,
}) {
  requireEqual(initial.schema, RUN_METADATA_SCHEMA, "initial metadata schema");
  requireEqual(initial.phase, "initial", "initial metadata phase");
  const finalSource = captureSourceSnapshot(projectRoot);
  const finalConfigSha256 = digest(
    await readFile(resolve(projectRoot, initial.profile.config))
  );
  requireSameInitialState(initial, finalSource, finalConfigSha256);

  const facts =
    observed || {
      environment: actualEnvironment(),
      toolchain: actualToolchain(alrExecutable),
      tls: await actualTls(initial.transport, serverLog, tlsLibraryDirectory),
    };
  const metadata = {
    ...initial,
    phase: "final",
    finalizedAt,
    source: finalSource,
    environment: facts.environment,
    toolchain: facts.toolchain,
    tls: facts.tls,
    verification: {
      sourceRecapturedAfterVerdicts: true,
      libraryReleaseConfigChecked: true,
      verdictGatePassed: true,
    },
  };
  return validateRunMetadata(metadata);
}

function validateEnvironment(value, context) {
  const environment = requireObject(value, context);
  const privacy = requireObject(environment.privacy, `${context}.privacy`);
  requireEqual(privacy.hostnameRecorded, false, `${context}.privacy.hostnameRecorded`);
  requireEqual(privacy.pathsRecorded, false, `${context}.privacy.pathsRecorded`);
  const system = requireObject(environment.os, `${context}.os`);
  for (const field of ["platform", "release", "version", "architecture"]) {
    requireString(system[field], `${context}.os.${field}`);
  }
  const cpu = requireObject(environment.cpu, `${context}.cpu`);
  requireString(cpu.model, `${context}.cpu.model`);
  if (!Number.isInteger(cpu.logicalCount) || cpu.logicalCount < 1) {
    fail(`${context}.cpu.logicalCount`, "must be a positive integer");
  }
  if (!Number.isSafeInteger(environment.memoryBytes) || environment.memoryBytes < 1) {
    fail(`${context}.memoryBytes`, "must be a positive safe integer");
  }
}

function validateTls(metadata, context) {
  if (metadata.transport === "plain") {
    requireEqual(metadata.tls, null, `${context}.tls`);
    return;
  }
  const tls = requireObject(metadata.tls, `${context}.tls`);
  requireString(tls.provider, `${context}.tls.provider`);
  requireString(tls.version, `${context}.tls.version`);
  requireEqual(
    tls.librarySelection,
    "explicit-directory",
    `${context}.tls.librarySelection`
  );
  if (!Array.isArray(tls.modules) || tls.modules.length !== 2) {
    fail(`${context}.tls.modules`, "must identify libcrypto and libssl");
  }
  for (const [index, module] of tls.modules.entries()) {
    requireObject(module, `${context}.tls.modules[${index}]`);
    requireString(module.fileName, `${context}.tls.modules[${index}].fileName`);
    requireString(module.sha256, `${context}.tls.modules[${index}].sha256`, sha256);
    if (!Number.isSafeInteger(module.bytes) || module.bytes < 1) {
      fail(`${context}.tls.modules[${index}].bytes`, "must be a positive integer");
    }
  }
}

export function validateRunMetadata(metadata, expected, context = "run metadata") {
  requireObject(metadata, context);
  requireEqual(metadata.schema, RUN_METADATA_SCHEMA, `${context}.schema`);
  requireEqual(metadata.phase, "final", `${context}.phase`);
  requireString(metadata.capturedAt, `${context}.capturedAt`, isoInstant);
  requireString(metadata.finalizedAt, `${context}.finalizedAt`, isoInstant);

  const source = requireObject(metadata.source, `${context}.source`);
  requireString(source.revision, `${context}.source.revision`, fullGitObject);
  requireString(source.tree, `${context}.source.tree`, fullGitObject);
  if (source.headRef !== null) requireString(source.headRef, `${context}.source.headRef`);
  const status = requireObject(source.status, `${context}.source.status`);
  requireEqual(status.clean, true, `${context}.source.status.clean`);
  requireString(status.digest, `${context}.source.status.digest`, sha256);
  requireEqual(status.entries, 0, `${context}.source.status.entries`);
  requireEqual(status.trackedChanges, 0, `${context}.source.status.trackedChanges`);
  requireEqual(status.untracked, 0, `${context}.source.status.untracked`);
  const submodules = requireObject(source.submodules, `${context}.source.submodules`);
  requireString(submodules.digest, `${context}.source.submodules.digest`, sha256);
  if (!Number.isInteger(submodules.entries) || submodules.entries < 0) {
    fail(`${context}.source.submodules.entries`, "must be a nonnegative integer");
  }

  const profile = requireObject(metadata.profile, `${context}.profile`);
  requireString(profile.name, `${context}.profile.name`);
  requireString(profile.lane, `${context}.profile.lane`);
  requireString(profile.report, `${context}.profile.report`);
  requireString(profile.config, `${context}.profile.config`);
  requireString(profile.configSha256, `${context}.profile.configSha256`, sha256);

  requireString(metadata.transport, `${context}.transport`);
  const autobahn = requireObject(metadata.autobahn, `${context}.autobahn`);
  requireString(autobahn.suiteVersion, `${context}.autobahn.suiteVersion`);
  requireString(autobahn.containerImage, `${context}.autobahn.containerImage`);
  requireString(autobahn.imageDigest, `${context}.autobahn.imageDigest`, sha256Digest);
  requireString(autobahn.platform, `${context}.autobahn.platform`);
  requireEqual(autobahn.digestPinned, true, `${context}.autobahn.digestPinned`);
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
  requireEqual(build.libraryOptimization, "-O3", `${context}.build.libraryOptimization`);
  requireEqual(build.harnessOptimization, "-O3", `${context}.build.harnessOptimization`);
  requireEqual(build.runtimeDefault, "lightweight", `${context}.build.runtimeDefault`);
  requireEqual(build.runtimeLoopPoolSize, 1, `${context}.build.runtimeLoopPoolSize`);

  validateEnvironment(metadata.environment, `${context}.environment`);
  const toolchain = requireObject(metadata.toolchain, `${context}.toolchain`);
  requireString(toolchain.alire, `${context}.toolchain.alire`);
  requireString(toolchain.gnat, `${context}.toolchain.gnat`);
  validateTls(metadata, context);

  const verification = requireObject(metadata.verification, `${context}.verification`);
  requireEqual(
    verification.sourceRecapturedAfterVerdicts,
    true,
    `${context}.verification.sourceRecapturedAfterVerdicts`
  );
  requireEqual(
    verification.libraryReleaseConfigChecked,
    true,
    `${context}.verification.libraryReleaseConfigChecked`
  );
  requireEqual(
    verification.verdictGatePassed,
    true,
    `${context}.verification.verdictGatePassed`
  );

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
  const commonFields = [
    ["source", (item) => JSON.stringify(item.source)],
    ["environment", (item) => JSON.stringify(item.environment)],
    ["toolchain", (item) => JSON.stringify(item.toolchain)],
    ["autobahn", (item) => JSON.stringify(item.autobahn)],
    ["build", (item) => JSON.stringify(item.build)],
  ];
  for (const [field, read] of commonFields) {
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

  const tlsEntries = entries.filter((entry) => entry.metadata.transport === "tls");
  if (tlsEntries.length) {
    const expected = JSON.stringify(tlsEntries[0].metadata.tls);
    for (const entry of tlsEntries.slice(1)) {
      const actual = JSON.stringify(entry.metadata.tls);
      if (actual !== expected) {
        throw new Error(
          `${entry.report} run metadata is inconsistent for tls: ` +
            `expected ${expected}, got ${actual}`
        );
      }
    }
  }
  return first.metadata;
}

async function writeJsonAtomically(path, value) {
  const temporary = `${path}.tmp-${process.pid}`;
  await rm(temporary, { force: true });
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}

export async function finalizeRunMetadataFile({
  initialPath,
  output,
  projectRoot,
  alrExecutable,
  serverLog,
  tlsLibraryDirectory,
  finalizedAt,
  observed,
}) {
  await rm(output, { force: true });
  const initial = JSON.parse(await readFile(initialPath, "utf8"));
  const metadata = await finalizeRunMetadata({
    initial,
    projectRoot,
    alrExecutable,
    serverLog,
    tlsLibraryDirectory,
    finalizedAt,
    observed,
  });
  await writeJsonAtomically(output, metadata);
  await rm(initialPath, { force: true });
  return metadata;
}

async function main() {
  const command = process.argv[2];
  const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
  if (command === "begin") {
    const [output, profile, lane, report, config, transport, containerImage] =
      process.argv.slice(3);
    if (!output || !profile || !lane || !report || !config || !transport || !containerImage) {
      console.error(
        "usage: websocket-run-provenance.mjs begin OUTPUT PROFILE LANE REPORT CONFIG TRANSPORT IMAGE"
      );
      process.exit(2);
    }
    await writeJsonAtomically(
      output,
      await beginRunMetadata({
        projectRoot,
        profile,
        lane,
        report,
        config,
        transport,
        containerImage,
      })
    );
    return;
  }

  if (command === "finalize") {
    const [initialPath, output, alrExecutable, serverLog, tlsLibraryDirectory = ""] =
      process.argv.slice(3);
    if (!initialPath || !output || !alrExecutable || !serverLog) {
      console.error(
        "usage: websocket-run-provenance.mjs finalize INITIAL OUTPUT ALR SERVER_LOG [TLS_LIBRARY_DIRECTORY]"
      );
      process.exit(2);
    }
    await finalizeRunMetadataFile({
      initialPath,
      output,
      projectRoot,
      alrExecutable,
      serverLog,
      tlsLibraryDirectory,
    });
    return;
  }

  console.error("usage: websocket-run-provenance.mjs {begin|finalize} ...");
  process.exit(2);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
