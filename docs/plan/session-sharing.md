# Ghostty Session Sharing Plan

## Status Summary

Last updated: 2026-05-03

Overall status: partially implemented, with the browser client now migrated to a `ghostty-web`-based terminal view

Implemented now:

- macOS desktop session sharing UI entry
- share settings sheet and local config persistence
- session sharing state badge and stop action
- desktop `POST /api/register` plus `wss /ws/agent` flow
- PTY raw output to WebSocket bridge
- WebSocket input back into Ghostty surface as raw bytes
- reconnect with exponential backoff
- relay prototype with REST and WebSocket endpoints
- mobile/browser client backed by `ghostty-web`

Not finished yet:

- GTK/Linux desktop implementation
- production-grade relay service
- production-grade `ghostty-web` packaging and deployment flow
- client token rotation / refresh flow
- higher-level controller and integration tests
- richer browser input support and broader reconnect / mobile behavior hardening

## Plan

### 1. Desktop Host Integration

Status: mostly complete on macOS

Completed:

- Added menu entry and shortcut for toggling session sharing
- Added share settings dialog with session name, relay, token, save option
- Added config load/save behavior for `~/.config/ghostty/sharing.conf`
- Added per-surface sharing state updates in the UI
- Added start/stop sharing flow and reconnect state display
- Added raw byte bridge APIs for Ghostty surface IO

Remaining:

- Move shortcut binding into the normal configurable shortcut system
- Improve error presentation in the sheet and status UI
- Add stronger token redaction checks around all error paths
- Add GTK-side UI and host integration if Linux support is required

### 2. Core Bridge and Terminal Plumbing

Status: complete for the first macOS prototype

Completed:

- Added surface raw byte input API
- Added termio output callback hook
- Bridged PTY output to host callback without changing render behavior
- Bridged WebSocket input back to PTY as raw bytes

Remaining:

- Add targeted Zig tests for the new bridge hooks
- Review threading assumptions around output callback lifetime
- Add targeted end-to-end verification for resize/control channel handling

### 3. Relay Service

Status: prototype complete, production service not started

Completed:

- Added Python relay prototype
- Implemented `POST /api/register`
- Implemented `GET /api/sessions`
- Implemented `/ws/agent`
- Implemented `/ws/client`
- Added in-memory session table and offline cleanup
- Added static serving for the browser web client
- Added client-disconnect signaling so the desktop agent can restore its original size

Remaining:

- Replace prototype with a production service, preferably Zig if desired
- Enforce HTTPS/WSS deployment assumptions at the edge
- Add token expiry validation and refresh flow
- Add rate limiting, structured logging, and observability
- Add multi-user hardening and persistence strategy

### 4. Mobile Web Client

Status: browser client is usable, still not production-ready

Completed:

- Added token login and session listing page
- Added online/offline session selection
- Added `ghostty-web`-backed terminal page
- Added terminal-only session route and browser title updates
- Added browser-side reconnect loop for dropped WebSocket sessions
- Added terminal resize reporting to the relay/agent
- Added mobile hidden-input fallback and focus recovery
- Added session list display for recent activity time

Remaining:

- Add better mobile keyboard behavior and IME handling
- Add more robust reconnect UX and session recovery validation on page refresh
- Add visual/performance optimization for larger scroll regions
- Add browser-side smoke and regression coverage

### 5. Security and Storage

Status: partially complete

Completed:

- Avoided logging token values in the implemented paths
- Stored local config with restricted file permissions
- Used agent token for `/ws/agent`
- Used separate client token for `/ws/client`

Remaining:

- Add automated checks for token redaction
- Finish keychain write path instead of read-only fallback
- Ensure browser client token refresh/expiry behavior is enforced
- Audit all prototype endpoints for production-safe defaults

### 6. Test and Validation

Status: substantially improved, still not complete

Completed:

- Built desktop Zig targets successfully
- Built macOS app successfully
- Built `libghostty-vt` WASM successfully
- Verified relay Python syntax
- Verified browser JS syntax
- Verified WASM terminal/render ABI with Node-based smoke tests
- Verified relay static serving of `ghostty-vt.wasm`
- Added relay smoke coverage for register/session listing/WebSocket forwarding
- Added macOS unit tests for sharing config persistence and file permission handling
- Added macOS unit tests for reconnect backoff policy and reset behavior
- Added macOS unit tests for sharing state presentation and menu presentation logic
- Added macOS unit tests for relay URL construction and invalid address rejection
- Added macOS unit tests for inbound WebSocket control frame parsing
- Added macOS unit tests for register request and WebSocket request construction
- Added macOS unit tests for register response parsing and invalid-response rejection paths
- Added macOS unit tests for disconnect, stop, and reconnect lifecycle decisions

Remaining:

- Add higher-level tests around `SessionSharingController` scheduling and dependency wiring
- Add Zig tests for the raw byte bridge hooks
- Add browser smoke test automation

## Recommended Next Steps

1. Add higher-level tests around `SessionSharingController` network scheduling and reconnect orchestration.
2. Decide whether the relay should remain a prototype or be rewritten as an in-repo Zig service.
3. Complete browser IME handling and validate reconnect/resize behavior on real mobile devices.
4. If cross-platform support matters, start the GTK implementation instead of deepening macOS-only polish.

## Current Deliverable Boundary

What exists now is a working first-pass stack for local development and architecture validation:

- macOS desktop can start and stop a shared session
- relay prototype can register and bridge sessions
- browser client can render the remote terminal using Ghostty's WASM terminal core

What does not exist yet is a production-ready, fully tested, cross-platform feature set.
