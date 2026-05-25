#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import contextvars
import dataclasses
import hashlib
import ipaddress
import json
import os
import pathlib
import secrets
import signal
import struct
import time
import urllib.parse
from typing import Optional


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEFAULT_MAX_BODY_BYTES = 64 * 1024
DEFAULT_MAX_SESSIONS = 4096
DEFAULT_MAX_CLIENTS_PER_SESSION = 8
DEFAULT_MAX_FRAME_BYTES = 256 * 1024
DEFAULT_RATE_LIMIT_REQUESTS = 120
DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 60.0

# File upload defaults (see docs/plan/web-upload.md).
DEFAULT_UPLOAD_MAX_BYTES = 100 * 1024 * 1024  # 100 MiB per file
DEFAULT_UPLOAD_SESSION_MAX_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB / session
DEFAULT_UPLOAD_MAX_PENDING = 4  # concurrent in-flight uploads per session
# Global cap on in-flight (not-yet-pulled) uploads across all sessions.
# Defaults high enough not to bother a single-user deployment but caps
# the disk footprint when the relay is shared / multi-tenant.
DEFAULT_UPLOAD_GLOBAL_MAX_PENDING = 128
DEFAULT_UPLOAD_TTL = 600.0  # seconds an upload can wait for agent pull
DEFAULT_UPLOAD_INIT_BODY_BYTES = 4096
DEFAULT_UPLOAD_CHUNK_BYTES = 1 * 1024 * 1024  # streaming chunk size (PUT)
DEFAULT_UPLOAD_PATCH_CHUNK_BYTES = 5 * 1024 * 1024  # recommended PATCH chunk
# Hard cap on a single PATCH body. Large enough to let a sensible client
# upload in big chunks (faster on high-RTT links) but bounded so a hostile
# client can't pin the relay's memory with one massive PATCH. Keep in sync
# with the web client's chunk picker in upload.js.
DEFAULT_UPLOAD_PATCH_MAX_BYTES = 16 * 1024 * 1024

# Sentinels rejected anywhere in user-supplied filenames. Anything else is
# kept verbatim so non-ASCII (CJK / accents) filenames survive the round
# trip; the macOS agent does its own sanitize pass before touching disk.
_UPLOAD_FORBIDDEN_NAME_CHARS = frozenset({"/", "\\", "\x00", "\r", "\n"})
_UPLOAD_NAME_MAX_LENGTH = 200


@dataclasses.dataclass(frozen=True)
class RelayConfig:
    host: str
    port: int
    offline_ttl: float
    token_ttl: float
    allowed_user_tokens: frozenset[str]
    allow_user_token_client_access: bool
    static_root: pathlib.Path
    max_body_bytes: int
    max_sessions: int
    max_clients_per_session: int
    max_frame_bytes: int
    rate_limit_requests: int
    rate_limit_window_seconds: float
    trusted_proxies: tuple = ()
    token_expiry_check_seconds: float = 30.0
    ping_interval_seconds: float = 30.0
    ping_timeout_seconds: float = 60.0
    client_send_buffer_bytes: int = 1024 * 1024
    admin_host: str = "127.0.0.1"
    admin_port: int = 0
    upload_max_bytes: int = DEFAULT_UPLOAD_MAX_BYTES
    upload_session_max_bytes: int = DEFAULT_UPLOAD_SESSION_MAX_BYTES
    upload_max_pending: int = DEFAULT_UPLOAD_MAX_PENDING
    upload_global_max_pending: int = DEFAULT_UPLOAD_GLOBAL_MAX_PENDING
    upload_ttl: float = DEFAULT_UPLOAD_TTL
    upload_dir: pathlib.Path = pathlib.Path("/tmp/ghostty-uploads")


@dataclasses.dataclass
class RateLimitBucket:
    window_started_at: float
    count: int


def env_str(name: str, default: str) -> str:
    return os.environ.get(name, default)


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value is None:
        return default
    return int(value)


def env_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    if value is None:
        return default
    return float(value)


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


# Per-session replay backlog. A fresh client connect drains the entire
# backlog through `term.write` before live frames resume; a 256 KiB cap
# was producing a visible top-to-bottom scan on long sessions, so the
# default is now sized for "a few screens of recent activity" and the
# operator can dial it back up via env where the longer scrollback is
# worth the slower first paint.
SESSION_BACKLOG_LIMIT = env_int("GHOSTTY_RELAY_SESSION_BACKLOG_BYTES", 64 * 1024)
SESSION_BACKLOG_FRAME_LIMIT = env_int("GHOSTTY_RELAY_SESSION_BACKLOG_FRAMES", 256)


def parse_trusted_proxies(value: str) -> tuple:
    """Parse a comma-separated list of IPs/CIDRs into ip_network objects.

    Empty / unparseable entries are dropped silently so the env can be left
    unset by default and never accidentally trust a real client.
    """
    items: list = []
    for raw in (value or "").split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            items.append(ipaddress.ip_network(raw, strict=False))
        except ValueError:
            log_event("trusted_proxy_invalid", value=raw)
            continue
    return tuple(items)


def resolve_client_ip(
    peer_host: Optional[str],
    headers: dict[str, str],
    trusted_proxies: tuple,
) -> str:
    """Return the real client IP, honoring X-Forwarded-For only when the socket
    peer itself is a trusted proxy. Anything else returns the socket peer.
    """
    if not peer_host:
        return "unknown"
    if not trusted_proxies:
        return peer_host
    try:
        peer_ip = ipaddress.ip_address(peer_host)
    except ValueError:
        return peer_host
    if not any(peer_ip in net for net in trusted_proxies):
        return peer_host
    forwarded = headers.get("x-forwarded-for", "").strip()
    if not forwarded:
        return peer_host
    first_hop = forwarded.split(",", 1)[0].strip()
    if not first_hop:
        return peer_host
    try:
        ipaddress.ip_address(first_hop)
    except ValueError:
        return peer_host
    return first_hop


def load_allowed_user_tokens() -> frozenset[str]:
    configured: set[str] = set()

    inline = os.environ.get("GHOSTTY_RELAY_USER_TOKENS", "")
    if inline.strip():
        configured.update(
            token.strip()
            for token in inline.split(",")
            if token.strip()
        )

    token_file = os.environ.get("GHOSTTY_RELAY_USER_TOKENS_FILE", "").strip()
    if token_file:
        for line in pathlib.Path(token_file).read_text(encoding="utf-8").splitlines():
            token = line.strip()
            if token and not token.startswith("#"):
                configured.add(token)

    return frozenset(configured)


def log_event(event: str, **fields: object) -> None:
    payload = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
    }
    payload.update(fields)
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def host_requires_public_bind_ack(host: str) -> bool:
    """Return True if binding to ``host`` exposes the relay outside a single
    private interface and therefore requires an explicit operator ack via
    ``--allow-public-bind`` / ``GHOSTTY_RELAY_ALLOW_PUBLIC_BIND``.

    - localhost / 127.0.0.0/8 / ::1: trusted loopback, no ack needed.
    - 0.0.0.0 and :: (wildcard): bind to every interface including any
      public one, so an ack is always required.
    - RFC1918 (10/8, 172.16/12, 192.168/16), CGNAT, IPv4 link-local
      (169.254/16), IPv6 link-local (fe80::/10), and IPv6 ULA (fc00::/7)
      bind to a single non-public interface — that's a deliberate LAN
      deployment, not a footgun, so no ack is required.
    - Anything else (including unparseable hostnames we can't reason
      about) is treated as a public bind.
    """
    normalized = host.strip().lower()
    if normalized in {"localhost"}:
        return False
    try:
        ip = ipaddress.ip_address(normalized)
    except ValueError:
        return True
    if ip.is_unspecified:
        return True
    if ip.is_loopback:
        return False
    if ip.is_private or ip.is_link_local:
        return False
    return True


class ClientChannel:
    """Per-client send buffer with a byte cap.

    Frames produced by the agent (or backlog replay) are enqueued via
    ``try_enqueue``. A dedicated sender task drains the queue. When a client
    cannot keep up and the queue exceeds ``max_bytes``, the channel marks
    itself dropped and signals the sender, which closes the underlying socket
    with the slow-consumer close code so other clients are not delayed by it.
    """

    def __init__(self, writer: asyncio.StreamWriter, max_bytes: int) -> None:
        self.writer = writer
        self.queue: asyncio.Queue = asyncio.Queue()
        self.queued_bytes = 0
        self.max_bytes = max_bytes
        self.dropped = False

    def try_enqueue(self, opcode: int, payload: bytes) -> bool:
        if self.dropped:
            return False
        if self.max_bytes > 0 and self.queued_bytes + len(payload) > self.max_bytes:
            self.dropped = True
            try:
                self.queue.put_nowait(None)
            except asyncio.QueueFull:
                pass
            return False
        self.queued_bytes += len(payload)
        try:
            self.queue.put_nowait((opcode, payload))
        except asyncio.QueueFull:
            self.queued_bytes -= len(payload)
            self.dropped = True
            return False
        return True


@dataclasses.dataclass
class PendingUpload:
    """A file the browser has uploaded to the relay but the agent has not
    yet pulled. Lives in memory + a single .partial / final file on disk.

    The relay only ever holds one copy per upload_id. After a successful
    pull the file and dict entry are removed; the cumulative
    `session.uploaded_bytes_total` counter is *not* decremented — it
    counts lifetime bytes for quota enforcement.
    """
    upload_id: str
    session_id: str
    name: str
    size: int
    sha256: Optional[str]
    pull_token: str
    path: pathlib.Path
    created_at: float
    expires_at: float
    received: int = 0
    sha256_observed: Optional[str] = None
    delivered: bool = False  # True once agent has pulled, prior to cleanup
    uploading: bool = False  # True between PUT/PATCH start and finish
    # Rolling sha256 state. None until the first byte lands. PATCH-based
    # uploads update this on every chunk so we don't have to re-read the
    # final file from disk just to verify. PUT uploads still compute hash
    # inline but write through the same field for parity.
    _hasher: object = None  # hashlib._Hash; typed as object to keep
    # dataclass auto-generated __eq__ from comparing hasher objects.

    def hasher(self):
        """Lazily create the rolling sha256 hasher. Idempotent — repeated
        calls return the same instance so PATCH chunks keep accumulating
        into a single digest across multiple requests."""
        if self._hasher is None:
            self._hasher = hashlib.sha256()
        return self._hasher


