#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[3]
SERVER = ROOT / "contrib" / "session-sharing" / "relay" / "server.py"
STATIC_ROOT = ROOT / "contrib" / "session-sharing" / "ghostty-web-client" / "dist"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_for_server(port: int, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            conn.request("GET", "/")
            response = conn.getresponse()
            response.read()
            conn.close()
            return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("relay server did not start in time")


def http_json(
    port: int,
    method: str,
    path: str,
    body: Optional[dict] = None,
    headers: Optional[dict[str, str]] = None,
) -> tuple[int, object]:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request_headers = {"Content-Type": "application/json"}
    if headers:
        request_headers.update(headers)
    conn.request(method, path, body=payload, headers=request_headers)
    response = conn.getresponse()
    data = response.read()
    status = response.status
    conn.close()
    return status, json.loads(data.decode("utf-8"))


class WebSocketClient:
    def __init__(self, port: int, path: str, headers: Optional[dict[str, str]] = None) -> None:
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        lines = [
            f"GET {path} HTTP/1.1",
            "Host: 127.0.0.1",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if headers:
            for header_key, header_value in headers.items():
                lines.append(f"{header_key}: {header_value}")
        lines.append("")
        lines.append("")
        self.sock.sendall("\r\n".join(lines).encode("utf-8"))

        response = self._read_until(b"\r\n\r\n")
        expected = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("utf-8")).digest()
        ).decode("ascii")
        if b"101 Switching Protocols" not in response or expected.encode("ascii") not in response:
            raise RuntimeError(f"websocket handshake failed: {response!r}")

    def _read_until(self, marker: bytes) -> bytes:
        chunks = bytearray()
        while marker not in chunks:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            chunks.extend(chunk)
        return bytes(chunks)

    def _recv_exact(self, count: int) -> bytes:
        data = bytearray()
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise RuntimeError("socket closed while reading frame")
            data.extend(chunk)
        return bytes(data)

    def send_text(self, text: str) -> None:
        payload = text.encode("utf-8")
        self._send_frame(0x1, payload)

    def send_binary(self, payload: bytes) -> None:
        self._send_frame(0x2, payload)

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        first = 0x80 | opcode
        mask_key = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = bytes([first, 0x80 | length])
        elif length < (1 << 16):
            header = bytes([first, 0x80 | 126]) + struct.pack("!H", length)
        else:
            header = bytes([first, 0x80 | 127]) + struct.pack("!Q", length)
        masked = bytes(value ^ mask_key[index % 4] for index, value in enumerate(payload))
        self.sock.sendall(header + mask_key + masked)

    def receive(self) -> tuple[int, bytes]:
        header = self._recv_exact(2)
        first, second = header[0], header[1]
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        payload = self._recv_exact(length) if length else b""
        return opcode, payload

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        finally:
            self.sock.close()


def main() -> int:
    if not STATIC_ROOT.exists():
        print("missing built ghostty-web-client dist/, run npm run build first", file=sys.stderr)
        return 1

    port = free_port()
    process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        wait_for_server(port)

        user_token = "smoke-user-token"
        session_id = secrets.token_hex(8)
        session_name = "Smoke Session"

        status, register = http_json(
            port,
            "POST",
            "/api/register",
            {
                "session_id": session_id,
                "name": session_name,
                "token": user_token,
            },
        )
        assert status == 200, status
        agent_token = register["agent_token"]
        client_token = register["client_token"]

        status, sessions = http_json(
            port,
            "GET",
            "/api/sessions",
            headers={"Authorization": f"Bearer {user_token}"},
        )
        assert status == 200, status
        assert len(sessions) == 1
        assert sessions[0]["name"] == session_name
        assert "last_seen_at" in sessions[0]

        agent = WebSocketClient(
            port,
            f"/ws/agent?id={session_id}",
            headers={"Authorization": f"Bearer {agent_token}"},
        )
        client = WebSocketClient(
            port,
            f"/ws/client?id={session_id}&token={client_token}",
        )

        agent.send_binary(b"hello from agent")
        opcode, payload = client.receive()
        assert opcode == 0x2
        assert payload == b"hello from agent"

        client.send_text("ls\r")
        opcode, payload = agent.receive()
        assert opcode == 0x1
        assert payload.decode("utf-8") == "ls\r"

        client.close()
        opcode, payload = agent.receive()
        assert opcode == 0x1
        control = json.loads(payload.decode("utf-8"))
        assert control["type"] == "client_disconnect"

        agent.close()
        print("relay smoke test passed")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
