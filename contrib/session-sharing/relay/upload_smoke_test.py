#!/usr/bin/env python3
"""Smoke test for the file-upload subset of the relay (POST /api/upload/init,
PUT /api/upload/<id>, GET /api/upload/<id>/pull, upload_ready control frame
delivery, and TTL-driven cleanup).

Runs the relay in-process on a free port and exercises every path the
production protocol uses. The existing smoke_test.py covers the
register / ws-agent / ws-client paths; this file is the same shape but
scoped to the upload surface so failures localise immediately.

Exit code 0 == all cases pass, non-zero on the first assertion failure.
"""
from __future__ import annotations

import asyncio
import base64
import dataclasses
import hashlib
import json
import pathlib
import secrets
import socket
import struct
import sys
import time
from typing import Optional

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import server  # noqa: E402

USER_TOKEN = "smoke-token"
SESSION_ID = "smoke-session"
SMALL_PAYLOAD = b"hello upload world\n" * 100
UPLOAD_DIR = pathlib.Path("/tmp/ghostty-upload-smoke")


def _http(host: str, port: int, method: str, path: str,
          body: bytes = b"", headers: Optional[dict] = None
          ) -> tuple[int, bytes]:
    s = socket.create_connection((host, port))
    s.settimeout(10)
    request = (
        f"{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
        f"Connection: close\r\nContent-Length: {len(body)}\r\n"
    )
    for k, v in (headers or {}).items():
        request += f"{k}: {v}\r\n"
    request += "\r\n"
    s.sendall(request.encode() + body)
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    head, _, payload = data.partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0]
    status = int(status_line.split(b" ", 2)[1])
    return status, payload


