import { FitAddon, init, Terminal } from "ghostty-web";
import { buildAppearanceTheme } from "./appearance.js";
import { redactErrorMessage } from "./redaction.js";
import { createCoalescedScroll } from "./scroll.js";
import { createReplayBuffer } from "./scrollback.js";
import { createUploadManager } from "./upload.js";
import {
  activateWebBundle,
  clearOldBundles,
  downloadWebBundle,
  getLocalWebVersion,
  isWebUpdateSupported,
  resetToBundled,
} from "./web-update.js";
import {
  APK_NEED_INSTALL_PERMISSION,
  downloadAndInstallApk,
  isApkInstallSupported,
} from "./apk-installer.js";

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
const mobileKillLine = document.querySelector("#mobileKillLine");
const sessionActionsModal = document.querySelector("#sessionActionsModal");
const sessionActionsTargetEl = document.querySelector("#sessionActionsTarget");
const sessionCloseBtn = document.querySelector("#sessionCloseBtn");
const sessionCloseConfirmHint = document.querySelector(
  "#sessionCloseConfirmHint",
);
const sessionActionsCancelBtn = document.querySelector(
  "#sessionActionsCancelBtn",
);
const uploadFileInput = document.querySelector("#uploadFileInput");
const uploadToastStack = document.querySelector("#uploadToastStack");
const apkLocalVersionEl = document.querySelector("#apkLocalVersion");
const apkServerVersionEl = document.querySelector("#apkServerVersion");
const checkApkVersionBtn = document.querySelector("#checkApkVersionBtn");
const apkUpgradeBanner = document.querySelector("#apkUpgradeBanner");
const apkUpgradeBannerText = document.querySelector("#apkUpgradeBannerText");
const apkUpgradeBannerBtn = document.querySelector("#apkUpgradeBannerBtn");
const apkForceModal = document.querySelector("#apkForceModal");
const apkForceModalBtn = document.querySelector("#apkForceModalBtn");
const apkForceModalLocal = document.querySelector("#apkForceModalLocal");
const apkForceModalMin = document.querySelector("#apkForceModalMin");
const webLocalVersionEl = document.querySelector("#webLocalVersion");
const webServerVersionEl = document.querySelector("#webServerVersion");
const installWebUpdateBtn = document.querySelector("#installWebUpdateBtn");
const resetWebBundleBtn = document.querySelector("#resetWebBundleBtn");
const webUpdateHintEl = document.querySelector("#webUpdateHint");

// APK OTA version state. Populated on boot by loadLocalApkVersion +
// checkApkVersion, refreshed when the user opens settings or taps
// "check now". Compared in refreshVersionUI which paints the
// settings page + an upgrade-available banner.
const apkVersionInfo = {
  localVersionCode: 0,
  localVersionName: "(browser)",
  serverVersionCode: 0,
  serverVersionName: "unknown",
  serverAvailable: false,
  serverBuiltAt: "",
  hasUpdate: false,
  // minVersionCode comes from GHOSTTY_RELAY_MIN_APK_VERSION_CODE on
  // the relay. 0 = disabled (default). When local < min, the force
  // modal blocks all UI interaction until the user upgrades.
  minVersionCode: 0,
  forceUpgrade: false,
  lastCheckedAt: 0,
  lastCheckOk: false,
};

// Web OTA state. Local version is read via the GhosttyWebUpdate plugin
// (it reads the .version marker that the plugin writes after a
// successful extract). Server version comes from /api/web/manifest.json.
// On the browser build, localVersion stays "" and both buttons stay
// disabled — the hint text explains why.
const webVersionInfo = {
  localVersion: "",
  localSha: "",
  localPath: "",
  serverVersion: "",
  serverSha: "",
  serverBundleUrl: "",
  serverBuiltAt: "",
  serverAvailable: false,
  hasUpdate: false,
  // Repo-pinned minimum APK versionCode required by the currently
  // deployed web bundle (manifest.json field). Compared against local
  // APK code in refreshVersionUI; refreshVersionUI also folds in
  // apkVersionInfo.minVersionCode (relay env var) so whichever floor
  // is higher wins. Keeps "native bump" enforcement in the same
  // commit/deploy that needs it — no manual server env var dance.
  requiredApkVersionCode: 0,
  lastCheckedAt: 0,
  lastCheckOk: false,
  busy: false,
};

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
// Platform-aware default: APP / mobile browser get "light" (省电省发热,
// 几乎无糊感), PC 浏览器原生 DPR 文字最清晰所以 "off"。prefersMobileDefaults
// 同时也决定下面三个 checkbox 的默认值,保证"环境 → 默认偏好"一致。
const LOW_RES_DEFAULT_LEVEL = prefersMobileDefaults() ? "light" : "off";

// True when we should ship the mobile-friendly preset on by default.
// Capacitor 8 with androidScheme:"https" makes location.hostname ===
// "localhost" inside the APK shell; outside the APK we fall back to a
// UA hint. Picks up tablets too (iPad/Android tablets get the mobile
// preset, which matches the touch-input ergonomics they share with phones).
function prefersMobileDefaults() {
  if (typeof location !== "undefined" && location.hostname === "localhost") {
    return true;
  }
  const ua =
    typeof navigator !== "undefined" ? (navigator.userAgent ?? "") : "";
  return /Android|iPhone|iPad|iPod|IEMobile|Mobile|Phone/i.test(ua);
}
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
// Defaults: APP / mobile browser ship the mobile-friendly preset on
// (lock host size + desktop-width + live-mirror all checked); PC web
// ships all three off so desktop users keep PTY-follows-viewport and
// lazy-history scrollback. An explicit "0" stored by a prior toggle
// still wins, so a user who opted out stays opted out across reloads.
const defaultsOn = prefersMobileDefaults();
lockHostSizeInput.checked = readBoolPref(LOCK_HOST_SIZE_KEY, defaultsOn);
desktopWidthInput.checked = readBoolPref(DESKTOP_WIDTH_KEY, defaultsOn);
lowResRenderSelect.value = getInitialLowResLevel();
liveMirrorModeInput.checked = readBoolPref(LIVE_MIRROR_KEY, defaultsOn);

function readBoolPref(key, fallback) {
  const raw = localStorage.getItem(key);
  if (raw === null) return fallback;
  return raw === "1";
}

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
    const currentY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
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

// Cached labels so the banner / force-modal buttons can be restored after
// an in-app download finishes (the settings button is restored by
// resetDownloadApkUI). Captured once at module load from the static HTML.
const apkUpgradeBannerBtnLabel = apkUpgradeBannerBtn?.textContent ?? "下载";
const apkForceModalBtnLabel = apkForceModalBtn?.textContent ?? "下载最新 APK";

// Paint download progress on whichever entry point is visible. All three
// are updated (only one shows at a time) so downloadApk() doesn't need to
// know which one the user tapped. total <= 0 → no Content-Length, show MB.
function setApkDownloadProgress(received, total) {
  const label =
    total > 0
      ? `下载中 ${Math.round((received / total) * 100)}%`
      : `下载中 ${(received / 1024 / 1024).toFixed(1)} MB`;
  downloadApkButton.textContent = label;
  if (apkUpgradeBannerBtn) apkUpgradeBannerBtn.textContent = label;
  if (apkForceModalBtn) apkForceModalBtn.textContent = label;
  downloadApkHint.textContent = "正在下载并安装新版本，请稍候…";
}

function restoreApkDownloadButtons() {
  if (apkUpgradeBannerBtn) apkUpgradeBannerBtn.textContent = apkUpgradeBannerBtnLabel;
  if (apkForceModalBtn) apkForceModalBtn.textContent = apkForceModalBtnLabel;
}

async function downloadApk() {
  const token = tokenInput.value.trim();
  if (!token) {
    resetDownloadApkUI("请先填写 User Token。");
    return;
  }

  // Native APK build with the ApkInstaller plugin: download inside the app
  // (Bearer-auth direct download — no grant flow needed since the plugin
  // can set the Authorization header), show progress, and auto-launch the
  // system installer. Browsers / older APKs without the plugin fall through
  // to the grant-flow browser download below.
  if (isApkInstallSupported()) {
    downloadApkButton.disabled = true;
    setApkDownloadProgress(0, 0);
    try {
      const url = apiURL("/api/app/android").toString();
      await downloadAndInstallApk({
        url,
        token,
        onProgress: ({ received, total }) =>
          setApkDownloadProgress(received, total),
      });
      restoreApkDownloadButtons();
      resetDownloadApkUI("已开始安装，请在系统弹窗中确认。");
    } catch (err) {
      restoreApkDownloadButtons();
      const msg = String(err?.message ?? err);
      if (msg.includes(APK_NEED_INSTALL_PERMISSION)) {
        resetDownloadApkUI(
          "请在系统设置里允许「安装未知应用」，授权后重新点击下载。",
        );
      } else {
        resetDownloadApkUI(`下载失败：${msg}`);
      }
    }
    return;
  }

  // Two-step grant flow (browser / no-plugin APK): trade the Bearer user
  // token for a short-lived URL grant, then navigate the window at
  // /api/app/android?dl=<grant>. The blob + <a download> approach fails on
  // Huawei/UC/in-app webviews because they refuse to trigger downloads off
  // object URLs; a direct navigation lets the browser honour
  // Content-Disposition natively.
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
    setTimeout(
      () => resetDownloadApkUI("如果未弹出下载，请检查浏览器下载管理。"),
      3000,
    );
    window.location.href = downloadURL.toString();
  } catch (err) {
    resetDownloadApkUI(`下载失败：${err?.message ?? err}`);
  }
}

downloadApkButton.addEventListener("click", () => {
  downloadApk();
});

syncDownloadApkButton();

// APK version check / OTA upgrade-available prompt. Public endpoint
// (/api/app/version), no Bearer required, so this works on first boot
// before the user has saved their token. The result feeds into
// refreshVersionUI which paints both the settings row and the
// upgrade-available banner. We never block the rest of the boot on
// it — failures are silent + visible only in debug log.
//
// Local APK BuildConfig comes from @capacitor/app App.getInfo(); on
// the browser build there is no native version, we keep the default
// "(browser)" string so the settings row stays consistent.
async function loadLocalApkVersion() {
  if (!window.Capacitor?.isNativePlatform?.()) {
    apkVersionInfo.localVersionName = "(浏览器)";
    return;
  }
  try {
    const { App } = await import("@capacitor/app");
    const info = await App.getInfo();
    apkVersionInfo.localVersionCode = parseInt(info.build, 10) || 0;
    apkVersionInfo.localVersionName = info.version || "unknown";
  } catch (err) {
    logEvt(`App.getInfo failed ${err?.message || err}`);
  }
}

async function checkApkVersion() {
  let url;
  try {
    url = apiURL("/api/app/version");
  } catch (err) {
    logEvt(`apk version url invalid ${err?.message || err}`);
    return;
  }
  try {
    const response = await fetch(url.toString(), {
      method: "GET",
      credentials: "omit",
    });
    if (!response.ok) {
      logEvt(`apk version check failed status=${response.status}`);
      apkVersionInfo.lastCheckedAt = Date.now();
      apkVersionInfo.lastCheckOk = false;
      refreshVersionUI();
      return;
    }
    const data = await response.json();
    apkVersionInfo.serverVersionCode = Number(data.versionCode) || 0;
    apkVersionInfo.serverVersionName =
      typeof data.versionName === "string" ? data.versionName : "unknown";
    apkVersionInfo.serverAvailable = !!data.available;
    apkVersionInfo.serverBuiltAt =
      typeof data.builtAt === "string" ? data.builtAt : "";
    apkVersionInfo.minVersionCode = Number(data.minVersionCode) || 0;
    apkVersionInfo.hasUpdate =
      apkVersionInfo.serverAvailable &&
      apkVersionInfo.localVersionCode > 0 &&
      apkVersionInfo.serverVersionCode > apkVersionInfo.localVersionCode;
    // Hard-block when the running APK is below the minimum required.
    // Fail-open: only force when we actually have a positive local code
    // (browser builds = 0) AND a positive min (relay env disabled = 0).
    apkVersionInfo.forceUpgrade = computeForceUpgrade();
    apkVersionInfo.lastCheckedAt = Date.now();
    apkVersionInfo.lastCheckOk = true;
    refreshVersionUI();
  } catch (err) {
    logEvt(`apk version check error ${err?.message || err}`);
    apkVersionInfo.lastCheckedAt = Date.now();
    apkVersionInfo.lastCheckOk = false;
    refreshVersionUI();
  }
}

// Effective minimum APK versionCode below which forceUpgrade fires.
// Two independent floors are folded together with max():
//   - apkVersionInfo.minVersionCode   relay env var (operator-set)
//   - webVersionInfo.requiredApkVersionCode  repo-pinned (commit-set)
// The repo-pinned floor lets a deploy that requires a newer APK
// enforce the bump without needing an SSH/env-var change. The
// operator floor stays useful for emergency lockouts that don't go
// through web deploy (e.g. urgent security recall of a bad APK).
function effectiveMinApkVersionCode() {
  const env = apkVersionInfo.minVersionCode || 0;
  const repo = webVersionInfo.requiredApkVersionCode || 0;
  return Math.max(env, repo);
}

function computeForceUpgrade() {
  const min = effectiveMinApkVersionCode();
  return (
    apkVersionInfo.localVersionCode > 0 &&
    min > 0 &&
    apkVersionInfo.localVersionCode < min
  );
}

function refreshVersionUI() {
  // forceUpgrade depends on BOTH the APK check (env-var min) and the
  // web manifest check (repo-pinned required). Re-evaluate every
  // refresh so whichever check completed most recently can flip the
  // gate without waiting for the other.
  apkVersionInfo.forceUpgrade = computeForceUpgrade();
  if (apkLocalVersionEl) {
    if (apkVersionInfo.localVersionCode > 0) {
      apkLocalVersionEl.textContent = `${apkVersionInfo.localVersionName} (build ${apkVersionInfo.localVersionCode})`;
    } else {
      apkLocalVersionEl.textContent = apkVersionInfo.localVersionName;
    }
  }
  if (apkServerVersionEl) {
    if (!apkVersionInfo.lastCheckedAt) {
      apkServerVersionEl.textContent = "检查中…";
    } else if (!apkVersionInfo.lastCheckOk) {
      apkServerVersionEl.textContent = "(无法连接到服务器)";
    } else if (!apkVersionInfo.serverAvailable) {
      apkServerVersionEl.textContent = "(服务器未发布)";
    } else {
      apkServerVersionEl.textContent = `${apkVersionInfo.serverVersionName} (build ${apkVersionInfo.serverVersionCode})`;
    }
    // Highlight the row when an upgrade is available.
    const line = apkServerVersionEl.closest(".apk-version-line");
    if (line) line.classList.toggle("upgrade", apkVersionInfo.hasUpdate);
  }
  if (apkUpgradeBanner) {
    // Force-modal supersedes the soft banner — no point showing both.
    const showBanner = apkVersionInfo.hasUpdate && !apkVersionInfo.forceUpgrade;
    apkUpgradeBanner.classList.toggle("hidden", !showBanner);
    if (apkUpgradeBannerText && showBanner) {
      apkUpgradeBannerText.textContent = `有新版本 APP 可用：${apkVersionInfo.serverVersionName} (build ${apkVersionInfo.serverVersionCode})`;
    }
  }
  if (apkForceModal) {
    apkForceModal.classList.toggle("hidden", !apkVersionInfo.forceUpgrade);
    if (apkVersionInfo.forceUpgrade) {
      if (apkForceModalLocal) {
        apkForceModalLocal.textContent = String(
          apkVersionInfo.localVersionCode,
        );
      }
      if (apkForceModalMin) {
        // Show the effective floor (max of env-var + repo-pinned) so
        // the user sees the real number they need to hit, not whichever
        // single source happened to set it.
        apkForceModalMin.textContent = String(effectiveMinApkVersionCode());
      }
    }
  }
}

