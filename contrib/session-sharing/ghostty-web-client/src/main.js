import { FitAddon, init, Terminal } from "ghostty-web";

const DEFAULT_TITLE = "Ghostty Session Sharing";
const SESSION_QUERY_KEY = "session";
const SESSION_POLL_INTERVAL_MS = 15_000;

const shell = document.querySelector("#shell");
const launcherView = document.querySelector("#launcherView");
const terminalView = document.querySelector("#terminalView");
const terminalStatus = document.querySelector("#terminalStatus");
const backendBaseInput = document.querySelector("#backendBase");
const tokenInput = document.querySelector("#token");
const saveTokenButton = document.querySelector("#saveToken");
const sessionList = document.querySelector("#sessionList");
const sessionMeta = document.querySelector("#sessionMeta");
const terminalMount = document.querySelector("#terminal");
const mobileInput = document.querySelector("#mobileInput");
const mobileToolbar = document.querySelector("#mobileToolbar");
const mobileToolbarToggle = document.querySelector("#mobileToolbarToggle");

let terminal = null;
let fitAddon = null;
let resizeObserver = null;
let socket = null;
let activeSession = null;
let activeSessionId = null;
let cachedSessions = [];
let reconnectTimer = null;
let reconnectAttempt = 0;
let shouldReconnect = false;
let reconnectStatusText = null;
let mobileToolbarCollapsed = false;
let pendingCtrlModifier = false;
let pendingAltModifier = false;
let isMobileComposing = false;
let mobileFocusTimer = null;
let sessionPollTimer = null;

backendBaseInput.value = localStorage.getItem("ghostty-sharing-backend-base") ?? location.origin;
tokenInput.value = localStorage.getItem("ghostty-sharing-token") ?? "";

saveTokenButton.addEventListener("click", async () => {
  localStorage.setItem("ghostty-sharing-backend-base", backendBaseInput.value.trim());
  localStorage.setItem("ghostty-sharing-token", tokenInput.value.trim());
  await refreshSessions();
  scheduleSessionRefresh();
});

function resolvedBackendBase() {
  const configured = backendBaseInput.value.trim();
  return configured || location.origin;
}

function normalizedHttpBase() {
  const candidate = resolvedBackendBase();
  const parsed = new URL(candidate, location.origin);
  if (parsed.protocol === "ws:") parsed.protocol = "http:";
  if (parsed.protocol === "wss:") parsed.protocol = "https:";
  return parsed;
}

function apiURL(pathname) {
  const url = normalizedHttpBase();
  url.pathname = pathname;
  url.search = "";
  url.hash = "";
  return url;
}

function wsBaseURL(pathname) {
  const parsed = new URL(resolvedBackendBase(), location.origin);
  if (parsed.protocol === "http:") parsed.protocol = "ws:";
  else if (parsed.protocol === "https:") parsed.protocol = "wss:";
  else if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
    parsed.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  }
  parsed.pathname = pathname;
  parsed.search = "";
  parsed.hash = "";
  return parsed;
}

async function ensureTerminal() {
  if (terminal) return terminal;
  await init();
  terminal = new Terminal({
    fontSize: 14,
    cursorBlink: true,
    theme: {
      background: "#171412",
      foreground: "#f5f0e8",
    },
  });
  terminal.open(terminalMount);
  fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  fitAddon.fit();
  fitAddon.observeResize();
  focusTerminal();
  terminal.onData((data) => {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(data);
    }
  });
  terminal.onResize(({ cols, rows }) => {
    sendControlFrame({ type: "resize", id: activeSession?.id ?? "", cols, rows });
  });
  resizeObserver = new ResizeObserver(() => {
    if (!fitAddon) return;
    fitAddon.fit();
  });
  resizeObserver.observe(terminalMount);
  return terminal;
}

