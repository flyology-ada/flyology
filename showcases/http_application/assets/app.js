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

  const endpointOutput = document.querySelector("[data-endpoint-output]");
  document.querySelectorAll("[data-endpoint]").forEach((button) => {
    button.addEventListener("click", async () => {
      const endpoint = button.dataset.endpoint;
      endpointOutput.textContent = `GET ${endpoint}\nwaiting…`;
      const headers = button.dataset.token ? { Authorization: `Bearer ${button.dataset.token}` } : {};
      try {
        const response = await fetch(endpoint, { headers, cache: "no-store" });
        endpointOutput.textContent = `GET ${endpoint}\n${response.status} ${response.statusText}\nrequest-id: ${response.headers.get("x-request-id") || "not returned"}\n\n${await response.text()}`;
      } catch (error) {
        endpointOutput.textContent = `GET ${endpoint}\nrequest failed: ${error.message}`;
      }
    });
  });
})();
