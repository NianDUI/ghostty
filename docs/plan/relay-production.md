# Session Sharing Relay Production Plan

## Scope

This plan focuses on taking the current Python relay prototype in
`contrib/session-sharing/relay/server.py` to a state that is suitable for
running on a Linux server behind HTTPS/WSS.

The goal is not "planet-scale infrastructure." The goal is a deployable,
observable, minimally hardened service that can reliably support real users.

## Status Snapshot

Last updated: 2026-05-03

Completed:

- Linux-friendly env/config model
- Health/readiness endpoints
- Prometheus-style `/metrics`
- Structured logs without token leakage
- Request body / frame / session / client limits
- Token TTL and expiry enforcement on new connections
- User token allowlist support
- Default localhost bind plus explicit public-bind acknowledgement
- Default prohibition on user-token direct `/ws/client` access
- Per-IP fixed-window rate limiting (currently keyed on socket peer; see
  Phase 1.5 for the reverse-proxy IP-trust gap)
- Linux deployment artifacts:
  - `DEPLOY.md`
  - `ghostty-relay.service`
  - `ghostty-relay.env.example`
  - `nginx.conf.example`
  - `Caddyfile.example`
- Relay smoke test covering register/list/WebSocket/expiry/limits

Still remaining before calling the relay "production-ready":

- Reverse-proxy IP trust + `X-Forwarded-For` parsing (Phase 1.5)
- Long-lived connection lifecycle: mid-connection token expiry, slow-consumer
  policy, backpressure, heartbeat (Phase 2.5)
- `/metrics` and `/healthz` exposure scoped away from the public listener
  (Phase 3)
- Decide whether Python remains the deployed implementation or is replaced
  later — moved into "Decision Triggers" with explicit conditions
- Optional persistence/audit story — moved into Phase 4 with a decision rule
- Production quantitative baseline (load, latency, memory) — see new section
- Broader operational validation on a real Linux host

## Out of Scope (handled in `session-sharing.md`)

These items used to leak into the relay plan but are client-side concerns:

- Desktop/browser production-mode TLS expectation and trust UX
- Mobile IME, keyboard, and reconnect UX hardening
- `SessionSharingController`-level integration tests on the desktop side

The relay enforces server-side correctness. Client-side TLS posture is the
client's responsibility and lives in `session-sharing.md`.

## Current State

What exists today:

- Single-process Python relay (~890 lines, hand-rolled HTTP/1.1 + WebSocket)
- In-memory session registry
- `POST /api/register`
- `GET /api/sessions`
- `/ws/agent`
- `/ws/client`
- Backlog replay for new browser clients
- Client-disconnect signal back to the desktop agent
- Static file serving for the web client
- Smoke test for register/list/WebSocket forwarding/expiry/limits

What still blocks production deployment:

- Reverse-proxy `X-Forwarded-For` is not parsed; rate limit and access logs
  see only the proxy's IP
- No mid-connection token expiry on long-lived WS connections
- No slow-consumer policy: a stalled browser client can stall fan-out
- No WS heartbeat: silent NAT drops are not detected
- `/metrics` is exposed on the same listener as user traffic
- No production go/no-go quantitative baseline

## Target Deployment Model

Recommended first production topology:

1. Linux VM or bare-metal host
2. `ghostty-relay` Python process bound to `127.0.0.1:<relay-port>`
3. Nginx or Caddy in front
4. TLS termination at the reverse proxy
5. `https://relay.example.com`
6. `wss://relay.example.com`
7. `systemd` manages process lifecycle
8. Reverse proxy sets `X-Forwarded-For`; relay is configured with the proxy's
   IP in `GHOSTTY_RELAY_TRUSTED_PROXIES`

Why this topology:

- Keeps Python process off the public interface
- Lets the reverse proxy handle TLS, headers, and request buffering
- Fits the current implementation without forcing a rewrite first
- Matches the current browser and desktop client assumptions

## Phase 1: Make The Current Python Relay Deployable

Status: complete

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

Definition of done (met):

- Relay can be launched under `systemd`
- Relay exposes health/readiness probes
- Relay can be configured without editing code
- Relay emits useful logs without leaking secrets

## Phase 1.5: Protocol Stack & Reverse-Proxy Trust

Status: not started — required before serious public deployment

### Protocol stack decision

`server.py` hand-rolls HTTP/1.1 parsing, WebSocket handshake, frame parsing,
close handshake, and ping/pong. This is fine as a prototype but is the most
likely place for security or correctness bugs to land.

Decision:

- **Default**: keep the hand-rolled implementation; add fuzz inputs to the
  smoke test (truncated frames, oversized lengths, invalid UTF-8 in text
  frames, malformed close codes) and assert the connection is closed cleanly.