@dataclasses.dataclass
class Session:
    session_id: str
    name: str
    user_token: str
    agent_token: str
    client_token: str
    expires_at: float
    online: bool = False
    last_seen_at: float = dataclasses.field(default_factory=lambda: time.time())
    agent_writer: Optional[asyncio.StreamWriter] = None
    clients: dict[asyncio.StreamWriter, ClientChannel] = dataclasses.field(default_factory=dict)
    backlog: list[tuple[int, bytes]] = dataclasses.field(default_factory=list)
    backlog_size: int = 0
    pending_uploads: dict[str, PendingUpload] = dataclasses.field(default_factory=dict)
    uploaded_bytes_total: int = 0
    # Uploads that completed PUT before the agent reconnected. We drain
    # this list right after the agent's WS handshake so files don't get
    # stuck if the agent flapped while a transfer was finishing.
    pending_ready_notifications: list[str] = dataclasses.field(default_factory=list)

    def append_backlog(self, opcode: int, payload: bytes) -> None:
        if opcode not in (0x1, 0x2) or not payload:
            return

        # The macOS agent emits a `{"type":"screen", ...}` text frame as a
        # checkpoint: it carries the full visible viewport as VT bytes, so
        # any frame strictly before it is redundant for a fresh client and
        # only causes a slow top-to-bottom replay. Drop the prior backlog
        # when we see a snapshot land — except for metadata frames like
        # `hello` and `appearance` that aren't redundant with the
        # snapshot (they tell the client the host's cols/rows and the
        # colour scheme, which the screen frame doesn't re-state). A
        # fresh client that connects after a screen frame still needs
        # those, otherwise the grid stays at FitAddon's default and
        # wide host content wraps inside the browser. We deliberately
        # only inspect text frames; binary payloads are raw PTY bytes
        # and not control-shaped.
        if opcode == 0x1 and _is_screen_snapshot(payload):
            preserved: list[tuple[int, bytes]] = []
            preserved_size = 0
            for entry_opcode, entry_payload in self.backlog:
                if entry_opcode == 0x1 and _is_essential_metadata(entry_payload):
                    preserved.append((entry_opcode, entry_payload))
                    preserved_size += len(entry_payload)
            self.backlog = preserved
            self.backlog_size = preserved_size

        entry = (opcode, bytes(payload))
        self.backlog.append(entry)
        self.backlog_size += len(payload)

        while (
            self.backlog_size > SESSION_BACKLOG_LIMIT
            or len(self.backlog) > SESSION_BACKLOG_FRAME_LIMIT
        ):
            stale_opcode, stale_payload = self.backlog.pop(0)
            if stale_opcode in (0x1, 0x2):
                self.backlog_size -= len(stale_payload)


def _is_screen_snapshot(payload: bytes) -> bool:
    if not payload:
        return False
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return isinstance(decoded, dict) and decoded.get("type") == "screen"


# Frame types whose value to a fresh client outlasts the screen
# checkpoint. `hello` carries the host's cols/rows (without it the
# browser falls back to FitAddon and wraps wide content); `appearance`
# carries colours / font-size. Both are sent once at agent connect
# time and never re-emitted unless the agent reconnects, so dropping
# them on every screen checkpoint silently broke late-joining clients.
_ESSENTIAL_BACKLOG_TYPES = frozenset({"hello", "appearance"})


def _is_essential_metadata(payload: bytes) -> bool:
    if not payload:
        return False
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return (
        isinstance(decoded, dict)
        and decoded.get("type") in _ESSENTIAL_BACKLOG_TYPES
    )


# Upper bound matches the register payload's name length cap.
_NAME_UPDATE_MAX_LENGTH = 256


def _handle_name_update(state: "RelayState", session: "Session", payload: bytes) -> bool:
    """Apply a `name_update` control frame in-place on `session`.

    Returns ``True`` when the frame was consumed (so the caller should
    skip forwarding it to clients and skip appending it to the backlog).
    Returns ``False`` for any frame that isn't a well-formed
    `name_update`, leaving the normal forward path untouched.

    String assignment to ``session.name`` is atomic in CPython, so no
    additional locking is required for the read path in
    `handle_sessions`.
    """
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(decoded, dict) or decoded.get("type") != "name_update":
        return False
    new_name = decoded.get("name")
    if not isinstance(new_name, str) or len(new_name) > _NAME_UPDATE_MAX_LENGTH:
        # Malformed name_update: consume the frame so it doesn't pollute
        # the backlog, but don't touch session.name.
        return True
    if session.name != new_name:
        session.name = new_name
        state.increment_metric("name_update_total")
        # Don't log the name itself — terminal titles often carry the
        # active task/project subject, and journal access is shared with
        # ops. Length lets us still spot abuse (zero-length / huge names).
        log_event(
            "name_update",
            session_id=session.session_id,
            name_length=len(new_name),
        )
    return True


class RelayState:
    def __init__(self, config: RelayConfig) -> None:
        self.config = config
        self.offline_ttl = config.offline_ttl
        self.sessions: dict[str, Session] = {}
        self.rate_limits: dict[str, RateLimitBucket] = {}
        self.lock = asyncio.Lock()
        self.started_at = time.time()
        self.shutting_down = False
        self.metrics: dict[str, int] = {
            "register_requests_total": 0,
            "register_rejected_total": 0,
            "register_reused_total": 0,
            "agent_connect_total": 0,
            "agent_disconnect_total": 0,
            "client_connect_total": 0,
            "client_disconnect_total": 0,
            "auth_rejected_total": 0,
            "expired_session_rejected_total": 0,
            "rate_limited_total": 0,
            "slow_consumer_drop_total": 0,
            "upload_init_total": 0,
            "upload_init_rejected_total": 0,
            "upload_put_total": 0,
            "upload_put_rejected_total": 0,
            "upload_pull_total": 0,
            "upload_pull_rejected_total": 0,
            "upload_expired_total": 0,
            "upload_bytes_total": 0,
            "apk_download_total": 0,
            "apk_download_rejected_total": 0,
            "apk_download_grant_total": 0,
            "apk_download_grant_rejected_total": 0,
        }
        # short-lived single-use download tokens, granted by /api/app/android/grant.
        # Maps grant_token -> expires_at (epoch seconds). Some mobile browsers
        # (Huawei, UC, in-app webviews) refuse blob URL + <a download>, so the
        # web client trades its Bearer token for one of these and navigates the
        # window straight at /api/app/android?dl=<grant>. 60 s TTL keeps the
        # leak window small if a URL ends up in a proxy log.
        self.apk_download_grants: dict[str, float] = {}

    def is_valid_user_token(self, token: str) -> bool:
        allowed = self.config.allowed_user_tokens
        if not allowed:
            return True
        return token in allowed

    def increment_metric(self, name: str, amount: int = 1) -> None:
        self.metrics[name] = self.metrics.get(name, 0) + amount

    def metrics_text(self) -> str:
        sessions_total = len(self.sessions)
        sessions_online = sum(1 for session in self.sessions.values() if session.online)
        sessions_offline = sessions_total - sessions_online
        active_agents = sum(1 for session in self.sessions.values() if session.agent_writer is not None)
        active_clients = sum(len(session.clients) for session in self.sessions.values())
        lines = [
            "# TYPE ghostty_relay_sessions gauge",
            f"ghostty_relay_sessions {sessions_total}",
            "# TYPE ghostty_relay_sessions_online gauge",
            f"ghostty_relay_sessions_online {sessions_online}",
            "# TYPE ghostty_relay_sessions_offline gauge",
            f"ghostty_relay_sessions_offline {sessions_offline}",
            "# TYPE ghostty_relay_active_agents gauge",
            f"ghostty_relay_active_agents {active_agents}",
            "# TYPE ghostty_relay_active_clients gauge",
            f"ghostty_relay_active_clients {active_clients}",
            "# TYPE ghostty_relay_uptime_seconds gauge",
            f"ghostty_relay_uptime_seconds {int(time.time() - self.started_at)}",
        ]
        for key in sorted(self.metrics):
            lines.append(f"# TYPE ghostty_relay_{key} counter")
            lines.append(f"ghostty_relay_{key} {self.metrics[key]}")
        return "\n".join(lines) + "\n"

    async def cleanup_loop(self) -> None:
        while True:
            await asyncio.sleep(5)
            now = time.time()
            cutoff = now - self.offline_ttl
            rate_limit_cutoff = now - self.config.rate_limit_window_seconds
            async with self.lock:
                # Drop expired uploads before dropping their owning sessions
                # so we always remove the temp file even if the session is
                # also going away in the same tick.
                for session in self.sessions.values():
                    expired_uploads = [
                        upload
                        for upload in session.pending_uploads.values()
                        if upload.expires_at < now
                    ]
                    for upload in expired_uploads:
                        self.increment_metric("upload_expired_total")
                        _remove_upload(session, upload, reason="ttl_expired")
                        log_event(
                            "upload_expired",
                            session_id=session.session_id,
                            upload_id=upload.upload_id,
                        )
                expired = [
                    session_id
                    for session_id, session in self.sessions.items()
                    if not session.online and session.last_seen_at < cutoff
                ]
                for session_id in expired:
                    session = self.sessions.pop(session_id, None)
                    if session is not None:
                        for upload in list(session.pending_uploads.values()):
                            _remove_upload(session, upload, reason="session_expired")
                    log_event("session_expired", session_id=session_id)
                expired_grants = [
                    grant for grant, deadline in self.apk_download_grants.items()
                    if deadline < now
                ]
                for grant in expired_grants:
                    self.apk_download_grants.pop(grant, None)
                stale_rate_keys = [
                    key
                    for key, bucket in self.rate_limits.items()
                    if bucket.window_started_at < rate_limit_cutoff
                ]
                for key in stale_rate_keys:
                    self.rate_limits.pop(key, None)

    def should_rate_limit(self, key: str, now: float | None = None) -> tuple[bool, int]:
        if self.config.rate_limit_requests <= 0:
            return False, 0
        if now is None:
            now = time.time()
        bucket = self.rate_limits.get(key)
        if bucket is None or now - bucket.window_started_at >= self.config.rate_limit_window_seconds:
            self.rate_limits[key] = RateLimitBucket(window_started_at=now, count=1)
            return False, 0
        if bucket.count >= self.config.rate_limit_requests:
            retry_after = max(1, int(self.config.rate_limit_window_seconds - (now - bucket.window_started_at)))
            return True, retry_after
        bucket.count += 1
        return False, 0