if (checkApkVersionBtn) {
  checkApkVersionBtn.addEventListener("click", async () => {
    checkApkVersionBtn.disabled = true;
    const originalText = checkApkVersionBtn.textContent;
    checkApkVersionBtn.textContent = "检查中…";
    try {
      await Promise.all([
        loadLocalApkVersion(),
        checkApkVersion(),
        loadLocalWebVersion(),
        checkWebManifest(),
      ]);
    } finally {
      checkApkVersionBtn.disabled = false;
      checkApkVersionBtn.textContent = originalText;
    }
  });
}

if (apkUpgradeBannerBtn) {
  // Banner shortcut reuses the same grant-flow downloadApk path the
  // settings button uses. Keeps a single auth + Content-Disposition
  // flow regardless of how the user triggered it.
  apkUpgradeBannerBtn.addEventListener("click", () => downloadApk());
}

if (apkForceModalBtn) {
  // Force-modal upgrade button: same grant-flow download path. The
  // modal stays up after click — user must restart APP with the new
  // APK before forceUpgrade clears (the new version check on next boot
  // will close the modal automatically).
  apkForceModalBtn.addEventListener("click", () => downloadApk());
}

// Kick off both checks in parallel — local read is sync-ish, server
// fetch is async. UI re-paints after each completes.
loadLocalApkVersion().then(refreshVersionUI);
checkApkVersion();

// --- Web OTA --------------------------------------------------------
//
// Mirrors the APK version flow but uses /api/web/manifest.json +
// /api/web/bundle. Install path is the GhosttyWebUpdate plugin →
// Capacitor's built-in WebView.setServerBasePath → reload. Browser
// builds stay no-op since setServerBasePath only applies inside the
// APK WebView.

async function loadLocalWebVersion() {
  if (!isWebUpdateSupported()) {
    webVersionInfo.localVersion = "";
    webVersionInfo.localSha = "";
    webVersionInfo.localPath = "";
    return;
  }
  try {
    const info = await getLocalWebVersion();
    webVersionInfo.localVersion = info?.version ?? "";
    webVersionInfo.localSha = info?.sha256 ?? "";
    webVersionInfo.localPath = info?.path ?? "";
  } catch (err) {
    logEvt(`getLocalWebVersion failed ${err?.message || err}`);
  }
}

async function checkWebManifest() {
  let url;
  try {
    url = apiURL("/api/web/manifest.json");
  } catch (err) {
    logEvt(`web manifest url invalid ${err?.message || err}`);
    return;
  }
  try {
    const response = await fetch(url.toString(), {
      method: "GET",
      credentials: "omit",
    });
    if (!response.ok) {
      logEvt(`web manifest check failed status=${response.status}`);
      webVersionInfo.lastCheckedAt = Date.now();
      webVersionInfo.lastCheckOk = false;
      refreshWebVersionUI();
      return;
    }
    const data = await response.json();
    webVersionInfo.serverVersion =
      typeof data.webVersion === "string" ? data.webVersion : "";
    webVersionInfo.serverSha =
      typeof data.sha256 === "string" ? data.sha256 : "";
    webVersionInfo.serverBundleUrl =
      typeof data.bundleUrl === "string" ? data.bundleUrl : "";
    webVersionInfo.serverBuiltAt =
      typeof data.builtAt === "string" ? data.builtAt : "";
    webVersionInfo.serverAvailable = !!data.available;
    webVersionInfo.requiredApkVersionCode =
      Number(data.requiredApkVersionCode) || 0;
    // sha256 is the source of truth — a dirty rebuild keeps the same
    // version label ("...-dirty") but ships different bytes, and we
    // want the user to be able to re-install. Version label is just
    // informational. Local sha "" means we're on bundled APK assets
    // (no .version marker), which also counts as "outdated" so the
    // first install button is enabled.
    webVersionInfo.hasUpdate =
      webVersionInfo.serverAvailable &&
      webVersionInfo.serverSha !== "" &&
      webVersionInfo.serverBundleUrl !== "" &&
      webVersionInfo.serverSha !== webVersionInfo.localSha;
    webVersionInfo.lastCheckedAt = Date.now();
    webVersionInfo.lastCheckOk = true;
    refreshWebVersionUI();
  } catch (err) {
    logEvt(`web manifest check error ${err?.message || err}`);
    webVersionInfo.lastCheckedAt = Date.now();
    webVersionInfo.lastCheckOk = false;
    refreshWebVersionUI();
  }
}

function refreshWebVersionUI() {
  // Also re-evaluate force-upgrade — webVersionInfo.requiredApkVersionCode
  // is one of the two inputs to computeForceUpgrade, so a fresh manifest
  // fetch needs to refresh the modal even when no APK-side check ran.
  refreshVersionUI();
  if (webLocalVersionEl) {
    if (!isWebUpdateSupported()) {
      webLocalVersionEl.textContent = "(浏览器)";
    } else if (webVersionInfo.localVersion) {
      webLocalVersionEl.textContent = webVersionInfo.localVersion;
    } else {
      webLocalVersionEl.textContent = "(内置)";
    }
  }
  if (webServerVersionEl) {
    if (!webVersionInfo.lastCheckedAt) {
      webServerVersionEl.textContent = "检查中…";
    } else if (!webVersionInfo.lastCheckOk) {
      webServerVersionEl.textContent = "(无法连接到服务器)";
    } else if (!webVersionInfo.serverAvailable) {
      webServerVersionEl.textContent = "(服务器未发布)";
    } else {
      webServerVersionEl.textContent =
        webVersionInfo.serverVersion || "(unknown)";
    }
    const line = webServerVersionEl.closest(".apk-version-line");
    if (line) line.classList.toggle("upgrade", webVersionInfo.hasUpdate);
  }
  const native = isWebUpdateSupported();
  if (installWebUpdateBtn) {
    installWebUpdateBtn.disabled =
      !native || webVersionInfo.busy || !webVersionInfo.hasUpdate;
  }
  if (resetWebBundleBtn) {
    // Reset only makes sense when the WebView is currently running off
    // an OTA bundle — disable when already on bundled assets.
    resetWebBundleBtn.disabled =
      !native || webVersionInfo.busy || webVersionInfo.localVersion === "";
  }
  if (webUpdateHintEl) {
    if (!native) {
      webUpdateHintEl.textContent = "仅 APP 端可用。";
    } else if (webVersionInfo.busy) {
      webUpdateHintEl.textContent = "处理中，请勿离开页面…";
    } else if (webVersionInfo.hasUpdate) {
      webUpdateHintEl.textContent = "下载并安装后 APP 会自动重新加载新版本。";
    } else if (webVersionInfo.localVersion) {
      webUpdateHintEl.textContent = "正在运行下载安装的 Web 资源。";
    } else {
      webUpdateHintEl.textContent = "正在运行 APK 内置的 Web 资源。";
    }
  }
}

async function installWebUpdate() {
  logEvt(
    `installWebUpdate enter native=${isWebUpdateSupported()} busy=${webVersionInfo.busy} hasUpdate=${webVersionInfo.hasUpdate} localSha=${webVersionInfo.localSha.slice(0, 8)} serverSha=${webVersionInfo.serverSha.slice(0, 8)}`,
  );
  if (!isWebUpdateSupported()) {
    logEvt("installWebUpdate skip: not native");
    return;
  }
  if (webVersionInfo.busy) {
    logEvt("installWebUpdate skip: busy");
    return;
  }
  if (!webVersionInfo.hasUpdate) {
    logEvt("installWebUpdate skip: no update available");
    return;
  }
  const token = tokenInput.value.trim();
  if (!token) {
    logEvt("installWebUpdate skip: no token");
    if (webUpdateHintEl) {
      webUpdateHintEl.textContent = "请先填写 User Token。";
    }
    return;
  }
  webVersionInfo.busy = true;
  refreshWebVersionUI();
  if (webUpdateHintEl) webUpdateHintEl.textContent = "下载中…";
  let bundleURL;
  try {
    bundleURL = apiURL(webVersionInfo.serverBundleUrl);
  } catch (err) {
    webVersionInfo.busy = false;
    refreshWebVersionUI();
    if (webUpdateHintEl) {
      webUpdateHintEl.textContent = `下载地址无效：${err?.message || err}`;
    }
    return;
  }
  try {
    const result = await downloadWebBundle({
      url: bundleURL.toString(),
      sha256: webVersionInfo.serverSha,
      version: webVersionInfo.serverVersion,
      token,
      onProgress: (info) => {
        // Log every phase including install chunks — without these we
        // can't tell hung-chunk vs hung-finalize vs hung-reload on the
        // device. Volume is ~7 chunks per install, manageable.
        logEvt(
          `web update progress phase=${info.phase}${info.total ? ` ${info.received ?? info.sent ?? 0}/${info.total}` : ""}`,
        );
        if (!webUpdateHintEl) return;
        if (info.phase === "download") {
          if (info.total > 0 && info.received >= info.total) {
            webUpdateHintEl.textContent = `下载完成 (${(info.received / 1024).toFixed(1)} KB)，校验中…`;
          } else {
            webUpdateHintEl.textContent = "下载中…";
          }
        } else if (info.phase === "verify") {
          webUpdateHintEl.textContent = "校验中…";
        } else if (info.phase === "install") {
          const pct =
            info.total > 0 ? Math.floor((info.sent / info.total) * 100) : 0;
          webUpdateHintEl.textContent = `安装中… ${pct}%`;
        }
      },
    });
    if (webUpdateHintEl)
      webUpdateHintEl.textContent = "安装中，APP 将自动刷新…";
    logEvt(`web update install done path=${result.path}`);
    // Drop older bundles BEFORE activate — activate triggers a reload
    // and this JS instance dies, taking any pending cleanup with it.
    try {
      await clearOldBundles(webVersionInfo.serverVersion);
      logEvt("web update clearOldBundles done");
    } catch (cleanupErr) {
      logEvt(`clearOldBundles failed ${cleanupErr?.message || cleanupErr}`);
    }
    logEvt("web update activate start");
    await activateWebBundle(result.path);
    logEvt("web update activate returned (reload pending)");
    // The plugin's activate() resolves immediately then schedules the
    // reload on the UI thread. Give it ~500ms to fire. If for some
    // reason the WebView still hasn't navigated, fall back to a JS
    // reload — at this point JS state (busy, hint) is stale anyway.
    setTimeout(() => {
      try {
        window.location.replace("https://localhost/?ota=" + Date.now());
      } catch {
        try {
          window.location.reload();
        } catch {
          /* give up */
        }
      }
    }, 500);
    // activateWebBundle posts a reload — execution past here is best-
    // effort; the new JS bundle takes over momentarily.
  } catch (err) {
    webVersionInfo.busy = false;
    refreshWebVersionUI();
    if (webUpdateHintEl) {
      webUpdateHintEl.textContent = `安装失败：${err?.message || err}`;
    }
    logEvt(`web update install failed ${err?.message || err}`);
  }
}

async function resetWebToBundled() {
  if (!isWebUpdateSupported() || webVersionInfo.busy) return;
  if (webVersionInfo.localVersion === "") return;
  webVersionInfo.busy = true;
  refreshWebVersionUI();
  if (webUpdateHintEl) webUpdateHintEl.textContent = "正在恢复内置版本…";
  try {
    await resetToBundled();
    // Same reload caveat as installWebUpdate — APP reloads, JS dies.
  } catch (err) {
    webVersionInfo.busy = false;
    refreshWebVersionUI();
    if (webUpdateHintEl) {
      webUpdateHintEl.textContent = `恢复失败：${err?.message || err}`;
    }
    logEvt(`web reset failed ${err?.message || err}`);
  }
}

if (installWebUpdateBtn) {
  installWebUpdateBtn.addEventListener("click", () => installWebUpdate());
}
if (resetWebBundleBtn) {
  resetWebBundleBtn.addEventListener("click", () => resetWebToBundled());
}

loadLocalWebVersion().then(refreshWebVersionUI);
checkWebManifest();

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
// Upgradeable force flag: any schedulePaint(true) before the frame
// fires pulls it up to forceAll, even if a previous schedulePaint(false)
// already booked the rAF. Cleared on cancel and at the start of the
// rAF callback so the next schedule starts at default.
let scheduledPaintForce = false;

// Sliding window: while Date.now() < forcePaintUntil every schedulePaint
// is treated as forceAll, even ones called with the default `false`.
// Used to blanket-cover the brief window after socket reconnect /
// foreground-resume, where dist's dirty-row tracking may underflag
// rows that the new byte stream affects — leaving GPU pixels from the
// pre-suspend frame visible underneath the new content (user-reported
// "文字重叠"). 2.5 s comfortably covers a hello → backlog (~256 frames)
// → snapshot sequence on a typical phone link without spending CPU on
// forced paints during steady-state usage.
let forcePaintUntil = 0;
const FORCE_PAINT_WINDOW_MS = 2500;

function startForcePaintWindow(reason) {
  forcePaintUntil = Date.now() + FORCE_PAINT_WINDOW_MS;
  logEvt(`force-paint window ${reason} ${FORCE_PAINT_WINDOW_MS}ms`);
}