async function refreshSessions() {
  const token = tokenInput.value.trim();
  sessionList.innerHTML = "";
  sessionMeta.textContent = token ? "加载中..." : "缺少用户令牌";
  if (!token) return;

  try {
    const response = await fetch(apiURL("/api/sessions"), {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    if (!response.ok) {
      sessionMeta.textContent = `请求失败 (${response.status})`;
      return;
    }

    const sessions = sortSessions(await response.json());
    cachedSessions = sessions;
    const onlineCount = sessions.filter((session) => session.online).length;
    sessionMeta.textContent = `${onlineCount} 在线 / ${sessions.length} 个会话`;
    for (const session of sessions) {
      sessionList.append(renderSession(session));
    }

    if (activeSessionId) {
      const updatedActiveSession = sessions.find((session) => session.id === activeSessionId);
      if (updatedActiveSession) {
        activeSession = updatedActiveSession;
      }
    }

    const requestedSessionID = currentRequestedSessionID();
    if (requestedSessionID && !activeSessionId) {
      const requestedSession = sessions.find((session) => session.id === requestedSessionID);
      if (requestedSession?.online) {
        await connectToSession(requestedSession, { updateHistory: false });
      } else if (requestedSession) {
        sessionMeta.textContent = "目标会话当前离线";
      } else {
        sessionMeta.textContent = "目标会话不存在或已过期";
      }
    }
  } catch (error) {
    console.error(error);
    sessionMeta.textContent = "请求失败";
  }
}

function scheduleSessionRefresh() {
  if (sessionPollTimer !== null) {
    window.clearTimeout(sessionPollTimer);
  }
  sessionPollTimer = window.setTimeout(async () => {
    sessionPollTimer = null;
    await refreshSessions();
    scheduleSessionRefresh();
  }, SESSION_POLL_INTERVAL_MS);
}

function renderSession(session) {
  const activityText = formatLastSeen(session.last_seen_at);
  const displayName = displaySessionName(session);
  const item = document.createElement("button");
  item.type = "button";
  item.className = [
    "session",
    session.online ? "" : "offline",
    session.id === activeSessionId ? "active" : "",
  ].filter(Boolean).join(" ");
  item.innerHTML = `
    <div style="font-size: 12px; color: #6d655c;">会话名称：${escapeHtml(displayName)}</div>
    <div style="margin-top: 6px; font-size: 12px; color: #6d655c;">会话 ID：${escapeHtml(session.id)}</div>
    <div style="margin-top: 4px; font-size: 12px; color: #6d655c;">最近活动：${escapeHtml(activityText)}</div>
    <div class="status ${session.online ? "online" : "offline"}">${session.online ? "在线" : "离线"}</div>
  `;
  if (session.online) {
    item.addEventListener("click", () => connectToSession(session));
  } else {
    item.disabled = true;
  }
  return item;
}

function sortSessions(sessions) {
  return [...sessions].sort((left, right) => {
    if (left.online !== right.online) {
      return left.online ? -1 : 1;
    }

    const rightTime = timestampForSort(right.last_seen_at);
    const leftTime = timestampForSort(left.last_seen_at);
    if (rightTime !== leftTime) {
      return rightTime - leftTime;
    }

    return displaySessionName(left).localeCompare(displaySessionName(right), "zh-CN");
  });
}

function displaySessionName(session) {
  const name = typeof session.name === "string" ? session.name.trim() : "";
  return name || "未命名会话";
}

function timestampForSort(value) {
  if (!value) return 0;
  const time = new Date(value).getTime();
  return Number.isNaN(time) ? 0 : time;
}

async function connectToSession(session, { updateHistory = true } = {}) {
  try {
    const url = wsBaseURL("/ws/client");
    url.searchParams.set("id", session.id);
    url.searchParams.set("token", session.client_token);

    cancelReconnect();
    if (socket) {
      socket.close();
      socket = null;
    }

    shouldReconnect = true;
    activeSession = session;
    activeSessionId = session.id;
    enterTerminalView(session, { updateHistory });
    document.title = session.name;
    setTerminalStatus("连接中");
    const term = await ensureTerminal();
    term.reset();
    focusTerminal();
    rerenderSessionSelection();

    socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";

    socket.addEventListener("open", () => {
      reconnectAttempt = 0;
      if (fitAddon) fitAddon.fit();
      focusTerminal();
      updateDocumentTitle();
      setTerminalStatus("已连接", "connected");
      sendControlFrame({
        type: "resize",
        id: session.id,
        cols: term.cols,
        rows: term.rows,
      });
    });

    socket.addEventListener("close", (event) => {
      socket = null;
      scheduleReconnect(classifyCloseEvent(event));
    });

    socket.addEventListener("error", () => {
      updateDocumentTitle("连接错误");
      setTerminalStatus("连接错误", "error");
    });

    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        handleControlFrame(event.data);
        return;
      }

      const bytes = new Uint8Array(event.data);
      term.write(bytes);
      if (shouldUseMobileInput()) {
        window.setTimeout(scrollTerminalToBottom, 0);
      }
    });
  } catch (error) {
    console.error(error);
    terminalMount.textContent = String(error);
  }
}

