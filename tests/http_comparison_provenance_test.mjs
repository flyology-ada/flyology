#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const journalRoot = join(
  projectRoot,
  "website/journal/2026-08-http-comparison-correction"
);
const methodPath = join(journalRoot, "data/method.json");
const recordedLocal = "d0abaa294e7c650aef3e94c10b757d103ef561ee";
const reachableLocal = "6110161d0806d504a1802030c6ce74c519c15e7f";
const recordedOverlay = "46a718a4fd87c3ec7f18d3ddd7e7bd9aedbe78e9";
const reachableOverlay = "49ef1ca535dced0fde888e291914d7fab9beb61f";

function git(...args) {
  const result = spawnSync("git", args, { cwd: projectRoot, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function patchId(revision) {
  const patch = spawnSync("git", ["show", "--pretty=format:", "--binary", revision], {
    cwd: projectRoot,
  });
  assert.equal(patch.status, 0, patch.stderr.toString());
  const result = spawnSync("git", ["patch-id", "--stable"], {
    cwd: projectRoot,
    input: patch.stdout,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split(/\s+/, 1)[0];
}

test("method schema retains recorded hashes and reachable equivalents", async () => {
  const method = JSON.parse(await readFile(methodPath, "utf8"));
  assert.equal(method.schema, 2);
  assert.equal(method.source_revision, recordedOverlay);
  assert.equal(method.source_revision_reachable_equivalent, reachableOverlay);
  assert.equal(method.measurement_sources.local.revision, recordedLocal);
  assert.equal(
    method.measurement_sources.local.reachable_equivalent_revision,
    reachableLocal
  );
  assert.equal(
    method.measurement_sources.kubernetes.checkout_revision,
    "7880b4e231e043bf1fb102d34b0b362ac0505fe7"
  );
  assert.equal(
    method.harness_correction_revision,
    "b0cfa28b1d31313f022f42a0d79d4e7b84a5719b"
  );
  assert.equal(method.validity.raw_results_available, false);
  assert.match(method.validity.aggregate_regeneration, /cannot be independently regenerated/);
});

test("reachable equivalents match the recorded subtree and patch evidence", async () => {
  const method = JSON.parse(await readFile(methodPath, "utf8"));
  assert.equal(
    git("rev-parse", `${reachableLocal}:showcases/http-comparison`),
    method.measurement_sources.local.equivalence.showcase_tree
  );
  assert.equal(
    patchId(reachableLocal),
    method.measurement_sources.local.equivalence.stable_patch_id
  );
  assert.equal(
    git("rev-parse", `${reachableOverlay}:showcases/http-comparison`),
    method.source_revision_equivalence.showcase_tree
  );
  assert.equal(patchId(reachableOverlay), method.source_revision_equivalence.stable_patch_id);
});

test("journal links and reproduction commands use reachable snapshots", async () => {
  const html = await readFile(join(journalRoot, "index.html"), "utf8");
  assert.match(html, new RegExp(`/tree/${reachableLocal}/showcases/http-comparison`));
  assert.match(html, new RegExp(`/tree/${reachableOverlay}/showcases/http-comparison`));
  assert.doesNotMatch(html, new RegExp(`/tree/${recordedLocal}/`));
  assert.doesNotMatch(html, new RegExp(`/tree/${recordedOverlay}/`));
  assert.match(html, new RegExp(`git switch --detach ${reachableLocal}`));
  assert.match(html, new RegExp(`git switch --detach ${reachableOverlay}`));
  assert.match(html, /raw oha JSON[\s\S]*are no longer available/);
  assert.match(html, /No measurement was rerun/);
});

test("historical aggregate CSV bytes remain unchanged", async () => {
  const expected = new Map([
    ["summary.csv", "9ae0c2945d4e6e91ac16cd615469262dcf19cc94902a4ca153f3197b01d335b1"],
    ["resources.csv", "38efbebfb3eddde59b0f88c910f1417f0f9954a6b411f43be80768e4d0e303ba"],
    ["saturation.csv", "6ce5ad3cf3f3a57a0df3d487f50cf2a9d435394a63419cc5a97a9ff6555b265c"],
    ["saturation-excluded.csv", "194d51bb817070c6d5978fb07cf0820705a7fa7e012c640d097552e33b0518e9"],
    ["saturation-resources.csv", "54620c43c89b28201287384959139d4e3c76a74bb0d36ca0f4fa88f21980a878"],
  ]);
  for (const [name, digest] of expected) {
    const bytes = await readFile(join(journalRoot, "data", name));
    assert.equal(createHash("sha256").update(bytes).digest("hex"), digest, name);
  }
});
