# Linux Deployment Guide

This document describes the recommended first production-style deployment for
the session sharing relay on a Linux server.

## Command Overview

- `python3 contrib/session-sharing/relay/server.py`
  - starts the relay process with env-based configuration
- `python3 contrib/session-sharing/relay/server.py --host 0.0.0.0 --allow-public-bind`
  - intentionally binds on a non-loopback interface for LAN/public access
- `python3 contrib/session-sharing/relay/smoke_test.py`
  - runs the end-to-end relay smoke test
- `python3 -m py_compile contrib/session-sharing/relay/server.py contrib/session-sharing/relay/smoke_test.py`
  - catches Python syntax/import errors before deployment
- `systemctl enable --now ghostty-relay`
  - installs and starts the relay as a Linux service
- `journalctl -u ghostty-relay -f`
  - tails runtime logs

## Development Startup

For local development on the relay host:

```bash
cd /path/to/ghostty
python3 contrib/session-sharing/relay/server.py --port 18080
```

If you want the relay reachable from other machines on your LAN:

```bash
cd /path/to/ghostty
python3 contrib/session-sharing/relay/server.py --host 0.0.0.0 --port 18080 --allow-public-bind
```

Recommended validation:

```bash
python3 -m py_compile contrib/session-sharing/relay/server.py contrib/session-sharing/relay/smoke_test.py
python3 contrib/session-sharing/relay/smoke_test.py
```

## Topology

Recommended layout:

1. `ghostty-relay` Python process bound to `127.0.0.1:18080`
2. Nginx or Caddy in front
3. TLS terminated at the reverse proxy
4. `systemd` manages the Python process

## Production Startup

Recommended production startup sequence:

1. Copy the env example to `/etc/ghostty-relay.env`
2. Populate the user token allowlist
3. Keep the relay bound to `127.0.0.1:18080`
4. Put Nginx or Caddy in front for `https://` and `wss://`
5. Start the `systemd` unit

Direct process start example:

```bash
cd /opt/ghostty
export GHOSTTY_RELAY_HOST=127.0.0.1
export GHOSTTY_RELAY_PORT=18080
export GHOSTTY_RELAY_USER_TOKENS_FILE=/etc/ghostty-relay.tokens
export GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
export GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
python3 contrib/session-sharing/relay/server.py
```

`systemd`-managed startup:

```bash
sudo cp contrib/session-sharing/relay/deploy/ghostty-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ghostty-relay
```

## Environment

Copy the example file:

```bash
cp contrib/session-sharing/relay/deploy/ghostty-relay.env.example /etc/ghostty-relay.env
```

Adjust values as needed.

If you intentionally want to bind on a public or LAN interface instead of
localhost, also set:

```bash
GHOSTTY_RELAY_ALLOW_PUBLIC_BIND=1
```

Configure valid user tokens through either:

```bash
GHOSTTY_RELAY_USER_TOKENS=token-a,token-b
```

or:

```bash
GHOSTTY_RELAY_USER_TOKENS_FILE=/etc/ghostty-relay.tokens
```

If neither is configured, the relay keeps the current compatibility behavior
and accepts any non-empty user token. For a real server, you should configure
an allowlist.

Browser/client use of the long-lived user token on `/ws/client` is disabled by
default. The recommended path is to use the issued `client_token`.

Only enable user-token client access if you explicitly need it:

```bash
GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS=1
```

Basic per-IP rate limiting is also available:

```bash
GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
```

This currently applies to:

- `/api/register`
- `/api/sessions`
- `/ws/agent`
- `/ws/client`

## systemd

Install the unit:

```bash
sudo cp contrib/session-sharing/relay/deploy/ghostty-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ghostty-relay
```

Check status:

```bash
systemctl status ghostty-relay
journalctl -u ghostty-relay -f
```

## Health Checks

Local checks:

```bash
curl http://127.0.0.1:18080/healthz
curl http://127.0.0.1:18080/readyz
curl http://127.0.0.1:18080/metrics
```

Expected:

- `/healthz` returns `{ "ok": true }`
- `/readyz` returns process readiness and current session count
- `/metrics` returns Prometheus-style plaintext metrics

## Reverse Proxy

Use one of the provided examples:

- `deploy/nginx.conf.example`
- `deploy/Caddyfile.example`

The reverse proxy must forward:

- `/api/register`
- `/api/sessions`
- `/ws/agent`
- `/ws/client`
- static browser assets if you serve them from the relay

## Notes

- Do not expose the Python process directly on the public Internet if you can avoid it.
- Current productionization work does not yet force HTTPS/WSS in-code; enforce that at the reverse proxy.
- Tokens are not logged by design; keep it that way in any local modifications.
