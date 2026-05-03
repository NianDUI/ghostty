# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

- **Build:** `zig build`
  - On macOS, skip the app bundle to speed up compilation: `zig build -Demit-macos-app=false`
- **Run:** `zig build run`
- **Test:** `zig build test`
  - Filter to specific tests: `zig build test -Dtest-filter=<test name>`
- **Test (libghostty-vt only):** `zig build test-lib-vt -Dtest-filter=<filter>`
- **Format (Zig):** `zig fmt .`
- **Format (Swift):** `swiftlint lint --strict --fix`
- **Format (docs/markdown/etc.):** `prettier -w .`
- **Update translations:** `zig build update-translations`
- **Run under Valgrind:** `zig build run-valgrind`
- **Build libghostty-vt (WASM):** `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`

## Architecture

Ghostty is a cross-platform terminal emulator with a shared Zig core and platform-native UIs.

### Core Components (all in `src/`)

- **`terminal/`** — The heart of Ghostty. Implements VT parsing (CSI, OSC, DCS, APC, SGR sequences), terminal screen state (`Terminal.zig`, `Screen.zig`, `PageList.zig`), cursor management, selection, search, mouse protocol, Kitty graphics/image protocols, and tmux control mode. This is terminal emulation logic with zero platform coupling.
- **`termio/`** — Bridges the terminal to the outside world. `Termio.zig` manages per-terminal I/O: spawning child processes (`Exec.zig`), reading/writing to the pty, and routing output to the renderer. Communicates via a shared mailbox system.
- **`renderer/`** — Rendering backends. `Metal.zig` (macOS), `OpenGL.zig` (Linux), and `WebGL.zig` (WASM). `State.zig` is the renderer state machine. Each terminal surface has its own render thread.
- **`config/`** — Configuration system. `Config.zig` is the canonical config struct (flat key-value pairs). Parsing, file loading, CLI overrides, and error reporting live here.
- **`apprt/gtk/`** — The GTK-based Linux application runtime. Contains all GTK-specific window, tab, split, and IME handling. There is no generic "apprt" abstraction; each platform's app runtime is independent.
- **`cli/`** — CLI argument parsing for the `ghostty` binary.
- **`lib/`** — C API surface (`libghostty`). These files generate C-compatible bindings to the Zig core so other projects can embed Ghostty.

### Platform-Specific UIs

- **macOS app:** `macos/` — Full SwiftUI application. Uses Metal rendering, CoreText font discovery, and integrates deeply with macOS features (AppIntents, AppleScript, menu bars, settings GUI).
- **Linux app (GTK):** `src/apprt/gtk/` — Uses GTK for windowing, tabs, and splits. Integrates with systemd for single-instance and cgroup isolation.

### Threading Model

Each terminal surface runs three dedicated threads:
1. **Read thread** — Reads from the pty, runs the SIMD-optimized VT parser
2. **Write thread** — Handles keyboard/mouse input to the pty
3. **Render thread** — Renders the terminal screen via Metal/OpenGL

### Libraries

- **`libghostty`** — Full-featured embeddable terminal library (C and Zig). See `include/ghostty/` for C headers.
- **`libghostty-vt`** — Stripped-down VT-only library for parsing terminal sequences and maintaining terminal state. WASM-compatible. See `include/ghostty/vt/`. All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` sentinel as the last entry to force int enum sizing (C23 portability).

## Key Conventions

- Zig build configuration is defined in `src/build/Config.zig` (available via `-D` flags)
- Shell integration scripts live in `src/shell-integration/`
- Terminfo definitions in `src/terminfo/`
- Font discovery and shaping in `src/font/`
- Input handling (key encoding, bindings, IME) in `src/input/`
- Logging is controlled by `GHOSTTY_LOG` env var (destinations: `stderr`, `macos`) and compile-time optimization level (debug builds log to stderr by default)

## Git Notes

- Do not run multiple Git write operations in parallel in this repository.
- Parallel `git add` / `git commit` / `git push` attempts can leave or contend on `.git/index.lock`.
- If an `index.lock` error appears, first confirm there is no active Git process, then retry the Git operation serially.
