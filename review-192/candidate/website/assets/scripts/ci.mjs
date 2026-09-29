const SNAPSHOT_URL = "https://flyology-ada.github.io/flyology.org/status.json";

const STATUS_LABELS = {
  passing: "Passing",
  failing: "Failing",
  pending: "In progress",
  cancelled: "Cancelled",
  "not-configured": "No CI run",
  unavailable: "Unavailable",
};

const ATTENTION_STATUSES = new Set(["failing", "cancelled", "unavailable"]);

export function statusMatches(status, filter) {
  if (filter === "all") return true;
  if (filter === "attention") return ATTENTION_STATUSES.has(status);
  return status === filter;
}

export function summarizeData(data) {
  const mainPassing = data.repositories.filter((repo) => repo.status === "passing").length;
  const attention = [...data.repositories, ...data.pullRequests].filter((item) =>
    ATTENTION_STATUSES.has(item.status)
  ).length;
  return {
    repositories: data.repositories.length,
    mainPassing,
    pullRequests: data.pullRequests.length,
    attention,
  };
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function githubLink(url, className, text) {
  const link = element("a", className, text);
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "https:" && parsed.hostname === "github.com") link.href = parsed.href;
  } catch (_error) {
    // Leave an invalid URL as plain link text with no navigation target.
  }
  return link;
}

function statusBadge(status) {
  const badge = element("span", "ci-status");
  badge.dataset.status = status;
  badge.append(element("span", "ci-status-mark"), element("span", "", STATUS_LABELS[status] || "Unknown"));
  return badge;
}

function dateLabel(value) {
  if (!value) return "No run";
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return "Unknown";
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

function fullDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return "Unknown time";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
}

function renderRepository(repo) {
  const row = element("tr", "ci-repository");
  row.dataset.status = repo.status;
  row.dataset.search = repo.name.toLowerCase();

  const identity = element("td");
  identity.append(githubLink(repo.url, "ci-repository-link", repo.name));
  const metadata = element("div", "ci-repository-meta");
  if (repo.fork) metadata.append(element("span", "", "Fork"));
  if (repo.archived) metadata.append(element("span", "", "Archived"));
  if (repo.defaultBranch !== "main") metadata.append(element("span", "", `Default: ${repo.defaultBranch}`));
  if (metadata.childElementCount) identity.append(metadata);

  const state = element("td");
  state.append(statusBadge(repo.status));

  const latest = element("td");
  if (repo.runs.length) {
    const newest = repo.runs.reduce((current, run) =>
      Date.parse(run.created_at) > Date.parse(current.created_at) ? run : current
    );
    latest.append(githubLink(newest.html_url, "ci-run-link", newest.name));
    const runMeta = element("div", "ci-run-meta", `Run ${newest.run_number}`);
    if (repo.runs.length > 1) runMeta.append(` · ${repo.runs.length} CI workflows`);
    latest.append(runMeta);
  } else {
    latest.append(element("span", "ci-run-meta", repo.error || "No matching workflow run found on main"));
  }

  const observed = element("td", "ci-observed");
  const newestTime = repo.runs.reduce((latestTime, run) => {
    const candidate = run.updated_at || run.created_at;
    return !latestTime || Date.parse(candidate) > Date.parse(latestTime) ? candidate : latestTime;
  }, null);
  observed.textContent = dateLabel(newestTime);
  if (newestTime) observed.title = fullDate(newestTime);

  row.append(identity, state, latest, observed);
  return row;
}

function checkLabel(check) {
  if (check.status !== "completed") return STATUS_LABELS.pending;
  const labels = {
    success: "Passed",
    neutral: "Neutral",
    skipped: "Skipped",
    failure: "Failed",
    timed_out: "Timed out",
    cancelled: "Cancelled",
    action_required: "Action required",
    stale: "Stale",
    startup_failure: "Startup failure",
  };
  return labels[check.conclusion] || "Unknown";
}

function renderPullRequest(pr) {
  const details = element("details", "ci-pr");
  details.dataset.status = pr.status;
  details.dataset.search = `${pr.repository} ${pr.number} ${pr.title} ${pr.author}`.toLowerCase();

  const summary = element("summary");
  const identity = element("div", "ci-pr-identity");
  identity.append(element("span", "", `${pr.repository} #${pr.number}`));
  if (pr.draft) identity.append(element("span", "ci-draft", "Draft"));

  const copy = element("div");
  copy.append(githubLink(pr.url, "ci-pr-title", pr.title));
  const metadata = element("div", "ci-pr-meta");
  metadata.append(element("span", "", `by ${pr.author}`), element("span", "", pr.branch));
  const updated = element("span", "", `updated ${dateLabel(pr.updatedAt)}`);
  updated.title = fullDate(pr.updatedAt);
  metadata.append(updated);
  copy.append(metadata);

  summary.append(identity, copy, statusBadge(pr.status));

  const checkArea = element("div", "ci-pr-checks");
  const countCopy = pr.checks.length === 1 ? "1 check on the head commit" : `${pr.checks.length} checks on the head commit`;
  checkArea.append(element("p", "", pr.error || countCopy));
  const list = element("ul", "ci-check-list");
  if (pr.checks.length) {
    pr.checks
      .slice()
      .sort((a, b) => a.name.localeCompare(b.name))
      .forEach((check) => {
        const item = element("li");
        const name = check.app?.name ? `${check.name} · ${check.app.name}` : check.name;
        item.append(githubLink(check.html_url, "", name), element("span", "", checkLabel(check)));
        list.append(item);
      });
  } else {
    const item = element("li");
    item.append(element("span", "", "No check runs were reported for this commit."));
    list.append(item);
  }
  checkArea.append(list);
  details.append(summary, checkArea);
  return details;
}

