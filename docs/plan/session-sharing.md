# Ghostty Session Sharing Plan

## Status Summary

Last updated: 2026-05-04

This is the top-level plan. Relay-side work has its own subplan in
`relay-production.md`; this file does not duplicate it.

Section dashboard:

| Section                   | State                                          | Owner |
| ------------------------- | ---------------------------------------------- | ----- |
| 1. Desktop Host (macOS)   | covered                                        | macOS |
| 1. Desktop Host (GTK)     | not started; trigger-gated                     | Linux |
| 2. Core Bridge / Terminal | covered                                        | Zig   |
| 3. Relay Service          | production-shaped; see `relay-production.md`   | Relay |
| 4. Mobile Web Client      | usable on desktop browser, mobile UX gaps      | Web   |
| 5. Security & Storage     | redaction + Keychain write covered both sides  | macOS |
| 6. Test & Validation      | relay covered, controller / Zig / browser thin | Mixed |

The single biggest blocker for "GA-shippable on macOS + LAN" is
mobile IME / soft keyboard handling (Section 4 P0). The single
biggest blocker for cross-platform is the unstarted GTK host (Section
1 P0 once triggered).

## Current Deliverable Boundary

What works today:

- ✅ macOS desktop starts and stops a shared session, persists settings,
  shows status and reconnect state.
- ✅ A LAN browser (laptop or tablet on a desktop browser) can join the
  shared terminal, see output, and send input.
- ✅ Relay handles trusted-proxy IP forwarding, mid-connection token
  expiry, slow-consumer drop, heartbeat reaping, and admin-listener
  separation. Reference workload of 100 sessions × 4 fan-out runs at
  p99 ≤ 5 ms / RSS ≤ 60 MiB on a developer macOS host (see
  `relay-production.md`).
- ✅ LAN bind without `--allow-public-bind`; macOS client trusts http/ws
  on RFC1918 / loopback.

What does **not** work today:

- ❌ Linux desktop host (no GTK implementation).
- ❌ Mobile soft keyboard / IME flow on iOS / Android browsers.
- ❌ Browser-side automated regression tests.
- ❌ Public-internet deployment without operator effort: the relay
  itself is hardened, but the macOS / browser clients do not yet
  enforce strict TLS posture, so an operator has to police that
  externally.
- ❌ Token refresh on the browser client; sessions are bounded by the
  initial token TTL.

This boundary defines what we can demo, not what we can ship at GA.
See "GA Criteria" below.

## End-to-End Acceptance Flow

The plan is "done at the main flow" when this script passes on macOS
host + browser client, against the LAN relay topology, without manual
tweaks:

1. macOS user opens a shared session — ✅ works
2. Sharing UI displays session URL and status — ✅ works
3. Mobile / desktop browser user opens that URL — ✅ works
4. Browser shows the live terminal, scrolled to the cursor — ✅ works
5. Browser user types a command; macOS user sees it in the terminal — ✅ works
6. macOS user types output; browser user sees it streamed — ✅ works
7. Browser user disconnects; macOS user sees "client disconnected" — ✅ works
8. Browser reconnects after a network blip; sees the buffered backlog — ✅ works (relay backlog replay verified by smoke)
9. macOS host network blips; both ends recover within 10 s — ✅ relay-side MTTR ≤ 1 ms measured; sharing badge now surfaces the live reconnect countdown ("重连中（${seconds}s 后）") so the user sees the backoff progress instead of a static "重连中..."
10. Mobile user opens the same URL on iOS Safari, types via the soft keyboard, sees output — ❌ IME path is broken / unverified
11. macOS host token expires mid-connection; browser is told to refresh — ✅ relay sends WS 4401 close. Browser slow-polls `/api/sessions` with a "session expired, waiting for host" status. macOS host recognizes the 4401 close code, resets the reconnect backoff, and immediately re-runs `registerAndConnect` to fetch a fresh agent token + expires_at without user action.

Steps 9-11 are the gap to "GA-shippable on macOS + LAN."

