// JS-side wrapper for the ApkInstaller Capacitor plugin. The plugin only
// stages bytes to cacheDir + launches the system installer; the download
// itself runs here in JS (the WebView network stack) because a plugin-side
// HttpURLConnection hangs on HarmonyOS WebView under our self-signed cert
// (same reason web-update.js downloads in JS — see its notes). The APK is
// handed to the plugin in chunks because passing a multi-MB base64 string
// through Capacitor's WebMessageListener hangs on the same WebView (it
// drops messages beyond ~64 KB).
//
// On the browser build (no Capacitor) isApkInstallSupported() is false and
// callers fall back to the grant-flow browser download.

import { Capacitor, registerPlugin } from "@capacitor/core";

const NATIVE = Capacitor?.isNativePlatform?.() ?? false;

let _plugin = null;
function plugin() {
  if (!NATIVE) return null;
  if (_plugin) return _plugin;
  _plugin = registerPlugin("ApkInstaller");
  return _plugin;
}

// Rejected by the plugin when the user hasn't granted "install unknown
// apps". The plugin opens the system settings page; callers should show a
// hint and let the user retry after granting.
export const APK_NEED_INSTALL_PERMISSION = "NEED_INSTALL_PERMISSION";

// 32 KB binary ≈ 43 KB base64, comfortably under HarmonyOS WebView's
// ~64 KB WebMessageListener payload ceiling (matches web-update.js).
const CHUNK_BYTES = 32_768;

export function isApkInstallSupported() {
  if (!NATIVE) return false;
  // Older APKs that OTA'd to this web bundle may not ship the plugin yet —
  // fall back to grant-flow there.
  return Capacitor?.isPluginAvailable?.("ApkInstaller") ?? false;
}

// Download the APK via fetch (WebView network stack) and stream it to the
// plugin in <= CHUNK_BYTES base64 slices, then launch the system installer.
// `onProgress` is called with { received, total } (total = 0 when the
// server sends no Content-Length). Throws Error whose message contains
// APK_NEED_INSTALL_PERMISSION when install permission is missing.
export async function downloadAndInstallApk({ url, token, onProgress }) {
  const p = plugin();
  if (!p) throw new Error("apk install not supported on this platform");
  if (!url) throw new Error("url required");
  if (!token) throw new Error("missing bearer token");

  // Check + request install permission BEFORE downloading tens of MB.
  // Rejects (and opens settings) with NEED_INSTALL_PERMISSION if missing.
  await p.ensureInstallPermission();

  const response = await fetch(url, {
    method: "GET",
    headers: { Authorization: `Bearer ${token}` },
    credentials: "omit",
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  const total = Number(response.headers.get("Content-Length")) || 0;
  onProgress?.({ received: 0, total });

  await p.installBegin();
  try {
    if (response.body && typeof response.body.getReader === "function") {
      // Streaming: keeps a multi-MB APK out of the JS heap and gives a
      // real download progress. Re-slice each network chunk to CHUNK_BYTES
      // (network chunks can exceed the bridge payload ceiling).
      await streamToPlugin(p, response.body.getReader(), total, onProgress);
    } else {
      // Fallback for WebViews without ReadableStream body support.
      const bytes = new Uint8Array(await response.arrayBuffer());
      await feedBytes(p, bytes, bytes.length, onProgress);
    }
    await p.installFinalize();
  } catch (err) {
    try {
      await p.installAbort();
    } catch {
      // best effort
    }
    throw err;
  }
}

async function streamToPlugin(p, reader, total, onProgress) {
  let received = 0;
  let carry = new Uint8Array(0);
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.length;
    let buf = value;
    if (carry.length) {
      const merged = new Uint8Array(carry.length + value.length);
      merged.set(carry, 0);
      merged.set(value, carry.length);
      buf = merged;
      carry = new Uint8Array(0);
    }
    let offset = 0;
    while (buf.length - offset >= CHUNK_BYTES) {
      await p.installChunk({
        chunk: await bytesSliceToBase64(buf, offset, offset + CHUNK_BYTES),
      });
      offset += CHUNK_BYTES;
    }
    if (offset < buf.length) {
      carry = buf.slice(offset);
    }
    onProgress?.({ received, total: total || received });
  }
  if (carry.length) {
    await p.installChunk({
      chunk: await bytesSliceToBase64(carry, 0, carry.length),
    });
  }
}

async function feedBytes(p, bytes, total, onProgress) {
  for (let offset = 0; offset < bytes.length; offset += CHUNK_BYTES) {
    const end = Math.min(offset + CHUNK_BYTES, bytes.length);
    await p.installChunk({ chunk: await bytesSliceToBase64(bytes, offset, end) });
    onProgress?.({ received: end, total: total || bytes.length });
  }
}

// Convert a slice of a Uint8Array to base64 via FileReader's native
// data-URL encoder (btoa(String.fromCharCode(...)) blows the call stack on
// large slices). Mirrors web-update.js.
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
    reader.onerror = () => reject(reader.error ?? new Error("FileReader failed"));
    reader.readAsDataURL(blob);
  });
}
