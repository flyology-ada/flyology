#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmod,
  lstat,
  mkdtemp,
  mkdir,
  readFile,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  beginRunMetadata,
  finalizeRunMetadata,
  finalizeRunMetadataFile,
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

function observedFacts(transport) {
  return {
    environment: {
      privacy: { hostnameRecorded: false, pathsRecorded: false },
      os: {
        platform: "fixture-os",
        release: "1.2.3",
        version: "Fixture OS 1.2.3",
        architecture: "fixture-arch",
      },
      cpu: { model: "Fixture CPU", logicalCount: 8 },
      memoryBytes: 16 * 1_073_741_824,
    },
    toolchain: {
      alire: "alr 2.1.1",
      gnat: "GNAT 16.1.0",
    },
    tls:
      transport === "tls"
        ? {
            provider: "OpenSSL 3",
            version: "OpenSSL 3.6.3 9 Jun 2026",
            librarySelection: "explicit-directory",
            modules: [
              { fileName: "libcrypto.3.dylib", bytes: 101, sha256: "e".repeat(64) },
              { fileName: "libssl.3.dylib", bytes: 102, sha256: "f".repeat(64) },
            ],
          }
        : null,
  };
}

function metadataFor([report, name, lane, config, transport], revision = "a".repeat(40)) {
  return {
    schema: 2,
    phase: "final",
    capturedAt: "2026-08-05T12:34:56.000Z",
    finalizedAt: "2026-08-05T12:44:56.000Z",
    source: {
      revision,
      tree: "b".repeat(40),
      headRef: "fixture",
      status: {
        clean: true,
        digest: createHash("sha256").update("").digest("hex"),
        entries: 0,
        trackedChanges: 0,
        untracked: 0,
      },
      submodules: {
        digest: createHash("sha256").update("").digest("hex"),
        entries: 0,
      },
    },
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
    ...observedFacts(transport),
    verification: {
      sourceRecapturedAfterVerdicts: true,
      libraryReleaseConfigChecked: true,
      verdictGatePassed: true,
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

function runPublisher(input, output, failure) {
  return spawnSync(process.execPath, [publisher, input, output], {
    cwd: projectRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      ...(failure ? { FLYOLOGY_WEBSOCKET_PUBLISH_FAIL: failure } : {}),
    },
  });
}

function git(cwd, ...args) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

async function createRepository(t) {
  const root = await mkdtemp(join(tmpdir(), "flyology-websocket-source-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, "tests/autobahn"), { recursive: true });
  await writeFile(join(root, "tests/autobahn/fuzzingclient.json"), "{}\n");
  await writeFile(join(root, "source.txt"), "source\n");
  await writeFile(join(root, ".gitignore"), "/build/\n");
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
  return root;
}

async function beginFixture(root, transport = "plain") {
  return beginRunMetadata({
    projectRoot: root,
    profile: transport === "tls" ? "core-wss" : "core",
    lane: "lightweight",
    report: transport === "tls" ? "core-lightweight-wss" : "core-lightweight",
    config: "tests/autobahn/fuzzingclient.json",
    transport,
    containerImage: `crossbario/autobahn-testsuite@${digest}`,
    capturedAt: "2026-08-05T12:34:56.000Z",
  });
}

async function snapshotDirectory(root, directory = root) {
  const records = [];
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) =>
    a.name.localeCompare(b.name)
  )) {
    const path = join(directory, entry.name);
    const relative = path.slice(root.length + 1);
    const info = await lstat(path);
    if (entry.isDirectory()) records.push(...(await snapshotDirectory(root, path)));
    else if (entry.isSymbolicLink()) records.push([relative, "link", info.mode]);
    else {
      records.push([
        relative,
        createHash("sha256").update(await readFile(path)).digest("hex"),
        info.mode,
      ]);
    }
  }
  return records;
}

function publicationSiblings(output) {
  const name = basename(output);
  const parent = resolve(output, "..");
  return [join(parent, `.${name}.publish-stage`), join(parent, `.${name}.publish-backup`)];
}

test("finalization records sanitized observed environment after recapturing source", async (t) => {
  const root = await createRepository(t);
  const initial = await beginFixture(root);
  const metadata = await finalizeRunMetadata({
    initial,
    projectRoot: root,
    observed: observedFacts("plain"),
    finalizedAt: "2026-08-05T12:44:56.000Z",
  });
  assert.equal(metadata.phase, "final");
  assert.equal(metadata.source.revision, git(root, "rev-parse", "HEAD"));
  assert.equal(metadata.environment.privacy.hostnameRecorded, false);
  assert.equal(metadata.environment.privacy.pathsRecorded, false);
  assert.equal(metadata.toolchain.gnat, "GNAT 16.1.0");
  assert.equal(metadata.tls, null);
  assert.equal(metadata.verification.sourceRecapturedAfterVerdicts, true);
});

test("TLS finalization hashes the explicitly selected modules and observed provider", async (t) => {
  const root = await createRepository(t);
  const initial = await beginFixture(root, "tls");
  const tools = join(root, "build/tools");
  const libraries = join(root, "build/openssl/private/location");
  await mkdir(tools, { recursive: true });
  await mkdir(libraries, { recursive: true });
  const fakeAlr = join(tools, "alr");
  await writeFile(
    fakeAlr,
    '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "alr 9.8.7"; else echo "GNAT 7.8.9"; fi\n'
  );
  await chmod(fakeAlr, 0o755);
  const names =
    process.platform === "darwin"
      ? ["libcrypto.3.dylib", "libssl.3.dylib"]
      : ["libcrypto.so.3", "libssl.so.3"];
  await writeFile(join(libraries, names[0]), "crypto fixture\n");
  await writeFile(join(libraries, names[1]), "ssl fixture\n");
  const serverLog = join(root, "build/server.log");
  await writeFile(
    serverLog,
    "READY lightweight wss://127.0.0.1:18081/websocket\n" +
      "TLS_PROVIDER OpenSSL 3\nTLS_VERSION OpenSSL 3.9.9 fixture\n"
  );
  const metadata = await finalizeRunMetadata({
    initial,
    projectRoot: root,
    alrExecutable: fakeAlr,
    serverLog,
    tlsLibraryDirectory: libraries,
    finalizedAt: "2026-08-05T12:44:56.000Z",
  });
  assert.equal(metadata.toolchain.alire, "alr 9.8.7");
  assert.equal(metadata.toolchain.gnat, "GNAT 7.8.9");
  assert.equal(metadata.tls.provider, "OpenSSL 3");
  assert.equal(metadata.tls.version, "OpenSSL 3.9.9 fixture");
  assert.deepEqual(metadata.tls.modules.map((item) => item.fileName), names);
  assert.equal(JSON.stringify(metadata).includes(root), false);
});

test("initial capture rejects real tracked and untracked dirt", async (t) => {
  const tracked = await createRepository(t);
  await writeFile(join(tracked, "source.txt"), "changed\n");
  await assert.rejects(() => beginFixture(tracked), /1 tracked, 0 untracked/);

  const untracked = await createRepository(t);
  await writeFile(join(untracked, "untracked.txt"), "new\n");
  await assert.rejects(() => beginFixture(untracked), /0 tracked, 1 untracked/);
});

test("finalization rejects real mid-run edits, config changes, and commits", async (t) => {
  const edited = await createRepository(t);
  const editInitial = await beginFixture(edited);
  await mkdir(join(edited, "build"));
  const initialPath = join(edited, "build/.initial.json");
  const finalPath = join(edited, "build/run-metadata.json");
  await writeFile(initialPath, `${JSON.stringify(editInitial)}\n`);
  await writeFile(finalPath, "stale publishable metadata\n");
  await writeFile(join(edited, "source.txt"), "mid-run edit\n");
  await assert.rejects(
    () =>
      finalizeRunMetadataFile({
        initialPath,
        output: finalPath,
        projectRoot: edited,
        observed: observedFacts("plain"),
      }),
    /clean worktree/
  );
  assert.equal(await lstat(finalPath).catch(() => null), null);
  assert.notEqual(await lstat(initialPath).catch(() => null), null);

  const configured = await createRepository(t);
  const configInitial = await beginFixture(configured);
  await writeFile(join(configured, "tests/autobahn/fuzzingclient.json"), '{"changed":true}\n');
  await assert.rejects(
    () =>
      finalizeRunMetadata({
        initial: configInitial,
        projectRoot: configured,
        observed: observedFacts("plain"),
      }),
    /clean worktree/
  );

  const committed = await createRepository(t);
  const commitInitial = await beginFixture(committed);
  await writeFile(join(committed, "source.txt"), "committed change\n");
  git(committed, "add", "source.txt");
  git(
    committed,
    "-c",
    "user.name=Flyology Test",
    "-c",
    "user.email=test@example.invalid",
    "commit",
    "-q",
    "-m",
    "mid-run"
  );
  await assert.rejects(
    () =>
      finalizeRunMetadata({
        initial: commitInitial,
        projectRoot: committed,
        observed: observedFacts("plain"),
      }),
    /source\.revision/
  );
});

test("capture uses the selected alternate worktree state", async (t) => {
  const root = await createRepository(t);
  const alternate = await mkdtemp(join(tmpdir(), "flyology-websocket-worktree-"));
  await rm(alternate, { recursive: true, force: true });
  t.after(() => rm(alternate, { recursive: true, force: true }));
  git(root, "worktree", "add", "--quiet", "--detach", alternate);
  await writeFile(join(root, "main-only-untracked.txt"), "not in alternate\n");
  const initial = await beginFixture(alternate);
  assert.equal(initial.source.revision, git(alternate, "rev-parse", "HEAD"));
  assert.equal(initial.source.headRef, null);
  assert.equal(initial.source.status.clean, true);
});

test("metadata schema validates actual environment and transport-specific TLS", () => {
  const plain = metadataFor(profiles[0]);
  assert.equal(validateRunMetadata(plain, expectedFor(profiles[0])).tls, null);
  const tls = metadataFor(profiles[2]);
  assert.equal(validateRunMetadata(tls, expectedFor(profiles[2])).tls.provider, "OpenSSL 3");

  const leaked = metadataFor(profiles[0]);
  leaked.environment.privacy.hostnameRecorded = true;
  assert.throws(() => validateRunMetadata(leaked, expectedFor(profiles[0])), /hostnameRecorded/);
});

test("campaign guard defines common facts and transport-specific TLS facts", () => {
  const entries = profiles.map((profile) => ({
    report: profile[0],
    metadata: metadataFor(profile),
  }));
  assert.equal(requireConsistentRunMetadata(entries).source.revision, "a".repeat(40));

  const environmentDrift = structuredClone(entries);
  environmentDrift[1].metadata.environment.os.release = "other";
  assert.throws(() => requireConsistentRunMetadata(environmentDrift), /environment/);

  const tlsDrift = structuredClone(entries);
  tlsDrift.find((entry) => entry.metadata.transport === "tls").metadata.tls.version = "other";
  assert.throws(() => requireConsistentRunMetadata(tlsDrift), /tls/);
});

test("historical reports use accurate bundle wording", async () => {
  for (const [report] of profiles) {
    const directory = join(projectRoot, "website/reports/websocket", report);
    const cases = JSON.parse(await readFile(join(directory, "cases.json"), "utf8"));
    assert.equal(cases.revisionRole, "implementation-under-test", report);
    assert.equal(cases.completeHarnessReportRevision, "9428106", report);
    const html = await readFile(join(directory, "index.html"), "utf8");
    assert.match(html, /dated report bundle/, report);
    assert.doesNotMatch(html, /one reproducible conformance run/, report);
  }
});

test("publisher requires final metadata for every profile", async (t) => {
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

test("publisher renders captured environment instead of the dated static record", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-valid-"));
  const output = join(outputBase, `.fixture-valid-${process.pid}`);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { recursive: true, force: true });
    for (const path of publicationSiblings(output)) {
      await rm(path, { recursive: true, force: true });
    }
  });
  await writeFixture(input);
  const result = runPublisher(input, output);
  assert.equal(result.status, 0, result.stderr);
  const published = JSON.parse(
    await readFile(join(output, "core-lightweight/cases.json"), "utf8")
  );
  assert.equal(published.runMetadata.environment.cpu.model, "Fixture CPU");
  const performance = await readFile(
    join(output, "performance-lightweight/index.html"),
    "utf8"
  );
  assert.match(performance, /Fixture CPU/);
  assert.match(performance, /GNAT 16\.1\.0/);
  assert.doesNotMatch(performance, /MacBook Pro|Apple M3 Max/);
  assert.equal(
    JSON.parse(await readFile(join(output, ".publication-manifest.json"), "utf8")).schema,
    1
  );
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
  const before = await snapshotDirectory(output);
  const result = runPublisher(input, output);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /source/);
  assert.deepEqual(await snapshotDirectory(output), before);
});