async function readSnapshot(signal) {
  const response = await fetch(`${SNAPSHOT_URL}?t=${Date.now()}`, {
    cache: "no-store",
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error(`Snapshot returned ${response.status}`);
  const snapshot = await response.json();
  if (!Array.isArray(snapshot?.repositories) || !Array.isArray(snapshot?.pullRequests)) {
    throw new Error("Snapshot has an invalid shape");
  }
  return snapshot;
}

function initializePage() {
  const root = document.querySelector("[data-ci-root]");
  if (!root) return;

  const fetchState = document.querySelector(".ci-fetch-state");
  const fetchTitle = document.querySelector("[data-fetch-title]");
  const fetchDetail = document.querySelector("[data-fetch-detail]");
  const refresh = document.querySelector("[data-refresh]");
  const repositoryBody = document.querySelector("[data-repositories]");
  const pullRequestList = document.querySelector("[data-pull-requests]");
  const repositoryEmpty = document.querySelector("[data-repositories-empty]");
  const pullRequestEmpty = document.querySelector("[data-prs-empty]");
  const search = document.querySelector("[data-search]");
  const statusFilter = document.querySelector("[data-status-filter]");
  const filterCount = document.querySelector("[data-filter-count]");
  const notice = document.querySelector("[data-notice]");
  const noticeTitle = document.querySelector("[data-notice-title]");
  const noticeCopy = document.querySelector("[data-notice-copy]");
  let data;
  let controller;

  function setLoading() {
    fetchState.dataset.state = "loading";
    fetchTitle.textContent = "Loading CI status";
    fetchDetail.textContent = "Reading the generated snapshot";
    refresh.disabled = true;
    root.setAttribute("aria-busy", "true");
    notice.hidden = true;
  }

  function applyFilters() {
    if (!data) return;
    const query = search.value.trim().toLowerCase();
    const selected = statusFilter.value;
    let repositoriesVisible = 0;
    let pullRequestsVisible = 0;

    repositoryBody.querySelectorAll(".ci-repository").forEach((row) => {
      row.hidden = !(row.dataset.search.includes(query) && statusMatches(row.dataset.status, selected));
      if (!row.hidden) repositoriesVisible += 1;
    });
    pullRequestList.querySelectorAll(".ci-pr").forEach((row) => {
      row.hidden = !(row.dataset.search.includes(query) && statusMatches(row.dataset.status, selected));
      if (!row.hidden) pullRequestsVisible += 1;
    });

    repositoryEmpty.hidden = repositoriesVisible !== 0;
    pullRequestEmpty.hidden = pullRequestsVisible !== 0;
    filterCount.textContent = `${repositoriesVisible} repositories · ${pullRequestsVisible} pull requests`;
  }

  function render(nextData) {
    data = nextData;
    repositoryBody.replaceChildren(...data.repositories.map(renderRepository));
    pullRequestList.replaceChildren(...data.pullRequests.map(renderPullRequest));

    const summary = summarizeData(data);
    document.querySelector("[data-summary-repositories]").textContent = summary.repositories;
    document.querySelector("[data-summary-main]").textContent = `${summary.mainPassing} / ${summary.repositories}`;
    document.querySelector("[data-summary-prs]").textContent = summary.pullRequests;
    document.querySelector("[data-summary-attention]").textContent = summary.attention;

    const partial = data.errors.length > 0;
    fetchState.dataset.state = partial ? "partial" : "ready";
    fetchTitle.textContent = partial ? "Partial snapshot loaded" : "CI snapshot loaded";
    fetchDetail.textContent = `Generated ${dateLabel(data.generatedAt || data.fetchedAt)} · static data`;
    document.querySelector("[data-api-method]").textContent =
      `Snapshot generated ${fullDate(data.generatedAt || data.fetchedAt)}.`;
    if (partial) {
      notice.hidden = false;
      noticeTitle.textContent = "Some results are unavailable";
      noticeCopy.textContent = "The generated snapshot contains unavailable results. Reload after the publisher updates it.";
    }
    refresh.disabled = false;
    root.setAttribute("aria-busy", "false");
    applyFilters();
  }

  function showError(error) {
    fetchState.dataset.state = "error";
    fetchTitle.textContent = "CI snapshot unavailable";
    fetchDetail.textContent = "No status data was loaded";
    notice.hidden = false;
    noticeTitle.textContent = "Published data could not be loaded";
    noticeCopy.textContent = `${error.message}. Reload the snapshot or open the organization directly.`;
    repositoryBody.replaceChildren();
    pullRequestList.replaceChildren();
    repositoryEmpty.hidden = false;
    pullRequestEmpty.hidden = false;
    filterCount.textContent = "No snapshot results";
    refresh.disabled = false;
    root.setAttribute("aria-busy", "false");
  }

  async function load() {
    controller?.abort();
    controller = new AbortController();
    setLoading();

    try {
      render(await readSnapshot(controller.signal));
    } catch (error) {
      if (error.name !== "AbortError") showError(error);
    }
  }

  search.addEventListener("input", applyFilters);
  statusFilter.addEventListener("change", applyFilters);
  refresh.addEventListener("click", load);
  load();
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initializePage);
  else initializePage();
}
