import { FitAddon, init, Terminal } from "ghostty-web";
import { buildAppearanceTheme } from "./appearance.js";
import { redactErrorMessage } from "./redaction.js";
import { createCoalescedScroll } from "./scroll.js";
import { createReplayBuffer } from "./scrollback.js";
import { createUploadManager } from "./upload.js";

const DEFAULT_TITLE = "Ghostty Session Sharing";
const SESSION_QUERY_KEY = "session";
const SESSION_POLL_INTERVAL_MS = 15_000;

const shell = document.querySelector("#shell");
const launcherView = document.querySelector("#launcherView");
const launcherHomeView = document.querySelector("#launcherHomeView");
const launcherSettingsView = document.querySelector("#launcherSettingsView");
const openSettingsButton = document.querySelector("#openSettings");
const closeSettingsButton = document.querySelector("#closeSettings");
const refreshSessionsButton = document.querySelector("#refreshSessions");
const terminalView = document.querySelector("#terminalView");
const terminalStatus = document.querySelector("#terminalStatus");
const backendBaseInput = document.querySelector("#backendBase");
const tokenInput = document.querySelector("#token");
const saveTokenButton = document.querySelector("#saveToken");
const downloadApkButton = document.querySelector("#downloadApk");
const downloadApkHint = document.querySelector("#downloadApkHint");
const sessionList = document.querySelector("#sessionList");
const sessionMeta = document.querySelector("#sessionMeta");
const terminalMount = document.querySelector("#terminal");
const mobileInput = document.querySelector("#mobileInput");
const mobileToolbar = document.querySelector("#mobileToolbar");
const mobileToolbarToggle = document.querySelector("#mobileToolbarToggle");
const lockHostSizeInput = document.querySelector("#lockHostSize");
const desktopWidthInput = document.querySelector("#desktopWidth");
const lowResRenderSelect = document.querySelector("#lowResRender");
const liveMirrorModeInput = document.querySelector("#liveMirrorMode");
const debugModeInput = document.querySelector("#debugMode");
const mobileUploadLauncher = document.querySelector("#mobileUploadLauncher");
const uploadFileInput = document.querySelector("#uploadFileInput");
const uploadToastStack = document.querySelector("#uploadToastStack");

let terminal = null;
let fitAddon = null;
let globalTerminalListenersInstalled = false;
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
// Low-resolution rendering level. Cap `terminal.renderer.devicePixelRatio`
// to LOW_RES_LEVELS[level] when the user picks a non-"off" preset. The
// cap-vs-quality picks: 2.0 keeps text edges crisp on DPR=3 phones with
// modest backing savings; 1.5 is the sweet spot (4× backing savings, text
// still legible); 1.0 is aggressive and noticeably blurs small fonts /
// box-drawing chars. "off" disables the cap entirely so the renderer
// uses native `window.devicePixelRatio`.
//
// The localStorage value was originally "0"/"1" when this was a single
// checkbox; getLowResLevel() handles the legacy migration so users who
// had the checkbox on don't get silently downgraded to "off".
const LOW_RES_RENDER_KEY = "ghostty-sharing-low-res-render";
const LOW_RES_LEVELS = {
  off: Number.POSITIVE_INFINITY, // no cap → renderer keeps native DPR
  light: 2.0,
  balanced: 1.5,
  strong: 1.0,
};
const LOW_RES_DEFAULT_LEVEL = "off";
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
lowResRenderSelect.value = getInitialLowResLevel();
liveMirrorModeInput.checked = localStorage.getItem(LIVE_MIRROR_KEY) === "1";

// Resolve the stored low-res level on boot, applying the legacy
// migration: the old single-checkbox UI stored "1" (= on, balanced
// cap) and "0" (= off). New presets are "off"/"light"/"balanced"/
// "strong". Anything unrecognised falls back to the default so a
// stray value can't break the select.
function getInitialLowResLevel() {
  const raw = localStorage.getItem(LOW_RES_RENDER_KEY);
  if (raw === "1") return "balanced";
  if (raw && raw !== "0" && raw in LOW_RES_LEVELS) return raw;
  return LOW_RES_DEFAULT_LEVEL;
}
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