def _ws_connect(host: str, port: int, path: str, auth: str) -> socket.socket:
    s = socket.create_connection((host, port))
    s.settimeout(10)
    key = base64.b64encode(secrets.token_bytes(16)).decode()
    s.sendall((
        f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\nAuthorization: Bearer {auth}\r\n\r\n"
    ).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise RuntimeError(
                "ws handshake closed early: "
                + buf.decode("utf-8", "replace"))
        buf += chunk
    if b"101" not in buf:
        raise RuntimeError("ws handshake failed: " + buf.decode("utf-8", "replace"))
    return s


def _ws_recv(sock: socket.socket) -> tuple[int, bytes]:
    hdr = b""
    while len(hdr) < 2:
        hdr += sock.recv(2 - len(hdr))
    first, second = hdr[0], hdr[1]
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        ext = b""
        while len(ext) < 2:
            ext += sock.recv(2 - len(ext))
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = b""
        while len(ext) < 8:
            ext += sock.recv(8 - len(ext))
        length = struct.unpack("!Q", ext)[0]
    payload = b""
    while len(payload) < length:
        payload += sock.recv(length - len(payload))
    return opcode, payload


def _ws_recv_text_with_type(sock: socket.socket, expected_type: str,
                             timeout: float = 2.0) -> Optional[dict]:
    """Read text frames from the agent socket until we get one matching the
    expected `type`. Returns None on timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            opcode, payload = _ws_recv(sock)
        except socket.timeout:
            continue
        if opcode != 0x1:
            continue
        try:
            frame = json.loads(payload.decode("utf-8"))
        except Exception:
            continue
        if frame.get("type") == expected_type:
            return frame
    return None


def _make_config(*, upload_ttl: float = 60.0, upload_max: int = 10 * 1024 * 1024,
                  session_max: int = 100 * 1024 * 1024,
                  upload_dir: Optional[pathlib.Path] = None,
                  rate_limit: int = 0) -> server.RelayConfig:
    return server.RelayConfig(
        host="127.0.0.1", port=0,
        offline_ttl=60.0, token_ttl=60.0,
        allowed_user_tokens=frozenset({USER_TOKEN}),
        allow_user_token_client_access=False,
        static_root=server.pathlib.Path("/tmp"),
        max_body_bytes=64 * 1024,
        max_sessions=10, max_clients_per_session=4,
        max_frame_bytes=64 * 1024,
        rate_limit_requests=rate_limit,
        rate_limit_window_seconds=60.0,
        upload_dir=upload_dir or UPLOAD_DIR,
        upload_max_bytes=upload_max,
        upload_session_max_bytes=session_max,
        upload_max_pending=4,
        upload_ttl=upload_ttl,
    )


class _RelayHarness:
    """Boots an in-process relay on a random port for a single test case."""

    def __init__(self, config: server.RelayConfig) -> None:
        self.config = config
        self.state: Optional[server.RelayState] = None
        self.server: Optional[asyncio.base_events.Server] = None
        self.cleanup_task: Optional[asyncio.Task] = None
        self.port: int = 0

    async def __aenter__(self) -> "_RelayHarness":
        self.state = server.RelayState(config=self.config)
        srv = await asyncio.start_server(
            lambda r, w: server.handle_connection(
                self.state, server.pathlib.Path("/tmp"), r, w),
            host="127.0.0.1", port=0,
        )
        self.server = srv
        self.port = srv.sockets[0].getsockname()[1]
        self.cleanup_task = asyncio.create_task(self.state.cleanup_loop())
        await asyncio.sleep(0.05)
        return self

    async def __aexit__(self, *_exc) -> None:
        if self.cleanup_task:
            self.cleanup_task.cancel()
        if self.server:
            self.server.close()
            try:
                await self.server.wait_closed()
            except Exception:
                pass


async def _http_async(port: int, method: str, path: str,
                       body: bytes = b"", headers: Optional[dict] = None
                       ) -> tuple[int, bytes]:
    return await asyncio.to_thread(
        _http, "127.0.0.1", port, method, path, body, headers)


async def _register(port: int) -> dict:
    status, body = await _http_async(
        port, "POST", "/api/register",
        json.dumps({
            "session_id": SESSION_ID, "name": "smoke", "token": USER_TOKEN,
        }).encode(),
        {"Content-Type": "application/json"},
    )
    assert status == 200, (status, body)
    return json.loads(body)


async def _init_upload(port: int, *, name: str, payload: bytes,
                        sha256: Optional[str] = "auto"
                        ) -> tuple[int, dict]:
    body = {
        "session_id": SESSION_ID,
        "name": name,
        "size": len(payload),
    }
    if sha256 == "auto":
        body["sha256"] = hashlib.sha256(payload).hexdigest()
    elif sha256 is not None:
        body["sha256"] = sha256
    status, raw = await _http_async(
        port, "POST", "/api/upload/init",
        json.dumps(body).encode(),
        {"Content-Type": "application/json",
         "Authorization": f"Bearer {USER_TOKEN}"},
    )
    try:
        decoded = json.loads(raw)
    except Exception:
        decoded = {"raw": raw}
    return status, decoded


async def _put_upload(port: int, upload_url: str, payload: bytes
                       ) -> tuple[int, dict]:
    status, raw = await _http_async(
        port, "PUT", upload_url, payload,
        {"Authorization": f"Bearer {USER_TOKEN}",
         "Content-Type": "application/octet-stream"},
    )
    try:
        decoded = json.loads(raw)
    except Exception:
        decoded = {"raw": raw}
    return status, decoded


def _http_with_response_headers(
    host: str, port: int, method: str, path: str,
    body: bytes = b"", headers: Optional[dict] = None,
) -> tuple[int, dict[str, str], bytes]:
    """Variant of _http that also returns the response headers. Used by
    the PATCH/HEAD tests to read Upload-Offset back out."""
    s = socket.create_connection((host, port))
    s.settimeout(10)
    request = (
        f"{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
        f"Connection: close\r\nContent-Length: {len(body)}\r\n"
    )
    for k, v in (headers or {}).items():
        request += f"{k}: {v}\r\n"
    request += "\r\n"
    s.sendall(request.encode() + body)
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    head, _, payload = data.partition(b"\r\n\r\n")
    lines = head.decode("utf-8", "replace").split("\r\n")
    status = int(lines[0].split(" ", 2)[1])
    response_headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" in line:
            k, _, v = line.partition(":")
            response_headers[k.strip().lower()] = v.strip()
    return status, response_headers, payload


async def _patch_chunk(port: int, upload_url: str, offset: int,
                        chunk: bytes) -> tuple[int, dict[str, str], bytes]:
    return await asyncio.to_thread(
        _http_with_response_headers,
        "127.0.0.1", port, "PATCH", upload_url, chunk,
        {"Authorization": f"Bearer {USER_TOKEN}",
         "Content-Type": "application/offset+octet-stream",
         "Upload-Offset": str(offset)},
    )


async def _head_upload(port: int, upload_url: str
                        ) -> tuple[int, dict[str, str]]:
    status, response_headers, _ = await asyncio.to_thread(
        _http_with_response_headers,
        "127.0.0.1", port, "HEAD", upload_url, b"",
        {"Authorization": f"Bearer {USER_TOKEN}"},
    )
    return status, response_headers


# -- Test cases -------------------------------------------------------------

async def case_happy_path() -> None:
    async with _RelayHarness(_make_config()) as harness:
        reg = await _register(harness.port)
        agent = await asyncio.to_thread(
            _ws_connect, "127.0.0.1", harness.port,
            f"/ws/agent?id={SESSION_ID}", reg["agent_token"])
        await asyncio.sleep(0.05)

        status, init = await _init_upload(
            harness.port, name="smoke.txt", payload=SMALL_PAYLOAD)
        assert status == 200, (status, init)

        status, put = await _put_upload(
            harness.port, init["upload_url"], SMALL_PAYLOAD)
        assert status == 200, (status, put)
        assert put["received"] == len(SMALL_PAYLOAD)

        # The agent must receive an upload_ready frame referencing this id.
        frame = await asyncio.to_thread(
            _ws_recv_text_with_type, agent, "upload_ready", 2.0)
        assert frame is not None and frame["upload_id"] == init["upload_id"]
        assert frame["pull_token"] and frame["pull_url"].endswith("/pull")

        # Pull succeeds and returns the exact body.
        status, body = await _http_async(
            harness.port, "GET",
            f"{frame['pull_url']}?token={frame['pull_token']}")
        assert status == 200 and body == SMALL_PAYLOAD

        # Second pull is rejected because the entry was consumed.
        status, _ = await _http_async(
            harness.port, "GET",
            f"{frame['pull_url']}?token={frame['pull_token']}")
        assert status in (404, 410), status
        agent.close()


async def case_oversize_init_rejected() -> None:
    async with _RelayHarness(_make_config()) as harness:
        await _register(harness.port)
        status, body = await _http_async(
            harness.port, "POST", "/api/upload/init",
            json.dumps({
                "session_id": SESSION_ID, "name": "big.bin",
                "size": 11 * 1024 * 1024,
            }).encode(),
            {"Content-Type": "application/json",
             "Authorization": f"Bearer {USER_TOKEN}"},
        )
        assert status == 413, (status, body)
        assert b"size_exceeds_limit" in body


async def case_hash_mismatch_rejected() -> None:
    async with _RelayHarness(_make_config()) as harness:
        reg = await _register(harness.port)
        _ = await asyncio.to_thread(
            _ws_connect, "127.0.0.1", harness.port,
            f"/ws/agent?id={SESSION_ID}", reg["agent_token"])
        await asyncio.sleep(0.05)

        status, init = await _init_upload(
            harness.port, name="forged.txt", payload=SMALL_PAYLOAD,
            sha256="0" * 64)
        assert status == 200, (status, init)
        status, _ = await _put_upload(
            harness.port, init["upload_url"], SMALL_PAYLOAD)
        assert status == 422, status


async def case_size_mismatch_rejected() -> None:
    async with _RelayHarness(_make_config()) as harness:
        await _register(harness.port)
        status, init = await _init_upload(
            harness.port, name="short.txt", payload=SMALL_PAYLOAD)
        assert status == 200
        # Lie about the body length: send only half of what init declared.
        # The PUT handler keys the declared size off Content-Length, so a
        # mismatched length is what surfaces as 409.
        truncated = SMALL_PAYLOAD[: len(SMALL_PAYLOAD) // 2]
        status, _ = await _put_upload(
            harness.port, init["upload_url"], truncated)
        assert status == 409, status


async def case_invalid_name_rejected() -> None:
    async with _RelayHarness(_make_config()) as harness:
        await _register(harness.port)
        # Names that hit the relay's sanitize rejection (path separator,
        # control character, ..) all surface as 400 invalid_payload.
        for bad in ["../escape", "with/slash", "with\x00nul", "..", ".",
                     "with\nnewline"]:
            status, body = await _http_async(
                harness.port, "POST", "/api/upload/init",
                json.dumps({
                    "session_id": SESSION_ID, "name": bad, "size": 16,
                }).encode(),
                {"Content-Type": "application/json",
                 "Authorization": f"Bearer {USER_TOKEN}"},
            )
            assert status == 400, (bad, status, body)


async def case_patch_chunked_happy_path() -> None:
    """Three-chunk PATCH upload completes, agent gets a single
    upload_ready frame for the assembled file."""
    payload = b"abcdefghij" * 600  # 6000 bytes
    chunks = [payload[i:i + 2000] for i in range(0, len(payload), 2000)]
    async with _RelayHarness(_make_config()) as harness:
        reg = await _register(harness.port)
        agent = await asyncio.to_thread(
            _ws_connect, "127.0.0.1", harness.port,
            f"/ws/agent?id={SESSION_ID}", reg["agent_token"])
        await asyncio.sleep(0.05)

        status, init = await _init_upload(
            harness.port, name="chunked.bin", payload=payload)
        assert status == 200
        assert init["chunk_size"] > 0
        assert init["patch_max_bytes"] >= init["chunk_size"]

        offset = 0
        for idx, chunk in enumerate(chunks):
            status, response_headers, body = await _patch_chunk(
                harness.port, init["upload_url"], offset, chunk)
            if idx < len(chunks) - 1:
                assert status == 204, (idx, status, body)
                offset += len(chunk)
                # Server-reported offset must match our running counter.
                assert int(response_headers.get("upload-offset", "-1")) == offset
            else:
                # Last chunk completes the upload: 200 + JSON body.
                assert status == 200, (status, body)
                final = json.loads(body)
                assert final["received"] == len(payload)
                assert final["sha256"] == hashlib.sha256(payload).hexdigest()

        # And the agent must receive exactly one upload_ready frame.
        frame = await asyncio.to_thread(
            _ws_recv_text_with_type, agent, "upload_ready", 2.0)
        assert frame is not None
        assert frame["upload_id"] == init["upload_id"]

        # The pull endpoint serves the reassembled bytes verbatim.
        status, raw = await _http_async(
            harness.port, "GET",
            f"{frame['pull_url']}?token={frame['pull_token']}")
        assert status == 200 and raw == payload
        agent.close()


async def case_patch_resume_after_disconnect() -> None:
    """A client that uploaded the first chunk and never sent the rest
    can use HEAD to discover the resume offset and PATCH from there."""
    payload = b"resume-data-" * 500  # 6000 bytes
    async with _RelayHarness(_make_config()) as harness:
        reg = await _register(harness.port)
        agent = await asyncio.to_thread(
            _ws_connect, "127.0.0.1", harness.port,
            f"/ws/agent?id={SESSION_ID}", reg["agent_token"])
        await asyncio.sleep(0.05)

        status, init = await _init_upload(
            harness.port, name="resume.bin", payload=payload)
        assert status == 200

        # Send only the first 2000 bytes.
        first = payload[:2000]
        status, _, _ = await _patch_chunk(
            harness.port, init["upload_url"], 0, first)
        assert status == 204

        # Resume: HEAD returns the offset we should pick up from.
        status, response_headers = await _head_upload(
            harness.port, init["upload_url"])
        assert status == 200
        assert int(response_headers["upload-offset"]) == 2000
        assert int(response_headers["upload-length"]) == len(payload)

        # Mismatched offset is rejected with 409.
        bad_status, _, _ = await _patch_chunk(
            harness.port, init["upload_url"], 0, payload[2000:3000])
        assert bad_status == 409

        # Now send the rest at the correct offset.
        rest = payload[2000:]
        status, _, body = await _patch_chunk(
            harness.port, init["upload_url"], 2000, rest)
        assert status == 200, (status, body)
        final = json.loads(body)
        assert final["received"] == len(payload)

        frame = await asyncio.to_thread(
            _ws_recv_text_with_type, agent, "upload_ready", 2.0)
        assert frame is not None
        agent.close()


async def case_patch_rejects_missing_content_type() -> None:
    """PATCH without Content-Type: application/offset+octet-stream is
    rejected as 415, per tus 1.0. The relay used to be lenient here."""
    async with _RelayHarness(_make_config()) as harness:
        await _register(harness.port)
        status, init = await _init_upload(
            harness.port, name="bad-ct.txt", payload=SMALL_PAYLOAD)
        assert status == 200
        status, _, _ = await asyncio.to_thread(
            _http_with_response_headers,
            "127.0.0.1", harness.port, "PATCH", init["upload_url"],
            SMALL_PAYLOAD,
            {"Authorization": f"Bearer {USER_TOKEN}",
             "Upload-Offset": "0"},
            # ^ deliberately no Content-Type
        )
        assert status == 415, status


async def case_global_pending_cap_rejected() -> None:
    """Once the global pending pool is full, further init attempts fail
    with 429 / global_pending_full, even on a brand-new session."""
    # Tight per-session and global caps so the test runs fast.
    async with _RelayHarness(_make_config()) as harness:
        # Override the cap on the live state so we don't have to plumb
        # a separate make_config kwarg.
        harness.state.config = dataclasses.replace(
            harness.state.config,
            upload_max_pending=4,
            upload_global_max_pending=2,
        )
        await _register(harness.port)
        # First two inits succeed.
        for i in range(2):
            status, init = await _init_upload(
                harness.port, name=f"f{i}.bin", payload=SMALL_PAYLOAD)
            assert status == 200, (i, status, init)
        # Third one must be rejected — global pool is full.
        status, body = await _init_upload(
            harness.port, name="overflow.bin", payload=SMALL_PAYLOAD)
        assert status == 429, (status, body)
        assert body.get("error") == "global_pending_full"


async def case_patch_rejects_overshoot() -> None:
    """A chunk that would push us past Upload-Length is rejected."""
    payload = b"x" * 100
    async with _RelayHarness(_make_config()) as harness:
        await _register(harness.port)
        status, init = await _init_upload(
            harness.port, name="short.bin", payload=payload)
        assert status == 200

        # Send a chunk twice the declared size at offset 0.
        bigger = payload + b"y" * 100
        status, _, _ = await _patch_chunk(
            harness.port, init["upload_url"], 0, bigger)
        assert status == 413


async def case_ttl_expiry_cleans_files() -> None:
    upload_dir = pathlib.Path("/tmp/ghostty-upload-smoke-ttl")
    if upload_dir.exists():
        for p in upload_dir.iterdir():
            try:
                p.unlink()
            except OSError:
                pass
    async with _RelayHarness(_make_config(
        upload_ttl=0.01, upload_dir=upload_dir,
    )) as harness:
        # Need an agent to be online for the upload_ready frame to land —
        # but the test really cares about the file on disk, not the frame.
        # We skip the WS connect and let the upload sit pending until TTL.
        await _register(harness.port)
        status, init = await _init_upload(
            harness.port, name="ttl.txt", payload=SMALL_PAYLOAD)
        assert status == 200
        status, _ = await _put_upload(
            harness.port, init["upload_url"], SMALL_PAYLOAD)
        assert status == 200
        staged = upload_dir / f"{init['upload_id']}.bin"
        assert staged.exists()

        # cleanup_loop runs every ~5s in production. We have to wait for at
        # least one cycle to see the file vanish. Bumping the sleep to 6.5
        # keeps the test robust without dragging the suite out.
        await asyncio.sleep(6.5)
        assert not staged.exists(), \
            f"expired upload still on disk: {staged}"


# -- Driver -----------------------------------------------------------------

CASES = [
    ("happy_path", case_happy_path),
    ("oversize_init_rejected", case_oversize_init_rejected),
    ("hash_mismatch_rejected", case_hash_mismatch_rejected),
    ("size_mismatch_rejected", case_size_mismatch_rejected),
    ("invalid_name_rejected", case_invalid_name_rejected),
    ("patch_chunked_happy_path", case_patch_chunked_happy_path),
    ("patch_resume_after_disconnect", case_patch_resume_after_disconnect),
    ("patch_rejects_missing_content_type", case_patch_rejects_missing_content_type),
    ("patch_rejects_overshoot", case_patch_rejects_overshoot),
    ("global_pending_cap_rejected", case_global_pending_cap_rejected),
    ("ttl_expiry_cleans_files", case_ttl_expiry_cleans_files),
]


async def amain() -> int:
    failures: list[tuple[str, BaseException]] = []
    for name, case in CASES:
        try:
            await case()
            print(f"[PASS] {name}")
        except BaseException as exc:  # noqa: BLE001
            failures.append((name, exc))
            print(f"[FAIL] {name}: {exc}")
    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print(f"\nAll {len(CASES)} cases passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(amain()))
