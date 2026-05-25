// Browser → relay file upload. The flow is:
//   1. POST /api/upload/init  →  { upload_id, upload_url }
//   2. PUT  <upload_url>      (raw body, single shot for MVP)
//   3. listen on the existing /ws/client socket for upload_ack frames
//      coming back from the Mac agent, which is where we learn the
//      final on-disk path that just got injected at the cursor.
//
// The relay protocol contract lives at docs/plan/web-upload.md — this
// module's job is to translate that contract into a small reactive UI
// (button + toasts) and a pending-uploads map keyed by upload_id.

/** @typedef {Object} UploadManagerDeps
 *  @property {string} backendBase  Relay base URL ("http://host:port").
 *  @property {string} userToken    Bearer token used by /api/upload/init.
 *  @property {() => string|null} getActiveSessionId
 *  @property {(payload: object) => void} onToast  Show a toast describing the upload.
 *  @property {(line: string) => void} [logEvt]  Optional debug logger.
 *  @property {typeof window.fetch} [fetchImpl]  Injectable for tests.
 *  @property {(req: { url: string, body: Blob, headers: Record<string,string>,
 *                     onProgress: (loaded: number, total: number) => void
 *           }) => Promise<{status: number, body: string}>}
 *           [putImpl]  Injectable PUT with progress (default uses XHR).
 */

/** Upper bound on filenames we send to the relay (the relay enforces a
 *  matching cap server-side; mismatched limits would surface as 400s). */
const UPLOAD_NAME_MAX = 200;

/** Files larger than this skip the WebCrypto sha256 step — hashing a
 *  500 MB blob on the main thread freezes the tab for noticeable seconds.
 *  The agent treats sha256:null as "skip verification" (see web-upload.md
 *  §8 decision log). */
const SHA256_SKIP_BYTES = 50 * 1024 * 1024;

/** Default fallback chunk size if the relay's `init` response omits one
 *  (older relays predate the chunked PATCH path). 5 MiB matches the
 *  server's `DEFAULT_UPLOAD_PATCH_CHUNK_BYTES`. */
const DEFAULT_PATCH_CHUNK_BYTES = 5 * 1024 * 1024;

/** Hard ceiling on a single PATCH chunk, matching the relay's
 *  `DEFAULT_UPLOAD_PATCH_MAX_BYTES`. We never send more than this even if
 *  the file is much larger. */
const PATCH_HARD_MAX_BYTES = 16 * 1024 * 1024;

/** Files at or below this size keep using the single-shot PUT path —
 *  the chunked PATCH path adds a per-chunk round-trip that isn't worth
 *  it for small files. Tweaked to match the relay's recommended chunk. */
const CHUNKED_UPLOAD_THRESHOLD_BYTES = DEFAULT_PATCH_CHUNK_BYTES;

/** Per-chunk retry budget. The relay returns 409 with an
 *  `Upload-Offset` header when the client and server disagree on offset;
 *  one cheap retry covers that and an occasional transient 5xx. */
const PATCH_CHUNK_RETRY_LIMIT = 1;

export function isUploadAckFrame(frame) {
  return frame && typeof frame === "object" && frame.type === "upload_ack";
}

export function sanitizeFilenameForUpload(name) {
  if (typeof name !== "string") return null;
  const trimmed = name.trim();
  if (!trimmed) return null;
  if (trimmed === "." || trimmed === "..") return null;
  if (trimmed.startsWith(".")) return null;
  if (new TextEncoder().encode(trimmed).length > UPLOAD_NAME_MAX) return null;
  for (const codeUnit of trimmed) {
    const code = codeUnit.charCodeAt(0);
    if (code < 0x20 || code === 0x7f) return null;
    if (codeUnit === "/" || codeUnit === "\\") return null;
  }
  return trimmed;
}