saveTokenButton.addEventListener("click", () => {
  localStorage.setItem(
    "ghostty-sharing-backend-base",
    backendBaseInput.value.trim(),
  );
  localStorage.setItem("ghostty-sharing-token", tokenInput.value.trim());
  // Save folds the previous explicit "重新加载页面" entry — the rest of
  // the SPA reads backend / token from localStorage at boot, so a soft
  // reload is the simplest "apply settings everywhere" path and also
  // clears any wedged terminal / WebSocket / cache state in one shot.
  // Skip the reload when no token is set: there's nothing to reload
  // into, the user just landed on settings to fill the token field.
  if (tokenInput.value.trim()) {
    performAppReload();
    return;
  }
  // Token-less branch: stay on settings, refresh sessions list defensively
  // so any tab the user may switch to picks up cleared state.
  refreshSessions();
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
function showLauncherSettings({ recordHistory = true } = {}) {
  launcherHomeView.classList.add("hidden");
  launcherSettingsView.classList.remove("hidden");
  closeSettingsButton.disabled = !hasUserToken();
  // Push a `view: 'settings'` entry so the system back gesture / hardware
  // back button (and browser ←) can pop us back to the home view instead
  // of exiting the APP / navigating away. Skip if we're already at this
  // state to avoid duplicate entries on repeated openSettings clicks.
  if (recordHistory && window.history.state?.view !== "settings") {
    window.history.pushState({ view: "settings" }, "");
  }
}

function showLauncherHome() {
  if (!hasUserToken()) {
    showLauncherSettings();
    return;
  }
  launcherSettingsView.classList.add("hidden");
  launcherHomeView.classList.remove("hidden");
}

openSettingsButton.addEventListener("click", () => showLauncherSettings());
closeSettingsButton.addEventListener("click", () => {
  if (!hasUserToken()) return;
  // If we entered settings via pushState, route the close through
  // history.back() so the back-button event chain is consistent. The
  // popstate handler will hide the view. Falls back to a direct hide
  // when we somehow got here without the pushState entry.
  if (window.history.state?.view === "settings") {
    window.history.back();
  } else {
    showLauncherHome();
  }
});

refreshSessionsButton.addEventListener("click", async () => {
  // Disable + spin while the request is in flight so a rapid second
  // click can't queue two overlapping fetches that race each other to
  // mutate sessionList. The minimum-spin floor (~360ms) keeps the
  // animation perceptible even on a fast network — without it, the
  // class flickers on/off and the user can't tell the click registered.
  if (refreshSessionsButton.classList.contains("is-spinning")) return;
  refreshSessionsButton.classList.add("is-spinning");
  const spinStartedAt = performance.now();
  try {
    await refreshSessions();
  } finally {
    const elapsed = performance.now() - spinStartedAt;
    const remainder = Math.max(0, 360 - elapsed);
    setTimeout(() => {
      refreshSessionsButton.classList.remove("is-spinning");
    }, remainder);
  }
});

// Full SPA reload — drops WebSocket / terminal / pending writes / DOM
// state and re-parses the bundled assets from scratch. Useful when
// something gets wedged (terminal stuck mid-frame, IME composer stuck,
// stale CSS variables after a viewport oddity) and the user wants a
// clean slate without quitting/relaunching the APK. Two entry points
// keep the rare case reachable: the "保存并刷新" button in settings
// (folds settings-apply + reload into one action — the rest of the
// SPA reads backend/token from localStorage at boot so a soft reload
// is the simplest "apply everywhere" path), and a two-finger
// pull-down on the session list (mobile-friendly gesture that
// bypasses the single-finger list scroll).
function performAppReload() {
  // location.reload() is identical to a browser soft refresh: WebView
  // re-fetches index.html from the local assets, the module graph is
  // rebuilt, and every closure / event listener from the previous run
  // is dropped. We do NOT pass `true` (force-reload) — APK assets are
  // local files so cache semantics don't apply, and the deprecated
  // boolean argument trips MDN/lint warnings without any benefit here.
  window.location.reload();
}

// Two-finger pull-down on the session list as a quick gesture. Single
// finger is reserved for normal list scrolling; requiring two touch
// points makes the gesture intentional and removes any conflict with
// scrollTop tracking or rubber-band overscroll. Threshold is the
// average vertical displacement of the two contact points, so users
// don't have to keep their fingers perfectly parallel.
const TWO_FINGER_RELOAD_THRESHOLD_PX = 60;
let twoFingerStartY = null;
let twoFingerTriggered = false;

launcherHomeView.addEventListener(
  "touchstart",
  (event) => {
    if (event.touches.length !== 2) {
      twoFingerStartY = null;
      twoFingerTriggered = false;
      return;
    }
    twoFingerStartY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
    twoFingerTriggered = false;
  },
  { passive: true },
);

launcherHomeView.addEventListener(
  "touchmove",
  (event) => {
    if (twoFingerStartY == null) return;
    if (event.touches.length !== 2) {
      // User lifted/added a finger mid-gesture — abandon the pull so a
      // later single-finger scroll doesn't accidentally cross the
      // threshold against the stale anchor.
      twoFingerStartY = null;
      twoFingerTriggered = false;
      return;
    }
    const currentY =
      (event.touches[0].clientY + event.touches[1].clientY) / 2;
    if (
      currentY - twoFingerStartY >= TWO_FINGER_RELOAD_THRESHOLD_PX &&
      !twoFingerTriggered
    ) {
      twoFingerTriggered = true;
    }
  },
  { passive: true },
);

launcherHomeView.addEventListener(
  "touchend",
  () => {
    const shouldReload = twoFingerTriggered;
    twoFingerStartY = null;
    twoFingerTriggered = false;
    if (shouldReload) performAppReload();
  },
  { passive: true },
);

launcherHomeView.addEventListener(
  "touchcancel",
  () => {
    twoFingerStartY = null;
    twoFingerTriggered = false;
  },
  { passive: true },
);
// Keep the back button's enabled state in sync as the user types or
// clears the token — without this, clearing the field mid-edit leaves
// the button enabled and the user could escape with no token.
tokenInput.addEventListener("input", () => {
  if (!launcherSettingsView.classList.contains("hidden")) {
    closeSettingsButton.disabled = !hasUserToken();
  }
  syncDownloadApkButton();
});

function syncDownloadApkButton() {
  downloadApkButton.disabled = !hasUserToken();
}

function resetDownloadApkUI(message) {
  downloadApkButton.disabled = !hasUserToken();
  downloadApkButton.textContent = "下载 Android 安装包";
  if (message) downloadApkHint.textContent = message;
}

async function downloadApk() {
  // Two-step flow: trade the Bearer user token for a short-lived URL
  // grant, then navigate the window at /api/app/android?dl=<grant>. The
  // blob + <a download> approach fails on Huawei/UC/in-app webviews
  // because they refuse to trigger downloads off object URLs; a direct
  // navigation lets the browser honour Content-Disposition natively.
  const token = tokenInput.value.trim();
  if (!token) {
    resetDownloadApkUI("请先填写 User Token。");
    return;
  }
  downloadApkButton.disabled = true;
  downloadApkButton.textContent = "准备中…";
  downloadApkHint.textContent = "正在请求下载授权。";
  try {
    const grantResp = await fetch(apiURL("/api/app/android/grant"), {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (grantResp.status === 401) {
      resetDownloadApkUI("Token 无效或已失效，请重新输入。");
      return;
    }
    if (!grantResp.ok) {
      resetDownloadApkUI(`授权失败（HTTP ${grantResp.status}）。`);
      return;
    }
    const { token: grant } = await grantResp.json();
    if (!grant) {
      resetDownloadApkUI("授权响应缺少 token，请联系管理员。");
      return;
    }
    const downloadURL = apiURL("/api/app/android");
    downloadURL.searchParams.set("dl", grant);
    // Cosmetic only — the actual navigation below is what triggers the
    // browser's download. Reset shortly after so the button isn't stuck
    // in case the browser stays on the page (Content-Disposition typically
    // keeps the current page alive).
    downloadApkHint.textContent = "已请求下载，浏览器应该开始保存文件。";
    setTimeout(() => resetDownloadApkUI("如果未弹出下载，请检查浏览器下载管理。"), 3000);
    window.location.href = downloadURL.toString();
  } catch (err) {
    resetDownloadApkUI(`下载失败：${err?.message ?? err}`);
  }
}

downloadApkButton.addEventListener("click", () => {
  downloadApk();
});

syncDownloadApkButton();

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
  // Stop any in-flight momentum before we wipe pan state. Without
  // this, a flying momentum step could fire one frame later and
  // re-commit a translate while applyDesktopWidthSize is still in
  // its rAF deferring panToBottom.
  cancelPanMomentum();
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

// Pan momentum: after the user lifts their finger from a swipe, keep
// scrolling for ~800ms-1s under decaying velocity so the gesture feels
// like physical inertia instead of "snap-stop on release". iOS-style
// (friction 0.95 / frame).
//
// Scope: only desktop-width pan (X + Y). Terminal scrollback is left to
// dist's smoothScroll (which has its own ~150ms ease-out). Boundary
// behaviour: hit panX=0 / panX=max → cancel immediately, no rubber-
// banding, no transfer-to-scrollback. Any new touchstart cancels
// in-flight momentum so the next gesture starts from rest.
//
// The rAF chain here is short-lived (200-800ms) and only mutates
// `terminalMount.style.transform` via commitDesktopPan — it doesn't
// touch canvas or trigger schedulePaint, so it's compositor-only and
// doesn't fight the on-demand render strategy.
const PAN_MOMENTUM_FRICTION = 0.95; // per 16ms frame
const PAN_MOMENTUM_MIN_VELOCITY = 0.05; // px/ms (≈3 px/frame at 60Hz)
const PAN_MOMENTUM_SAMPLE_WINDOW_MS = 100;
// Cap on the velocity seeded into the momentum chain. Without this, a
// spurious final touchmove sample (last 2 events 1ms apart but 30px
// jump because of pointer-coalescing) could seed v > 20 px/ms which
// flings the pan past max in a single frame and feels unhinged.
const PAN_MOMENTUM_MAX_INITIAL_VELOCITY = 4.0; // px/ms

let panMomentumFrame = null;
let panMomentumAxis = null; // 'x' | 'y' | null
let panMomentumVelocity = 0; // px/ms
let panMomentumLastT = 0;

function cancelPanMomentum() {
  if (panMomentumFrame !== null) {
    cancelAnimationFrame(panMomentumFrame);
    panMomentumFrame = null;
  }
  panMomentumAxis = null;
  panMomentumVelocity = 0;
}

function startPanMomentum(axis, velocity) {
  if (axis !== "x" && axis !== "y") return;
  if (!isDesktopWidthMode()) return;
  if (Math.abs(velocity) < PAN_MOMENTUM_MIN_VELOCITY) return;
  cancelPanMomentum();
  panMomentumAxis = axis;
  // Clamp absurd seed values from coalesced pointer events.
  panMomentumVelocity = Math.max(
    -PAN_MOMENTUM_MAX_INITIAL_VELOCITY,
    Math.min(PAN_MOMENTUM_MAX_INITIAL_VELOCITY, velocity),
  );
  panMomentumLastT = performance.now();
  panMomentumFrame = requestAnimationFrame(panMomentumStep);
}

function panMomentumStep(t) {
  if (panMomentumAxis === null) {
    panMomentumFrame = null;
    return;
  }
  // Cap dt so a slow rAF (tab in background just resurfaced, GC pause)
  // doesn't fling the pan by a huge delta on the recovery frame.
  const dt = Math.max(1, Math.min(50, t - panMomentumLastT));
  panMomentumLastT = t;
  // Frame-rate-independent decay: at 60 Hz (dt≈16) this matches the
  // chosen per-frame friction exactly; at 30 Hz the per-step decay is
  // friction^2 so the visible curve is unchanged.
  panMomentumVelocity *= Math.pow(PAN_MOMENTUM_FRICTION, dt / 16);
  if (Math.abs(panMomentumVelocity) < PAN_MOMENTUM_MIN_VELOCITY) {
    cancelPanMomentum();
    return;
  }
  const delta = panMomentumVelocity * dt;
  // applyDesktopPan{,Y} both clamp to [0, max]; we detect "hit a
  // boundary" by checking whether the value moved when we asked it to.
  if (panMomentumAxis === "x") {
    const prev = desktopPanX;
    applyDesktopPan(desktopPanX - delta);
    if (desktopPanX === prev && delta !== 0) {
      cancelPanMomentum();
      return;
    }
  } else {
    const prev = desktopPanY;
    applyDesktopPanY(desktopPanY - delta);
    if (desktopPanY === prev && delta !== 0) {
      cancelPanMomentum();
      return;
    }
  }
  panMomentumFrame = requestAnimationFrame(panMomentumStep);
}

// Record a touchmove sample into the gesture's ring buffer. Bounded
// at 24 entries because we only need the last 100ms (≈6 frames on
// 60Hz), and a tight cap stops a slow drag from accumulating a
// thousand-entry buffer.
function recordPanSample(state, touch) {
  if (!state || !state.panSamples) return;
  state.panSamples.push({
    t: performance.now(),
    x: touch.clientX,
    y: touch.clientY,
  });
  if (state.panSamples.length > 24) {
    state.panSamples.shift();
  }
}

// Compute fling velocity from the tail of the touchmove sample buffer.
// We use the oldest sample within the last PAN_MOMENTUM_SAMPLE_WINDOW_MS
// rather than the last 2 samples because pointer-coalescing in modern
// browsers means consecutive samples can be unreliable (same-frame events
// merged into one dispatch with synthetic timestamps).
function computePanVelocity(samples, axis) {
  if (!samples || samples.length < 2) return 0;
  const last = samples[samples.length - 1];
  const cutoff = last.t - PAN_MOMENTUM_SAMPLE_WINDOW_MS;
  let first = null;
  for (let i = 0; i < samples.length; i++) {
    if (samples[i].t >= cutoff) {
      first = samples[i];
      break;
    }
  }
  if (!first || first === last) return 0;
  const dt = last.t - first.t;
  if (dt <= 0) return 0;
  const delta = axis === "x" ? last.x - first.x : last.y - first.y;
  return delta / dt;
}

// Vertical pan strategy:
//
// - Default to "pan to grid bottom" so the host TUI's status bar /
//   spinner area (which lives at the bottom of the grid, e.g. Claude
//   Code's footer) sits just above the mobile toolbar. The input
//   prompt and cursor are above that — both still visible because
//   the locked grid is ~48 rows and the viewport holds ~27, leaving
//   plenty of margin once we've anchored to the bottom.
//
// - Fall back to "no pan" only when grid-bottom anchoring would
//   scroll the host cursor off the top of the viewport. That's the
//   freshly-opened-shell case (cursor on row 2 of a 48-row grid)
//   where the prompt is near the very top and there's nothing
//   interesting at the bottom yet.
//
// Earlier attempts tried to anchor the cursor row to the visible
// bottom (panToCursor). That hides the status bar whenever the host
// cursor sits at the input row, which is exactly where Claude Code
// keeps it — the status bar with model/token/spinner data ends up
// pushed behind the toolbar. Switching to grid-bottom-anchored with
// the cursor-out-of-viewport guard recovers the status bar without
// losing the freshly-opened-shell case.
function panToBottom() {
  const max = maxDesktopPanY();
  if (max <= 0 || !terminal) {
    applyDesktopPanY(max);
    return;
  }
  const cursorY = terminal.buffer?.active?.cursorY;
  const cellH = currentCellHeightPx();
  if (cursorY == null || !(cellH > 0)) {
    applyDesktopPanY(max);
    return;
  }
  // cursor row top edge in #terminal coords. If panning all the way
  // to grid-bottom would put it above the visible area (negative
  // viewport y), the host cursor isn't anywhere near the bottom yet
  // (early-session case). Use pan = 0 so the top of the grid is the
  // reference frame; once the cursor moves further down the natural
  // grid-bottom anchor takes over.
  const cursorTopPx = cursorY * cellH;
  applyDesktopPanY(cursorTopPx >= max ? max : 0);
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
  //
  // Must read DPR from the renderer instance, not `window.devicePixelRatio`:
  // the low-resolution rendering setting caps `renderer.devicePixelRatio`
  // below `window.devicePixelRatio`, and reading the window value here
  // would divide canvas.width by too large a denominator → cellW reported
  // as ~half real → desktop-width container under-allocated → right
  // columns clipped.
  const canvas = terminal?.element?.querySelector?.("canvas");
  const cols = terminal?.cols ?? 0;
  if (canvas && canvas.width > 0 && cols > 0) {
    const dpr =
      terminal?.renderer?.devicePixelRatio ?? window.devicePixelRatio ?? 1;
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

lowResRenderSelect.addEventListener("change", () => {
  const level = lowResRenderSelect.value;
  // Defence against a stray DOM mutation: only persist values we
  // actually recognise so the next page-load doesn't fall back to
  // default silently because the value is gibberish.
  if (level in LOW_RES_LEVELS) {
    localStorage.setItem(LOW_RES_RENDER_KEY, level);
  }
  // Apply live to the active terminal. When no terminal is open yet
  // (user is still on the launcher) this is a no-op — the next
  // installOnDemandRender will read the select value.
  applyRendererDpr();
  // After the DPR cap changes, cellW in CSS px is unchanged (metric
  // is DPR-independent), but `currentCellWidthPx` derives from
  // canvas.width / DPR — and `renderer.resize` runs synchronously
  // inside applyRendererDpr. Re-run applyDesktopWidthSize so the
  // desktop-width container width stays in sync if the user is
  // toggling while in desktop-width mode.
  applyDesktopWidthSize();
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

// Live-frame coalescing + visibility throttle.
//
// Hot path is socket onmessage → scheduleTermWrite. Multiple writes
// inside one window merge into a single `terminal.write`, pinning
// the effective render rate regardless of how fast the host emits.
// Spinner TUIs at 60+ Hz were making the phone hot because the
// canvas renderer repaints on every write; coalescing cuts repaint
// count by an order of magnitude. We pick the window per platform:
//
//   - Touch-input devices (APK + phones / tablets, gated purely by
//     `pointer: coarse` so a narrow desktop window does NOT trip into
//     this branch): 80 ms ≈ 12 FPS. Still above the perceptual floor
//     (~10 FPS) so text-mode spinners read as continuous motion, but
//     ~40% fewer paints than the desktop setting, which directly
//     trims canvas fillRect / GPU composite work + battery on phones.
//   - Mouse/keyboard browsers: 50 ms = 20 FPS. PCs aren't thermally
//     constrained and users expect snappier feedback for spinners /
//     typing echo even when the window is narrow.
//
// When the page is hidden we keep accumulating bytes but skip the
// flush entirely — a backgrounded WebView shouldn't be burning
// CPU/GPU on invisible repaints. A 1 MB cap bounds the buffer so a
// long background stretch can't OOM the WebView; the snapshot frame
// re-anchors anyway, so dropping the oldest queued bytes is safe.
const PENDING_WRITE_CAP_BYTES = 1024 * 1024;
const PENDING_WRITE_THROTTLE_MS_MOBILE = 80;
const PENDING_WRITE_THROTTLE_MS_DESKTOP = 50;

function pendingWriteThrottleMs() {
  // Use pointer:coarse (the actual "touch input device" signal)
  // rather than shouldUseMobileInput() — the latter also flips true
  // on narrow PC viewports (max-width: 860px) for UI layout reasons,
  // but a narrow PC window is still a PC: not thermally constrained,
  // and the user expects snappy spinner / echo response. Only slow
  // down the throttle when the input device itself is touch-only.
  return window.matchMedia("(pointer: coarse)").matches
    ? PENDING_WRITE_THROTTLE_MS_MOBILE
    : PENDING_WRITE_THROTTLE_MS_DESKTOP;
}
let pendingWriteChunks = [];
let pendingWriteSize = 0;
let pendingWriteTimer = null;

function scheduleTermWrite(bytes) {
  if (!terminal || !bytes || bytes.length === 0) return;
  pendingWriteChunks.push(bytes);
  pendingWriteSize += bytes.length;
  while (
    pendingWriteSize > PENDING_WRITE_CAP_BYTES &&
    pendingWriteChunks.length > 1
  ) {
    const dropped = pendingWriteChunks.shift();
    pendingWriteSize -= dropped.length;
  }
  if (document.hidden) return;
  if (pendingWriteTimer != null) return;
  pendingWriteTimer = window.setTimeout(() => {
    pendingWriteTimer = null;
    flushPendingWrites();
  }, pendingWriteThrottleMs());
}

function flushPendingWrites() {
  if (pendingWriteTimer != null) {
    window.clearTimeout(pendingWriteTimer);
    pendingWriteTimer = null;
  }
  if (!terminal || pendingWriteChunks.length === 0) return;
  const total = pendingWriteSize;
  const combined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of pendingWriteChunks) {
    combined.set(chunk, offset);
    offset += chunk.length;
  }
  pendingWriteChunks = [];
  pendingWriteSize = 0;
  terminal.write(combined);
}

function dropPendingWrites() {
  pendingWriteChunks = [];
  pendingWriteSize = 0;
  if (pendingWriteTimer != null) {
    window.clearTimeout(pendingWriteTimer);
    pendingWriteTimer = null;
  }
}

// On-demand render: replace upstream's unconditional 60 Hz rAF chain
// with a single-frame rAF scheduled only when terminal state actually
// changes.
//
// `ghostty-web` v0.4.0's `Terminal.startRenderLoop` re-arms
// `requestAnimationFrame` every frame regardless of dirty state, and
// the only paint path lives inside that loop — `write`, `clear`,
// `reset`, selection updates, and smooth-scroll all mutate state then
// rely on the next tick of the loop to paint. On a mobile WebView
// this pins CPU above idle even with `cursorBlink: false` and no
// inbound writes, worst in desktop-width landscape where the canvas
// backing buffer is oversized.
//
// Strategy:
//   1. Kill the constant rAF chain entirely (override startRenderLoop).
//   2. Provide a single-frame `schedulePaint` with rAF dedupe.
//   3. Wrap the prototype methods that mutate visible state but don't
//      paint themselves (`write` / `clear` / `reset` / `paste`).
//   4. Subscribe to the public emitters that fire on every internal
//      mutation that doesn't go through (3): `onScroll` covers smooth-
//      scroll / wheel / scrollTo*; `onSelectionChange` covers selection
//      drag; `onResize` is idempotent (dist already paints in resize).
//   5. Keep the existing capture-phase mouse/touch/wheel DOM listeners
//      as a belt for `processMouseMove` (hover link state change has
//      no emitter — the only blind spot in the emitter coverage).
//
// Idle behaviour: zero rAF, zero main-thread wake. Under burst writes
// the existing pendingWrite throttle (50 ms desktop / 80 ms mobile)
// caps rAF frequency to ≤20 Hz.
let scheduledPaintFrame = null;

function schedulePaint() {
  if (!terminal || terminal.isDisposed || !terminal.isOpen) return;
  if (scheduledPaintFrame != null) return;
  scheduledPaintFrame = window.requestAnimationFrame(() => {
    scheduledPaintFrame = null;
    if (!terminal || terminal.isDisposed || !terminal.isOpen) return;
    const renderer = terminal.renderer;
    const wasm = terminal.wasmTerm;
    if (!renderer || !wasm) return;
    try {
      renderer.render(
        wasm,
        false,
        terminal.viewportY,
        terminal,
        terminal.scrollbarOpacity,
      );
    } catch (_) {}
  });
}

function cancelScheduledPaint() {
  if (scheduledPaintFrame != null) {
    window.cancelAnimationFrame(scheduledPaintFrame);
    scheduledPaintFrame = null;
  }
}

// Install the on-demand patch on a fresh Terminal instance. Must run
// AFTER `terminal.open(parent)` because (a) open() starts the dist
// rAF chain we need to cancel, and (b) `selectionManager` is created
// inside open() — onSelectionChange fires nothing until then.
function installOnDemandRender(t) {
  // (1) Cancel the rAF chain dist's open() just started.
  if (t.animationFrameId != null) {
    window.cancelAnimationFrame(t.animationFrameId);
    t.animationFrameId = undefined;
  }
  // (2) Neutralise startRenderLoop. dist's resize / setColsRows do
  // NOT call it again (they paint inline), but any future refresh
  // path that does will simply enqueue one frame.
  t.startRenderLoop = function () {
    schedulePaint();
  };

  // (3) Wrap mutating prototype methods on this instance. Prototype-
  // level wrap would leak across hypothetical future Terminal
  // instances; instance wrap is scoped and survives dispose by virtue
  // of the next ensureTerminal() building a fresh instance.
  const origWrite = t.write.bind(t);
  t.write = function (data, callback) {
    const ret = origWrite(data, callback);
    schedulePaint();
    return ret;
  };
  const origClear = t.clear.bind(t);
  t.clear = function () {
    const ret = origClear();
    schedulePaint();
    return ret;
  };
  const origReset = t.reset.bind(t);
  t.reset = function () {
    const ret = origReset();
    schedulePaint();
    return ret;
  };
  const origPaste = t.paste.bind(t);
  t.paste = function (data) {
    const ret = origPaste(data);
    schedulePaint();
    return ret;
  };

  // (4) Subscribe to public emitters for state changes that don't
  // route through (3). dist source verified for v0.4.0:
  //   - animateScroll only fires scrollEmitter (no inline render)
  //   - selectionManager.onSelectionChange only fires
  //     selectionChangeEmitter (no inline render)
  //   - resize already paints inline; onResize subscription is
  //     idempotent (rAF dedupes the second schedule away)
  t.onScroll(() => schedulePaint());
  t.onSelectionChange(() => schedulePaint());
  t.onResize(() => schedulePaint());

  // (5) Apply the low-res DPR cap immediately so the very first
  // post-open paint already runs at the chosen resolution. Without
  // this the canvas would briefly allocate at native DPR before the
  // cap kicks in (one frame of wasted backing buffer + an avoidable
  // re-resize).
  applyRendererDpr(true);

  // (6) dist's open() already painted once before startRenderLoop.
  // We just cancelled that loop; schedule one explicit paint so any
  // post-open state mutation that landed before installOnDemandRender
  // ran is reflected. applyRendererDpr already calls schedulePaint
  // when it actually changes DPR, but it's a no-op when the requested
  // DPR equals what dist initialised — explicit schedule here covers
  // that branch.
  schedulePaint();
}

// Low-res rendering preset. Cap the renderer's effective DPR so the
// canvas backing buffer shrinks (4× pixel savings on a DPR=3 phone at
// "balanced"). The cap is applied per-instance because `Terminal`'s
// constructor doesn't forward `RendererOptions.devicePixelRatio` — we
// have to reach into `terminal.renderer.devicePixelRatio` after
// `terminal.open()` builds the CanvasRenderer.
function currentLowResCap() {
  const level = lowResRenderSelect?.value ?? LOW_RES_DEFAULT_LEVEL;
  const cap = LOW_RES_LEVELS[level];
  return Number.isFinite(cap) ? cap : Number.POSITIVE_INFINITY;
}

function computeRendererDpr() {
  const native = window.devicePixelRatio || 1;
  return Math.min(native, currentLowResCap());
}

// Apply the target DPR to the live renderer. `force=true` always
// resizes (used on first install where the renderer was created with
// the upstream default — we may want to override even when the values
// happen to match a freshly-set field). Otherwise no-op when the
// requested DPR equals the currently-applied one.
//
// Calling `renderer.resize(cols, rows)` is mandatory after changing
// `devicePixelRatio`: it (a) reallocates canvas.width/height to
// cssW × newDPR, (b) re-applies `ctx.scale(newDPR, newDPR)` so all
// subsequent draws are scaled correctly. Without the resize the ctx
// scale stays at the old DPR and rendering output is misaligned.
function applyRendererDpr(force = false) {
  if (!terminal || terminal.isDisposed || !terminal.isOpen) return;
  const renderer = terminal.renderer;
  if (!renderer) return;
  const target = computeRendererDpr();
  if (!force && renderer.devicePixelRatio === target) return;
  renderer.devicePixelRatio = target;
  try {
    renderer.resize(terminal.cols, terminal.rows);
  } catch (_) {}
  schedulePaint();
}

// Tear down the xterm instance + DOM nodes it created, so the next
// `ensureTerminal()` call rebuilds from scratch. `terminal.reset()` /
// `\x1b[3J` cannot clean cross-session leaks like cursor blink state,
// IME composer fragments, or stale renderer textures — only a fresh
// instance is guaranteed-clean. Caller is responsible for clearing
// `replayBuffer` and other module state separately.
function disposeTerminal() {
  if (!terminal) return;
  cancelScheduledPaint();
  // Pan momentum may be flying over the about-to-die canvas; the
  // step rAF only touches DOM transform on terminalMount (which we
  // wipe below) but cleaning up first avoids a stray rAF callback
  // operating on a stale terminalMount.style after innerHTML clear.
  cancelPanMomentum();
  // Any rAF-queued bytes belong to the terminal we're about to throw
  // away; flushing them onto the next instance would smear stale
  // frames into a fresh session.
  dropPendingWrites();
  try {
    fitAddon?.dispose?.();
  } catch (_) {}
  try {
    terminal.dispose();
  } catch (_) {}
  fitAddon = null;
  terminal = null;
  if (terminalMount) terminalMount.innerHTML = "";
  // Pan transforms live on the mount element; once we wipe the DOM
  // they're effectively meaningless but the inline style hangs around
  // and the next mount inherits it.
  if (terminalMount) {
    terminalMount.style.transform = "";
    terminalMount.style.width = "";
    terminalMount.style.minWidth = "";
    terminalMount.style.height = "";
    terminalMount.style.minHeight = "";
  }
  desktopPanX = 0;
  desktopPanY = 0;
}

async function ensureTerminal() {
  if (terminal) return terminal;
  await init();
  terminal = new Terminal({
    fontSize: 14,
    // cursorBlink off — the blink redraw is ~2 Hz on a busy mobile
    // canvas renderer; with a live mirror feeding spinner frames at
    // 1-30 Hz the extra repaint compounds heat / battery on top.
    cursorBlink: false,
    theme: {
      background: "#171412",
      foreground: "#f5f0e8",
    },
  });
  terminal.open(terminalMount);
  // `terminal.open` starts dist's unconditional 60 Hz rAF chain.
  // Replace it with the on-demand single-frame schedule.
  // See installOnDemandRender / schedulePaint.
  installOnDemandRender(terminal);
  // Re-anchor the pan to the bottom-right whenever .terminal-host
  // resizes — the soft keyboard appearing, the mobile toolbar
  // expanding, or the URL bar showing/hiding all shrink the visible
  // area without firing terminal.onResize. Without this, panY would
  // be left at its previous value while the new bottom edge is
  // further down, hiding the cursor row again. Guarded so repeat
  // ensureTerminal calls (after disposeTerminal) don't accumulate
  // ResizeObserver leaks.
  if (
    !globalTerminalListenersInstalled &&
    typeof ResizeObserver !== "undefined"
  ) {
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
  if (!globalTerminalListenersInstalled) {
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
    // Belt for the one emitter blind spot: `processMouseMove` updates
    // hoveredHyperlinkId / hoveredLinkRange without firing any public
    // emitter, so without these listeners the hover link underline +
    // cursor style change wouldn't repaint until something else fires
    // a paint. Listeners are installed once on terminalMount and
    // survive disposeTerminal because the mount element itself is not
    // destroyed.
    //
    // The other paths (write/scroll/selection/resize) are already
    // covered by installOnDemandRender's emitter subscriptions and
    // method wraps — these listeners are redundant for those but
    // schedulePaint dedupes via rAF so the overlap is free.
    const wake = () => schedulePaint();
    const wakeEvents = [
      "touchstart",
      "touchmove",
      "mousedown",
      "mousemove",
      "wheel",
    ];
    for (const evt of wakeEvents) {
      terminalMount.addEventListener(evt, wake, {
        capture: true,
        passive: true,
      });
    }
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) schedulePaint();
    });
    globalTerminalListenersInstalled = true;
  }
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
    // No explicit paint needed: installOnDemandRender subscribes to
    // onResize and dist itself paints inline inside resize().
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
    // Tear the prior xterm instance down before the terminal element
    // is un-hidden. `reset()` + `\x1b[3J` weren't enough — cross-session
    // residue still leaked through (renderer textures, IME composer
    // shards, the alt-buffer/scrollback split, etc). Rebuilding via
    // `ensureTerminal()` below is the only guaranteed-clean reset.
    // Covers every entry path: launcher click, direct URL deep-link,
    // first session after page load, auto-reconnect after socket drop.
    disposeTerminal();
    replayBuffer.onScreen(new Uint8Array(0));
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
      refreshUploadLauncherVisibility();
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
      refreshUploadLauncherVisibility();
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
      scheduleTermWrite(bytes);
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
    case "upload_ack":
      uploadManager.handleAckFrame(frame);
      return;
    default:
      if (terminal) terminal.write(data);
  }
}

// ---- Upload UI ---------------------------------------------------------
// Per-upload toast handles, keyed by the toastId picked by the manager so
// successive updates (progress → done) replace the same DOM node instead
// of stacking.
const uploadToastNodes = new Map();

function renderUploadToast(payload) {
  const id = payload.id;
  if (!id) return;
  let node = uploadToastNodes.get(id);
  if (!node) {
    node = document.createElement("div");
    node.className = "upload-toast";
    node.dataset.id = id;
    const title = document.createElement("div");
    title.className = "upload-toast-title";
    const body = document.createElement("div");
    body.className = "upload-toast-body";
    const progress = document.createElement("span");
    progress.className = "upload-toast-progress";
    const bar = document.createElement("span");
    progress.appendChild(bar);
    node.append(title, body, progress);
    uploadToastStack.appendChild(node);
    uploadToastNodes.set(id, node);
  }
  node.classList.remove("pending", "success", "error");
  node.classList.add(payload.kind ?? "pending");
  node.querySelector(".upload-toast-title").textContent = payload.title ?? "";
  node.querySelector(".upload-toast-body").textContent = payload.message ?? "";
  const progressBar = node
    .querySelector(".upload-toast-progress > span");
  if (typeof payload.progress === "number") {
    const pct = Math.min(100, Math.max(0, Math.round(payload.progress * 100)));
    progressBar.style.width = `${pct}%`;
    node.querySelector(".upload-toast-progress").style.display = "block";
  } else {
    node.querySelector(".upload-toast-progress").style.display = "none";
  }
  // Auto-dismiss terminal states after a few seconds so the stack stays
  // tidy. Pending toasts persist indefinitely — they will be replaced
  // by a terminal-state toast under the same id.
  if (payload.kind === "success" || payload.kind === "error") {
    setTimeout(() => {
      if (uploadToastNodes.get(id) === node) {
        node.remove();
        uploadToastNodes.delete(id);
      }
    }, payload.kind === "success" ? 6000 : 9000);
  }
}

const uploadManager = createUploadManager({
  // Capture the *current* values at call time, not at module init —
  // the user can change either from the settings sheet before
  // starting an upload.
  get backendBase() {
    return backendBaseInput.value.trim() || location.origin;
  },
  get userToken() {
    return tokenInput.value.trim();
  },
  getActiveSessionId: () => activeSession?.id ?? null,
  onToast: renderUploadToast,
  logEvt: (line) => logEvt(line),
});

function refreshUploadLauncherVisibility() {
  const connected =
    activeSession != null && socket && socket.readyState === WebSocket.OPEN;
  // The upload pill rides the same row as the toolbar toggle, so when
  // the user collapses the toolbar we hide the pill too — otherwise it
  // floats orphaned over the terminal area. Connection state is the
  // hard gate (no relay → nothing to upload to); collapsed state is the
  // courtesy gate.
  const visible = connected && !mobileToolbarCollapsed;
  mobileUploadLauncher.classList.toggle("hidden", !visible);
  mobileUploadLauncher.disabled = !visible;
}

mobileUploadLauncher.addEventListener("click", () => {
  uploadFileInput.value = "";
  uploadFileInput.click();
});

uploadFileInput.addEventListener("change", () => {
  const files = Array.from(uploadFileInput.files ?? []);
  uploadFileInput.value = "";
  enqueueUploads(files);
});

function enqueueUploads(files) {
  if (!files || files.length === 0) return;
  if (!activeSession || !socket || socket.readyState !== WebSocket.OPEN) {
    // The relay won't accept an init without an online session, so don't
    // even start the request: surface a toast so the user knows why their
    // drop / paste seemed to vanish.
    renderUploadToast({
      id: `noop-${Date.now()}`,
      kind: "error",
      title: "未连接",
      message: "请先连接到会话再上传",
    });
    return;
  }
  for (const file of files) {
    uploadManager.start(file).catch((err) => {
      logEvt(`upload start failed: ${err}`);
    });
  }
}

// Drag-and-drop. We attach to #terminal's parent so the overlay can pick
// up the events; events that bubble up from the canvas still hit us.
// dragenter/dragleave fire repeatedly as the mouse moves over child
// elements, so we use a counter to know when we've actually left.
const terminalHostElement = terminalMount.parentElement;
let dragDepth = 0;

function setDragVisual(active) {
  if (!terminalHostElement) return;
  terminalHostElement.classList.toggle("upload-dropping", active);
}

function dragHasFiles(event) {
  // Some browsers populate `dataTransfer.types` as a DOMStringList that
  // doesn't implement `includes`, so we iterate. "Files" is the standard
  // payload type for dragged OS files (vs. text from the terminal etc).
  const types = event.dataTransfer?.types;
  if (!types) return false;
  for (const t of types) {
    if (t === "Files") return true;
  }
  return false;
}

window.addEventListener("dragenter", (event) => {
  if (!dragHasFiles(event)) return;
  // Only react while the terminal view is the active page; we don't
  // want a drop on the launcher to feel like it'll upload.
  if (terminalView.classList.contains("hidden")) return;
  event.preventDefault();
  dragDepth++;
  setDragVisual(true);
});

window.addEventListener("dragover", (event) => {
  if (!dragHasFiles(event)) return;
  if (terminalView.classList.contains("hidden")) return;
  // preventDefault is required to allow "drop" to fire.
  event.preventDefault();
  event.dataTransfer.dropEffect = "copy";
});

window.addEventListener("dragleave", (event) => {
  if (!dragHasFiles(event)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) setDragVisual(false);
});

window.addEventListener("drop", (event) => {
  if (!dragHasFiles(event)) return;
  if (terminalView.classList.contains("hidden")) return;
  event.preventDefault();
  dragDepth = 0;
  setDragVisual(false);
  const files = Array.from(event.dataTransfer?.files ?? []);
  enqueueUploads(files);
});

// Paste. Modern browsers expose dropped/pasted files via DataTransfer's
// `files` and `items`. Inline pasted images (e.g. from a screenshot tool)
// arrive as `items` of kind "file" whose getAsFile() returns a File with
// `name === "image.png"` or similar — perfectly suitable to upload.
window.addEventListener("paste", (event) => {
  if (terminalView.classList.contains("hidden")) return;
  // Don't hijack pastes that target an input field — the launcher
  // settings page uses real <input>s and the user expects normal paste.
  const target = event.target;
  if (
    target instanceof HTMLElement
    && (target.tagName === "INPUT"
        || target.tagName === "TEXTAREA"
        || target.isContentEditable)
  ) {
    return;
  }
  const dt = event.clipboardData;
  if (!dt) return;
  let files = Array.from(dt.files ?? []);
  if (files.length === 0 && dt.items) {
    for (const item of dt.items) {
      if (item.kind === "file") {
        const f = item.getAsFile();
        if (f) files.push(f);
      }
    }
  }
  if (files.length === 0) return;
  event.preventDefault();
  enqueueUploads(files);
});

function applyScreenSnapshot(frame) {
  if (!terminal || typeof frame?.content !== "string") return;
  const bytes = decodeBase64(frame.content);
  if (!bytes) return;
  // Tail diagnostic: lets the touch-log show whether the agent
  // appended the cursor anchor escape (\x1b[<row>;<col>H) to the
  // snapshot. The duplicate-spinner bug needs that anchor to land.
  if (debugEnabled) {
    const tailLen = Math.min(30, bytes.length);
    const tail = bytes.subarray(bytes.length - tailLen);
    let repr = "";
    for (const b of tail) {
      if (b === 0x1b) repr += "\\x1b";
      else if (b >= 0x20 && b < 0x7f) repr += String.fromCharCode(b);
      else repr += `\\x${b.toString(16).padStart(2, "0")}`;
    }
    logEvt(`screen bytes=${bytes.length} tail=${repr}`);
  }
  // In live-mirror mode we never read the replayBuffer, so don't bother
  // feeding it. Snapshot still writes through below — it's the host's
  // re-anchor checkpoint and we want the viewport to match.
  if (!activeMirrorMode) replayBuffer.onScreen(bytes);
  // Drop anything coalesced for the next rAF: those bytes are
  // pre-snapshot live frames; the snapshot is a re-anchor checkpoint
  // and any earlier delta is by definition redundant once the
  // snapshot lands.
  dropPendingWrites();
  // Do NOT call terminal.reset() here — the agent's snapshot bytes
  // already begin with `\x1b[2J\x1b[H` (erase-in-display + home),
  // which clears the visible viewport per the VT spec without
  // touching scrollback. terminal.reset() goes further and wipes the
  // entire scrollback buffer; calling it on every snapshot was
  // producing the user-visible "screen blanks and gets redrawn"
  // flicker on a strict 5-minute cadence — nginx's upstream idle
  // timeout drops the agent's WebSocket, the agent auto-reconnects
  // and re-emits hello+appearance+screen, the relay forwards the
  // snapshot to every online client, and we used to reset+repaint
  // the entire terminal. Letting the snapshot's own CSI escapes do
  // the clearing makes the redraw seamless (no flash, scrollback
  // preserved across reconnects).
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
  dropPendingWrites();
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
  // Tear the xterm instance down on exit too — covers paths where the
  // user leaves the terminal view and stays in launcher for a while
  // (the DOM still shows the prior buffer if they switch tabs/apps
  // and come back). `connectToSession` repeats this on enter; both
  // directions kept symmetric on purpose.
  disposeTerminal();
  replayBuffer.onScreen(new Uint8Array(0));

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
  // Upload pill is bound to the same row → keep them in sync.
  refreshUploadLauncherVisibility();
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

  // .terminal-page is a flex column now (see index.html mobile media
  // query), so the toolbar's natural height is absorbed by the flex
  // layout — no JS measurement of offsetHeight, no CSS variable
  // feedback, no race during display:none → visible transitions.
  // visualViewport-driven --mobile-viewport-height above is the only
  // remaining handle the JS still needs for keyboard pop / URL-bar
  // changes; the toolbar position rides the flex container down with
  // it automatically.

  if (typeof logEvt === "function") {
    const vv = window.visualViewport;
    const termRect = terminalMount?.getBoundingClientRect();
    const hostRect = terminalMount?.parentElement?.getBoundingClientRect();
    const toolbarRect = mobileToolbar?.getBoundingClientRect();
    logEvt(
      `VV mobile=${mobile ? 1 : 0} ih=${window.innerHeight} vvh=${vv ? Math.round(vv.height) : "-"} vvtop=${vv ? Math.round(vv.offsetTop) : "-"} tbcollapsed=${mobileToolbarCollapsed ? 1 : 0} tb.oh=${mobileToolbar?.offsetHeight ?? "-"} tb.rect.bot=${toolbarRect ? Math.round(toolbarRect.bottom) : "-"} host.rect.bot=${hostRect ? Math.round(hostRect.bottom) : "-"} term.rect.bot=${termRect ? Math.round(termRect.bottom) : "-"} term.h=${termRect ? Math.round(termRect.height) : "-"}`,
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
    // Any finger-down cancels in-flight momentum so the new gesture
    // starts from rest. Without this, touchstart records lastPanX/Y
    // at the current finger position while momentum keeps shifting
    // desktopPanX/Y under it — the first touchmove computes dxStep
    // against a stale baseline and the pan jumps.
    cancelPanMomentum();
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
      // Ring buffer of recent samples, used by computePanVelocity at
      // touchend to seed momentum. Reset per gesture so a slow drag
      // followed by a fast flick doesn't average the two.
      panSamples: [],
      // Set by touchmove's pan branches; consumed by endTouchScroll to
      // decide whether to start momentum (and on which axis). null means
      // the gesture never entered a pan branch (scrollback fall-through
      // or a tap).
      lastPanAxis: null,
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
        touchScrollState.lastPanAxis = "x";
        recordPanSample(touchScrollState, touch);
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
        touchScrollState.lastPanAxis = "y";
        recordPanSample(touchScrollState, touch);
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
  // Snapshot momentum inputs BEFORE nulling the state. computePanVelocity
  // reads the recorded sample buffer; sign convention matches
  // applyDesktopPan(desktopPanX - delta) — positive velocity = finger
  // moving in the + direction, which propagates the pan in the same
  // direction the user was already swiping.
  const momentumAxis = touchScrollState.lastPanAxis;
  const momentumVelocity =
    wasMovedSwipe && momentumAxis
      ? computePanVelocity(touchScrollState.panSamples, momentumAxis)
      : 0;
  touchScrollState = null;
  if (wasMovedSwipe && momentumAxis) {
    startPanMomentum(momentumAxis, momentumVelocity);
  }
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
  if (document.visibilityState === "visible") {
    // While the tab was hidden scheduleTermWrite kept appending to
    // pendingWriteChunks but skipped the flush (see the
    // `if (document.hidden) return;` guard there). The ring buffer
    // FIFO-drops once it crosses PENDING_WRITE_CAP_BYTES, so the
    // tail may now contain a stale screen snapshot followed by
    // partial bytes that are no longer self-consistent — writing
    // them straight into the terminal paints "the picture as it was
    // mid-hide", which on Android looks like the canvas suddenly
    // reverting to an older frame as soon as the user taps to
    // unblank. Instead: drop the queued bytes (no replay of stale
    // content) and bounce the WebSocket so the relay re-emits a
    // client_connected event — the macOS agent reacts by pushing a
    // fresh screen snapshot, which is the only source-of-truth way
    // to reach the current host state. scheduleReconnect (already
    // wired via socket.onclose) handles the backoff + status UI.
    dropPendingWrites();
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.close(4000, "visibility_resync");
    }
    focusTerminal();
  }
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

window.addEventListener("popstate", async (event) => {
  // Settings view exit: if we're on the settings page and we just
  // popped past its `view: 'settings'` history entry, hide it back to
  // the home view. This handles both the in-app close button (via
  // history.back) and the Android system back gesture.
  const inSettings = !launcherSettingsView.classList.contains("hidden");
  const targetIsSettings = event.state?.view === "settings";
  if (inSettings && !targetIsSettings) {
    launcherSettingsView.classList.add("hidden");
    if (hasUserToken()) launcherHomeView.classList.remove("hidden");
    return;
  }

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

// Capacitor 8 doesn't auto-route the Android back gesture / hardware
// back button into WebView history — it emits a `backButton` event
// with `canGoBack` and expects JS to act. Without this, the default
// is App.finish() on every back press regardless of history depth.
// Browser builds skip this (window.Capacitor is undefined).
//
// At the root view we use the Android "press back again to exit"
// convention so an accidental swipe doesn't kill the APP.
const EXIT_CONFIRM_WINDOW_MS = 2000;
let lastBackPressAt = 0;

function showExitConfirmToast() {
  const existing = document.querySelector("#exit-confirm-toast");
  if (existing) existing.remove();
  const toast = document.createElement("div");
  toast.id = "exit-confirm-toast";
  toast.textContent = "再按一次返回退出";
  Object.assign(toast.style, {
    position: "fixed",
    bottom: "calc(env(safe-area-inset-bottom, 0px) + 24px)",
    left: "50%",
    transform: "translateX(-50%)",
    background: "rgba(0, 0, 0, 0.78)",
    color: "#fff",
    padding: "10px 18px",
    borderRadius: "20px",
    fontSize: "14px",
    lineHeight: "1",
    zIndex: "9999",
    pointerEvents: "none",
    boxShadow: "0 2px 10px rgba(0,0,0,0.3)",
  });
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), EXIT_CONFIRM_WINDOW_MS);
}

if (window.Capacitor?.isNativePlatform?.()) {
  import("@capacitor/app").then(({ App }) => {
    App.addListener("backButton", ({ canGoBack }) => {
      if (canGoBack) {
        window.history.back();
        return;
      }
      const now = Date.now();
      if (now - lastBackPressAt < EXIT_CONFIRM_WINDOW_MS) {
        App.exitApp();
        return;
      }
      lastBackPressAt = now;
      showExitConfirmToast();
    });
  });
}

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