async def read_http_head(
    reader: asyncio.StreamReader,
) -> tuple[str, str, dict[str, str]]:
    """Read the request line and headers only.

    Body bytes remain on the wire for the caller to consume. This split lets
    routes that need streaming bodies (uploads) read incrementally instead of
    inheriting the legacy `max_body_bytes` cap.
    """
    header_blob = await reader.readuntil(b"\r\n\r\n")
    header_text = header_blob.decode("utf-8", "replace")
    lines = header_text.split("\r\n")
    request_line = lines[0]
    method, target, _ = request_line.split(" ", 2)
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return method, target, headers


async def read_http_body(
    reader: asyncio.StreamReader,
    headers: dict[str, str],
    *,
    max_body_bytes: int,
) -> bytes:
    length = int(headers.get("content-length", "0"))
    if length > max_body_bytes:
        raise ValueError("request body too large")
    return await reader.readexactly(length) if length else b""


async def read_http_request(
    reader: asyncio.StreamReader,
    *,
    max_body_bytes: int,
) -> tuple[str, str, dict[str, str], bytes]:
    """Compatibility wrapper kept for callers that want both head and body
    in a single shot. Upload routes deliberately use the split form."""
    method, target, headers = await read_http_head(reader)
    body = await read_http_body(reader, headers, max_body_bytes=max_body_bytes)
    return method, target, headers, body


# CORS support for Capacitor Android/iOS clients. Browsers hitting the
# same origin (where the web dist is served) don't need this; only the
# native APP's WebView, which loads HTML from `https://localhost`, is
# cross-origin. Authorization-bearing fetches trigger a preflight, and
# without these headers the browser drops the response before JS sees it.
CAPACITOR_CORS_ORIGINS = frozenset({
    "https://localhost",   # Capacitor 5+ default (androidScheme: "https")
    "http://localhost",    # Capacitor 4 / older Android default
    "capacitor://localhost",  # iOS default scheme
    "ionic://localhost",   # legacy Ionic scheme, harmless to allow
})

_cors_headers_ctx: contextvars.ContextVar[dict[str, str]] = contextvars.ContextVar(
    "cors_headers_ctx", default={}
)


def build_cors_headers(request_origin: str) -> dict[str, str]:
    if not request_origin or request_origin not in CAPACITOR_CORS_ORIGINS:
        return {}
    return {
        "Access-Control-Allow-Origin": request_origin,
        "Access-Control-Allow-Credentials": "true",
        "Vary": "Origin",
    }


async def send_response(
    writer: asyncio.StreamWriter,
    status: int,
    body: bytes,
    content_type: str = "application/json; charset=utf-8",
    extra_headers: Optional[dict[str, str]] = None,
) -> None:
    reason = {
        200: "OK",
        201: "Created",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        409: "Conflict",
        410: "Gone",
        413: "Payload Too Large",
        422: "Unprocessable Entity",
        429: "Too Many Requests",
        500: "Internal Server Error",
        503: "Service Unavailable",
    }.get(status, "OK")
    headers = {
        "Content-Type": content_type,
        "Content-Length": str(len(body)),
        "Connection": "close",
    }
    if extra_headers:
        headers.update(extra_headers)
    # Inject CORS for Capacitor APP cross-origin fetches. The ctx is set
    # by handle_connection at request entry. setdefault avoids clobbering
    # any CORS values a handler explicitly chose to set.
    for cors_key, cors_value in _cors_headers_ctx.get().items():
        headers.setdefault(cors_key, cors_value)

    try:
        writer.write(f"HTTP/1.1 {status} {reason}\r\n".encode("utf-8"))
        for key, value in headers.items():
            writer.write(f"{key}: {value}\r\n".encode("utf-8"))
        writer.write(b"\r\n")
        writer.write(body)
        await writer.drain()
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionResetError:
            pass


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


def bearer_token(headers: dict[str, str]) -> Optional[str]:
    value = headers.get("authorization")
    if not value:
        return None
    prefix = "bearer "
    if value.lower().startswith(prefix):
        return value[len(prefix):]
    return None


def websocket_accept(key: str) -> str:
    digest = hashlib.sha1((key + WS_GUID).encode("utf-8")).digest()
    return base64.b64encode(digest).decode("ascii")


async def websocket_handshake(writer: asyncio.StreamWriter, headers: dict[str, str]) -> None:
    key = headers.get("sec-websocket-key")
    if not key:
        raise ValueError("missing sec-websocket-key")
    accept = websocket_accept(key)
    writer.write(
        (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode("utf-8")
    )
    await writer.drain()


async def ws_read_frame(reader: asyncio.StreamReader, *, max_frame_bytes: int) -> tuple[int, bytes]:
    header = await reader.readexactly(2)
    first, second = header[0], header[1]
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", await reader.readexactly(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", await reader.readexactly(8))[0]
    if length > max_frame_bytes:
        raise ValueError("frame too large")

    mask = await reader.readexactly(4) if masked else b""
    payload = await reader.readexactly(length) if length else b""
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


async def ws_send_frame(writer: asyncio.StreamWriter, opcode: int, payload: bytes) -> None:
    first = 0x80 | (opcode & 0x0F)
    length = len(payload)
    if length < 126:
        header = bytes([first, length])
    elif length < (1 << 16):
        header = bytes([first, 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, 127]) + struct.pack("!Q", length)
    writer.write(header + payload)
    await writer.drain()


async def ws_send_text(writer: asyncio.StreamWriter, text: str) -> None:
    await ws_send_frame(writer, 0x1, text.encode("utf-8"))


async def ws_send_binary(writer: asyncio.StreamWriter, data: bytes) -> None:
    await ws_send_frame(writer, 0x2, data)


async def ws_close(writer: asyncio.StreamWriter) -> None:
    try:
        await ws_send_frame(writer, 0x8, b"")
    except Exception:
        pass
    writer.close()
    await writer.wait_closed()


async def ws_close_with_code(writer: asyncio.StreamWriter, code: int, reason: str = "") -> None:
    payload = struct.pack("!H", code) + reason.encode("utf-8")
    try:
        await ws_send_frame(writer, 0x8, payload)
    except Exception:
        pass
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass


async def watch_token_expiry(
    session: Session,
    writer: asyncio.StreamWriter,
    interval: float,
) -> None:
    if interval <= 0:
        return
    while True:
        await asyncio.sleep(interval)
        if session.expires_at <= time.time():
            await ws_close_with_code(writer, 4401, "token_expired")
            return


async def watch_heartbeat(
    writer: asyncio.StreamWriter,
    last_pong_at: dict,
    interval: float,
    timeout: float,
) -> None:
    if interval <= 0 or timeout <= 0:
        return
    while True:
        await asyncio.sleep(interval)
        now = time.time()
        if now - last_pong_at["value"] > timeout:
            await ws_close_with_code(writer, 4408, "ping_timeout")
            return
        try:
            await ws_send_frame(writer, 0x9, b"")
        except Exception:
            return


async def handle_register(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    body: bytes,
) -> None:
    if method != "POST":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return
    state.increment_metric("register_requests_total")

    try:
        payload = json.loads(body.decode("utf-8"))
        session_id = str(payload["session_id"])
        name = str(payload["name"])
        token = str(payload["token"])
    except Exception:
        await send_response(writer, 400, json_bytes({"error": "invalid json"}))
        return

    if not session_id or len(session_id) > 128 or len(name) > 256 or not token or len(token) > 1024:
        state.increment_metric("register_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid payload"}))
        return
    if not state.is_valid_user_token(token):
        state.increment_metric("register_rejected_total")
        state.increment_metric("auth_rejected_total")
        log_event("register_rejected", reason="invalid_user_token", session_id=session_id)
        await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
        return

    now = time.time()
    async with state.lock:
        existing = state.sessions.get(session_id)
        if existing is None and len(state.sessions) >= state.config.max_sessions:
            state.increment_metric("register_rejected_total")
            await send_response(writer, 503, json_bytes({"error": "session capacity reached"}))
            return

        if existing is not None:
            # Re-register of a session_id we already track — this is the
            # common case when the macOS agent's WebSocket drops (idle
            # NAT / nginx upstream timeout / Wi-Fi flap) and the agent
            # re-establishes within token TTL. Rotate the tokens and
            # extend expires_at so the client side picks up fresh
            # credentials, but preserve every field that the live
            # session has been accumulating since the original register:
            #
            #   - name: auto-sync mode always sends register with
            #     name="" and then drips `name_update` frames as the
            #     PTY title changes. A naive re-create here used to
            #     wipe name back to "" — and because the macOS side
            #     uses a diff-based lastSentTitleUpdate cache, the
            #     unchanged title would never re-publish, leaving the
            #     web session list showing "未命名会话" indefinitely.
            #     Accept a non-empty `name` override (explicit rename
            #     path) but otherwise hold onto the live value.
            #   - backlog: dropping it would force every reconnecting
            #     web client to start from a fresh screen snapshot and
            #     lose the rolling history of bin frames in between.
            #
            # We deliberately do NOT cross-check the incoming user_token
            # against existing.user_token: session_id is a client-side
            # UUID (collision-free in practice) and the original
            # handler also accepted whatever token the agent provided.
            existing.user_token = token
            existing.agent_token = secrets.token_urlsafe(24)
            existing.client_token = secrets.token_urlsafe(24)
            existing.expires_at = now + state.config.token_ttl
            existing.last_seen_at = now
            existing.online = False
            if name:
                existing.name = name
            session = existing
            state.increment_metric("register_reused_total")
        else:
            session = Session(
                session_id=session_id,
                name=name,
                user_token=token,
                agent_token=secrets.token_urlsafe(24),
                client_token=secrets.token_urlsafe(24),
                expires_at=now + state.config.token_ttl,
                online=False,
                last_seen_at=now,
            )
            state.sessions[session_id] = session
    log_event(
        "register",
        session_id=session_id,
        name_length=len(name),
        online=False,
        reused=existing is not None,
    )

    await send_response(
        writer,
        200,
        json_bytes(
            {
                "session_id": session.session_id,
                "agent_token": session.agent_token,
                "client_token": session.client_token,
                "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(session.expires_at)),
            }
        ),
    )


