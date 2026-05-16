import { FitAddon, init, Terminal } from "ghostty-web";
import { buildAppearanceTheme } from "./appearance.js";
import { redactErrorMessage } from "./redaction.js";
import { createCoalescedScroll } from "./scroll.js";
import { createReplayBuffer } from "./scrollback.js";

const DEFAULT_TITLE = "Ghostty Session Sharing";
const SESSION_QUERY_KEY = "session";
const SESSION_POLL_INTERVAL_MS = 15_000;

const shell = document.querySelector("#shell");
const launcherView = document.querySelector("#launcherView");
const launcherHomeView = document.querySelector("#launcherHomeView");
const launcherSettingsView = document.querySelector("#launcherSettingsView");
const openSettingsButton = document.querySelector("#openSettings");
const closeSettingsButton = document.querySelector("#closeSettings");
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
const lockHostSizeInput = document.querySelector("#lockHostSize");
const desktopWidthInput = document.querySelector("#desktopWidth");
const liveMirrorModeInput = document.querySelector("#liveMirrorMode");
const debugModeInput = document.querySelector("#debugMode");

let terminal = null;
let fitAddon = null;
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
const replayBuffer = createReplayBuffer();
// Latest host grid rows announced via `hello`. We need this to know
// how many rows of the snapshot are "viewport" vs "history" so the
// next fetch_scrollback request can set `before` correctly.
let hostRows = 24;
let hostCols = 80;
// True once we've heard the agent's first `hello`. Until then the
// `hostCols`/`hostRows` defaults are placeholders, so the
// lock-host-size snap-back has to wait or it would freeze the
// browser at 80x24 even when the host is bigger.
let helloReceived = false;
const SCROLLBACK_FETCH_BATCH = 200;
// Distance from the top of currently-loaded scrollback at which we
// fire the next fetch. Bumped from 10 to 50 so a fast swipe / drag
// doesn't bottom out before the older batch lands; 50 ≈ 2 swipe
// gestures of head-room on a phone.
const SCROLLBACK_TOP_TRIGGER_LINES = 50;
const LOCK_HOST_SIZE_KEY = "ghostty-sharing-lock-host-size";
const DESKTOP_WIDTH_KEY = "ghostty-sharing-desktop-width";
// Live-mirror mode: when on, we skip the replayBuffer accumulation and
// the lazy `fetch_scrollback` path entirely. The terminal only renders
// the host's current viewport plus live deltas. Default off so existing
// desktop users keep their lazy-history scrollback; mobile users can opt
// in once and the localStorage value persists.
const LIVE_MIRROR_KEY = "ghostty-sharing-live-mirror";
// Debug instrumentation toggle. When off (default), the debug bar isn't
// mounted and logEvt is a no-op — zero runtime cost. When on, we mount
// the top-of-screen log bar, wire scroll/ResizeObserver listeners, and
// every logEvt call records into a ring buffer downloadable via the
// "DL" button. Toggling requires a reload because the debug
// infrastructure (capture-phase listeners, ResizeObserver) is wired
// once at module init.
const DEBUG_MODE_KEY = "ghostty-sharing-debug";

backendBaseInput.value =
  localStorage.getItem("ghostty-sharing-backend-base") ?? location.origin;
tokenInput.value = localStorage.getItem("ghostty-sharing-token") ?? "";
lockHostSizeInput.checked = localStorage.getItem(LOCK_HOST_SIZE_KEY) === "1";
desktopWidthInput.checked = localStorage.getItem(DESKTOP_WIDTH_KEY) === "1";
liveMirrorModeInput.checked = localStorage.getItem(LIVE_MIRROR_KEY) === "1";
const debugEnabled = localStorage.getItem(DEBUG_MODE_KEY) === "1";
debugModeInput.checked = debugEnabled;
debugModeInput.addEventListener("change", () => {
  localStorage.setItem(DEBUG_MODE_KEY, debugModeInput.checked ? "1" : "0");
});

// Mirror-mode flag captured at connect time. The user can toggle the
// checkbox mid-session; we update this immediately so all the gates
// (replayBuffer feeding, fetch_scrollback dispatch, scrollback frame
// handling) flip together. Toggling A→B mid-session only captures
// history from that point forward — the older content is gone, which
// is documented in the launcher help text.
let activeMirrorMode = false;

saveTokenButton.addEventListener("click", async () => {
  localStorage.setItem(
    "ghostty-sharing-backend-base",
    backendBaseInput.value.trim(),
  );
  localStorage.setItem("ghostty-sharing-token", tokenInput.value.trim());
  // After save: jump to the session list only if a token is now present.
  // Without a token the list can't load anything, so we stay on the
  // settings page so the user can finish the only thing that matters.
  if (tokenInput.value.trim()) {
    showLauncherHome();
  }
  await refreshSessions();
  scheduleSessionRefresh();
});

function hasUserToken() {
  return Boolean(tokenInput.value.trim());
}

// Toggle between the home (session list) sub-view and the settings
// sub-view. The terminal view is unaffected — these only matter while
// the user is in the launcher. We disable the "返回" button when no
// token is configured so the user can't escape the settings page into
// an empty session list.
function showLauncherSettings() {
  launcherHomeView.classList.add("hidden");
  launcherSettingsView.classList.remove("hidden");
  closeSettingsButton.disabled = !hasUserToken();
}

function showLauncherHome() {
  if (!hasUserToken()) {
    showLauncherSettings();
    return;
  }
  launcherSettingsView.classList.add("hidden");
  launcherHomeView.classList.remove("hidden");
}

openSettingsButton.addEventListener("click", showLauncherSettings);
closeSettingsButton.addEventListener("click", () => {
  if (hasUserToken()) showLauncherHome();
});
// Keep the back button's enabled state in sync as the user types or
// clears the token — without this, clearing the field mid-edit leaves
// the button enabled and the user could escape with no token.
tokenInput.addEventListener("input", () => {
  if (!launcherSettingsView.classList.contains("hidden")) {
    closeSettingsButton.disabled = !hasUserToken();
  }
});

// Persist the lock-host-size preference and re-apply on the active
// session so the user sees the change immediately without needing
// to reconnect. Toggling it on snaps the browser back to the host's
// announced grid; toggling it off restores fit-to-viewport.
lockHostSizeInput.addEventListener("change", () => {
  localStorage.setItem(
    LOCK_HOST_SIZE_KEY,
    lockHostSizeInput.checked ? "1" : "0",
  );
  if (terminal && activeSessionId) {
    if (isHostSizeLocked()) {
      terminal.resize(hostCols, hostRows);
    } else if (fitAddon) {
      fitAddon.fit();
    }
  }
});