- **Migrate to `websockets` (or `aiohttp`)** when any one of the following
  triggers fires:
  - WS frame parsing surfaces a fuzz/CVE-class bug
  - Close handshake leaks file descriptors under reconnect storms
  - HTTP/1.1 keep-alive interactions cause head-of-line or pipelining bugs
  - We need `permessage-deflate`, subprotocol negotiation, or HTTP/2

The migration is a single-file replacement; it does not change protocol
semantics, only their implementation.

### Reverse-proxy IP trust

Today rate limiting and access logs key on the socket peer address. Behind
Nginx or Caddy that address is the reverse proxy itself, so the entire fleet
of real clients shares one bucket and the rate limit is effectively disabled.

Deliverables:

- Parse `X-Forwarded-For` only when the immediate socket peer is in
  `GHOSTTY_RELAY_TRUSTED_PROXIES` (default empty — never trust by accident).
- Use the resolved client IP for rate limiting and structured log fields.
- Update `nginx.conf.example` and `Caddyfile.example` to set
  `X-Forwarded-For` (Nginx already does; Caddy example needs the comment).
- Update `DEPLOY.md` to spell out: "If `GHOSTTY_RELAY_TRUSTED_PROXIES` is
  unset, the rate limit only sees the proxy's IP."

Definition of done:

- A request from `203.0.113.5` through the trusted proxy is rate-limited as
  `203.0.113.5`.
- A request from an untrusted source cannot spoof its IP via
  `X-Forwarded-For`.
- The deployment example is reproducible end-to-end.

## Phase 2: Enforce Security Boundaries

Status: substantially complete

Deliverables:

- Enforce token expiry at connection time for `/ws/agent` and `/ws/client`
- Enforce relay-side authentication for every caller
- Bind issued tokens to session identity and role:
  - agent token cannot be reused as client token
  - client token cannot be reused as agent token
  - token must match the target session ID
- Reject stale or malformed registration payloads
- Require explicit trust boundary:
  - either only bind to localhost
  - or require `--allow-public-bind`
- Input validation: session ID format, session name length, token length caps
- Limit resource abuse: max frame size, max body size, max sessions per user
  token, max client fan-out per session
- Optional origin allowlist for browser WebSocket clients (deferred to a
  trigger; see Decision Triggers)

Done:

- Token expiry enforcement (connect-time)
- Role-bound token paths
- Localhost-by-default binding
- Explicit public bind acknowledgement
- Request/frame/session/client limits
- User token allowlist
- Default disablement of user-token `/ws/client` access

`--allow-user-token-client-access` is a development-only escape hatch. It
must remain off in any deployment that exposes the relay outside localhost.
`DEPLOY.md` should call this out explicitly.

Remaining (relay-side only — desktop/browser TLS posture is in
`session-sharing.md`):

- Mid-connection token expiry — moved to Phase 2.5
- Optional browser origin allowlist (decision-triggered)
- Stricter payload shape constraints if a fuzz/abuse incident motivates it

Definition of done (met for connect-time concerns):

- A random caller cannot connect as agent or client without the correct
  role-bound token
- Expired tokens cannot open new client or agent sessions
- Relay resists trivial resource exhaustion from oversized requests/frames
- Public-facing deployment defaults are no longer foot-guns

## Phase 2.5: Long-Lived Connection Lifecycle

Status: not started — the largest production-grade gap

Once a WebSocket is established, today the relay is essentially passive:
no token revalidation, no heartbeat, and no slow-consumer policy. Each is a
real production failure mode.

### Mid-connection token expiry

- Track each active WS connection's token expiry
- When the token expires, close the connection with a WS close code that the
  client can recognize as "refresh and reconnect"
- Document client-side expectation: clients must refresh and reconnect on
  this code rather than treating it as a network error

### Slow-consumer / backpressure

- Maintain a per-client send buffer with an explicit byte cap
  (`GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES`, default e.g. 1 MiB)
- When the cap is exceeded:
  - Default policy: drop the slow client (close with a "slow consumer" code)
  - Increment a `slow_consumer_drop_total` metric
  - Never block the agent → fan-out path on a single slow client
- Backlog replay must run on a per-client task without holding the session
  forward lock
- A slow client must not be able to delay any other client by more than a
  bounded queueing delay (target ≤ 100 ms p99 in the load profile defined in
  the Production Quantitative Baseline section)

### Heartbeat

- Server-initiated ping every `GHOSTTY_RELAY_PING_INTERVAL_SECONDS`
  (default 30)