async function defaultSha256Hex(blob) {
  if (typeof crypto?.subtle?.digest !== "function") return null;
  const buf = await blob.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", buf);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function defaultPutWithProgress({ url, body, headers, onProgress }) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", url, true);
    for (const [key, value] of Object.entries(headers)) {
      xhr.setRequestHeader(key, value);
    }
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        onProgress(event.loaded, event.total);
      }
    };
    xhr.onload = () =>
      resolve({ status: xhr.status, body: xhr.responseText || "" });
    xhr.onerror = () => reject(new Error("network_error"));
    xhr.onabort = () => reject(new Error("aborted"));
    xhr.send(body);
  });
}

/** Single PATCH chunk with per-chunk progress reporting. Resolves with
 *  the server's response headers so callers can read `Upload-Offset`.
 *  The body is a Blob slice, never a whole file. */
function defaultPatchWithProgress({ url, body, offset, headers, onProgress }) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PATCH", url, true);
    xhr.setRequestHeader("Content-Type", "application/offset+octet-stream");
    xhr.setRequestHeader("Upload-Offset", String(offset));
    for (const [key, value] of Object.entries(headers)) {
      xhr.setRequestHeader(key, value);
    }
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        onProgress(event.loaded, event.total);
      }
    };
    xhr.onload = () => {
      const headerLines = (xhr.getAllResponseHeaders() || "").split("\r\n");
      const respHeaders = {};
      for (const line of headerLines) {
        const idx = line.indexOf(":");
        if (idx > 0) {
          respHeaders[line.slice(0, idx).trim().toLowerCase()] =
            line.slice(idx + 1).trim();
        }
      }
      resolve({
        status: xhr.status,
        body: xhr.responseText || "",
        headers: respHeaders,
      });
    };
    xhr.onerror = () => reject(new Error("network_error"));
    xhr.onabort = () => reject(new Error("aborted"));
    xhr.send(body);
  });
}

/**
 * Build an upload manager. The manager is stateful per-page-load: it
 * tracks pending uploads keyed by upload_id so incoming upload_ack
 * frames can be correlated back to the toast they were spawned from.
 */
