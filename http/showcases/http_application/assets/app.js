(() => {
  const root = document.documentElement;
  const storedTheme = localStorage.getItem("flyology-demo-theme");
  if (storedTheme === "dark" || storedTheme === "light") root.dataset.theme = storedTheme;

  document.querySelector("[data-theme-toggle]").addEventListener("click", () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
    localStorage.setItem("flyology-demo-theme", root.dataset.theme);
  });

  document.querySelector("[data-origin]").textContent = location.host;

  const adaKeywords = new Set([
    "access", "and", "begin", "body", "case", "constant", "declare",
    "delta", "do", "else", "elsif", "end", "exception", "exit", "for",
    "function", "generic", "if", "in", "is", "limited", "loop", "mod",
    "new", "not", "null", "of", "or", "others", "out", "package",
    "pragma", "private", "procedure", "raise", "range", "record", "rem",
    "renames", "return", "reverse", "select", "separate", "subtype",
    "task", "terminate", "then", "type", "until", "use", "when", "while",
    "with", "xor"
  ]);
  const adaTokenPattern = /(--[^\n]*|"(?:[^"]|"")*"|'[A-Za-z][A-Za-z0-9_]*|\b[A-Za-z][A-Za-z0-9_]*\b|\b\d[\d_]*(?:\.\d[\d_]*)?\b|=>|:=|\/=|<=|>=|\.\.)/g;

  function highlightedToken(className, value) {
    const token = document.createElement("span");
    token.className = className;
    token.textContent = value;
    return token;
  }

  function highlightAda(code) {
    const source = code.textContent;
    const fragment = document.createDocumentFragment();
    let cursor = 0;
    for (const match of source.matchAll(adaTokenPattern)) {
      if (match.index > cursor) fragment.append(document.createTextNode(source.slice(cursor, match.index)));
      const value = match[0];
      const normalized = value.toLowerCase();
      let className = "tok-identifier";
      if (value.startsWith("--")) className = "tok-comment";
      else if (value.startsWith('"')) className = "tok-string";
      else if (value.startsWith("'")) className = "tok-attribute";
      else if (/^\d/.test(value)) className = "tok-number";
      else if (adaKeywords.has(normalized)) className = "tok-keyword";
      else if (["=>", ":=", "/=", "<=", ">=", ".."].includes(value)) className = "tok-operator";
      fragment.append(highlightedToken(className, value));
      cursor = match.index + value.length;
    }
    if (cursor < source.length) fragment.append(document.createTextNode(source.slice(cursor)));
    code.replaceChildren(fragment);
  }

  document.querySelectorAll("[data-ada]").forEach(highlightAda);

  const serverState = document.querySelector("[data-server-state]");
  const serverLabel = document.querySelector("[data-server-label]");
  const requestMetric = document.querySelector("[data-metric-requests]");
  const activeMetric = document.querySelector("[data-metric-active]");

  let eventSource;
  const eventLog = document.querySelector("[data-event-log]");
  const sseState = document.querySelector("[data-sse-state]");
  const sseLabel = document.querySelector("[data-sse-label]");
  const sseRoute = document.querySelector("[data-sse-route]");
  const ssePanel = document.querySelector("#event-stream-panel");
  const sseRestart = document.querySelector("[data-sse-reconnect]");
  const sseSourceCode = document.querySelector("[data-sse-source-code]");
  const sseSourceName = document.querySelector("[data-sse-source-name]");
  const sseSourceCaption = document.querySelector("[data-sse-source-caption]");
  const streamTabs = [...document.querySelectorAll("[data-sse-stream]")];
  const streamDefinitions = {
    flight: {
      url: "/events",
      event: "flight",
      route: "GET /events",
      opening: "opening flight stream",
      open: "flight stream connected",
      empty: "The first lifecycle event will appear here.",
      restart: "Replay flight",
      sourceName: "SSE_Events",
      sourceCaption: "bounded producer and sole writer"
    },
    requests: {
      url: "/request-log/events",
      event: "request",
      route: "GET /request-log/events",
      opening: "opening request log",
      open: "request log live",
      empty: "Waiting for a completed request. Try a probe below.",
      restart: "Reconnect log",
      sourceName: "Request_Log_Events",
      sourceCaption: "bounded access-log cursor and sole writer"
    }
  };
  let selectedStream = "flight";

  function setSSEState(state, label) {
    sseState.dataset.sseState = state;
    sseLabel.textContent = label;
  }

  function receivedTime() {
    return new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  }

  function eventRow(sequenceValue, titleValue, detailValue, kind = "flight") {
    const item = document.createElement("li");
    item.className = `event-row ${kind}`;
    const sequence = document.createElement("span");
    sequence.className = "event-sequence";
    sequence.textContent = String(sequenceValue).padStart(2, "0");
    const copy = document.createElement("div");
    copy.className = "event-copy";
    const title = document.createElement("strong");
    title.textContent = titleValue;
    const detail = document.createElement("span");
    detail.textContent = detailValue;
    copy.append(title, detail);
    const time = document.createElement("time");
    time.className = "event-time";
    time.textContent = receivedTime();
    item.append(sequence, copy, time);
    eventLog.append(item);
    eventLog.scrollTop = eventLog.scrollHeight;
  }

  function requestDetail(entry) {
    const status = entry.status === 0 ? "status unavailable" : `HTTP ${entry.status}`;
    return `${status} · ${entry.request_id} · ${formatInteger(entry.request_bytes)} B in / ${formatInteger(entry.response_bytes)} B out · ${(Number(entry.elapsed) * 1000).toFixed(1)} ms`;
  }

  function showDroppedRequests(count) {
    if (!count) return;
    const item = document.createElement("li");
    item.className = "event-gap";
    item.textContent = `${formatInteger(count)} older request records fell outside the 64-entry retained window.`;
    eventLog.append(item);
  }

  function connectEvents() {
    if (eventSource) eventSource.close();
    const definition = streamDefinitions[selectedStream];
    eventLog.replaceChildren();
    const empty = document.createElement("li");
    empty.className = "empty-state";
    empty.textContent = definition.empty;
    eventLog.append(empty);
    setSSEState("waiting", definition.opening);
    const source = new EventSource(definition.url);
    eventSource = source;
    source.onopen = () => {
      if (eventSource === source) setSSEState("open", definition.open);
    };
    source.addEventListener(definition.event, (event) => {
      if (eventSource !== source) return;
      eventLog.querySelector(".empty-state")?.remove();
      const value = JSON.parse(event.data);
      if (selectedStream === "flight") {
        eventRow(value.sequence, value.phase, value.detail);
      } else {
        showDroppedRequests(value.dropped_before);
        eventRow(value.sequence, `${value.entry.method} ${value.entry.route || "unmatched"}`, requestDetail(value.entry), "request");
      }
    });
    source.addEventListener("complete", () => {
      if (eventSource !== source || selectedStream !== "flight") return;
      setSSEState("open", "flight complete");
      source.close();
    });
    source.onerror = () => {
      if (eventSource === source) setSSEState("error", `${selectedStream === "flight" ? "flight stream" : "request log"} reconnecting`);
    };
  }

  function selectStream(name, moveFocus = false) {
    selectedStream = name;
    const definition = streamDefinitions[name];
    streamTabs.forEach((tab) => {
      const selected = tab.dataset.sseStream === name;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && moveFocus) tab.focus();
    });
    const selectedTab = streamTabs.find((tab) => tab.dataset.sseStream === name);
    ssePanel.setAttribute("aria-labelledby", selectedTab.id);
    sseRoute.textContent = definition.route;
    sseRestart.textContent = definition.restart;
    sseSourceName.textContent = definition.sourceName;
    sseSourceCaption.textContent = definition.sourceCaption;
    const template = document.querySelector(`[data-sse-source-template="${name}"]`);
    sseSourceCode.textContent = template.content.textContent.trim();
    highlightAda(sseSourceCode);
    connectEvents();
  }

  streamTabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectStream(tab.dataset.sseStream));
    tab.addEventListener("keydown", (event) => {
      if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
      event.preventDefault();
      const offset = event.key === "ArrowRight" ? 1 : -1;
      const next = (index + offset + streamTabs.length) % streamTabs.length;
      selectStream(streamTabs[next].dataset.sseStream, true);
    });
  });
  sseRestart.addEventListener("click", connectEvents);
  connectEvents();

  let socket;
  const chatState = document.querySelector("[data-chat-state]");
  const chatLabel = document.querySelector("[data-chat-label]");
  const messages = document.querySelector("[data-chat-messages]");
  const chatForm = document.querySelector("[data-chat-form]");

  function addMessage(text, kind = "remote") {
    const item = document.createElement("div");
    item.className = `message ${kind}`;
    item.textContent = text;
    messages.append(item);
    messages.scrollTop = messages.scrollHeight;
  }

  function connectChat() {
    if (socket && socket.readyState < WebSocket.CLOSING) socket.close(1000, "reconnect");
    const scheme = location.protocol === "https:" ? "wss" : "ws";
    socket = new WebSocket(`${scheme}://${location.host}/chat`);
    chatState.dataset.chatState = "connecting";
    chatLabel.textContent = "connecting";
    socket.addEventListener("open", () => {
      chatState.dataset.chatState = "open";
      chatLabel.textContent = "connected";
    });
    socket.addEventListener("message", (event) => addMessage(event.data, event.data.startsWith("system:") ? "system" : "remote"));
    socket.addEventListener("close", () => {
      chatState.dataset.chatState = "closed";
      chatLabel.textContent = "closed, reconnect to continue";
    });
    socket.addEventListener("error", () => addMessage("system: the WebSocket transport reported an error", "system"));
  }
  document.querySelector("[data-chat-reconnect]").addEventListener("click", connectChat);
  chatForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const data = new FormData(chatForm);
    const name = String(data.get("name") || "guest").trim();
    const message = String(data.get("message") || "").trim();
    if (!message) return;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      addMessage("system: reconnect before sending", "system");
      return;
    }
    const payload = `${name}: ${message}`;
    socket.send(payload);
    addMessage(payload, "mine");
    chatForm.elements.message.value = "";
    chatForm.elements.message.focus();
  });
  connectChat();

  const uploadForm = document.querySelector("[data-upload-form]");
  const uploadOutput = document.querySelector("[data-upload-output]");
  const fileLabel = document.querySelector("[data-file-label]");
  uploadForm.elements.file.addEventListener("change", () => {
    const file = uploadForm.elements.file.files[0];
    fileLabel.textContent = file ? `${file.name} · ${file.size.toLocaleString()} bytes` : "Nothing selected yet";
  });
  uploadForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const file = uploadForm.elements.file.files[0];
    if (!file) return;
    uploadOutput.textContent = `streaming ${file.name}…`;
    try {
      const response = await fetch("/upload", { method: "POST", headers: { "Content-Type": file.type || "application/octet-stream" }, body: file });
      uploadOutput.textContent = `${response.status} ${response.statusText} · ${(await response.text()).trim()}`;
    } catch (error) {
      uploadOutput.textContent = `upload failed · ${error.message}`;
    }
  });

  const runtimeState = document.querySelector("[data-runtime-state]");
  const runtimeLabel = document.querySelector("[data-runtime-label]");
  const groupTable = document.querySelector("[data-group-table]");
  const groupWorkers = document.querySelector("[data-group-workers]");
  const groupLabStatus = document.querySelector("[data-group-lab-status]");
  const groupActionButtons = [...document.querySelectorAll("[data-group-action]")];
  const routeTable = document.querySelector("[data-route-table]");
  const middlewareList = document.querySelector("[data-middleware-list]");

  function formatInteger(value) {
    return Number(value).toLocaleString();
  }

  function formatBytes(value) {
    const bytes = Number(value);
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  }

  function cell(row, text, className = "") {
    const item = document.createElement("td");
    item.textContent = text;
    if (className) item.className = className;
    row.append(item);
    return item;
  }

  function renderGroups(groups, lab) {
    groupTable.replaceChildren();
    if (!groups.length) {
      const row = document.createElement("tr");
      const item = cell(row, "No execution group has been created.", "table-empty");
      item.colSpan = 12;
      groupTable.append(row);
      return;
    }
    groups.forEach((group) => {
      const row = document.createElement("tr");
      const labMembers = lab?.workers?.filter((worker) => worker.online && worker.group === group.id) || [];
      if (labMembers.length) {
        row.className = "group-has-lab-worker";
        row.title = `${labMembers.length} migration-lab worker${labMembers.length === 1 ? "" : "s"} currently here`;
      }
      cell(row, String(group.id), "method-cell");
      cell(row, group.state, `state-${group.state}`);
      const members = cell(row, formatInteger(group.members));
      members.title = `${formatInteger(group.pinned)} pinned`;
      cell(row, formatInteger(group.ready));
      cell(row, formatInteger(group.waiting));
      cell(row, formatInteger(group.running));
      cell(row, formatInteger(group.timers));
      cell(row, formatInteger(group.descriptors));
      cell(row, formatInteger(group.files));
      cell(row, formatInteger(group.dispatches));
      cell(row, formatInteger(group.poll_events));
      cell(row, formatInteger(group.wakeups));
      groupTable.append(row);
    });
  }

  function renderMigrationLab(lab) {
    if (!lab) return;
    groupWorkers.replaceChildren();
    lab.workers.forEach((worker) => {
      const item = document.createElement("li");
      if (worker.online) item.className = "online";
      const name = document.createElement("span");
      name.textContent = `worker ${worker.id}`;
      const group = document.createElement("strong");
      group.textContent = worker.online ? `group ${worker.group}` : "offline";
      const moves = document.createElement("small");
      moves.textContent = `${formatInteger(worker.moves)} move${worker.moves === 1 ? "" : "s"}`;
      item.append(name, group, moves);
      groupWorkers.append(item);
    });

    if (!lab.started) {
      groupLabStatus.textContent = "No showcase workers created. The scheduler remains lazy.";
      return;
    }
    const failureText = lab.failures ? ` · ${formatInteger(lab.failures)} failed` : "";
    groupLabStatus.textContent = `${formatInteger(lab.active_workers)} workers online · ${formatInteger(lab.total_moves)} migrations completed${failureText} · last action ${lab.last_action}`;
  }

  groupActionButtons.forEach((button) => {
    button.addEventListener("click", async () => {
      const action = button.dataset.groupAction;
      groupActionButtons.forEach((item) => { item.disabled = true; });
      groupLabStatus.textContent = `${action} in progress…`;
      try {
        const response = await fetch(`/runtime/groups/${action}`, { method: "POST" });
        const result = await response.json();
        if (!response.ok) throw new Error(result.detail || `HTTP ${response.status}`);
        const poolNote = result.configured_groups === 1 ? " · one configured group, so movement is a no-op" : "";
        groupLabStatus.textContent = `${result.action} complete · ${formatInteger(result.workers)} workers · ${formatInteger(result.total_moves)} migrations${poolNote}`;
      } catch (error) {
        groupLabStatus.textContent = `migration action failed · ${error.message}`;
      } finally {
        groupActionButtons.forEach((item) => { item.disabled = false; });
      }
    });
  });

  const runtimeSource = new EventSource("/runtime/events");
  runtimeSource.onopen = () => {
    serverState.dataset.serverState = "online";
    serverLabel.textContent = "server online";
    runtimeState.dataset.runtimeState = "open";
    runtimeLabel.textContent = "runtime feed live";
  };
  runtimeSource.addEventListener("runtime", (event) => {
    const sample = JSON.parse(event.data);
    //  One bounded SSE sample drives both metric summaries. The separate
    //  /metrics JSON handler remains available for tools and direct reads.
    requestMetric.textContent = formatInteger(sample.http.requests);
    activeMetric.textContent = formatInteger(sample.http.active);
    document.querySelector("[data-runtime-lane]").textContent = sample.lane;
    document.querySelector("[data-runtime-cpus]").textContent = formatInteger(sample.cpu_count);
    document.querySelector("[data-runtime-created]").textContent = formatInteger(sample.created_groups);
    document.querySelector("[data-runtime-configured]").textContent = formatInteger(sample.configured_groups);
    const stackValue = document.querySelector("[data-runtime-stacks]");
    stackValue.textContent = formatInteger(sample.stacks.live);
    stackValue.title = `${formatBytes(sample.stacks.usable_bytes)} usable, ${formatBytes(sample.stacks.reserved_bytes)} reserved across ${formatInteger(sample.stacks.arenas)} arenas`;
    document.querySelector("[data-runtime-active]").textContent = formatInteger(sample.http.active);
    document.querySelector("[data-runtime-sequence]").textContent = formatInteger(sample.sequence);
    renderGroups(sample.groups, sample.migration_lab);
    renderMigrationLab(sample.migration_lab);
  });
  runtimeSource.onerror = () => {
    serverState.dataset.serverState = "error";
    serverLabel.textContent = "server stream reconnecting";
    runtimeState.dataset.runtimeState = "error";
    runtimeLabel.textContent = "runtime feed reconnecting";
  };

  async function loadIntrospection() {
    try {
      const response = await fetch("/introspection", { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const registry = await response.json();
      middlewareList.replaceChildren();
      registry.middleware.forEach((middleware, index) => {
        const item = document.createElement("li");
        const order = document.createElement("span");
        order.className = "middleware-order";
        order.textContent = String(index + 1).padStart(2, "0");
        const name = document.createElement("strong");
        name.textContent = middleware.name || "anonymous";
        const stage = document.createElement("small");
        stage.textContent = middleware.stage;
        item.append(order, name, stage);
        middlewareList.append(item);
      });

      document.querySelector("[data-route-count]").textContent = formatInteger(registry.routes.length);
      routeTable.replaceChildren();
      registry.routes.forEach((route) => {
        const row = document.createElement("tr");
        cell(row, route.method, "method-cell");
        cell(row, route.pattern);
        cell(row, route.name, "route-name");
        cell(row, `${route.policy.body} · ${formatBytes(route.policy.max_body)}`, `body-${route.policy.body}`);
        cell(row, route.policy.timeout < 0 ? "server deadline" : `${route.policy.timeout.toFixed(1)} s`);
        const admission = [];
        if (route.policy.concurrency) admission.push(`≤ ${route.policy.concurrency} active`);
        if (route.policy.rate) admission.push(`${route.policy.rate}/s`);
        if (route.policy.authentication !== "none") admission.push(`${route.policy.authentication} auth`);
        if (route.policy.cors_slot) admission.push(`CORS ${route.policy.cors_slot}`);
        if (route.policy.upgrade !== "none") admission.push(route.policy.upgrade);
        cell(row, admission.length ? admission.join(" · ") : "default admission");
        cell(row, route.middleware.length ? route.middleware.map((item) => `${item.name || "anonymous"} (${item.stage})`).join(", ") : "none");
        routeTable.append(row);
      });
    } catch (error) {
      middlewareList.replaceChildren();
      const middlewareError = document.createElement("li");
      middlewareError.textContent = `Registry unavailable: ${error.message}`;
      middlewareList.append(middlewareError);
      routeTable.replaceChildren();
      const row = document.createElement("tr");
      const item = cell(row, `Router registry unavailable: ${error.message}`, "table-empty");
      item.colSpan = 7;
      routeTable.append(row);
    }
  }
  loadIntrospection();

  const endpointOutput = document.querySelector("[data-endpoint-output]");
  const probeResult = document.querySelector("[data-probe-state]");
  const probeTitle = document.querySelector("[data-probe-result-title]");
  const probeClaim = document.querySelector("[data-probe-result-claim]");
  const probeVerdict = document.querySelector("[data-probe-verdict]");
  const probeSource = document.querySelector("[data-probe-source-output]");
  const probeSourceName = document.querySelector("[data-probe-source-name]");

  function transcriptLine(...parts) {
    parts.forEach(([className, value]) => endpointOutput.append(highlightedToken(className, value)));
    endpointOutput.append(document.createTextNode("\n"));
  }

  function transcriptSpace() {
    endpointOutput.append(document.createTextNode("\n"));
  }

  function transcriptHeader(name, value) {
    transcriptLine(["http-header", name], ["http-punctuation", ": "], ["http-value", value]);
  }

  function renderJSONBody(body) {
    let formatted;
    try {
      formatted = JSON.stringify(JSON.parse(body), null, 2);
    } catch (_) {
      endpointOutput.append(highlightedToken("http-body", body));
      return;
    }

    const tokenPattern = /"(?:\\.|[^"\\])*"(?=\s*:)|"(?:\\.|[^"\\])*"|-?\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b|\b(?:true|false|null)\b/gi;
    let cursor = 0;
    for (const match of formatted.matchAll(tokenPattern)) {
      if (match.index > cursor) endpointOutput.append(document.createTextNode(formatted.slice(cursor, match.index)));
      const value = match[0];
      let className = "json-literal";
      if (value.startsWith('"')) className = formatted.slice(match.index + value.length).match(/^\s*:/) ? "json-key" : "json-string";
      else if (/^-?\d/.test(value)) className = "json-number";
      endpointOutput.append(highlightedToken(className, value));
      cursor = match.index + value.length;
    }
    if (cursor < formatted.length) endpointOutput.append(document.createTextNode(formatted.slice(cursor)));
  }

  function renderRequest(endpoint, state) {
    endpointOutput.replaceChildren();
    transcriptLine(["http-label", "REQUEST"]);
    transcriptLine(["http-method", "GET"], ["http-target", ` ${endpoint}`]);
    transcriptSpace();
    transcriptLine(["http-pending", state]);
  }

  async function renderResponse(endpoint, response) {
    const body = await response.text();
    endpointOutput.replaceChildren();
    transcriptLine(["http-label", "REQUEST"]);
    transcriptLine(["http-method", "GET"], ["http-target", ` ${endpoint}`]);
    transcriptSpace();
    transcriptLine(["http-label", "RESPONSE"]);
    transcriptLine(
      ["http-version", "HTTP/1.1 "],
      [response.ok ? "http-status-success" : "http-status-error", String(response.status)],
      ["http-reason", ` ${response.statusText}`]
    );
    transcriptHeader("x-request-id", response.headers.get("x-request-id") || "not returned");
    transcriptHeader("content-type", response.headers.get("content-type") || "not returned");
    transcriptHeader("x-content-type-options", response.headers.get("x-content-type-options") || "not returned");
    transcriptHeader("content-security-policy", response.headers.get("content-security-policy") || "not returned");
    transcriptSpace();
    transcriptLine(["http-label", "BODY"]);
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("json") || /^[\s]*[\[{]/.test(body)) renderJSONBody(body);
    else endpointOutput.append(highlightedToken("http-body", body));
  }

  document.querySelectorAll("[data-endpoint]").forEach((button) => {
    button.addEventListener("click", async () => {
      const endpoint = button.dataset.endpoint;
      const expectedStatus = Number(button.dataset.expectedStatus);
      const probeItem = button.closest(".probe-item");
      const sourceTemplate = probeItem.querySelector("template[data-probe-source]");
      document.querySelectorAll("[data-endpoint]").forEach((candidate) => candidate.setAttribute("aria-pressed", String(candidate === button)));
      probeItem.append(probeResult);
      probeResult.hidden = false;
      probeTitle.textContent = button.dataset.probeTitle;
      probeClaim.textContent = button.dataset.probeClaim;
      probeSource.textContent = sourceTemplate.content.textContent.trim();
      probeSourceName.textContent = `${endpoint} handler`;
      highlightAda(probeSource);
      probeResult.dataset.probeState = "running";
      probeVerdict.textContent = "request in flight";
      renderRequest(endpoint, "Waiting for the server…");
      const headers = button.dataset.token ? { Authorization: `Bearer ${button.dataset.token}` } : {};
      try {
        const response = await fetch(endpoint, { headers, cache: "no-store" });
        const matched = response.status === expectedStatus;
        probeResult.dataset.probeState = matched ? "verified" : "unexpected";
        probeVerdict.textContent = matched ? `expected HTTP ${expectedStatus} observed` : `expected HTTP ${expectedStatus}, observed HTTP ${response.status}`;
        await renderResponse(endpoint, response);
      } catch (error) {
        probeResult.dataset.probeState = "unexpected";
        probeVerdict.textContent = "transport failed before an HTTP response arrived";
        endpointOutput.replaceChildren();
        transcriptLine(["http-label", "REQUEST"]);
        transcriptLine(["http-method", "GET"], ["http-target", ` ${endpoint}`]);
        transcriptSpace();
        transcriptLine(["http-label", "TRANSPORT ERROR"]);
        transcriptLine(["http-status-error", error.message]);
      }
    });
  });
})();
