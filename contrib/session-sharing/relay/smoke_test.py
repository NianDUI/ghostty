#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import http.client
import importlib.util
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

    spec = importlib.util.spec_from_file_location("relay_server", str(SERVER))
    relay_module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = relay_module
    spec.loader.exec_module(relay_module)
    for bind_host, expected_ack in [
        ("localhost", False),
        ("127.0.0.1", False),
        ("::1", False),
        ("0.0.0.0", True),
        ("::", True),
        ("192.168.1.5", False),
        ("10.0.0.5", False),
        ("172.16.0.1", False),
        ("172.31.255.255", False),
        ("169.254.1.5", False),
        ("fe80::1", False),
        ("fd00::1", False),
        ("8.8.8.8", True),
        ("2001:4860:4860::8888", True),
    ]:
        actual = relay_module.host_requires_public_bind_ack(bind_host)
        assert actual == expected_ack, (bind_host, "expected", expected_ack, "got", actual)

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

    forwarded_port = free_port()
    forwarded_env = os.environ.copy()
    forwarded_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    forwarded_env["GHOSTTY_RELAY_TRUSTED_PROXIES"] = "127.0.0.1"
    forwarded_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(forwarded_port),
            "--rate-limit-requests",
            "1",
            "--rate-limit-window-seconds",
            "60",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=forwarded_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(forwarded_port)
        auth = "Bearer smoke-user-token"
        status, _ = http_json(
            forwarded_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": auth, "X-Forwarded-For": "1.2.3.4"},
        )
        assert status == 200, status
        status, _ = http_json(
            forwarded_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": auth, "X-Forwarded-For": "1.2.3.4"},
        )
        assert status == 429, status
        # A different forwarded IP gets its own bucket from the trusted proxy.
        status, _ = http_json(
            forwarded_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": auth, "X-Forwarded-For": "5.6.7.8"},
        )
        assert status == 200, status
    finally:
        forwarded_process.terminate()
        try:
            forwarded_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            forwarded_process.kill()
            forwarded_process.wait(timeout=5)

    expiry_port = free_port()
    expiry_env = os.environ.copy()
    expiry_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    expiry_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(expiry_port),
            "--token-ttl",
            "0.6",
            "--token-expiry-check-seconds",
            "0.2",
            "--ping-interval-seconds",
            "0",
            "--ping-timeout-seconds",
            "0",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=expiry_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(expiry_port)
        expiry_session_id = secrets.token_hex(8)
        status, register = http_json(
            expiry_port,
            "POST",
            "/api/register",
            {
                "session_id": expiry_session_id,
                "name": "Expiry Session",
                "token": "smoke-user-token",
            },
        )
        assert status == 200, status
        agent = WebSocketClient(
            expiry_port,
            f"/ws/agent?id={expiry_session_id}",
            headers={"Authorization": f"Bearer {register['agent_token']}"},
        )
        close_code = None
        deadline = time.time() + 3.0
        while time.time() < deadline:
            try:
                opcode, payload = agent.receive()
            except (RuntimeError, OSError):
                break
            if opcode == 0x8 and len(payload) >= 2:
                close_code = struct.unpack("!H", payload[:2])[0]
                break
        agent.sock.close()
        assert close_code == 4401, f"expected 4401 token_expired, got {close_code}"
    finally:
        expiry_process.terminate()
        try:
            expiry_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            expiry_process.kill()
            expiry_process.wait(timeout=5)

    heartbeat_port = free_port()
    heartbeat_env = os.environ.copy()
    heartbeat_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    heartbeat_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(heartbeat_port),
            "--token-ttl",
            "30",
            "--token-expiry-check-seconds",
            "0",
            "--ping-interval-seconds",
            "0.2",
            "--ping-timeout-seconds",
            "0.4",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=heartbeat_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(heartbeat_port)
        heartbeat_session_id = secrets.token_hex(8)
        status, register = http_json(
            heartbeat_port,
            "POST",
            "/api/register",
            {
                "session_id": heartbeat_session_id,
                "name": "Heartbeat Session",
                "token": "smoke-user-token",
            },
        )
        assert status == 200, status
        agent = WebSocketClient(
            heartbeat_port,
            f"/ws/agent?id={heartbeat_session_id}",
            headers={"Authorization": f"Bearer {register['agent_token']}"},
        )
        saw_ping = False
        close_code = None
        deadline = time.time() + 3.0
        while time.time() < deadline:
            try:
                opcode, payload = agent.receive()
            except (RuntimeError, OSError):
                break
            if opcode == 0x9:
                saw_ping = True
            elif opcode == 0x8 and len(payload) >= 2:
                close_code = struct.unpack("!H", payload[:2])[0]
                break
        agent.sock.close()
        assert saw_ping, "did not observe heartbeat ping"
        assert close_code == 4408, f"expected 4408 ping_timeout, got {close_code}"
    finally:
        heartbeat_process.terminate()
        try:
            heartbeat_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            heartbeat_process.kill()
            heartbeat_process.wait(timeout=5)

    slow_port = free_port()
    slow_env = os.environ.copy()
    slow_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    slow_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(slow_port),
            "--token-ttl",
            "30",
            "--token-expiry-check-seconds",
            "0",
            "--ping-interval-seconds",
            "0",
            "--ping-timeout-seconds",
            "0",
            "--client-send-buffer-bytes",
            "1024",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=slow_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(slow_port)
        slow_session_id = secrets.token_hex(8)
        status, register = http_json(
            slow_port,
            "POST",
            "/api/register",
            {
                "session_id": slow_session_id,
                "name": "Slow Session",
                "token": "smoke-user-token",
            },
        )
        assert status == 200, status
        agent = WebSocketClient(
            slow_port,
            f"/ws/agent?id={slow_session_id}",
            headers={"Authorization": f"Bearer {register['agent_token']}"},
        )
        slow_client = WebSocketClient(
            slow_port,
            f"/ws/client?id={slow_session_id}&token={register['client_token']}",
        )
        # Single 4 KiB frame on a 1 KiB per-client send buffer must be
        # rejected at enqueue time and result in a slow_consumer close.
        agent.send_binary(b"x" * 4096)
        slow_client.sock.settimeout(3.0)
        close_code = None
        deadline = time.time() + 3.0
        while time.time() < deadline:
            try:
                opcode, payload = slow_client.receive()
            except (RuntimeError, OSError, socket.timeout):
                break
            if opcode == 0x8 and len(payload) >= 2:
                close_code = struct.unpack("!H", payload[:2])[0]
                break
        slow_client.sock.close()
        assert close_code == 4408, f"expected 4408 slow_consumer, got {close_code}"

        status, metrics = http_text(slow_port, "GET", "/metrics")
        assert status == 200, status
        drop_count = None
        for line in metrics.splitlines():
            if line.startswith("ghostty_relay_slow_consumer_drop_total "):
                drop_count = int(line.split(" ")[-1])
                break
        assert drop_count is not None and drop_count >= 1, drop_count
        agent.close()
    finally:
        slow_process.terminate()
        try:
            slow_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            slow_process.kill()
            slow_process.wait(timeout=5)

    admin_public_port = free_port()
    admin_listener_port = free_port()
    admin_env = os.environ.copy()
    admin_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    admin_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(admin_public_port),
            "--admin-host",
            "127.0.0.1",
            "--admin-port",
            str(admin_listener_port),
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=admin_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(admin_public_port)
        # Public listener must hide admin endpoints when a dedicated admin
        # listener is configured.
        for admin_path in ("/healthz", "/readyz", "/metrics"):
            status, _ = http_text(admin_public_port, "GET", admin_path)
            assert status == 404, (admin_path, status)
        # Admin listener serves admin endpoints.
        status, health = http_json(admin_listener_port, "GET", "/healthz")
        assert status == 200, status
        assert health["ok"] is True
        status, ready = http_json(admin_listener_port, "GET", "/readyz")
        assert status == 200, status
        assert ready["ok"] is True
        status, metrics = http_text(admin_listener_port, "GET", "/metrics")
        assert status == 200, status
        assert "ghostty_relay_sessions " in metrics
        # Admin listener rejects everything else (no register/list/static).
        status, _ = http_text(admin_listener_port, "GET", "/api/sessions")
        assert status == 404, status
        status, _ = http_text(admin_listener_port, "GET", "/")
        assert status == 404, status
    finally:
        admin_process.terminate()
        try:
            admin_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            admin_process.kill()
            admin_process.wait(timeout=5)

    fuzz_port = free_port()
    fuzz_env = os.environ.copy()
    fuzz_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    fuzz_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(fuzz_port),
            "--token-ttl",
            "30",
            "--token-expiry-check-seconds",
            "0",
            "--ping-interval-seconds",
            "0",
            "--ping-timeout-seconds",
            "0",
            "--max-frame-bytes",
            "65536",
            "--max-sessions",
            "8",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=fuzz_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(fuzz_port)
        fuzz_session_id = secrets.token_hex(8)
        status, register = http_json(
            fuzz_port,
            "POST",
            "/api/register",
            {
                "session_id": fuzz_session_id,
                "name": "Fuzz Session",
                "token": "smoke-user-token",
            },
        )
        assert status == 200, status
        fuzz_agent_token = register["agent_token"]

        def open_fuzz_agent_socket() -> socket.socket:
            sock = socket.create_connection(("127.0.0.1", fuzz_port), timeout=3.0)
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            lines = [
                f"GET /ws/agent?id={fuzz_session_id} HTTP/1.1",
                "Host: 127.0.0.1",
                "Upgrade: websocket",
                "Connection: Upgrade",
                f"Sec-WebSocket-Key: {key}",
                "Sec-WebSocket-Version: 13",
                f"Authorization: Bearer {fuzz_agent_token}",
                "",
                "",
            ]
            sock.sendall("\r\n".join(lines).encode("utf-8"))
            response = bytearray()
            while b"\r\n\r\n" not in response:
                chunk = sock.recv(4096)
                if not chunk:
                    sock.close()
                    raise RuntimeError("fuzz handshake EOF")
                response.extend(chunk)
            head, _, _rest = bytes(response).partition(b"\r\n\r\n")
            if b"101 Switching Protocols" not in head:
                sock.close()
                raise RuntimeError(f"fuzz handshake failed: {head!r}")
            return sock

        def expect_socket_closed(sock: socket.socket, timeout: float = 2.0) -> bool:
            sock.settimeout(timeout)
            try:
                while True:
                    data = sock.recv(4096)
                    if not data:
                        return True
            except (socket.timeout, OSError):
                return False
            finally:
                try:
                    sock.close()
                except OSError:
                    pass

        def masked(payload: bytes) -> tuple[bytes, bytes]:
            mask = bytes(4)
            return mask, bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

        # 1. Truncated header: announces 8 payload bytes, then half-closes.
        sock = open_fuzz_agent_socket()
        sock.sendall(bytes([0x82, 0x80 | 8]) + bytes(4))
        sock.shutdown(socket.SHUT_WR)
        assert expect_socket_closed(sock), "truncated frame did not close socket"
        time.sleep(0.1)

        # 2. Oversized length: 1 GiB exceeds --max-frame-bytes 65536.
        sock = open_fuzz_agent_socket()
        sock.sendall(bytes([0x82, 0x80 | 127]) + struct.pack("!Q", 1 << 30) + bytes(4))
        assert expect_socket_closed(sock), "oversized frame did not close socket"
        time.sleep(0.1)

        # 3. Invalid UTF-8 in a text frame: server uses errors="replace" so
        #    forwarding does not crash. We follow the bad text frame with a
        #    clean close to verify the connection is still in good state.
        sock = open_fuzz_agent_socket()
        mask, masked_payload = masked(b"\xc3\x28")
        sock.sendall(bytes([0x81, 0x80 | 2]) + mask + masked_payload)
        sock.sendall(bytes([0x88, 0x80 | 0]) + bytes(4))
        assert expect_socket_closed(sock), "invalid UTF-8 path did not close socket"
        time.sleep(0.1)

        # 4. Malformed close: 1-byte close payload (status code needs 2).
        sock = open_fuzz_agent_socket()
        mask, masked_payload = masked(b"\x03")
        sock.sendall(bytes([0x88, 0x80 | 1]) + mask + masked_payload)
        assert expect_socket_closed(sock), "malformed close did not close socket"
        time.sleep(0.1)

        # Sanity: the relay is still alive after every fuzz input above.
        status, health = http_json(fuzz_port, "GET", "/healthz")
        assert status == 200, status
        assert health["ok"] is True
    finally:
        fuzz_process.terminate()
        try:
            fuzz_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fuzz_process.kill()
            fuzz_process.wait(timeout=5)

    spoof_port = free_port()
    spoof_env = os.environ.copy()
    spoof_env["GHOSTTY_RELAY_USER_TOKENS"] = "smoke-user-token"
    # No GHOSTTY_RELAY_TRUSTED_PROXIES: untrusted senders cannot spoof IPs.
    spoof_process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(spoof_port),
            "--rate-limit-requests",
            "1",
            "--rate-limit-window-seconds",
            "60",
            "--static-root",
            str(STATIC_ROOT),
        ],
        cwd=str(ROOT),
        env=spoof_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(spoof_port)
        auth = "Bearer smoke-user-token"
        status, _ = http_json(
            spoof_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": auth, "X-Forwarded-For": "1.2.3.4"},
        )
        assert status == 200, status
        # The untrusted client cannot pick a new bucket via X-Forwarded-For;
        # both requests share the loopback bucket and the second is limited.
        status, _ = http_json(
            spoof_port,
            "GET",
            "/api/sessions",
            headers={"Authorization": auth, "X-Forwarded-For": "9.9.9.9"},
        )
        assert status == 429, status
    finally:
        spoof_process.terminate()
        try:
            spoof_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            spoof_process.kill()
            spoof_process.wait(timeout=5)

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