async def handle_sessions(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    headers: dict[str, str],
) -> None:
    if method != "GET":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return

    token = bearer_token(headers)
    if not token:
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return
    if not state.is_valid_user_token(token):
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
        return

    now = time.time()
    async with state.lock:
        sessions = [
            {
                "id": session.session_id,
                "name": session.name,
                "online": session.online,
                "last_seen_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(session.last_seen_at)),
                "client_token": session.client_token,
            }
            for session in state.sessions.values()
            if session.user_token == token and session.expires_at > now
        ]

    await send_response(writer, 200, json_bytes(sessions))


# ---------------------------------------------------------------------------
# Android APK download. Lives next to the web dist root:
#   <static_root>.parent / "apk" / "app-release.apk"
# The browser fetches with a Bearer token; behaves like /api/sessions.
# ---------------------------------------------------------------------------


APK_DOWNLOAD_FILENAME = "ghostty-sharing.apk"
APK_GRANT_TTL_SECONDS = 60.0


def resolve_apk_path(static_root: pathlib.Path) -> pathlib.Path:
    override = os.environ.get("GHOSTTY_RELAY_APK_PATH", "").strip()
    if override:
        return pathlib.Path(override)
    return static_root.parent / "apk" / "app-release.apk"


async def handle_apk_grant(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    headers: dict[str, str],
) -> None:
    """Trade a Bearer user token for a short-lived URL-friendly grant
    that the web client can append to a navigation URL. Some mobile
    browsers won't trigger downloads off blob URLs."""
    if method != "POST":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return

    token = bearer_token(headers)
    if not token:
        state.increment_metric("auth_rejected_total")
        state.increment_metric("apk_download_grant_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return
    if not state.is_valid_user_token(token):
        state.increment_metric("auth_rejected_total")
        state.increment_metric("apk_download_grant_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
        return

    grant = secrets.token_urlsafe(16)
    async with state.lock:
        state.apk_download_grants[grant] = time.time() + APK_GRANT_TTL_SECONDS
    state.increment_metric("apk_download_grant_total")
    await send_response(
        writer,
        200,
        json_bytes({"token": grant, "expires_in": int(APK_GRANT_TTL_SECONDS)}),
    )


async def handle_apk_download(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    headers: dict[str, str],
    query: dict[str, list[str]],
) -> None:
    if method != "GET":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return

    # Auth: either ?dl=<grant> (mobile-friendly URL nav) or Authorization: Bearer
    # (desktop / curl). Grants are not consumed on use — the 60 s TTL is the
    # only gate, so a browser retry of the same navigation still works.
    grant_values = query.get("dl") or query.get("grant") or []
    grant = grant_values[0] if grant_values else ""
    authorized = False
    if grant:
        async with state.lock:
            deadline = state.apk_download_grants.get(grant)
            if deadline is not None and deadline >= time.time():
                authorized = True
            elif deadline is not None:
                state.apk_download_grants.pop(grant, None)
        if not authorized:
            state.increment_metric("apk_download_rejected_total")
            await send_response(
                writer, 401, json_bytes({"error": "invalid or expired grant"})
            )
            return
    else:
        token = bearer_token(headers)
        if not token:
            state.increment_metric("auth_rejected_total")
            state.increment_metric("apk_download_rejected_total")
            await send_response(
                writer, 401, json_bytes({"error": "missing bearer token"})
            )
            return
        if not state.is_valid_user_token(token):
            state.increment_metric("auth_rejected_total")
            state.increment_metric("apk_download_rejected_total")
            await send_response(
                writer, 401, json_bytes({"error": "invalid user token"})
            )
            return

    apk_path = resolve_apk_path(state.config.static_root)
    if not apk_path.exists() or not apk_path.is_file():
        state.increment_metric("apk_download_rejected_total")
        log_event("apk_download_missing", path=str(apk_path))
        await send_response(writer, 503, json_bytes({"error": "apk_not_available"}))
        return

    body = apk_path.read_bytes()
    state.increment_metric("apk_download_total")
    await send_response(
        writer,
        200,
        body,
        "application/vnd.android.package-archive",
        extra_headers={
            "Content-Disposition": f'attachment; filename="{APK_DOWNLOAD_FILENAME}"',
            "Cache-Control": "no-store",
        },
    )


# ---------------------------------------------------------------------------
# File upload (browser → relay → mac agent). See docs/plan/web-upload.md.
# ---------------------------------------------------------------------------


def _sanitize_upload_name(raw: object) -> Optional[str]:
    """Light sanitize for filenames *as seen by the relay*. The agent does a
    stricter pass before touching disk; this stage just rejects obvious junk
    so we never write a path-separator-bearing filename into the relay's
    own staging directory."""
    if not isinstance(raw, str):
        return None
    trimmed = raw.strip()
    if not trimmed or len(trimmed.encode("utf-8")) > _UPLOAD_NAME_MAX_LENGTH:
        return None
    if any(ch in _UPLOAD_FORBIDDEN_NAME_CHARS for ch in trimmed):
        return None
    if any(ord(ch) < 0x20 for ch in trimmed):
        return None
    if trimmed in {".", ".."}:
        return None
    return trimmed


def _staging_path(state: RelayState, upload_id: str) -> pathlib.Path:
    state.config.upload_dir.mkdir(parents=True, exist_ok=True)
    return state.config.upload_dir / f"{upload_id}.bin"


def _upload_ready_frame(upload: PendingUpload) -> bytes:
    return json.dumps(
        {
            "type": "upload_ready",
            "upload_id": upload.upload_id,
            "name": upload.name,
            "size": upload.size,
            "sha256": upload.sha256,
            "pull_token": upload.pull_token,
            "pull_url": f"/api/upload/{upload.upload_id}/pull",
        },
        ensure_ascii=False,
    ).encode("utf-8")


def _queue_pending_notification(session: Session, upload_id: str) -> None:
    if upload_id not in session.pending_ready_notifications:
        session.pending_ready_notifications.append(upload_id)


async def _push_upload_ready_unlocked(
    session: Session, upload: PendingUpload
) -> bool:
    """Send `upload_ready` to the agent over /ws/agent.

    Must be called *outside* `state.lock`: ws_send_frame awaits real IO
    and we must not hold the global lock while doing that. The caller is
    expected to do a lock-protected lookup of `(session, upload)` and
    invoke this on the resolved objects.

    On send failure the upload_id is queued for replay on next agent
    connect.
    """
    writer = session.agent_writer
    if writer is None:
        _queue_pending_notification(session, upload.upload_id)
        return False
    try:
        await ws_send_frame(writer, 0x1, _upload_ready_frame(upload))
        return True
    except Exception:
        _queue_pending_notification(session, upload.upload_id)
        return False


async def _drain_pending_upload_ready(
    state: RelayState, session: Session
) -> None:
    """Send every upload_ready that landed while the agent was offline.

    The lock is taken twice: once to snapshot the pending list (under lock),
    once per send (no lock held). New notifications that arrive between
    snapshot and send are picked up by the next drain cycle.
    """
    async with state.lock:
        pending_ids = list(session.pending_ready_notifications)
        session.pending_ready_notifications.clear()
        ready: list[PendingUpload] = []
        for upload_id in pending_ids:
            upload = session.pending_uploads.get(upload_id)
            if not upload or upload.delivered or upload.received != upload.size:
                continue
            ready.append(upload)
    for upload in ready:
        await _push_upload_ready_unlocked(session, upload)


def _remove_upload(session: Session, upload: PendingUpload, *, reason: str) -> None:
    session.pending_uploads.pop(upload.upload_id, None)
    try:
        if upload.path.exists():
            upload.path.unlink()
    except OSError as exc:
        log_event(
            "upload_cleanup_failed",
            session_id=session.session_id,
            upload_id=upload.upload_id,
            reason=reason,
            error=str(exc),
        )


async def handle_upload_init(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    body: bytes,
    headers: dict[str, str],
) -> None:
    if method != "POST":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return
    state.increment_metric("upload_init_total")

    token = bearer_token(headers)
    if not token:
        state.increment_metric("upload_init_rejected_total")
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return

    try:
        payload = json.loads(body.decode("utf-8"))
    except Exception:
        state.increment_metric("upload_init_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid json"}))
        return

    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    size = payload.get("size") if isinstance(payload, dict) else None
    sha256_raw = payload.get("sha256") if isinstance(payload, dict) else None
    name = _sanitize_upload_name(payload.get("name") if isinstance(payload, dict) else None)

    if not isinstance(session_id, str) or not name:
        state.increment_metric("upload_init_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid payload"}))
        return
    if not isinstance(size, int) or size <= 0:
        state.increment_metric("upload_init_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid_size"}))
        return
    if size > state.config.upload_max_bytes:
        state.increment_metric("upload_init_rejected_total")
        await send_response(writer, 413, json_bytes({"error": "size_exceeds_limit"}))
        return

    sha256: Optional[str] = None
    if sha256_raw is not None:
        if not isinstance(sha256_raw, str) or len(sha256_raw) != 64 or any(
            ch not in "0123456789abcdef" for ch in sha256_raw.lower()
        ):
            state.increment_metric("upload_init_rejected_total")
            await send_response(writer, 400, json_bytes({"error": "invalid_sha256"}))
            return
        sha256 = sha256_raw.lower()

    now = time.time()
    async with state.lock:
        session = state.sessions.get(session_id)
        if not session or session.user_token != token:
            state.increment_metric("upload_init_rejected_total")
            await send_response(writer, 404, json_bytes({"error": "session_not_found"}))
            return
        if session.expires_at <= now:
            state.increment_metric("upload_init_rejected_total")
            state.increment_metric("expired_session_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "expired session"}))
            return
        active_pending = sum(
            1 for u in session.pending_uploads.values() if not u.delivered
        )
        if active_pending >= state.config.upload_max_pending:
            state.increment_metric("upload_init_rejected_total")
            await send_response(
                writer, 429, json_bytes({"error": "too_many_pending"})
            )
            return
        # Belt-and-braces global cap: per-session max_pending stops a
        # single bad actor from filling their own slots, but with many
        # sessions the relay-wide footprint scales linearly. The global
        # cap puts an upper bound on the entire staging tree so a
        # multi-tenant deployment can't accumulate more than N pending
        # files at once across the whole process.
        global_pending = sum(
            1
            for sess in state.sessions.values()
            for u in sess.pending_uploads.values()
            if not u.delivered
        )
        if global_pending >= state.config.upload_global_max_pending:
            state.increment_metric("upload_init_rejected_total")
            await send_response(
                writer, 429, json_bytes({"error": "global_pending_full"})
            )
            return
        projected = session.uploaded_bytes_total + size
        if projected > state.config.upload_session_max_bytes:
            state.increment_metric("upload_init_rejected_total")
            await send_response(
                writer, 413, json_bytes({"error": "size_exceeds_session_limit"})
            )
            return

        upload_id = secrets.token_urlsafe(16)
        pull_token = secrets.token_urlsafe(24)
        upload = PendingUpload(
            upload_id=upload_id,
            session_id=session_id,
            name=name,
            size=size,
            sha256=sha256,
            pull_token=pull_token,
            path=_staging_path(state, upload_id),
            created_at=now,
            expires_at=now + state.config.upload_ttl,
        )
        session.pending_uploads[upload_id] = upload

    log_event(
        "upload_init",
        session_id=session_id,
        upload_id=upload_id,
        name=name,
        size=size,
        sha256=sha256 or "",
    )
    await send_response(
        writer,
        200,
        json_bytes(
            {
                "upload_id": upload_id,
                "upload_url": f"/api/upload/{upload_id}",
                "expires_at": int(upload.expires_at),
                # Recommended chunk size for PATCH-based resumable
                # upload. The web client may use a smaller value (e.g.
                # to keep per-chunk progress events frequent) but
                # should not exceed `patch_max_bytes` per chunk.
                "chunk_size": DEFAULT_UPLOAD_PATCH_CHUNK_BYTES,
                "patch_max_bytes": DEFAULT_UPLOAD_PATCH_MAX_BYTES,
            }
        ),
    )


async def _finalize_completed_upload(
    state: RelayState,
    owning_session: Session,
    upload: PendingUpload,
) -> Optional[str]:
    """Common tail for PUT (single-shot) and the *last* PATCH chunk: turn
    the rolling sha256 into a digest, verify against the advertised one
    (if any), bump session counters, clear the in-progress flag, and
    notify the agent over /ws/agent.

    Returns `None` on success or one of:
      - "hash_mismatch": observed digest disagrees with init.sha256;
        the upload entry has been removed and the temp file deleted.
    """
    digest = upload.hasher().hexdigest()
    upload.sha256_observed = digest

    if upload.sha256 is not None and digest != upload.sha256:
        async with state.lock:
            _remove_upload(owning_session, upload, reason="hash_mismatch")
        return "hash_mismatch"

    async with state.lock:
        owning_session.uploaded_bytes_total += upload.size
        state.increment_metric("upload_bytes_total", upload.size)
        upload.uploading = False
    # Push the upload_ready frame *outside* the lock so the WS write does
    # not block other handlers. Failures requeue automatically.
    await _push_upload_ready_unlocked(owning_session, upload)
    return None


async def handle_upload_put(
    state: RelayState,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    headers: dict[str, str],
    upload_id: str,
) -> None:
    """Stream the request body to disk, verify, and notify the agent.

    Body bytes are not pre-loaded by handle_connection — this function owns
    the wire from after the header until the response is written."""
    state.increment_metric("upload_put_total")

    token = bearer_token(headers)
    if not token:
        state.increment_metric("upload_put_rejected_total")
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return

    try:
        declared = int(headers.get("content-length", "0"))
    except ValueError:
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid_content_length"}))
        return

    async with state.lock:
        upload: Optional[PendingUpload] = None
        owning_session: Optional[Session] = None
        for session in state.sessions.values():
            candidate = session.pending_uploads.get(upload_id)
            if candidate is not None:
                upload = candidate
                owning_session = session
                break
        if upload is None or owning_session is None:
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 404, json_bytes({"error": "not_found"}))
            return
        if owning_session.user_token != token:
            state.increment_metric("upload_put_rejected_total")
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
            return
        if upload.uploading or upload.received > 0 or upload.delivered:
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 409, json_bytes({"error": "already_uploaded"}))
            return
        if declared != upload.size:
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 409, json_bytes({"error": "size_mismatch"}))
            return
        if upload.size > state.config.upload_max_bytes:
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 413, json_bytes({"error": "size_exceeds_limit"}))
            return
        # Mark as in-progress *inside* the lock so a racing second PUT for
        # the same upload_id sees `uploading=True` and short-circuits.
        upload.uploading = True

    hasher = upload.hasher()
    remaining = declared
    chunk = DEFAULT_UPLOAD_CHUNK_BYTES
    try:
        upload.path.parent.mkdir(parents=True, exist_ok=True)
        with open(upload.path, "wb") as fp:
            while remaining > 0:
                read_size = chunk if remaining > chunk else remaining
                buf = await reader.readexactly(read_size)
                fp.write(buf)
                hasher.update(buf)
                remaining -= read_size
                upload.received += read_size
                # Yield to the loop between chunks so a 100 MiB PUT
                # doesn't lock other sessions out of ping handling.
                await asyncio.sleep(0)
    except (asyncio.IncompleteReadError, ConnectionResetError, OSError) as exc:
        state.increment_metric("upload_put_rejected_total")
        async with state.lock:
            _remove_upload(owning_session, upload, reason="put_aborted")
        log_event(
            "upload_put_aborted",
            session_id=owning_session.session_id,
            upload_id=upload_id,
            error=str(exc),
        )
        await send_response(writer, 400, json_bytes({"error": "incomplete_body"}))
        return

    failure = await _finalize_completed_upload(state, owning_session, upload)
    if failure == "hash_mismatch":
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 422, json_bytes({"error": "hash_mismatch"}))
        return

    log_event(
        "upload_put",
        session_id=owning_session.session_id,
        upload_id=upload_id,
        size=upload.size,
        sha256=upload.sha256_observed or "",
    )

    await send_response(
        writer,
        200,
        json_bytes(
            {
                "upload_id": upload_id,
                "received": upload.received,
                "sha256": upload.sha256_observed,
            }
        ),
    )


