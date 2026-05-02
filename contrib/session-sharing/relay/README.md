# Session Sharing Relay Prototype

This directory contains a no-dependency relay prototype plus the contract expected by the macOS session sharing client.

Run it with:

```bash
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
python3 contrib/session-sharing/relay/server.py --host 127.0.0.1 --port 8080
```

Then open:

`http://127.0.0.1:8080/`

Notes:

- This prototype is plain HTTP/WS and is meant for local development.
- For real deployment, place it behind an HTTPS/WSS reverse proxy.
- If `zig-out/bin/ghostty-vt.wasm` exists, the relay also serves it at `/ghostty-vt.wasm` for the browser client.

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
