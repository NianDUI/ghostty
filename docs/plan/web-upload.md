# Web → Mac File Upload (Session Sharing)

This document is the **canonical contract** for the file-upload feature in
session sharing. Three components implement against it independently:

- `contrib/session-sharing/relay/server.py` — Python relay
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` — Mac agent
- `contrib/session-sharing/ghostty-web-client/` — browser client

If implementation deviates from this doc, update the doc in the same PR.

## 1. Goal

The user is sitting in a browser tab connected to a `session-sharing` relay.
The agent is the user's own Mac running Ghostty. Goal: pick / paste / drag
a local file in the browser, have it land on the Mac filesystem, and have
the absolute path appear at the terminal cursor (no `Enter`, no command
template — see decision log).

## 2. Threat Model

A holder of a valid `/ws/client` session token already has full keystroke
write access to the pty — i.e. arbitrary remote command execution. Adding
file upload does **not** widen the attack surface meaningfully. Therefore:

- No per-upload Mac-side confirmation prompt (impossible while the user
  is remote anyway).
- Authorization is granted **once** when the session is shared from Mac.
- Defense is concentrated on: (a) session token strength + TLS,
  (b) drop-zone containment, (c) shell-escape on injection, (d) audit log.

## 3. Topology

```
browser ──HTTPS──> relay
   1. POST /api/upload/init   →  { upload_id, upload_url }
   2. PUT  <upload_url>       (raw body, single shot for MVP)

relay ──/ws/agent control frame──> Mac agent
   3. { type:"upload_ready", upload_id, name, size, sha256, pull_token }

Mac agent ──HTTPS──> relay
   4. GET /api/upload/<id>/pull?token=<pull_token>
   5. write to <upload_dir>/<sanitized-name>
   6. shell-escape path → surfaceModel.sendText(path)
   7. agent emits {type:"upload_ack", upload_id, ok, path, reason?}
      via /ws/agent. Relay forwards as text frame to all session clients.
