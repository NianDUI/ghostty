// JS-side wrapper for the GhosttyWebUpdate Capacitor plugin. The plugin
// only handles the dirty work (download + sha256 + unzip into filesDir);
// routing/persistence is delegated to Capacitor's built-in WebView
// plugin via setServerBasePath + persistServerBasePath so we don't need
// to reimplement WebViewAssetLoader integration ourselves.
//
// On the browser build (no Capacitor) every export is a stub that
// returns sensible "not available" values so settings UI can stay
// generic across platforms.

import { Capacitor, registerPlugin } from "@capacitor/core";

const NATIVE = Capacitor?.isNativePlatform?.() ?? false;

let _plugin = null;
function plugin() {
  if (!NATIVE) return null;
  if (_plugin) return _plugin;
  _plugin = registerPlugin("GhosttyWebUpdate");
  return _plugin;
}

let _capWebView = null;
async function capWebView() {
  // Capacitor's built-in WebView plugin lives in @capacitor/core; older
  // versions exposed it via a separate import. registerPlugin works for
  // both because the bridge routes by name.
  if (!NATIVE) return null;
  if (_capWebView) return _capWebView;
  _capWebView = registerPlugin("WebView");
  return _capWebView;
}

export function isWebUpdateSupported() {
  return NATIVE;
}

// Read the currently-active web bundle version + sha256 (from the
// .version marker that download() writes last). Empty version means
// we're serving from the APK's bundled assets — either no OTA has
// happened yet, or Capacitor cleared the persisted basePath after an
// APK upgrade (Bridge.isNewBinary clears it automatically). The sha
// lets the caller detect re-deploys that share a version label
// (e.g. dirty builds re-pushed) where label equality alone would miss.
export async function getLocalWebVersion() {
  const p = plugin();
  if (!p) return { version: "", sha256: "", path: "" };
  try {
    const ret = await p.getLocalWebVersion();
    return {
      version: ret?.version ?? "",
      sha256: ret?.sha256 ?? "",
      path: ret?.path ?? "",
    };
  } catch {
    return { version: "", sha256: "", path: "" };
  }
}

// Download + verify + unpack into filesDir/web/<version>/. Returns the
// unpacked path so the caller can hand it to setServerBasePath.
//
// The HTTP fetch deliberately runs in JS (via the WebView's network
// stack) rather than inside the Capacitor plugin. The plugin's previous
// HttpURLConnection implementation hung indefinitely on HarmonyOS
// WebView (ICL-AL20 / Android 12 wv) — likely because Capacitor +
// HarmonyOS use divergent TLS stacks for the WebView vs the OS network
// API, and the self-signed cert NSC pin only consistently applied to
// the WebView side. Doing the HTTP in JS means there's exactly one
// network code path to worry about. The bytes get base64-encoded and
// handed to the plugin for sha verification + extract.
//
// Caller-supplied `onProgress` is called with {phase, ...} so the UI
// can show download / verify / install transitions; phases:
//   "download"  bytes received  -> {received, total}
//   "verify"    base64 + sha     -> {}
//   "install"   plugin unpack    -> {}
export async function downloadWebBundle({ url, sha256, version, token, onProgress }) {
  const p = plugin();
  if (!p) throw new Error("web update not supported on this platform");
  if (!url || !sha256 || !version) throw new Error("url, sha256, version are required");
  if (!token) throw new Error("missing bearer token");

  onProgress?.({ phase: "download", received: 0, total: 0 });
  const response = await fetch(url, {
    method: "GET",
    headers: { Authorization: `Bearer ${token}` },
    credentials: "omit",
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  const buffer = await response.arrayBuffer();
  onProgress?.({ phase: "download", received: buffer.byteLength, total: buffer.byteLength });

  onProgress?.({ phase: "verify" });
  const base64 = await arrayBufferToBase64(buffer);

  onProgress?.({ phase: "install" });
  return p.installFromBase64({ data: base64, sha256, version });
}

// Convert ArrayBuffer to base64 string. Uses FileReader.readAsDataURL
// because the browser's native base64 encoder is faster than a JS loop
// of fromCharCode + btoa for buffers > a few KB, and avoids the
// argument-count limit of String.fromCharCode.apply.
function arrayBufferToBase64(buffer) {
  return new Promise((resolve, reject) => {
    const blob = new Blob([buffer]);
    const reader = new FileReader();
    reader.onload = () => {
      const dataUrl = reader.result;
      const comma = typeof dataUrl === "string" ? dataUrl.indexOf(",") : -1;
      if (comma < 0) {
        reject(new Error("base64 encode failed"));
        return;
      }
      resolve(dataUrl.slice(comma + 1));
    };
    reader.onerror = () => reject(reader.error || new Error("base64 encode failed"));
    reader.readAsDataURL(blob);
  });
}

// Switch the WebView to the freshly downloaded bundle. setServerBasePath
// updates the local server's basePath AND posts a webView.loadUrl on the
// main thread to refresh the page. persistServerBasePath writes the path
// to SharedPreferences so Bridge.attachWebView picks it up on next launch.
//
// We always force a window.location.reload() ourselves afterwards
// because the Capacitor-internal `webView.post(loadUrl)` doesn't fire
// reliably on HarmonyOS WebView (observed on ICL-AL20 / Android 12 wv) —
// the call resolves but the page stays put, leaving the user stuck on a
// "安装中..." spinner. JS-level reload is belt-and-braces; at worst the
// page reloads twice in rapid succession, which is harmless.
export async function activateWebBundle(path) {
  const wv = await capWebView();
  if (!wv) throw new Error("WebView plugin not available");
  await wv.setServerBasePath({ path });
  await wv.persistServerBasePath();
  try {
    // location.replace (not assign) so the navigation stack doesn't
    // accumulate; a back-button after activation should land on whatever
    // launcher state the new bundle paints, not on an "installing"
    // intermediate.
    window.location.replace("https://localhost/");
  } catch {
    // Last resort: reload current URL.
    try { window.location.reload(); } catch { /* give up */ }
  }
}

// Revert to the APK's bundled assets. Empty path → Capacitor reverts
// localServer to hostAssets("public") on the next load. Same reload
// caveat as activateWebBundle — fire our own window.location.replace
// because the Capacitor internal one doesn't always fire.
export async function resetToBundled() {
  const wv = await capWebView();
  if (!wv) throw new Error("WebView plugin not available");
  await wv.setServerBasePath({ path: "" });
  await wv.persistServerBasePath();
  try {
    window.location.replace("https://localhost/");
  } catch {
    try { window.location.reload(); } catch { /* give up */ }
  }
}

// Drop all cached bundles except the currently-active one. Safe to call
// after a successful activate — Capacitor has already loaded into the
// new basePath, the old dirs are dead weight.
export async function clearOldBundles(keepVersion) {
  const p = plugin();
  if (!p) return { removed: 0 };
  try {
    return await p.clearCache({ keepVersion: keepVersion ?? "" });
  } catch {
    return { removed: 0 };
  }
}
