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


def http_text(port: int, method: str, path: str) -> tuple[int, str]:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request(method, path)
    response = conn.getresponse()
    data = response.read()
    status = response.status
    conn.close()
    return status, data.decode("utf-8")


def expect_websocket_upgrade_failure(
    port: int,
    path: str,
    headers: Optional[dict[str, str]] = None,
) -> tuple[int, bytes]:
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
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
        sock.sendall("\r\n".join(lines).encode("utf-8"))
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
        head, _, rest = bytes(response).partition(b"\r\n\r\n")
        status_line = head.split(b"\r\n", 1)[0].decode("utf-8")
        status_code = int(status_line.split(" ")[1])
        content_length = 0
        for raw_line in head.split(b"\r\n")[1:]:
            key, _, value = raw_line.partition(b":")
            if key.strip().lower() == b"content-length":
                content_length = int(value.strip() or b"0")
                break
        body = bytearray(rest)
        while len(body) < content_length:
            chunk = sock.recv(content_length - len(body))
            if not chunk:
                break
            body.extend(chunk)
        return status_code, bytes(body)
    finally:
        sock.close()


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

    public_bind = subprocess.run(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "0.0.0.0",
            "--port",
            str(free_port()),
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert public_bind.returncode != 0
    assert "--allow-public-bind" in public_bind.stderr

    rate_limit_port = free_port()
    rate_limit_env = os.environ.copy()
    rate_limit_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    rate_limit_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(rate_limit_port),
            "--rate-limit-requests",
            "2",
            "--rate-limit-window-seconds",
            "60",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=rate_limit_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(rate_limit_port)
        status, _ = http_json(
            rate_limit_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": "Bearer smoke-user-token"},
        )
        assert status == 200, status
        status, _ = http_json(
            rate_limit_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": "Bearer smoke-user-token"},
        )
        assert status == 200, status
        status, body = http_json(
            rate_limit_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": "Bearer smoke-user-token"},
        )
        assert status == 429, status
        assert body["error"] == "rate limited"
    finally:
        rate_limit_process.terminate()
        try:
            rate_limit_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            rate_limit_process.kill()
            rate_limit_process.wait(timeout=5)

    port = free_port()
    env = os.environ.copy()
    env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--token-ttl",
            "1",
            "--max-sessions",
            "1",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        wait_for_server(port)

        status, health = http_json(port, "GET", "/healthz")
        assert status == 200, status
        assert health["ok"] is True

        status, ready = http_json(port, "GET", "/readyz")
        assert status == 200, status
        assert ready["ok"] is True
        assert ready["sessions"] == 0

        status, metrics = http_text(port, "GET", "/metrics")
        assert status == 200, status
        assert "ghostty_relay_sessions " in metrics
        assert "ghostty_relay_register_requests_total " in metrics

        user_token = "smoke-user-token"
        session_id = secrets.token_hex(8)
        session_name = "Smoke Session"

        status, invalid_register = http_json(
            port,
            "POST",
            "/api/register",
            {
                "session_id": secrets.token_hex(8),
                "name": "Invalid Token Session",
                "token": "bad-token",
            },
        )
        assert status == 401, status
        assert invalid_register["error"] == "invalid user token"

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

        status, invalid_list = http_json(
            port,
            "GET",
            "/api/sessions",
            headers={"Authorization": "Bearer bad-token"},
        )
        assert status == 401, status
        assert invalid_list["error"] == "invalid user token"

        status, capacity_error = http_json(
            port,
            "POST",
            "/api/register",
            {
                "session_id": secrets.token_hex(8),
                "name": "Second Session",
                "token": user_token,
            },
        )
        assert status == 503, status
        assert capacity_error["error"] == "session capacity reached"

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

        status, payload = expect_websocket_upgrade_failure(
            port,
            f"/ws/client?id={session_id}",
            headers={"Authorization": f"Bearer {user_token}"},
        )
        assert status == 401, status
        assert b"user token client access disabled" in payload

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

        time.sleep(1.2)

        status, sessions = http_json(
            port,
            "GET",
            "/api/sessions",
            headers={"Authorization": f"Bearer {user_token}"},
        )
        assert status == 200, status
        assert sessions == []

        status, payload = expect_websocket_upgrade_failure(
            port,
            f"/ws/client?id={session_id}&token={client_token}",
        )
        assert status == 401, status
        assert b"expired client token" in payload

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