async def handle_upload_head(
    state: RelayState,
    writer: asyncio.StreamWriter,
    headers: dict[str, str],
    upload_id: str,
) -> None:
    """Tus-style HEAD: report the byte count the client should resume from.

    Used by a chunked client that lost its connection mid-PATCH and wants
    to confirm how much the relay actually persisted before sending the
    next slice.
    """
    token = bearer_token(headers)
    if not token:
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return
    async with state.lock:
        upload: Optional[PendingUpload] = None
        owning_session: Optional[Session] = None
        for session in state.sessions.values():
            candidate = session.pending_uploads.get(upload_id)
            if candidate is not None:
                upload = candidate
                owning_session = session
                break
        if upload is None or owning_session is None:
            await send_response(writer, 404, json_bytes({"error": "not_found"}))
            return
        if owning_session.user_token != token:
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
            return
        offset = upload.received
        total = upload.size
    await send_response(
        writer,
        200,
        b"",
        content_type="application/octet-stream",
        extra_headers={
            "Upload-Offset": str(offset),
            "Upload-Length": str(total),
            "Cache-Control": "no-store",
        },
    )


async def handle_upload_patch(
    state: RelayState,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    headers: dict[str, str],
    upload_id: str,
) -> None:
    """Append a single chunk to an in-flight upload.

    Contract (a deliberately small subset of tus 1.0.0):
      Required headers:
        Authorization: Bearer <user_token>
        Content-Type:  application/offset+octet-stream
        Content-Length: <bytes-in-this-chunk>
        Upload-Offset: <bytes-already-on-server>
      Successful response:
        204 No Content + Upload-Offset: <new offset>
        If the offset now equals Upload-Length the relay also finalises
        the upload (sha verification + upload_ready frame) and the
        response body switches to the same JSON shape PUT returns so
        callers don't have to special-case the last chunk.
    """
    state.increment_metric("upload_put_total")  # share PUT counter family

    token = bearer_token(headers)
    if not token:
        state.increment_metric("upload_put_rejected_total")
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return

    # tus 1.0 requires Content-Type: application/offset+octet-stream on
    # every PATCH. We enforce it strictly (the old "missing header is OK"
    # behaviour widened the surface to any caller that could supply
    # Authorization without a preflight-trigger header).
    content_type = headers.get("content-type", "").lower().split(";", 1)[0].strip()
    if content_type != "application/offset+octet-stream":
        state.increment_metric("upload_put_rejected_total")
        await send_response(
            writer, 415, json_bytes({"error": "invalid_content_type"}))
        return

    try:
        declared = int(headers.get("content-length", "0"))
    except ValueError:
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid_content_length"}))
        return
    if declared <= 0:
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "empty_chunk"}))
        return
    if declared > DEFAULT_UPLOAD_PATCH_MAX_BYTES:
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 413, json_bytes({"error": "chunk_too_large"}))
        return

    try:
        client_offset = int(headers.get("upload-offset", ""))
    except ValueError:
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 400, json_bytes({"error": "invalid_upload_offset"}))
        return

    async with state.lock:
        upload: Optional[PendingUpload] = None
        owning_session: Optional[Session] = None
        for session in state.sessions.values():
            candidate = session.pending_uploads.get(upload_id)
            if candidate is not None:
                upload = candidate
                owning_session = session
                break
        if upload is None or owning_session is None:
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 404, json_bytes({"error": "not_found"}))
            return
        if owning_session.user_token != token:
            state.increment_metric("upload_put_rejected_total")
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
            return
        if upload.delivered:
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 409, json_bytes({"error": "already_delivered"}))
            return
        if upload.uploading:
            # Another PATCH for the same upload is in flight. Tus says
            # this is undefined behaviour and a 409 is the cleanest
            # signal — a real tus client serialises PATCHes per upload.
            state.increment_metric("upload_put_rejected_total")
            await send_response(writer, 409, json_bytes({"error": "concurrent_patch"}))
            return
        if client_offset != upload.received:
            state.increment_metric("upload_put_rejected_total")
            await send_response(
                writer, 409, json_bytes({"error": "offset_mismatch"}),
                extra_headers={"Upload-Offset": str(upload.received)},
            )
            return
        if upload.received + declared > upload.size:
            state.increment_metric("upload_put_rejected_total")
            await send_response(
                writer, 413, json_bytes({"error": "overshoot"}))
            return
        upload.uploading = True

    hasher = upload.hasher()
    remaining = declared
    chunk = DEFAULT_UPLOAD_CHUNK_BYTES
    try:
        upload.path.parent.mkdir(parents=True, exist_ok=True)
        # First chunk creates the file; subsequent chunks append.
        mode = "wb" if upload.received == 0 else "ab"
        with open(upload.path, mode) as fp:
            while remaining > 0:
                read_size = chunk if remaining > chunk else remaining
                buf = await reader.readexactly(read_size)
                fp.write(buf)
                hasher.update(buf)
                remaining -= read_size
                upload.received += read_size
                # Yield to the event loop after every chunk write so a
                # large PATCH (worst case 16 MiB across many 1 MiB
                # iterations) doesn't starve other sessions' WS ping /
                # heartbeat handlers. The hash itself is C-implemented
                # so a single chunk is only a few ms, but stacking many
                # chunks in one PATCH adds up.
                await asyncio.sleep(0)
    except (asyncio.IncompleteReadError, ConnectionResetError, OSError) as exc:
        state.increment_metric("upload_put_rejected_total")
        async with state.lock:
            # On a partial chunk we keep the upload pending so the client
            # can resume: don't remove the entry, just clear the inflight
            # flag and trim the file back to the last known good offset.
            upload.uploading = False
        log_event(
            "upload_patch_aborted",
            session_id=owning_session.session_id,
            upload_id=upload_id,
            offset=upload.received,
            error=str(exc),
        )
        await send_response(writer, 400, json_bytes({"error": "incomplete_chunk"}))
        return

    new_offset = upload.received

    if new_offset < upload.size:
        # Mid-upload chunk: keep the entry alive and report new offset.
        async with state.lock:
            upload.uploading = False
        await send_response(
            writer, 204, b"",
            content_type="application/octet-stream",
            extra_headers={
                "Upload-Offset": str(new_offset),
                "Cache-Control": "no-store",
            },
        )
        return

    failure = await _finalize_completed_upload(state, owning_session, upload)
    if failure == "hash_mismatch":
        state.increment_metric("upload_put_rejected_total")
        await send_response(writer, 422, json_bytes({"error": "hash_mismatch"}))
        return

    log_event(
        "upload_patch_complete",
        session_id=owning_session.session_id,
        upload_id=upload_id,
        size=upload.size,
        sha256=upload.sha256_observed or "",
    )
    await send_response(
        writer, 200,
        json_bytes(
            {
                "upload_id": upload_id,
                "received": upload.received,
                "sha256": upload.sha256_observed,
            }
        ),
        extra_headers={
            "Upload-Offset": str(new_offset),
        },
    )


