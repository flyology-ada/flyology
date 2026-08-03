(() => {
  const root = document.documentElement;
  const storedTheme = localStorage.getItem("flyology-demo-theme");
  if (storedTheme === "dark" || storedTheme === "light") root.dataset.theme = storedTheme;

  document.querySelector("[data-theme-toggle]").addEventListener("click", () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
    localStorage.setItem("flyology-demo-theme", root.dataset.theme);
  });

  document.querySelector("[data-origin]").textContent = location.host;
  const serverState = document.querySelector("[data-server-state]");
  const serverLabel = document.querySelector("[data-server-label]");
  const requestMetric = document.querySelector("[data-metric-requests]");
  const activeMetric = document.querySelector("[data-metric-active]");

  async function refreshMetrics() {
    try {
      const response = await fetch("/metrics", { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const metrics = await response.json();
      requestMetric.textContent = metrics.requests;
      activeMetric.textContent = metrics.active;
      serverState.dataset.serverState = "online";
      serverLabel.textContent = "server online";
    } catch (_) {
      serverState.dataset.serverState = "error";
      serverLabel.textContent = "server unavailable";
    }
  }
  refreshMetrics();
  setInterval(refreshMetrics, 3000);

  let eventSource;
  const eventLog = document.querySelector("[data-event-log]");
  const sseState = document.querySelector("[data-sse-state]");
  const sseLabel = document.querySelector("[data-sse-label]");

  function setSSEState(state, label) {
    sseState.dataset.sseState = state;
    sseLabel.textContent = label;
  }

  function connectEvents() {
    if (eventSource) eventSource.close();
    eventLog.replaceChildren();
    setSSEState("waiting", "opening event stream");
    eventSource = new EventSource("/events");
    eventSource.onopen = () => setSSEState("open", "stream connected");
    eventSource.addEventListener("flight", (event) => {
      const value = JSON.parse(event.data);
      const item = document.createElement("li");
      const sequence = document.createElement("span");
      sequence.className = "event-sequence";
      sequence.textContent = String(value.sequence).padStart(2, "0");
      const copy = document.createElement("div");
      copy.className = "event-copy";
      const title = document.createElement("strong");
      title.textContent = value.phase;
      const detail = document.createElement("span");
      detail.textContent = value.detail;
      copy.append(title, detail);
      const time = document.createElement("time");
      time.className = "event-time";
      time.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      item.append(sequence, copy, time);
      eventLog.append(item);
      eventLog.scrollTop = eventLog.scrollHeight;
    });
    eventSource.addEventListener("complete", () => {
      setSSEState("open", "flight complete");
      eventSource.close();
    });
    eventSource.onerror = () => setSSEState("error", "stream interrupted");
  }
  document.querySelector("[data-sse-reconnect]").addEventListener("click", connectEvents);
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

  function renderGroups(groups) {
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

  const runtimeSource = new EventSource("/runtime/events");
  runtimeSource.onopen = () => {
    runtimeState.dataset.runtimeState = "open";
    runtimeLabel.textContent = "runtime feed live";
  };
  runtimeSource.addEventListener("runtime", (event) => {
    const sample = JSON.parse(event.data);
    document.querySelector("[data-runtime-lane]").textContent = sample.lane;
    document.querySelector("[data-runtime-cpus]").textContent = formatInteger(sample.cpu_count);
    document.querySelector("[data-runtime-created]").textContent = formatInteger(sample.created_groups);
    document.querySelector("[data-runtime-configured]").textContent = formatInteger(sample.configured_groups);
    const stackValue = document.querySelector("[data-runtime-stacks]");
    stackValue.textContent = formatInteger(sample.stacks.live);
    stackValue.title = `${formatBytes(sample.stacks.usable_bytes)} usable, ${formatBytes(sample.stacks.reserved_bytes)} reserved across ${formatInteger(sample.stacks.arenas)} arenas`;
    document.querySelector("[data-runtime-active]").textContent = formatInteger(sample.http.active);
    document.querySelector("[data-runtime-sequence]").textContent = formatInteger(sample.sequence);
    renderGroups(sample.groups);
  });
  runtimeSource.onerror = () => {
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
  document.querySelectorAll("[data-endpoint]").forEach((button) => {
    button.addEventListener("click", async () => {
      const endpoint = button.dataset.endpoint;
      const expectedStatus = Number(button.dataset.expectedStatus);
      document.querySelectorAll("[data-endpoint]").forEach((candidate) => candidate.setAttribute("aria-pressed", String(candidate === button)));
      probeTitle.textContent = button.dataset.probeTitle;
      probeClaim.textContent = button.dataset.probeClaim;
      probeResult.dataset.probeState = "running";
      probeVerdict.textContent = "request in flight";
      endpointOutput.textContent = `REQUEST\nGET ${endpoint}\n\nWaiting for the server…`;
      const headers = button.dataset.token ? { Authorization: `Bearer ${button.dataset.token}` } : {};
      try {
        const response = await fetch(endpoint, { headers, cache: "no-store" });
        const matched = response.status === expectedStatus;
        probeResult.dataset.probeState = matched ? "verified" : "unexpected";
        probeVerdict.textContent = matched ? `expected HTTP ${expectedStatus} observed` : `expected HTTP ${expectedStatus}, observed HTTP ${response.status}`;
        endpointOutput.textContent = `REQUEST\nGET ${endpoint}\n\nRESPONSE\nHTTP/1.1 ${response.status} ${response.statusText}\nrequest-id: ${response.headers.get("x-request-id") || "not returned"}\ncontent-type: ${response.headers.get("content-type") || "not returned"}\nx-content-type-options: ${response.headers.get("x-content-type-options") || "not returned"}\ncontent-security-policy: ${response.headers.get("content-security-policy") || "not returned"}\n\nBODY\n${await response.text()}`;
      } catch (error) {
        probeResult.dataset.probeState = "unexpected";
        probeVerdict.textContent = "transport failed before an HTTP response arrived";
        endpointOutput.textContent = `REQUEST\nGET ${endpoint}\n\nTRANSPORT ERROR\n${error.message}`;
      }
    });
  });
})();
