#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  statusMatches,
  summarizeData,
} from "../website/assets/scripts/ci.mjs";
import {
  classifyRuns,
  isCiWorkflow,
  latestCiRuns,
  loadOrganizationStatus,
} from "./lib/ci-status.mjs";

assert.equal(isCiWorkflow({ name: "CI", path: ".github/workflows/build.yml" }), true);
assert.equal(isCiWorkflow({ name: "CI Linux", path: ".github/workflows/linux.yml" }), true);
assert.equal(isCiWorkflow({ name: "Build", path: ".github/workflows/ci.yaml" }), true);
assert.equal(isCiWorkflow({ name: "Pages", path: ".github/workflows/pages.yml" }), false);

assert.equal(classifyRuns([]), "not-configured");
assert.equal(classifyRuns([{ status: "in_progress", conclusion: null }]), "pending");
assert.equal(classifyRuns([{ status: "completed", conclusion: "success" }]), "passing");
assert.equal(classifyRuns([{ status: "completed", conclusion: "failure" }]), "failing");
assert.equal(classifyRuns([{ status: "completed", conclusion: "cancelled" }]), "cancelled");

const newestRuns = latestCiRuns([
  {
    workflow_id: 1,
    name: "CI",
    path: ".github/workflows/ci.yml",
    created_at: "2026-08-28T10:00:00Z",
    pull_requests: [],
  },
  {
    workflow_id: 1,
    name: "CI",
    path: ".github/workflows/ci.yml",
    created_at: "2026-08-29T10:00:00Z",
    pull_requests: [],
  },
  {
    workflow_id: 2,
    name: "Pages",
    path: ".github/workflows/pages.yml",
    created_at: "2026-08-29T11:00:00Z",
    pull_requests: [],
  },
  {
    workflow_id: 3,
    name: "CI fork",
    path: ".github/workflows/ci-fork.yml",
    created_at: "2026-08-29T12:00:00Z",
    pull_requests: [{ number: 4 }],
  },
]);
assert.equal(newestRuns.length, 1);
assert.equal(newestRuns[0].created_at, "2026-08-29T10:00:00Z");

assert.equal(statusMatches("failing", "attention"), true);
assert.equal(statusMatches("pending", "attention"), false);
assert.equal(statusMatches("passing", "passing"), true);

assert.deepEqual(
  summarizeData({
    repositories: [{ status: "passing" }, { status: "failing" }],
    pullRequests: [{ status: "cancelled" }, { status: "pending" }],
  }),
  { repositories: 2, mainPassing: 1, pullRequests: 2, attention: 2 }
);

const requested = [];
async function requestJson(path, _signal, quota) {
  quota.requests += 1;
  requested.push(path);
  const parsed = new URL(path, "https://api.github.com");

  if (parsed.pathname === "/orgs/flyology-ada/repos") {
    return [
      {
        name: "flyology",
        html_url: "https://github.com/flyology-ada/flyology",
        archived: false,
        fork: false,
        default_branch: "main",
      },
    ];
  }
  if (parsed.pathname === "/search/issues") {
    return {
      total_count: 1,
      items: [{
        number: 42,
        title: "Keep task state bounded",
        draft: true,
        html_url: "https://github.com/flyology-ada/flyology/pull/42",
        repository_url: "https://api.github.com/repos/flyology-ada/flyology",
        updated_at: "2026-08-29T11:00:00Z",
        user: { login: "ada" },
        pull_request: { url: "https://api.github.com/repos/flyology-ada/flyology/pulls/42" },
      }],
    };
  }
  if (parsed.pathname === "/repos/flyology-ada/flyology/actions/runs") {
    return {
      workflow_runs: [{
        workflow_id: 7,
        name: "CI",
        path: ".github/workflows/ci.yml",
        status: "completed",
        conclusion: "success",
        created_at: "2026-08-29T10:00:00Z",
        updated_at: "2026-08-29T10:30:00Z",
        html_url: "https://github.com/flyology-ada/flyology/actions/runs/7",
        run_number: 7,
        pull_requests: [],
      }],
    };
  }
  if (parsed.pathname === "/repos/flyology-ada/flyology/pulls/42") {
    return {
      number: 42,
      title: "Keep task state bounded",
      draft: true,
      html_url: "https://github.com/flyology-ada/flyology/pull/42",
      updated_at: "2026-08-29T11:00:00Z",
      user: { login: "ada" },
      head: { ref: "bounded-state", sha: "abc123" },
      base: { repo: { name: "flyology", full_name: "flyology-ada/flyology" } },
    };
  }
  if (parsed.pathname === "/repos/flyology-ada/flyology/commits/abc123/check-runs") {
    return {
      check_runs: [{
        name: "Linux / GNAT 16",
        status: "completed",
        conclusion: "success",
        html_url: "https://github.com/flyology-ada/flyology/runs/8",
        app: { name: "GitHub Actions" },
      }],
    };
  }
  throw new Error(`Unexpected test request: ${path}`);
}

const data = await loadOrganizationStatus(new AbortController().signal, { requestJson });
assert.equal(data.repositories.length, 1);
assert.equal(data.repositories[0].status, "passing");
assert.equal(data.pullRequests.length, 1);
assert.equal(data.pullRequests[0].draft, true);
assert.equal(data.pullRequests[0].status, "passing");
assert.equal(data.quota.requests, 5);
assert.deepEqual(data.quota.resources, {});
assert.equal(requested.length, 5);

console.log("CI page data tests passed.");
