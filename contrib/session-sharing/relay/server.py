#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
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
SESSION_BACKLOG_LIMIT = 256 * 1024
SESSION_BACKLOG_FRAME_LIMIT = 512
DEFAULT_MAX_BODY_BYTES = 64 * 1024
DEFAULT_MAX_SESSIONS = 4096
DEFAULT_MAX_CLIENTS_PER_SESSION = 8
DEFAULT_MAX_FRAME_BYTES = 256 * 1024
DEFAULT_RATE_LIMIT_REQUESTS = 120
DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 60.0


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

    def append_backlog(self, opcode: int, payload: bytes) -> None:
        if opcode not in (0x1, 0x2) or not payload:
            return

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
            "agent_connect_total": 0,
            "agent_disconnect_total": 0,
            "client_connect_total": 0,
            "client_disconnect_total": 0,
            "auth_rejected_total": 0,
            "expired_session_rejected_total": 0,
            "rate_limited_total": 0,
            "slow_consumer_drop_total": 0,
        }

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
            cutoff = time.time() - self.offline_ttl
            rate_limit_cutoff = time.time() - self.config.rate_limit_window_seconds
            async with self.lock:
                expired = [
                    session_id
                    for session_id, session in self.sessions.items()
                    if not session.online and session.last_seen_at < cutoff
                ]
                for session_id in expired:
                    self.sessions.pop(session_id, None)
                    log_event("session_expired", session_id=session_id)
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


async def read_http_request(
    reader: asyncio.StreamReader,
    *,
    max_body_bytes: int,
) -> tuple[str, str, dict[str, str], bytes]:
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

    length = int(headers.get("content-length", "0"))
    if length > max_body_bytes:
        raise ValueError("request body too large")
    body = await reader.readexactly(length) if length else b""
    return method, target, headers, body


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
        429: "Too Many Requests",
        404: "Not Found",
        405: "Method Not Allowed",
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
    async with state.lock:
        if len(state.sessions) >= state.config.max_sessions and session_id not in state.sessions:
            state.increment_metric("register_rejected_total")
            await send_response(writer, 503, json_bytes({"error": "session capacity reached"}))
            return
        state.sessions[session_id] = session
    log_event("register", session_id=session_id, session_name=name, online=False)

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
        method, target, headers, body = await read_http_request(
            reader,
            max_body_bytes=state.config.max_body_bytes,
        )
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

    if path in {"/api/register", "/api/sessions", "/ws/agent", "/ws/client"}:
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