// force=false: dist's dirty-row optimisation — only repaint rows that
// changed in wasmTerm since last render. The default for normal writes.
//
// force=true: pass forceAll through to renderer.render so every visible
// row is redrawn regardless of dist's dirty tracking. Use whenever the
// canvas backing might be stale relative to wasmTerm — these are the
// paths where dirty-only is wrong:
//   - first paint after `terminal.open()` / dispose+recreate: dist's
//     open() does paint with forceAll=true, but applyRendererDpr's
//     renderer.resize then resets ctx + fillRect background and wipes
//     it. The first schedulePaint AFTER install must redo forceAll.
//   - visibility resumed: Android WebView may have lost GPU texture
//     while backgrounded (OS evicts on memory pressure). dimensions
//     match so dist's self-heal doesn't trigger; only forceAll can
//     overwrite the garbage page contents.
//   - applyScreenSnapshot: the snapshot is a re-anchor checkpoint;
//     even if part of the new content equals wasmTerm's pre-snapshot
//     state (snapshot includes static frame chrome), we want every
//     visible row redrawn so we don't leave stale GPU pages visible.
function schedulePaint(force = false) {
  if (!terminal || terminal.isDisposed || !terminal.isOpen) return;
  if (force || Date.now() < forcePaintUntil) scheduledPaintForce = true;
  if (scheduledPaintFrame != null) return;
  scheduledPaintFrame = window.requestAnimationFrame(() => {
    scheduledPaintFrame = null;
    const forceAll = scheduledPaintForce;
    scheduledPaintForce = false;
    if (!terminal || terminal.isDisposed || !terminal.isOpen) return;
    const renderer = terminal.renderer;
    const wasm = terminal.wasmTerm;
    if (!renderer || !wasm) return;
    try {
      if (forceAll) {
        // Belt over dist's per-row fillRect clearing inside renderLine.
        // HarmonyOS / ICL-AL20 WebView GPU compositors have been
        // observed to keep showing pre-eviction pixels under areas
        // that dist's renderLine just fillRected — the rect lands in
        // the 2D context's backing buffer but doesn't propagate to
        // the compositor's cached layer texture, producing the
        // "two terminals overlapping" symptom after APP foreground
        // resume. A single full-canvas fillRect at the start of a
        // forceAll paint forces the entire layer to invalidate
        // before the per-row writes land, which the compositor
        // honours where the per-row writes alone do not.
        //
        // ~1-2 ms extra per forceAll paint at DPR 1.5; only fires in
        // the forcePaintUntil window or on explicit scheduleFullPaint
        // (snapshot / install / appearance / resize / hello), not in
        // steady-state writes. Daily on-demand paints stay cheap.
        // Reanchor viewportY to bottom on the same tick so a stale
        // smooth-scroll target can't leave the renderer drawing
        // scrollback + active mixed (dist render line 1431 splits
        // the visible rows between buffers when viewportY > 0).
        // Followers only: when the user scrolled into history,
        // viewportY > 0 is intentional and the mixed render IS the
        // correct scrolled-up view — reanchoring here would yank
        // them on every forceAll (snapshot / hello / appearance).
        if (userFollowBottom && terminal.viewportY !== 0) {
          terminal.scrollToBottom?.();
        }
        renderer.clear();
      }
      renderer.render(
        wasm,
        forceAll,
        terminal.viewportY,
        terminal,
        terminal.scrollbarOpacity,
      );
    } catch (_) {}
  });
}

function scheduleFullPaint() {
  schedulePaint(true);
}

function cancelScheduledPaint() {
  if (scheduledPaintFrame != null) {
    window.cancelAnimationFrame(scheduledPaintFrame);
    scheduledPaintFrame = null;
  }
  scheduledPaintForce = false;
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
    // dist Terminal.write (ghostty-web v0.4.0, line 2390) has an
    // unconditional `this.viewportY !== 0 && this.scrollToBottom()`
    // inside — every write yanks the user back to the live area, even
    // if they're actively reading scrollback. Compensate when the
    // user has opted into history (userFollowBottom === false):
    //   1. snapshot viewportY (rows above bottom) + scrollback length
    //   2. let dist write; it will reset viewportY to 0
    //   3. the write pushed N rows off the live screen into history
    //      (scrollback grew by N), so the lines the user was reading
    //      sit N rows further from the bottom; restore viewportY to
    //      oldViewportY+N to keep the visible window anchored.
    // buffer.active.baseY is NOT usable for the delta — it's a stub
    // hardcoded to 0 in ghostty-web v0.4.0 (same trap as isAtBottom),
    // which made delta always 0 and the view drift up one row per new
    // host line. A saturated scrollback ring under-reports the delta
    // (oldest rows fall off as new ones enter), drifting the anchor at
    // worst — the Math.min cap below bounds it the same way the old
    // baseY math intended.
    // userFollowBottom = true → original behaviour (dist's scroll
    // wins, snapshot of new content visible immediately).
    if (!userFollowBottom) {
      const oldViewportY = t.viewportY ?? 0;
      const oldScrollback = t.getScrollbackLength?.() ?? 0;
      const ret = origWrite(data, callback);
      const newScrollback = t.getScrollbackLength?.() ?? 0;
      const delta = newScrollback - oldScrollback;
      const desired = oldViewportY + Math.max(0, delta);
      const restored = Math.min(desired, newScrollback);
      if (restored !== t.viewportY) {
        t.viewportY = restored;
      }
      schedulePaint();
      return ret;
    }
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
  t.onScroll(() => {
    schedulePaint();
    // Keep the mobile selection handles glued to the live highlight when
    // terminal output scrolls the buffer under an active selection. No-op
    // (early return) unless a selection is active, so the hot scroll path
    // stays cheap.
    repositionActiveSelection();
  });
  t.onSelectionChange(() => schedulePaint());
  t.onResize(() => {
    schedulePaint();
    repositionActiveSelection();
  });

  // (5) Apply the low-res DPR cap immediately so the very first
  // post-open paint already runs at the chosen resolution. Without
  // this the canvas would briefly allocate at native DPR before the
  // cap kicks in (one frame of wasted backing buffer + an avoidable
  // re-resize).
  applyRendererDpr(true);

  // (6) dist's open() already painted once before startRenderLoop with
  // forceAll=true, but applyRendererDpr's renderer.resize then wiped
  // the canvas (canvas.width assignment resets ctx + fillRect background).
  // Schedule a full paint so the first visible frame is a complete
  // render, not a forceAll-only-then-overwritten-by-dirty-only frame.
  // This also recovers from the Android driver "new canvas reuses a GPU
  // page that wasn't zeroed" case — on a clean canvas the forceAll
  // overhead is negligible.
  scheduleFullPaint();
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
  // renderer.resize internally fills the canvas with theme.background.
  // A dirty-only schedulePaint here would leave most of the visible
  // area as bare background until the next mutation. Force full paint
  // so the existing wasmTerm content is restored immediately.
  scheduleFullPaint();
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
  // Wipes the layer-promoted `.terminal-canvas-host` wrapper along
  // with the canvas + textarea it holds. Wrapper destruction is what
  // releases the GPU compositor layer; without it the next canvas
  // would inherit stale layer pixels on HarmonyOS WebView.
  // See ensureTerminal's canvasHost block for the why.
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
  // Compositor-layer isolation wrapper. dist's `terminal.open(host)`
  // appends `<canvas>` + helper `<textarea>` into `host`. If `host` is
  // terminalMount directly, the canvas pixels paint into the same
  // GPU compositor layer that terminalMount owns (terminalMount gets
  // its own layer because we put `transform: translate3d(...)` on it
  // for desktop-width pan). On HarmonyOS / ICL-AL20 WebView that
  // layer texture is **persistent across canvas replacements** — when
  // disposeTerminal removes the old canvas and ensureTerminal builds
  // a new one, the new canvas's fillRects land in the 2D context's
  // backing buffer but the compositor keeps showing the previous
  // canvas's pixels for a while (observed: 2 "terminals" overlapping
  // after APP foreground resume; only a full `location.reload()` —
  // which rebuilds the whole DOM tree and releases all layers —
  // clears it).
  //
  // Workaround without a reload: insert a child wrapper into
  // terminalMount and promote *that* to its own layer (will-change +
  // translateZ(0)). Now the canvas is part of the wrapper's layer,
  // not terminalMount's. When disposeTerminal wipes
  // `terminalMount.innerHTML`, the wrapper is destroyed → its layer
  // is released → the next wrapper from this function gets a fresh
  // layer texture, just like reload would.
  //
  // Layout invariants: wrapper inherits terminalMount's width/height
  // (100%), so desktop-width sizing and mobile viewport fit are
  // unaffected. Pan transform stays on terminalMount and moves the
  // wrapper's layer as a child (compositor applies parent transform
  // to promoted children).
  const canvasHost = document.createElement("div");
  canvasHost.className = "terminal-canvas-host";
  canvasHost.style.width = "100%";
  canvasHost.style.height = "100%";
  canvasHost.style.willChange = "transform";
  canvasHost.style.transform = "translateZ(0)";
  terminalMount.appendChild(canvasHost);
  terminal.open(canvasHost);
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
        const isField =
          target instanceof HTMLTextAreaElement ||
          target instanceof HTMLInputElement;
        // During a long-press selection (timer pending OR active) freeze the
        // keyboard at the state it had when the gesture started. dist's
        // terminal.focus() focuses the .terminal-canvas-host DIV
        // (canvas.parentElement) on touch, which on HarmonyOS flips the soft
        // keyboard ~190ms later. So:
        //   - started HIDDEN  → blur the intruder so the keyboard stays down
        //   - started VISIBLE → re-assert mobileInput focus so it stays up
        const duringSelect = termSelLongPressTimer !== null || termSelActive;
        if (duringSelect) {
          if (kbVisibleOnSelect) {
            if (document.activeElement !== mobileInput) {
              mobileInput.focus({ preventScroll: true });
            }
          } else if (typeof target.blur === "function") {
            target.blur();
          }
          return;
        }
        // Outside a selection: dist's hidden helper textarea must never hold
        // focus on mobile (it re-raises the keyboard after a swipe).
        if (isField && typeof target.blur === "function") {
          target.blur();
          logEvt(`blur stolen ${target.tagName.toLowerCase()}`);
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
      // Force-all so that an Android WebView whose GPU texture was
      // evicted while backgrounded gets a clean repaint of the entire
      // visible area, not just dist's dirty rows. Without force the
      // non-dirty rows show GPU garbage from the evicted page.
      if (!document.hidden) scheduleFullPaint();
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
    item.addEventListener("click", () => {
      // A long-press that opened the actions sheet can also synthesize
      // a trailing click on release — swallow it so we don't ALSO enter
      // the session underneath the sheet.
      if (sessionLongPressJustFired()) return;
      switchToSession(session);
    });
    attachSessionLongPress(item, session);
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
  if (name) return name;
  // Fallback when the macOS agent hasn't published a PTY title yet
  // (bash / zsh defaults don't emit ESC]2;TITLE). Showing the same
  // "未命名会话" string for every nameless session made it impossible
  // to tell them apart — including the session id's leading 8 chars
  // makes each fallback row unique and recognisable in the list /
  // tooltip / quick switcher.
  const shortId = typeof session.id === "string" ? session.id.slice(0, 8) : "";
  return shortId ? `会话 ${shortId}` : "未命名会话";
}

function timestampForSort(value) {
  if (!value) return 0;
  const time = new Date(value).getTime();
  return Number.isNaN(time) ? 0 : time;
}

// APP-mode wrapper for user-initiated session selection. HarmonyOS /
// ICL-AL20 WebView keeps the GPU compositor layer texture across
// disposeTerminal + ensureTerminal rebuilds, so any in-place session
// switch leaks pixels from the prior session (same root cause as the
// visibility=visible reload). location.replace + ?session=<id> does a
// full document navigation that tears down the layer tree; the new
// SPA boot routes back into the picked session via routeFromLocation.
//
// Browser builds keep the cheap in-place path — they don't exhibit
// the layer-stacking bug and a full reload here would be a visible
// regression (launcher flashes, vite chunks re-evaluate).
//
// Only user-driven `<button class="session">` clicks go through this
// wrapper; the auto-recover paths (popstate routing, scheduleReconnect
// retry, deep-link boot) keep calling connectToSession directly with
// updateHistory:false because they're already running in the right
// document and a reload would be wasteful.
function switchToSession(session) {
  if (window.Capacitor?.isNativePlatform?.()) {
    const url = new URL(window.location.href);
    url.searchParams.set(SESSION_QUERY_KEY, session.id);
    persistDebugLogsForReload();
    // assign (NOT replace) — replace overwrites the current history
    // entry, leaving only one entry total; the Android backButton
    // handler then sees `canGoBack=false` and exits the APP instead of
    // taking the user back to the launcher. assign pushes a new entry
    // so back → popstate → routeFromLocation → leaveTerminalView
    // returns the user to the session list as expected.
    window.location.assign(url.toString());
    return;
  }
  connectToSession(session);
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
    // Switching to a different session invalidates any queued uploads
    // that were waiting for the previous session's WS to recover —
    // they were scoped to the old session_id. A same-session reconnect
    // (auto-reconnect path) keeps the queue intact so flush-on-open
    // can pick them up.
    if (activeSession && activeSession.id !== session.id) {
      cancelPendingUploads("已切换会话，上传取消");
    }

    shouldReconnect = true;
    activeSession = session;
    activeSessionId = session.id;
    helloReceived = false;
    activeMirrorMode = isLiveMirrorEnabled();
    // Fresh session view starts at the bottom; any previous user pan
    // intent belonged to the prior session.
    userFollowBottom = true;
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
      // Open the force-paint window before any frames land. hello →
      // backlog (~256 binary frames) → screen snapshot land in rapid
      // sequence and each terminal.write through our wrap schedules a
      // dirty-only paint; without the window the dirty-row optimisation
      // leaves rows from the pre-suspend frame visible underneath the
      // new content. See FORCE_PAINT_WINDOW_MS for the rationale.
      startForcePaintWindow("socket_open");
      // Only fit-to-viewport when we're allowed to push the host
      // around. With the lock engaged we wait for the agent's hello
      // / screen frame to tell us what dimensions to render at.
      if (fitAddon && !isHostSizeLocked()) fitAddon.fit();
      focusTerminal();
      updateDocumentTitle();
      setTerminalStatus("已连接", "connected");
      refreshUploadLauncherVisibility();
      // Drain any uploads that arrived while the WS was down (typically
      // dropped/pasted right after foreground-resume, or queued by the
      // 401 auto-retry path). They share the existing toastId so the
      // pending toast morphs into "上传中" instead of stacking.
      flushPendingUploads();
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
        const cols = frame.cols;
        const rows = frame.rows;
        // Skip the resize + paint storm when the grid hasn't actually
        // changed. The relay should dedup essential metadata in the
        // backlog, but defend in case an older relay (or replay race)
        // floods us with identical hello frames — every needless
        // terminal.resize() triggers dist's "set canvas.width → paint
        // self-heal" cycle, which on HarmonyOS WebView appears to feed
        // the compositor extra stale frames. helloReceived gates the
        // very first hello through unconditionally (terminal was just
        // created with default cols/rows, we still need the resize).
        const helloChanged =
          !helloReceived || cols !== hostCols || rows !== hostRows;
        hostRows = rows;
        hostCols = cols;
        helloReceived = true;
        if (helloChanged) {
          // Mirror the host's grid verbatim. We previously trimmed rows
          // on mobile to avoid the canvas-overflow clip at the bottom,
          // but that made absolute cursor positioning escapes from live
          // frames (host computed them against its 46-row grid) land at
          // the wrong visual row in our shorter grid — TUI status bars
          // ended up stacked on top of unrelated content. With rows
          // preserved, applyDesktopWidthSize sizes #terminal to the
          // natural canvas height and we expose the off-screen rows via
          // vertical transform pan.
          terminal.resize(cols, rows);
          applyDesktopWidthSize();
          // hello often lands just before the backlog/snapshot pair on
          // reconnect. Force the next paint so the resize-triggered
          // self-heal doesn't leave us with a half-rendered viewport.
          scheduleFullPaint();
        }
      }
      return;
    case "resize":
      if (
        Number.isInteger(frame.cols) &&
        Number.isInteger(frame.rows) &&
        terminal
      ) {
        terminal.resize(frame.cols, frame.rows);
        scheduleFullPaint();
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
    case "session_created":
      // Consumed by the launcher's ephemeral create flow. On the main
      // socket it's either a backlog replay or another client's create —
      // never auto-switch this viewer, just keep the JSON out of the
      // terminal.
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
  const progressBar = node.querySelector(".upload-toast-progress > span");
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
    setTimeout(
      () => {
        if (uploadToastNodes.get(id) === node) {
          node.remove();
          uploadToastNodes.delete(id);
        }
      },
      payload.kind === "success" ? 6000 : 9000,
    );
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
  // 清行 pill shares the same pill row + gating as the upload launcher.
  if (mobileKillLine) {
    mobileKillLine.classList.toggle("hidden", !visible);
    mobileKillLine.disabled = !visible;
  }
}

// File-picker grace window for the APP-mode visibilitychange handler.
// The native file chooser hides our WebView (visibility=hidden); when
// the user dismisses the chooser the WebView returns to visibility=
// visible and the handler would normally `location.reload()` — which
// throws away the <input> element + change callback before the
// selected file event can land, so the upload silently does nothing.
//
// Setting this timestamp on every uploadFileInput.click() lets the
// handler short-circuit the reload while the chooser is plausibly
// still open. Clearing it on `change` covers the select-success path
// immediately; the WINDOW_MS fallback covers the cancel path (no
// change event fires on cancel).
//
// Window length: chooser sessions can run minutes (browsing albums,
// granting permissions, scrolling), but we'd rather over-stay the
// grace than miss a reload. 60s is enough for the common "tap upload
// → scroll album → confirm" flow on slower devices while keeping
// the reload responsive when the APP actually backgrounds.
//
// Safety wrt the layer-stacking bug: while the chooser is on top the
// WebView is not rendering, so the compositor isn't accumulating any
// new stale frames during this window. Skipping the reload here is
// safe even though we'd normally treat any hidden→visible as a fresh
// stack event.
let filePickerOpenAt = 0;
const FILE_PICKER_VISIBLE_GRACE_MS = 60_000;

function openUploadFilePicker() {
  filePickerOpenAt = Date.now();
  logEvt(`openUploadFilePicker filePickerOpenAt=${filePickerOpenAt}`);
  uploadFileInput.value = "";
  uploadFileInput.click();
}

mobileUploadLauncher.addEventListener("click", () => {
  openUploadFilePicker();
});

// ---- Session actions (create / close host surface) ---------------------
// Entry point: long-press (touch) or right-click (contextmenu) an ONLINE
// session in the launcher list. The frames ride a short-lived ephemeral
// client WS to the TARGET session — the launcher holds no persistent
// connection, and create_session anchors to the long-pressed session's
// surface on the mac (tab joins its window, splits divide it) while
// close_session closes that surface outright. The relay forwards client
// text frames verbatim — only the agent parses them, so agents must be
// upgraded before this UI ships (old agents leak unknown JSON into the
// PTY).

// Dedupe set for session_created frames. The agent's reply can sit in
// the relay backlog until the next screen checkpoint prunes it, so a
// reconnecting client may replay it — without the seen-set we'd
// auto-switch again on every reconnect.
const SESSION_CREATED_SEEN_KEY = "ghostty-sharing-created-seen";
const SESSION_CREATED_SEEN_MAX = 50;

function seenCreatedSessions() {
  try {
    const raw = localStorage.getItem(SESSION_CREATED_SEEN_KEY);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function markCreatedSessionSeen(id) {
  const list = seenCreatedSessions();
  list.push(id);
  localStorage.setItem(
    SESSION_CREATED_SEEN_KEY,
    JSON.stringify(list.slice(-SESSION_CREATED_SEEN_MAX)),
  );
}

// Simple transient toast, same look as the exit-confirm one. The upload
// toast stack is upload-specific (progress morphing, manager-owned ids),
// reusing it here would tangle the two lifecycles.
function showSessionActionToast(text, { durationMs = 4000 } = {}) {
  const existing = document.querySelector("#session-action-toast");
  if (existing) existing.remove();
  const toast = document.createElement("div");
  toast.id = "session-action-toast";
  toast.textContent = text;
  Object.assign(toast.style, {
    position: "fixed",
    bottom: "calc(env(safe-area-inset-bottom, 0px) + 64px)",
    left: "50%",
    transform: "translateX(-50%)",
    background: "rgba(0, 0, 0, 0.78)",
    color: "#fff",
    padding: "10px 18px",
    borderRadius: "20px",
    fontSize: "14px",
    lineHeight: "1.4",
    zIndex: "9999",
    maxWidth: "85vw",
    pointerEvents: "none",
    boxShadow: "0 2px 10px rgba(0,0,0,0.3)",
  });
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), durationMs);
}

// Two-step in-sheet confirm for the destructive close. First tap arms,
// second tap within the same sheet sends; closing the sheet disarms.
let sessionCloseArmed = false;
// The session the open sheet operates on (set by long-press /右键).
let sessionActionsTargetSession = null;

function openSessionActionsModal(session) {
  sessionActionsTargetSession = session;
  sessionCloseArmed = false;
  sessionCloseConfirmHint?.classList.add("hidden");
  if (sessionActionsTargetEl) {
    sessionActionsTargetEl.textContent = `目标会话：${displaySessionName(session)}`;
  }
  sessionActionsModal?.classList.remove("hidden");
}

function closeSessionActionsModal() {
  sessionActionsTargetSession = null;
  sessionCloseArmed = false;
  sessionCloseConfirmHint?.classList.add("hidden");
  sessionActionsModal?.classList.add("hidden");
}

sessionActionsCancelBtn?.addEventListener("click", () => {
  closeSessionActionsModal();
});

sessionActionsModal?.addEventListener("click", (event) => {
  // Backdrop tap dismisses; taps inside the sheet bubble up with a
  // different target.
  if (event.target === sessionActionsModal) closeSessionActionsModal();
});

for (const btn of sessionActionsModal?.querySelectorAll("[data-create-mode]") ??
  []) {
  btn.addEventListener("click", () => {
    const mode = btn.dataset.createMode;
    const target = sessionActionsTargetSession;
    closeSessionActionsModal();
    if (!target) return;
    requestCreateSession(target, mode);
  });
}

sessionCloseBtn?.addEventListener("click", () => {
  if (!sessionCloseArmed) {
    sessionCloseArmed = true;
    sessionCloseConfirmHint?.classList.remove("hidden");
    return;
  }
  const target = sessionActionsTargetSession;
  closeSessionActionsModal();
  if (!target) return;
  requestCloseSession(target);
});

// ---- Long-press → actions sheet ----------------------------------------
const SESSION_LONG_PRESS_MS = 500;
const SESSION_LONG_PRESS_MOVE_TOLERANCE_PX = 12;
// Timestamp instead of a boolean: some browsers don't synthesize the
// trailing click after a long-press, and a sticky boolean would swallow
// the NEXT genuine tap on a session.
let lastSessionLongPressAt = 0;

function sessionLongPressJustFired() {
  return Date.now() - lastSessionLongPressAt < 800;
}

function attachSessionLongPress(item, session) {
  let timer = null;
  let startX = 0;
  let startY = 0;
  const cancel = () => {
    if (timer !== null) {
      window.clearTimeout(timer);
      timer = null;
    }
  };
  item.addEventListener(
    "touchstart",
    (event) => {
      cancel();
      if (event.touches.length !== 1) return;
      const touch = event.touches[0];
      startX = touch.clientX;
      startY = touch.clientY;
      timer = window.setTimeout(() => {
        timer = null;
        lastSessionLongPressAt = Date.now();
        openSessionActionsModal(session);
      }, SESSION_LONG_PRESS_MS);
    },
    { passive: true },
  );
  item.addEventListener(
    "touchmove",
    (event) => {
      const touch = event.touches[0];
      if (
        !touch ||
        Math.abs(touch.clientX - startX) >
          SESSION_LONG_PRESS_MOVE_TOLERANCE_PX ||
        Math.abs(touch.clientY - startY) > SESSION_LONG_PRESS_MOVE_TOLERANCE_PX
      ) {
        cancel();
      }
    },
    { passive: true },
  );
  item.addEventListener("touchend", cancel, { passive: true });
  item.addEventListener("touchcancel", cancel, { passive: true });
  // Desktop right-click, plus the contextmenu some Android WebViews
  // synthesize on long-press (covers devices where it races our timer;
  // preventDefault also suppresses the system text-selection menu).
  item.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    cancel();
    lastSessionLongPressAt = Date.now();
    openSessionActionsModal(session);
  });
}

