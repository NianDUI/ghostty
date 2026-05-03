# Session Sharing Relay Production Plan

## Scope

This plan focuses on taking the current Python relay prototype in
`contrib/session-sharing/relay/server.py` to a state that is suitable for
running on a Linux server behind HTTPS/WSS.

The goal is not "planet-scale infrastructure." The goal is a deployable,
observable, minimally hardened service that can reliably support real users.

## Status Snapshot

Completed:

- Linux-friendly env/config model
- Health/readiness endpoints
- Prometheus-style `/metrics`
- Structured logs without token leakage
- Request body / frame / session / client limits
- Token TTL and expiry enforcement
- User token allowlist support
- Default localhost bind plus explicit public-bind acknowledgement
- Default prohibition on user-token direct `/ws/client` access
- Per-IP fixed-window rate limiting
- Linux deployment artifacts:
  - `DEPLOY.md`
  - `ghostty-relay.service`
  - `ghostty-relay.env.example`
  - `nginx.conf.example`
  - `Caddyfile.example`
- Relay smoke test covering register/list/WebSocket/expiry/limits

Still remaining before calling the relay "production-ready":

- Desktop/browser side production-mode UX around relay trust and TLS errors
- Stronger upstream identity model than static allowlists if needed
- Decide whether Python remains the deployed implementation or is replaced later
- Optional persistence/audit story
- Broader operational validation on a real Linux host

## Current State

What exists today:

- Single-process Python relay
- In-memory session registry
- `POST /api/register`
- `GET /api/sessions`
- `/ws/agent`
- `/ws/client`
- Backlog replay for new browser clients
- Client-disconnect signal back to the desktop agent
- Static file serving for the web client
- Basic smoke test for register/list/WebSocket forwarding

What blocks production deployment today:

- No structured logging
- No health/readiness endpoints
- No deployment packaging or service unit
- No environment-based config model
- No request size / connection limits
- No explicit server-authentication policy for desktop/browser clients
- No token expiry enforcement on every relevant path
- No reverse-proxy deployment guidance
- No persistence strategy beyond process memory
- No operational documentation for Linux

## Target Deployment Model

Recommended first production topology:

1. Linux VM or bare-metal host
2. `ghostty-relay` Python process bound to `127.0.0.1:<relay-port>`
3. Nginx or Caddy in front
4. TLS termination at the reverse proxy
5. `https://relay.example.com`
6. `wss://relay.example.com`
7. `systemd` manages process lifecycle

Why this topology:

- Keeps Python process off the public interface
- Lets the reverse proxy handle TLS, headers, and request buffering
- Fits the current implementation without forcing a rewrite first
- Matches the current browser and desktop client assumptions

## Phase 1: Make The Current Python Relay Deployable

Status: largely complete

Deliverables:

- Environment-variable based configuration
- Explicit bind host/port defaults for server deployment
- Health endpoint: `GET /healthz`
- Readiness endpoint: `GET /readyz`
- Structured logs with timestamps and event names
- Token-safe logging policy
- Configurable static root
- Configurable offline TTL
- Configurable backlog limits
- Configurable maximum body size
- Configurable maximum concurrent clients per session
- Configurable maximum sessions in memory
- Graceful shutdown handling

Implementation notes:

- Keep CLI flags, but let env vars override or provide the production path
- Do not log bearer tokens, agent tokens, or client tokens
- Emit one log line per important event:
  - register
  - agent connected
  - agent disconnected
  - client connected
  - client disconnected
  - session expired
  - request rejected
- Include safe identifiers only:
  - session_id
  - online/offline
  - remote address if available
  - counts

Definition of done:

- Relay can be launched under `systemd`
- Relay exposes health/readiness probes
- Relay can be configured without editing code
- Relay emits useful logs without leaking secrets

## Phase 2: Enforce Security Boundaries

Status: partially complete

Deliverables:

- Enforce trusted server identity for all clients:
  - desktop agent must connect only over `https` / `wss`
  - TLS certificate and hostname validation must succeed
  - no production fallback to plain `http` / `ws`
- Enforce token expiry for:
  - `/ws/agent`
  - `/ws/client`
  - session listing semantics where applicable
- Enforce relay-side authentication for every caller:
  - desktop registration requires valid user token
  - `/ws/agent` requires valid agent token tied to the session
  - `/ws/client` requires valid client token or explicitly allowed user token
- Bind issued tokens to session identity and role:
  - agent token cannot be reused as client token
  - client token cannot be reused as agent token
  - token must match the target session ID
- Reject stale or malformed registration payloads
- Require explicit trust boundary:
  - either only bind to localhost
  - or require `--allow-public-bind`
- Input validation:
  - session ID format
  - session name length
  - token length caps
- Limit resource abuse:
  - max frame size
  - max request body size
  - max sessions per user token
  - max client fan-out per session
- Optional origin allowlist for browser WebSocket clients

Current implementation status:

- Done:
  - token expiry enforcement
  - role-bound token paths
  - localhost-by-default binding
  - explicit public bind acknowledgement
  - request/frame/session/client limits
  - user token allowlist
  - default disablement of user-token `/ws/client` access
