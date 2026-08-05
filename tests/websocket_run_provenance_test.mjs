#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  captureRunMetadata,
  requireConsistentRunMetadata,
  validateRunMetadata,
} from "../scripts/websocket-run-provenance.mjs";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const publisher = join(projectRoot, "scripts/publish-websocket-conformance.mjs");
const outputBase = join(projectRoot, "website/reports/websocket");
const digest = `sha256:${"c".repeat(64)}`;

const profiles = [
  ["core-lightweight", "core", "lightweight", "fuzzingclient.json", "plain", false],
  ["core-native", "core", "native", "fuzzingclient-native.json", "plain", false],
  ["core-lightweight-wss", "core-wss", "lightweight", "fuzzingclient-wss.json", "tls", false],
  ["core-native-wss", "core-wss", "native", "fuzzingclient-wss-native.json", "tls", false],
  ["limits-lightweight", "limits", "lightweight", "fuzzingclient-limits.json", "plain", false],
  ["limits-native", "limits", "native", "fuzzingclient-limits-native.json", "plain", false],
  ["compression-lightweight", "compression", "lightweight", "fuzzingclient-compression.json", "plain", false],
  ["compression-native", "compression", "native", "fuzzingclient-compression-native.json", "plain", false],
  ["compression-lightweight-wss", "compression-wss", "lightweight", "fuzzingclient-compression-wss.json", "tls", false],
  ["compression-native-wss", "compression-wss", "native", "fuzzingclient-compression-wss-native.json", "tls", false],
  ["performance-lightweight", "performance", "lightweight", "fuzzingclient-performance.json", "plain", true],
  ["performance-native", "performance", "native", "fuzzingclient-performance-native.json", "plain", true],
  ["performance-lightweight-wss", "performance-wss", "lightweight", "fuzzingclient-performance-wss.json", "tls", true],
  ["performance-native-wss", "performance-wss", "native", "fuzzingclient-performance-wss-native.json", "tls", true],
];

