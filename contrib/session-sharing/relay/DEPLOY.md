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

If you want the relay reachable from other machines on your LAN, bind to
the host's LAN address. Private ranges (10/8, 172.16/12, 192.168/16,
169.254/16, IPv6 fe80::/10, IPv6 fc00::/7) do **not** require
`--allow-public-bind` because they are not routable on the public
internet:

```bash
cd /path/to/ghostty
# Replace 192.168.1.5 with your machine's LAN IP.
python3 contrib/session-sharing/relay/server.py --host 192.168.1.5 --port 18080
```

LAN clients can then point the desktop / browser app at
`http://192.168.1.5:18080` (and the matching `ws://` for the WebSocket
endpoints). The macOS app already trusts http/ws on RFC1918, link-local,
and loopback addresses, so no client-side flag is needed.

If instead you want to listen on every interface (including public ones,
if the host has any), you must opt in explicitly:

```bash
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

### Reverse-Proxy Client IP Trust

When the relay is fronted by Nginx or Caddy, every request the relay sees
arrives from the reverse proxy's address. Without further configuration, the
per-IP rate limiter treats the entire fleet of real clients as one bucket
keyed on the proxy IP — effectively disabling rate limiting in production.

Set `GHOSTTY_RELAY_TRUSTED_PROXIES` to the reverse proxy's address (or a
CIDR covering it). Only requests whose socket peer is in this list have
their `X-Forwarded-For` header honored; everything else continues to use the
socket peer IP, so an untrusted source cannot spoof its IP.

```bash
# Loopback Nginx/Caddy in front of the relay:
GHOSTTY_RELAY_TRUSTED_PROXIES=127.0.0.1

# Multiple trusted proxies / CIDRs are comma-separated:
# GHOSTTY_RELAY_TRUSTED_PROXIES=10.0.0.0/24,2001:db8::/32
```

Both `nginx.conf.example` and `Caddyfile.example` already forward
`X-Forwarded-For`. Without `GHOSTTY_RELAY_TRUSTED_PROXIES`, that header is
ignored and the rate limit only sees the proxy IP.

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

For production, run a dedicated admin listener so operator endpoints are not
part of the public attack surface:

```bash
GHOSTTY_RELAY_ADMIN_HOST=127.0.0.1
GHOSTTY_RELAY_ADMIN_PORT=18081
```

When the admin port is non-zero, the public listener returns `404` for
`/healthz`, `/readyz`, and `/metrics`; only the admin listener serves them.

Local checks (admin listener):

```bash
curl http://127.0.0.1:18081/healthz
curl http://127.0.0.1:18081/readyz
curl http://127.0.0.1:18081/metrics
```

Expected:

- `/healthz` returns `{ "ok": true }`
- `/readyz` returns process readiness and current session count
- `/metrics` returns Prometheus-style plaintext metrics

For backwards compatibility, leaving `GHOSTTY_RELAY_ADMIN_PORT=0` keeps the
admin endpoints on the main listener — useful for development, but in a
public deployment you should always run the dedicated admin listener and
also block `/healthz`, `/readyz`, `/metrics` at the reverse proxy as a
belt-and-suspenders measure (the example Nginx config does this already).

## Long-Lived WebSocket Lifecycle

The relay closes long-lived WebSocket connections in three production-grade
scenarios. All thresholds are configurable; defaults shown:

```bash
# Mid-connection token expiry. The relay re-checks session.expires_at every
# N seconds; on expiry the connection is closed with WS code 4401 so the
# client knows to refresh and reconnect.
GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS=30

# Heartbeat. Server-initiated ping every interval; if no pong arrives within
# the timeout, the connection is closed with WS code 4408. Catches silent
# NAT drops and idle middleboxes.
GHOSTTY_RELAY_PING_INTERVAL_SECONDS=30
GHOSTTY_RELAY_PING_TIMEOUT_SECONDS=60

# Slow-consumer guard. Each client has a per-connection send buffer with a
# byte cap. When the cap is exceeded, that client is dropped (close code
# 4408 "slow_consumer") so it cannot stall fan-out to other clients. Tracked
# by the `ghostty_relay_slow_consumer_drop_total` metric.
GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES=1048576
```

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

### TLS: letsencrypt vs self-signed + trust anchor pin

`nginx.conf.example` ships **layout (B), self-signed + trust anchor pin**
by default because that is what the upstream maintainer deploys. Two
layouts are supported and you should pick one before deploying:

- **Layout (A) — letsencrypt.** Use when the host has a public domain
  and port 80 is reachable from the public internet so HTTP-01
  challenges succeed. Set `server_name` to the real domain, point the
  `ssl_certificate*` directives at the live cert. This is the most
  common choice for typical cloud deployments.
- **Layout (B) — self-signed + trust anchor pin.** Use when HTTP-01 is
  not reachable. The Android APK already pins the upstream maintainer's
  self-signed CA via Network Security Config; desktop browsers can add
  the CA as a trust anchor to skip the "unknown issuer" warning. Cert
  validity is 10 years, SAN must list both the domain and the server IP.
  See `contrib/session-sharing/ghostty-web-client/CLAUDE.md` ("TLS"
  section) for the full decision rationale, the openssl generation
  recipe, and the per-OS trust-anchor install commands.

The default `nginx.conf.example` listens on **port 28443** (matches the
upstream deployment, which uses a non-standard HTTPS port to bypass an
upstream SNI inspector). If you control your network and prefer 443,
change both `listen` lines.

## Notes

- Do not expose the Python process directly on the public Internet if you can avoid it.
- Current productionization work does not yet force HTTPS/WSS in-code; enforce that at the reverse proxy.
- Tokens are not logged by design; keep it that way in any local modifications.