function isHostSizeLocked() {
  return lockHostSizeInput?.checked ?? false;
}

// Desktop-width mode widens `#terminal` past the phone viewport so a
// PC-shaped grid stays one-line-per-row and the user pans horizontally
// instead of seeing wraps. The CSS does the layout work; here we only
// toggle the class and ask FitAddon to recompute against the new width.
function syncDesktopWidthMode() {
  const enabled = desktopWidthInput?.checked ?? false;
  terminalView.classList.toggle("desktop-width-mode", enabled);
  // Drop any leftover pan transform so re-entering the mode always
  // starts at the top-left corner.
  desktopPanX = 0;
  desktopPanY = 0;
  terminalMount.style.transform = "";
  applyDesktopWidthSize();
  if (fitAddon && !isHostSizeLocked()) {
    requestViewportFit();
  }
}

// Pseudo-scroll for desktop-width mode. We drive #terminal's position
// via CSS transform rather than the parent's scroll because
// HuaweiBrowser (Chromium 114-based) silently resets overflow scroll
// between capture-phase and bubble-phase of touchend regardless of
// touch-action or preventDefault. We pan both axes so a locked host
// grid larger than the mobile viewport (e.g. 188×46 in a 346×530
// area) can still expose every row + column.
let desktopPanX = 0;
let desktopPanY = 0;
function isDesktopWidthMode() {
  return terminalView.classList.contains("desktop-width-mode");
}
function maxDesktopPanX() {
  const parent = terminalMount.parentElement;
  if (!parent) return 0;
  return Math.max(0, terminalMount.offsetWidth - parent.clientWidth);
}
function maxDesktopPanY() {
  const parent = terminalMount.parentElement;
  if (!parent) return 0;
  // .terminal-host carries padding-bottom = toolbar + keyboard offset
  // on mobile so the fixed toolbar doesn't sit on top of content.
  // clientHeight includes padding by definition, so panning all the
  // way to (offsetHeight − clientHeight) would land the bottom of
  // #terminal inside that padding region — i.e. behind the toolbar.
  // Subtract the paddings to get the actual visible content height.
  const cs = window.getComputedStyle(parent);
  const padTop = parseFloat(cs.paddingTop) || 0;
  const padBottom = parseFloat(cs.paddingBottom) || 0;
  const visible = parent.clientHeight - padTop - padBottom;
  return Math.max(0, terminalMount.offsetHeight - visible);
}
// Kept under its old name because the horizontal touchmove branch
// reads it. The Y-axis counterpart lives at maxDesktopPanY.
function maxDesktopPan() {
  return maxDesktopPanX();
}
function commitDesktopPan() {
  if (desktopPanX > 0 || desktopPanY > 0) {
    terminalMount.style.transform = `translate3d(${-desktopPanX | 0}px, ${-desktopPanY | 0}px, 0)`;
  } else {
    terminalMount.style.transform = "";
  }
}
function applyDesktopPan(x) {
  desktopPanX = Math.min(maxDesktopPanX(), Math.max(0, x));
  commitDesktopPan();
}
function applyDesktopPanY(y) {
  desktopPanY = Math.min(maxDesktopPanY(), Math.max(0, y));
  commitDesktopPan();
}
function panToBottom() {
  applyDesktopPanY(maxDesktopPanY());
}

// Adapt #terminal's pixel width to the live grid so a wide host
// (e.g. 120 cols on a phone) doesn't get clipped or wrapped inside
// the default 860px frame. Only takes effect while desktop-width-mode
// is on — otherwise the inline width is cleared and the CSS 100% /
// 860px cascade owns the layout again.
function currentCellWidthPx() {
  // Truth source: the canvas's internal pixel resolution. It's set
  // by the renderer based on its own font metrics, independent of any
  // CSS constraint, so dividing by DPR + cols always yields the real
  // per-cell CSS width.
  const canvas = terminal?.element?.querySelector?.("canvas");
  const cols = terminal?.cols ?? 0;
  if (canvas && canvas.width > 0 && cols > 0) {
    const dpr = window.devicePixelRatio || 1;
    return canvas.width / dpr / cols;
  }
  const metric = terminal?.renderer?.getMetrics?.();
  if (metric && metric.width > 0) return metric.width;
  // Last-resort heuristic. Err on the high side — under-allocating
  // clips the right edge; over-allocating just adds harmless pan range.
  const fontSize = terminal?.options?.fontSize ?? 14;
  return fontSize;
}
function applyDesktopWidthSize() {
  if (!isDesktopWidthMode()) {
    terminalMount.style.width = "";
    terminalMount.style.minWidth = "";
    terminalMount.style.height = "";
    terminalMount.style.minHeight = "";
    return;
  }
  // Defer one frame so the renderer has applied the latest grid
  // resize before we read canvas.{width,height}. The hello /
  // appearance / toggle paths all call this synchronously right
  // after changing grid state — without the rAF, the canvas
  // attributes still reflect the previous frame's grid.
  requestAnimationFrame(() => {
    const cols = terminal?.cols ?? 0;
    const rows = terminal?.rows ?? 0;
    let widthPx = 860;
    if (cols > 0) {
      // +16px slack so the rightmost column isn't fighting xterm's
      // scrollbar lane on the last few rendered glyphs.
      widthPx = Math.max(860, Math.ceil(cols * currentCellWidthPx()) + 16);
    }
    terminalMount.style.width = `${widthPx}px`;
    terminalMount.style.minWidth = `${widthPx}px`;

    // Height: only override the CSS calc if the host's grid is
    // taller than the parent viewport. Otherwise leave the inline
    // styles cleared so the existing media-query height (viewport −
    // toolbar) keeps applying.
    const parentH = terminalMount.parentElement?.clientHeight ?? 0;
    if (rows > 0) {
      const natural = Math.ceil(rows * currentCellHeightPx()) + 4;
      if (natural > parentH) {
        terminalMount.style.height = `${natural}px`;
        terminalMount.style.minHeight = `${natural}px`;
      } else {
        terminalMount.style.height = "";
        terminalMount.style.minHeight = "";
      }
    }

    // Re-anchor the pan to the bottom-right after a size change so
    // the cursor row (host's grid bottom) stays in view. Without
    // this, the user lands on the top of the grid after every
    // resize/hello.
    if (shouldUseMobileInput()) {
      panToBottom();
    }
  });
}

