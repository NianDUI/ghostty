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

// Note: we used to also depend on Capacitor's built-in WebView plugin
// (setServerBasePath + persistServerBasePath), but on HarmonyOS WebView
// chaining those three plugin calls hung the JS bridge. Our own
// GhosttyWebUpdate.activate folds persist + setServerBasePath + reload
// into a single UI-thread Runnable so JS only awaits one call.

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
// Two architectural reasons the heavy lifting is in JS:
//
// 1. HTTP fetch lives in JS (WebView network stack) because the plugin's
//    earlier HttpURLConnection hung indefinitely on HarmonyOS WebView
//    (ICL-AL20 / Android 12 wv) — likely divergent TLS stacks where the
//    self-signed cert NSC pin only consistently applied to the WebView
//    side. With JS fetch there's exactly one network path to worry about.
//
// 2. The bundle is handed to the plugin chunked rather than as one big
//    base64 string because passing ~290 KB through Capacitor's
//    WebMessageListener hangs the install call on the same WebView. We
//    suspect HarmonyOS drops messages beyond ~64 KB. CHUNK_BYTES=32_768
//    decoded (~43 KB base64) is comfortably under that cliff.
//
// Caller-supplied `onProgress` is called with {phase, ...} so the UI
// can show download / verify / install transitions; phases:
//   "download"  bytes received   -> {received, total}
//   "verify"    base64 produced  -> {}
//   "install"   chunked transfer -> {sent, total}
const CHUNK_BYTES = 32_768;

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
  const total = buffer.byteLength;
  onProgress?.({ phase: "download", received: total, total });

  onProgress?.({ phase: "verify" });
  // Per-chunk base64-encode keeps peak memory bounded and avoids
  // building a single ~290 KB string only to slice it back into chunks.
  const bytes = new Uint8Array(buffer);

  await p.installBegin({ version });
  try {
    let sent = 0;
    for (let offset = 0; offset < bytes.length; offset += CHUNK_BYTES) {
      const end = Math.min(offset + CHUNK_BYTES, bytes.length);
      const chunkBase64 = await bytesSliceToBase64(bytes, offset, end);
      await p.installChunk({ version, chunk: chunkBase64 });
      sent = end;
      onProgress?.({ phase: "install", sent, total });
    }
    return await p.installFinalize({ version, sha256 });
  } catch (err) {
    try { await p.installAbort({ version }); } catch { /* best effort */ }
    throw err;
  }
}

// Convert a slice of Uint8Array to base64 string via FileReader. Used
// per-chunk because btoa(String.fromCharCode(...arr)) blows the call
// stack on large slices and a plain for-loop is slower than the
// browser's native data-URL encoder.
function bytesSliceToBase64(bytes, start, end) {
  return new Promise((resolve, reject) => {
    const blob = new Blob([bytes.subarray(start, end)]);
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

// Switch the WebView to the freshly downloaded bundle. Single plugin
// call by design (see plugin's activate() doc for the HarmonyOS
// rationale). The plugin resolves immediately and then triggers
// reload from a UI-thread Runnable, so this await returns *before*
// the page actually navigates — caller should treat the return as
// "reload pending" rather than "reload done".
export async function activateWebBundle(path) {
  const p = plugin();
  if (!p) throw new Error("web update not supported on this platform");
  await p.activate({ path });
}

// Revert to the APK's bundled assets — empty path tells the plugin to
// clear the persisted basePath, which makes Capacitor fall back to
// hostAssets("public") on the next attach.
export async function resetToBundled() {
  const p = plugin();
  if (!p) throw new Error("web update not supported on this platform");
  await p.activate({ path: "" });
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