- Remaining:
  - strict production-mode TLS expectation on desktop/browser sides
  - optional browser origin allowlist
  - stricter payload shape constraints if needed

Implementation notes:

- Current tokens are random enough, but lifecycle enforcement is incomplete
- Current prototype allows local insecure transport for development; production mode must reject that
- Desktop and browser clients must treat relay certificate validation failure as fatal
- Relay should sign or mint role-specific short-lived tokens server-side; clients must never self-assert role
- Token expiry should be checked on every new WebSocket connection
- If a session expires while offline, it should be cleaned eagerly
- If an agent reconnects with a new registration, replace the old live session cleanly

Definition of done:

- A random third-party server cannot impersonate the relay without a trusted certificate
- A random caller cannot connect as agent or client without the correct role-bound token
- Expired tokens cannot open new client or agent sessions
- Relay resists trivial resource exhaustion from oversized requests/frames
- Public-facing deployment defaults are no longer foot-guns

## Phase 3: Linux Deployment Artifacts

Status: complete for first Linux rollout

Deliverables:

- `systemd` service unit
- Example environment file
- Example Nginx config
- Example Caddy config
- Deployment README for Linux
- Log rotation guidance

Recommended files:

- `contrib/session-sharing/relay/deploy/ghostty-relay.service`
- `contrib/session-sharing/relay/deploy/ghostty-relay.env.example`
- `contrib/session-sharing/relay/deploy/nginx.conf.example`
- `contrib/session-sharing/relay/deploy/Caddyfile.example`
- `contrib/session-sharing/relay/DEPLOY.md`

Definition of done:

- A Linux operator can deploy this without reading source code
- Service survives reboot
- TLS reverse proxy setup is documented and reproducible

## Phase 4: Persistence and Session Semantics

Status: decision deferred

Decision point:

- If the relay is only meant for active live sessions, in-memory storage may be enough
- If sessions should survive process restart or support better auditability, add persistence

Minimum acceptable first step:

- Keep session state in memory
- Persist nothing
- Document that relay restart drops all live sessions

Optional next step:

- Add a small SQLite backing store for:
  - registered sessions
  - expiry timestamps
  - last_seen_at
  - audit-safe metadata

Do not persist:

- raw PTY backlog by default
- long-lived plaintext tokens unless there is a clear need and encryption story

## Phase 5: Observability

Status: good first baseline in place

Deliverables:

- Counters or log-derived metrics for:
  - active sessions
  - active agents
  - active clients
  - rejected auth attempts
  - expired sessions
  - reconnects
  - backlog replay count
- Startup configuration summary without secrets
- Optional Prometheus-style `/metrics` endpoint if desired

Current implementation status:

- Done:
  - `/metrics`
  - startup config summary without secrets
  - auth/connect/disconnect/rejection counters
- Remaining:
  - richer reconnect/backlog metrics only if operationally needed

Definition of done:

- An operator can answer:
  - Is the relay up?
  - Are agents connected?
  - Are clients connecting?
  - Are auth failures spiking?
  - Is the process leaking sessions or clients?

## Phase 6: Validation

Status: baseline complete, can expand later

Required tests:

- Unit tests for config parsing and defaults
- Unit tests for token expiry checks
- Unit tests for request/body/frame limits
- Smoke test for health/readiness endpoints
- Smoke test for reverse-proxy deployment assumptions if practical
- Existing relay smoke test kept green

Recommended manual Linux validation:

1. Start service under `systemd`
2. Verify `curl http://127.0.0.1:<port>/healthz`
3. Verify reverse proxy serves `https://relay.example.com/`
4. Verify `wss://relay.example.com/ws/client` upgrades successfully
5. Verify browser and desktop client still interoperate
6. Kill relay process and confirm `systemd` restart behavior

## Startup Commands

Development:

```bash
cd /path/to/ghostty
python3 -m py_compile contrib/session-sharing/relay/server.py contrib/session-sharing/relay/smoke_test.py
python3 contrib/session-sharing/relay/smoke_test.py
python3 contrib/session-sharing/relay/server.py --port 18080
```

Production-style local process:

```bash
cd /opt/ghostty
export GHOSTTY_RELAY_HOST=127.0.0.1
export GHOSTTY_RELAY_PORT=18080
export GHOSTTY_RELAY_USER_TOKENS_FILE=/etc/ghostty-relay.tokens
export GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
export GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
python3 contrib/session-sharing/relay/server.py
```

Production `systemd` startup:

```bash
sudo cp contrib/session-sharing/relay/deploy/ghostty-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ghostty-relay
sudo systemctl status ghostty-relay
```

## Proposed Order Of Execution

1. Phase 1: deployable process hardening
2. Phase 2: security boundaries and limits
3. Phase 3: Linux deployment artifacts
4. Phase 6: validation for the above
5. Phase 4: persistence decision
6. Phase 5: richer observability

## Recommended Immediate Next Step

Implement Phase 1 first in the existing Python relay:

- env/config model
- `/healthz`
- `/readyz`
- structured logging
- graceful shutdown
- request/session/client limits

That gives a meaningful Linux deployment baseline without forcing a relay rewrite yet.
