# Ghostty Session Sharing Plan

## Status Summary

Last updated: 2026-05-02

Overall status: partially implemented

Implemented now:

- macOS desktop session sharing UI entry
- share settings sheet and local config persistence
- session sharing state badge and stop action
- desktop `POST /api/register` plus `wss /ws/agent` flow
- PTY raw output to WebSocket bridge
- WebSocket input back into Ghostty surface as raw bytes
- reconnect with exponential backoff
- relay prototype with REST and WebSocket endpoints
- mobile browser prototype backed by `libghostty-vt` WASM

Not finished yet:

- GTK/Linux desktop implementation
- production-grade relay service
- production-grade mobile `ghostty-web` packaging and deployment flow
- client token rotation / refresh flow
- higher-level controller and integration tests
- richer browser input support and resize synchronization

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
- Add explicit resize/control channel handling end to end

### 3. Relay Service

Status: prototype complete, production service not started

Completed:

- Added Python relay prototype
- Implemented `POST /api/register`
- Implemented `GET /api/sessions`
- Implemented `/ws/agent`
- Implemented `/ws/client`
- Added in-memory session table and offline cleanup
- Added static serving for the mobile web client and `ghostty-vt.wasm`

Remaining:

- Replace prototype with a production service, preferably Zig if desired
- Enforce HTTPS/WSS deployment assumptions at the edge
- Add token expiry validation and refresh flow
- Add rate limiting, structured logging, and observability
- Add multi-user hardening and persistence strategy

### 4. Mobile Web Client

Status: prototype complete

Completed:

- Added token login and session listing page
- Added online/offline session selection
- Added WebSocket client connection flow
- Replaced text-only terminal with `libghostty-vt` WASM-backed rendering
- Added browser-side VT parsing, render state extraction, and DOM rendering
- Added direct keyboard forwarding and textarea fallback input

Remaining:

- Replace prototype DOM renderer with a hardened `ghostty-web` distribution shape
- Add better mobile keyboard behavior and IME handling
- Add terminal resize reporting back to the relay/agent
- Add reconnect UX and session reconnect behavior on page refresh
- Add visual/performance optimization for larger scroll regions

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
- Add integration tests for relay registration and WebSocket forwarding
- Add browser smoke test automation

## Recommended Next Steps

1. Add higher-level tests around `SessionSharingController` network scheduling and reconnect orchestration.
2. Decide whether the relay should remain a prototype or be rewritten as an in-repo Zig service.
3. Complete browser resize and mobile input handling so the web client is usable beyond smoke testing.
4. If cross-platform support matters, start the GTK implementation instead of deepening macOS-only polish.

## Current Deliverable Boundary

What exists now is a working first-pass stack for local development and architecture validation:

- macOS desktop can start and stop a shared session
- relay prototype can register and bridge sessions
- browser client can render the remote terminal using Ghostty's WASM terminal core

What does not exist yet is a production-ready, fully tested, cross-platform feature set.