function handleControlFrame(data) {
  let frame;
  try {
    frame = JSON.parse(data);
  } catch {
    if (terminal) terminal.write(data);
    return;
  }

  switch (frame.type) {
    case "hello":
      if (frame.name && activeSession) {
        activeSession = { ...activeSession, name: frame.name };
      }
      updateDocumentTitle();
      if (Number.isInteger(frame.cols) && Number.isInteger(frame.rows) && terminal) {
        terminal.resize(frame.cols, frame.rows);
      }
      return;
    case "resize":
      if (Number.isInteger(frame.cols) && Number.isInteger(frame.rows) && terminal) {
        terminal.resize(frame.cols, frame.rows);
      }
      return;
    case "ping":
      if (socket && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ type: "pong", id: activeSession?.id ?? "" }));
      }
      return;
    case "pong":
      return;
    default:
      if (terminal) terminal.write(data);
  }
}

function sendControlFrame(frame) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify(frame));
}

function controlCharacterFor(value) {
  if (!value || value.length !== 1) return value;
  const code = value.toUpperCase().charCodeAt(0);
  if (code >= 64 && code <= 95) {
    return String.fromCharCode(code - 64);
  }
  if (value === " ") {
    return "\u0000";
  }
  return value;
}

function applyPendingModifiers(value) {
  let output = value;
  if (pendingCtrlModifier && value.length === 1) {
    output = controlCharacterFor(value);
  }
  if (pendingAltModifier) {
    output = `\u001b${output}`;
  }
  pendingCtrlModifier = false;
  pendingAltModifier = false;
  syncModifierButtons();
  return output;
}

// The relay uses these private WebSocket close codes for cases the client
// can act on. They mirror server.py: 4401 = session token expired
// (watch_token_expiry), 4408 = ping timeout / slow consumer drop.
const CLOSE_CODE_TOKEN_EXPIRED = 4401;
const CLOSE_CODE_TIMEOUT_OR_SLOW = 4408;

function classifyCloseEvent(event) {
  if (event && event.code === CLOSE_CODE_TOKEN_EXPIRED) {
    return {
      reason: "token_expired",
      statusText: "会话已过期，等待主机重新建立",
      slowPoll: true,
    };
  }
  if (event && event.code === CLOSE_CODE_TIMEOUT_OR_SLOW) {
    return {
      reason: "ping_timeout",
      statusText: "心跳断开，重连中",
      slowPoll: false,
    };
  }
  return { reason: "other", statusText: null, slowPoll: false };
}

