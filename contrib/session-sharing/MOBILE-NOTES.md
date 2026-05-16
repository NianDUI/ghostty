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

### 5. 锁定模式下主机底部行被裁

- **现象**：主机 46 行 × cellHeight 736px，超过手机可视区 530px，canvas 溢出 → 底部 13 行（含光标）被裁。
- **根因**：`onResize` 里强行把本地 grid 行数 snap 回 hostRows，本地 grid 永远比 viewport 高。
- **修复**：移动端 + 锁定模式下**只锁 cols，rows 跟随 viewport**。多出的内容自然进 xterm scrollback，光标永远在可视底部。

## 已知 trade-off

### 6. 行数适配引入光标定位错位

- **现象**：本地 grid 33 行 vs 主机 46 行时，主机发来的绝对 cursor 定位转义序列（如 Claude Code TUI 状态栏画在主机行 46）会被映射到本地行 33，导致内容**重叠**渲染（例如文件列表行上叠加了"bypass permissions"状态栏文字）。
- **根因**：主机的 PTY 字节流里包含 `\x1b[ROW;COLH` 这种绝对寻址，是按主机自己的 grid 维度算的。我们本地 grid 行数比主机少，绝对行号被 clamp 到我们的最大行（不是主机的对应行）。
- **未修**：要彻底解决需要保留 46 行本地 grid + 加垂直 pan（类似横向 pan 的 `translate3d`），UX 上和现在的垂直滚动（scrollback）会冲突。当前选择把光标可见性优先于绝对定位精度。
- **缓解建议**：日常使用不开 lock-host-size，让本地 grid 完全适配可视区，host 端的 TUI 程序会重排到正确尺寸。lock-host-size 适合桌面/平板用户保留原 grid。

## 移动端排查工具

启动器里有"调试日志栏"开关。打开后页面顶部出现 [DL] [CLR] 按钮：
- 触摸/滑动事件、`focusin`、控制帧类型、宽度计算、视口尺寸等都进环形日志
- [DL] 下载完整 `touch-log-*.txt`
- 关掉开关页面刷新后调试栏消失，零运行时开销

Relay 侧 `replay_backlog` 事件会在每个新客户端连入时打印 backlog 内容（`kinds: hello:114,appearance:298,screen:43801,bin:63`），用 `journalctl -u ghostty-relay -f` 实时观察。
