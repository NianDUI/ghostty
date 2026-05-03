#!/usr/bin/env python3
"""Relay load harness — manual driver for the Production Quantitative Baseline.

This is intentionally not part of ``smoke_test.py``. It boots a relay,
drives N sessions × K fan-out for a fixed duration, and reports
forwarding latency percentiles, peak RSS, and an optional reconnect
recovery measurement. Numbers feed the baseline table in
``docs/plan/relay-production.md``.

Example:

    python3 contrib/session-sharing/relay/load_test.py \\
        --sessions 100 --fan-out 4 --frame-size 256 \\
        --send-interval 0.05 --duration 30
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import http.client
import json
import os
import resource
import secrets
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SERVER = ROOT / "contrib" / "session-sharing" / "relay" / "server.py"
STATIC_ROOT = ROOT / "contrib" / "session-sharing" / "ghostty-web-client" / "dist"
USER_TOKEN = "load-user-token"


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
            conn.getresponse().read()
            conn.close()
            return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("relay server did not start in time")


def register(port: int, session_id: str, name: str) -> dict:
    body = json.dumps(
        {"session_id": session_id, "name": name, "token": USER_TOKEN}
    ).encode()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request(
        "POST",
        "/api/register",
        body=body,
        headers={"Content-Type": "application/json"},
    )
    response = conn.getresponse()
    payload = json.loads(response.read())
    conn.close()
    if response.status != 200:
        raise RuntimeError(f"register failed: {payload}")
    return payload


async def ws_handshake(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    path: str,
    extra_headers: dict[str, str],
) -> None:
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    lines = [
        f"GET {path} HTTP/1.1",
        "Host: 127.0.0.1",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
    ]
    for k, v in extra_headers.items():
        lines.append(f"{k}: {v}")
    lines.append("")
    lines.append("")
    writer.write("\r\n".join(lines).encode())
    await writer.drain()
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = await reader.read(4096)
        if not chunk:
            raise RuntimeError("ws handshake EOF")
        response.extend(chunk)
    head, _, _rest = bytes(response).partition(b"\r\n\r\n")
    if b"101 Switching Protocols" not in head:
        raise RuntimeError(f"ws handshake failed: {head!r}")


async def ws_open(port: int, path: str, extra_headers: dict[str, str]):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    await ws_handshake(reader, writer, path, extra_headers)
    return reader, writer


async def ws_send_binary(writer: asyncio.StreamWriter, payload: bytes) -> None:
    first = 0x82
    length = len(payload)
    if length < 126:
        header = bytes([first, 0x80 | length])
    elif length < (1 << 16):
        header = bytes([first, 0x80 | 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, 0x80 | 127]) + struct.pack("!Q", length)
    mask_key = os.urandom(4)
    masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    writer.write(header + mask_key + masked)
    await writer.drain()


async def ws_read_frame(reader: asyncio.StreamReader, max_frame_bytes: int):
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
        raise RuntimeError("oversize frame")
    mask_key = await reader.readexactly(4) if masked else b""
    payload = await reader.readexactly(length) if length else b""
    if masked:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return opcode, payload


async def agent_pump(
    port: int,
    session_id: str,
    agent_token: str,
    frame_size: int,
    send_interval: float,
    stop_at: float,
) -> None:
    reader, writer = await ws_open(
        port,
        f"/ws/agent?id={session_id}",
        {"Authorization": f"Bearer {agent_token}"},
    )
    try:
        body = b"x" * max(0, frame_size - 8)
        while time.time() < stop_at:
            payload = struct.pack("!Q", time.monotonic_ns()) + body
            try:
                await ws_send_binary(writer, payload)
            except (ConnectionResetError, BrokenPipeError):
                return
            await asyncio.sleep(send_interval)
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


async def client_consume(
    port: int,
    session_id: str,
    client_token: str,
    latency_ns: list,
    received_counter: list,
    stop_at: float,
    max_frame_bytes: int,
) -> None:
    reader, writer = await ws_open(
        port,
        f"/ws/client?id={session_id}&token={client_token}",
        {},
    )
    try:
        while time.time() < stop_at:
            remaining = stop_at - time.time()
            if remaining <= 0:
                return
            try:
                opcode, payload = await asyncio.wait_for(
                    ws_read_frame(reader, max_frame_bytes),
                    timeout=remaining,
                )
            except asyncio.TimeoutError:
                return
            except (asyncio.IncompleteReadError, ConnectionResetError):
                return
            if opcode == 0x2 and len(payload) >= 8:
                sent_ns = struct.unpack("!Q", payload[:8])[0]
                latency_ns.append(time.monotonic_ns() - sent_ns)
                received_counter[0] += 1
            elif opcode == 0x8:
                return
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


def measure_rss_kb(pid: int) -> int:
    try:
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
        return int(result.stdout.strip())
    except (subprocess.CalledProcessError, ValueError, subprocess.TimeoutExpired):
        return 0


def percentile_ns(values: list, pct: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    k = int(len(ordered) * pct / 100)
    return ordered[min(k, len(ordered) - 1)]


def raise_fd_limit(target: int = 4096) -> None:
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft >= target:
        return
    new_soft = min(target, hard if hard != resource.RLIM_INFINITY else target)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (new_soft, hard))
    except (ValueError, OSError):
        pass


async def run_once(args) -> dict:
    port = free_port()
    max_frame_bytes = max(args.frame_size * 4, 256 * 1024)
    process = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--token-ttl",
            "3600",
            "--max-sessions",
            str(args.sessions * 2),
            "--max-clients-per-session",
            str(max(args.fan_out * 2, 4)),
            "--client-send-buffer-bytes",
            str(8 * 1024 * 1024),
            "--max-frame-bytes",
            str(max_frame_bytes),
            "--ping-interval-seconds",
            "0",
            "--ping-timeout-seconds",
            "0",
            "--token-expiry-check-seconds",
            "0",
            "--rate-limit-requests",
            "0",
            "--static-root",
            str(STATIC_ROOT),
        ],
        env={**os.environ, "GHOSTTY_RELAY_USER_TOKENS": USER_TOKEN},
        cwd=str(ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wait_for_server(port)
    try:
        registrations = []
        for i in range(args.sessions):
            session_id = secrets.token_hex(8)
            entry = register(port, session_id, f"Load{i}")
            registrations.append(
                (session_id, entry["agent_token"], entry["client_token"])
            )

        latency_ns: list[int] = []
        received_counter = [0]
        start = time.time()
        stop_at = start + args.duration

        client_tasks = []
        for session_id, _agent_token, client_token in registrations:
            for _ in range(args.fan_out):
                client_tasks.append(
                    asyncio.create_task(
                        client_consume(
                            port,
                            session_id,
                            client_token,
                            latency_ns,
                            received_counter,
                            stop_at,
                            max_frame_bytes,
                        )
                    )
                )
        await asyncio.sleep(0.5)

        agent_tasks = []
        for session_id, agent_token, _client_token in registrations:
            agent_tasks.append(
                asyncio.create_task(
                    agent_pump(
                        port,
                        session_id,
                        agent_token,
                        args.frame_size,
                        args.send_interval,
                        stop_at,
                    )
                )
            )

        # Sample RSS at midpoint and again right before teardown.
        await asyncio.sleep(args.duration / 2)
        rss_mid_kb = measure_rss_kb(process.pid)
        await asyncio.sleep(max(0.0, stop_at - time.time() - 0.5))
        rss_late_kb = measure_rss_kb(process.pid)
        peak_rss_kb = max(rss_mid_kb, rss_late_kb)

        await asyncio.gather(*agent_tasks, return_exceptions=True)
        for task in client_tasks:
            task.cancel()
        await asyncio.gather(*client_tasks, return_exceptions=True)

        expected_per_client = max(1, int(args.duration / max(args.send_interval, 0.001)))
        total_clients = args.sessions * args.fan_out
        expected_total = expected_per_client * total_clients

        return {
            "config": {
                "sessions": args.sessions,
                "fan_out": args.fan_out,
                "frame_size_bytes": args.frame_size,
                "send_interval_seconds": args.send_interval,
                "duration_seconds": args.duration,
            },
            "samples": len(latency_ns),
            "expected_samples": expected_total,
            "delivery_ratio": (len(latency_ns) / expected_total) if expected_total else 0.0,
            "p50_ms": round(percentile_ns(latency_ns, 50) / 1e6, 2),
            "p95_ms": round(percentile_ns(latency_ns, 95) / 1e6, 2),
            "p99_ms": round(percentile_ns(latency_ns, 99) / 1e6, 2),
            "max_ms": round((max(latency_ns) if latency_ns else 0) / 1e6, 2),
            "peak_rss_mib": round(peak_rss_kb / 1024, 1),
            "rss_mid_mib": round(rss_mid_kb / 1024, 1),
            "rss_late_mib": round(rss_late_kb / 1024, 1),
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="Relay load harness")
    parser.add_argument("--sessions", type=int, default=10)
    parser.add_argument("--fan-out", type=int, default=2)
    parser.add_argument("--frame-size", type=int, default=256, help="Bytes per frame, including the 8-byte timestamp prefix.")
    parser.add_argument("--send-interval", type=float, default=0.1, help="Seconds between agent sends.")
    parser.add_argument("--duration", type=float, default=15.0)
    args = parser.parse_args()

    if args.frame_size < 8:
        print("--frame-size must be >= 8 (timestamp prefix)", file=sys.stderr)
        return 1
    if not STATIC_ROOT.exists():
        print("missing built ghostty-web-client dist/", file=sys.stderr)
        return 1

    raise_fd_limit()
    result = asyncio.run(run_once(args))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