- Close after `GHOSTTY_RELAY_PING_TIMEOUT_SECONDS` (default 60) without pong
- Detects silent NAT drops, idle middleboxes, and half-open TCP

Definition of done:

- A token expiring mid-stream causes the connection to close within
  `GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS` (default 30)
- A stalled client does not increase fan-out latency for other clients
  beyond the documented bound
- A silently dropped TCP connection is reaped within ping timeout
- All three behaviors are covered by smoke tests

## Phase 3: Linux Deployment Artifacts

Status: complete for first Linux rollout, with patches needed for Phase 1.5
and `/metrics` exposure

Deliverables (already shipped):

- `systemd` service unit
- Example environment file
- Example Nginx config
- Example Caddy config
- Deployment README for Linux
- Log rotation guidance

Files:

- `contrib/session-sharing/relay/deploy/ghostty-relay.service`
- `contrib/session-sharing/relay/deploy/ghostty-relay.env.example`
- `contrib/session-sharing/relay/deploy/nginx.conf.example`
- `contrib/session-sharing/relay/deploy/Caddyfile.example`
- `contrib/session-sharing/relay/DEPLOY.md`

Patches required before recommending public deployment:

- Document `GHOSTTY_RELAY_TRUSTED_PROXIES` setup; current Nginx config sets
  `X-Forwarded-For` but the relay does not yet read it
- Restrict `/metrics` and `/healthz` from the public listener via one of:
  - Bind a separate admin listener on `127.0.0.1:<admin-port>`
  - Or block `/metrics` at the reverse proxy with an `allow`/`deny` block
  - Document Basic Auth as an acceptable fallback for the admin endpoints
- Caddyfile example: add `header_up X-Forwarded-For {remote_host}` (Caddy
  forwards by default, but make the contract explicit)

Definition of done (met for the original goal; pending for the patches
above):

- A Linux operator can deploy this without reading source code
- Service survives reboot
- TLS reverse proxy setup is documented and reproducible
- `/metrics` is not part of the public attack surface
- Operator knows how to enable real-IP rate limiting

## Phase 4: Persistence and Session Semantics

Status: decision deferred with explicit triggers

Default position: keep all session state in memory. Restart drops live
sessions. Clients reconnect. Document this clearly. Do not add persistence
on speculation.

Add SQLite-backed session metadata only when at least one trigger fires:

- Operations explicitly requires N-day audit retention of session metadata
  (session_id, created_at, expired_at, created_by)
- A user-visible incident is caused by frequent deploys dropping sessions
- A multi-instance / HA deployment is required

Even when triggered, persist only safe metadata:

- Never persist raw PTY backlog
- Never persist long-lived plaintext tokens — store hashes if anything
- Never persist anything that would let a relay-restart resume a WebSocket
  in place; clients reconnect by design

## Phase 5: Observability

Status: good first baseline in place

Done:

- `/metrics`
- Startup configuration summary without secrets
- Counters for active sessions, agents, clients
- Counters for rejected auth attempts and expired sessions

Trigger-driven additions (do not add until needed):

- Reconnect-rate metrics — when reconnect storms become a real symptom
- Backlog replay metrics — when slow clients become a real symptom
  (Phase 2.5 will likely require at least `slow_consumer_drop_total`)
- Per-route latency histograms — when p99 latency becomes a target

`/metrics` access scope is owned by Phase 3, not Phase 5.

Definition of done (met):

- An operator can answer:
  - Is the relay up?
  - Are agents connected?
  - Are clients connecting?
  - Are auth failures spiking?
  - Is the process leaking sessions or clients?

## Phase 6: Validation

Status: baseline complete, expand as new phases land

Required tests:

- Unit tests for config parsing and defaults
- Unit tests for token expiry checks (connect-time)
- Unit tests for request/body/frame limits
- Smoke test for health/readiness endpoints
- Existing relay smoke test kept green

Add with new phases:

- Phase 1.5: smoke test that a request through a fake trusted proxy is
  rate-limited by the forwarded IP, not the proxy IP
- Phase 1.5: smoke test that an untrusted source cannot spoof
  `X-Forwarded-For`
- Phase 2.5: load test driving N concurrent clients with one deliberately
  stalled, asserting the bounded fan-out latency for the rest
- Phase 2.5: smoke test that a token expiring mid-connection closes the
  connection with the documented close code

Recommended manual Linux validation:

1. Start service under `systemd`
2. Verify `curl http://127.0.0.1:<port>/healthz`
3. Verify reverse proxy serves `https://relay.example.com/`
4. Verify `wss://relay.example.com/ws/client` upgrades successfully
5. Verify browser and desktop client still interoperate
6. Kill relay process and confirm `systemd` restart behavior
7. Verify rate limit triggers per real client IP, not per proxy IP

