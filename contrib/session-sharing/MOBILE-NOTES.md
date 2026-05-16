# 移动端调优记录

聚焦移动端（HuaweiBrowser 17 / Chromium 114 / Android 12）下的会话共享体验。

## 已修复

### 1. 横向 swipe 松手回弹（"桌面宽度"模式）

- **现象**：左右滑动后松手，`#terminal` 立刻弹回 0 偏移。
- **根因**：HuaweiBrowser 在 `touchend` 的 capture-phase 和 bubble-phase 之间会**静默重置父元素 `scrollLeft`**，跟 `touch-action`/`preventDefault` 都无关。
- **修复**：放弃 `scrollLeft`，用 `transform: translate3d(-X, 0, 0)` 实现伪滚动；浏览器不会回滚我们自己写的 `transform`。

### 2. 锁定主机尺寸时主机宽度被裁

- **现象**：主机 cols > ~100 时，`#terminal` 被 CSS 写死 860px，canvas 溢出 + `overflow: hidden` → 右侧内容被裁。
- **根因**：CSS 用了硬编码 860px，没适配实际 grid 宽度。
- **修复**：基于 `canvas.width / DPR / cols` 反算 cell 宽度，把 `#terminal` 内联 width 设成 `cols × cellWidth + 16`。pan 范围自动跟着扩。

### 3. 新连入客户端拿不到 `hello`/`appearance`

- **现象**：客户端只收到 `screen` 帧，没收到 `hello` → 不知道主机 cols/rows → FitAddon 把 grid 调成适配可视区的窄宽度 → 主机宽内容换行。
- **根因**：两个叠加 bug
  - relay：收到 `screen` 帧时清空整个 backlog，把 `hello` 和 `appearance` 一起丢了
  - agent：收到 `client_connected` 通知时只重发 `screen`，没重发 `hello`/`appearance`
- **修复**：
  - relay：清 backlog 时保留 `hello` 和 `appearance` (`_is_essential_metadata`)
  - agent：`client_connected` 时三发齐发（hello + appearance + screen）

### 4. 滑动松手后键盘自动弹起

- **现象**：用户用系统手势收掉键盘后，下次在终端区滑动，松手瞬间键盘自动重新弹起。
- **根因**：Android 软键盘弹起**不依赖新的 `focusin` 事件**——只要焦点输入框在、用户产生触摸交互，浏览器就会重新弹键盘。系统手势收键盘并不解除 DOM focus，`mobileInput` 始终保持 focus。
- **修复**：`endTouchScroll` 检测到真实滑动（非 tap）时主动 `mobileInput.blur()`。下次想要键盘？点终端任意位置（tap → focusTerminal → mobileInput.focus）。

### 5. 锁定模式下主机底部行被裁 + 绝对定位错位

- **现象**：
  - 第一版：主机 46 行 × cellHeight 736px 超过手机可视区 530px，canvas 溢出，底部 13 行（含光标）被 `overflow:hidden` 裁掉。
  - 改成"只锁 cols、rows 跟随 viewport"之后：底部回到可视区，但主机绝对 cursor 定位转义（如 `\x1b[46;1H`）按主机 46 行算，落到本地 33 行就被 clamp，TUI 状态栏栈到不相干内容上，出现**重叠渲染**。
- **根因**：本地 grid 行数必须和主机一致才能让绝对寻址映射正确，但保持一致就 canvas 比可视区高，自然得裁。
- **修复**：保留本地 grid = 主机 grid，外加**垂直 transform pan**——`#terminal` inline height 设为 `rows × cellHeight`，再用 `translate3d(0, -Y, 0)` 在 `.terminal-host` 内移动，`overflow:hidden` 配合 transform 模拟"垂直 scrollLeft"。
  - `maxDesktopPanY` 减去 `.terminal-host` 的 `padding-top/-bottom`，避免 pan 到底时 cursor 落进 toolbar 后面。
  - touchmove 垂直分支：pan 在 grid 边界饱和时落入 `terminal.scrollLines` —— 下拖到顶进 scrollback、上拖让 scrollback 退回再恢复 pan。
  - `ResizeObserver` 监听 `.terminal-host`：键盘弹起、URL 栏切换等让可视区缩小的事件触发 `panToBottom()`，光标自动跟上。
  - `panToBottom` 在 hello / applyAppearance / screen / 模式切换都会调用一次，首帧就锚到 cursor 行。