async def handle_upload_pull(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    headers: dict[str, str],
    query: dict[str, list[str]],
    upload_id: str,
) -> None:
    if method != "GET":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return
    state.increment_metric("upload_pull_total")

    token_header = bearer_token(headers)
    token_query = (query.get("token") or [None])[0]
    pull_token = token_query or token_header
    if not pull_token:
        state.increment_metric("upload_pull_rejected_total")
        await send_response(writer, 403, json_bytes({"error": "invalid_token"}))
        return

    async with state.lock:
        upload: Optional[PendingUpload] = None
        owning_session: Optional[Session] = None
        for session in state.sessions.values():
            candidate = session.pending_uploads.get(upload_id)
            if candidate is not None:
                upload = candidate
                owning_session = session
                break
        if upload is None or owning_session is None:
            state.increment_metric("upload_pull_rejected_total")
            await send_response(writer, 404, json_bytes({"error": "not_found"}))
            return
        if upload.delivered:
            state.increment_metric("upload_pull_rejected_total")
            await send_response(writer, 410, json_bytes({"error": "gone"}))
            return
        if not secrets.compare_digest(pull_token, upload.pull_token):
            state.increment_metric("upload_pull_rejected_total")
            await send_response(writer, 403, json_bytes({"error": "invalid_token"}))
            return
        if upload.received != upload.size:
            state.increment_metric("upload_pull_rejected_total")
            await send_response(writer, 409, json_bytes({"error": "not_complete"}))
            return
        # Mark delivered *before* streaming so a second concurrent pull
        # cannot race us into a double-send.
        upload.delivered = True

    try:
        data = upload.path.read_bytes()
    except OSError as exc:
        state.increment_metric("upload_pull_rejected_total")
        log_event(
            "upload_pull_failed",
            session_id=owning_session.session_id,
            upload_id=upload_id,
            error=str(exc),
        )
        async with state.lock:
            _remove_upload(owning_session, upload, reason="read_failed")
        await send_response(writer, 500, json_bytes({"error": "read_failed"}))
        return

    extra: dict[str, str] = {
        "X-Ghostty-Upload-Name": urllib.parse.quote(upload.name, safe=""),
        "X-Ghostty-Upload-SHA256": upload.sha256_observed or "",
    }
    try:
        await send_response(
            writer,
            200,
            data,
            content_type="application/octet-stream",
            extra_headers=extra,
        )
    finally:
        # The entry is already flagged delivered=True (set earlier under
        # the lock to defeat double-pull). If send_response raised mid-
        # write (client hung up, broken pipe) we still must remove the
        # staging file — otherwise the consumed pull token would leave
        # an orphan file on disk that cleanup_loop wouldn't touch until
        # TTL, even though the upload is no longer reachable.
        async with state.lock:
            _remove_upload(owning_session, upload, reason="pulled")
    log_event(
        "upload_pull",
        session_id=owning_session.session_id,
        upload_id=upload_id,
        size=upload.size,
    )


async def forward_to_clients(session: Session, opcode: int, payload: bytes) -> None:
    session.append_backlog(opcode, payload)
    if opcode not in (0x1, 0x2):
        return
    for channel in list(session.clients.values()):
        channel.try_enqueue(opcode, payload)


async def client_sender(channel: ClientChannel, state: RelayState, session_id: str) -> None:
    """Drain ``channel.queue`` to the underlying socket.

    A queued ``None`` indicates that the channel was dropped for exceeding
    its byte cap; the sender closes the socket with the slow-consumer close
    code and exits, so the client read loop unwinds and removes itself from
    the session.
    """
    try:
        while True:
            item = await channel.queue.get()
            if item is None:
                state.increment_metric("slow_consumer_drop_total")
                log_event(
                    "slow_consumer_drop",
                    session_id=session_id,
                    queued_bytes=channel.queued_bytes,
                    max_bytes=channel.max_bytes,
                )
                await ws_close_with_code(channel.writer, 4408, "slow_consumer")
                return
            opcode, payload = item
            try:
                if opcode == 0x1:
                    await ws_send_text(channel.writer, payload.decode("utf-8", "replace"))
                elif opcode == 0x2:
                    await ws_send_binary(channel.writer, payload)
            except Exception:
                return
            finally:
                channel.queued_bytes = max(0, channel.queued_bytes - len(payload))
    except asyncio.CancelledError:
        return


async def ws_agent_loop(
    state: RelayState,
    session: Session,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    last_pong_at: dict,
) -> None:
    try:
        while True:
            try:
                opcode, payload = await ws_read_frame(
                    reader, max_frame_bytes=state.config.max_frame_bytes
                )
            except (asyncio.IncompleteReadError, ConnectionResetError, ValueError):
                break
            session.last_seen_at = time.time()
            if opcode == 0x8:
                break
            if opcode == 0x9:
                await ws_send_frame(writer, 0xA, payload)
                continue
            if opcode == 0xA:
                last_pong_at["value"] = time.time()
                continue
            if opcode in (0x1, 0x2):
                # `name_update` is a control frame consumed by the relay
                # alone: it updates Session.name (which feeds /api/sessions)
                # without being forwarded or appended to the backlog. The
                # macOS host emits it when the user left the sharing name
                # field blank, so the session list mirrors the PTY title.
                if opcode == 0x1 and _handle_name_update(state, session, payload):
                    continue
                await forward_to_clients(session, opcode, payload)
    finally:
        async with state.lock:
            session.online = False
            session.agent_writer = None
            session.last_seen_at = time.time()
            clients = list(session.clients.keys())
            session.clients.clear()
        state.increment_metric("agent_disconnect_total")
        log_event("agent_disconnected", session_id=session.session_id, client_count=len(clients))
        for client in clients:
            await ws_close(client)
        await ws_close(writer)


async def ws_client_loop(
    state: RelayState,
    session: Session,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    last_pong_at: dict,
) -> None:
    try:
        while True:
            try:
                opcode, payload = await ws_read_frame(
                    reader, max_frame_bytes=state.config.max_frame_bytes
                )
            except (asyncio.IncompleteReadError, ConnectionResetError, ValueError):
                break
            session.last_seen_at = time.time()
            if opcode == 0x8:
                break
            if opcode == 0x9:
                await ws_send_frame(writer, 0xA, payload)
                continue
            if opcode == 0xA:
                last_pong_at["value"] = time.time()
                continue
            agent_writer = session.agent_writer
            if not agent_writer:
                continue
            if opcode == 0x1:
                await ws_send_text(agent_writer, payload.decode("utf-8", "replace"))
            elif opcode == 0x2:
                await ws_send_binary(agent_writer, payload)
    finally:
        session.clients.pop(writer, None)
        state.increment_metric("client_disconnect_total")
        log_event("client_disconnected", session_id=session.session_id, remaining_clients=len(session.clients))
        if not session.clients and session.agent_writer:
            try:
                await ws_send_text(session.agent_writer, json.dumps({"type": "client_disconnect"}))
            except Exception:
                pass
        await ws_close(writer)


async def replay_backlog(session: Session, channel: ClientChannel) -> None:
    # Diagnostic: which frame types are we replaying and how many bytes
    # each. The hello/appearance preserve fix lives or dies based on
    # whether these entries actually survive across screen checkpoints,
    # and there's no easy way to introspect backlog state from outside.
    summary = []
    for opcode, payload in session.backlog:
        kind = "bin"
        if opcode == 0x1:
            try:
                decoded = json.loads(payload.decode("utf-8"))
                kind = (
                    decoded.get("type", "txt")
                    if isinstance(decoded, dict)
                    else "txt"
                )
            except (UnicodeDecodeError, json.JSONDecodeError):
                kind = "txt"
        summary.append(f"{kind}:{len(payload)}")
    log_event(
        "replay_backlog",
        session_id=session.session_id,
        entries=len(session.backlog),
        kinds=",".join(summary),
    )
    for opcode, payload in session.backlog:
        if opcode in (0x1, 0x2):
            channel.try_enqueue(opcode, payload)