// ---- Ephemeral target-session sockets -----------------------------------
// Joining a session triggers the relay backlog replay plus the agent's
// client_connected re-emit (hello/appearance/snapshot) — we ignore all
// binary frames, so the cost is one snapshot-sized burst per action.
function openEphemeralSessionSocket(session) {
  const url = wsBaseURL("/ws/client");
  url.searchParams.set("id", session.id);
  url.searchParams.set("token", session.client_token);
  const ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  return ws;
}

const CREATE_SESSION_REPLY_TIMEOUT_MS = 15_000;

function requestCreateSession(session, mode) {
  showSessionActionToast("已请求在 Mac 上新建会话…");
  const ws = openEphemeralSessionSocket(session);
  let settled = false;
  const settle = (toastText, followUp) => {
    if (settled) return;
    settled = true;
    window.clearTimeout(timer);
    try {
      ws.close();
    } catch {
      /* already closed */
    }
    if (toastText) showSessionActionToast(toastText);
    followUp?.();
  };
  const timer = window.setTimeout(
    () => settle("未收到新会话回执，请稍后刷新列表"),
    CREATE_SESSION_REPLY_TIMEOUT_MS,
  );
  ws.addEventListener("open", () => {
    ws.send(JSON.stringify({ type: "create_session", mode }));
  });
  ws.addEventListener("message", (event) => {
    if (typeof event.data !== "string") return;
    let frame;
    try {
      frame = JSON.parse(event.data);
    } catch {
      return;
    }
    if (frame.type !== "session_created") return;
    const newId = frame.new_session_id;
    if (typeof newId !== "string" || !newId) return;
    // The backlog can replay session_created frames from earlier
    // creates; the seen-set latches us onto a FRESH reply only.
    if (seenCreatedSessions().includes(newId)) return;
    markCreatedSessionSeen(newId);
    settle("新会话已创建，正在切换…", () => resolveAndSwitchToSession(newId));
  });
  ws.addEventListener("error", () => settle("连接失败，无法新建会话"));
}

function requestCloseSession(session) {
  showSessionActionToast("已请求关闭 Mac 终端…");
  const ws = openEphemeralSessionSocket(session);
  let settled = false;
  const settle = (toastText) => {
    if (settled) return;
    settled = true;
    window.clearTimeout(timer);
    try {
      ws.close();
    } catch {
      /* already closed */
    }
    if (toastText) showSessionActionToast(toastText);
    refreshSessions();
  };
  // The relay may hold the session through an agent-offline grace window
  // after the agent stops sharing, so a fast socket close is the lucky
  // path, not a guarantee — hence the soft fallback wording.
  const timer = window.setTimeout(
    () => settle("已请求关闭，列表稍后更新"),
    8000,
  );
  ws.addEventListener("open", () => {
    ws.send(JSON.stringify({ type: "close_session" }));
  });
  ws.addEventListener("close", () => settle("会话已关闭"));
  ws.addEventListener("error", () => settle("连接失败，无法关闭会话"));
}