```

`upload_dir` defaults to
`~/Library/Application Support/com.mitchellh.ghostty/uploads/<session_id>/`.

## 4. HTTP API (relay)

All endpoints require `Authorization: Bearer <user_token>` matching the
session owner — same auth as `/api/sessions`. Rate-limited by the existing
relay limiter.

### 4.1 `POST /api/upload/init`

Request body (JSON):

```json
{
  "session_id": "abc...",
  "name": "screenshot.png",
  "size": 1048576,
  "sha256": "hexdigest"
}
```

Response (200):

```json
{
  "upload_id": "01HXYZ...",
  "upload_url": "/api/upload/01HXYZ...",
  "expires_at": 1736870400,
  "chunk_size": 5242880,
  "patch_max_bytes": 16777216
}
```

`chunk_size` is the relay's recommended PATCH chunk size (5 MiB by
default); clients should not exceed `patch_max_bytes`. A client that
predates this contract can ignore both fields and PUT the whole file.

Rejections (400/413/429/404):

- `400 invalid_size` — size missing / not positive / over per-file limit.
- `404 session_not_found` — session_id unknown or owned by a different token.
- `413 size_exceeds_limit` — `size > GHOSTTY_RELAY_UPLOAD_MAX_BYTES`.
- `429 too_many_pending` — too many in-flight uploads for this session.

### 4.2 `PUT /api/upload/<upload_id>` (single-shot, small files)

Streams raw bytes for a one-shot upload. Required headers:

- `Content-Length: <bytes>` (must match the `size` from init)
- `Authorization: Bearer <user_token>`
- `Content-Type: application/octet-stream` (recommended)

Response (200):

```json
{ "upload_id": "01HXYZ...", "received": 1048576, "sha256": "hex" }
```

Side effect on success: relay pushes `upload_ready` control frame to the
session's `agent_writer`. If the agent is offline at this moment the upload
is held and pushed on next agent connect within TTL.

Rejections:

- `404 not_found` — upload_id unknown or already consumed.
- `409 size_mismatch` — Content-Length disagrees with init size.
- `413 size_exceeds_limit`
- `422 hash_mismatch` — sha256 of body ≠ init sha256.

### 4.2b `PATCH /api/upload/<upload_id>` (resumable, recommended for >5 MiB)

A deliberately small subset of [tus 1.0.0](https://tus.io/). Each PATCH
appends a single chunk. Required headers:

- `Authorization: Bearer <user_token>`
- `Content-Type: application/offset+octet-stream`
- `Content-Length: <bytes-in-this-chunk>` (positive, ≤ `patch_max_bytes`)
- `Upload-Offset: <bytes-already-on-server>`

Response while more chunks remain (`upload.size > offset + chunk`):

```
HTTP/1.1 204 No Content
Upload-Offset: <new-offset>
Cache-Control: no-store
```

Response on the final chunk (server has now received the full file):

```
HTTP/1.1 200 OK
Upload-Offset: <upload.size>
Content-Type: application/json
{ "upload_id": "...", "received": <upload.size>, "sha256": "hex" }
```

Side effect on the final chunk: same as PUT — the relay pushes
`upload_ready` to the session's `agent_writer`.

Rejections:

- `400 invalid_upload_offset` / `400 invalid_content_length` / `400 empty_chunk`
- `409 offset_mismatch` — client offset ≠ server offset; the response
  includes `Upload-Offset: <server-offset>` so the client can resync.
- `409 concurrent_patch` — another PATCH for the same upload_id is in
  flight; a real client serialises PATCHes per upload.
- `409 already_delivered` — agent already pulled the bytes.
- `413 chunk_too_large` — `Content-Length > patch_max_bytes`.
- `413 overshoot` — chunk would push `received` past `upload.size`.
- `415 invalid_content_type` — `Content-Type` is set but isn't
  `application/offset+octet-stream`.
- `422 hash_mismatch` — last-chunk only; observed sha ≠ init sha.

### 4.2c `HEAD /api/upload/<upload_id>` (resume probe)

Reports how many bytes the relay actually persisted, used by a client
that lost its connection mid-PATCH and wants to confirm the resume offset
before sending the next chunk.

Required headers:
- `Authorization: Bearer <user_token>`

Response (200):

```
HTTP/1.1 200 OK
Upload-Offset: <bytes-received-so-far>
Upload-Length: <upload.size>
Cache-Control: no-store
```

Rejections: `404 not_found`, `401 invalid user token`.

### 4.3 `GET /api/upload/<upload_id>/pull?token=<pull_token>`

Agent-only endpoint. Single-use: pull_token is invalidated on first 200.

Response: raw file bytes, `Content-Type: application/octet-stream`,
`Content-Length` set, `X-Ghostty-Upload-Name: <utf-8 name>`,
`X-Ghostty-Upload-SHA256: <hex>`.

After successful pull (response fully drained), relay removes the temp
file from disk and clears state.

Rejections: `403 invalid_token`, `404 not_found`, `410 gone` (after pull).

### 4.4 Limits & TTL

| Env var | Default | Meaning |
|---|---|---|
| `GHOSTTY_RELAY_UPLOAD_MAX_BYTES` | `100*1024*1024` (100 MiB) | Per-file cap. |
| `GHOSTTY_RELAY_UPLOAD_SESSION_MAX_BYTES` | `2*1024*1024*1024` (2 GiB) | Cumulative cap per session. |
| `GHOSTTY_RELAY_UPLOAD_MAX_PENDING` | `4` | Concurrent uploads / session. |
| `GHOSTTY_RELAY_UPLOAD_TTL` | `600.0` | Seconds an upload waits for pull. |
| `GHOSTTY_RELAY_UPLOAD_DIR` | `<tmpdir>/ghostty-uploads` | Temp landing dir. |

Cleanup loop sweeps expired uploads on the same cadence as session GC.

## 5. WebSocket Control Frames

All control frames are JSON text frames (opcode 0x1). Frames whose `type`
is in the table below are intercepted; anything else falls through to the
existing terminal-byte path (per
`SessionSharingInboundFrameAction.parse`).

### 5.1 relay → agent (over `/ws/agent`)

```json
{
  "type": "upload_ready",
  "upload_id": "01HXYZ...",
  "name": "screenshot.png",
  "size": 1048576,
  "sha256": "hex",
  "pull_token": "opaque-bytes",
  "pull_url": "/api/upload/01HXYZ.../pull"
}
```

The agent acknowledges receipt by pulling the bytes; there is no explicit
ACK frame from agent for the `upload_ready` envelope itself.

### 5.2 agent → relay → all clients (over `/ws/agent`, forwarded)

```json
{
  "type": "upload_ack",
  "upload_id": "01HXYZ...",
  "ok": true,
  "path": "/Users/me/Library/Application Support/com.mitchellh.ghostty/uploads/abc/screenshot.png",
  "bytes_written": 1048576
}
```

Or on failure:

```json
{
  "type": "upload_ack",
  "upload_id": "01HXYZ...",
  "ok": false,
  "reason": "size_exceeds_session_limit" | "disk_full" | "hash_mismatch" | "pull_failed" | "sanitize_failed" | "agent_disabled"
}
```

The relay treats `upload_ack` like any other text frame from the agent
(forwarded to all clients in the session).

### 5.3 Client → agent (no new frame)

Browser side does **not** send control frames to start an upload. The
upload is driven entirely by the HTTP API; the WS path only carries the
`upload_ack` echoed back from the agent.

## 6. Mac Agent Behavior

1. On `upload_ready`:
   - Validate `name` (must not contain `/`, `\0`, leading `.`, control
     chars; trimmed to 200 bytes; collision → suffix `-1`, `-2`, ...).
   - Validate cumulative session bytes against the agent-side policy
     (mirrors relay limits as defense in depth).
   - HTTP `GET <relay>/api/upload/<id>/pull?token=...`.
   - Stream to a `.partial` temp file in `upload_dir`, rename on success.
   - Verify sha256 against advertised value; on mismatch, delete and
     emit `upload_ack ok:false reason:"hash_mismatch"`.
   - Compute shell-escaped POSIX absolute path:
     - Wrap in single quotes, replace `'` with `'\''`.
     - Append a trailing space so the cursor sits past the path.
   - Call `surfaceModel.sendText(quotedPath + " ")`.
   - Append one line to `~/Library/Logs/ghostty/uploads.log` (JSON).
   - Emit `upload_ack` over the existing agent WS.

2. Policy controls (per-session, derived from the share-sheet decision):
   - `uploadsEnabled: Bool` — default `false`. If false, agent replies
     `upload_ack ok:false reason:"agent_disabled"` and does not pull.
   - `maxFileBytes`, `maxSessionBytes` — agent-enforced caps.
   - Emergency stop: setting `uploadsEnabled = false` mid-session causes
     any pending `upload_ready` to be rejected.

3. Cleanup: on session stop, leave files in place (user data) but clear
   the in-memory cumulative-bytes counter.

## 7. Web Client Behavior

1. User picks files → for each file:
   - `POST /api/upload/init` with `{ session_id, name, size, sha256 }`
     (sha256 computed in browser via WebCrypto; for large files in MVP
     we may defer hashing — see decision log).
   - `PUT <upload_url>` body=File, with progress events.
2. Listen on `/ws/client` for `upload_ack`. Match by `upload_id`. Show
   toast: ok → "{name} → {path}", fail → "{name}: {reason}".

Drag/drop and paste are handled at the browser layer only; they all funnel
to the same per-file pipeline above.

## 8. Decision Log

- **Path injection only, no command template.** User specifies the
  command themselves; agent only injects the quoted path + trailing
  space. Rationale: simpler UI, no command-template parser, no expansion
  surprises.
- **No extension/MIME whitelist.** A holder of the session token can
  already `rm -rf` the box; an extension filter is security theater.
- **No per-upload Mac confirmation.** User is remote; one-time
  authorization at share time + audit log replaces it.
- **Single-shot PUT for small files, PATCH-with-Upload-Offset for the
  rest.** The PATCH path is a deliberately small subset of tus 1.0.0
  (core + creation-via-init + resume; no termination / checksum
  extensions). We carry our own creation step (`POST /api/upload/init`)
  instead of tus's `POST <base>` so the JSON envelope can stay
  symmetric with the existing register/session APIs. Web client picks
  PATCH automatically when `file.size > CHUNKED_UPLOAD_THRESHOLD_BYTES`
  (5 MiB by default).
- **sha256 advertised, not enforced for large files in MVP.** The browser
  can skip hashing for files over ~50 MiB and send `sha256: null`. Agent
  treats null as "skip verification".
