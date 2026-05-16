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
- **Source tarball:** `zig build dist` / `zig build distcheck`

### Build Dependencies (from a Git checkout)

- **Linux:** `blueprint-compiler` ≥ 0.16.0 is required (in addition to the deps for tarball builds).
- **macOS:** building the macOS app requires Xcode 26 with the macOS 26 SDK, the iOS SDK, and the Metal Toolchain. You can still run on macOS 15.

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
- Input-stack changes (key event → pty encoding) require manual IME testing on Linux: Wayland/X11 × ibus/fcitx/none × dead key / CJK / Emoji / Unicode hex. See `HACKING.md` "Input Stack Testing" for the full matrix — there is no automated coverage.
- Changes to the C ABI between Zig and macOS — `include/ghostty.h` enums, `src/apprt/action.zig` (`Action` / `Action.Tag`), `src/input/Binding.zig` `Action` cases, `src/apprt/embedded.zig` exports — must be followed by `zig build -Demit-macos-app=false` before committing so `macos/GhosttyKit.xcframework/` (gitignored) is regenerated. The xcframework is the bridge the Swift code links against; without the rebuild Xcode fails with `cannot find GHOSTTY_ACTION_…` (or similar) even though `zig build test` is clean.
- After every `zig build` (or `zig build -Demit-macos-app=false` + manual xcodebuild) the binary inside `zig-out/Ghostty.app` is replaced, which invalidates the ad-hoc signature. Launching the rebuilt bundle on macOS 26+ crashes immediately with `SIGKILL (Code Signature Invalid)` / `CODESIGNING, Invalid Page` (see `~/Library/Logs/DiagnosticReports/ghostty-*.ips`). Re-sign before launching: `codesign --force --deep --sign - zig-out/Ghostty.app`.
- `zig build` defaults to `-Doptimize=Debug` (see `build.zig` `.optimize = .Debug`). A bare `zig build -Demit-macos-app=false` produces a **Debug** `ghostty-internal.a` (~400 MB), and the resulting `Ghostty.app` is a Swift-Release / Zig-Debug hybrid — *not* a real release build, even though `xcodebuild -configuration Release[Local]` succeeds. The official release pipeline (`.github/workflows/release-tag.yml`) calls `zig build -Doptimize=ReleaseFast -Demit-macos-app=false` *before* `xcodebuild`. When the user asks for a "release" / "正式版" build, **always** pass `-Doptimize=ReleaseFast` to the Zig step. Sanity-check: ReleaseFast `ghostty-internal.a` is ~280 MB and the final binary ~50 MB, vs Debug-hybrid binary ~120 MB.

## Agent Rules

- Never open a GitHub issue or pull request. If the user explicitly asks for one, follow `AGENTS.md` ("Issue and PR Guidelines") rather than running `gh issue create` / `gh pr create`.
- AI-assisted contributions must be disclosed per `AI_POLICY.md`. The human contributor must understand and be able to explain every change.
- Vetted prompts for common tasks live in `.agents/commands/` (e.g. `/gh-issue` for diagnosing a GitHub issue). Prefer them over ad-hoc prompting when applicable.

## Git Notes

- Do not run multiple Git write operations in parallel in this repository.
- Parallel `git add` / `git commit` / `git push` attempts can leave or contend on `.git/index.lock`.
- If an `index.lock` error appears, first confirm there is no active Git process, then retry the Git operation serially.