export function createUploadManager(deps) {
  const fetchImpl = deps.fetchImpl ?? window.fetch.bind(window);
  const putImpl = deps.putImpl ?? defaultPutWithProgress;
  const patchImpl = deps.patchImpl ?? defaultPatchWithProgress;
  const log = deps.logEvt ?? (() => {});
  // upload_id -> internal handle (set by start, drained by ack).
  const pending = new Map();

  async function start(file, options = {}) {
    const sessionId = deps.getActiveSessionId();
    if (!sessionId) {
      deps.onToast({
        kind: "error",
        title: file.name,
        message: "尚未选择会话",
      });
      return;
    }
    const name = sanitizeFilenameForUpload(file.name);
    if (!name) {
      deps.onToast({
        kind: "error",
        title: file.name,
        message: "文件名不合法",
      });
      return;
    }
    // Caller may pass an existing toastId so a queued "等待重新连接..."
    // toast morphs into "准备上传..." in place instead of stacking.
    const toastId = options.toastId ?? `pending-${cryptoRandomId()}`;
    deps.onToast({
      id: toastId,
      kind: "pending",
      title: name,
      message: "准备上传...",
      progress: 0,
    });

    let sha256 = null;
    try {
      if (file.size <= SHA256_SKIP_BYTES) {
        sha256 = await defaultSha256Hex(file);
      }
    } catch (err) {
      log(`upload sha256 failed: ${err}`);
      sha256 = null;
    }

    let initResponse;
    try {
      const res = await fetchImpl(`${deps.backendBase}/api/upload/init`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${deps.userToken}`,
        },
        body: JSON.stringify({
          session_id: sessionId,
          name,
          size: file.size,
          sha256,
        }),
      });
      const text = await res.text();
      if (res.status === 401) {
        // Session likely expired on the relay; let the caller decide
        // whether to bounce the WebSocket + re-queue, instead of
        // surfacing a confusing "未授权" toast that the user can't act
        // on. The pending toast stays as-is so the caller can morph it.
        const unauthorized = new Error("upload_init_unauthorized");
        unauthorized.code = "unauthorized";
        unauthorized.toastId = toastId;
        unauthorized.name = name;
        throw unauthorized;
      }
      if (!res.ok) {
        deps.onToast({
          id: toastId,
          kind: "error",
          title: name,
          message: readableInitError(res.status, text),
        });
        return;
      }
      initResponse = JSON.parse(text);
    } catch (err) {
      if (err && err.code === "unauthorized") {
        // Re-throw so the caller's retry/reconnect logic runs. The pending
        // toast is intentionally left in place — the caller flips it back
        // to "等待重新连接..." or to a final error once it gives up.
        throw err;
      }
      log(`upload init network error: ${err}`);
      deps.onToast({
        id: toastId,
        kind: "error",
        title: name,
        message: "网络错误",
      });
      return;
    }

    const uploadId = initResponse.upload_id;
    pending.set(uploadId, { toastId, name });

    deps.onToast({
      id: toastId,
      kind: "pending",
      title: name,
      message: "上传中...",
      progress: 0,
    });

    const uploadURL = `${deps.backendBase}${initResponse.upload_url}`;
    const useChunked = file.size > CHUNKED_UPLOAD_THRESHOLD_BYTES;

    try {
      if (useChunked) {
        const chunkBytes = clampChunkSize(initResponse.chunk_size);
        await uploadViaPatch({
          uploadURL,
          file,
          chunkBytes,
          token: deps.userToken,
          patchImpl,
          onProgress: (sent) => {
            deps.onToast({
              id: toastId,
              kind: "pending",
              title: name,
              message: `上传中 ${formatBytes(sent)} / ${formatBytes(file.size)}`,
              progress: file.size > 0 ? sent / file.size : 0,
            });
          },
        });
      } else {
        const putResult = await putImpl({
          url: uploadURL,
          body: file,
          headers: {
            Authorization: `Bearer ${deps.userToken}`,
            "Content-Type": "application/octet-stream",
          },
          onProgress: (loaded, total) => {
            deps.onToast({
              id: toastId,
              kind: "pending",
              title: name,
              message: `上传中 ${formatBytes(loaded)} / ${formatBytes(total)}`,
              progress: total > 0 ? loaded / total : 0,
            });
          },
        });
        if (putResult.status < 200 || putResult.status >= 300) {
          pending.delete(uploadId);
          deps.onToast({
            id: toastId,
            kind: "error",
            title: name,
            message: readablePutError(putResult.status, putResult.body),
          });
          return;
        }
      }
    } catch (err) {
      pending.delete(uploadId);
      log(`upload PUT/PATCH error: ${err?.message ?? err}`);
      if (err && err.code === "server_rejected") {
        deps.onToast({
          id: toastId,
          kind: "error",
          title: name,
          message: readablePutError(err.status, err.body),
        });
      } else {
        deps.onToast({
          id: toastId,
          kind: "error",
          title: name,
          message: "上传中断",
        });
      }
      return;
    }

    deps.onToast({
      id: toastId,
      kind: "pending",
      title: name,
      message: "等待 Mac 确认...",
      progress: 1,
    });
    // Final outcome (success or rejection) lands via handleAckFrame.
  }

  async function uploadViaPatch({
    uploadURL, file, chunkBytes, token, patchImpl, onProgress,
  }) {
    let offset = 0;
    const total = file.size;
    while (offset < total) {
      const end = Math.min(offset + chunkBytes, total);
      const slice = file.slice(offset, end);
      const sliceSize = end - offset;
      let lastError;
      let succeeded = false;
      for (let attempt = 0; attempt <= PATCH_CHUNK_RETRY_LIMIT; attempt++) {
        try {
          const result = await patchImpl({
            url: uploadURL,
            body: slice,
            offset,
            headers: { Authorization: `Bearer ${token}` },
            onProgress: (loaded) => onProgress(offset + loaded),
          });
          if (result.status >= 200 && result.status < 300) {
            const reported = parseInt(
              result.headers["upload-offset"] ?? `${offset + sliceSize}`, 10);
            // Honour what the server tells us: if it persisted less
            // than we sent, the next iteration resumes from there
            // instead of overshooting.
            offset = Number.isFinite(reported)
              ? Math.max(offset, reported)
              : offset + sliceSize;
            succeeded = true;
            break;
          }
          if (result.status === 409 && result.headers["upload-offset"]) {
            // Server says we're out of sync. Adopt its offset and retry.
            const reported = parseInt(result.headers["upload-offset"], 10);
            if (Number.isFinite(reported) && reported !== offset) {
              offset = reported;
              continue;
            }
          }
          const err = new Error("chunk_rejected");
          err.code = "server_rejected";
          err.status = result.status;
          err.body = result.body;
          throw err;
        } catch (err) {
          lastError = err;
          if (err && err.code === "server_rejected") {
            throw err;
          }
          // Network/abort: retry once.
        }
      }
      if (!succeeded) {
        throw lastError ?? new Error("chunk_failed");
      }
    }
  }

  function handleAckFrame(frame) {
    if (!isUploadAckFrame(frame)) return false;
    const handle = pending.get(frame.upload_id);
    if (!handle) {
      // Could be a late ack after navigation; silently ignore.
      log(`upload ack for unknown upload_id=${frame.upload_id}`);
      return true;
    }
    pending.delete(frame.upload_id);
    if (frame.ok) {
      deps.onToast({
        id: handle.toastId,
        kind: "success",
        title: handle.name,
        message: `已注入路径: ${frame.path ?? "?"}`,
      });
    } else {
      deps.onToast({
        id: handle.toastId,
        kind: "error",
        title: handle.name,
        message: readableAckRejection(frame.reason),
      });
    }
    return true;
  }

  return { start, handleAckFrame };
}

function readableInitError(status, text) {
  try {
    const parsed = JSON.parse(text);
    if (parsed?.error) return labelForServerError(parsed.error, status);
  } catch {}
  return status === 401 ? "未授权" : `服务器拒绝 (${status})`;
}

function readablePutError(status, text) {
  try {
    const parsed = JSON.parse(text);
    if (parsed?.error) return labelForServerError(parsed.error, status);
  } catch {}
  return `上传失败 (${status})`;
}

function readableAckRejection(reason) {
  switch (reason) {
    case "agent_disabled":
      return "Mac 端已禁用上传";
    case "size_exceeds_file_limit":
      return "超过单文件大小限制";
    case "size_exceeds_session_limit":
      return "超过会话总量限制";
    case "sanitize_failed":
      return "文件名被拒绝";
    case "pull_failed":
      return "Mac 端拉取失败";
    case "hash_mismatch":
      return "文件校验失败";
    case "disk_full":
      return "Mac 磁盘空间不足";
    case "write_failed":
      return "Mac 端写入失败";
    default:
      return reason ? `Mac 端拒绝: ${reason}` : "Mac 端拒绝";
  }
}

function labelForServerError(code, status) {
  switch (code) {
    case "invalid_size":
      return "文件大小无效";
    case "size_exceeds_limit":
      return "超过单文件大小限制";
    case "size_exceeds_session_limit":
      return "超过会话总量限制";
    case "session_not_found":
      return "会话不存在";
    case "too_many_pending":
      return "并发上传过多";
    case "size_mismatch":
      return "上传字节数不匹配";
    case "hash_mismatch":
      return "校验和不匹配";
    case "invalid_sha256":
      return "sha256 格式错误";
    case "invalid_payload":
    case "invalid json":
      return "请求无效";
    default:
      return `服务器拒绝 (${status}): ${code}`;
  }
}

function clampChunkSize(serverHint) {
  if (
    typeof serverHint !== "number"
    || !Number.isFinite(serverHint)
    || serverHint <= 0
  ) {
    return DEFAULT_PATCH_CHUNK_BYTES;
  }
  return Math.min(Math.max(serverHint, 64 * 1024), PATCH_HARD_MAX_BYTES);
}

function formatBytes(n) {
  if (!Number.isFinite(n) || n < 0) return "?";
  const units = ["B", "KB", "MB", "GB"];
  let i = 0;
  let value = n;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return `${value.toFixed(value < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

function cryptoRandomId() {
  if (typeof crypto?.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return Math.random().toString(36).slice(2);
}