## GA Criteria

The plan ships when, in addition to the steps above:

1. **Platform coverage**: macOS desktop host plus a browser client
   (both mobile and desktop) work without manual workarounds. GTK is
   desirable but not required for first GA — see Decision Triggers.
2. **Relay**: production-ready per `relay-production.md` floor
   targets. Reference + headroom + reconnect MTTR + silent-drop MTTD
   already met on the developer baseline; needs a re-run on a real
   Linux production host before promoting.
3. **Security posture**: clients enforce TLS scheme rules
   (https/wss outside RFC1918), redact tokens from all logs and error
   surfaces (verified by automated test), and refresh tokens before
   long-lived sessions expire.
4. **Test coverage**: end-to-end flow above runs as a scripted check
   (manual or automated). Controller-level tests on macOS run against
   fakes. Zig raw-byte bridge has at least smoke-level coverage.
   Browser side has smoke automation for the join + input + reconnect
   path.
5. **Observability**: relay metrics + structured logs (already
   shipped), and macOS sharing state surfaces enough information for
   a user to self-diagnose connect failures.

## Out of Scope

These are explicitly **not** in this plan; do not let them creep in:

- Native iOS / Android applications (the browser web client is the
  mobile path).
- Multi-relay HA, anycast, or geo-failover.
- Enterprise SSO / OIDC integration (operator manages user tokens).
- Recording / replaying past sessions for audit (a relay-production
  Phase 4 trigger, but not a session-sharing top-level concern).
- Voice / video / file-transfer extensions.
- Windows desktop host (it does not exist in Ghostty itself yet).

## Plan

### 1. Desktop Host Integration

#### macOS

Status: shippable for LAN; polish + a few hardening items remain.

Done:

- Menu entry + shortcut for toggling session sharing
- Share settings dialog (session name, relay, token, save option)
- Config load/save for `~/.config/ghostty/sharing.conf`
- Per-surface sharing state updates in the UI
- Start/stop flow + reconnect state display
- Raw byte bridge APIs for Ghostty surface IO
- LAN-trusted scheme handling (http/ws for RFC1918, loopback,
  link-local; https/wss enforced for public)
- Token refresh / re-register on relay-side expiry: `handleDisconnect`
  reads `URLSessionWebSocketTask.closeCode` before tearing the task
  down; `SessionSharingControllerRecovery.disconnectAction` recognizes
  4401 (`SessionSharingCloseCode.tokenExpired`), resets the
  reconnect backoff, and reconnects immediately so the next
  `registerAndConnect` fetches a fresh `agent_token` and
  `expires_at` without user action. 4408 (timeout / slow consumer)
  still uses the standard exponential backoff. Covered by the
  `controllerRecoveryDisconnectAction*` Swift Testing cases.
- Actionable sheet error presentation:
  `SessionSharingErrorPresentation.actionableMessage(for:)` collapses
  start-sharing failures to user-actionable Chinese messages instead
  of dumping `error.localizedDescription`. Covers each
  `SessionSharingError` case (including the new
  `userTokenRejected` produced by `parseRegisterResponse` on HTTP
  401), the common `URLError` codes (DNS / connection / timeout /
  offline / TLS), and falls back to a token-redacted description
  for everything else. Covered by the `errorPresentation*` and
  `registerResponseParser*` Swift Testing cases.
- Reconnect-state UX surfaces the scheduled backoff:
  `SharingState.reconnecting` now carries the upcoming delay
  (`case reconnecting(after: TimeInterval)`); the badge text reads
  "重连中（${seconds}s 后）" while the controller is waiting and
  falls back to "重连中..." for the relay-driven 4401 fast-path
  (delay 0). `scheduleReconnect` threads
  `reconnectCoordinator.prepareToSchedule(...).delay` into
  `setState`, so the badge follows the actual scheduled wait
  instead of staying at a static "重连中...". Covered by the
  expanded `sharingStateDerivedPresentation` Swift Testing case.