function metadataFor([report, name, lane, config, transport], revision = "a".repeat(40)) {
  return {
    schema: 1,
    capturedAt: "2026-08-05T12:34:56.000Z",
    source: { revision, tree: "b".repeat(40), dirty: false },
    profile: {
      name,
      lane,
      report,
      config: `tests/autobahn/${config}`,
      configSha256: "d".repeat(64),
    },
    transport,
    autobahn: {
      suiteVersion: "25.10.1",
      containerImage: `crossbario/autobahn-testsuite@${digest}`,
      imageDigest: digest,
      platform: "linux/amd64",
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

function expectedFor([report, name, lane, config, transport]) {
  return {
    report,
    name,
    lane,
    config: `tests/autobahn/${config}`,
    transport,
  };
}

async function writeFixture(root, mutate) {
  for (const profile of profiles) {
    const [report, , , , , performance] = profile;
    const directory = join(root, report);
    await mkdir(directory, { recursive: true });
    const metadata = metadataFor(profile);
    if (mutate) mutate(profile, metadata);
    await writeFile(
      join(directory, "run-metadata.json"),
      `${JSON.stringify(metadata, null, 2)}\n`
    );
    const item = {
      id: performance ? "9.7.1" : "1.1.1",
      behavior: "OK",
      behaviorClose: "OK",
      description: performance
        ? "Send 1000 text messages of payload size 0"
        : "Fixture case",
      expectation: "Pass",
      result: "Pass",
      resultClose: "Pass",
      remoteCloseCode: 1000,
      localCloseCode: 1000,
      wasClean: true,
      duration: 100,
      started: "2026-08-05T12:34:56.000Z",
    };
    await writeFile(
      join(directory, "fixture_case_1.json"),
      `${JSON.stringify(item, null, 2)}\n`
    );
  }
}

function runPublisher(input, output) {
  return spawnSync(process.execPath, [publisher, input, output], {
    cwd: projectRoot,
    encoding: "utf8",
  });
}

function git(cwd, ...args) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

test("capture records the full clean revision, tree, config, image, and build", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "flyology-websocket-capture-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, "tests/autobahn"), { recursive: true });
  await writeFile(join(root, "tests/autobahn/fuzzingclient.json"), "{}\n");
  git(root, "init", "-q");
  git(root, "add", ".");
  git(
    root,
    "-c",
    "user.name=Flyology Test",
    "-c",
    "user.email=test@example.invalid",
    "commit",
    "-q",
    "-m",
    "fixture"
  );
  const metadata = await captureRunMetadata({
    projectRoot: root,
    profile: "core",
    lane: "lightweight",
    report: "core-lightweight",
    config: "tests/autobahn/fuzzingclient.json",
    transport: "plain",
    containerImage: `crossbario/autobahn-testsuite@${digest}`,
    capturedAt: "2026-08-05T12:34:56.000Z",
  });
  assert.equal(metadata.source.revision, git(root, "rev-parse", "HEAD"));
  assert.equal(metadata.source.tree, git(root, "rev-parse", "HEAD^{tree}"));
  assert.equal(metadata.source.dirty, false);
  assert.match(metadata.profile.configSha256, /^[0-9a-f]{64}$/);
  assert.equal(metadata.autobahn.imageDigest, digest);
  assert.equal(metadata.build.harnessOptimization, "-O3");
});

test("metadata schema accepts a complete matching record", () => {
  const profile = profiles[0];
  assert.equal(
    validateRunMetadata(metadataFor(profile), expectedFor(profile)).profile.report,
    profile[0]
  );
});

test("metadata schema rejects unsupported versions, dirty trees, and profile drift", () => {
  const profile = profiles[0];
  const unsupported = metadataFor(profile);
  unsupported.schema = 2;
  assert.throws(() => validateRunMetadata(unsupported, expectedFor(profile)), /schema/);

  const dirty = metadataFor(profile);
  dirty.source.dirty = true;
  assert.throws(() => validateRunMetadata(dirty, expectedFor(profile)), /dirty worktree/);

  const drifted = metadataFor(profile);
  drifted.profile.config = "tests/autobahn/other.json";
  assert.throws(() => validateRunMetadata(drifted, expectedFor(profile)), /profile\.config/);
});

test("campaign guard rejects mixed revisions", () => {
  assert.throws(
    () =>
      requireConsistentRunMetadata([
        { report: profiles[0][0], metadata: metadataFor(profiles[0]) },
        { report: profiles[1][0], metadata: metadataFor(profiles[1], "e".repeat(40)) },
      ]),
    /source\.revision/
  );
});

test("historical reports distinguish implementation from complete harness", async () => {
  const narrative = await readFile(
    join(projectRoot, "docs/websocket-conformance-2026-08-04.md"),
    "utf8"
  );
  assert.match(narrative, /implementation under test is repository revision `c4f1dd4`/);
  assert.match(narrative, /complete 14-profile harness and published[\s\S]*`9428106`/);
  assert.match(narrative, /native limits profile, native Core over WSS/);
  assert.match(narrative, /did not record a checkout revision for each historical invocation/);

  for (const [report] of profiles) {
    const directory = join(projectRoot, "website/reports/websocket", report);
    const cases = JSON.parse(await readFile(join(directory, "cases.json"), "utf8"));
    assert.equal(cases.revision, "c4f1dd4", report);
    assert.equal(cases.revisionRole, "implementation-under-test", report);
    assert.equal(cases.completeHarnessReportRevision, "9428106", report);
    assert.equal(cases.historicalPerRunRevisionCaptured, false, report);
    const html = await readFile(join(directory, "index.html"), "utf8");
    assert.match(html, /historical per-run checkout not captured/, report);
  }
});

test("publisher requires metadata for every profile", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-missing-"));
  const output = join(outputBase, `.fixture-missing-${process.pid}`);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { recursive: true, force: true });
  });
  await mkdir(join(input, profiles[0][0]), { recursive: true });
  const result = runPublisher(input, output);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /lacks readable run-metadata\.json/);
});

test("publisher reads complete per-profile provenance", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-valid-"));
  const output = join(outputBase, `.fixture-valid-${process.pid}`);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { recursive: true, force: true });
  });
  await writeFixture(input);
  const result = runPublisher(input, output);
  assert.equal(result.status, 0, result.stderr);
  const published = JSON.parse(
    await readFile(join(output, "core-lightweight/cases.json"), "utf8")
  );
  assert.equal(published.revision, "a".repeat(40));
  assert.equal(published.runMetadata.profile.report, "core-lightweight");
  assert.equal(published.runMetadata.autobahn.imageDigest, digest);
});

test("publisher rejects inconsistent campaigns before replacing output", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-mixed-"));
  const output = join(outputBase, `.fixture-mixed-${process.pid}`);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { recursive: true, force: true });
  });
  await writeFixture(input, (profile, metadata) => {
    if (profile[0] === "performance-native-wss") {
      metadata.source.revision = "e".repeat(40);
    }
  });
  await mkdir(output, { recursive: true });
  await writeFile(join(output, "sentinel"), "keep\n");
  const result = runPublisher(input, output);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /source\.revision/);
  assert.equal(await readFile(join(output, "sentinel"), "utf8"), "keep\n");
});