async def handle_ws_agent(
    state: RelayState,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    headers: dict[str, str],
    query: dict[str, list[str]],
) -> None:
    session_id = (query.get("id") or [None])[0]
    token = bearer_token(headers)
    if not session_id or not token:
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing agent credentials"}))
        return

    async with state.lock:
        session = state.sessions.get(session_id)
        if not session or session.agent_token != token:
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "invalid agent token"}))
            return
        if session.expires_at <= time.time():
            state.increment_metric("auth_rejected_total")
            state.increment_metric("expired_session_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "expired agent token"}))
            return
        session.online = True
        session.last_seen_at = time.time()
        session.agent_writer = writer

    await websocket_handshake(writer, headers)
    state.increment_metric("agent_connect_total")
    log_event("agent_connected", session_id=session.session_id)
    # Any upload_ready frames that landed while the agent was offline are
    # drained now, before the agent's normal read loop starts. This is
    # what keeps an upload from getting stuck if the agent flapped during
    # the PUT.
    await _drain_pending_upload_ready(state, session)
    last_pong_at = {"value": time.time()}
    background_tasks = [
        asyncio.create_task(
            watch_token_expiry(session, writer, state.config.token_expiry_check_seconds)
        ),
        asyncio.create_task(
            watch_heartbeat(
                writer,
                last_pong_at,
                state.config.ping_interval_seconds,
                state.config.ping_timeout_seconds,
            )
        ),
    ]
    try:
        await ws_agent_loop(state, session, reader, writer, last_pong_at)
    finally:
        for task in background_tasks:
            task.cancel()
        for task in background_tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


async def handle_ws_client(
    state: RelayState,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    headers: dict[str, str],
    query: dict[str, list[str]],
) -> None:
    session_id = (query.get("id") or [None])[0]
    query_token = (query.get("token") or [None])[0]
    header_token = bearer_token(headers)
    token = query_token or header_token
    if not session_id or not token:
        state.increment_metric("auth_rejected_total")
        await send_response(writer, 401, json_bytes({"error": "missing client credentials"}))
        return

    async with state.lock:
        session = state.sessions.get(session_id)
        if not session:
            await send_response(writer, 404, json_bytes({"error": "session not found"}))
            return
        if session.expires_at <= time.time():
            state.increment_metric("auth_rejected_total")
            state.increment_metric("expired_session_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "expired client token"}))
            return
        using_user_token = token == session.user_token
        if using_user_token and not state.config.allow_user_token_client_access:
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "user token client access disabled"}))
            return
        if using_user_token and not state.is_valid_user_token(token):
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "invalid user token"}))
            return
        if token not in (session.client_token, session.user_token):
            state.increment_metric("auth_rejected_total")
            await send_response(writer, 401, json_bytes({"error": "invalid client token"}))
            return
        if len(session.clients) >= state.config.max_clients_per_session:
            await send_response(writer, 503, json_bytes({"error": "client capacity reached"}))
            return
        channel = ClientChannel(writer, state.config.client_send_buffer_bytes)
        session.clients[writer] = channel
        session.last_seen_at = time.time()

    await websocket_handshake(writer, headers)
    state.increment_metric("client_connect_total")
    log_event("client_connected", session_id=session.session_id, client_count=len(session.clients))
    sender_task = asyncio.create_task(client_sender(channel, state, session.session_id))
    await replay_backlog(session, channel)
    # Tell the agent a fresh viewer just joined so it can re-emit a
    # current-state snapshot. Older relays (and agents) just ignore this
    # frame, so it's safe to send unconditionally.
    if session.agent_writer:
        try:
            await ws_send_text(
                session.agent_writer,
                json.dumps({"type": "client_connected"}),
            )
        except Exception:
            pass
    last_pong_at = {"value": time.time()}
    background_tasks = [
        asyncio.create_task(
            watch_token_expiry(session, writer, state.config.token_expiry_check_seconds)
        ),
        asyncio.create_task(
            watch_heartbeat(
                writer,
                last_pong_at,
                state.config.ping_interval_seconds,
                state.config.ping_timeout_seconds,
            )
        ),
    ]
    try:
        await ws_client_loop(state, session, reader, writer, last_pong_at)
    finally:
        for task in background_tasks:
            task.cancel()
        sender_task.cancel()
        for task in background_tasks + [sender_task]:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


def resolve_static_path(static_root: pathlib.Path, target_path: str) -> Optional[pathlib.Path]:
    if target_path == "/ghostty-vt.wasm":
        built_wasm = pathlib.Path(__file__).resolve().parents[3] / "zig-out" / "bin" / "ghostty-vt.wasm"
        if built_wasm.exists() and built_wasm.is_file():
            return built_wasm

    path = target_path if target_path != "/" else "/index.html"
    resolved = (static_root / path.lstrip("/")).resolve()
    if static_root not in resolved.parents and resolved != static_root / "index.html":
        return None
    if not resolved.exists() or not resolved.is_file():
        return None
    return resolved


async def serve_static(static_root: pathlib.Path, writer: asyncio.StreamWriter, target_path: str) -> None:
    resolved = resolve_static_path(static_root, target_path)
    if not resolved:
        await send_response(writer, 404, b"not found", "text/plain; charset=utf-8")
        return

    content_type = {
        ".html": "text/html; charset=utf-8",
        ".js": "application/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".wasm": "application/wasm",
    }.get(resolved.suffix, "application/octet-stream")
    await send_response(writer, 200, resolved.read_bytes(), content_type)


ADMIN_PATHS = {"/healthz", "/readyz", "/metrics"}


async def handle_connection(
    state: RelayState,
    static_root: pathlib.Path,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    admin: bool = False,
) -> None:
    peer = writer.get_extra_info("peername")
    peer_host = peer[0] if isinstance(peer, tuple) and peer else None
    try:
        method, target, headers = await read_http_head(reader)
    except asyncio.IncompleteReadError:
        writer.close()
        await writer.wait_closed()
        return
    except Exception:
        log_event("bad_request", remote=peer_host)
        await send_response(writer, 400, json_bytes({"error": "bad request"}))
        return

    parsed = urllib.parse.urlparse(target)
    path = parsed.path
    query = urllib.parse.parse_qs(parsed.query)
    upgrade = headers.get("upgrade", "").lower()
    client_ip = resolve_client_ip(peer_host, headers, state.config.trusted_proxies)
    admin_listener_enabled = state.config.admin_port > 0

    # Establish CORS for the rest of this request. send_response reads
    # the ContextVar and merges these into the response headers; the
    # OPTIONS preflight is short-circuited here so handlers don't need
    # to know about it.
    cors_headers = build_cors_headers(headers.get("origin", "").strip())
    if cors_headers:
        _cors_headers_ctx.set(cors_headers)
    if method == "OPTIONS":
        if not cors_headers:
            await send_response(writer, 403, b"", "text/plain")
            return
        requested = headers.get("access-control-request-headers", "")
        await send_response(
            writer,
            204,
            b"",
            "text/plain",
            extra_headers={
                "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, HEAD, OPTIONS",
                "Access-Control-Allow-Headers": requested or "Authorization, Content-Type",
                "Access-Control-Max-Age": "86400",
            },
        )
        return

    # Upload PUT and PATCH both stream their body so files larger than
    # max_body_bytes are still allowed. Everything else reads the body
    # up-front under the legacy cap. HEAD has no body so the cheap
    # consume path is fine.
    streaming_body = (
        method in {"PUT", "PATCH"} and path.startswith("/api/upload/")
    )
    if streaming_body:
        body = b""
    else:
        try:
            body = await read_http_body(
                reader, headers, max_body_bytes=state.config.max_body_bytes
            )
        except Exception:
            log_event("bad_request", remote=peer_host, path=path)
            await send_response(writer, 400, json_bytes({"error": "bad request"}))
            return

    if admin:
        # Admin listener serves only health/readiness/metrics. Everything
        # else is rejected so the operator surface is small and predictable.
        if path == "/healthz":
            await send_response(writer, 200, json_bytes({"ok": True}))
            return
        if path == "/readyz":
            async with state.lock:
                await send_response(writer, 200, json_bytes({
                    "ok": not state.shutting_down,
                    "sessions": len(state.sessions),
                    "uptime_seconds": int(time.time() - state.started_at),
                }))
            return
        if path == "/metrics":
            async with state.lock:
                await send_response(
                    writer,
                    200,
                    state.metrics_text().encode("utf-8"),
                    "text/plain; version=0.0.4; charset=utf-8",
                )
            return
        await send_response(writer, 404, b"not found", "text/plain; charset=utf-8")
        return

    # When the dedicated admin listener is enabled, the public listener must
    # never expose the operator-only endpoints.
    if path in ADMIN_PATHS and admin_listener_enabled:
        await send_response(writer, 404, b"not found", "text/plain; charset=utf-8")
        return

    if path == "/healthz":
        await send_response(writer, 200, json_bytes({"ok": True}))
        return
    if path == "/readyz":
        async with state.lock:
            await send_response(writer, 200, json_bytes({
                "ok": not state.shutting_down,
                "sessions": len(state.sessions),
                "uptime_seconds": int(time.time() - state.started_at),
            }))
        return
    if path == "/metrics":
        async with state.lock:
            await send_response(
                writer,
                200,
                state.metrics_text().encode("utf-8"),
                "text/plain; version=0.0.4; charset=utf-8",
            )
        return

    is_upload_init = path == "/api/upload/init"
    is_upload_resource = (
        path.startswith("/api/upload/")
        and not is_upload_init
        # /api/upload/<id> or /api/upload/<id>/pull
    )
    rate_limited_paths = {
        "/api/register",
        "/api/sessions",
        "/ws/agent",
        "/ws/client",
        "/api/upload/init",
        "/api/app/android",
        "/api/app/android/grant",
    }
    if path in rate_limited_paths or is_upload_resource:
        async with state.lock:
            limited, retry_after = state.should_rate_limit(client_ip)
            if limited:
                state.increment_metric("rate_limited_total")
                log_event(
                    "rate_limited",
                    remote=client_ip,
                    path=path,
                    retry_after=retry_after,
                )
                await send_response(
                    writer,
                    429,
                    json_bytes({"error": "rate limited"}),
                    extra_headers={"Retry-After": str(retry_after)},
                )
                return

    if upgrade == "websocket" and path == "/ws/agent":
        await handle_ws_agent(state, reader, writer, headers, query)
        return
    if upgrade == "websocket" and path == "/ws/client":
        await handle_ws_client(state, reader, writer, headers, query)
        return

    if path == "/api/register":
        await handle_register(state, writer, method, body)
        return
    if path == "/api/sessions":
        await handle_sessions(state, writer, method, headers)
        return
    if path == "/api/app/android":
        await handle_apk_download(state, writer, method, headers, query)
        return
    if path == "/api/app/android/grant":
        await handle_apk_grant(state, writer, method, headers)
        return
    if is_upload_init:
        await handle_upload_init(state, writer, method, body, headers)
        return
    if is_upload_resource:
        rest = path[len("/api/upload/"):]
        if rest.endswith("/pull"):
            upload_id = rest[: -len("/pull")]
            if not upload_id:
                await send_response(writer, 404, json_bytes({"error": "not_found"}))
                return
            await handle_upload_pull(state, writer, method, headers, query, upload_id)
            return
        upload_id = rest
        if "/" in upload_id or not upload_id:
            await send_response(writer, 404, json_bytes({"error": "not_found"}))
            return
        if method == "PUT":
            await handle_upload_put(state, reader, writer, headers, upload_id)
            return
        if method == "PATCH":
            await handle_upload_patch(state, reader, writer, headers, upload_id)
            return
        if method == "HEAD":
            await handle_upload_head(state, writer, headers, upload_id)
            return
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return

    await serve_static(static_root, writer, path)