- Sharing shortcut is now a first-class configurable binding.
  `toggle_session_sharing` is a real binding action across the
  full stack: `src/input/Binding.zig`,
  `src/input/command.zig` (command-palette entry "Share Terminal
  Session"), `src/Surface.zig` (dispatch to apprt),
  `src/apprt/action.zig` + `include/ghostty.h`
  (GHOSTTY_ACTION_TOGGLE_SESSION_SHARING), and macOS
  `Ghostty.App.swift` (`toggleSessionSharing(app:target:)` posts
  back to the focused SurfaceView). `AppDelegate.syncMenuShortcuts`
  calls `syncMenuShortcut(config, action: "toggle_session_sharing", …)`
  so a user `keybind = ⌥⌘S = toggle_session_sharing` overrides the
  menu shortcut, with `EditMenuFallbackShortcut.applyIfMissing`
  preserving the default ⌃⇧S when the user hasn't bound anything.

Remaining:

- (none — open Section 1 macOS items have all been picked up.)

#### GTK / Linux

Status: not started.

Decision trigger: start when **either** of the following holds:

- A Ghostty maintainer commits to maintaining the GTK sharing UI
  long-term (today no one is signed up).
- More than three Linux user requests land in the issue tracker
  asking for the feature.

Until triggered, do not begin GTK work; macOS ships first.

### 2. Core Bridge and Terminal Plumbing

Status: shipped with smoke coverage on the bridge primitives;
threading review and end-to-end resize still TODO.

Done:

- Surface raw-byte input API
- Termio output callback hook
- PTY output bridged to host callback without changing render
  behavior
- WebSocket input bridged back to PTY as raw bytes
- `OutputCallback.invoke` method consolidates the dispatch and is
  covered by Zig tests (default no-op, byte + userdata forwarding,
  empty payload still fires the callback)
- `Message.writeReq` Zig tests cover the small / empty / alloc paths
  and propagate `OutOfMemory` for the large-write path that
  `Surface.sendBytesCallback` runs through
- Output callback concurrency contract is documented on
  `Termio.output_callback` and on `Termio.processOutput`, and
  `processOutputLocked` asserts the first-seen thread ID matches on
  every subsequent call (debug builds only). Under the exec backend
  that thread is always the IO read thread set up in
  `Exec.threadMain` / `threadMainWindows`; manual callers must pick
  one dedicated thread.
- End-to-end resize + control-channel round trip is exercised by
  the relay smoke test: it drives an agent + client through the
  three control frames the host and browser actually exchange —
  agent → client `hello` (carries the host's initial cols/rows),
  client → agent `resize` (browser-driven viewport change), and
  the relay-emitted `client_disconnect` signal that the macOS
  controller uses to restore the original surface size. JSON
  bodies are asserted intact in both directions.

Remaining:

- (none — open Section 2 items have all been picked up.)

### 3. Relay Service

Status: production-shaped Python relay shipped. Detailed status,
hardening phases, deployment artifacts, and quantitative baseline
live in [`relay-production.md`](relay-production.md).

Highlights of what landed since the last revision of this plan:

- Reverse-proxy `X-Forwarded-For` trust + per-real-IP rate limiting
- Long-lived WebSocket lifecycle: token mid-expiry close, heartbeat
  ping/pong, slow-consumer drop with `slow_consumer_drop_total`
- Admin-listener split for `/healthz`, `/readyz`, `/metrics`
- Linux deployment artifacts (`ghostty-relay.service`,
  `nginx.conf.example`, `Caddyfile.example`, `DEPLOY.md`)
- Reference + headroom + reconnect MTTR + silent-drop MTTD
  measurements recorded against Decision Triggers

The previous "Replace prototype with a production service" item is no
longer open. Whether to migrate from Python to in-repo Zig is now a
trigger-gated decision in `relay-production.md`, not an open TODO.

Open relay-side work — token-binding refinements, optional
persistence, fuzz harness, public-host operational validation —
lives in `relay-production.md`.

### 4. Mobile Web Client

Status: usable on a desktop browser; mobile UX has known gaps.

Done:

- Token login + session listing
- Online / offline session selection
- `ghostty-web`-backed terminal page
- Terminal-only session route + browser title updates
- Browser-side reconnect loop for dropped WebSocket sessions
- Terminal resize reporting to relay / agent
- Mobile hidden-input fallback + focus recovery
- Session list display of recent activity time
- Automatic session list refresh + clearer recovery messaging for
  direct session links
- WS close-code classification: 4401 (token_expired) switches the
  reconnect loop to a steady 2-10 s polling cadence with a "session
  expired, waiting for host" status; 4408 (timeout / slow consumer)
  shows "heartbeat lost, reconnecting" and keeps the existing
  exponential backoff. Each reconnect re-fetches `/api/sessions`
  with the user token, so a fresh `client_token` is picked up
  automatically once the host re-registers.
- Mobile auto-scroll under noisy producers (`cat` / `npm install`
  / dense logs) used to queue one `setTimeout(scrollToBottom, 0)`
  per binary frame, dwarfing the actual render cost.
  `createCoalescedScroll` (in `src/scroll.js`) folds back-to-back
  requests into a single `requestAnimationFrame` tick: at most one
  `terminal.scrollToBottom()` per frame, regardless of how many
  frames the relay just delivered. All the
  `setTimeout(scrollTerminalToBottom, 0)` call sites in `main.js`
  now go through `requestMobileBottomScroll()`. Covered by four
  `node --test` cases in
  `ghostty-web-client/test/scroll.test.mjs`.

Remaining:

- **P0** Mobile soft keyboard / IME path. iOS Safari and Android
  Chrome both need verification; today the hidden-input fallback is
  best-effort and breaks on dead-key / CJK input.
- **P1** Reconnect UX validation on a real mobile device (page
  refresh, screen lock, switching tabs).
- **P1** Lower the relay's first-screen replay so a fresh browser
  join doesn't render a visible top-to-bottom scan over a long
  session. `server.py:22-23` currently caches up to `256 KiB` /
  `512` frames per session and `replay_backlog` writes the entire
  buffer through `term.write` on connect. Drop the defaults to
  something closer to "a few screens of recent activity"
  (e.g. `64 KiB` / `256` frames) and promote the caps to env-tunable
  knobs (`GHOSTTY_RELAY_SESSION_BACKLOG_BYTES` /
  `GHOSTTY_RELAY_SESSION_BACKLOG_FRAMES`) so operators can dial
  them per deployment. Trade-off: a late-joining client sees less
  recent history before the next live output from the host.
- **P1** Touch-drag the right-edge scrollbar so phone users get
  parity with mouse users. `ghostty-web`'s built-in scrollbar
  (`dist/ghostty-web.js:2177`, 8 px wide, 4 px right padding) only
  binds `mousedown`, so the thumb is unreachable from a touch
  device. Hit-test `touchstart` on `terminalMount` against the
  scrollbar lane (`canvas.width - 12 .. canvas.width - 4`); when
  inside, translate the touch Y into a viewport line via the same
  geometry the renderer uses (`k = 4`, `M = canvas.height - 8`) and
  call `terminal.scrollToLine(...)`. Outside the lane, fall through
  to the existing free-scroll handler that the touch-swipe work
  already added in `main.js`.
- **P2 Phase 1 (landed)** Viewport snapshot replaces byte-replay
  for the first paint. macOS agent calls
  `ghostty_surface_read_text(.viewport, ...)` after `hello` and on
  every relay-driven `client_connected` signal, base64-encodes
  `\x1b[2J\x1b[H` + the viewport text, and sends it as a `screen`
  control frame. Relay's `append_backlog` detects `type=screen`
  text frames and truncates earlier entries so a late-joining
  client only replays the most recent snapshot plus bytes since;
  `handle_ws_client` also writes `{type:client_connected}` to the
  agent on every join. Browser case `screen` runs
  `terminal.reset()` + `term.write(decoded)`. Covered by the
  `screenSnapshotEncodesBase64WithClearAndHomePrefix` Swift case
  and the `relay smoke_test` checkpoint scenario.
- **P2 Phase 2a (landed)** Snapshot now spans the full host screen
  (history + active) instead of just the viewport. The agent reads
  `GHOSTTY_POINT_SCREEN` (top_left → bottom_right), tail-trims at
  a `\n` boundary so the raw VT byte stream stays under a 32 KiB
  budget — sized so the JSON+base64 wrapping still fits inside the
  relay's default 64 KiB `SESSION_BACKLOG_LIMIT` and never gets
  evicted on its own append. Browser keeps its existing
  `terminal.reset()` + `term.write(decoded)` path; older rows
  scroll off into xterm.js's own scrollback as the newer ones fill
  the visible grid. Covered by
  `screenSnapshotTrimsHistoryAtLineBoundaryWhenOverBudget`.
- **P2 Phase 2b (landed)** True lazy fetch beyond the 32 KiB
  snapshot, decided after rejecting the "scroll the host alongside
  the browser" alternative (host scroll has intrusive side
  effects on the macOS user and conflicts with live PTY
  auto-scroll). Shape that landed:
  - **Protocol**: client → agent
    `{type:"fetch_scrollback", id, before, count}` asks for
    `count` rows older than the `before`-many newest rows.
    Agent → client
    `{type:"scrollback", id, before, count, total, content}`
    echoes `before`, returns the actual emitted row count, the
    agent's current total history length, and base64-encoded VT
    bytes (no clear/home prefix, just rows joined by `\r\n`).
  - **Agent**: `SessionSharingScrollbackPayload.respond` reads
    history via `ghostty_surface_read_text(.history, top_left ↔
    bottom_right)`, splits on `\n`, slices `[total - before -
    count, total - before)`, tail-trims to the same 32 KiB
    budget as the snapshot. Read-only: never moves the host's
    viewport. Inbound dispatch sits in
    `SessionSharingInboundFrameAction.fetchScrollback`. Covered
    by the slicer Swift cases.
  - **Relay**: untouched in code; just passes the new frames.
    Smoke test asserts the round trip.
  - **Browser**: `src/scrollback.js` holds a small replay buffer
    (`olderChunks`, `snapshotBody` with prefix stripped,
    `liveBuffer`, `inflight`, `agentTotal`). On every
    `terminal.onScroll` we run `maybeRequestOlderScrollback`,
    which fires a `fetch_scrollback` whenever the viewport is
    within `SCROLLBACK_TOP_TRIGGER_LINES` of the top, no fetch
    is in flight, and `hasReachedTop` is false. On response we
    prepend the chunk and refresh via `terminal.reset()` +
    `terminal.write(buildReplayBytes())`, where
    `buildReplayBytes()` always emits a single `\x1b[2J\x1b[H`
    prefix followed by older chunks (oldest first), the
    snapshot body, and the live buffer. Covered by
    `test/scrollback.test.mjs`.
  - **UX trade-off**: every fetch causes a full reset+replay
    flash. Acceptable because fetches are user-initiated (scroll
    to top) and bounded by `SCROLLBACK_FETCH_BATCH = 200` rows
    per round-trip.
- **P2 styled readback (landed)** SGR colour preservation in the
  snapshot and scrollback frames. New
  `Surface.dumpStyledTextLocked` runs the `terminal.formatter`
  `ScreenFormatter` with `emit = .vt` + `Extra = .styles` so the
  cell text comes back wrapped in SGR escapes (and OSC 8 hyperlink
  state). Exposed through a new C export
  `ghostty_surface_read_text_styled` in `embedded.zig`,
  declared in `include/ghostty.h`, and the macOS controller
  switched both `SessionSharingScreenSnapshotPayload.capture` and
  `SessionSharingScrollbackPayload.respond` over to the styled
  variant. Also added an idempotent `\r\n` normaliser on the Swift
  side because the styled formatter already emits `\r\n`, so the
  old bare-`\n`-to-`\r\n` rewrite would have corrupted line
  endings into `\r\r\n`. `zig build -Demit-macos-app=false`
  rebuilds `GhosttyKit.xcframework/`; the macOS app picks up the
  new symbol on its next Xcode build. Covered by
  `screenSnapshotIdempotentlyNormalisesCRLF` and
  `scrollbackSlicerNormalisesCRLF` Swift Testing cases.
- **Decision (deferred)** Forking `coder/ghostty-web` to add a
  proper `terminal.prependScrollback(rows)` API and eliminate the
  Phase 2b reset+replay flash. Rejected for now because the work
  spans a third-party WASM build (we don't ship the upstream's
  Zig-to-WASM toolchain), the maintenance overhead of a private
  fork, and the actual user complaint (history depth) is already
  resolved by Phase 2b. Trigger to revisit: the flash is reported
  as a real UX issue on a phone, *or* an upstream PR window opens
  for the prepend-rows API.

Browser-side smoke automation lives in Section 6 (single source of
truth).

### 5. Security and Storage

#### Server-side (relay)

Status: covered. See `relay-production.md` Phase 2 and Phase 2.5.

Done:

- Token-safe logging policy
- Connect-time + mid-connection token expiry
- Role-bound tokens (agent / client cannot be reused as the other)
- Localhost-by-default bind + explicit `--allow-public-bind` for
  wildcard / public binds
- LAN bind (RFC1918, link-local, ULA) does not require an ack
- Request / frame / session / client limits
- User-token allowlist; user-token client access disabled by default

#### Client-side (macOS / browser)

Status: covered.

Done:

- Local config stored with restricted file permissions
- Macros / paths avoid logging token values in the implemented code
  paths
- Browser distinguishes `4401` (token_expired) from `4408` (timeout /
  slow consumer) and from generic close: 4401 enters a slow-poll
  recovery loop that re-fetches the session list with the user token,
  so the next `client_token` is picked up automatically when the host
  re-registers. See Section 4.
- Browser error paths run through `redactErrorMessage` /
  `redactSensitiveText`, which scrub `Bearer …` Authorization headers
  and `?token=` / `?client_token=` / `?agent_token=` query params
  before they hit `console.error` or `terminalMount.textContent`.
  Covered by `node --test` unit tests in
  `ghostty-web-client/test/redaction.test.mjs` (run via `npm test`).
- macOS error surfaces (NSAlert "启动共享失败" path,
  `logError("failed to save session sharing config…")`) run through
  `SessionSharingTokenRedaction.redact(error:)`, which mirrors the
  browser scrubber on `Bearer …` headers and the three sensitive
  query parameters. Covered by Swift Testing cases in
  `SessionSharingTests` (`tokenRedaction*`).
- `SessionSharingConfigStore.writeKeychainToken` mirrors the user
  token to the macOS Keychain on every `save(…)` (via
  `SecItemUpdate` with a `SecItemAdd` fallback under
  `kSecAttrAccessibleWhenUnlocked`). The on-disk
  `~/.config/ghostty/sharing.conf` remains the primary store at
  0o600; the Keychain write makes the existing read fallback in
  `presentSettingsSheet` actually populated, so a future change
  that hides the on-disk token only loses convenience, not the
  token itself. `keychainTokenWriter` is injectable so tests don't
  touch the real Keychain. Covered by `configStoreWriteKeychainToken*`
  and `configStoreSaveMirrorsTokenToKeychain` Swift Testing cases.

Remaining:

- (none — open Section 5 items have all been picked up; future
  hardening should add explicit triggers.)

### 6. Test and Validation

Single source of truth for cross-cutting test coverage. Each platform
owns a thin Status block; a removed item is removed everywhere.

#### Relay (Python)

Status: well covered. See `relay-production.md` Phase 6 + load
harness scenarios (steady, reconnect, silent-drop). No open
top-level items.

#### macOS (Swift)

Done:

- Built desktop Zig targets, macOS app, libghostty-vt WASM
- Sharing config persistence + file permission tests
- Reconnect backoff policy + reset behavior
- Sharing state presentation + menu presentation logic
- Relay URL construction + invalid address rejection
- Inbound WebSocket control frame parsing
- Register request + WebSocket request construction
- Register response parsing + invalid-response rejection paths
- Disconnect / stop / reconnect lifecycle decisions
- Controller-level connect-failure presentation + reconnect backoff
  orchestration
- Pending reconnect replacement + cancellation coordination
- Injectable network / output-bridge / reconnect-scheduler
  collaborators with wiring tests

Remaining:

- **P0** Higher-level tests that drive `SessionSharingController`
  directly against fake network and output-bridge collaborators
  (component-level, not unit-of-component). **Currently blocked on
  visibility / NSView coupling**: `SessionSharingController` is
  file-private and constructs through `Ghostty.SurfaceView`, an
  NSView subclass that requires a real `ghostty_app_t` opaque
  pointer. Doing this properly needs splitting the controller into
  an internal `SessionSharingControllerCore` (state machine +
  collaborator orchestration, no NSView dependency) wrapped by the
  current SessionSharingController. Until that refactor lands, the
  existing unit tests on
  `SessionSharingControllerRecovery` /
  `SessionSharingReconnectPolicy` /
  `SessionSharingReconnectCoordinator` cover the controller's
  decision logic at the helper level and the
  `controllerRecoveryDisconnectAction*` cases cover the close-code
  fast-paths.

#### Zig core / bridge

Remaining:

- **P0** Smoke coverage for the raw-byte bridge hooks
  (Section 2 P0).

#### Browser web client

Remaining:

- **P0** Smoke automation for join + input + reconnect happy path on
  a headless browser. Today there is no CI coverage for any browser
  flow.
- **P1** Mobile-device validation script (manual today; could be
  promoted to BrowserStack / Appium when the headless smoke is
  green).

## Decision Triggers

Centralized so deferred items have explicit conditions, not "later":

- **Start GTK host** — three or more Linux user requests, or a
  committed maintainer (see Section 1 GTK).
- **Public-internet GA** — fires only after both client-side strict
  TLS + automated token redaction assertions land (Section 1 P0,
  Section 5 P0). Until then the LAN deployment is the supported
  shape.
- **Browser smoke automation** — start once mobile IME P0 is green;
  no point automating against a UI we know is broken (Section 4 P0
  → Section 6 browser P0).
- **Migrate Python relay to Zig** — controlled by
  `relay-production.md` Decision Triggers (CPU / RSS / GIL
  thresholds). Not an open question in this plan.
- **Native iOS / Android app** — explicit Out of Scope; do not let
  this creep back in.

## Recommended Next Steps

In priority order:

1. **Section 4 P0**: mobile IME / soft keyboard. Browser-side
   close-code handling already landed; the remaining macOS + LAN
   GA blocker on the browser side is the IME path on iOS Safari
   and Android Chrome.
2. **Controller core refactor** (precondition for Section 6 macOS P0):
   split `SessionSharingController` into an internal
   `SessionSharingControllerCore` (no NSView dependency) wrapped by
   the current AppKit-bound class, then build the fake-driven
   component-level test suite on top.
3. **Section 6 browser P0**: only after Section 4 P0 (mobile IME)
   stabilizes; otherwise the smoke encodes broken behavior.
4. GTK and persistence remain trigger-gated; do not start them ahead
   of P0 work.

The previous "decide whether the relay should be rewritten in Zig"
recommendation has been resolved into a Decision Trigger and is no
longer in the next-step list.

## Reference: Map to Subplans

- [`relay-production.md`](relay-production.md) — relay
  hardening, deployment artifacts, baseline measurements, and
  Decision Triggers for the relay-only concerns.

When a topic looks like it could live in either plan, the rule is:
anything observable from outside `contrib/session-sharing/relay/`
goes here; anything inside that directory plus its DEPLOY artifacts
goes in the relay subplan.
