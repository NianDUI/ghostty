# Plan: Live Mirror Mode toggle

Status: draft (post-codex review)
Owner: web-client
Scope: `contrib/session-sharing/ghostty-web-client/` only — no relay or agent changes.

## Problem

Today's web client always runs in "B-mode": it lazy-fetches host scrollback
on scroll-up via `fetch_scrollback`, accumulates it (plus the screen snapshot
and live deltas) in `src/scrollback.js`, and on every scrollback fetch does
`terminal.reset() + terminal.write(replayBuffer.buildReplayBytes())`
(`src/main.js:475-490`). That full-buffer replay is the visible top-to-bottom
repaint users see on mobile, especially after a swipe-scroll.

The screen-frame path (`applyScreenSnapshot`, `src/main.js:461-473`) only
writes the snapshot itself, not the whole replay buffer, so its flash is
already small — Codex correctly flagged that the original draft attributed
the flicker to screen frames; the actual culprit is scrollback responses.

## Goal

Add an opt-in "实时镜像（不缓存历史）" toggle in the launcher that disables
the lazy scrollback path and the replay buffer accumulation. When on, the
client mirrors host viewport + live deltas only. The xterm-side scrollback
that naturally accrues from streamed bytes is left alone (the wasm Terminal
keeps its own buffer) — we just don't bolt our own replay logic on top.

## Non-goals

- Not capping xterm's local scrollback. The `Terminal` instance is created
  once in `ensureTerminal` and memoized; passing `scrollback: N` into the
  constructor would only take effect on a hard page reload, which is
  misleading. Skip.
- Not changing `applyScreenSnapshot`'s rendering (already minimal).
- Not changing relay or agent. Same wire format.
- Not fixing pull-to-refresh in this PR. Track separately as a CSS
  `overscroll-behavior: contain` follow-up.

## UX

Add a checkbox under the existing "锁定主机尺寸" / "桌面宽度" toggles in the
launcher. Label: "实时镜像（不缓存历史）". Help text: "只显示主机当前可视区
和实时输出，不在 web 端缓存滚动历史。手机端建议开启。"

**Default: off for everyone.** Codex flagged that reusing
`shouldUseMobileInput()` (a coarse-pointer / narrow-viewport heuristic for
input affordances) as a performance-mode default conflates two concerns and
risks silent behavior change for existing desktop users. Discoverability is
fine: the checkbox sits next to the other prominent toggles, and the
localStorage value persists once a user opts in.

## Behavior on toggle

To stay consistent with the other two launcher toggles (which take effect
immediately on the active session), this toggle also applies live, with one
caveat documented below.

- **off → on (B → A)**:
  1. Persist the new value.
  2. If a session is active: stop issuing `fetch_scrollback`. Stop
     accumulating in `replayBuffer`. The replay buffer's existing state
     becomes irrelevant — it will never be read.
  3. The xterm-side scrollback already showing in the viewport stays
     visible. The next agent-emitted `screen` frame will `reset()` and
     redraw the viewport (same as today); after that, the user only sees
     viewport + live deltas going forward.
