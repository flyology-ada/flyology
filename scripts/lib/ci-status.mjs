const ORGANIZATION = "flyology-ada";
const CONCURRENCY = 6;

export function isCiWorkflow(run) {
  const name = String(run?.name || "").trim();
  const path = String(run?.path || "");
  return /^ci(?:\b|\s|[-_:])/i.test(name) || /(?:^|\/)ci\.ya?ml$/i.test(path);
}

export function classifyRuns(runs) {
  if (!runs?.length) return "not-configured";
  if (runs.some((run) => run.status !== "completed")) return "pending";

  const conclusions = runs.map((run) => run.conclusion);
  if (conclusions.some((value) => ["failure", "timed_out", "startup_failure", "action_required"].includes(value))) {
    return "failing";
  }
  if (conclusions.some((value) => ["cancelled", "stale"].includes(value))) return "cancelled";
  if (conclusions.every((value) => ["success", "neutral", "skipped"].includes(value))) return "passing";
  return "unavailable";
}

export function latestCiRuns(runs) {
  const latest = new Map();
  runs
    .filter(isCiWorkflow)
    .filter((run) => !run.pull_requests?.length)
    .forEach((run) => {
      const key = run.workflow_id || run.path || run.name;
      const previous = latest.get(key);
      if (!previous || Date.parse(run.created_at) > Date.parse(previous.created_at)) latest.set(key, run);
    });
  return Array.from(latest.values()).sort((a, b) => a.name.localeCompare(b.name));
}

async function mapConcurrent(items, limit, work) {
  const results = new Array(items.length);
  let next = 0;

  async function worker() {
    while (next < items.length) {
      const index = next++;
      try {
        results[index] = { status: "fulfilled", value: await work(items[index], index) };
      } catch (reason) {
        results[index] = { status: "rejected", reason };
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

async function fetchRepositories(signal, quota, requestJson) {
  const repositories = [];
  for (let page = 1; page <= 10; page += 1) {
    const batch = await requestJson(
      `/orgs/${ORGANIZATION}/repos?type=public&sort=full_name&direction=asc&per_page=100&page=${page}`,
      signal,
      quota
    );
    repositories.push(...batch);
    if (batch.length < 100) break;
  }
  return repositories;
}

async function fetchOpenPullRequestSearch(signal, quota, requestJson) {
  const pullRequests = [];
  const query = encodeURIComponent(`org:${ORGANIZATION} is:pr is:open is:public`);
  let total = Infinity;

  for (let page = 1; page <= 10 && pullRequests.length < total; page += 1) {
    const response = await requestJson(
      `/search/issues?q=${query}&sort=updated&order=desc&per_page=100&page=${page}`,
      signal,
      quota
    );
    total = Math.min(response.total_count, 1000);
    pullRequests.push(...response.items);
    if (response.items.length < 100) break;
  }
  return pullRequests;
}

async function loadRepositoryStatus(repo, signal, quota, requestJson) {
  const response = await requestJson(
    `/repos/${ORGANIZATION}/${encodeURIComponent(repo.name)}/actions/runs?branch=main&per_page=100`,
    signal,
    quota
  );
  const runs = latestCiRuns(response.workflow_runs || []);
  return {
    name: repo.name,
    url: repo.html_url,
    archived: repo.archived,
    fork: repo.fork,
    defaultBranch: repo.default_branch,
    runs,
    status: classifyRuns(runs),
  };
}

function unavailableRepository(repo, error) {
  return {
    name: repo.name,
    url: repo.html_url,
    archived: repo.archived,
    fork: repo.fork,
    defaultBranch: repo.default_branch,
    runs: [],
    status: "unavailable",
    error: error.message,
  };
}

async function loadPullRequest(searchResult, signal, quota, requestJson) {
  const detail = await requestJson(searchResult.pull_request.url, signal, quota);
  const checksResponse = await requestJson(
    `/repos/${detail.base.repo.full_name}/commits/${encodeURIComponent(detail.head.sha)}/check-runs?filter=latest&per_page=100`,
    signal,
    quota
  );
  const checks = checksResponse.check_runs || [];
  return {
    repository: detail.base.repo.name,
    number: detail.number,
    title: detail.title,
    draft: detail.draft,
    url: detail.html_url,
    author: detail.user?.login || "unknown",
    branch: detail.head.ref,
    updatedAt: detail.updated_at,
    checks,
    status: classifyRuns(checks),
  };
}

function unavailablePullRequest(searchResult, error) {
  const repository = searchResult.repository_url.split("/").pop();
  return {
    repository,
    number: searchResult.number,
    title: searchResult.title,
    draft: Boolean(searchResult.draft),
    url: searchResult.html_url,
    author: searchResult.user?.login || "unknown",
    branch: "unknown",
    updatedAt: searchResult.updated_at,
    checks: [],
    status: "unavailable",
    error: error.message,
  };
}

export async function loadOrganizationStatus(signal, { requestJson } = {}) {
  if (typeof requestJson !== "function") throw new TypeError("A GitHub data provider is required");
  const quota = { requests: 0, resources: {} };
  const [repositories, pullRequestSearch] = await Promise.all([
    fetchRepositories(signal, quota, requestJson),
    fetchOpenPullRequestSearch(signal, quota, requestJson),
  ]);

  const [repositoryResults, pullRequestResults] = await Promise.all([
    mapConcurrent(repositories, CONCURRENCY, (repo) => loadRepositoryStatus(repo, signal, quota, requestJson)),
    mapConcurrent(pullRequestSearch, CONCURRENCY, (pr) => loadPullRequest(pr, signal, quota, requestJson)),
  ]);

  const repositoryStatuses = repositoryResults.map((result, index) =>
    result.status === "fulfilled" ? result.value : unavailableRepository(repositories[index], result.reason)
  );
  const pullRequests = pullRequestResults.map((result, index) =>
    result.status === "fulfilled" ? result.value : unavailablePullRequest(pullRequestSearch[index], result.reason)
  );

  return {
    organization: ORGANIZATION,
    fetchedAt: new Date().toISOString(),
    repositories: repositoryStatuses.sort((a, b) => a.name.localeCompare(b.name)),
    pullRequests: pullRequests.sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt)),
    errors: [...repositoryStatuses, ...pullRequests].filter((item) => item.error).map((item) => item.error),
    quota,
  };
}