## Production Quantitative Baseline

Production "go/no-go" needs measured numbers, not aspirations. Floor
targets — anything below these is a regression worth investigating:

- Concurrent sessions per instance: ≥ 100
- Client fan-out per session: ≥ 4
- p99 PTY frame forwarding latency: ≤ 100 ms
- Steady-state memory at the reference workload: ≤ 500 MiB
- Agent reconnect recovery time after a transient disconnect: ≤ 10 s
- Time to detect a silently dropped WS connection: ≤ ping timeout

Reference and headroom measurements from
`contrib/session-sharing/relay/load_test.py`, run 2026-05-03 on a
developer macOS host (single Python process, loopback). Re-run on
production hardware before declaring the relay production-ready:

| Workload | Sessions × fan-out | Frame / interval | Aggregate | p50 | p95 | p99 | Max | Peak RSS | Delivery |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Reference | 100 × 4 | 256 B / 100 ms | ~1 MiB/s fan-out | 1.56 ms | 3.45 ms | 4.72 ms | 9.02 ms | 51 MiB | 97.3% |
| Headroom | 200 × 4 | 1024 B / 50 ms | ~16 MiB/s fan-out | 1.11 ms | 1.89 ms | 2.74 ms | 13.67 ms | 133 MiB | 96.0% |

Both workloads sit well under the 100 ms / 500 MiB floor. The 2-4%
delivery shortfall is agent ramp-up: clients start half a second before
agents, so the first ~half second of expected frames never had a sender.
A more accurate harness would discount that startup window — already
TODO in `load_test.py`.

### Failure-Path Measurements

Steady-state percentiles do not capture the user-visible cost of the
two main failure modes. These come from
`load_test.py --scenario reconnect` and
`load_test.py --scenario silent-drop`:

- **Reconnect MTTR** — from agent socket close to the freshly
  reconnected client receiving the first marker frame. Loopback, agent
  reopens immediately, three runs averaged **0.79 ms**. Real-world
  MTTR is dominated by client backoff and network RTT, not by relay
  code; this number is the server-side ceiling.
- **Silent-drop MTTD** — idle client never reads or sends pong; timer
  measures how long until `ghostty_relay_active_clients` decrements
  via the heartbeat watcher.
  - Smoke config (interval 1 s / timeout 2 s): **1.63 s**
  - Production config (interval 30 s / timeout 60 s): **59.7 s**

  Detection tracks the configured timeout closely, since
  ``last_pong`` is set at connect and the watcher closes the socket as
  soon as ``now − last_pong > timeout``.

Both measurements clear the floor targets above (≤ 10 s reconnect,
≤ ping timeout for silent drops). When a production deployment cannot
meet these floors under its real workload, that becomes a Decision
Trigger to investigate (see the next section).

## Decision Triggers

Centralized so that "deferred" items have an explicit condition rather than
a vague "later":

- **Replace Python relay with an in-repo Zig service** — when sustained CPU
  exceeds 60% under target load, steady-state memory exceeds 1 GiB, or the
  Python GIL becomes a measurable forwarding bottleneck.
- **Replace static user-token allowlist** — when active operator count
  exceeds N (TBD by ops), or operations needs role/organization scoping.
- **Browser origin allowlist** — when a cross-site abuse incident occurs, or
  a deployment requires strict CORS by policy.
- **Persistence (Phase 4)** — see Phase 4 triggers.
- **Migrate hand-rolled HTTP/WS to a library** — see Phase 1.5 triggers.
- **Richer reconnect/backlog observability** — when reconnect or replay
  becomes a real incident class.

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
export GHOSTTY_RELAY_TRUSTED_PROXIES=127.0.0.1
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

1. Phase 1 — done
2. Phase 1.5 — reverse-proxy IP trust + protocol-stack decision recorded
3. Phase 2.5 — long-lived connection lifecycle (token mid-expiry, slow
   consumer, heartbeat)
4. Phase 3 patches — `/metrics` access scope, deploy doc updates for
   trusted proxies and Caddy `X-Forwarded-For`
5. Phase 6 — validation for the above
6. Production Quantitative Baseline — load test against the targets, fill in
   real numbers
7. Phase 4 / Phase 5 expansions — only if their triggers fire

## Recommended Immediate Next Step

Phase 1.5 reverse-proxy trust and Phase 2.5 token mid-expiry are the two
cheapest changes that move the relay from "works on a developer's laptop"
to "safe to put behind real users on the public internet." Both are local
to `server.py` and the deploy docs, and both have well-scoped smoke tests.
Do those next, then run the load test to populate the Production
Quantitative Baseline.