- **on → off (A → B)**:
  1. Persist.
  2. If a session is active: `replayBuffer` resumes capturing live deltas
     immediately, but the snapshot/older-history state is empty. The user
     will only be able to scroll back into history that arrives after the
     toggle (or after the next `screen` frame). This asymmetry is OK and
     documented next to the toggle. (We could force a fresh
     `screen + fetch_scrollback` round-trip here, but it's complexity we
     don't need until a user asks.)

There is no "下次连接生效" hint. The toggle just works, with the asymmetry
noted in the UI help text.

## Files

- `contrib/session-sharing/ghostty-web-client/index.html` — add the checkbox
  and a one-line help string.
- `contrib/session-sharing/ghostty-web-client/src/main.js` — wire the
  mode-aware gates.

The `replayBuffer` module (`src/scrollback.js`) and its tests
(`test/scrollback.test.mjs`) are untouched.

## Implementation

1. **HTML** (`index.html`):
   ```html
   <label class="toggle">
     <input id="liveMirrorMode" type="checkbox">
     实时镜像（不缓存历史）
   </label>
   ```
   Place under the existing toggle group in the launcher.

2. **localStorage key** (`src/main.js`):
   ```js
   const LIVE_MIRROR_KEY = "ghostty-sharing-live-mirror";
   liveMirrorModeInput.checked = localStorage.getItem(LIVE_MIRROR_KEY) === "1";
   ```
   Default off. No mobile auto-default.

3. **Accessor**:
   ```js
   function isLiveMirrorEnabled() {
     return liveMirrorModeInput?.checked ?? false;
   }
   ```

4. **Mode capture at connect time**:
   ```js
   let activeMirrorMode = false;
   // inside connectToSession(...):
   activeMirrorMode = isLiveMirrorEnabled();
   ```
   Stored module-side. The change handler updates it for an active session.

5. **Gates** (all in `src/main.js`):
   - In `connectToSession`'s `socket.addEventListener("message", ...)`:
     skip `replayBuffer.onLive(bytes)` when `activeMirrorMode` is true.
   - In `applyScreenSnapshot`: skip `replayBuffer.onScreen(bytes)` when
     `activeMirrorMode` is true. Still `reset() + write(bytes)`.
   - In `applyScrollbackResponse`: early return when `activeMirrorMode` is
     true (defensive — `maybeRequestOlderScrollback` won't fire requests in
     that mode anyway).
   - In `maybeRequestOlderScrollback`: early return when `activeMirrorMode`
     is true.
   - `terminal.onScroll` listener: keep bound; the early return inside
     `maybeRequestOlderScrollback` makes it a no-op without lifecycle
     gymnastics. (Codex confirmed this is fine.)

6. **Change listener**:
   ```js
   liveMirrorModeInput.addEventListener("change", () => {
     localStorage.setItem(LIVE_MIRROR_KEY, liveMirrorModeInput.checked ? "1" : "0");
     activeMirrorMode = liveMirrorModeInput.checked;
   });
   ```
   No reconnect, no UI hint. The asymmetry note lives in the help text.

7. **No changes to `ensureTerminal`**. Codex reviewed: capping
   `scrollback` at construction would require destroying and rebuilding
   the Terminal on toggle, which is too much surface for a marginal win.

## Test plan

Manual (the only practical coverage given main.js is currently untested):

- Desktop, toggle off (default): unchanged. Scroll up triggers
  `fetch_scrollback`; replay flash visible as before. Confirms regression
  guard.
- Desktop, toggle on: connect to a session with non-trivial scrollback.
  Scroll up — confirm xterm scrolls through whatever bytes have streamed
  this session, no `fetch_scrollback` request issued (check Network /
  socket frames), no full-replay flash.
- Mobile (real device or DevTools coarse-pointer emulation), toggle on:
  connect to a busy session. Confirm no top-to-bottom repaint when content
  scrolls past the viewport.
- Toggle on while connected: confirm no flicker or disconnect; subsequent
  scroll-ups stop triggering fetches.
- Toggle off while connected: confirm `replayBuffer` resumes capturing
  (scroll up after a few seconds shows recent live content; older
  pre-toggle content is gone, as expected).
- `pnpm test` — existing test suite continues to pass.

## Open questions / future work (out of scope here)

1. Pull-to-refresh on iOS/Android still reloads the page. Apply
   `overscroll-behavior: contain` to `html, body, #shell` in a follow-up
   PR.
2. If we later want the A → B → A asymmetry to be smoother, the agent
   can be asked to re-emit a `screen` frame on demand and the client can
   restart its `replayBuffer` cleanly. Defer until requested.
3. Codex flagged that frontend code can't verify ordering invariants
   between `screen` and live-binary frames. The current code assumes
   either order is safe; this PR doesn't change that assumption.

## Codex critique applied

| Codex finding | Resolution |
|---|---|
| 1. "screen frame causes full-history replay" claim is wrong | Removed the claim. Goal narrowed to "skip the lazy scrollback replay path", which is the actual win. |
| 2. `scrollback: 200` on a memoized Terminal is misleading | Dropped from the plan. |
| 3. Reusing `shouldUseMobileInput()` for default couples concerns | Default off everywhere. User opts in. |
| 4. "Next connection only" is inconsistent with sibling toggles | Toggle now applies live, with documented A↔B asymmetry. |
| 5. `terminal.onScroll` no-op acceptable | Kept as-is; gate inside `maybeRequestOlderScrollback`. |
| 6. `replayBuffer` cross-session state | Not cleared explicitly; A-mode never reads it, B-mode resets it on the next `screen` via `replayBuffer.onScreen`. |
| 7. Frontend can't verify screen/delta ordering | Out of scope; existing assumption preserved. |
| 8. Test coverage on `main.js` is weak | Acknowledged; this PR adds no new tests for `main.js`. Manual verification only, plus the existing `scrollback.test.mjs` suite which the buffer module's API doesn't break. |