async function resolveAndSwitchToSession(id, attempt = 0) {
  const MAX_ATTEMPTS = 10;
  const token = tokenInput.value.trim();
  if (!token) return;
  try {
    const response = await fetch(apiURL("/api/sessions"), {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (response.ok) {
      const sessions = await response.json();
      cachedSessions = sessions;
      const session = sessions.find((candidate) => candidate.id === id);
      if (session?.online) {
        switchToSession(session);
        return;
      }
    }
  } catch (error) {
    console.error(redactErrorMessage(error));
  }
  if (attempt + 1 >= MAX_ATTEMPTS) {
    showSessionActionToast("新会话尚未上线，请稍后在会话列表查看");
    return;
  }
  window.setTimeout(() => resolveAndSwitchToSession(id, attempt + 1), 1000);
}

uploadFileInput.addEventListener("change", () => {
  const files = Array.from(uploadFileInput.files ?? []);
  logEvt(`uploadFileInput change files=${files.length}`);
  // DO NOT clear filePickerOpenAt synchronously. On HarmonyOS WebView
  // the `change` event fires ~50 ms *before* visibilitychange=visible
  // (verified via debug log: `change files=1` at t=23235, `visibility
  // =visible … dt=-1` at t=23281). A synchronous clear here lets the
  // visibility handler see grace=0 → grace MISS → location.reload(),
  // which kills the in-flight upload init request before it can land.
  //
  // Deferring the clear by 2 s covers the visibility transition + the
  // typical upload init RTT (a few hundred ms). After the timeout the
  // flag goes back to 0 so the next genuine backgrounding triggers
  // reload as expected. The cancel path (no change event) naturally
  // relies on the 60 s window in openUploadFilePicker for its grace.
  window.setTimeout(() => {
    filePickerOpenAt = 0;
  }, 2_000);
  uploadFileInput.value = "";
  enqueueUploads(files);
});

// How long a queued upload waits for the WebSocket to come back before
// we give up and surface an error toast. 15 s covers the common
// foreground-resume reconnect (≤ 5 s with the default backoff) plus
// some headroom for a flaky network without making the user stare at
// a stuck spinner.
const UPLOAD_PENDING_TIMEOUT_MS = 15_000;
// Hard cap on auto-retries when init returns 401. One retry covers
// "session expired mid-resume, bounce the WS and the relay re-issues a
// hello" without looping forever if the user's token is truly dead.
const UPLOAD_AUTH_RETRY_LIMIT = 1;

// Queued files that arrived while the WS was down. Drained from
// socket.onopen and from a 1 s sweep that enforces the deadline.
const pendingUploads = [];
let pendingUploadSweepTimer = null;

function isUploadReady() {
  return (
    activeSession != null &&
    socket != null &&
    socket.readyState === WebSocket.OPEN
  );
}

function enqueueUploads(files) {
  if (!files || files.length === 0) return;
  for (const file of files) {
    queueUpload(file);
  }
}

function queueUpload(file, { toastId = null, attempt = 0 } = {}) {
  // Always render *something* immediately: when the user drops or
  // pastes a file with the socket down, the silence before the actual
  // upload starts otherwise feels like the action vanished.
  const id =
    toastId ??
    `pending-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  if (isUploadReady()) {
    startSingleUpload(file, id, attempt);
    return;
  }
  renderUploadToast({
    id,
    kind: "pending",
    title: file.name,
    message: "等待重新连接...",
  });
  pendingUploads.push({
    file,
    toastId: id,
    deadline: Date.now() + UPLOAD_PENDING_TIMEOUT_MS,
    attempt,
  });
  ensurePendingUploadSweep();
}

function startSingleUpload(file, toastId, attempt) {
  uploadManager.start(file, { toastId }).catch((err) => {
    if (err && err.code === "unauthorized") {
      // The relay said 401 (almost always session expired). Bounce the
      // socket so scheduleReconnect kicks in, then re-queue so the file
      // rides the new connection — but only up to UPLOAD_AUTH_RETRY_LIMIT
      // so a permanently-invalid token doesn't loop.
      const used = attempt;
      logEvt(
        `upload init 401, attempt=${used} limit=${UPLOAD_AUTH_RETRY_LIMIT}`,
      );
      if (used >= UPLOAD_AUTH_RETRY_LIMIT) {
        renderUploadToast({
          id: toastId,
          kind: "error",
          title: err.name ?? file.name,
          message: "会话已过期，请重新选择会话",
        });
        return;
      }
      // Forcing a close fires scheduleReconnect via socket.onclose,
      // which is what eventually re-issues "hello" on a fresh session.
      if (socket && socket.readyState === WebSocket.OPEN) {
        socket.close(4000, "upload_auth_resync");
      }
      renderUploadToast({
        id: toastId,
        kind: "pending",
        title: err.name ?? file.name,
        message: "会话失效，正在重连...",
      });
      pendingUploads.push({
        file,
        toastId,
        deadline: Date.now() + UPLOAD_PENDING_TIMEOUT_MS,
        attempt: used + 1,
      });
      ensurePendingUploadSweep();
      return;
    }
    logEvt(`upload start failed: ${err?.message ?? err}`);
  });
}

function ensurePendingUploadSweep() {
  if (pendingUploadSweepTimer != null) return;
  pendingUploadSweepTimer = window.setInterval(sweepPendingUploads, 1000);
}

function sweepPendingUploads() {
  if (pendingUploads.length === 0) {
    stopPendingUploadSweep();
    return;
  }
  const now = Date.now();
  // Split the queue into expired / still-waiting in one pass so we
  // don't mutate while iterating.
  const stillWaiting = [];
  const expired = [];
  for (const item of pendingUploads) {
    if (now >= item.deadline) expired.push(item);
    else stillWaiting.push(item);
  }
  pendingUploads.length = 0;
  pendingUploads.push(...stillWaiting);
  for (const item of expired) {
    renderUploadToast({
      id: item.toastId,
      kind: "error",
      title: item.file.name,
      message: "连接未恢复，已放弃上传",
    });
  }
  if (pendingUploads.length === 0) stopPendingUploadSweep();
}

function stopPendingUploadSweep() {
  if (pendingUploadSweepTimer != null) {
    window.clearInterval(pendingUploadSweepTimer);
    pendingUploadSweepTimer = null;
  }
}

function flushPendingUploads() {
  if (pendingUploads.length === 0) return;
  if (!isUploadReady()) return;
  const items = pendingUploads.splice(0);
  stopPendingUploadSweep();
  for (const item of items) {
    startSingleUpload(item.file, item.toastId, item.attempt);
  }
}

function cancelPendingUploads(reason) {
  if (pendingUploads.length === 0) {
    stopPendingUploadSweep();
    return;
  }
  const items = pendingUploads.splice(0);
  stopPendingUploadSweep();
  for (const item of items) {
    renderUploadToast({
      id: item.toastId,
      kind: "error",
      title: item.file.name,
      message: reason,
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
    target instanceof HTMLElement &&
    (target.tagName === "INPUT" ||
      target.tagName === "TEXTAREA" ||
      target.isContentEditable)
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
  // terminal.write's wrap already booked a forceAll=false schedulePaint;
  // upgrade it to forceAll so every visible row is redrawn. The snapshot
  // is a complete re-anchor — even when part of its content equals
  // wasmTerm's pre-snapshot state (static frame chrome, status bar),
  // we must overwrite the GPU page anyway because the canvas backing
  // could be stale (Android backgrounded WebView, driver page reuse,
  // ctx state from a recent renderer.resize).
  scheduleFullPaint();
  // Snapshot is a re-anchor checkpoint for FOLLOWERS only. Snapshots
  // are not just a connect-time event: the agent re-emits one on every
  // reconnect (nginx's idle timeout drops the agent WS while the host
  // is quiet, and the agent only notices when it next tries to send —
  // i.e. exactly when new output appears) and the relay broadcasts it
  // to every online client when anyone joins. Yanking a user who is
  // reading history on each of those made scrollback unusable, so
  // preserve their position — the terminal.write above already
  // restored viewportY via the write wrap when !userFollowBottom.
  //
  // When the user IS following and the locked host grid is taller
  // than the mobile viewport (e.g. host 46 rows in a 33-row visible
  // window), the snapshot lands but xterm's viewport stays at the
  // top → the user sees the top portion of the grid, cursor is
  // clipped below. Re-anchor to the bottom so the live area (where
  // new content lands) is in view. scrollTerminalToBottom is a no-op
  // for !userFollowBottom, so the call is naturally scoped.
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
  // Theme change rewrites every glyph's colour; renderer.setTheme alone
  // doesn't invalidate dist's per-row dirty tracking, so without a
  // forced full paint the next dirty-only render leaves rows that
  // happened to be clean drawn in the *previous* theme's colours.
  scheduleFullPaint();
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
  // Queued uploads are scoped to the session the user left — if they
  // pick a different one we shouldn't silently push the files into it.
  cancelPendingUploads("已退出会话，上传取消");
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
    // Don't reset follow-mode here — focusTerminal is fired from
    // viewport-resize / system handlers too, not only user intent.
    // The mobileInput "focus" event listener handles the user-driven
    // case (genuine new focus = user wants to type = follow restore);
    // if mobileInput is already focused, focus() is a no-op and we
    // intentionally leave userFollowBottom untouched so the user's
    // history-reading state survives keyboard show/hide.
    if (mobileFocusTimer !== null) {
      window.clearTimeout(mobileFocusTimer);
      mobileFocusTimer = null;
    }
    logEvt(
      `[SEL] focusTerminal → mobileInput.focus (selActive=${termSelActive})`,
    );
    mobileInput.focus({ preventScroll: true });
    return;
  }
  logEvt(`[SEL] focusTerminal → terminal.focus (desktop)`);
  if (terminal) terminal.focus();
}

// Follow-mode: when the user is actively reading history (pan or wasm
// scrollback away from the live area), we suppress the auto-anchor that
// runs on every binary frame / paint. New output keeps accumulating
// into wasmTerm but the visible viewport stays put, so the user isn't
// yanked back to the bottom mid-read. Restored to true by:
//   - snapshot landing (re-anchor checkpoint)
//   - user keyboard input via sendInput (typing implies they want to
//     see the response)
//   - user pan/scroll that lands back at the bottom
//   - enterTerminalView / connectToSession (fresh session = follow)
let userFollowBottom = true;

function isAtBottom() {
  if (!terminal) return true;
  // ghostty-web v0.4.0's buffer.active getters are stubs — viewportY
  // and baseY are both hardcoded `return 0`, so comparing them always
  // reported "at bottom". Whenever the pan axis had no range either
  // (host grid shorter than the viewport), follow-mode could never
  // disengage and every binary frame yanked the user out of history.
  // Read the terminal's real scroll offset instead: 0 = live screen,
  // >0 = rows into history (fractional mid smooth-scroll).
  const viewportY =
    typeof terminal.getViewportY === "function"
      ? terminal.getViewportY()
      : (terminal.viewportY ?? 0);
  const wasmAtBottom = viewportY <= 0;
  const panMax = maxDesktopPanY();
  const panAtBottom = panMax <= 0 || desktopPanY === panMax;
  return wasmAtBottom && panAtBottom;
}

function scrollTerminalToBottom() {
  if (!terminal) return;
  if (!userFollowBottom) return;
  if (typeof terminal.scrollToBottom === "function") {
    terminal.scrollToBottom();
  }
  // xterm's scrollToBottom only moves wasmTerm's internal viewport.
  // In desktop-width-mode the visible window is also clipped by our
  // own `desktopPanY` translate3d on .terminal-host (because the
  // host grid is taller than the mobile viewport and we expose the
  // off-screen rows via vertical pan). Without panToBottom here the
  // user lands on the grid top after every snapshot / busy producer
  // burst and only sees the bottom rows after the soft keyboard
  // opens (visualViewport resize fires the .terminal-host
  // ResizeObserver at main.js:1276, which calls panToBottom). Doing
  // it inline keeps the two viewport axes in sync on every content
  // update — cheap (clamped translate3d write, no canvas repaint).
  if (shouldUseMobileInput() && isDesktopWidthMode()) {
    panToBottom();
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
  // Any user-driven keypress / paste / toolbar tap means they want to
  // see the response — re-enable follow-mode even if they were reading
  // history a moment ago. The next binary frame's auto-anchor will then
  // bring them back to the bottom.
  userFollowBottom = true;
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
  // User-driven tap on a toolbar key → re-enable follow-mode (same
  // policy as sendInput). The post-tap scrollTerminalToBottom() then
  // actually anchors.
  userFollowBottom = true;
  // dist's keyboard handler is attached to its helper textarea (inside
  // the `.terminal-canvas-host` wrapper now, not terminalMount). Events
  // dispatched on terminalMount bubble UP to document and never reach
  // the textarea, so arrow/Tab/Home/etc. silently no-op. Dispatch on
  // the textarea directly so dist's listener fires. Fall back to
  // terminal.element / terminalMount only if textarea isn't exposed
  // (older dist versions).
  const target =
    terminal.textarea ||
    terminal.element?.querySelector("textarea") ||
    terminal.element ||
    terminalMount;
  target.dispatchEvent(event);
  return true;
}

// ---- Toolbar auto-repeat (press-and-hold) -------------------------------
// Holding an arrow / Backspace / etc. repeats it like a physical keyboard.
// Pointer Events (not touch) so one path covers desktop mouse-hold and
// touch; setPointerCapture keeps move/up anchored to the button even if the
// finger drifts off it (otherwise the interval would never stop). The
// container's capture-phase pointerdown (added further below) already
// preventDefault()s the focus transfer, so we must NOT preventDefault here.
const TOOLBAR_REPEAT_DELAY_MS = 400;
const TOOLBAR_REPEAT_INTERVAL_MS = 90;
const TOOLBAR_REPEAT_MOVE_TOLERANCE_PX = 12;
// Timestamp (not a boolean) to swallow the synthesized click trailing a
// pointer press — same rationale as lastSessionLongPressAt: some WebViews
// don't emit the trailing click, and a sticky boolean would then swallow
// the NEXT genuine tap.
let lastToolbarRepeatAt = 0;
function toolbarRepeatJustFired() {
  return Date.now() - lastToolbarRepeatAt < 800;
}

// Fire one toolbar "seq" button action — identical to the click handler's
// seq branch. Special keys go through a synthesized keydown; raw character
// sequences fall back to sendInput with the pending modifiers applied.
// sendToolbarKeyEvent already re-enables follow-mode (userFollowBottom),
// so every repeat tick keeps the viewport anchored, same as a single tap.
function fireToolbarSeqButton(button) {
  const seq = button.dataset.seq;
  if (sendToolbarKeyEvent(seq)) {
    scrollTerminalToBottom();
    return;
  }
  sendInput(applyPendingModifiers(toolbarSequence(seq)));
}

function attachToolbarRepeat(button) {
  let delayTimer = null;
  let intervalTimer = null;
  let startX = 0;
  let startY = 0;
  const stopRepeat = (event) => {
    if (delayTimer !== null) {
      window.clearTimeout(delayTimer);
      delayTimer = null;
    }
    if (intervalTimer !== null) {
      window.clearInterval(intervalTimer);
      intervalTimer = null;
    }
    if (event) {
      try {
        button.releasePointerCapture(event.pointerId);
      } catch {
        // Capture may not be held (older WebView) — ignore.
      }
    }
  };
  button.addEventListener("pointerdown", (event) => {
    // Primary mouse button / touch / pen only.
    if (event.button !== undefined && event.button !== 0) return;
    stopRepeat();
    startX = event.clientX;
    startY = event.clientY;
    try {
      button.setPointerCapture(event.pointerId);
    } catch {
      // Capture unsupported — fall back to move/up without anchoring.
    }
    // Fire immediately so the press feels instant, and stamp the timestamp
    // NOW (not only inside the interval) so the trailing synthesized click
    // is swallowed even for a quick tap that never enters the repeat phase.
    fireToolbarSeqButton(button);
    lastToolbarRepeatAt = Date.now();
    // Repeating ESC is useless and can disturb TUIs (vim) — fire once only.
    if (button.dataset.seq === "esc") return;
    delayTimer = window.setTimeout(() => {
      delayTimer = null;
      intervalTimer = window.setInterval(() => {
        lastToolbarRepeatAt = Date.now();
        fireToolbarSeqButton(button);
      }, TOOLBAR_REPEAT_INTERVAL_MS);
    }, TOOLBAR_REPEAT_DELAY_MS);
  });
  button.addEventListener("pointermove", (event) => {
    if (delayTimer === null && intervalTimer === null) return;
    if (
      Math.abs(event.clientX - startX) > TOOLBAR_REPEAT_MOVE_TOLERANCE_PX ||
      Math.abs(event.clientY - startY) > TOOLBAR_REPEAT_MOVE_TOLERANCE_PX
    ) {
      stopRepeat(event);
    }
  });
  button.addEventListener("pointerup", stopRepeat);
  button.addEventListener("pointercancel", stopRepeat);
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

// Largest visualViewport height seen = the keyboard-DOWN full-screen
// baseline. innerHeight also shrinks with the keyboard on Android, so it
// can't serve as the baseline; the running max can. Used by
// enterTerminalSelection to tell whether the soft keyboard is currently up.
let maxSeenViewportH = 0;
function syncMobileViewportInsets() {
  const mobile = shouldUseMobileInput();
  if (window.visualViewport) {
    maxSeenViewportH = Math.max(maxSeenViewportH, window.visualViewport.height);
  }
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
// Snapshot the current ring buffer to localStorage before a path that
// blows the buffer away (location.reload). The next boot prepends the
// snapshot so the DL button still shows what happened across the
// reload boundary. No-op when debug is off. Defined at module scope
// so visibility handlers below can call it; the implementation is
// installed inside the `if (debugEnabled)` block.
const DEBUG_PERSIST_KEY = "ghostty-debug-prev-logs";
let persistDebugLogsForReload = () => {};
if (debugEnabled) {
  const debugBar = document.createElement("div");
  debugBar.style.cssText =
    "position:fixed;top:0;left:0;right:0;z-index:9999;font:11px/1.3 ui-monospace,monospace;background:rgba(0,0,0,0.82);color:#7de3bb;padding:3px 8px;white-space:nowrap;overflow:hidden;display:flex;gap:6px;align-items:center;";
  const debugText = document.createElement("span");
  // min-width:0 lets the text actually shrink (flex items default to
  // min-width:auto) so the buttons always have room and never get clipped
  // by the bar's overflow:hidden.
  debugText.style.cssText =
    "flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;pointer-events:none;";
  debugText.textContent = "(waiting for touch)";
  // All three buttons must set width:auto + flex:0 0 auto to override the
  // global `button { width: 100% }`; otherwise each wants full width and a
  // third button pushes the others off-screen (clipped by overflow:hidden).
  const debugBtnCss =
    "font:11px ui-monospace,monospace;border:0;border-radius:3px;padding:2px 8px;width:auto;flex:0 0 auto;";
  const debugDlBtn = document.createElement("button");
  debugDlBtn.textContent = "DL";
  debugDlBtn.style.cssText = debugBtnCss + "background:#7de3bb;color:#000;";
  const debugClrBtn = document.createElement("button");
  debugClrBtn.textContent = "CLR";
  debugClrBtn.style.cssText = debugBtnCss + "background:#444;color:#fff;";
  const debugUpBtn = document.createElement("button");
  debugUpBtn.textContent = "UP";
  debugUpBtn.style.cssText = debugBtnCss + "background:#5ab0ff;color:#000;";
  debugBar.append(debugText, debugUpBtn, debugDlBtn, debugClrBtn);
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
  // Hydrate ring buffer with logs persisted by a previous reload path.
  // We pull then immediately clear so a fresh boot without a prior
  // reload behaves identically to before. The boundary marker makes
  // the DL output easy to scan when diagnosing reload-induced bugs.
  try {
    const prev = localStorage.getItem(DEBUG_PERSIST_KEY);
    if (prev) {
      localStorage.removeItem(DEBUG_PERSIST_KEY);
      const lines = prev.split("\n").filter(Boolean);
      const carry = lines.slice(-DEBUG_LOG_CAP);
      for (const line of carry) debugLogs.push(line);
      debugLogs.push("-------- reload boundary --------");
    }
  } catch (_) {}
  persistDebugLogsForReload = () => {
    try {
      localStorage.setItem(DEBUG_PERSIST_KEY, debugLogs.join("\n"));
    } catch (_) {}
  };
  debugDlBtn.addEventListener("click", () => {
    const body = debugLogs.join("\n") + "\n";
    // Capacitor WebView (HarmonyOS / Android) silently drops blob URL +
    // <a download>. Fall back to "copy to clipboard + show in a full-screen
    // <textarea> for manual select+copy" — same trade-off documented in
    // ../CLAUDE.md (APK download grant flow). Browser builds keep the
    // real blob download because it produces an actual file.
    if (window.Capacitor?.isNativePlatform?.()) {
      showDebugLogOverlay(body);
    } else {
      const blob = new Blob([body], { type: "text/plain;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `touch-log-${new Date().toISOString().replace(/[:.]/g, "-")}.txt`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
  });
  // One-tap log upload: turn the in-memory log into a .txt File and push it
  // through the EXISTING file-upload path. It lands on the Mac agent at
  // ~/Library/Application Support/com.mitchellh.ghostty/uploads/<session>/,
  // which Claude Code can read directly — no copy/paste, no share sheet,
  // no relay changes. Needs an active session; if the socket is down,
  // enqueueUploads queues it and flushes on reconnect.
  debugUpBtn.addEventListener("click", () => {
    const body = debugLogs.join("\n") + "\n";
    const fname = `ghostty-log-${new Date().toISOString().replace(/[:.]/g, "-")}.txt`;
    let file;
    try {
      file = new File([body], fname, { type: "text/plain" });
    } catch (_) {
      // Older engines without the File constructor: tag a Blob with a name.
      file = new Blob([body], { type: "text/plain" });
      file.name = fname;
    }
    enqueueUploads([file]);
    setDebugBar(`UP ${fname} (${body.length}B)`);
  });
  debugClrBtn.addEventListener("click", () => {
    debugLogs.length = 0;
    setDebugBar("(cleared)");
  });
  // Full-screen overlay used as APP-mode fallback for the DL button.
  // Tries clipboard first; always shows the textarea so long-press
  // select+copy works if Clipboard API is rejected by the WebView.
  function showDebugLogOverlay(body) {
    const overlay = document.createElement("div");
    overlay.style.cssText =
      "position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,0.92);display:flex;flex-direction:column;padding:env(safe-area-inset-top) 8px env(safe-area-inset-bottom);gap:6px;";
    const status = document.createElement("div");
    status.style.cssText =
      "font:12px ui-monospace,monospace;color:#7de3bb;padding:4px 2px;";
    status.textContent = "正在复制到剪贴板...";
    const ta = document.createElement("textarea");
    ta.readOnly = true;
    ta.value = body;
    ta.style.cssText =
      "flex:1;width:100%;font:11px/1.3 ui-monospace,monospace;background:#111;color:#ddd;border:1px solid #333;border-radius:4px;padding:6px;resize:none;-webkit-user-select:text;user-select:text;";
    const row = document.createElement("div");
    row.style.cssText = "display:flex;gap:8px;";
    const selectAllBtn = document.createElement("button");
    selectAllBtn.textContent = "全选";
    selectAllBtn.style.cssText =
      "flex:1;font:13px ui-monospace,monospace;background:#444;color:#fff;border:0;border-radius:4px;padding:10px;";
    const closeBtn = document.createElement("button");
    closeBtn.textContent = "关闭";
    closeBtn.style.cssText =
      "flex:1;font:13px ui-monospace,monospace;background:#7de3bb;color:#000;border:0;border-radius:4px;padding:10px;";
    row.append(selectAllBtn, closeBtn);
    overlay.append(status, ta, row);
    document.body.appendChild(overlay);
    selectAllBtn.addEventListener("click", () => {
      ta.focus();
      ta.select();
    });
    closeBtn.addEventListener("click", () => overlay.remove());
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(body).then(
        () => {
          status.textContent =
            "已复制到剪贴板。可直接粘贴到笔记 / 微信。也可下方长按全选手动复制。";
        },
        (err) => {
          status.textContent = `自动复制失败 (${err?.message || err})，请点"全选"后长按 → 复制。`;
        },
      );
    } else {
      status.textContent = '剪贴板 API 不可用，请点"全选"后长按 → 复制。';
    }
  }
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
        // The jump moved the wasm viewport — recompute follow-mode so
        // the next binary frame doesn't yank the user back to the
        // bottom (same policy as the swipe-scroll paths).
        userFollowBottom = isAtBottom();
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
        // Same as the swipe paths: the drag moved the wasm viewport,
        // recompute follow-mode (dragging back to the bottom of the
        // lane restores follow automatically).
        userFollowBottom = isAtBottom();
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
        // User actively steered the Y pan — recompute follow-mode so
        // a subsequent binary frame doesn't yank them back. Re-bottom
        // pan restores follow automatically (isAtBottom checks both
        // axes).
        userFollowBottom = isAtBottom();
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
      // Same as above — user moved wasmTerm viewport, recompute follow.
      userFollowBottom = isAtBottom();
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
  // A long-press that entered selection mode must NOT focus mobileInput
  // (that would pop the soft keyboard and clear the selection). Swallow
  // the trailing tap.
  if (termSelLongPressFired) {
    termSelLongPressFired = false;
    return;
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
    logEvt(`[SEL] SUPPRESS ${event.type}`);
  } else {
    logEvt(`[SEL] PASS ${event.type} (no suppress window)`);
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
  // Two cases where ghostty-web would re-raise the keyboard against the
  // user's intent: (1) a moved swipe, (2) a long-press that just entered
  // text-selection mode. In both, swallow dist's synthetic click/pointerup
  // so it doesn't focus its hidden textarea and pop the soft keyboard.
  // (A plain tap still wants focus + keyboard, so it's excluded.)
  logEvt(
    `[SEL] touchend longPressFired=${termSelLongPressFired} tss=${touchScrollState ? touchScrollState.type + (touchScrollState.moved ? "/moved" : "") : "null"} cancelable=${event.cancelable ? 1 : 0}`,
  );
  if (
    termSelLongPressFired ||
    (touchScrollState &&
      touchScrollState.type === "swipe" &&
      touchScrollState.moved)
  ) {
    if (event.cancelable) event.preventDefault();
    suppressTerminalClickUntil = performance.now() + 500;
    logEvt(`[SEL] touchend → suppress window +500ms`);
  }
  endTouchScroll();
});
terminalMount.addEventListener("touchcancel", () => {
  logEvt(`touchcancel`);
  touchScrollState = null;
});

// ===== Mobile/APP long-press text selection =============================
// Touch only — desktop keeps dist's native mouse drag-select. The terminal
// is a canvas, so selection is driven through ghostty-web's select() API
// and dist renders the highlight itself; we only draw two drag handles + a
// copy/share bar. Coordinate system pinned to dist's SelectionManager:
//   select(col, row, len): row is VIEWPORT-relative (0 = top visible row),
//     dist adds viewportY internally; col 0-based; len = char count (wraps
//     across rows by cols).
//   pixel→cell: floor((clientX - canvasRect.left) / charW), same for row.
//   charW/H = renderer.getMetrics() (CSS px, DPR already handled).
//   canvasRect via getBoundingClientRect() already reflects the desktop-pan
//   translate, and scroll offset is dist's viewportY — so NO manual
//   pan/scroll correction is needed.
const TERMINAL_LONG_PRESS_MS = 500;
const TERMINAL_LONG_PRESS_MOVE_PX = 10;
const SELECTION_BREAK_RE =
  /[\s\u0021-\u002c\u002e\u002f\u003a-\u0040\u005b-\u005e\u0060\u007b-\u007e\u3000-\u303f\uff00-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65]/;

let termSelLongPressTimer = null;
let termSelLongPressFired = false;
let termSelActive = false;
let termSelStartCell = null; // {col,row} in viewport coords
let termSelEndCell = null;
// Text captured at SELECTION time (press + every handle drag), read straight
// from the live buffer via getLine. dist's getSelection() reads the buffer at
// COPY time, which on HarmonyOS WebView is often already empty (the canvas
// shows stale GPU-cached pixels while the buffer rows have been cleared) —
// so copy must use this cached snapshot, not a fresh getSelection().
let termSelText = "";
// Soft-keyboard visible/hidden state captured at the START of the gesture that
// may become a selection. The whole long-press → copy/paste/share flow must
// NOT change the keyboard's shown/hidden state, so we record it up front and
// restore it on exit (exitTerminalSelection → restoreKeyboardState).
let kbVisibleOnSelect = false;
let termSelStartX = 0;
let termSelStartY = 0;
let termSelHandleStart = null;
let termSelHandleEnd = null;
let termSelBar = null;

function clampInt(value, lo, hi) {
  return Math.max(lo, Math.min(value, hi));
}

function terminalCanvasEl() {
  return terminalMount.querySelector("canvas");
}

function terminalMetrics() {
  return terminal?.renderer?.getMetrics?.() || null;
}

// Browser clientX/Y → viewport cell {col,row}, matching dist's pixelToCell.
function terminalPixelToCell(clientX, clientY) {
  const canvas = terminalCanvasEl();
  const m = terminalMetrics();
  if (!canvas || !m || !terminal) return null;
  const rect = canvas.getBoundingClientRect();
  return {
    col: clampInt(
      Math.floor((clientX - rect.left) / m.width),
      0,
      (terminal.cols || 1) - 1,
    ),
    row: clampInt(
      Math.floor((clientY - rect.top) / m.height),
      0,
      (terminal.rows || 1) - 1,
    ),
  };
}

// Viewport cell → fixed-position pixel (top-left of the cell).
function terminalCellToFixed(col, row) {
  const canvas = terminalCanvasEl();
  const m = terminalMetrics();
  if (!canvas || !m) return null;
  const rect = canvas.getBoundingClientRect();
  return {
    x: rect.left + col * m.width,
    y: rect.top + row * m.height,
    w: m.width,
    h: m.height,
  };
}

function ensureSelectionDom() {
  if (termSelBar) return;
  termSelHandleStart = document.createElement("div");
  termSelHandleStart.className = "term-sel-handle";
  termSelHandleStart.dataset.handle = "start";
  termSelHandleEnd = document.createElement("div");
  termSelHandleEnd.className = "term-sel-handle";
  termSelHandleEnd.dataset.handle = "end";
  termSelBar = document.createElement("div");
  termSelBar.className = "term-sel-bar";
  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.textContent = "复制";
  const pasteBtn = document.createElement("button");
  pasteBtn.type = "button";
  pasteBtn.textContent = "粘贴";
  const shareBtn = document.createElement("button");
  shareBtn.type = "button";
  shareBtn.textContent = "分享";
  termSelBar.append(copyBtn, pasteBtn, shareBtn);
  document.body.append(termSelHandleStart, termSelHandleEnd, termSelBar);

  // Taps on handles/bar must not bubble to terminalMount (which would
  // dismiss the selection) and must not steal focus.
  for (const el of [termSelHandleStart, termSelHandleEnd, termSelBar]) {
    el.addEventListener("pointerdown", (e) => e.stopPropagation(), true);
    el.addEventListener("touchstart", (e) => e.stopPropagation(), {
      capture: true,
      passive: true,
    });
  }
  // The action buttons must NOT steal focus from mobileInput — taking focus
  // blurs the soft keyboard and changes its shown/hidden state, which the
  // long-press → copy/paste/share flow must never do. preventDefault on
  // mousedown is the canonical "keep focus where it is" trick: it stops the
  // focus transfer while leaving the click event intact. (capture so it runs
  // before the synthesized focus.)
  termSelBar.addEventListener("mousedown", (e) => e.preventDefault(), true);
  copyBtn.addEventListener("click", (e) => {
    e.preventDefault();
    copyTerminalSelection();
  });
  pasteBtn.addEventListener("click", (e) => {
    e.preventDefault();
    pasteFromClipboard();
  });
  shareBtn.addEventListener("click", (e) => {
    e.preventDefault();
    shareTerminalSelection();
  });
  attachHandleDrag(termSelHandleStart);
  attachHandleDrag(termSelHandleEnd);
}

// The dist SelectionManager (TS-private but present at runtime) drives the
// selection / scrollback-aware row mapping we rely on.
function selManager() {
  return terminal?.selectionManager || null;
}

// Force the keyboard back to the state it had when the selection started, so
// the long-press → copy/paste/share flow never changes shown/hidden. Driven
// purely by mobileInput focus (focused ⇒ keyboard up, blurred ⇒ down).
function restoreKeyboardState() {
  if (!shouldUseMobileInput() || !mobileInput) return;
  if (kbVisibleOnSelect) {
    if (document.activeElement !== mobileInput) {
      mobileInput.focus({ preventScroll: true });
    }
  } else if (document.activeElement === mobileInput) {
    mobileInput.blur();
  }
}

// Set the selection from VIEWPORT coordinates, driving the SelectionManager
// directly. We CANNOT use dist's public select()/selectLines(): they compute
// the absolute buffer row as `viewportY + row`, which is wrong whenever
// scrollback exists — the correct mapping is `scrollbackLen + row - viewportY`
// (viewportRowToAbsolute). With scrollback, select() lands the selection on
// off-screen scrollback rows: getSelection() returns "", normalizeSelection()
// returns null, and no highlight draws (observed on real devices). Setting
// selectionStart/End ourselves with viewportRowToAbsolute fixes all of that.
// NOTE: dist internals (TS-private but present at runtime) — re-verify on any
// ghostty-web upgrade: selectionManager, viewportRowToAbsolute,
// selectionStart/End, requestRender, selectionChangedEmitter.
function setViewportSelection(startCol, startRow, endCol, endRow) {
  const sm = selManager();
  if (!sm || typeof sm.viewportRowToAbsolute !== "function") return false;
  sm.selectionStart = {
    col: startCol,
    absoluteRow: sm.viewportRowToAbsolute(startRow),
  };
  sm.selectionEnd = {
    col: endCol,
    absoluteRow: sm.viewportRowToAbsolute(endRow),
  };
  sm.requestRender?.();
  sm.selectionChangedEmitter?.fire?.();
  return true;
}

// Build the selected text ourselves from the live buffer, replicating dist's
// getSelection() scrollback/screen split but under OUR control so we can call
// it at SELECTION time (when the buffer rows are guaranteed live) and cache
// the result. Reads selectionStart/End (absolute buffer rows) from the
// SelectionManager. Returns "" if there's no selection.
function buildSelectionText() {
  const sm = selManager();
  const wt = terminal?.wasmTerm;
  if (!sm || !sm.selectionStart || !sm.selectionEnd || !wt) return "";
  let aCol = sm.selectionStart.col;
  let aRow = sm.selectionStart.absoluteRow;
  let bCol = sm.selectionEnd.col;
  let bRow = sm.selectionEnd.absoluteRow;
  if (aRow > bRow || (aRow === bRow && aCol > bCol)) {
    [aCol, bCol] = [bCol, aCol];
    [aRow, bRow] = [bRow, aRow];
  }
  const sbLen = wt.getScrollbackLength?.() ?? 0;
  const lines = [];
  for (let D = aRow; D <= bRow; D++) {
    const line =
      D < sbLen ? wt.getScrollbackLine?.(D) : wt.getLine?.(D - sbLen);
    if (!line) {
      lines.push("");
      continue;
    }
    const sCol = D === aRow ? aCol : 0;
    const eCol = D === bRow ? bCol : line.length - 1;
    let s = "";
    for (let c = sCol; c <= eCol && c < line.length; c++) {
      const cell = line[c];
      // Wide-char (CJK/emoji) spacer cell: width 0, codepoint 0. The glyph
      // was already emitted by the preceding cell, so skip it — otherwise
      // every wide char gets a spurious trailing space ("你 选 中").
      if (cell && cell.width === 0) continue;
      s +=
        cell && cell.codepoint && cell.codepoint !== 0
          ? String.fromCodePoint(cell.codepoint)
          : " ";
    }
    lines.push(s.replace(/\s+$/, ""));
  }
  return lines.join("\n");
}

// Recompute the cached selection text from the live buffer. Call after every
// change to the selection (initial word select + each handle drag).
function captureSelectionText() {
  termSelText = buildSelectionText();
}

// Read a VIEWPORT row's cells scrollback-aware. getLine() indexes the active
// screen, so a raw getLine(viewportRow) reads the wrong line whenever the user
// has scrolled into history (viewportY > 0) — the visible row then maps to a
// scrollback line. Mirror buildSelectionText: map viewport row → absolute row
// via the SelectionManager, then split scrollback vs screen.
function viewportRowCells(row) {
  const wt = terminal?.wasmTerm;
  if (!wt) return null;
  const abs = selManager()?.viewportRowToAbsolute?.(row);
  if (abs == null) return wt.getLine?.(row) ?? null;
  const sbLen = wt.getScrollbackLength?.() ?? 0;
  return abs < sbLen ? wt.getScrollbackLine?.(abs) : wt.getLine?.(abs - sbLen);
}

function selectWordAt(col, row) {
  if (!terminal) return false;
  const cols = terminal.cols || 1;
  const line = viewportRowCells(row);
  // Word-ness of a cell column, read straight from the live buffer. getLine is
  // reliable; the old per-cell dist getSelection probe mis-read CJK and even
  // ASCII, so word-expand only ever grabbed a single char. A wide-char spacer
  // (width 0) inherits the owning glyph in the previous column, so a CJK run
  // scans as one word; SELECTION_BREAK_RE bounds words at whitespace and
  // ASCII/CJK punctuation.
  const isWord = (c) => {
    if (!line || c < 0 || c >= cols) return false;
    let cell = line[c];
    if (cell && cell.width === 0 && c > 0) cell = line[c - 1];
    if (!cell || !cell.codepoint || cell.codepoint === 0) return false;
    return !SELECTION_BREAK_RE.test(String.fromCodePoint(cell.codepoint));
  };
  let c = col;
  if (!isWord(c)) {
    // Press landed on whitespace / padding — snap to the nearest word column.
    let found = -1;
    for (let d = 1; d <= 40; d++) {
      if (isWord(col + d)) {
        found = col + d;
        break;
      }
      if (isWord(col - d)) {
        found = col - d;
        break;
      }
    }
    if (found < 0) {
      setViewportSelection(col, row, col, row);
      termSelStartCell = { col, row };
      termSelEndCell = { col, row };
      captureSelectionText();
      return true;
    }
    c = found;
  }
  let s = c;
  while (isWord(s - 1)) s--;
  let e = c;
  while (isWord(e + 1)) e++;
  setViewportSelection(s, row, e, row);
  termSelStartCell = { col: s, row };
  termSelEndCell = { col: e, row };
  captureSelectionText();
  return true;
}

function enterTerminalSelection(clientX, clientY) {
  if (!terminal || !shouldUseMobileInput()) return;
  const cell = terminalPixelToCell(clientX, clientY);
  if (!cell) return;
  ensureSelectionDom();
  if (!selectWordAt(cell.col, cell.row)) return;
  termSelActive = true;
  // Keyboard state is handled at touchstart (see the long-press listener),
  // not here — doing it at enter (long-press fire, 500ms in) is too late and
  // the keyboard flashes up first. enter must not touch focus.
  refreshSelectionFromDist();
  // Must be a FULL paint: dist's select() API sets the selection but does
  // NOT mark the selected rows dirty (only mouse-drag selection and
  // clearSelection do). A dirty-only paint would skip those rows and the
  // highlight never draws — handles/bar show but the text isn't highlighted.
  scheduleFullPaint();
  showSelectionUI();
  const canvasRect = terminalCanvasEl()?.getBoundingClientRect();
  const m = terminalMetrics();
  logEvt(
    `[SEL] enter cell=${cell.col},${cell.row} start=${termSelStartCell?.col},${termSelStartCell?.row} end=${termSelEndCell?.col},${termSelEndCell?.row} ` +
      `pos=${JSON.stringify(terminal.getSelectionPosition?.() ?? null)} ` +
      `text="${(terminal.getSelection?.() || "").slice(0, 24)}" ` +
      `cols=${terminal.cols} rows=${terminal.rows} vY=${terminal.getViewportY?.()} ` +
      `m=${m ? `${m.width.toFixed(1)}x${m.height.toFixed(1)}` : "null"} ` +
      `rect=${canvasRect ? `${canvasRect.left.toFixed(0)},${canvasRect.top.toFixed(0)} ${canvasRect.width.toFixed(0)}x${canvasRect.height.toFixed(0)}` : "null"}`,
  );
}

// Re-read the authoritative selection rect from dist (viewport coords).
function refreshSelectionFromDist() {
  const pos = terminal?.getSelectionPosition?.();
  if (!pos) return false;
  termSelStartCell = { col: pos.start.x, row: pos.start.y };
  termSelEndCell = { col: pos.end.x, row: pos.end.y };
  return true;
}

// Keep the handles/bar pinned to the live selection when the viewport
// moves under it — terminal output scrolling the buffer, the soft keyboard
// resizing the view, or device rotation. dist anchors the highlight to the
// absolute buffer row, so its viewport projection shifts; getSelectionPosition
// returns that fresh projection (clamped to the visible range), which we
// re-read and redraw. If the selection scrolled fully out of view, hide the
// UI; it reappears when it scrolls back. Handle-drag uses raw finger cells,
// not this path, so the two never fight (you can't drag while it scrolls).
function repositionActiveSelection() {
  if (!termSelActive) return;
  if (refreshSelectionFromDist()) {
    // Full paint so the highlight survives the viewport move (select()
    // rows aren't marked dirty — see enterTerminalSelection).
    scheduleFullPaint();
    showSelectionUI();
  } else {
    hideSelectionUI();
  }
}

function showSelectionUI() {
  if (!termSelActive || !termSelStartCell || !termSelEndCell) return;
  const startFx = terminalCellToFixed(
    termSelStartCell.col,
    termSelStartCell.row,
  );
  // End handle anchors to the right edge of the last selected cell.
  const endFx = terminalCellToFixed(termSelEndCell.col + 1, termSelEndCell.row);
  if (!startFx || !endFx) return;
  termSelHandleStart.style.left = `${startFx.x}px`;
  termSelHandleStart.style.top = `${startFx.y + startFx.h}px`;
  termSelHandleStart.classList.add("visible");
  termSelHandleEnd.style.left = `${endFx.x}px`;
  termSelHandleEnd.style.top = `${endFx.y + endFx.h}px`;
  termSelHandleEnd.classList.add("visible");
  // Bar centered above the selection's top; flip below if no room.
  termSelBar.classList.add("visible");
  const midX = (startFx.x + endFx.x) / 2;
  const topY = Math.min(startFx.y, endFx.y);
  let barTop = topY - termSelBar.offsetHeight - 8;
  if (barTop < 4) barTop = Math.max(startFx.y, endFx.y) + startFx.h + 14;
  termSelBar.style.left = `${midX}px`;
  termSelBar.style.top = `${barTop}px`;
}

function hideSelectionUI() {
  termSelHandleStart?.classList.remove("visible");
  termSelHandleEnd?.classList.remove("visible");
  termSelBar?.classList.remove("visible");
}

function exitTerminalSelection(restoreKb = true) {
  if (!termSelActive) return;
  termSelActive = false;
  termSelStartCell = null;
  termSelEndCell = null;
  termSelText = "";
  hideSelectionUI();
  terminal?.clearSelection?.();
  schedulePaint();
  // Preserve the keyboard's shown/hidden state across the whole long-press →
  // copy/paste/share flow. The touchstart-dismiss path opts out
  // (restoreKb=false): a fresh tap on the terminal follows the normal
  // tap-to-focus behaviour instead.
  if (restoreKb) restoreKeyboardState();
}

// Synchronous execCommand copy. HarmonyOS / Android WebViews deny
// navigator.clipboard.writeText ("Write permission denied"), so this is the
// reliable path. Notes:
//   - readonly: stops the textarea from popping the soft keyboard on focus.
//   - appended to <body> (NOT inside terminalView): the focusin guard that
//     blurs stray textareas only polices terminalView, so this one survives
//     long enough to be selected + copied.
//   - must run inside the click gesture (no await before it).
function execCommandCopy(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.cssText =
    "position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0;";
  document.body.appendChild(ta);
  let ok = false;
  try {
    ta.focus();
    ta.select();
    ta.setSelectionRange(0, text.length);
    ok = document.execCommand("copy");
  } catch (_) {
    ok = false;
  }
  ta.remove();
  return ok;
}

// Copy text. On the APP (Capacitor native) the HarmonyOS WebView denies the
// async Clipboard API AND execCommand silently no-ops (returns true but
// writes nothing), so the ONLY reliable path is the native @capacitor/clipboard
// plugin (Android ClipboardManager). Web/desktop keep execCommand + Clipboard
// API. Dynamic import mirrors the @capacitor/app pattern so browser builds
// (window.Capacitor undefined) never load the plugin.
async function copyTextRobust(text) {
  if (!text) return false;
  if (window.Capacitor?.isNativePlatform?.()) {
    try {
      const { Clipboard } = await import("@capacitor/clipboard");
      await Clipboard.write({ string: text });
      return true;
    } catch (err) {
      logEvt(`[SEL] native clipboard write failed ${err?.message || err}`);
    }
  }
  if (execCommandCopy(text)) return true;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (err) {
    logEvt(`[SEL] clipboard write failed ${err?.message || err}`);
    return false;
  }
}

// Read the clipboard and paste into the terminal. Native plugin first (same
// reasons as copyTextRobust), then navigator.clipboard for web/desktop. The
// text goes through terminal.paste() so bracketed-paste mode is honoured.
async function pasteFromClipboard() {
  let text = "";
  if (window.Capacitor?.isNativePlatform?.()) {
    try {
      const { Clipboard } = await import("@capacitor/clipboard");
      const res = await Clipboard.read();
      text = res?.value || "";
    } catch (err) {
      logEvt(`[SEL] native clipboard read failed ${err?.message || err}`);
    }
  }
  if (!text) {
    try {
      text = (await navigator.clipboard.readText()) || "";
    } catch (err) {
      logEvt(`[SEL] clipboard read failed ${err?.message || err}`);
    }
  }
  if (text && terminal) {
    userFollowBottom = true;
    try {
      terminal.paste(text);
    } catch (err) {
      logEvt(`[SEL] paste failed ${err?.message || err}`);
    }
  }
  logEvt(`[SEL] paste len=${text.length}`);
  exitTerminalSelection();
}

// Pick the best available selection text: the snapshot captured at selection
// time (buffer guaranteed live) first, then a fresh live re-read, then dist's
// own getSelection() as a last resort. On HarmonyOS the cached one is usually
// the only non-empty source (buffer cleared by copy time, canvas stale).
function resolveSelectionText() {
  return (
    termSelText || buildSelectionText() || terminal?.getSelection?.() || ""
  );
}

async function copyTerminalSelection() {
  const text = resolveSelectionText();
  if (text) {
    const ok = await copyTextRobust(text);
    showSessionActionToast(ok ? "已复制" : "复制失败");
    logEvt(
      `[SEL] copy ok=${ok} len=${text.length} preview="${text.slice(0, 16)}"`,
    );
  } else {
    showSessionActionToast("未选中文字");
    logEvt(`[SEL] copy SKIP empty selection`);
  }
  exitTerminalSelection();
}

async function shareTerminalSelection() {
  const text = resolveSelectionText();
  if (!text) {
    exitTerminalSelection();
    return;
  }
  if (navigator.share) {
    try {
      await navigator.share({ text });
    } catch (err) {
      // User-cancelled share rejects — ignore.
      logEvt(`[SEL] share dismissed/failed ${err?.message || err}`);
    }
  } else {
    const ok = await copyTextRobust(text);
    logEvt(`[SEL] share unsupported, copied instead ok=${ok}`);
    showSessionActionToast(ok ? "已复制" : "复制失败");
  }
  exitTerminalSelection();
}

// Re-apply the selection from the cached start/end cells after a handle drag.
function applySelectionRange() {
  if (!terminal || !termSelStartCell || !termSelEndCell) return;
  let a = termSelStartCell;
  let b = termSelEndCell;
  if (a.row > b.row || (a.row === b.row && a.col > b.col)) {
    [a, b] = [b, a];
  }
  setViewportSelection(a.col, a.row, b.col, b.row);
  // Re-capture the text from the live buffer on every drag step — the buffer
  // rows are guaranteed live while the user is actively selecting.
  captureSelectionText();
  // Full paint: setting the selection doesn't mark the rows dirty (see
  // enterTerminalSelection), so dirty-only wouldn't redraw the highlight.
  scheduleFullPaint();
}

function attachHandleDrag(handle) {
  handle.addEventListener(
    "touchmove",
    (event) => {
      if (!termSelActive) return;
      const touch = event.touches[0];
      if (!touch) return;
      event.preventDefault();
      const cell = terminalPixelToCell(touch.clientX, touch.clientY);
      if (!cell) return;
      if (handle.dataset.handle === "start") termSelStartCell = cell;
      else termSelEndCell = cell;
      applySelectionRange();
      // Do NOT refreshSelectionFromDist() here. applySelectionRange already
      // normalises (swaps) the range for dist's highlight, but we keep the
      // raw start/end cells tied to their physical handle so dragging one
      // handle past the other doesn't swap which handle the finger controls
      // (that caused a visible jump). showSelectionUI draws each handle from
      // its own cell, so the handles simply cross — matching the finger.
      showSelectionUI();
    },
    { passive: false },
  );
  handle.addEventListener("touchend", (event) => event.stopPropagation());
}

// Long-press detection on the terminal. Independent of the scroll/pan
// listeners above — we only read positions and never preventDefault here.
terminalMount.addEventListener(
  "touchstart",
  (event) => {
    if (!shouldUseMobileInput()) return;
    // Keep the keyboard's VISIBLE state stable across this touch. If it's
    // already hidden but mobileInput is still focused, blur NOW (at
    // touchstart, before the long-press fires) so this touch can't revive
    // it — blur is invisible since the keyboard is already down. A real tap
    // re-focuses afterwards via endTouchScroll → focusTerminal. When the
    // keyboard is visible (vv.height well below the full-screen baseline) we
    // leave focus alone so it stays up.
    const vv = window.visualViewport;
    const kbDown =
      !vv || maxSeenViewportH <= 0 || vv.height >= maxSeenViewportH - 80;
    // Record the keyboard's state at the START of this gesture — if it becomes
    // a long-press selection, exitTerminalSelection restores exactly this.
    kbVisibleOnSelect = !kbDown;
    if (kbDown && document.activeElement === mobileInput) {
      mobileInput.blur();
    }
    // A fresh touch on the terminal dismisses an active selection (handles
    // and bar stopPropagation, so taps on them never reach here). Don't force
    // the keyboard here — the normal tap-to-focus path handles it.
    if (termSelActive) exitTerminalSelection(false);
    termSelLongPressFired = false;
    if (termSelLongPressTimer !== null) clearTimeout(termSelLongPressTimer);
    if (event.touches.length !== 1) return;
    const touch = event.touches[0];
    termSelStartX = touch.clientX;
    termSelStartY = touch.clientY;
    termSelLongPressTimer = window.setTimeout(() => {
      termSelLongPressTimer = null;
      termSelLongPressFired = true;
      logEvt(`[SEL] longpress fire @${termSelStartX | 0},${termSelStartY | 0}`);
      enterTerminalSelection(termSelStartX, termSelStartY);
    }, TERMINAL_LONG_PRESS_MS);
  },
  { passive: true },
);
terminalMount.addEventListener(
  "touchmove",
  (event) => {
    if (termSelLongPressTimer === null) return;
    const touch = event.touches[0];
    if (
      !touch ||
      Math.abs(touch.clientX - termSelStartX) > TERMINAL_LONG_PRESS_MOVE_PX ||
      Math.abs(touch.clientY - termSelStartY) > TERMINAL_LONG_PRESS_MOVE_PX
    ) {
      clearTimeout(termSelLongPressTimer);
      termSelLongPressTimer = null;
    }
  },
  { passive: true },
);
const clearTermSelLongPressTimer = () => {
  if (termSelLongPressTimer !== null) {
    clearTimeout(termSelLongPressTimer);
    termSelLongPressTimer = null;
  }
};
terminalMount.addEventListener("touchend", clearTermSelLongPressTimer, {
  passive: true,
});
terminalMount.addEventListener("touchcancel", clearTermSelLongPressTimer, {
  passive: true,
});
// Belt-and-braces for the native long-press menu: even with user-select:none
// on body.terminal-mode, some Android WebViews still synthesize a contextmenu
// on press-and-hold. Swallow it so the WebView's "复制/全选" callout never
// appears over our own selection bar.
terminalMount.addEventListener("contextmenu", (event) => {
  event.preventDefault();
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
  if (document.visibilityState !== "visible") return;
  // HarmonyOS / ICL-AL20 WebView caches the GPU compositor layer
  // texture across visibility transitions and merges every paint we
  // issue on top of the previously-cached frame. Every visibility
  // round-trip stacks another layer of stale pixels — symptom is
  // "two or more terminals overlapping, older sessions visible
  // underneath" after a few foreground/background cycles.
  //
  // Things that have been tried and *do not* clear it:
  //   - schedulePaint(force=true) / renderer.clear() — fillRect lands
  //     in 2D context backing but the compositor keeps the cached
  //     layer texture on top
  //   - layer-isolation wrapper `.terminal-canvas-host` with
  //     will-change + translateZ(0)
  //   - disposeTerminal that wipes the wrapper before any paint
  //     (verified via logEvt that dispose runs and ensureTerminal
  //     builds a brand-new wrapper, but the bug still reproduces)
  //
  // Only `location.reload()` — a full document navigation that tears
  // down the entire layer tree — reliably releases the cached
  // texture. The visible cost (~1-2 s blank → SPA boot → reconnect
  // → snapshot) is the same we paid with disposeTerminal, but this
  // path is the only one that actually fixes the overlap on
  // HarmonyOS.
  //
  // Session id lives in the URL (?session=<id>), token + backendBase
  // in localStorage → after reload the SPA routes straight back into
  // the same session and reconnects automatically. No user-visible
  // state is lost beyond the in-flight uploads (uploads in the
  // visibility-suspended state are already broken by the socket
  // close + 401 reauth dance anyway).
  //
  // Desktop browsers do not exhibit this bug; gate on Capacitor
  // native platform to keep the desktop "tab switch" experience
  // (instant resume, no flicker).
  if (window.Capacitor?.isNativePlatform?.()) {
    const sincePicker =
      filePickerOpenAt > 0 ? Date.now() - filePickerOpenAt : -1;
    logEvt(
      `visibility=visible APP filePickerOpenAt=${filePickerOpenAt} dt=${sincePicker}`,
    );
    // Skip the reload while a native file picker is plausibly open.
    // Reloading at picker dismiss time would kill the <input> change
    // callback before the selected file event lands, so the upload
    // would silently do nothing. The picker overlays the WebView so
    // no new stale frames accumulate during the grace window — this
    // is the one resume path where skipping the layer reset is safe.
    // See openUploadFilePicker for the timestamp + grace constant.
    if (filePickerOpenAt > 0 && sincePicker < FILE_PICKER_VISIBLE_GRACE_MS) {
      logEvt(`grace HIT, skip reload (dt=${sincePicker}ms)`);
      return;
    }
    logEvt(`grace MISS, reload`);
    persistDebugLogsForReload();
    window.location.reload();
    return;
  }
  // Desktop fallback: cheap soft-resync. Keep the existing
  // disposeTerminal + reconnect path because desktop's compositor
  // does not need a full reload to drop stale layers.
  if (terminal) disposeTerminal();
  setTerminalStatus("重连中", "reconnecting");
  startForcePaintWindow("visibility_visible");
  dropPendingWrites();
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.close(4000, "visibility_resync");
  }
  focusTerminal();
});

// Genuine focus on mobileInput = user taps it (or focusTerminal puts
// the IME up for them) and the input wasn't already focused. Reset
// follow-mode here: the act of taking focus implies "I'm about to
// type and want to see the response". focusTerminal itself doesn't
// reset because it's also called from viewport-resize and similar
// system bookkeeping handlers; if mobileInput was already focused,
// focus() is a no-op and we intentionally leave the user's
// history-reading state intact across keyboard show/hide.
mobileInput.addEventListener("focus", () => {
  userFollowBottom = true;
  logEvt(`[SEL] mobileInput FOCUS event`);
});

// Diagnostic: capture EVERY focus to learn who pops the soft keyboard
// after a long-press. mobileInput is ours; a TEXTAREA that isn't
// mobileInput is dist's hidden helper textarea (the suspected culprit).
document.addEventListener(
  "focusin",
  (event) => {
    const t = event.target;
    let who;
    if (t === mobileInput) who = "mobileInput";
    else if (t && t.tagName === "TEXTAREA") who = "dist-textarea";
    else who = `${t?.tagName || "?"}.${(t && t.className) || ""}`.slice(0, 40);
    logEvt(`[SEL] FOCUSIN ${who} selActive=${termSelActive}`);
  },
  true,
);

// Route pastes through dist's paste() so bracketed-paste mode (DEC 2004)
// is honoured: when the running program enabled it (bash readline, vim,
// tmux…), dist wraps the text in ESC[200~ … ESC[201~ so a multi-line
// paste arrives as ONE chunk instead of being executed line-by-line; when
// it's off, dist sends the raw text. The data flows out via onData →
// socket.send like everything else. preventDefault stops the textarea
// insert, so the trailing `input` event sees an empty value and no-ops.
// Modifiers are intentionally NOT applied — a paste is literal text.
mobileInput.addEventListener("paste", (event) => {
  const text = event.clipboardData?.getData("text") ?? "";
  if (!text || !terminal) return;
  event.preventDefault();
  userFollowBottom = true;
  try {
    terminal.paste(text);
  } catch (err) {
    logEvt(`paste failed ${err?.message || err}`);
  }
  mobileInput.value = "";
  requestMobileBottomScroll();
  scheduleMobileRefocus();
});

mobileInput.addEventListener("input", () => {
  if (isMobileComposing) return;
  if (!mobileInput.value) return;
  sendInput(applyPendingModifiers(mobileInput.value));
  mobileInput.value = "";
  requestMobileBottomScroll();
  scheduleMobileRefocus();
});

// Soft-keyboard delete gestures — a single backspace AND the "swipe the
// delete key = clear N chars" gesture — fire beforeinput with a delete*
// inputType, often with NO keydown event. Our proxy textarea is kept empty,
// so these can't delete anything locally; forward them to the terminal as
// control bytes. Insertions are handled by the input/compositionend handlers
// (they read the textarea value), so we only act on delete* here. This is the
// authoritative delete path — keydown no longer sends Backspace (would double).
mobileInput.addEventListener("beforeinput", (event) => {
  const t = event.inputType || "";
  if (!t.startsWith("delete")) return;
  if (isMobileComposing) return; // composition edits its own pending text
  let seq;
  switch (t) {
    case "deleteWordBackward":
      seq = "\u0017"; // Ctrl+W — delete previous word
      break;
    case "deleteSoftLineBackward":
    case "deleteHardLineBackward":
    case "deleteEntireSoftLine":
      seq = "\u0015"; // Ctrl+U — kill line back to start
      break;
    case "deleteContentForward":
    case "deleteWordForward":
      seq = "\u001b[3~"; // forward Delete
      break;
    default:
      // deleteContentBackward (incl. the swipe-clear burst) → Backspace.
      seq = "\u007f";
      break;
  }
  event.preventDefault();
  sendInput(applyPendingModifiers(seq));
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
    // Backspace is handled in the beforeinput listener (deleteContentBackward)
    // — that path also catches the soft-keyboard "swipe delete key = clear"
    // gesture, which fires beforeinput but NO keydown. Handling it here too
    // would double-send the DEL.
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

// Toolbar / launcher / toggle buttons all live below the terminal
// area. Tapping any of them must NOT steal focus from mobileInput —
// on Android, the input losing focus collapses the soft keyboard, so
// the user's keyboard would close every time they tap an arrow / Tab
// / Ctrl etc to drive a TUI. preventDefault on pointerdown blocks the
// default focus transfer without affecting the subsequent click. The
// listener is delegated on the toolbar container so future
// .mobile-tool additions are covered automatically.
for (const el of [
  mobileToolbar,
  mobileToolbarToggle,
  mobileUploadLauncher,
  mobileKillLine,
]) {
  if (!el) continue;
  el.addEventListener(
    "pointerdown",
    (event) => {
      // If the toolbar happens to wrap a non-button child element
      // (e.g. a label), let it through — only suppress focus
      // transfer for the actual tappable controls.
      if (event.target.closest("button")) event.preventDefault();
    },
    { capture: true },
  );
}

// 清行 pill: one tap sends Ctrl+U to clear the whole input line. Reliable
// replacement for the soft-keyboard long-press/swipe clear (unreliable on our
// always-empty proxy textarea). Keep the keyboard up so the user can keep
// typing right after clearing.
mobileKillLine?.addEventListener("click", () => {
  sendInput("\u0015");
  scrollTerminalToBottom();
  focusTerminal();
});

mobileToolbar.addEventListener("click", (event) => {
  const button = event.target.closest(".mobile-tool");
  if (!button) return;

  // Toolbar taps must NOT raise the soft keyboard. Previously each
  // branch ended with focusTerminal() → mobileInput.focus() →
  // Android pops the IME, which is the opposite of what the user
  // wants when they're tapping arrow / Tab / Ctrl etc to drive a
  // TUI. Modifier toggles, dispatched key events, and the
  // sendInput() raw-sequence path all leave focus untouched —
  // dist's key dispatch + sendInput don't require the helper
  // textarea to be focused (verified via sendToolbarKeyEvent
  // dispatching on terminal.textarea directly).
  const modifier = button.dataset.modifier;
  if (modifier === "ctrl") {
    pendingCtrlModifier = !pendingCtrlModifier;
    syncModifierButtons();
    return;
  }
  if (modifier === "alt") {
    pendingAltModifier = !pendingAltModifier;
    syncModifierButtons();
    return;
  }

  // A pointer press already fired (and possibly auto-repeated) this seq
  // button; swallow the trailing synthesized click so desktop mouse taps
  // (and WebViews that do emit it) don't double-fire.
  if (toolbarRepeatJustFired()) return;
  fireToolbarSeqButton(button);
});

// Wire press-and-hold auto-repeat onto every sequence button. Modifier
// buttons (Ctrl/Alt) are toggles → stay click-only.
for (const repeatButton of mobileToolbar.querySelectorAll("button[data-seq]")) {
  attachToolbarRepeat(repeatButton);
}

// Press-and-hold on Android synthesizes a contextmenu + text-selection
// menu (copy / share). Suppress it for every toolbar button (seq AND
// modifier) — same fix as the session list long-press (main.js
// attachSessionLongPress). CSS user-select:none on .mobile-tool is the
// primary guard; this covers WebViews that still fire contextmenu.
mobileToolbar.addEventListener("contextmenu", (event) => {
  if (event.target.closest(".mobile-tool")) event.preventDefault();
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
  // Canvas may have moved/resized without a grid (cols/rows) change — e.g.
  // rotation or the URL bar collapsing — so the terminal.onResize hook
  // wouldn't fire. Re-pin any active selection's handles to the new layout.
  repositionActiveSelection();
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