### 6. liveMirror 模式下 spinner 行在 scrollback 里堆副本

- **现象**：开了"实时镜像模式"后，Claude Code 的状态行（"Compacting conversation... 30s/31s/32s..."、"Concocting..."）每 tick 一次在 web 端就多一行，停下来不消失，scrollback 里全是同一行的不同时间戳。
- **根因**：`SessionSharingScreenSnapshotPayload.encode` 拿 `ghostty_surface_read_text_styled` 把整屏当 plain bytes，前缀 `\x1b[2J\x1b[H`、内容、**没有 cursor 位置**。xterm 写完 snapshot 后 cursor 落在内容最后一行，但主机此刻的 cursor 还在 spinner 行。后续 Ink/log-update 系 TUI 发的"光标上移 N 行 + 重绘"是**相对定位** → xterm 从 snapshot 尾巴上移 N，主机从 spinner 行上移 N，两边落到不同的行；每次 tick 在 xterm 的新行上写一份，老行就被 commit 进 scrollback。
  - 非 liveMirror 模式之所以没事：`replayBuffer` 在重连时把 `terminal.reset()` + 全量 replay 再跑一遍，间接把 cursor 校准了。liveMirror 直接 bypass 这套，所以漏。
- **修复**：
  - Zig 侧新增 `ghostty_surface_cursor_position` C API（`src/apprt/embedded.zig` + `include/ghostty.h`），上锁 `renderer_state.mutex` 读 `screens.active.cursor.{x,y}`。
  - Swift 侧 `encode` 在 snapshot 字节末尾拼 `\x1b[<y+1>;<x+1>H`，VT 1-indexed。`capture` 调新 API 拿到 cursor，传给 `encode`。
  - 因为是跨 C ABI 改动，提交前要跑 `zig build -Demit-macos-app=false` 重建 `macos/GhosttyKit.xcframework/`，否则 Xcode 报 `cannot find ghostty_surface_cursor_s`。
- **二轮修复（关键）**：第一版分两次 lock 读 text + cursor，PTY reader 线程在两次 lock 之间会把 cursor 往前推，导致 cursor 锚点跟 snapshot 文本不在同一时刻 → 实测**比不加更糟**。改成 `ghostty_surface_read_text_styled_with_cursor` 一次 lock 原子读两份，cursor 锚点跟 dump 一致。
- **三轮修复（最终）**：二轮锚点位置仍然错。根因是 `formatter.zig` 注释里的硬规则——"Trailing blank lines are always trimmed"。host active screen 底部的空白行（cursor 下方那几行）被 dump 吃掉，xterm viewport 底部对应到 host 的"最后非空行"而不是 active screen 真正的最后一行 → `\x1b[<y+1>;<x+1>H` 在两边落到不同的 grid cell。
  - 中间走过弯路：切到 `POINT_ACTIVE` 让 dump 只含 active screen + 用 `\r\n` 补到 hostRows。但这砍掉了 scrollback；liveMirror 模式下 `fetch_scrollback` 是禁用的（`activeMirrorMode return;`），用户下滑回看历史**直接看不到**。
  - 终态：`ghostty_surface_read_text_styled_with_cursor_and_trim` 在一次 lock 下原子读 text + cursor + active 尾部空行数。Swift 拿到 trailing_blank_rows，在 cursor anchor 前补对应数量的 `\r\n`。这样 `POINT_SCREEN` 保留（scrollback 还在），xterm viewport row R 又能精确对齐 host active row R-1。
