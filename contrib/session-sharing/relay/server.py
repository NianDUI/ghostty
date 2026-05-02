#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import dataclasses
import hashlib
import json
import pathlib
import secrets
import struct
import time
import urllib.parse
from typing import Optional


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


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
    clients: set[asyncio.StreamWriter] = dataclasses.field(default_factory=set)


class RelayState:
    def __init__(self, offline_ttl: float) -> None:
        self.offline_ttl = offline_ttl
        self.sessions: dict[str, Session] = {}
        self.lock = asyncio.Lock()

    async def cleanup_loop(self) -> None:
        while True:
            await asyncio.sleep(5)
            cutoff = time.time() - self.offline_ttl
            async with self.lock:
                expired = [
                    session_id
                    for session_id, session in self.sessions.items()
                    if not session.online and session.last_seen_at < cutoff
                ]
                for session_id in expired:
                    self.sessions.pop(session_id, None)


async def read_http_request(reader: asyncio.StreamReader) -> tuple[str, str, dict[str, str], bytes]:
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
        404: "Not Found",
        405: "Method Not Allowed",
        500: "Internal Server Error",
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


async def ws_read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    header = await reader.readexactly(2)
    first, second = header[0], header[1]
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", await reader.readexactly(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", await reader.readexactly(8))[0]

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


async def handle_register(
    state: RelayState,
    writer: asyncio.StreamWriter,
    method: str,
    body: bytes,
) -> None:
    if method != "POST":
        await send_response(writer, 405, json_bytes({"error": "method not allowed"}))
        return

    try:
        payload = json.loads(body.decode("utf-8"))
        session_id = str(payload["session_id"])
        name = str(payload["name"])
        token = str(payload["token"])
    except Exception:
        await send_response(writer, 400, json_bytes({"error": "invalid json"}))
        return

    now = time.time()
    session = Session(
        session_id=session_id,
        name=name,
        user_token=token,
        agent_token=secrets.token_urlsafe(24),
        client_token=secrets.token_urlsafe(24),
        expires_at=now + 300,
        online=False,
        last_seen_at=now,
    )
    async with state.lock:
        state.sessions[session_id] = session

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
        await send_response(writer, 401, json_bytes({"error": "missing bearer token"}))
        return

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
            if session.user_token == token
        ]

    await send_response(writer, 200, json_bytes(sessions))


async def forward_to_clients(session: Session, opcode: int, payload: bytes) -> None:
    stale: list[asyncio.StreamWriter] = []
    for client in list(session.clients):
        try:
            if opcode == 0x1:
                await ws_send_text(client, payload.decode("utf-8", "replace"))
            elif opcode == 0x2:
                await ws_send_binary(client, payload)
        except Exception:
            stale.append(client)
    for client in stale:
        session.clients.discard(client)


async def ws_agent_loop(
    state: RelayState,
    session: Session,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    try:
        while True:
            opcode, payload = await ws_read_frame(reader)
            session.last_seen_at = time.time()
            if opcode == 0x8:
                break
            if opcode == 0x9:
                await ws_send_frame(writer, 0xA, payload)
                continue
            if opcode in (0x1, 0x2):
                await forward_to_clients(session, opcode, payload)
    finally:
        async with state.lock:
            session.online = False
            session.agent_writer = None
            session.last_seen_at = time.time()
            clients = list(session.clients)
            session.clients.clear()
        for client in clients:
            await ws_close(client)
        await ws_close(writer)


async def ws_client_loop(
    session: Session,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    try:
        while True:
            opcode, payload = await ws_read_frame(reader)
            session.last_seen_at = time.time()
            if opcode == 0x8:
                break
            if opcode == 0x9:
                await ws_send_frame(writer, 0xA, payload)
                continue
            agent_writer = session.agent_writer
            if not agent_writer:
                continue
            if opcode == 0x1:
                await ws_send_text(agent_writer, payload.decode("utf-8", "replace"))
            elif opcode == 0x2:
                await ws_send_binary(agent_writer, payload)
    finally:
        session.clients.discard(writer)
        await ws_close(writer)


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
        await send_response(writer, 401, json_bytes({"error": "missing agent credentials"}))
        return

    async with state.lock:
        session = state.sessions.get(session_id)
        if not session or session.agent_token != token:
            await send_response(writer, 401, json_bytes({"error": "invalid agent token"}))
            return
        session.online = True
        session.last_seen_at = time.time()
        session.agent_writer = writer

    await websocket_handshake(writer, headers)
    await ws_agent_loop(state, session, reader, writer)


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
        await send_response(writer, 401, json_bytes({"error": "missing client credentials"}))
        return

    async with state.lock:
        session = state.sessions.get(session_id)
        if not session:
            await send_response(writer, 404, json_bytes({"error": "session not found"}))
            return
        if token not in (session.client_token, session.user_token):
            await send_response(writer, 401, json_bytes({"error": "invalid client token"}))
            return
        session.clients.add(writer)
        session.last_seen_at = time.time()

    await websocket_handshake(writer, headers)
    await ws_client_loop(session, reader, writer)


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


async def handle_connection(
    state: RelayState,
    static_root: pathlib.Path,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    try:
        method, target, headers, body = await read_http_request(reader)
    except asyncio.IncompleteReadError:
        writer.close()
        await writer.wait_closed()
        return
    except Exception:
        await send_response(writer, 400, json_bytes({"error": "bad request"}))
        return

    parsed = urllib.parse.urlparse(target)
    path = parsed.path
    query = urllib.parse.parse_qs(parsed.query)
    upgrade = headers.get("upgrade", "").lower()

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
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--offline-ttl", type=float, default=300.0)
    parser.add_argument(
        "--static-root",
        default=str(pathlib.Path(__file__).resolve().parent.parent / "web"),
    )
    args = parser.parse_args()

    state = RelayState(offline_ttl=args.offline_ttl)
    static_root = pathlib.Path(args.static_root).resolve()

    server = await asyncio.start_server(
        lambda r, w: handle_connection(state, static_root, r, w),
        host=args.host,
        port=args.port,
    )

    print(f"relay listening on http://{args.host}:{args.port}")
    asyncio.create_task(state.cleanup_loop())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