desktopWidthInput.addEventListener("change", () => {
  localStorage.setItem(
    DESKTOP_WIDTH_KEY,
    desktopWidthInput.checked ? "1" : "0",
  );
  syncDesktopWidthMode();
});

liveMirrorModeInput.addEventListener("change", () => {
  localStorage.setItem(
    LIVE_MIRROR_KEY,
    liveMirrorModeInput.checked ? "1" : "0",
  );
  // Apply live so the gates flip on the active session. Asymmetry is
  // accepted: A→B leaves the replayBuffer empty until new bytes arrive,
  // and B→A doesn't drop already-displayed scrollback rows.
  activeMirrorMode = liveMirrorModeInput.checked;
});

function isLiveMirrorEnabled() {
  return liveMirrorModeInput?.checked ?? false;
}

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
  // Re-anchor the pan to the bottom-right whenever .terminal-host
  // resizes — the soft keyboard appearing, the mobile toolbar
  // expanding, or the URL bar showing/hiding all shrink the visible
  // area without firing terminal.onResize. Without this, panY would
  // be left at its previous value while the new bottom edge is
  // further down, hiding the cursor row again.
  if (typeof ResizeObserver !== "undefined") {
    const hostObserver = new ResizeObserver(() => {
      if (shouldUseMobileInput() && isDesktopWidthMode()) {
        panToBottom();
      }
    });
    hostObserver.observe(terminalMount.parentElement);
  }
  // Neutralise ghostty-web's helper textarea on mobile. It races our
  // mobileInput by calling .focus() inside its own touchend handler,
  // which on Android re-raises the soft keyboard right after a swipe.
  // On desktop the original behaviour is fine — we only patch mobile.
  for (const helper of terminalMount.querySelectorAll("textarea")) {
    const originalFocus = helper.focus.bind(helper);
    helper.focus = function (opts) {
      if (shouldUseMobileInput()) {
        logEvt("helper focus suppressed");
        return;
      }
      originalFocus(opts);
    };
  }
  // Belt-and-braces: even with the .focus() override, the browser
  // can still auto-focus a focusable element on tap (ghostty-web's
  // helper textarea is in the tap target). The override only catches
  // explicit JS .focus() calls; the native tap-to-focus bypasses it
  // and the keyboard pops up anyway. Catch any focus that lands on
  // something *other than* mobileInput on mobile and blur it back
  // out. Tap-to-bring-keyboard still works because endTouchScroll's
  // wasTap branch calls focusTerminal → mobileInput.focus(), which
  // matches the allow-list here.
  document.addEventListener(
    "focusin",
    (event) => {
      if (!shouldUseMobileInput()) return;
      const target = event.target;
      if (!target || target === mobileInput) return;
      // Only police focus inside the terminal view — the settings
      // page legitimately wants its backend / token inputs to take
      // focus when the user taps them.
      if (!terminalView.contains(target)) return;
      if (
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLInputElement
      ) {
        if (typeof target.blur === "function") {
          target.blur();
          logEvt(`blur stolen ${target.tagName.toLowerCase()}`);
        }
      }
    },
    { capture: true },
  );
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
    // Recompute the inline #terminal pixel width on every grid change,
    // regardless of which side initiated it (FitAddon, hello, host
    // resize). This is the catch-all path — the explicit calls in
    // hello / applyAppearance / toggle are belt-and-braces.
    applyDesktopWidthSize();
    // Re-anchor the viewport to the bottom after any resize. With a
    // locked host grid taller than the mobile viewport, xterm
    // otherwise leaves the visible window on the top rows and the
    // cursor stays clipped at the bottom.
    if (shouldUseMobileInput()) {
      requestMobileBottomScroll();
    }
    // When the operator opted into "lock host size" we never push the
    // browser's grid up to the host. fitAddon.observeResize keeps
    // firing fit() in the background as the browser viewport
    // changes, so any resize that disagrees with the host has to be
    // snapped back here. Without the snap-back the grid would drift
    // off-host but the user wouldn't see anything change because
    // the host is still rendering at its own dimensions.
    if (isHostSizeLocked()) {
      if (helloReceived && (cols !== hostCols || rows !== hostRows)) {
        terminal.resize(hostCols, hostRows);
      }
      return;
    }
    sendControlFrame({
      type: "resize",
      id: activeSession?.id ?? "",
      cols,
      rows,
    });
  });
  if (typeof terminal.onScroll === "function") {
    terminal.onScroll(() => {
      maybeRequestOlderScrollback();
    });
  }
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
      const updatedActiveSession = sessions.find(
        (session) => session.id === activeSessionId,
      );
      if (updatedActiveSession) {
        activeSession = updatedActiveSession;
      }
    }

    const requestedSessionID = currentRequestedSessionID();
    if (requestedSessionID && !activeSessionId) {
      const requestedSession = sessions.find(
        (session) => session.id === requestedSessionID,
      );
      if (requestedSession?.online) {
        await connectToSession(requestedSession, { updateHistory: false });
      } else if (requestedSession) {
        sessionMeta.textContent = "目标会话当前离线";
      } else {
        sessionMeta.textContent = "目标会话不存在或已过期";
      }
    }
  } catch (error) {
    console.error(redactErrorMessage(error));
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
  ]
    .filter(Boolean)
    .join(" ");
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

    return displaySessionName(left).localeCompare(
      displaySessionName(right),
      "zh-CN",
    );
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
    helloReceived = false;
    activeMirrorMode = isLiveMirrorEnabled();
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
      // Only fit-to-viewport when we're allowed to push the host
      // around. With the lock engaged we wait for the agent's hello
      // / screen frame to tell us what dimensions to render at.
      if (fitAddon && !isHostSizeLocked()) fitAddon.fit();
      focusTerminal();
      updateDocumentTitle();
      setTerminalStatus("已连接", "connected");
      if (!isHostSizeLocked()) {
        sendControlFrame({
          type: "resize",
          id: session.id,
          cols: term.cols,
          rows: term.rows,
        });
      }
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
      if (!activeMirrorMode) replayBuffer.onLive(bytes);
      term.write(bytes);
      if (shouldUseMobileInput()) {
        requestMobileBottomScroll();
      }
    });
  } catch (error) {
    const redacted = redactErrorMessage(error);
    console.error(redacted);
    terminalMount.textContent = redacted || "连接错误";
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
  logEvt(`ctrl type=${frame.type}`);

  switch (frame.type) {
    case "hello":
      logEvt(
        `hello cols=${frame.cols} rows=${frame.rows} name=${frame.name ?? "-"}`,
      );
      if (frame.name && activeSession) {
        activeSession = { ...activeSession, name: frame.name };
      }
      updateDocumentTitle();
      if (
        Number.isInteger(frame.cols) &&
        Number.isInteger(frame.rows) &&
        terminal
      ) {
        hostRows = frame.rows;
        hostCols = frame.cols;
        helloReceived = true;
        // Mirror the host's grid verbatim. We previously trimmed rows
        // on mobile to avoid the canvas-overflow clip at the bottom,
        // but that made absolute cursor positioning escapes from live
        // frames (host computed them against its 46-row grid) land at
        // the wrong visual row in our shorter grid — TUI status bars
        // ended up stacked on top of unrelated content. With rows
        // preserved, applyDesktopWidthSize sizes #terminal to the
        // natural canvas height and we expose the off-screen rows via
        // vertical transform pan.
        terminal.resize(frame.cols, frame.rows);
        applyDesktopWidthSize();
      }
      return;
    case "resize":
      if (
        Number.isInteger(frame.cols) &&
        Number.isInteger(frame.rows) &&
        terminal
      ) {
        terminal.resize(frame.cols, frame.rows);
      }
      return;
    case "ping":
      if (socket && socket.readyState === WebSocket.OPEN) {
        socket.send(
          JSON.stringify({ type: "pong", id: activeSession?.id ?? "" }),
        );
      }
      return;
    case "pong":
      return;
    case "appearance":
      applyAppearance(frame);
      return;
    case "screen":
      applyScreenSnapshot(frame);
      return;
    case "scrollback":
      applyScrollbackResponse(frame);
      return;
    default:
      if (terminal) terminal.write(data);
  }
}