test("render, write, and swap failures preserve the prior bundle byte-for-byte", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-failures-"));
  const output = join(outputBase, `.fixture-failures-${process.pid}`);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { recursive: true, force: true });
    for (const path of publicationSiblings(output)) {
      await rm(path, { recursive: true, force: true });
    }
  });
  await writeFixture(input);
  await mkdir(join(output, "prior"), { recursive: true });
  await writeFile(join(output, "index.html"), "prior index\n");
  await writeFile(join(output, "prior/data.bin"), Buffer.from([0, 1, 2, 3]));
  const before = await snapshotDirectory(output);

  for (const failure of [
    "render",
    "write",
    "verify",
    "swap-after-backup",
    "swap-after-publish",
  ]) {
    const result = runPublisher(input, output, failure);
    assert.notEqual(result.status, 0, failure);
    assert.match(result.stderr, new RegExp(`forced WebSocket publication failure at ${failure}`));
    assert.deepEqual(await snapshotDirectory(output), before, failure);
    for (const path of publicationSiblings(output)) {
      assert.equal(await lstat(path).catch(() => null), null, `${failure}: stale sibling`);
    }
  }
});

test("publisher refuses symlink publication targets", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-symlink-input-"));
  const target = await mkdtemp(join(tmpdir(), "flyology-websocket-symlink-target-"));
  const output = join(outputBase, `.fixture-symlink-${process.pid}`);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { force: true });
    await rm(target, { recursive: true, force: true });
  });
  await writeFixture(input);
  await writeFile(join(target, "sentinel"), "keep\n");
  await symlink(target, output);
  const result = runPublisher(input, output);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must be an ordinary directory/);
  assert.equal(await readFile(join(target, "sentinel"), "utf8"), "keep\n");
});

