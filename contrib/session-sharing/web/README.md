# Session Sharing Mobile Web Prototype

Expected browser flow:

1. Prompt for user token.
2. Request `GET /api/sessions`.
3. Render the returned session list with `online` and `offline` states.
4. When the user selects an online session, connect:

`wss://relay.example.com/ws/client?id=<session_id>&token=<client_token>`

5. Feed binary output frames into the `libghostty-vt` WASM terminal adapter.
6. Forward browser keyboard input as binary frames to the relay.

The current prototype page in this directory now does:

- loads `ghostty-vt.wasm`
- creates a real Ghostty terminal and render state in the browser
- writes agent VT bytes into that terminal
- renders rows/cells/colors/cursor into DOM
- forwards direct keyboard events and textarea input back to the relay

Build the WASM artifact first:

```bash
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

The relay prototype will serve `zig-out/bin/ghostty-vt.wasm` automatically at `/ghostty-vt.wasm`.

The current macOS agent implementation already emits:

- raw PTY bytes on binary frames
- `hello` / `pong` JSON text frames

The browser implementation should therefore:

- accept binary frames as terminal output VT stream
- ignore unknown text control frames
- optionally emit `ping` and `resize`