function applyScreenSnapshot(frame) {
  if (!terminal || typeof frame?.content !== "string") return;
  const bytes = decodeBase64(frame.content);
  if (!bytes) return;
  // In live-mirror mode we never read the replayBuffer, so don't bother
  // feeding it. The reset+write below still runs because the agent's
  // snapshot is a re-anchor checkpoint and we want it to land cleanly.
  if (!activeMirrorMode) replayBuffer.onScreen(bytes);
  // The agent prefixes its snapshot with `\x1b[2J\x1b[H`, but reset()
  // also clears the active scrollback so a stale checkpoint can't
  // bleed through after the host re-emits the current viewport.
  if (typeof terminal.reset === "function") {
    terminal.reset();
  }
  terminal.write(bytes);
  // When the locked host grid is taller than the mobile viewport
  // (e.g. host 46 rows in a 33-row visible window), the snapshot
  // lands but xterm's viewport stays at the top → the user sees the
  // top portion of the grid, cursor is clipped below. Re-anchor to
  // the bottom so the live area (where new content lands) is in
  // view.
  if (shouldUseMobileInput()) {
    requestMobileBottomScroll();
  }
}

function applyScrollbackResponse(frame) {
  if (!terminal || typeof frame?.content !== "string") return;
  // Defensive: in live-mirror mode we never issue fetch_scrollback, but
  // a late response from a request fired right before the toggle could
  // still arrive. Drop it so it doesn't trigger a buildReplayBytes
  // rewrite that the user just opted out of.
  if (activeMirrorMode) return;
  const bytes = decodeBase64(frame.content);
  if (!bytes) {
    replayBuffer.fetchFailed();
    return;
  }
  replayBuffer.onScrollback(bytes, {
    count: Number.isInteger(frame.count) ? frame.count : 0,
    total: Number.isInteger(frame.total) ? frame.total : null,
  });
  if (typeof terminal.reset === "function") {
    terminal.reset();
  }
  terminal.write(replayBuffer.buildReplayBytes());
}

function maybeRequestOlderScrollback() {
  if (activeMirrorMode) return;
  if (!terminal || !socket || socket.readyState !== WebSocket.OPEN) return;
  if (replayBuffer.isFetchInFlight()) return;
  if (replayBuffer.hasReachedTop(hostRows)) return;
  const scrollback =
    typeof terminal.getScrollbackLength === "function"
      ? terminal.getScrollbackLength()
      : 0;
  const viewportY =
    typeof terminal.getViewportY === "function"
      ? terminal.getViewportY()
      : (terminal.viewportY ?? 0);
  // viewportY is the offset from the live screen (0 = bottom). We
  // trigger the fetch when the user is within a few lines of the
  // top of currently-loaded scrollback so the new content lands
  // before they hit the wall.
  if (viewportY < scrollback - SCROLLBACK_TOP_TRIGGER_LINES) return;
  replayBuffer.fetchStarted();
  socket.send(
    JSON.stringify({
      type: "fetch_scrollback",
      id: activeSession?.id ?? "",
      before: replayBuffer.coveredHistoryRows(hostRows),
      count: SCROLLBACK_FETCH_BATCH,
    }),
  );
}

function decodeBase64(text) {
  try {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  } catch (error) {
    console.error(redactErrorMessage(error));
    return null;
  }
}

function applyAppearance(frame) {
  const theme = buildAppearanceTheme(frame);
  if (!theme) return;
  if (terminal?.renderer) {
    terminal.renderer.setTheme(theme);
  }
  if (terminal) {
    terminal.options.theme = theme;
    if (typeof frame.font_size === "number" && frame.font_size > 0) {
      terminal.options.fontSize = frame.font_size;
    }
  }
  // Font size affects cell width, which feeds the desktop-width
  // calculation. Recompute so a smaller font frees up pan range.
  applyDesktopWidthSize();
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
    delay = Math.min(1000 * 2 ** Math.max(0, reconnectAttempt - 1), 30000);
    const fallback =
      delay >= 1000 ? `重连中（${Math.round(delay / 1000)}s）` : "重连中";
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
      const session = sessions.find(
        (candidate) => candidate.id === activeSessionId,
      );
      if (!session?.online) {
        scheduleReconnect(closeContext);
        return;
      }

      await connectToSession(session, { updateHistory: false });
    } catch (error) {
      console.error(redactErrorMessage(error));
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
    // The first call to syncMobileViewportInsets ran while #terminalView
    // was still display:none, so mobileToolbar.offsetHeight read 0 and
    // the CSS variables fell back to a 112px estimate. Once the view is
    // visible we re-measure so #terminal's calc() height accounts for
    // the real toolbar — without this the bottom row sits under the
    // toolbar until the user collapses+reopens it (which re-syncs).
    syncMobileViewportInsets();
    if (fitAddon && !isHostSizeLocked()) fitAddon.fit();
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
  if (diff < 3_600_000)
    return `${Math.max(1, Math.floor(diff / 60_000))} 分钟前`;
  if (diff < 86_400_000)
    return `${Math.max(1, Math.floor(diff / 3_600_000))} 小时前`;

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

// Mobile auto-scroll: a busy producer fires hundreds of binary frames per
// second, and previously each one queued its own setTimeout. Folding them
// into a single rAF tick caps the work at one scroll-to-bottom per frame
// while still keeping the cursor visible. See `scroll.js` for the helper.
const requestMobileBottomScroll = createCoalescedScroll(
  (cb) => window.requestAnimationFrame(cb),
  scrollTerminalToBottom,
);

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
  terminalStatus.classList.remove(
    "hidden",
    "connected",
    "reconnecting",
    "error",
  );
  if (kind) {
    terminalStatus.classList.add(kind);
  }
}