test("publisher safely recovers stale siblings and refuses sibling symlinks", async (t) => {
  const input = await mkdtemp(join(tmpdir(), "flyology-websocket-stale-input-"));
  const target = await mkdtemp(join(tmpdir(), "flyology-websocket-stale-target-"));
  const output = join(outputBase, `.fixture-stale-${process.pid}`);
  const [stage, backup] = publicationSiblings(output);
  t.after(async () => {
    await rm(input, { recursive: true, force: true });
    await rm(output, { recursive: true, force: true });
    await rm(stage, { recursive: true, force: true });
    await rm(backup, { recursive: true, force: true });
    await rm(target, { recursive: true, force: true });
  });
  await writeFixture(input);
  await mkdir(join(backup, "prior"), { recursive: true });
  await writeFile(join(backup, "prior/data"), "recover me\n");
  await mkdir(stage);
  await writeFile(join(stage, "stale"), "discard me\n");
  const prior = await snapshotDirectory(backup);
  const recovered = runPublisher(input, output, "render");
  assert.notEqual(recovered.status, 0);
  assert.deepEqual(await snapshotDirectory(output), prior);
  assert.equal(await lstat(stage).catch(() => null), null);
  assert.equal(await lstat(backup).catch(() => null), null);

  await symlink(target, stage);
  const stageResult = runPublisher(input, output);
  assert.notEqual(stageResult.status, 0);
  assert.match(stageResult.stderr, /publication stage must be an ordinary directory/);
  await rm(stage);

  await symlink(target, backup);
  const backupResult = runPublisher(input, output);
  assert.notEqual(backupResult.status, 0);
  assert.match(backupResult.stderr, /publication backup must be an ordinary directory/);
  assert.deepEqual(await snapshotDirectory(output), prior);
});