- **四轮修复（多 tab 切换时偶发复发）**：spinner 重复行在多个 surface 来回切 session 时仍偶发。`touch-log` 抓到一个 `bytes=190 tail=\x0d\x0a × 11 + \x1b[2;37H` 的异常 screen frame——cursor 在 row 2 但 trailing 只有 11，host rows 是 48，pad 数学怎么都不对。根因是 trailing 算法的"空白"判定跟 formatter 不一致：
  - `embedded.zig` 用 `Cell.hasTextAny`（`page.zig:2188`）——对 `bg_color_palette`/`bg_color_rgb` 类型 cell 返回 false → 整行纯背景色 → 算空白
  - `formatter.zig:1131-1142` 在 styled 模式判 blank 用 `cell.isEmpty() && !cell.hasStyling()`——bg color cell 的 `isEmpty()` 是 false → 不算空白 → **保留**这行不 trim
  - Host TUI 在 active 底部画纯背景色行（Claude Code 的状态栏填充、xterm 的颜色块等都会触发）时：formatter 保留，trailing 算法 over-count → snapshot 的 `\r\n` pad 多于 formatter 实际 trim 数 → xterm 滚屏过头 → cursor anchor 落到空白行 → host 后续的 `\x1b[1A\x1b[2K` 之类相对寻址叠到错的行 → 重复行。
  - 修复：`page.zig` 加 `Cell.isBlankStyled` 公共方法（判定跟 formatter styled 模式一致），`embedded.zig` 的 trailing 计算改用它，删掉之前的本地 helper。配套单元测试证明两个算法在纯背景色行上的差异。

### 7. 会话切换时上一个会话的内容残留

- **现象**：在 session A 里看了一阵 → 退出回到启动器（不刷新页面）→ 点进 session B，开屏前一瞬看到 session A 的 buffer，等到新 screen frame 到达才被覆盖。直接通过 URL `?id=` 进入第二个 session 时也会有。
- **根因**：
  - `leaveTerminalView` 只关 socket + 切回 launcher，**xterm 和 replayBuffer 都是模块级单例不动**。
  - `connectToSession` 原本在 `enterTerminalView`（解除 `#terminalView` 隐藏）**之后**才 `term.reset()`，中间至少一帧（~16ms）旧 buffer 暴露。
  - 即便 `reset()` 跑了，xterm.js 的 `reset()` **不清 scrollback**（VT RIS 只管 active buffer / cursor / state）——下拉时旧历史还在。
- **修复演进**：
  - **一轮（不够）**：`leaveTerminalView` 调 `terminal.reset()`。结果直接 URL 深链 / 刷新后首次进入跳过 leave，仍有残留。
  - **二轮（不够）**：`connectToSession` 进入前**在 `enterTerminalView` 之前** 也跑 `terminal.reset()` + 写 `\x1b[3J`（erase saved lines 清 scrollback）+ `replayBuffer.onScreen(new Uint8Array(0))`。实测仍偶发残留——`reset()` 是 VT RIS，但 xterm.js 内部的 renderer textures / 合成层 / IME composer state / alt-buffer 切换状态都不靠 VT 状态机走，会幸存。
  - **终态**：`disposeTerminal()` 销毁 xterm 实例 + dispose fitAddon + 清 `terminalMount.innerHTML` + 重置 pan 状态。`connectToSession` 在 `enterTerminalView` 之前调一次（每个进入路径都过），`leaveTerminalView` 也调一次（守 launcher 长时间停留场景）。下次 `ensureTerminal()` 通过 `if (terminal) return terminal` 的 null check 自动重建。
    - 配套：`ensureTerminal` 内挂的 `document.addEventListener("focusin", ...)` 和 `ResizeObserver(terminalMount.parentElement)` 用 `globalTerminalListenersInstalled` flag 守起来，避免重建累积 listener leak。
    - 性能代价：每次进入会话重建 xterm，~100-300ms 初始化（创建 canvas renderer + fitAddon.fit + addons）。换得视觉绝对干净。
  - `replayBuffer.onScreen(new Uint8Array(0))` 仍保留——空字节走 scrollback.js 里 "新 snapshot 到达 → 丢掉所有旧记忆" 那条路径（`snapshotBody / olderChunks / liveBuffer` 一次性清）。

## 移动端排查工具

启动器里有"调试日志栏"开关。打开后页面顶部出现 [DL] [CLR] 按钮：
- 触摸/滑动事件、`focusin`、控制帧类型、宽度计算、视口尺寸等都进环形日志
- [DL] 下载完整 `touch-log-*.txt`
- 关掉开关页面刷新后调试栏消失，零运行时开销

Relay 侧 `replay_backlog` 事件会在每个新客户端连入时打印 backlog 内容（`kinds: hello:114,appearance:298,screen:43801,bin:63`），用 `journalctl -u ghostty-relay -f` 实时观察。