async def main() -> None:
    parser = argparse.ArgumentParser(description="Ghostty session sharing relay prototype")
    parser.add_argument("--host", default=env_str("GHOSTTY_RELAY_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=env_int("GHOSTTY_RELAY_PORT", 18080))
    parser.add_argument("--offline-ttl", type=float, default=env_float("GHOSTTY_RELAY_OFFLINE_TTL", 300.0))
    parser.add_argument("--token-ttl", type=float, default=env_float("GHOSTTY_RELAY_TOKEN_TTL", 300.0))
    parser.add_argument("--max-body-bytes", type=int, default=env_int("GHOSTTY_RELAY_MAX_BODY_BYTES", DEFAULT_MAX_BODY_BYTES))
    parser.add_argument("--max-sessions", type=int, default=env_int("GHOSTTY_RELAY_MAX_SESSIONS", DEFAULT_MAX_SESSIONS))
    parser.add_argument("--max-clients-per-session", type=int, default=env_int("GHOSTTY_RELAY_MAX_CLIENTS_PER_SESSION", DEFAULT_MAX_CLIENTS_PER_SESSION))
    parser.add_argument("--max-frame-bytes", type=int, default=env_int("GHOSTTY_RELAY_MAX_FRAME_BYTES", DEFAULT_MAX_FRAME_BYTES))
    parser.add_argument("--rate-limit-requests", type=int, default=env_int("GHOSTTY_RELAY_RATE_LIMIT_REQUESTS", DEFAULT_RATE_LIMIT_REQUESTS))
    parser.add_argument("--rate-limit-window-seconds", type=float, default=env_float("GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS", DEFAULT_RATE_LIMIT_WINDOW_SECONDS))
    parser.add_argument(
        "--allow-user-token-client-access",
        action="store_true",
        default=env_bool("GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS", False),
    )
    parser.add_argument(
        "--allow-public-bind",
        action="store_true",
        default=env_bool("GHOSTTY_RELAY_ALLOW_PUBLIC_BIND", False),
    )
    parser.add_argument(
        "--trusted-proxies",
        default=env_str("GHOSTTY_RELAY_TRUSTED_PROXIES", ""),
        help="Comma-separated IPs/CIDRs whose X-Forwarded-For header is trusted.",
    )
    parser.add_argument(
        "--token-expiry-check-seconds",
        type=float,
        default=env_float("GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS", 30.0),
    )
    parser.add_argument(
        "--ping-interval-seconds",
        type=float,
        default=env_float("GHOSTTY_RELAY_PING_INTERVAL_SECONDS", 30.0),
    )
    parser.add_argument(
        "--ping-timeout-seconds",
        type=float,
        default=env_float("GHOSTTY_RELAY_PING_TIMEOUT_SECONDS", 60.0),
    )
    parser.add_argument(
        "--client-send-buffer-bytes",
        type=int,
        default=env_int("GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES", 1024 * 1024),
    )
    parser.add_argument(
        "--admin-host",
        default=env_str("GHOSTTY_RELAY_ADMIN_HOST", "127.0.0.1"),
        help="Bind host for the admin listener (health/readiness/metrics).",
    )
    parser.add_argument(
        "--admin-port",
        type=int,
        default=env_int("GHOSTTY_RELAY_ADMIN_PORT", 0),
        help="Bind port for the admin listener; 0 keeps admin endpoints on the public listener.",
    )
    parser.add_argument(
        "--static-root",
        default=env_str(
            "GHOSTTY_RELAY_STATIC_ROOT",
            str(pathlib.Path(__file__).resolve().parent.parent / "web"),
        ),
    )
    parser.add_argument(
        "--upload-max-bytes",
        type=int,
        default=env_int("GHOSTTY_RELAY_UPLOAD_MAX_BYTES", DEFAULT_UPLOAD_MAX_BYTES),
    )
    parser.add_argument(
        "--upload-session-max-bytes",
        type=int,
        default=env_int(
            "GHOSTTY_RELAY_UPLOAD_SESSION_MAX_BYTES",
            DEFAULT_UPLOAD_SESSION_MAX_BYTES,
        ),
    )
    parser.add_argument(
        "--upload-max-pending",
        type=int,
        default=env_int("GHOSTTY_RELAY_UPLOAD_MAX_PENDING", DEFAULT_UPLOAD_MAX_PENDING),
    )
    parser.add_argument(
        "--upload-global-max-pending",
        type=int,
        default=env_int(
            "GHOSTTY_RELAY_UPLOAD_GLOBAL_MAX_PENDING",
            DEFAULT_UPLOAD_GLOBAL_MAX_PENDING,
        ),
    )
    parser.add_argument(
        "--upload-ttl",
        type=float,
        default=env_float("GHOSTTY_RELAY_UPLOAD_TTL", DEFAULT_UPLOAD_TTL),
    )
    parser.add_argument(
        "--upload-dir",
        default=env_str(
            "GHOSTTY_RELAY_UPLOAD_DIR",
            str(pathlib.Path("/tmp/ghostty-uploads")),
        ),
    )
    args = parser.parse_args()

    if host_requires_public_bind_ack(args.host) and not args.allow_public_bind:
        parser.error(
            "public bind requires --allow-public-bind "
            "(or GHOSTTY_RELAY_ALLOW_PUBLIC_BIND=1)"
        )

    config = RelayConfig(
        host=args.host,
        port=args.port,
        offline_ttl=args.offline_ttl,
        token_ttl=args.token_ttl,
        allowed_user_tokens=load_allowed_user_tokens(),
        allow_user_token_client_access=args.allow_user_token_client_access,
        static_root=pathlib.Path(args.static_root).resolve(),
        max_body_bytes=args.max_body_bytes,
        max_sessions=args.max_sessions,
        max_clients_per_session=args.max_clients_per_session,
        max_frame_bytes=args.max_frame_bytes,
        rate_limit_requests=args.rate_limit_requests,
        rate_limit_window_seconds=args.rate_limit_window_seconds,
        trusted_proxies=parse_trusted_proxies(args.trusted_proxies),
        token_expiry_check_seconds=args.token_expiry_check_seconds,
        ping_interval_seconds=args.ping_interval_seconds,
        ping_timeout_seconds=args.ping_timeout_seconds,
        client_send_buffer_bytes=args.client_send_buffer_bytes,
        admin_host=args.admin_host,
        admin_port=args.admin_port,
        upload_max_bytes=args.upload_max_bytes,
        upload_session_max_bytes=args.upload_session_max_bytes,
        upload_max_pending=args.upload_max_pending,
        upload_global_max_pending=args.upload_global_max_pending,
        upload_ttl=args.upload_ttl,
        upload_dir=pathlib.Path(args.upload_dir).resolve(),
    )
    state = RelayState(config=config)
    static_root = config.static_root

    server = await asyncio.start_server(
        lambda r, w: handle_connection(state, static_root, r, w, admin=False),
        host=config.host,
        port=config.port,
    )
    admin_server = None
    if config.admin_port > 0:
        admin_server = await asyncio.start_server(
            lambda r, w: handle_connection(state, static_root, r, w, admin=True),
            host=config.admin_host,
            port=config.admin_port,
        )

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def begin_shutdown() -> None:
        if state.shutting_down:
            return
        state.shutting_down = True
        log_event("shutdown_requested")
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, begin_shutdown)
        except NotImplementedError:
            pass

    log_event(
        "relay_started",
        host=config.host,
        port=config.port,
        static_root=str(config.static_root),
        auth_mode="token-allowlist" if config.allowed_user_tokens else "accept-any-token",
        configured_user_tokens=len(config.allowed_user_tokens),
        allow_user_token_client_access=config.allow_user_token_client_access,
        offline_ttl=config.offline_ttl,
        token_ttl=config.token_ttl,
        max_body_bytes=config.max_body_bytes,
        max_sessions=config.max_sessions,
        max_clients_per_session=config.max_clients_per_session,
        max_frame_bytes=config.max_frame_bytes,
        rate_limit_requests=config.rate_limit_requests,
        rate_limit_window_seconds=config.rate_limit_window_seconds,
        trusted_proxies=[str(net) for net in config.trusted_proxies],
        token_expiry_check_seconds=config.token_expiry_check_seconds,
        ping_interval_seconds=config.ping_interval_seconds,
        ping_timeout_seconds=config.ping_timeout_seconds,
        client_send_buffer_bytes=config.client_send_buffer_bytes,
        admin_host=config.admin_host,
        admin_port=config.admin_port,
        upload_max_bytes=config.upload_max_bytes,
        upload_session_max_bytes=config.upload_session_max_bytes,
        upload_max_pending=config.upload_max_pending,
        upload_global_max_pending=config.upload_global_max_pending,
        upload_ttl=config.upload_ttl,
        upload_dir=str(config.upload_dir),
    )
    asyncio.create_task(state.cleanup_loop())
    try:
        if admin_server is not None:
            async with server, admin_server:
                await stop_event.wait()
        else:
            async with server:
                await stop_event.wait()
    finally:
        server.close()
        await server.wait_closed()
        if admin_server is not None:
            admin_server.close()
            await admin_server.wait_closed()
    log_event("relay_stopped")


if __name__ == "__main__":
    asyncio.run(main())
