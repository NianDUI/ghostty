# Session Sharing Relay

This directory contains the current Python relay implementation plus the contract expected by the macOS session sharing client.

## Quick Start

### Development Startup

Build the WASM terminal parser the browser client expects:

```bash
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

Start the relay for local development:

```bash
python3 contrib/session-sharing/relay/server.py --port 18080
```

Then open:

`http://<your-lan-ip>:18080/`

Command purpose:

- `zig build -Demit-lib-vt ...`
  - builds `zig-out/bin/ghostty-vt.wasm` for the browser terminal
- `python3 .../server.py --port 18080`
  - starts the Python relay and serves the browser client / APIs / WebSockets

### Production-Style Startup

Run the relay behind Nginx or Caddy and keep the Python process on localhost:

```bash
export GHOSTTY_RELAY_HOST=127.0.0.1
export GHOSTTY_RELAY_PORT=18080
export GHOSTTY_RELAY_USER_TOKENS_FILE=/etc/ghostty-relay.tokens
export GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
export GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
python3 contrib/session-sharing/relay/server.py
```

Recommended production path:

- run the relay under `systemd`
- terminate TLS at Nginx or Caddy
- expose only `https://` and `wss://` publicly

See [DEPLOY.md](DEPLOY.md) for the full Linux deployment flow, including
the TLS layout choice (letsencrypt vs self-signed + trust anchor pin).

## Notes

- The relay currently still allows plain HTTP/WS for local development.
- For Linux server deployment, place it behind an HTTPS/WSS reverse proxy.
- The relay now binds to `127.0.0.1` by default for safer server deployment.
- To bind on `0.0.0.0` or another non-loopback host, you must explicitly pass:

```bash
python3 contrib/session-sharing/relay/server.py --host 0.0.0.0 --allow-public-bind
```

- If `zig-out/bin/ghostty-vt.wasm` exists, the relay also serves it at `/ghostty-vt.wasm` for the browser client.
- New browser clients receive a replay of the recent agent output backlog so the terminal is not blank on first connect.
- When the last browser client disconnects, the relay sends a `client_disconnect` control frame back to the agent so the desktop side can restore its original terminal size.
- The relay exposes:
  - `GET /healthz`
  - `GET /readyz`
  - `GET /metrics`
- The relay now supports environment-based configuration for Linux deployment.
- The relay validates user tokens through:
  - `GHOSTTY_RELAY_USER_TOKENS`
  - `GHOSTTY_RELAY_USER_TOKENS_FILE`
- Browser/client use of the long-lived user token on `/ws/client` is now disabled by default.
- To re-enable that compatibility path, set:

```bash
GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS=1
```

- The relay now enforces:
  - request body size limits
  - WebSocket frame size limits
  - max sessions in memory
  - max clients per session
  - fixed-window per-IP request rate limiting on API/WebSocket entrypoints
  - token expiry checks for session listing and new WebSocket connections

### Validation Commands

Smoke test:

```bash
python3 contrib/session-sharing/relay/smoke_test.py
```

Syntax check:

```bash
python3 -m py_compile contrib/session-sharing/relay/server.py contrib/session-sharing/relay/smoke_test.py
```

Linux deployment guide:

```bash
cat contrib/session-sharing/relay/DEPLOY.md
```

Example environment variables:

```bash
cat contrib/session-sharing/relay/deploy/ghostty-relay.env.example
```

## REST

`POST /api/register`

Request body:

```json
{
  "session_id": "uuid",
  "name": "Ghostty-20260502-133700",
  "token": "user-token"
}
```

Response body:

```json
{
  "session_id": "uuid",
  "agent_token": "one-time-agent-token",
  "client_token": "short-lived-client-token",
  "expires_at": "2026-05-02T13:37:30Z"
}
```

`GET /api/sessions`

Headers:

`Authorization: Bearer <user-token>`

Response body:

```json
[
  {
    "id": "uuid",
    "name": "Ghostty-20260502-133700",
    "online": true,
    "last_seen_at": "2026-05-02T13:37:30Z"
  }
]
```

## WebSocket

Agent endpoint:

`wss://relay.example.com/ws/agent?id=<session_id>`

Headers:

`Authorization: Bearer <agent_token>`

Client endpoint:

`wss://relay.example.com/ws/client?id=<session_id>&token=<client_token>`

## Frames

Binary frames:

- agent -> client: raw PTY output bytes
- client -> agent: raw terminal input bytes

Text frames:

```json
{ "type": "hello", "id": "uuid", "name": "Ghostty-20260502-133700", "cols": 120, "rows": 32 }
```

```json
{ "type": "ping" }
```

```json
{ "type": "pong", "id": "uuid" }
```

```json
{ "type": "resize", "cols": 80, "rows": 24 }
```

## Environment Variables

- `GHOSTTY_RELAY_HOST`
- `GHOSTTY_RELAY_PORT`
- `GHOSTTY_RELAY_OFFLINE_TTL`
- `GHOSTTY_RELAY_TOKEN_TTL`
- `GHOSTTY_RELAY_ALLOW_PUBLIC_BIND`
- `GHOSTTY_RELAY_USER_TOKENS`
- `GHOSTTY_RELAY_USER_TOKENS_FILE`
- `GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS`
- `GHOSTTY_RELAY_STATIC_ROOT`
- `GHOSTTY_RELAY_MAX_BODY_BYTES`
- `GHOSTTY_RELAY_MAX_SESSIONS`
- `GHOSTTY_RELAY_MAX_CLIENTS_PER_SESSION`
- `GHOSTTY_RELAY_MAX_FRAME_BYTES`
- `GHOSTTY_RELAY_RATE_LIMIT_REQUESTS`
- `GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS`

## Observability

Prometheus-style metrics are exposed at:

`GET /metrics`

Current metrics include:

- total sessions
- online/offline sessions
- active agents
- active clients
- uptime seconds
- register/auth/connect/disconnect counters