function hideTerminalStatus() {
  terminalStatus.classList.add("hidden");
  terminalStatus.classList.remove("connected", "reconnecting", "error");
}

function shouldUseMobileInput() {
  return (
    window.matchMedia("(pointer: coarse)").matches ||
    window.matchMedia("(max-width: 860px)").matches
  );
}

function sendInput(data) {
  if (!socket || socket.readyState !== WebSocket.OPEN || !data) return;
  socket.send(data);
}

function syncModifierButtons() {
  for (const button of mobileToolbar.querySelectorAll("[data-modifier]")) {
    const modifier = button.dataset.modifier;
    const active =
      (modifier === "ctrl" && pendingCtrlModifier) ||
      (modifier === "alt" && pendingAltModifier);
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

// Coalesces fit + bottom-scroll into one rAF tick. iOS keyboard show/hide
// fires `visualViewport.scroll` dozens of times per animation; before this
// each tick reflowed the terminal and triggered a full re-render that
// looked like a top-down repaint on long sessions.
const requestViewportFit = createCoalescedScroll(
  (cb) => window.requestAnimationFrame(cb),
  () => {
    if (!fitAddon) return;
    fitAddon.fit();
    scrollTerminalToBottom();
  },
);

function syncMobileViewportInsets() {
  const mobile = shouldUseMobileInput();
  const viewportHeight =
    mobile && window.visualViewport
      ? `${window.visualViewport.height}px`
      : `${window.innerHeight}px`;
  document.documentElement.style.setProperty(
    "--mobile-viewport-height",
    viewportHeight,
  );

  const toolbarHeight =
    mobile && !mobileToolbarCollapsed
      ? `${mobileToolbar.offsetHeight || 112}px`
      : "0px";
  document.documentElement.style.setProperty(
    "--mobile-toolbar-height",
    toolbarHeight,
  );

  let keyboardOffset = 0;
  if (mobile && window.visualViewport) {
    keyboardOffset = Math.max(
      0,
      window.innerHeight -
        window.visualViewport.height -
        window.visualViewport.offsetTop,
    );
  }
  document.documentElement.style.setProperty(
    "--mobile-toolbar-offset",
    `${keyboardOffset}px`,
  );

  // Snapshot the relevant numbers so we can correlate key viewport
  // changes against terminal-host / #terminal layout in the log file.
  if (typeof logEvt === "function") {
    const vv = window.visualViewport;
    const termRect = terminalMount?.getBoundingClientRect();
    const hostRect = terminalMount?.parentElement?.getBoundingClientRect();
    const toolbarRect = mobileToolbar?.getBoundingClientRect();
    logEvt(
      `VV mobile=${mobile ? 1 : 0} ih=${window.innerHeight} vvh=${vv ? Math.round(vv.height) : "-"} vvtop=${vv ? Math.round(vv.offsetTop) : "-"} kbd=${keyboardOffset | 0} tbh=${toolbarHeight} tbcollapsed=${mobileToolbarCollapsed ? 1 : 0} tb.oh=${mobileToolbar?.offsetHeight ?? "-"} tb.rect.bot=${toolbarRect ? Math.round(toolbarRect.bottom) : "-"} host.rect.bot=${hostRect ? Math.round(hostRect.bottom) : "-"} term.rect.bot=${termRect ? Math.round(termRect.bottom) : "-"} term.h=${termRect ? Math.round(termRect.height) : "-"}`,
    );
  }

  if (fitAddon) requestViewportFit();
  if (mobile || activeSessionId) {
    window.scrollTo(0, 0);
  }
  // The parent's clientHeight just changed (keyboard popped, URL bar
  // toggled, etc.) so the natural-vs-parent decision in
  // applyDesktopWidthSize might flip, and our existing panY value is
  // no longer at the new bottom. Recompute + snap.
  if (mobile && isDesktopWidthMode() && terminal) {
    applyDesktopWidthSize();
  }
}

// Touch interaction: a tap focuses the hidden mobile input (which raises
// the soft keyboard), a vertical drag in the body scrolls the scrollback,
// and a touch in the right-edge scrollbar lane drags the thumb (xterm.js
// only binds `mousedown` for the scrollbar so the lane is unreachable
// from a touch device by default). Previously every `touchstart`
// immediately popped the keyboard, so swipes never reached the renderer
// and the terminal felt frozen.
let touchScrollState = null;
const TOUCH_TAP_THRESHOLD_PX = 6;

// === DEBUG: top-of-screen bar + ring-buffered touch event log.
// "DL" downloads the buffered log as a .txt; "CLR" wipes it. Gated by
// the debug toggle in the launcher — when off, logEvt/setDebugBar are
// no-ops and none of the listeners or observers below are wired.
let logEvt = (_line) => {};
let setDebugBar = (_text) => {};
if (debugEnabled) {
  const debugBar = document.createElement("div");
  debugBar.style.cssText =
    "position:fixed;top:0;left:0;right:0;z-index:9999;font:11px/1.3 ui-monospace,monospace;background:rgba(0,0,0,0.82);color:#7de3bb;padding:3px 8px;white-space:nowrap;overflow:hidden;display:flex;gap:6px;align-items:center;";
  const debugText = document.createElement("span");
  debugText.style.cssText =
    "flex:1;overflow:hidden;text-overflow:ellipsis;pointer-events:none;";
  debugText.textContent = "(waiting for touch)";
  const debugDlBtn = document.createElement("button");
  debugDlBtn.textContent = "DL";
  debugDlBtn.style.cssText =
    "font:11px ui-monospace,monospace;background:#7de3bb;color:#000;border:0;border-radius:3px;padding:2px 8px;";
  const debugClrBtn = document.createElement("button");
  debugClrBtn.textContent = "CLR";
  debugClrBtn.style.cssText =
    "font:11px ui-monospace,monospace;background:#444;color:#fff;border:0;border-radius:3px;padding:2px 8px;";
  debugBar.append(debugText, debugDlBtn, debugClrBtn);
  document.body.appendChild(debugBar);
  setDebugBar = (text) => {
    debugText.textContent = text;
  };
  const DEBUG_LOG_CAP = 8000;
  const debugLogs = [];
  const debugT0 = performance.now();
  logEvt = (line) => {
    const t = (performance.now() - debugT0).toFixed(1);
    debugLogs.push(`${t.padStart(8, " ")} ${line}`);
    if (debugLogs.length > DEBUG_LOG_CAP) debugLogs.shift();
  };
  debugDlBtn.addEventListener("click", () => {
    const body = debugLogs.join("\n") + "\n";
    const blob = new Blob([body], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `touch-log-${new Date().toISOString().replace(/[:.]/g, "-")}.txt`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  debugClrBtn.addEventListener("click", () => {
    debugLogs.length = 0;
    setDebugBar("(cleared)");
  });
  logEvt(`UA ${navigator.userAgent}`);
  // Log every focus change so we can identify what raised the
  // mobile soft keyboard. focusin bubbles unlike focus, so a single
  // capture-phase listener at document covers everything.
  document.addEventListener(
    "focusin",
    (e) => {
      const tgt = e.target;
      const id = tgt?.id || "";
      const tag = tgt?.tagName || "?";
      const cls = String(tgt?.className || "").slice(0, 30);
      logEvt(`focusin <${tag}#${id}.${cls}>`);
    },
    { capture: true },
  );
  // Capture-phase touchend on the window so we can read scrollLeft at
  // the earliest possible moment, before any bubble-phase JS runs.
  window.addEventListener(
    "touchend",
    () => {
      const s = terminalMount?.parentElement;
      if (s) logEvt(`touchend@capture sl=${s.scrollLeft | 0}`);
    },
    { capture: true, passive: true },
  );
  // Attach a scroll listener on the .terminal-host parent as soon as it
  // exists in the DOM. Logs every scrollLeft change so we can correlate
  // against touch events on the timeline. Also wires a ResizeObserver
  // onto #terminal so we can see whether the inner element shrinks at
  // touchend (which would clamp scrollLeft to 0).
  queueMicrotask(() => {
    const _scroller = terminalMount?.parentElement;
    if (!_scroller) return;
    _scroller.addEventListener(
      "scroll",
      () => {
        logEvt(
          `SCROLL sl=${_scroller.scrollLeft | 0} sw=${_scroller.scrollWidth | 0} cw=${_scroller.clientWidth | 0}`,
        );
      },
      { passive: true },
    );
    if (typeof ResizeObserver !== "undefined") {
      const ro = new ResizeObserver((entries) => {
        for (const e of entries) {
          const w = (e.contentRect?.width ?? 0) | 0;
          const h = (e.contentRect?.height ?? 0) | 0;
          logEvt(`RESIZE #terminal w=${w} h=${h}`);
        }
      });
      ro.observe(terminalMount);
      const ro2 = new ResizeObserver((entries) => {
        for (const e of entries) {
          const w = (e.contentRect?.width ?? 0) | 0;
          const h = (e.contentRect?.height ?? 0) | 0;
          logEvt(`RESIZE .terminal-host w=${w} h=${h}`);
        }
      });
      ro2.observe(_scroller);
    }
  });
}
// Mirror of ghostty-web's renderScrollbar layout: 8 px wide thumb in a
// lane offset 4 px from the right edge, with 4 px top/bottom padding on
// the track. See `node_modules/ghostty-web/dist/ghostty-web.js` ~L2186.
const SCROLLBAR_LANE_WIDTH_PX = 8;
const SCROLLBAR_LANE_RIGHT_PADDING_PX = 4;
const SCROLLBAR_TRACK_PADDING_Y_PX = 4;
const SCROLLBAR_HIT_SLOP_PX = 6;

function currentCellHeightPx() {
  const metric = terminal?.renderer?.getMetrics?.();
  if (metric && metric.height > 0) return metric.height;
  const computed = Number.parseFloat(
    window.getComputedStyle(terminalMount).fontSize,
  );
  return Number.isFinite(computed) && computed > 0 ? computed * 1.2 : 16;
}

function terminalCanvas() {
  return terminal?.element?.querySelector?.("canvas") ?? null;
}

function scrollbarHitTest(touch) {
  if (!terminal) return null;
  const canvas = terminalCanvas();
  if (!canvas) return null;
  const scrollback =
    typeof terminal.getScrollbackLength === "function"
      ? terminal.getScrollbackLength()
      : 0;
  if (scrollback <= 0) return null;
  const rect = canvas.getBoundingClientRect();
  const x = touch.clientX - rect.left;
  const laneRight = rect.width - SCROLLBAR_LANE_RIGHT_PADDING_PX;
  const laneLeft = laneRight - SCROLLBAR_LANE_WIDTH_PX;
  if (
    x < laneLeft - SCROLLBAR_HIT_SLOP_PX ||
    x > laneRight + SCROLLBAR_HIT_SLOP_PX
  ) {
    return null;
  }
  return { canvasRect: rect, scrollback };
}

function scrollbarLineForTouchY(canvasRect, scrollback, touchY) {
  const k = SCROLLBAR_TRACK_PADDING_Y_PX;
  const trackHeight = Math.max(1, canvasRect.height - k * 2);
  const localY = touchY - canvasRect.top;
  // Library convention (handleMouseDown): viewportY=0 is the live screen
  // and viewportY=scrollback is the top of history, so an upper touch
  // maps to a higher viewportY.
  const fraction = Math.max(0, Math.min(1, 1 - (localY - k) / trackHeight));
  return Math.round(fraction * scrollback);
}

terminalMount.addEventListener(
  "touchstart",
  (event) => {
    if (event.touches.length !== 1) {
      touchScrollState = null;
      return;
    }
    const touch = event.touches[0];
    const scrollbar = scrollbarHitTest(touch);
    if (scrollbar) {
      touchScrollState = {
        type: "scrollbar",
        canvasRect: scrollbar.canvasRect,
        scrollback: scrollbar.scrollback,
      };
      // Tap inside the lane jumps to that position (matches the
      // mouse-side click-to-jump behaviour).
      if (typeof terminal.scrollToLine === "function") {
        terminal.scrollToLine(
          scrollbarLineForTouchY(
            scrollbar.canvasRect,
            scrollbar.scrollback,
            touch.clientY,
          ),
        );
      }
      return;
    }
    touchScrollState = {
      type: "swipe",
      startX: touch.clientX,
      startY: touch.clientY,
      lastY: touch.clientY,
      lastPanX: touch.clientX,
      lastPanY: touch.clientY,
      cellHeight: currentCellHeightPx(),
      moved: false,
    };
    const _scroller = terminalMount.parentElement;
    const _sl = _scroller ? _scroller.scrollLeft | 0 : 0;
    const _sw = _scroller ? _scroller.scrollWidth | 0 : 0;
    const _cw = _scroller ? _scroller.clientWidth | 0 : 0;
    logEvt(
      `START x=${touch.clientX | 0} y=${touch.clientY | 0} sl=${_sl} sw=${_sw} cw=${_cw}`,
    );
  },
  { passive: true },
);

terminalMount.addEventListener(
  "touchmove",
  (event) => {
    if (!touchScrollState || !terminal) return;
    if (event.touches.length !== 1) {
      touchScrollState = null;
      return;
    }
    const touch = event.touches[0];
    if (touchScrollState.type === "scrollbar") {
      if (typeof terminal.scrollToLine === "function") {
        terminal.scrollToLine(
          scrollbarLineForTouchY(
            touchScrollState.canvasRect,
            touchScrollState.scrollback,
            touch.clientY,
          ),
        );
      }
      if (event.cancelable) event.preventDefault();
      return;
    }
    touchScrollState.lastTouchX = touch.clientX;
    touchScrollState.lastTouchY = touch.clientY;
    const dx = touch.clientX - touchScrollState.startX;
    const dy = touch.clientY - touchScrollState.startY;
    const adx = Math.abs(dx);
    const ady = Math.abs(dy);
    if (Math.max(adx, ady) > TOUCH_TAP_THRESHOLD_PX) {
      touchScrollState.moved = true;
    }
    // DEBUG: track the highest scrollLeft seen during the gesture so
    // touchend can distinguish "Chrome committed pan asynchronously"
    // from "something reset scrollLeft on release".
    const _scroller = terminalMount.parentElement;
    let _sl = 0;
    if (_scroller) {
      _sl = _scroller.scrollLeft | 0;
      if (
        touchScrollState.maxSlDuringMove === undefined ||
        _sl > touchScrollState.maxSlDuringMove
      ) {
        touchScrollState.maxSlDuringMove = _sl;
      }
    }
    logEvt(
      `MOVE dx=${dx | 0} dy=${dy | 0} adx=${adx | 0} ady=${ady | 0} m=${touchScrollState.moved ? 1 : 0} sl=${_sl} cancelable=${event.cancelable ? 1 : 0}`,
    );
    if (!touchScrollState.moved) return;
    // Only consume the gesture as terminal scrollback when it's
    // vertically dominant. A horizontal-leaning swipe must fall
    // through without preventDefault so the browser's native pan on
    // `.terminal-host` (used by desktop-width-mode) commits cleanly —
    // calling preventDefault here makes Chrome roll back the
    // already-applied scroll on release, which manifested as the
    // "small horizontal swipe snaps back to the left" symptom.
    if (ady <= adx) {
      // Horizontal-dominant: drive #terminal's CSS transform manually.
      // Native scrollLeft is unreliable on HuaweiBrowser (resets
      // between capture- and bubble-phase of touchend regardless of
      // touch-action), so we don't use it.
      let dxStep = 0;
      if (isDesktopWidthMode() && maxDesktopPan() > 0) {
        dxStep = touch.clientX - touchScrollState.lastPanX;
        if (dxStep !== 0) {
          applyDesktopPan(desktopPanX - dxStep);
          touchScrollState.lastPanX = touch.clientX;
        }
      }
      if (event.cancelable) event.preventDefault();
      logEvt(
        `MOVE-pan dxStep=${dxStep | 0} panX=${desktopPanX} max=${maxDesktopPan()} cancelable=${event.cancelable ? 1 : 0}`,
      );
      return;
    }
    // Vertical-dominant: if a locked host grid overflows the mobile
    // viewport, pan #terminal on the Y axis instead of routing into
    // xterm scrollback. The pan is symmetric with the horizontal
    // path and bypasses the same HuaweiBrowser scrollTop quirks.
    // We still need to coordinate with xterm's own scrollback so
    // the user can read history older than the host's live grid:
    //   - drag DOWN (older) at panY=0 → fall through to scrollLines
    //     so xterm scrolls into its scrollback
    //   - drag UP (newer) while scrollback is active → fall through
    //     to scrollLines so xterm unwinds back to the live area
    //     before resuming pan toward the grid bottom
    if (isDesktopWidthMode() && maxDesktopPanY() > 0) {
      const dyStep = touch.clientY - touchScrollState.lastPanY;
      if (dyStep === 0) {
        if (event.cancelable) event.preventDefault();
        return;
      }
      const draggingDown = dyStep > 0;
      const viewportY =
        typeof terminal.getViewportY === "function"
          ? terminal.getViewportY()
          : (terminal.viewportY ?? 0);
      const panToScrollback = draggingDown && desktopPanY === 0;
      const unwindScrollback = !draggingDown && viewportY > 0;
      if (!panToScrollback && !unwindScrollback) {
        applyDesktopPanY(desktopPanY - dyStep);
        touchScrollState.lastPanY = touch.clientY;
        if (event.cancelable) event.preventDefault();
        return;
      }
      // Fall through — scrollLines handles the saturated direction.
    }
    if (typeof terminal.scrollLines !== "function") return;
    const cellHeight = touchScrollState.cellHeight || 16;
    // Drag down = scroll into older history (scrollLines wants negative).
    const lines = Math.trunc(
      (touchScrollState.lastY - touch.clientY) / cellHeight,
    );
    if (lines !== 0) {
      terminal.scrollLines(lines);
      touchScrollState.lastY -= lines * cellHeight;
    }
    if (event.cancelable) {
      event.preventDefault();
    }
  },
  { passive: false },
);

function endTouchScroll() {
  if (!touchScrollState) return;
  const wasTap = touchScrollState.type === "swipe" && !touchScrollState.moved;
  // DEBUG: write the last gesture's signature into a top-of-screen
  // bar so we can confirm on-device whether the swipe was actually
  // horizontal-dominant in pixels (i.e. adx > ady).
  const scroller = terminalMount.parentElement;
  const dx =
    touchScrollState.lastTouchX !== undefined
      ? Math.round(touchScrollState.lastTouchX - (touchScrollState.startX ?? 0))
      : 0;
  const dy =
    touchScrollState.lastTouchY !== undefined
      ? Math.round(touchScrollState.lastTouchY - (touchScrollState.startY ?? 0))
      : 0;
  const sl0 = (scroller?.scrollLeft ?? 0) | 0;
  const maxSl = (touchScrollState.maxSlDuringMove ?? 0) | 0;
  const axis = Math.abs(dy) > Math.abs(dx) ? "V" : "H";
  const movedFlag = touchScrollState.moved ? 1 : 0;
  setDebugBar(
    `m=${movedFlag} dx=${dx} dy=${dy} ${axis} max=${maxSl} sl=${sl0}`,
  );
  logEvt(
    `END m=${movedFlag} dx=${dx} dy=${dy} axis=${axis} maxSl=${maxSl} sl@end=${sl0}`,
  );
  if (scroller) {
    let samples = 0;
    const sampleAt = [50, 100, 200, 350, 600];
    sampleAt.forEach((ms) => {
      setTimeout(() => {
        const slNow = scroller.scrollLeft | 0;
        logEvt(
          `POST t+${ms}ms sl=${slNow} sw=${scroller.scrollWidth | 0} cw=${scroller.clientWidth | 0}`,
        );
        samples += 1;
        if (samples === sampleAt.length) {
          setDebugBar(
            `m=${movedFlag} dx=${dx} dy=${dy} ${axis} max=${maxSl} sl=${sl0}→${slNow}`,
          );
        }
      }, ms);
    });
  }
  const wasMovedSwipe =
    touchScrollState.type === "swipe" && touchScrollState.moved;
  touchScrollState = null;
  if (wasTap && shouldUseMobileInput()) {
    focusTerminal();
    return;
  }
  // After a real swipe, force-blur mobileInput so the Android soft
  // keyboard doesn't auto-pop back up. The keyboard returns whenever
  // the focused input receives a user-interaction signal, even
  // without a new focusin event — dismissing it via system gesture
  // leaves mobileInput focused, and the very next touchend revives
  // it. Dropping focus here means the next tap is what brings the
  // keyboard back, which matches user intent.
  if (
    wasMovedSwipe &&
    shouldUseMobileInput() &&
    document.activeElement === mobileInput
  ) {
    mobileInput.blur();
    logEvt("blur mobileInput after swipe");
  }
}

// On Android, ghostty-web reacts to the synthetic click / pointerup
// that follows touchend by focusing its hidden helper textarea, which
// re-raises the soft keyboard right after a swipe completes (even when
// our endTouchScroll didn't call focusTerminal). After a moved swipe
// we mark a short window during which any pointerup / click bubbling
// up through terminalMount is swallowed in capture phase so the
// follow-up focus call never lands.
let suppressTerminalClickUntil = 0;
function suppressTerminalFollowupClick(event) {
  if (performance.now() < suppressTerminalClickUntil) {
    event.stopPropagation();
    event.preventDefault();
    logEvt(`SUPPRESS ${event.type} after swipe`);
  }
}
terminalMount.addEventListener("click", suppressTerminalFollowupClick, {
  capture: true,
});
terminalMount.addEventListener("pointerup", suppressTerminalFollowupClick, {
  capture: true,
});

terminalMount.addEventListener("touchend", (event) => {
  const scroller = terminalMount.parentElement;
  if (scroller) {
    logEvt(
      `touchend fires sl=${scroller.scrollLeft | 0} sw=${scroller.scrollWidth | 0} cw=${scroller.clientWidth | 0} #terminal.w=${terminalMount.offsetWidth | 0} cancelable=${event.cancelable ? 1 : 0}`,
    );
  } else {
    logEvt(`touchend fires no-scroller cancelable=${event.cancelable ? 1 : 0}`);
  }
  // A moved swipe is the only case where ghostty-web could re-raise
  // the keyboard against the user's intent — for a tap we still want
  // the focus + keyboard.
  if (
    touchScrollState &&
    touchScrollState.type === "swipe" &&
    touchScrollState.moved
  ) {
    if (event.cancelable) event.preventDefault();
    suppressTerminalClickUntil = performance.now() + 500;
  }
  endTouchScroll();
});
terminalMount.addEventListener("touchcancel", () => {
  logEvt(`touchcancel`);
  touchScrollState = null;
});

terminalView.addEventListener("pointerdown", (event) => {
  // Touch input is handled via touchend tap detection above so a vertical
  // swipe scrolls the terminal instead of immediately focusing the input.
  if (event.pointerType === "touch") return;
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
  requestMobileBottomScroll();
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
  requestMobileBottomScroll();
  scheduleMobileRefocus();
});

mobileInput.addEventListener("keydown", (event) => {
  switch (event.key) {
    case "Enter":
      event.preventDefault();
      sendInput(applyPendingModifiers("\r"));
      mobileInput.value = "";
      requestMobileBottomScroll();
      scheduleMobileRefocus();
      break;
    case "Tab":
      event.preventDefault();
      sendInput(applyPendingModifiers("\t"));
      mobileInput.value = "";
      requestMobileBottomScroll();
      scheduleMobileRefocus();
      break;
    case "Backspace":
      if (mobileInput.value.length === 0) {
        sendInput(applyPendingModifiers("\u007f"));
      }
      requestMobileBottomScroll();
      scheduleMobileRefocus();
      break;
    default:
      break;
  }
});

// Intentionally NOT auto-refocusing on blur. The previous behaviour
// scheduled a 60ms refocus every time mobileInput lost focus, which
// fought the user's intent to dismiss the keyboard via a system
// gesture — after the dismissal the keyboard would pop back up, and
// a swipe started in that window looked like "swiping raises the
// keyboard". Now blur is permanent: to bring the keyboard back, the
// user taps the terminal (endTouchScroll wasTap → focusTerminal) or
// a toolbar button (click handler → focusTerminal). Typing-time
// refocus still happens from the input / keydown / compositionend
// handlers above, so keystroke flow inside the textarea is unchanged.

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

  const session = cachedSessions.find(
    (candidate) => candidate.id === requestedSessionID,
  );
  if (session?.online) {
    await connectToSession(session, { updateHistory: false });
  }
});

setMobileToolbarCollapsed(false);
syncMobileViewportInsets();
syncDesktopWidthMode();
// First-run routing: without a token the session list is just an empty
// state, so drop the user straight onto the settings page. After they
// save the token the saveToken handler flips us to the home view.
if (hasUserToken()) {
  showLauncherHome();
} else {
  showLauncherSettings();
}
refreshSessions();