function scheduleReconnect(closeContext = null) {
  if (!shouldReconnect || !activeSession) return;
  cancelReconnect();
  reconnectAttempt += 1;
  updateDocumentTitle("重连中");

  let delay;
  let statusText;
  if (closeContext?.slowPoll) {
    // Token-expired close: the host must re-register before any reconnect
    // can succeed. Poll the session list at a steady cadence (capped at
    // 10 s) instead of ramping an exponential backoff that would burn
    // pointless API calls and delay recovery once the host comes back.
    delay = Math.min(2000 + 1000 * (reconnectAttempt - 1), 10000);
    statusText = closeContext.statusText;
  } else {
    delay = Math.min(1000 * (2 ** Math.max(0, reconnectAttempt - 1)), 30000);
    const fallback = delay >= 1000 ? `重连中（${Math.round(delay / 1000)}s）` : "重连中";
    statusText = closeContext?.statusText ?? fallback;
  }
  reconnectStatusText = statusText;
  setTerminalStatus(reconnectStatusText, "reconnecting");
  reconnectTimer = window.setTimeout(async () => {
    reconnectTimer = null;
    if (!activeSession) return;

    const token = tokenInput.value.trim();
    if (!token) return;

    try {
      const response = await fetch(apiURL("/api/sessions"), {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
      if (!response.ok) {
        scheduleReconnect(closeContext);
        return;
      }

      const sessions = await response.json();
      cachedSessions = sessions;
      const session = sessions.find((candidate) => candidate.id === activeSessionId);
      if (!session?.online) {
        scheduleReconnect(closeContext);
        return;
      }

      await connectToSession(session, { updateHistory: false });
    } catch (error) {
      console.error(error);
      scheduleReconnect(closeContext);
    }
  }, delay);
}

function cancelReconnect() {
  if (reconnectTimer !== null) {
    window.clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  reconnectStatusText = null;
}

function updateDocumentTitle(status = null) {
  const base = activeSession?.name ?? DEFAULT_TITLE;
  document.title = status ? `${base} · ${status}` : base;
}

function enterTerminalView(session, { updateHistory = true } = {}) {
  shell.classList.add("terminal-mode");
  document.body.classList.add("terminal-mode");
  launcherView.classList.add("hidden");
  terminalView.classList.remove("hidden");
  document.title = session.name;
  window.scrollTo(0, 0);

  if (updateHistory) {
    const url = new URL(window.location.href);
    url.searchParams.set(SESSION_QUERY_KEY, session.id);
    window.history.pushState({ sessionID: session.id }, "", url);
  }

  requestAnimationFrame(() => {
    if (fitAddon) fitAddon.fit();
    focusTerminal();
    window.scrollTo(0, 0);
  });
}

function leaveTerminalView({ updateHistory = true } = {}) {
  shouldReconnect = false;
  cancelReconnect();
  activeSession = null;
  activeSessionId = null;
  pendingCtrlModifier = false;
  pendingAltModifier = false;
  if (socket) {
    socket.close();
    socket = null;
  }

  shell.classList.remove("terminal-mode");
  document.body.classList.remove("terminal-mode");
  launcherView.classList.remove("hidden");
  terminalView.classList.add("hidden");
  document.title = DEFAULT_TITLE;
  hideTerminalStatus();
  syncModifierButtons();
  rerenderSessionSelection();

  if (updateHistory) {
    const url = new URL(window.location.href);
    url.searchParams.delete(SESSION_QUERY_KEY);
    window.history.pushState({}, "", url);
  }
}

function currentRequestedSessionID() {
  const url = new URL(window.location.href);
  return url.searchParams.get(SESSION_QUERY_KEY);
}

function rerenderSessionSelection() {
  for (const node of sessionList.querySelectorAll(".session")) {
    const idNode = node.querySelector("div:nth-child(2)");
    if (!idNode) continue;
    const id = idNode.textContent.trim();
    node.classList.toggle("active", id === activeSessionId);
  }
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function formatLastSeen(value) {
  if (!value) return "未知";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "未知";

  const diff = Date.now() - date.getTime();
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return `${Math.max(1, Math.floor(diff / 60_000))} 分钟前`;
  if (diff < 86_400_000) return `${Math.max(1, Math.floor(diff / 3_600_000))} 小时前`;

  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function focusTerminal() {
  if (shouldUseMobileInput()) {
    if (mobileFocusTimer !== null) {
      window.clearTimeout(mobileFocusTimer);
      mobileFocusTimer = null;
    }
    mobileInput.focus({ preventScroll: true });
    return;
  }
  if (terminal) terminal.focus();
}

function scrollTerminalToBottom() {
  if (!terminal) return;
  if (typeof terminal.scrollToBottom === "function") {
    terminal.scrollToBottom();
  }
}

function scheduleMobileRefocus() {
  if (!shouldUseMobileInput() || !activeSessionId || document.hidden) return;
  if (mobileFocusTimer !== null) {
    window.clearTimeout(mobileFocusTimer);
  }
  mobileFocusTimer = window.setTimeout(() => {
    mobileFocusTimer = null;
    if (!activeSessionId || document.hidden) return;
    focusTerminal();
  }, 60);
}

function setTerminalStatus(text, kind = null) {
  terminalStatus.textContent = text;
  terminalStatus.classList.remove("hidden", "connected", "reconnecting", "error");
  if (kind) {
    terminalStatus.classList.add(kind);
  }
}

function hideTerminalStatus() {
  terminalStatus.classList.add("hidden");
  terminalStatus.classList.remove("connected", "reconnecting", "error");
}

function shouldUseMobileInput() {
  return window.matchMedia("(pointer: coarse)").matches || window.matchMedia("(max-width: 860px)").matches;
}

function sendInput(data) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !data) return;
  socket.send(data);
}

function syncModifierButtons() {
  for (const button of mobileToolbar.querySelectorAll("[data-modifier]")) {
    const modifier = button.dataset.modifier;
    const active = (modifier === "ctrl" && pendingCtrlModifier)
      || (modifier === "alt" && pendingAltModifier);
    button.classList.toggle("mod-active", active);
  }
}

function setMobileToolbarCollapsed(collapsed) {
  mobileToolbarCollapsed = collapsed;
  mobileToolbar.classList.toggle("hidden", collapsed);
  mobileToolbarToggle.classList.toggle("collapsed", collapsed);
  mobileToolbarToggle.classList.toggle("hidden", !shouldUseMobileInput());
  syncMobileViewportInsets();
}

function toggleMobileToolbar() {
  setMobileToolbarCollapsed(!mobileToolbarCollapsed);
  focusTerminal();
}

function toolbarSequence(name) {
  switch (name) {
    case "esc":
      return "\u001b";
    case "backspace":
      return "\u007f";
    default:
      return name;
  }
}

function toolbarKeyDefinition(name) {
  switch (name) {
    case "esc":
      return { key: "Escape", code: "Escape" };
    case "tab":
      return { key: "Tab", code: "Tab" };
    case "home":
      return { key: "Home", code: "Home" };
    case "up":
      return { key: "ArrowUp", code: "ArrowUp" };
    case "end":
      return { key: "End", code: "End" };
    case "pageup":
      return { key: "PageUp", code: "PageUp" };
    case "left":
      return { key: "ArrowLeft", code: "ArrowLeft" };
    case "down":
      return { key: "ArrowDown", code: "ArrowDown" };
    case "right":
      return { key: "ArrowRight", code: "ArrowRight" };
    case "pagedown":
      return { key: "PageDown", code: "PageDown" };
    case "backspace":
      return { key: "Backspace", code: "Backspace" };
    default:
      return null;
  }
}

function sendToolbarKeyEvent(name) {
  if (!terminal) return false;
  const key = toolbarKeyDefinition(name);
  if (!key) return false;

  const event = new KeyboardEvent("keydown", {
    key: key.key,
    code: key.code,
    ctrlKey: pendingCtrlModifier,
    altKey: pendingAltModifier,
    bubbles: true,
    cancelable: true,
  });

  pendingCtrlModifier = false;
  pendingAltModifier = false;
  syncModifierButtons();
  terminalMount.dispatchEvent(event);
  return true;
}

function syncMobileViewportInsets() {
  const mobile = shouldUseMobileInput();
  const viewportHeight = mobile && window.visualViewport
    ? `${window.visualViewport.height}px`
    : `${window.innerHeight}px`;
  document.documentElement.style.setProperty("--mobile-viewport-height", viewportHeight);

  const toolbarHeight = mobile && !mobileToolbarCollapsed ? `${mobileToolbar.offsetHeight || 112}px` : "0px";
  document.documentElement.style.setProperty("--mobile-toolbar-height", toolbarHeight);

  let keyboardOffset = 0;
  if (mobile && window.visualViewport) {
    keyboardOffset = Math.max(
      0,
      window.innerHeight - window.visualViewport.height - window.visualViewport.offsetTop
    );
  }
  document.documentElement.style.setProperty("--mobile-toolbar-offset", `${keyboardOffset}px`);

  if (fitAddon) {
    window.requestAnimationFrame(() => {
      fitAddon.fit();
      scrollTerminalToBottom();
    });
  }
  if (mobile || activeSessionId) {
    window.scrollTo(0, 0);
  }
}

terminalView.addEventListener("touchstart", focusTerminal, { passive: true });
terminalView.addEventListener("pointerdown", () => {
  if (shouldUseMobileInput()) {
    window.setTimeout(focusTerminal, 0);
  }
});
window.addEventListener("focus", focusTerminal);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") focusTerminal();
});

mobileInput.addEventListener("input", () => {
  if (isMobileComposing) return;
  if (!mobileInput.value) return;
  sendInput(applyPendingModifiers(mobileInput.value));
  mobileInput.value = "";
  window.setTimeout(scrollTerminalToBottom, 0);
  scheduleMobileRefocus();
});

mobileInput.addEventListener("compositionstart", () => {
  isMobileComposing = true;
});

mobileInput.addEventListener("compositionend", () => {
  isMobileComposing = false;
  if (!mobileInput.value) return;
  sendInput(applyPendingModifiers(mobileInput.value));
  mobileInput.value = "";
  window.setTimeout(scrollTerminalToBottom, 0);
  scheduleMobileRefocus();
});

mobileInput.addEventListener("keydown", (event) => {
  switch (event.key) {
    case "Enter":
      event.preventDefault();
      sendInput(applyPendingModifiers("\r"));
      mobileInput.value = "";
      window.setTimeout(scrollTerminalToBottom, 0);
      scheduleMobileRefocus();
      break;
    case "Tab":
      event.preventDefault();
      sendInput(applyPendingModifiers("\t"));
      mobileInput.value = "";
      window.setTimeout(scrollTerminalToBottom, 0);
      scheduleMobileRefocus();
      break;
    case "Backspace":
      if (mobileInput.value.length === 0) {
        sendInput(applyPendingModifiers("\u007f"));
      }
      window.setTimeout(scrollTerminalToBottom, 0);
      scheduleMobileRefocus();
      break;
    default:
      break;
  }
});

mobileInput.addEventListener("blur", () => {
  scheduleMobileRefocus();
});

mobileToolbarToggle.addEventListener("click", toggleMobileToolbar);

mobileToolbar.addEventListener("click", (event) => {
  const button = event.target.closest(".mobile-tool");
  if (!button) return;

  const modifier = button.dataset.modifier;
  if (modifier === "ctrl") {
    pendingCtrlModifier = !pendingCtrlModifier;
    syncModifierButtons();
    focusTerminal();
    return;
  }
  if (modifier === "alt") {
    pendingAltModifier = !pendingAltModifier;
    syncModifierButtons();
    focusTerminal();
    return;
  }

  if (sendToolbarKeyEvent(button.dataset.seq)) {
    scrollTerminalToBottom();
    focusTerminal();
    return;
  }

  const sequence = toolbarSequence(button.dataset.seq);
  sendInput(applyPendingModifiers(sequence));
  focusTerminal();
});

window.addEventListener("resize", () => {
  if (!shouldUseMobileInput()) {
    mobileToolbarToggle.classList.add("hidden");
    syncMobileViewportInsets();
    scrollTerminalToBottom();
    return;
  }
  mobileToolbarToggle.classList.remove("hidden");
  syncMobileViewportInsets();
});

if (window.visualViewport) {
  window.visualViewport.addEventListener("resize", syncMobileViewportInsets);
  window.visualViewport.addEventListener("scroll", syncMobileViewportInsets);
}

window.addEventListener("popstate", async () => {
  const requestedSessionID = currentRequestedSessionID();
  if (!requestedSessionID) {
    leaveTerminalView({ updateHistory: false });
    return;
  }

  const session = cachedSessions.find((candidate) => candidate.id === requestedSessionID);
  if (session?.online) {
    await connectToSession(session, { updateHistory: false });
  }
});

setMobileToolbarCollapsed(false);
syncMobileViewportInsets();
refreshSessions();
