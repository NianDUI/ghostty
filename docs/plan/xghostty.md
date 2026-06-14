# XGhostty 执行计划

> 基于 Ghostty 私人 fork 自研 XShell/WindTerm 式 SSH 运维座舱。
> 本文是可执行的工程计划,经 6-agent 对抗评审 + 多轮形态决策敲定。
> 维护人:liyongda  ·  起草:2026-06-11

---

## 0. 定位与形态(已定）

- **是什么**:左侧会话树 + 右侧终端 + 底部批量发送/快捷命令条的 SSH 座舱,管理数十~上百台阿里云生产服务器。
- **怎么落地**:做成**独立的第二个 macOS app「XGhostty」**——独立 bundle id → Dock 两个图标 → ⌘Tab 可独立切换 → 崩溃隔离。原 `Ghostty.app` 保持纯终端(日常跑 Claude Code),一行不改其行为。
- **同源双 target**:同一套源码,两个 Xcode target/scheme。Zig 核心 `GhosttyKit.xcframework` 两 app 共享、只编一次。
- **命名三层**:
  - Xcode target/scheme:`XGhostty`
  - 产物 / Dock 显示名:`XGhostty.app` / `XGhostty`(`CFBundleDisplayName`)
  - bundle id:`com.liyongda.ghostty.x`（可改）

---

## 1. 总体架构决策(已定，附理由)

| 决策 | 选择 | 理由 / 评审依据 |
|---|---|---|
| 载体 | Ghostty fork macOS app + 第二 target | 复用 libghostty/Metal/SurfaceView,不重写终端模拟 |
| app 形态 | 独立 bundle（非同 app 多窗口/浮动面板） | macOS 铁律:Dock 两图标=两 bundle id;且开发回路天然隔离 |
| target 区分 | 编译标志 `XGHOSTTY` | 仿现有 `DOCK_TILE_PLUGIN` 先例（project.pbxproj:884/913/942；AppIcon.swift:19） |
| 开会话 | `SurfaceConfiguration.command = "ssh …"` | 退出留“尸体 tab”→ 正好挂重连按钮;代价:失系统级窗口恢复(自建) |
| **广播原语** | **`ghostty_surface_send_bytes`** | **不可用 `sendText`/`ghostty_surface_text`——后者是 paste 语义,远端 bracketed-paste 下命令被包裹不执行**;行尾 `\r` |
| 座舱 tab 模型 | 单窗口自管多 surface（非原生 NSWindow tabbing） | 真 XShell 形态;surface 可独立创建已验证（BaseTerminalController.swift:142） |
| 凭据 | 密码只存 Keychain，座舱独占；JSON 只存 host/port/user | 日常 Ghostty.app 碰不到凭据,攻击面更小 |
| 签名 | 一张自签 Code Signing 证书签两个 app | 替代 ad-hoc `--sign -`,根治 Keychain ACL churn |

---

## 2. 已验证的代码事实（file:line）

- `Ghostty.SurfaceView(ghostty_app, baseConfig:)` 可独立创建,不依赖 NSWindow tabbing——`BaseTerminalController` 注释明说“不实现 Tabbing”（BaseTerminalController.swift:20-23, 142）。surfaceTree 类型 `SplitTree<Ghostty.SurfaceView>`（:44）。
- `SurfaceConfiguration{ command / workingDirectory / environmentVariables / initialInput / waitAfterCommand }`（SurfaceView.swift:695-718）；C 通道完整（embedded.zig:425-595）。
- `ghostty_surface_send_bytes` 零变换直写 pty（embedded.zig:1950）；fork 已有 Swift 封装范例 `sendSharedBytes`（SurfaceView_AppKit.swift:471-477）。
- `sendText` → `ghostty_surface_text` 是 paste 语义（embedded.zig:1940；Surface.zig completeClipboardPaste）——**广播禁用**。
- 编译标志机制:`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DOCK_TILE_PLUGIN`（project.pbxproj:884/913/942）;`#if !DOCK_TILE_PLUGIN`（AppIcon.swift:19）。XGhostty 照此加 `XGHOSTTY`。
- xcframework 同一 fileRef 被多 target 共享（project.pbxproj:306/314；fileRef A5D495A1…）；`zig build` 不在 xcodebuild 内(唯一 script phase 是 SwiftLint，:621)。
- pbxproj objectVersion 70 + `Sources` 为 PBXFileSystemSynchronizedRootGroup（iOS target 用 membershipExceptions 排除）。
- 主 target build settings:bundle id（:785）、CFBundleDisplayName（:758）、INFOPLIST_FILE=Ghostty-Info.plist、NSMainNibFile=MainMenu、CODE_SIGN_ENTITLEMENTS（:745/1143/1198）。
- 图标为枚举 + 运行时生成（AppIcon.swift），非静态 asset——XGhostty 可用代码给默认配色,无需新图标资源。

---

## 3. 里程碑总览

| 阶段 | 内容 | 业余工时 | 出口标准 |
|---|---|---|---|
| **M0** | 自签证书替换 `--sign -` | 0.5h | 重新构建后 Keychain 不再弹授权框 |
| **M1-spike** | 立起 XGhostty 第二 app + 验证 tab 模型 + send_bytes 广播 | 4–6h | 见 §4，spike DoD 全绿 |
| **M1** | 会话树/JSON/SSH 命令构造/广播条/快捷条/重连/防误发 | ~25h | 能天天用 |
| **M2** | askpass 自动登录/组广播/导入/搜索/审计/会话日志 | ~16h | XShell 存量可迁入 |
| **M3** | sftp tab/工作区/trzsz 文档（砍图形 SFTP 面板、渲染层高亮） | ~6h | — |

> 本次执行范围 = **M0 + M1-spike**。spike 结果出来后再细化 M1 任务粒度。

---

## 4. 详细执行步骤（本次执行：M0 + M1-spike）

### M0 — 自签 Code Signing 证书（前置，0.5h）

**为什么**:ad-hoc `codesign --sign -` 的 designated requirement 是逐次构建变化的 cdhash → 每次重 build 后 Keychain ACL 失配弹框,正好砸在“要 ssh 进生产”那一刻。现有 session-sharing token 已踩此雷。

- **M0.1** 造证书（用户手动，Keychain Access）:
  钥匙串访问 → 证书助理 → 创建证书 → 名称 `Ghostty Dev Cert`、身份类型 **自签名根**、证书类型 **代码签名**、有效期拉长（如 3650 天）；确认私钥落在 login 钥匙串。
  - 备选(命令行,执行时我提供脚本):`security` + 带 codesigning EKU 的自签证书导入。GUI 更稳,优先。
- **M0.2** 改签名命令:把 macos/CLAUDE.md 流水线里的 `codesign --force --deep --sign -` 改为 `--sign "Ghostty Dev Cert"`（两个 app 都用这张）。
  - CI/无人值守坑:先 `security unlock-keychain` + `set-key-partition-list`,否则取私钥卡死。
  - 保留 `com.apple.security.cs.disable-library-validation`（Debug/ReleaseLocal entitlements 已带，:7）——自签无 Team ID,需要它。
- **DoD**:`codesign -dv /path/XGhostty.app` 显示 Authority=Ghostty Dev Cert（非 adhoc）；连续两次重 build 后读 Keychain 不弹框。
- **回滚**:改回 `--sign -` 即可，证书留着无害。
- **风险**:低。首次用新证书签旧 ad-hoc 创建的 Keychain item 会弹一次“始终允许”,点过即稳。

### M1-spike — 立起 XGhostty + 验证 tab 模型（4–6h，最高风险先打掉）

> spike 的唯一使命:把全案三个未知数一次性打通——①第二个 app 能否独立立起、②surface 能否进自管 tab 容器、③send_bytes 广播能否真执行。**只写最小验证代码,不做正式 UI。**

- **M1.1 建 XGhostty target**（用户手动 + 我配合）
  - 方法（定）:Xcode GUI 里右键 `Ghostty` target → **Duplicate**（objectVersion 70 + 同步组下,GUI duplicate 最稳;ruby 无 xcodeproj gem，手改 pbxproj 风险高，不走）。
  - 我接手改新 target 两处 config（Debug/Release）:
    - `PRODUCT_BUNDLE_IDENTIFIER = com.liyongda.ghostty.x`
    - `INFOPLIST_KEY_CFBundleDisplayName = XGhostty`、`PRODUCT_NAME = XGhostty`
    - `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 追加 `XGHOSTTY`（Debug 为 `XGHOSTTY DEBUG`）
  - 新建 scheme `XGhostty`（Xcode → Manage Schemes）。
  - **验证点(风险)**:duplicate 后新 target 是否自动含 `Sources` 同步组。若编译报找不到符号 → 在 target membership 勾上 Sources 组。
  - **DoD**:`xcodebuild -project macos/Ghostty.xcodeproj -scheme XGhostty -configuration Debug build` 产出 `XGhostty.app`。

- **M1.2 XGhostty 启动分支**（我写，最小）
  - 文件:`macos/Sources/Features/XGhostty/XGhosttyMode.swift`（新目录,fileSystemSynchronized 自动纳入）。
  - `#if XGHOSTTY`:`applicationDidFinishLaunching` 时**不开**普通终端窗口,改开座舱窗口(下一步);给 AppIcon 默认一个不同 customStyle 配色（区分 Dock 图标）。
  - **DoD**:`open XGhostty.app` 起来是座舱窗口(哪怕先空),Dock 出现第二个图标,⌘Tab 能在 Ghostty / XGhostty 间切。

- **M1.3 最小座舱窗口 + 自管 tab 容器**（我写，spike 核心）
  - `XGhosttyConsoleController : NSWindowController`，窗口横向分:左 = 硬编码 2 台主机的 `List`，右 = surface 容器。
  - 从 `AppDelegate.ghostty`(Ghostty.App) 取 `ghostty.app`,用 `Ghostty.SurfaceView(ghostty_app, baseConfig:)` **独立创建** 2 个 surface,baseConfig.command = `ssh -o ServerAliveInterval=30 user@host`、environmentVariables `["TERM": "xterm-256color"]`。
  - 左 List 点击 → 切换右侧显示哪个 surface（自管,不走原生 tabbing）。
  - **DoD**:一个 XGhostty 窗口里,点左侧在 2 个真实 ssh 会话间切换,各自独立渲染。← **tab 模型可行性最终落地**。

- **M1.4 send_bytes 广播验证**（我写）
  - Swift 给 `Ghostty.Surface` 加 `func sendBytes(_:)`（仿 `sendSharedBytes`，SurfaceView_AppKit.swift:471-477）。
  - 座舱底部一个输入框 + 「发到全部」按钮 → 对 2 个 surface 逐个 `sendBytes(cmd + "\r")`。
  - **DoD**:输入 `echo XGHOSTTY_OK` 点全部 → **两个远端都真正执行并回显**（验证 send_bytes 绕过 bracketed-paste、`\r` 触发执行）。

- **M1.5 签名 + 双 app 共存冒烟**
  - `codesign --force --deep --sign "Ghostty Dev Cert" XGhostty.app`；`open` 之。
  - **DoD**:XGhostty.app 与正在跑 Claude Code 的 Ghostty.app 同时在 Dock,互不影响;重建 XGhostty 不需碰 Ghostty。

**spike 总出口**:M1.1–M1.5 DoD 全绿 = 架构验证完成,后续 M1 全是顺水推舟的 UI 工程。

---

## 5. M1 后续 / M2 / M3 任务清单（spike 后细化）

**M1（填 UI，~25h）**:SessionStore(Codable JSON,schema 与 web 端共用) · SessionCommandBuilder(host/user/port 白名单校验+escape+ServerAlive/TERM/ProxyJump) · 会话树(搜索+键盘流) · BroadcastService(目标 当前/全部/组 + 三态过滤 readonly/exited/passwordInput + 结果反馈 + 次数/间隔) · 快捷命令条(含 secret 型,仅 passwordInput 态可发) · 重连按钮(ChildExitedMessageBar+⌘R) · 防误发(默认OFF/新tab不入全部/armed红框常驻/>3二次确认) · 开组同窗多 tab + 按组自动 tab 色 + “序号 IP”标题钉死。

**M2（~16h）**:SSH_ASKPASS 自动登录(先 30min spike;helper 入 Contents/MacOS、`SSH_ASKPASS_REQUIRE=force`、`StrictHostKeyChecking=accept-new` 防 host-key 劫持) · 组广播 · 简化 expect(等正则→发文本) · XShell/WindTerm 导入(一次性 Python 脚本转 JSON) · 组级快捷命令覆盖 · 广播审计日志 · 会话日志落盘。

**M3（~6h）**:开 sftp tab 按钮 + trzsz 文档 · 工作区(保存 tab 集合一键全部重连)。**砍**:图形 SFTP 面板(30–60h)、渲染层关键词高亮(穿 C ABI,用 `grep --color` 替代)。

---

## 6. 关键技术约束备忘（违反即出 bug）

1. 广播/快捷命令一律 `send_bytes`,行尾 `\r`;**绝不** sendText。
2. SSH surface 必注入 `TERM=xterm-256color`,否则 xterm-ghostty 透传到无 terminfo 的远端 → vim/clear 花屏。
3. `command` 走 `/bin/sh -c`(macOS 落为 `login … bash -c "exec -l <字符串>"`)→ host/user/port 必须白名单校验防 shell 注入;导入文件的 raw 字段默认置灰待确认。
4. 广播前过滤三态:`childExited` / readonly / `passwordInput`(SurfaceView_AppKit.swift:128),并 UI 反馈被跳过者。
5. `command` 非空 → 强制 wait-after-command(留尸 tab,挂重连)且失系统窗口恢复 → 会话恢复自建。
6. 签名用自签证书,非 ad-hoc;否则 Keychain ACL churn。
7. 新文件按需 `#if XGHOSTTY` / `#if os(macOS)`,避免污染 iOS target 与日常 Ghostty。

---

## 7. 风险登记册

| ID | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | duplicate target 未含 Sources 同步组 | 中 | M1.1 验证点;不行则勾 membership |
| R2 | duplicate 改动 pbxproj 与 upstream 合并冲突 | 中 | 一次性;之后稳定;合并用 merge 非 rebase |
| R3 | surface 脱离 controller 后生命周期/焦点异常 | 中 | spike 实测;参考 BaseTerminalController 持有方式 |
| R4 | 自签证书在 CI/无人值守取私钥卡死 | 低 | unlock-keychain + set-key-partition-list |
| R5 | 座舱自管 tab 的 Metal 渲染/resize 适配 | 中 | spike 后专项;复用 SplitTree 既有布局 |
| R6 | upstream 重构 macos/Sources(1.4，2026-09) | 中 | 退出触发器:合并一次 >1 晚则冻结,迁 web 端 |

---

## 8. 分支与 upstream 合并策略

- `feat/xghostty` 从 main 切出孵化 → spike 通过合回 main(仿 session-sharing 模式)。
- upstream 永远 merge 不 rebase;每 2–4 周或 upstream 出 tag 合一次,合完跑冒烟 + i18n 原文 diff 审计。
- 新文件优先,住 `macos/Sources/Features/XGhostty/`;对现有文件触点收敛到最少(duplicate target 改 pbxproj 是唯一大改,一次性)。
- 文档归位:计划文档住 `docs/plan/xghostty.md`(跟随 `session-sharing.md` / `relay-production.md` 惯例);部署类住 `docs/deploy/`;将来 XGhostty 的独立脚本/产物(如导入工具)再住 `contrib/xghostty/`(对应 `contrib/session-sharing/` 装代码的惯例)。

---

## 9. 开放项 / 待决

- bundle id 命名空间 `com.liyongda.ghostty.x` 是否采用。
- 座舱图标配色(spike 先给占位 customStyle)。
- 会话恢复:重启后是否自动重连上次会话集(M1 决定)。
- 与 session-sharing 的 create_session 管道在数据层汇合(多设备),M3 后评估。

---

## 进度

- [x] M0 自签证书（GUI 证书助理造好 `Ghostty Dev Cert`；spike 用 ad-hoc，证书 partition-list 放行留 M1）
- [x] M1.1 建 XGhostty target（duplicate 两坑已修；独立 app 立起，bundle id `top.niandui.xghostty`）
- [x] M1.2 启动分支（`#if XGHOSTTY` 进座舱；无条件 present + 关闭 saved-state 恢复的普通终端，座舱每次稳定拉起）
- [x] M1.3 座舱窗口 + 自管 tab（`Features/XGhostty/XGhosttyConsole.swift`：`SurfaceView` 脱离原生 tabbing、isHidden 叠放切换 ✅）
- [x] M1.4 send_bytes 广播验证（`echo XGHOSTTY_OK` 两会话都执行 ✅；`SurfaceView.xghosttySendBytes` + `\r`）
- [x] M1.5 签名 + 双 app 冒烟（ad-hoc；双 Dock 图标共存，日常 Ghostty 不受影响 ✅）

**M1-spike 全绿（2026-06-12）——架构三大未知数验证通过：单窗口自管多 surface + send_bytes 广播在 Ghostty 上成立。**
另：spawn 的 shell 默认丢 UTF-8 locale → 中文乱码，靠 `environmentVariables = ["LANG": "en_US.UTF-8"]` 注入修复（正式版 ssh 同样走 env 注入 TERM/LANG）。

### M1 正式 UI —— 第一批（2026-06-12，已验证）

数据层 + 三大栏 + 布局，均 `#if XGHOSTTY`，落在 `Features/XGhostty/`：

- [x] **SessionStore.swift** — `SessionNode`（Codable 树，`host==nil`=本地 shell）/ `QuickCommand` / `StoreDocument`，持久化 `~/.config/xghostty/sessions.json`（0600，旧纯数组格式兼容）。种子：本机 shell + 一个示例主机（`192.0.2.10 root 22`）+ 4 条快捷命令。
- [x] **SessionCommandBuilder.swift** — 纯函数构造 ssh 命令，host/user/port/proxy **白名单校验**防注入；注入 `ServerAliveInterval=30/CountMax=3`、`TERM=xterm-256color`、`LANG=en_US.UTF-8`；ProxyJump→`-J`。
- [x] **会话树**（SwiftUI `OutlineGroup`）双击开/切、右键关、已开绿色高亮。
- [x] **顶部会话 Tab 栏**（自绘 SwiftUI，彩点+名称+✕，当前 tab 高亮+顶部 accent 条），驱动自 `openOrder`。
- [x] **快捷命令条** — 独立窄条（终端宽、贴终端下方），**只发当前会话**（不随广播下拉变化，防误喷全场）。
- [x] **批量发送条** — 独立窄条（整窗宽、钉最底）：目标下拉（当前/全部已开）+ 三态过滤（`processExited`/`passwordInput`）+ 全部时红框警告显命中数 + `>3` 二次确认。
- [x] **布局重构** — `NSSplitView`（左树↔右栏可拖）+ 右栏 Auto Layout（tab / 终端 / 快捷条）+ 批量条钉窗底。**终端用 `SurfaceScrollView` 包裹**：修复裸 `SurfaceView` 不调 `sizeDidChange` 致 grid 卡初始尺寸、不随窗口缩放的 bug；同时白送 Ghostty 原生 scrollback 滚动条。

**关键修复（布局）**：裸 `Ghostty.SurfaceView` 加约束撑满容器后，**view frame 会变但终端 grid 不变**——因为 `sizeDidChange()` 不是 NSView 自动回调，而是 `SurfaceScrollView.layout()` 里手动喂的。所以自管容器里挂 surface **必须用 `SurfaceScrollView(contentSize:surfaceView:)` 包裹**，否则终端永远卡在初始 cols/rows。

> 分隔条最终方案：三条全可拖（左树↔右栏 / 终端↔快捷条 / 上部整块↔批量发送条），经典 frame 模式 `ConsoleSplitView`（`translatesAutoresizingMask=true` 的 pane + delegate 限 min/max + `drawDivider` 自绘 2px），最外层 `outerSplit` 套住 mSplit + sendBar。

### M1 正式 UI —— 第二批（2026-06-12，已验证）

- [x] **多 tab 架构重构**：按 `tabId`（而非 node.id）索引 `tabs/tabOrder/currentTabId` + `OpenTab` 类，支持同一主机/多个本地 shell 同时多开。
- [x] **顶部 tab 空白双击** → 新建本地 shell（`SessionTabBar` 加 `onNewTab` + `Color.clear` 双击区，`GeometryReader` 撑满宽度才点得到右侧空白）。
- [x] **⌘T 复制当前会话 + 继承目录**：本地用 `cfg.workingDirectory`；ssh 等新会话「登录就绪」（远端首次上报 pwd）后再 `send_bytes` `cd`——避免 cd 在 ssh 认证阶段被吞（原因：`initialInput` 对 ssh 发太早）。
- [x] **⌘N 新窗口**：`static all: [Controller]` 多窗口；`window.delegate=self` + `windowWillClose` 移除；`presentInitial` 改「无窗口才建」。
- [x] **⌘W 关当前 tab、⌘T/⌘N 拦截**（原本冒泡到主 app 开原始 Ghostty 窗口）：全在座舱 `NSEvent.addLocalMonitorForEvents`。
- [x] **会话树搜索保持分组层级**：无词 `OutlineGroup`，有词递归 `SessionTreeRows`（过滤树 + 缩进 + 全展开），匹配 name/host。
- [x] **终端搜索高亮**：复用 Ghostty `searchState`（设 `SearchState` → 框架发 `search:needle`、C 回调回填 total/selected）；⌘F 唤出右上角搜索栏、Esc 关、‹/› 翻页、n/m 计数。
- [x] **tab 图标同步会话图标**（绿 `terminal.fill`）；**window.title = 当前选中 tab 名称**。
- [x] **exit 行为**：直接跑 ssh、`exit` 关当前 tab、焦点落到剩余最后一个、无 tab 关窗口（订阅 `$childExitedMessage`）。
- [x] **ssh 远端目录跟踪（OSC 7 注入）**：`ssh -t host '<bootstrap>'` 位置参数（兼容老 OpenSSH，不用 `RemoteCommand`，失败只降级不断连）；bootstrap = `export PROMPT_COMMAND='printf OSC7'; exec "${SHELL:-/bin/bash}" -l`。

**关键坑（OSC 7 host 必须写 `localhost`）**：Ghostty core 故意拒绝非本机 hostname 的 OSC 7（`src/termio/stream_handler.zig` `isLocal(host)` 校验，防 ssh 伪造本地路径），远端真实 `$HOSTNAME` 会被丢弃 → pwd 不更新 → ⌘T 读不到目录。解法：注入的 OSC 7 host 写字面 `localhost`（`isLocal("localhost")` 恒真）。core 一行没改，只在 XGhostty 侧配合规则。

**构建铁律重申**：纯 Swift 改动 `xcodebuild -scheme XGhostty -configuration Debug build` 后**直接 `open`，不要手动 `codesign --deep` 重签**（会触发 `Launch Constraint Violation` SIGKILL）。

### M1 正式 UI —— 第三批（2026-06-13，已验证）

会话管理（CRUD / 复制粘贴 / 多选），全 `#if XGHOSTTY`，落在 `Features/XGhostty/`：

- [x] **会话增删改 UI**：左树右键（分组：新建子会话/子分组·重命名·删除；会话：打开·编辑·删除）+ 左下 `＋` 工具条（新建到根）+ `SessionEditView` sheet。`SessionStore` 加 `add(_:toParent:)/update(_:)/remove(_:)/parentId(of:)/cloneWithNewIds(_:)`（递归重建不可变树 + 落盘）。
- [x] **编辑表单**：名称 + host/port/user/proxyJump + 登录命令；保存复用 `SessionCommandBuilder.build` 做白名单校验。**host、user 必填**（本地 shell 走 tab 空白双击，不在表单建）；**名称留空→用 host(IP) 顶上**；分组名必填。
- [x] **复制粘贴**：右键复制（深拷贝换全子树 id）；粘贴目标=分组内/会话同级/根；剪贴板升 `[SessionNode]` 支持批量。
- [x] **多选**：`selectedIds` + `selectionAnchor` 在 controller；单击单选、⌘单击切换、⇧锚点到当前**范围选**（`visibleOrder()` 算可见行顺序）；选中行 accent 高亮；右键多选时切**批量菜单**（复制/删除 N 项）；**⌘⌫ 删除选中**（keyCode 51）。
- [x] **双击=总是新开 tab**（允许同会话多开）；右键「切到已打开」`switchToSession` 切到首个已开 tab。
- [x] **tab 关闭 ✕ 修复**：原 `.onTapGesture+.contentShape` 覆盖整条 tab 吃掉小 ✕；改 `ZStack` 双独立 Button（底层选中、顶层关闭）。
- [x] **sheet 主题一致**：编辑 sheet `sheet.appearance = window?.appearance` + `backgroundColor` 继承座舱明暗。
- [x] **Dock 重开修复**：`AppDelegate.applicationShouldHandleReopen` 加 `#if XGHOSTTY` 分支 → 无可见窗口时 `presentInitial` 座舱（原本走原始 `TerminalController.newWindow` 开普通 Ghostty 终端）。
- [x] **会话树扁平重构**：`List(.sidebar)+DisclosureGroup` → `ScrollView+LazyVStack(spacing:2)`（消 List 固有行距、选中块连续贴合 + 为拖拽铺路）；`SessionTreeRow{node,depth}` + `flatten(expanded:)` 算可见行；`SessionRowView` 自带 depth 缩进 + 手动展开三角；单击/双击改 `simultaneousGesture`（count:1 即时选中不等 count:2 超时 → 消除选中延迟）；选中高亮 `RoundedRectangle(cornerRadius:3)` 填满整行。
- [x] **多选 / 批量**：单击单选 / ⌘切换 / ⇧范围（`selectionAnchor`+`visibleOrder()`）；右键多选 →「打开 / 复制 / 删除 选中 N 项」；`⌘⌫` 删除选中；分组右键「打开本级会话（直接子级）/ 打开全部会话（递归）」。
- [x] **连接信息首行**：打开 ssh 会话，终端首行 `printf` 暗灰连接串（`SessionCommandBuilder.displayCommand`，只 user@host/-p/-J）。**坑**：Ghostty 对 `command` 是 `exec -l <argv0>`，`printf …; ssh …` 用 `;` 串联只会 exec 到 printf、跑完即退 → tab 闪退；必须裹进 `/bin/sh -c '<script>'`（脚本内单引号用 `'\''` 转义，与 OSC7 bootstrap 同法）。

**关键坑（SwiftUI 右键菜单 disabled / 高亮不刷新）**：`canPaste`、`isSelected`、`selectedCount` 必须作为**显式值（Bool/Int/Set）传入每个 view**，不能藏在闭包里（如 `canPaste: () -> Bool`）。`clipboard`/`selectedIds` 是 controller 的普通可变状态，SwiftUI 观察不到；只有显式值参与 `View` diff，变化（`false→true`）才会触发受影响行重渲染、菜单 `.disabled`/背景才更新。否则现象是「复制后粘贴仍灰，要等另一个 Bool 输入（如 isOpen）变了才连带刷新」。单击修饰键用 `NSEvent.modifierFlags`（SwiftUI `onTapGesture` 读不到 ⌘/⇧）。

### 待办规划（2026-06-13 用户新增，分批执行 —— **已全部完成**）

执行顺序按价值/风险定为：批 A（④⑤）→ 批 B（③）→ 批 C（①②），均已完成。

1. **拖拽改层级** ✅（批 C，见下「第六批」）。
2. **拖拽改顺序 + 按名称排序** ✅（批 C，见下「第六批」）。
3. **配置页面 + 布局持久化** ✅（批 B，见下「第六批」）。
4. **快捷命令（QuickCommand）增删改** ✅（批 A，见下「第四批」）。
5. **SSH 密钥登录（`-i` identity file）** ✅（批 A，见下「第四批」）。

### M1 正式 UI —— 第四批（2026-06-13，批 A：鉴权 + 快捷命令，已构建启动待验）

全 `#if XGHOSTTY`，落在 `Features/XGhostty/`：

- [x] **SSH 密钥登录（⑤）**：`SessionNode.identityFile: String?`（Optional → 旧 JSON 缺字段解码为 nil，向后兼容）；`SessionCommandBuilder.build` 拼 `-i '<展开后的绝对路径>' -o IdentitiesOnly=yes`（路径单引号包裹防注入 + `~` 先本地展开，因单引号会阻断 shell 展开；`IdentitiesOnly=yes` 强制只用此钥匙，避免 agent 多钥匙触发 *Too many authentication failures*）；`displayCommand` 首行连接信息显示 `-i ~/.ssh/xxx`（`abbreviatingWithTildeInPath`）。`SessionEditView` 加「密钥文件」字段 + `NSOpenPanel`（`canChooseFiles`、`showsHiddenFiles=true` 看见点目录、`directoryURL` 定位 `~/.ssh`），保存存 `~` 缩写形式；保存时校验本地文件存在（`ssh -i` 需私钥落地），不存在则拦在表单。
- [x] **快捷命令增删改（④）**：`QuickCommandEditView` sheet（`ForEach($items)` 行内绑定，名称 + 命令 + 删除，底部「添加一条」追加空行，保存丢弃空行后 `store.setQuickCommands` 整体写回）；`QuickCommandBar` 最左加「管理」入口（`slider.horizontal.3`）→ 弹面板；`makeQuickBar()`/`refreshQuickBar()` 工厂化，保存后即时刷新快捷条。sheet 同样继承座舱 appearance + 背景色。

**坑/注意**：① `identityFile` 用 Optional 才能向后兼容旧 `sessions.json`（合成 Codable 对 Optional 用 `decodeIfPresent`，缺字段 → nil，不报错）。② `-i` 路径走 `/bin/sh -c '<script>'` 外层再被 `shellQuote` 转义一次（与 OSC7 bootstrap 同链路），内层单引号经 `'\''` 逃逸，嵌套引用成立。③ `NSOpenPanel` 在 sheet 之上用 `runModal()` 直接弹，不需另接 window。④ `SessionEditView` 新增 `import AppKit`（用 NSOpenPanel）。

### M1 正式 UI —— 第五批（2026-06-13，Ghostty 风格统一 + ⌘F 复用原生 + 标题栏同色，已验证）

涵盖批 A 之后用户连续提的一连串 UI / 风格诉求，全 `#if XGHOSTTY`：

- [x] **多行支持**：快捷命令 command + 批量发送框都支持多行。发送统一走 `sendBytes(for:)`——多行按「每行一条命令」逐行执行（`\r\n`/`\n` → `\r`，末尾补一个 `\r`），`send_bytes` 直写 pty，每行被远端 shell 当独立命令。批量发送框 `usesSingleLineMode=false`，默认≈一行高（发送条 `outerSplit` 下格、分隔条可拖高看多行），**⌘⏎ 发送、⏎ 换行**（多行编辑时回车不误发）。
- [x] **快捷命令交互重做**（XShell 式，**废弃第四批的「管理面板 / 管理入口」**）：快捷条最左 `+` 新增；命令按钮**左键发送、右键菜单（编辑/删除）、长按拖动排序**（三手势共存）；`QuickCommandEditView` 改单条编辑表单（1:1 复刻 `SessionEditView`）；`SessionStore` 加 `addQuickCommand/updateQuickCommand/removeQuickCommand`；拖拽重排 `onDrag`/`onDrop` + `DropDelegate`，松手 `setQuickCommands` 回写。
- [x] **所有控件对齐 Ghostty 风格**：参照命令面板（`CommandPalette.swift:258` 用 `.textFieldStyle(.plain)`）。新建 `XGhosttyFieldStyle.swift`：`consoleFieldBox()`/`consoleEditorBox()` = `.plain` + `Color.primary.opacity(0.06)` 填充 + `0.18` 描边（明暗自适配），所有表单输入框统一；目标下拉从系统 `NSPopUpButton` 换成 **borderless `Menu` + 自绘 label**（仿 `SurfaceView.swift:304`），`broadcastAll` 标志驱动；批量发送框（AppKit）用 `inputBg` 圆角半透明容器包透明 `NSTextField`。
- [x] **sheet 背景铺座舱色**：`makeThemedSheet` 给 sheet 内容 `.background(Color(nsColor: bg))` + hosting layer 背景（单设 `window.backgroundColor` 会被 NSHostingController 内容盖住、无效）。
- [x] **标题栏与窗口同色**（仿 `TransparentTitlebarTerminalWindow`，macOS 26 Tahoe 路径）：`applyTitlebarTheme()` = `titlebarAppearsTransparent=true` + `titlebarSeparatorStyle=.none` + 从 `contentView.superview` 找 `NSTitlebarContainerView`→`NSTitlebarView` 染 `bg` + 隐藏 `NSTitlebarBackgroundView`；在 `applyTheme` + 布局后 + `windowDidBecomeKey` 各重应用一次（系统激活时会重置标题栏）。
- [x] **⌘F 复用 Ghostty 原生 `SurfaceSearchOverlay`**：删掉自造 `makeSearchBar`（NSSearchField + ‹›✕ + 计数 + `NSSearchFieldDelegate`）整套；`xghosttyStartSearch()` 只建空 `searchState`，再用 `NSHostingView` 挂 `Ghostty.SurfaceSearchOverlay(surfaceView:searchState:onClose:)`，needle/计数/翻页/Esc 全交给它，样式天然与主 app 一致；切 tab 自动关搜索。

**坑（本批，换机/重做必看）**：
1. **`open` 前必须 kill 旧实例**：`open` 同 bundle id 已运行的 app 只激活旧实例、**不换新二进制** → 改了代码没反应（新字段/入口都"没有"）。每次 `PID=$(ps -A -o pid,comm | awk '/XGhostty.app\/Contents\/MacOS\/ghostty/ {print $1}' | head -1); kill "$PID"` 再 `open`。
2. **CALayer 的 dynamic NSColor `.cgColor` 不跟明暗**：`inputBg` 在 `buildUI`（座舱 appearance 未定）解析 `labelColor.cgColor` 会按 **light** 出「6% 黑」，与 SwiftUI 动态色「6% 白」不一致（现象：两个输入框背景一暗一亮）。必须在 `applyTheme` 里 `window.appearance.performAsCurrentDrawingAppearance { … }` 上下文解析。
3. **自定义 `hitTest` 穿透会误杀 SwiftUI Button**：`SurfaceSearchOverlay` 的 ‹›✕ 是 SwiftUI 绘制（无 backing NSView），`hitTest` 返回 hosting `self`；`hit === self ? nil` 的穿透把按钮点击吞了（TextField 有真 view 不受影响 → 现象「框能输入、按钮点不动」）。**用普通 `NSHostingView`**——SwiftUI 自身命中测试让搜索条拦截、透明区穿透、按钮正确分发，别自己 override hitTest。
4. `SurfaceSearchOverlay` 是 `Ghostty` 直接成员（`Ghostty.SurfaceSearchOverlay`）、internal、不依赖 ghostty environment（只要 `surfaceView`+`searchState`+`onClose`），@State private 不影响 memberwise init 跨文件可见。
5. `NSWindow.backgroundColor` 是 IUO，存进 `let bg` 被推断成 optional → 取 `.cgColor` 报错；直接 `window.backgroundColor.cgColor`。

### M1 正式 UI —— 第六批（2026-06-13，批 B 布局持久化 + 批 C 会话树拖拽，已验证）

补齐待办 ①②③，全 `#if XGHOSTTY`：

- [x] **布局持久化 + 配置页（③）**：`LayoutStore`/`ConsoleLayout`（Codable → `~/.config/xghostty/layout.json`，0600）存窗口 frame + 三条分隔条位置（mainSplit 左树宽 / rightSplit 终端高 / outerSplit 上部高，读 `subviews.first?.frame` 的 width/height）+ 展开态 + autoSave/sortByName 偏好。启动 `init` 还原 frame（**仅首个窗口**，后续居中避免完全重叠）+ 展开态；async 块按保存值或默认 `setPosition`。交互防抖保存（`windowDidResize`/`windowDidMove`/`splitViewDidResizeSubviews`/`toggleGroup` → `scheduleSaveLayout` 0.4s 防抖；`windowWillClose` flush 一次）。`ConsoleSettingsView` sheet（**⌘, 或左下齿轮入口**）：自动保存开关 + 按名排序开关 + 还原默认布局。
- [x] **拖拽改层级 / 重排（①）+ 按名排序（②）**：扁平树行 `onDrag`/`onDrop` + `TreeDropDelegate`，落点按行内纵向位置（`DropInfo.location.y` / 估算行高）判 `before`/`after`/`into`——上 30% 插前、下 30% 插后（同级）、分组中 40% 移入；视觉 before/after 画插入线、into 画整行蓝框。`SessionStore.move(_:toParent:atIndex:)`（先删后插 + `contains(inSubtreeOf:)` 防把分组移进自己子树）；`insertSibling` 处理 off-by-one。按名排序为展示层（`flatten` 里 `localizedCaseInsensitiveCompare`，不动存储顺序），开关存 layout.json。

**坑（本批）**：
1. **SwiftUI onDrag 的 drag 预览在 drop 后有系统级淡出「尾影」**，async 刷新 / 自定义卡片预览都治不了（async 反而让淡出动画完整播放、残影更普遍）。解法：`onDrag(_:preview:)` 给**透明 1×1 `Color.clear`** 预览 → drag image 不可见 → 淡出不可见 = 无残影；拖拽反馈完全交给落点插入线 / 移入蓝框（跟手）。
2. **落点 off-by-one**：`move` 先删后插，同父且 dragged 原在 target 之前时，删除让 target 下标左移 1，插入点要 -1。
3. `ConsoleLayout` 新增字段（如 sortByName）用 **Optional**，兼容已存在的 layout.json（synthesized Codable `decodeIfPresent`）。
4. 布局 frame 还原**只给首个窗口**（`all.isEmpty`），否则多窗口完全重叠。

> **M1 待办（①–⑤）至此全部完成。** 后续方向：M2（askpass 密码自动登录 / 组广播 / XShell 导入 / 会话日志）、与 session-sharing 数据层汇合做多设备。

### M1 正式 UI —— 第七批（2026-06-13，标题栏路径 + session-sharing 共享设置重写，已验证）

- [x] **标题栏加路径**（XGhostty）：`window.title` =「当前会话名 · 当前目录（~ 缩写）」，订阅当前 surface 的 `$pwd`（OSC7 跟踪）实时更新（`updateWindowTitle()` + `titlePwdCancellable`，切 tab 换订阅）。分隔符用 middle dot `·`。
- [x] **session-sharing「共享设置」重写成 SwiftUI sheet**（主 app 跨界，用户选「重写」方案）：旧 `NSAlert` + AppKit 控件（`SessionSharingSheetContentView`，已删 145 行）→ 新 `SessionSharingSheetView`（`Ghostty/Surface View/SessionSharingSheetView.swift`，`#if os(macOS)`）。会话名 / 中转服务器（TextField + 历史 Menu）/ 认证令牌（SecureField）/ 保存·上传·自动清理 3 开关 / 天数 Menu / 实时校验红字 + 启动共享禁用态；输入框 `.textFieldStyle(.plain)` + 半透明圆角（命令面板风格）。`presentSettingsSheet`（`SessionSharingController`）改 themed `NSWindow` sheet，背景铺 `surfaceView.derivedConfig.backgroundColor`（终端色）。**逻辑一字未改**（trim + `SessionSharingSheetValidation`、`reconcile` 自动清理、`store.save` 含 relay 历史 / Keychain、`startSharing`）。
- [x] **XGhostty 加 ⌃⇧S 共享入口**：座舱主菜单的「共享此会话」走 `BaseTerminalController` 响应链、XGhostty 没有该 controller → 菜单 + 快捷键全禁用；在座舱 keyMonitor 加 `⌃⇧S` → `currentSurface?.toggleSessionSharing(from: window)`，sheet 弹在座舱窗口、背景终端色。

**坑**：① XGhostty 用主 app 的 MainMenu，但凡 target 是 `BaseTerminalController`/`TerminalController` 的菜单项在座舱里都点不动（响应链没有这些 controller）——要用就得在座舱 keyMonitor 自己接 binding action / surface 方法。② session-sharing UI 在共享文件，改它主 app + XGhostty 两个 target 都要编译过；`NSColor(swiftUIColor)` + `isLightColor` 是现成 extension。

### M2 —— 第八批（2026-06-13，SSH 密码自动登录 SSH_ASKPASS，已构建启动**待真机验证**）

M2 头号项，与已完成的密钥登录（⑤）凑成「密码 + 密钥」两种鉴权闭环。全 `#if XGHOSTTY`：

- [x] **Keychain 凭据存储** `XGhosttyCredentialStore`：密码绝不进 `sessions.json`，只进 macOS Keychain（generic password，account=会话 UUID，service=`top.niandui.xghostty.ssh`）。沿用 session-sharing token 的 update-first + `kSecAttrAccessibleWhenUnlocked` 模式。`password(for:)` 取 data（可能弹 ACL）、`hasPassword(for:)` 只查存在性（不取 data → 不弹框，编辑表单显「已保存」用）、`setPassword`/`removePassword`。
- [x] **SSH_ASKPASS helper** `XGhosttyAskpass`：ssh 跑在 pty 有 tty，默认不用 askpass → 必须 `SSH_ASKPASS_REQUIRE=force` 强制（需 OpenSSH ≥ 8.4，macOS 15+ 自带 9.x）。密码投递不碰 Keychain ACL（规避 ad-hoc 签名 churn）：控制器从 Keychain 取出密码 → 写 0600 临时文件（`~/.config/xghostty/.askpass/<uuid>`，以 0600 直接 `createFile`，避开 `write(atomically:)` 的权限窗口）→ 路径经 `XGHOSTTY_ASKPASS_FILE` 环境变量传给脚本；脚本 `cat` 后**立即 `rm` 自删**（密码在盘上只活到 ssh 读走一瞬）；pubkey 先成功→askpass 不被调→控制器 20s backstop 定时器兜底删。
- [x] **命令行选项** `SessionCommandBuilder.build(for:passwordAuth:)`：始终加 `-o StrictHostKeyChecking=accept-new`（新主机免 yes/no 卡住自动登录，**变更指纹仍拒**防中间人；密码登录尤其依赖它，否则 yes/no 会被 askpass 当密码答进去）；`passwordAuth=true` 再加 `-o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password -o NumberOfPasswordPrompts=1`（跳过 agent 多钥匙避免 Too many auth failures，密码错只提示一次即失败）。
- [x] **开会话接线**（`openTab`）：仅当 `identityFile == nil`（密钥优先）且 Keychain 有密码时取出 → `XGhosttyAskpass.prepare` → merge 进 `cfg.environmentVariables`。
- [x] **编辑表单密码字段**（`SessionEditView`）：SecureField（永远空起步、不把密文读进字段）；`hadPassword` 决定占位文案（「已保存，留空保持不变」/「留空＝不存密码」）；有存密码时显「清除已存密码」按钮（→`clearPassword` 标志 + 撤销）。保存：非空＝`setPassword`、空且点清除＝`removePassword`、否则不动（编辑不误删已存密码）。
- [x] **删除会话清密码**：`purgePasswords(in:)` 递归子树，`deleteNode`/`deleteSelected` 删除前调用，避免孤儿 Keychain 项。

**待验证（真机 spike 出口）**：对真实需密码登录的主机，配好密码后双击 → **ssh 不弹密码提示、直接登录成功**。验证 `SSH_ASKPASS_REQUIRE=force` 在 Ghostty 的 pty 里被 macOS ssh 认账。若不认账（仍在终端里要密码）→ 退路是 expect 式（监听终端输出 `assword:` → `send_bytes` 密码，复用已验证的广播原语）。

**坑/注意**：① `SSH_ASKPASS_REQUIRE=force` 是关键——有 tty 时 ssh 默认 getpass 读 tty、忽略 askpass，只有 force 才强制走 askpass。② host-key：必须配 `accept-new`，否则首连 yes/no 提示走 askpass 被当密码。③ 密码本身**不进环境变量**（只传临时文件路径），环境变量 `ps eww` 可被同用户进程读到，路径泄露无害。④ 密钥与密码互斥：`identityFile != nil` 时不取密码（密钥优先），且 `passwordAuth` 关 pubkey 仅在纯密码会话生效。⑤ ad-hoc 签名下重建后首次 `password(for:)` 取 data 会弹一次 ACL 授权框，点「始终允许」即稳（`hasPassword` 不取 data 不弹）——这正是 M0 自签证书要根治的。

### M2 —— 第九批（2026-06-13，密码登录完善 + Keychain 反复授权根治，真机验证通过）

- [x] **密码框自动切英文**：`ASCIISecureField`（NSSecureTextField + `cell.allowedInputSourceLocales=[NSAllRomanInputSourcesLocaleIdentifier]`），聚焦自动切 ABC、失焦还原，根治全角字符混入（曾因一个全角字符致 13 字符密码变 15 字节、认证失败）。
- [x] **密码/密钥二选一**：SessionEditView 顶部 segmented「认证方式」，互斥（选密钥清密码、选密码清密钥路径）。
- [x] **复制会话连密码**：`cloneWithNewIds(_:idMap:)` 回填旧→新 id 映射，paste 时按映射搬 Keychain 密码。
- [x] **登录失败可见 + 重连**：ssh 会话 `waitAfterCommand=true` 留「尸体 tab」展示 `Permission denied`，不再静默关闭；终端容器顶部不透明红横幅（`exitBar`）+ 重连/关闭。
- [x] **绿图标=真登录成功**：`OpenTab.connected`（本地 shell 即真；ssh 等远端首次 OSC7 pwd）；树 `connectedIds`（与菜单用的 `openIds` 拆开）+ tab 栏三态（连接中灰/已连接绿/尸体红）；OSC7 bootstrap 登录瞬间立即 emit 一次（任何 shell 生效、兼容 zsh）。
- [x] **Keychain 反复授权根治**（用户反馈「不同会话反复输密码」）：
  - 病根：每会话密码各占一个 Keychain item（独立 ACL，每台首读各弹一次）+ ad-hoc 签名指纹每次重建变（「始终允许」记不住）。
  - **(A) 单一保险库**：`XGhosttyCredentialStore` 重写——所有密码塞进**一个** item（service `top.niandui.xghostty`/account `vault`，值=JSON `[id:密码]`）→ 一次授权覆盖全部；首读后内存缓存常驻（每次启动至多弹一次）；明文索引 `~/.config/xghostty/.cred-index.json`（无密文，`hasPassword` 不弹框）；旧逐会话 item 懒迁移。
  - **(B) 自签证书签名**：`Ghostty Dev Cert` 信任后（`sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain`），改 XGhostty Debug `CODE_SIGN_IDENTITY=Ghostty Dev Cert`/`Manual`（pbxproj 块 `04775E49…`，备份 `project.pbxproj.bak-codesign`）→ 签名指纹稳定、重建不再弹；entitlements 已带 `disable-library-validation`；`verify --deep --strict` 过、启动存活。**主 Ghostty.app 仍 ad-hoc 未动**。

**坑**：① pbxproj 改签名只动 XGhostty Debug 块（按 config UUID 锚定，别误伤主 Ghostty 或 Release）。② `Ghostty Dev Cert` 之前 `CSSMERR_TP_NOT_TRUSTED` 不可用，只差「信任」不必重造（有私钥 + Code Signing EKU）。③ 保险库迁移：旧 service account 列表用 `kSecReturnAttributes`（不读 data）并入索引 → hasPassword 对历史密码也准，不弹框；真正迁移在 `password(for:)` 懒触发。

### M2 —— 第十批（2026-06-13，密码库 / 凭据管理界面，已构建启动）

- [x] **密码库**：`CredentialLibrary` + `Credential{id,name,username?}`，元数据 → `~/.config/xghostty/credentials.json`（0600）；密码进保险库（account=凭据 id，与会话内联密码同库、UUID 不撞）。
- [x] **管理界面**：左树底部 🔑 入口 → `CredentialLibraryView`（themed sheet，单 sheet 内「列表↔编辑」模式切换，CRUD，`ASCIISecureField`）。
- [x] **会话引用**：`SessionNode.credentialId`（Optional 向后兼容）；`SessionEditView` 密码区加「密码来源」Menu：直接输入（内联，按 node.id）/ 选具名凭据（按 credentialId）。`openTab` 解析 `credKey = credentialId ?? node.id`。
- [x] **互斥/共享**：选密钥或选凭据都清本会话内联密码；复制会话保留 credentialId（共用同凭据）；删会话不删凭据。多台共用一套密码、改一处全生效。

### M2 —— 第十一批（2026-06-13，密码库修复 + ⌘A 全选 + 取消按钮，已验证）

- [x] **密码库列表首次为空修复**：真因=`ScrollView` 在自适应尺寸的 `NSHostingController` 里没有确定高度会塌成 ~0、行被裁没（空状态因 `minHeight:80` 才有高 → 显得时有时无）。改 `.frame(height: min(条数*46+4, 260))` 确定高度；`CredentialLibrary` 改 `ObservableObject`（`@Published credentials`）+ 视图 `@ObservedObject` 直接观察（去 `@State` 快照 + `.onAppear` 兜底）。**坑：自适应 sheet 里的 ScrollView/flexible 视图必须给确定高度**。
- [x] **取消按钮**：密码库 + 设置界面都加可见「取消」（`.cancelAction`/Esc）。
- [x] **会话列表 ⌘A 全选**：`FocusableHostingView`（`acceptsFirstResponder=true`）做 treeHosting，点树时 `makeFirstResponder` 夺焦；keyMonitor ⌘A 按 first responder 是否在 `surfaceContainer`/是否 `NSText` 判定——终端/搜索框交给它们，否则全选 `visibleOrder()`。

### M2 —— 第十二批（2026-06-13，组广播，已构建启动）

- [x] **广播目标三态**：`enum BroadcastTarget { case current/.all/.group(UUID) }` + 目标下拉 `BroadcastTargetPicker`（当前 / 全部 / 分组:xxx）。`broadcastTargets` 按枚举解算命中 surface（组=该组下叶子 id ∩ 已开 tab）；`updateBroadcastWarning` 以 `!= .current` 驱动红框；`onBroadcast` 在 `!= .current && 命中>3` 时二次确认。`refreshTree` 刷新 picker，选中组被删则回落 `.current`。

### M2 —— 第十三批（2026-06-13，XShell / WindTerm 导入 + 批量凭据映射，已验证）

- [x] **导入器 `XGhosttyImporter`**（纯函数、可单测）：`importWindTerm(from:)` 找 `…/terminal/user.sessions`（递归、优先 `/terminal/`）解析 JSON，只导 `protocol==SSH`；`importXshell(from:)` 递归 `*.xsh`（UTF-16LE INI、去 BOM）。字段映射：target→host、port、label→name、`group(a>b>c)` / 相对目录 → 嵌套分组、autoExecution / ExpectSend(Count==1) → loginCommands、`ssh.identityFilePath.macos`→identityFile。统一包进「来源 导入」顶层分组，不污染现有树。
- [x] **批量密码映射（关键）**：两边密文都**无法解密**，但不用解密——按 WindTerm oneKey / XShell UserName **自动建密码库凭据**（按名字去重、已存在复用），会话 `credentialId` 指过去。填几次密码即覆盖全部引用会话（WindTerm 各 oneKey、XShell 各用户名各建一条）。WindTerm 用户名取 oneKey name 首个 `-` 前段（如 `root-2`→root，去掉凭据变体后缀）。
- [x] **UI**：左树 `＋` 菜单加「从 WindTerm/XShell 导入…」→ `NSOpenPanel`（默认定位 `~/.wind` / Xshell Sessions）→ 解析 → 二次确认（会话/分组/凭据数）→ 合并落盘 + 建凭据（密码留空）+ 展开顶层。非沙盒，仍按安全作用域包裹一次。

### M2 —— 第十四批（2026-06-13，密钥库凭据 = 统一凭据库，已构建启动）

- [x] **模型扩展**：`Credential` 加 `kind: CredentialKind?`（nil/.password 兼容旧 JSON / .key）+ `keyPath: String?`。秘密统一存保险库（account=凭据 id）：密码凭据=密码、密钥凭据=可选 passphrase。
- [x] **密码库 UI**：编辑器加类型切换（密码/密钥）；密钥 → 私钥路径（可浏览 `~/.ssh`）+ passphrase；列表行区分（`key.horizontal.fill` + 「密钥」标签 + 显示路径）。
- [x] **会话表单对称**：密钥侧也加「密钥来源」下拉（会话指定路径 / 密钥库凭据）；密码侧来源只列密码凭据。
- [x] **登录解析重构 `resolveAuth`**：① 会话级密钥路径 > ② 引用凭据（密钥取路径+passphrase / 密码取密码）> ③ 内联密码。密钥凭据路径并入 `effective.identityFile` 走 `ssh -i`；秘密统一经 SSH_ASKPASS 注入（密码 or passphrase）。导入时名字含 `id_rsa`/`.pem` 的 oneKey 建成密钥凭据（路径探测 `~/.ssh/<词>/<stem>` 实际存在则用，如名字含某子目录名 → `~/.ssh/<子目录>/id_rsa`）。

### M2 —— 第十五批（2026-06-13，SSH 认证兼容性，真机验证通过）

- [x] **每会话「仅用密码」开关**：`SessionNode.passwordOnly: Bool?`；表单密码侧勾选。`SessionCommandBuilder.PasswordPolicy{none/auto/strict}`：**auto（默认）= 先试默认公钥再密码**（同一密码身份兼容「只收密钥」与「只收密码」的混合机群，复刻 WindTerm www）；strict=关 pubkey 仅密码；none=密钥/无凭据。
- [x] **老服务器 RSA-SHA1 兼容**：全 ssh 命令加 `-o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa`（append 形式，现代机仍协商强算法，仅对只剩 ssh-rsa 的老机回落）。**真机实锤**：WindTerm 走 libssh2 默认支持，OpenSSH 9+ 默认禁用故需显式开。
- [x] **踩坑（真机）**：私钥文件权限必须 0600，OpenSSH 拒绝加载 0644 的钥匙（WindTerm/libssh2 不查权限故能用）。某专用私钥（路径含子目录，如 `~/.ssh/<子目录>/id_rsa`）当时是 0644，`chmod 600` 后 + `+ssh-rsa` 才登录成功。

### M2 —— 第十六批（2026-06-13，会话树交互完善，已构建启动）

- [x] **多选拖拽整批移动**：`handleDrop` 在「被拖节点∈选区且选区>1」时移动 `orderedSelectedTopLevelIds()`（按可见树序、父子都选只移父）；into 顺序追加、before 顺序插、after 逆序插以保持原序。Tap(count:1) 选中不会在拖拽时触发，选区不塌。
- [x] **标签栏自动滚动**：`SessionTabBar` 包 `ScrollViewReader` + tab `.id`，`onChange(currentId)` 滚到可视区——标签过多时焦点标签不再被挤出看不见。
- [x] **批量展开/折叠**：左树底部 `▼`/`▶`（全部分组）；分组右键三件套「展开本级（一层）/ 展开全部子组（递归）/ 折叠全部子组（仅后代、本组保持展开）」。
- [x] **两个设置开关**（座舱设置）：①「折叠分组时同时折叠其子分组」**默认开**（`toggleGroup` 折叠时连后代子组一起收起，nil 视为开）；②「退出应用后全部折叠」默认关（启动时若开则忽略已存展开态、全收起，磁盘态保留可恢复）。均存 `layout.json`。

### M2 —— 第十七批（2026-06-13，跳板机单独管理 + 跳板自鉴权 + 数据脱敏，真机验证通过）

跳板（堡垒机）从「会话内手填一行 proxyJump」升级为**独立清单管理**，多台会话引用同一条、改一处全生效；跳板自身可带登录凭据。全 `#if XGHOSTTY`：

- [x] **跳板清单 `JumpHostStore` / `JumpHost`**（`{id,name,host,user?,port?,credentialId?}` + `endpointDisplay`=`[user@]host[:port]`，`ObservableObject` `@Published hosts`，持久化 `~/.config/xghostty/jumphosts.json` 0600，find/upsert/remove）。`JumpHostLibraryView` 管理 sheet（仿密码库，`JumpHostEditView` 名称/host/port/user + **登录凭据 Menu**：默认密钥(~/.ssh) / 密码库条目）；左树底部 `arrow.triangle.branch` 入口（🔑 与 ⚙ 之间）。
- [x] **会话引用跳板**：`SessionNode.proxyJumpId: UUID?`（与手填 `proxyJump` 二选一、前者优先，Optional 向后兼容）。`SessionEditView` 跳板字段改 Menu：无 / 手动填写 / 跳板清单条目（`proxyJumpId`/`manualJump` 双 State + `jumpSourceLabel`）。
- [x] **跳板自鉴权（关键）`SessionCommandBuilder.Jump{endpoint,port,identityFile,askpassEnv,hasAuth}`**：跳板**无独立凭据** → 普通 `-J endpoint[:port]`（走 `~/.ssh` 默认/agent）；跳板**带凭据** → 改 `ProxyCommand`：`proxyCommand(for:)` 拼 `[env <askpass…>] ssh <ssh-rsa兼容> [-p port] [-i key -o IdentitiesOnly=yes -o PasswordAuthentication=no …] -W %h:%p endpoint`——`-W` 让跳板只做 TCP 转发、其登录用**自己**的密钥/askpass（与目标机的 askpass 环境变量**分开**，互不串密码）。`jumpEndpoint(for:)` 解析跳板成 `[user@]host`（端口走 `-p`/`-W` 不混进 endpoint）。
- [x] **`openTab` 接线**：`proxyJumpId` → `JumpHostStore.find` → `jumpEndpoint` 组 `Jump`；若 `jh.credentialId`：密钥凭据 → `spec.identityFile = cred.keyPath`，密码凭据 → `XGhosttyAskpass.prepare` 单独生成 `spec.askpassEnv`（独立于目标机密码）。手填跳板仍走 `-J`。
- [x] **连接信息显示跳板**：`displayCommand(for:viaJump:)` 首行 banner 追加 `-J <跳板endpoint>`，让"这台是经跳板连的"一眼可见（排障用）。
- [x] **数据脱敏**：源码/docs/memory 内真实公司名（如某航空）、真实生产 IP（10.55.x/10.56.x）、真实主机名/凭据名/专用密钥子目录全部换成通用占位（RFC 5737 `192.0.2.x`、`root`/`<子目录>`/`示例主机` 等），技术结论保留。

**坑/排障（真机）**：① **`-J` vs `ProxyCommand` 的取舍**：`-J` 简洁但跳板登录只能走 OpenSSH 默认（`~/.ssh`/agent/`~/.ssh/config`）；跳板要用座舱托管的**专属密钥/密码**就必须降到 `ProxyCommand -W`，否则跳板那一跳无法用座舱凭据。② **askpass 必须分两份**：目标机与跳板各自的密码各写各的 0600 临时文件、各自 `SSH_ASKPASS*` 环境变量，混用会把目标密码答给跳板（或反之）。③ **连不上≠程序 bug**：曾排查某目标机经跳板登录"卡住"，实为**网络拓扑**——跳板所在网段路由不到目标网段（`ssh 跳板 'echo > /dev/tcp/<目标>/<端口>'` 实测不可达），解法是该会话去掉跳板直连；`displayCommand` 显示 `-J` 正是为让这类拓扑问题一眼现形。

### M2 —— 第十八批（2026-06-13，密码库「查看明文 + 查看引用会话」，已构建启动）

密码库 backlog 收口：查看已存秘密明文、看清一条凭据被谁引用（改/删前心里有数）。全 `#if XGHOSTTY`：

- [x] **查看已存密码 / passphrase**（`CredentialEditView.revealRow`）：密码/passphrase 字段下 eye 切换——点开 `XGhosttyCredentialStore.password(for:)` 读明文（**显式动作，触发一次 Keychain 授权**符合预期）、再点收起，旁带复制按钮（`NSPasteboard`）；label 随类型变（密码凭据「查看已存**密码**」/ 密钥凭据「查看已存 **passphrase**」）；仅 `hadSecret`（确有已存秘密）时出现，新建空壳不显示。
- [x] **查看被哪些会话/跳板机引用**：`SessionStore.sessionsReferencing(credentialId:)` → `[(node, path)]`（path = `分组 › 子组 › 会话名`）；`CredentialLibraryView.usage(of:)` 静态聚合**会话**（`SessionNode.credentialId`）+ **跳板机**（`JumpHost.credentialId`）两类引用。编辑页 `usageSection` 列出全部引用（两类图标区分、可滚动封顶 110pt，仅 `!isNew` 且非空）；列表行右侧加「N 处引用」accent 徽标。
- [x] **删除前看清影响面**：删除确认框从笼统提示改为**列出具体引用方**（封顶 10 条、跳板机带前缀、余数省略；无人引用时明确提示"当前没有会话或跳板机引用它"）——避免误删共享凭据。

### M2 —— 第十九批（2026-06-14，广播审计日志，已构建启动）

- [x] **`BroadcastAuditLog`**：批量发送条向「全部 / 分组」群发命令时留痕（高危操作可追溯）。挂在 `onBroadcast` 实际群发之后，**只记真广播**（目标≠当前会话），单发不记（噪音）。串行队列异步落盘 `~/.config/xghostty/broadcast-audit.log`（0600，**JSON Lines** 每行一条：`ts`[本地时区]/`target`/`count`/`sessions[{name,host}]`/`command`），便于 `jq`/`grep` 与将来「审计查看 UI」。反查命中 tab 取会话名/host。
- [x] **查看入口**：座舱设置「查看广播审计日志」→ Finder 定位文件（自选编辑器打开）；无记录时友好提示。

### M2 —— 第二十批（2026-06-14，会话日志落盘，已构建启动）

把每个 **ssh 会话**的终端输出实时 tee 到本地文件。**零改 Zig 核心**——复用 session-sharing 在 `src/` 已建好的 `ghostty_surface_set_output_callback` C 机制（调研确认通路；见 `docs/plan/session-sharing.md`）。

- [x] **`SessionLogStore` / `SessionLogger`**（新）：`SessionLogger` 把 pty 原始字节追加到 `.log`——`ingest` 由 termio 回调在 **termio 线程**同步触发 → 立刻派发到自己的串行队列异步落盘，**绝不**在 termio 线程做文件 IO（否则拖慢 pty 读取）。懒创建文件（首批输出才建，目录 0700/文件 0600）。`SessionLogStore` 按开关给会话挂回调、管生命周期。
- [x] **`SurfaceView_AppKit.swift`** `#if XGHOSTTY` 块：加 `xghosttyAttachOutputLog`/`xghosttyDetachOutputLog`（实例方法）+ 顶层 `xghosttyOutputLogCallback`（同 `sessionSharingOutputCallback` 范式，转交 `SessionLogger`）。
- [x] **接线**：`openTab`（仅远端 ssh 会话）`start` / `closeTab` `stop`；`LayoutStore.sessionLogging` 开关（设置面板）+ 「打开日志目录」按钮。文件 `~/.config/xghostty/logs/<安全会话名>-<时间戳>.log`，内容 **raw 字节**（含 ANSI，`cat`/`less -R` 回放）。
- **取舍**：开关**默认关**（隐私/磁盘 + 与共享互斥），**仅对新打开会话生效**。Zig 侧 output_callback 是**单槽** → 同一会话再开 ⌃⇧S 共享会互相覆盖（XGhostty 场景极少同时用）；彻底共存需在 src/ 加第二槽（改 C ABI + 重建 xcframework），成本高，未做。

### M2 —— 第二十一批（2026-06-14，组级快捷命令 + 移除 Finder 服务菜单，已构建启动）

- [x] **组级快捷命令**：`QuickCommand.groupId: UUID?`（nil=全局，Optional 向后兼容）。快捷条 = 全局命令 + **当前会话所属分组链**（直接父组到根）的组级命令；`select` 切 tab 时刷新（本地 shell/根级会话只见全局）。`QuickCommandEditView` 加「作用范围」下拉（全局/各分组）；`+` 新增默认 = 当前会话直接父组。拖拽重排**可见子集 → 合并回完整数组**（可见项按新序填回原槽位、隐藏项原位不动，不因过滤丢序）。
- [x] **移除 XGhostty 的 Finder 服务菜单**：`Ghostty copy-Info.plist` 删整个 `NSServices`（`openTab`/`openWindow` 两个 "New XGhostty Tab/Window Here"，duplicate target 时从主 Ghostty 继承，座舱用不上）。`PlistBuddy -c "Delete :NSServices"` + `plutil -lint` 校验；`lsregister -f` 重注册 + `pbs -flush` 刷新服务缓存（旧菜单项消失，顽固时重开 Finder 窗口/注销重登）。主 Ghostty 服务不动。
- [x] **Info.plist fileRef 相对路径**（已单独提交 `1bcb37ab7`）：`Ghostty copy-Info.plist` 的 PBXFileReference 从本机绝对路径 + `sourceTree=<absolute>` 改为相对 path + `<group>`（对齐主 Ghostty-Info.plist），换机/换路径后 Xcode 导航器不再丢失引用。构建走 `INFOPLIST_FILE` 不受影响。

> **M2 剩余**：简化 expect —— **已在第二十五批收口**（先做输出多订阅分发器解决与会话日志的单槽冲突，再实现 expect 自动登录兜底，opt-in 默认关）。（组广播、XShell·WindTerm 导入、跳板机管理、密码库查看引用、广播审计、会话日志落盘、组级快捷命令 已完成。）**M2 全部完成。**

### M3 —— 第二十二批（2026-06-14，工作区 / 会话恢复，已构建启动）

把「一组会话」做成可保存/可恢复的单元（运维每天开固定一批生产机的刚需）。全 `#if XGHOSTTY`：

- [x] **工作区（手动）`WorkspaceStore` / `Workspace{name, sessionIds}`**（持久化 `~/.config/xghostty/workspaces.json` 0600）+ `WorkspaceLibraryView` 管理 sheet（列表一键「打开」/删除 + 「保存当前 N 个会话为新工作区」）。左树底部 ▦（`rectangle.stack`）入口。打开 = 按存的顺序逐个 `openSession`（已删节点跳过、追加不关现有 tab）；保存 = 抓 `currentOpenSessionIds()`（tabOrder 里有 nodeId 的会话，临时本地 shell 不计）。
- [x] **会话恢复（自动）**：`LayoutStore.restoreLastSession` 开关（默认关）+ `lastSessionIds`。`windowWillClose` 记当前会话集；`init` 的 `restoreOrOpenInitialSession()`：首个窗口（`all.isEmpty`）+ 开关开 + 有记录 → 恢复那组（ssh 重新登录），否则兜底开第一个避免空白。设置面板「启动时恢复上次打开的会话」开关。

### M3 —— 第二十三批（2026-06-14，会话日志增强，已构建启动）

- [x] **`SessionLogStore` 扩展**：`stripANSI`（扫描式剥离 CSI[`ESC[…`]/OSC[`ESC]…`]/其他 ESC 序列 + 控制字符，留 `\n`/`\t`、丢 `\r`）+ `logFiles`（按修改时间倒序）+ `readLog`（纯文本可选剥离；超大只取末尾 500KB 防卡 UI）。
- [x] **`SessionLogViewerView`**（新 sheet）：选日志文件（Menu）+「原始/纯文本」切换 + 滚动查看 + 在 Finder 显示/删除。**raw 保真落盘不变**，纯文本是查看时按需剥离（不改磁盘）。座舱设置「查看会话日志…」入口（先 `dismissEditor` 关设置再 `presentSessionLogViewer`，避免嵌套 sheet）。
- **局限**：纯文本简单剥离对普通命令输出（ls/df/cat）效果好；交互式 TUI（vim/top）布局剥离后仍可能不完美（已在 UI 注明）。

### M3 —— 第二十四批（2026-06-14，作用范围/分组广播下拉改自绘 submenu 弹层，已构建启动）

把「作用范围」（快捷命令）和「分组广播」两个下拉从系统 `Menu` 换成**自绘弹层**——因为**系统 NSMenu 的下拉背景 macOS 不让改成座舱终端色**（所有 app 一致的系统材质），要统一座舱样式只能自绘。多轮迭代定稿：

- [x] **`ScopePopup.swift`（新）**：`ScopeValue`（global/current/all/group）+ `ScopeRow`（树）+ `ScopePopupList`。
- [x] **复刻系统 submenu 的右侧子浮层（flyout）**：父组行右侧 ▸，hover 停 **~0.05s** 后在**右侧**弹出子页（递归同组件、`.popover(arrowEdge:.trailing)`）；移到子浮层时本层无行被 hover、`openSub` 不变 → 子页保持；hover 到另一个父组才切换。延时用 `DispatchWorkItem` 可取消，挡极快划过的误触发。（**坑**：一开始误做成「下方 inline 展开」，用户要的是系统 submenu 那种**右侧** flyout。）
- [x] **命令面板同款视觉**（仿 `CommandPalette.swift`）：背景 `.ultraThinMaterial` 毛玻璃 + `bg.blendMode(.color)` 终端色调（`presentationBackground`，13.3+ availability gate）；整行高亮——选中 = `accentColor` 蓝条、hover = `secondary` 灰条（替代系统 ✓）；`colorScheme` 按 `bg.isLightColor`。
- [x] **打开时定位上次选择**：`onAppear` 沿 `selected` 祖先链设 `openSub` → 逐层 popover onAppear 接力展开到选中项（深层子组也能一打开就高亮可见）；选顶层项则停主层。
- [x] **接线**：`ScopeGroup` + `scopeGroupTree()`（分组树）；`QuickCommandEditView`/`BroadcastTargetPicker` 从 `Menu` 改 `Button + .popover(ScopePopupList)`，**触发器框样式一字未改**（仍 `consoleFieldBox`/自绘背景）；controller 传 `consoleBgColor`（`ghostty.config.backgroundColor`）+ `selected`（`broadcastScopeValue` / `groupId`）。

**关键坑/取舍**：① **系统下拉（NSMenu）背景无法自定义**——要座舱统一样式必须放弃系统 Menu、自绘弹层。② 自绘 flyout 用 **SwiftUI 嵌套 `.popover`** 递归实现；hover 切换靠「只在 hover 本层某行时更新 `openSub`、离开不清」保证移到子浮层不收。③ `presentationBackground` 需 macOS 13.3+，用 `#available` gate（低版本 fallback `.background`）。④ 迭代历程（缩进扁平→系统 submenu→自绘纯色→自绘缩进直选→自绘 flyout+命令面板视觉）记录了"系统好用 vs 座舱样式"的反复权衡，最终自绘 flyout 两者兼得。

> **M3 剩余**：SFTP tab / trzsz(rz/sz) 文件传输（较大的新交互模型，按需再开）。（工作区、会话恢复、会话日志增强、下拉自绘 submenu 已完成。）

### 第二十五批（2026-06-14，输出多订阅分发器 + 会话日志/共享共存 + expect 自动登录兜底，已构建启动）

把 XGhostty 侧 pty 输出捕获从「单槽抢占」重构成「多订阅分发器」，顺带收口 M2 暂缓的 expect。全 `#if XGHOSTTY`，**零改 Zig 核心**：

- [x] **`XGhosttyOutputDispatch`（新 `OutputDispatch.swift`）**：每个 surface 一个分发器，只向 Zig 的 `ghostty_surface_set_output_callback` **单槽**注册**一个** trampoline（`xghosttyOutputDispatchCallback`），trampoline 把每批 pty 字节转发给该 surface 的**全部订阅者**。订阅 `add`/退订 `remove`（主线程）用 `key: AnyObject`（订阅方对象本身的 `ObjectIdentifier`）做凭据；`dispatch`（termio 线程）取订阅者快照后出锁逐个调用。**dispatcher 常驻注册表不随订阅清零销毁**——回避「termio 正回调、主线程释放 dispatcher」的 UAF（`passUnretained` context 必须回调期间有效）；订阅清零只把 Zig 回调置 nil（无开销），下次再挂回。
- [x] **会话日志 + ⌃⇧S 共享同会话共存**（消除「已知互斥」取舍）：`SurfaceView` 的 `xghosttyAttachOutputLog/Detach`（含旧顶层 `xghosttyOutputLogCallback`）换成通用 `xghosttyAddOutputSink(key:_:)`/`xghosttyRemoveOutputSink(key:)`，内部走分发器。`SessionLogStore` 用 `logger` 做 key 订阅。**session-sharing 控制器**的 `attachOutputCallback`/`detachOutputCallback` 仅在 `#if XGHOSTTY` 下改走分发器（`key: self`、sink→`enqueueOutgoing`）——`#else` 主 app 仍走 `SessionSharingOutputBridge.live` 直连单槽，**原版 Ghostty.app 路径一字不改**。现在同一会话日志落盘与共享可同时生效（输出多路转发）。
- [x] **expect 式自动登录兜底（`ExpectAutoLogin.swift`，opt-in 默认关）**：收口 M2 暂缓项。正常路径 `SSH_ASKPASS_REQUIRE=force` → 终端无 `password:` 提示 → 兜底静默；少数环境 ssh 不认 askpass（仍在 tty 问密码）→ 监听到 `password:` 用 `send_bytes`（复用广播原语，行尾 `\r`、绕 bracketed-paste）自动答密码。**只在登录阶段武装**：连接成功（首个 OSC7 pwd）/ 45s 超时 / 关闭标签即解除武装——**防误答登录后的 `sudo` 提示**（`[sudo] password for…` 也含 `password:`）；最多答 2 次防喷密码。`feed` 在 termio 线程匹配累积尾巴（120 字符、跨批拼接、小写、清尾防重复触发）。
- [x] **接线**：`LayoutStore.expectAutoLogin`（默认关）+ 设置面板开关；`openTab` 仅对**有密码的远端会话**且开关开时武装（`expectPassword = auth.password`）；`OpenTab.expect` 持有；connect 成功 sink + `closeTab` 解除武装 + 退订。

**关键取舍/坑**：① **`ghostty_surface_t` 实为 `UnsafeMutableRawPointer`（不是 `OpaquePointer`）**——注册表 key 用 `[ghostty_surface_t: …]`（即 `[UnsafeMutableRawPointer: …]`，Hashable），别想当然写 `OpaquePointer`（`typedef void* ghostty_surface_t`，但 importer 这里给的是 RawPointer，编译报 `no exact matches in call to subscript`）。② **分发器 dispatcher 不释放**是刻意的——与既有单槽 detach 同一类竞态（termio 线程回调 vs 主线程置 nil），用「常驻」彻底消除 UAF，代价是每个曾打开的 surface 留一个极小对象，可忽略。③ **seam 选在 controller 的 attach/detach + `#if XGHOSTTY`**，而非改 `SessionSharingOutputBridge.live`（共享 struct 主 app 也用）——保证主 app 行为零变更、回归面最小。④ **expect 必须登录阶段限定武装**：否则会把 ssh 密码误答给登录后的 sudo/其他 `password:` 提示；用「连接成功即 disarm」精确卡住，45s 超时兜底（登录失败留尸 tab 时也能解除）。⑤ askpass 与 expect 天然互斥：askpass 生效则无提示、expect 不触发；askpass 失效才由 expect 接管——叠加不冲突。

> **M2 expect 至此收口**（不再暂缓）。**M3 剩余**：SFTP tab / trzsz(rz/sz) 文件传输（较大新交互模型，按需再开）。

### 第二十六批（2026-06-14，SFTP 文件传输标签，已构建启动）

收口 M3 计划里「开 sftp tab 按钮」一项（M3 范围本就**砍掉图形 SFTP 面板**，只做在终端内跑交互式 sftp）。复用现有 tab/surface 模型，全 `#if XGHOSTTY`，**零改 Zig**：

- [x] **`SessionCommandBuilder.buildSFTP` + `displaySFTPCommand`**：与 `build` 的差异——① 二进制 `sftp`；② 端口大写 `-P`（ssh 是小写 `-p`）；③ 不加 `-t`（sftp 自带交互）；④ **不**追加远端 OSC7 bootstrap 位置参数（sftp 位置参数是远端**路径**，塞脚本会被当路径；sftp 自维护远端 cwd）。auth（`SSH_ASKPASS`）/ `-i` / policy / jump 经 `-o`/`-i`/`-J` **整段透传**——sftp 复用 ssh 传输层，`SSH_ASKPASS_REQUIRE=force` 同样让它走 askpass（含跳板 ProxyCommand、密钥、引用凭据、`+ssh-rsa` 老服务器兼容全部复用，无重复实现）。
- [x] **入口**：会话树叶子右键「打开 SFTP」（`SessionTreeActions.onOpenSFTP` → `openSFTP` → `openTab(node:, transport:.sftp)`），仅非本地节点显示；总是新开一个标签，可与同会话的 ssh 标签并存。标题 `名字 · SFTP`。
- [x] **`TabTransport`（ssh/sftp）+ `OpenTab.transport`**：`openTab` 按 transport 选 build/display、标题、是否发 loginCommands（sftp 跳过——登录命令是远端 shell 命令，sftp> 不收）。
- [x] **「已连接」判定**（`SFTPReadyWatcher.swift` 新）：sftp **不发 OSC7**，ssh 那套 `$pwd` 首次上报失效 → 改扫输出里首个 `sftp>` 提示符判定登录成功（**复用第二十五批输出分发器**，成为日志/共享/expect 之外的**第四个**输出消费者）；命中即标已连接、撤探测订阅、disarm expect。
- [x] **排除群发**：`broadcastTargets()` 的 `.all`/`.group` 一律滤掉 sftp 标签（sftp 提示符不接受 shell 命令，群发到它无意义且危险）；`.current` 单发**不**排除——让用户能在底栏对当前 sftp 会话直接敲 put/get 等 sftp 命令。
- [x] **重连**：`reconnectExitedTab` 用尸体的原 transport 重开（sftp 尸体重连仍开 sftp，不退回 ssh）；`closeTab` 对称撤 sftpWatcher 订阅。

**关键取舍/坑**：① **sftp 端口是大写 `-P`**（ssh 小写 `-p`）——抄 `build` 时极易漏改。② **sftp 不能塞远端命令位置参数**（那是路径），故没有 OSC7 目录跟踪、连接判定只能靠扫 `sftp>` 提示符。③ **必须把 sftp 标签挡在群发外**（正确性关键）——否则一条群发 `rm`/`reboot` 会被当 sftp 命令打进去；但 `.current` 保留以支持底栏直接发 sftp 命令。④ **askpass 对 sftp 同样生效**（sftp 复用 ssh 传输层 + `SSH_ASKPASS_REQUIRE=force`），故认证/跳板/密钥逻辑整段复用，无需任何 sftp 专属密码处理。⑤ **trzsz(rz/sz) 仍按计划仅文档不实现**——Ghostty 无 trzsz 协议支持（远端跑 `trz`/`tsz` 只会吐乱码），文件传输统一引导到 SFTP 标签或 `scp`；真要做 trzsz 需在分发器上实现协议状态机（被 M3 明确砍掉的 30–60h 量级，按需再开）。

> **M3「开 sftp tab 按钮」已收口。** **M3 剩余（按需再开）**：trzsz(rz/sz) 协议级文件传输（M3 明确砍掉的大头，需分发器上跑 trzsz 协议状态机 + 原生文件选择/保存对话框，较大新交互模型）。

### 第二十七批（2026-06-14，修复钥匙串反复弹授权框，已构建启动）

用户反馈「XGhostty 想访问钥匙串 top.niandui.xghostty」框每次启动都弹。诊断：**签名是稳定自签证书**（`Authority=Ghostty Dev Cert`，**非 ad-hoc**），DR=`identifier "top.niandui.xghostty" and certificate leaf = H"82139ee5…"`，**leaf 与历史记录一致**——不是"重建指纹变"那个老问题。真因：**保险库钥匙串项的 ACL 还是 ad-hoc 时代创建时的**（信任旧 cdhash），换证书后身份对不上 → 每次读保险库都弹；本机还有**两个一模一样的「Ghostty Dev Cert」签名身份**（同 SHA-1，疑似 p12 重复导入），让「始终允许」追加的授权粘不稳。

- [x] **`XGhosttyCredentialStore.repairKeychainACL()`**：`ensureLoaded` 读出内存快照 → `deleteVault`（删旧项连其脏 ACL）→ `persistVault`（找不到项→走 `SecItemAdd` 在**当前签名下**新建）。新项默认 ACL 只信任**创建它的本 app**，而本 app 的指定要求是 cert-leaf（跨重建稳定）→ 此后同证书签名构建读取保险库**根本不弹框**（连「始终允许」都不用）。返回 (ok, 迁移条数)。
- [x] **设置面板「修复钥匙串授权」按钮**（`ConsoleSettingsView.repairKeychain`）：直接调 store + NSAlert 反馈（含迁移条数）；说明文案提示"会读一次现有密码，旧授权仍脏时弹最后一次、点始终允许放行"。
- 重复证书清理需动 login 钥匙串（用户本人操作）：`security find-identity -v -p codesigning` 看到两条同 hash → 删多余那份私钥/证书。

> **⚠️ 第二十七批结论已被第二十七批·订正推翻（见下）**：「删项重建 ACL 后同证书构建不再弹」是**错的**。

### 第二十七批·订正（2026-06-14，钥匙串"重建后必弹"的真因 + 用户选保持现状）

用户复现：**单纯重开同一二进制不弹、改代码重新构建后才弹**。实测确认 **cdhash 每次重建都变**（`2e88a337…`→`0e5e3c33…`）。真因不是"早于证书的旧 ACL"，而是：

- **自签证书下，macOS 把钥匙串项的「始终允许」钉死在具体这一版构建的 cdhash 上，而非证书**（不honor 自签证书的 cert-leaf DR 作稳定身份）。每重建 cdhash 变 → 旧授权对不上 → 重新弹。
- **`repairKeychainACL()`（删项重建）治不了这个**——它只把授权重置到"当前构建"，下次一重建照样弹。第二十七批"通解"是误判，已订正。
- 能跨重建不弹的只有：① 去掉应用门禁（保险库项设 allow-all SecAccess，任何进程免提示读 → 安全降级）；② 换 Apple Developer ID 真证书（cert-DR 被honor，稳定）。
- **用户决策：保持现状**（不降安全），开发期每次重建点一次「始终允许」忍一下；功能定稿不再重建后即不弹。`修复授权`按钮保留作"清理旧 ACL"的窄用途，UI 说明已改诚实（不再承诺"重建不弹"）。

> **教训**：自签/ad-hoc 代码的钥匙串 ACL 按 cdhash 钉死，**任何"重建 ACL"都无法跨重建免弹**；要么 allow-all（降安全）要么真证书。别再说"删项重建就不弹"。

### 第二十八批（2026-06-14，ZMODEM(rz/sz)文件传输——桥接本机 lrzsz，第一批，已构建启动）

收口 M3 当初砍掉的 trzsz/rz-sz 大头。用户选**桥接本机 lrzsz**方案（vs 纯 Swift 实现 ZMODEM）。全 `#if XGHOSTTY`，**零改 Zig**：

- [x] **`ZmodemBridge.swift`（新）**：在输出分发器上侦测 ZMODEM 触发头——`**\x18B00`(ZRQINIT，远端 `sz`→本机收) / `**\x18B01`(ZRINIT，远端 `rz`→本机发)——命中即 spawn 本机 `rz`/`sz`，把**触发头起的后续 pty 输出**喂给其 stdin、其 stdout 经 `send_bytes` 回灌远端，本机 lrzsz 当 ZMODEM 端点跑完整协议。下载存 `~/Downloads`（不弹框，避免 ZMODEM 超时）；上传弹 `NSOpenPanel` 选文件（远端 rz 会耐心等）。
- [x] **触发→接管的字节交接**：扫描态累积封顶 512B，命中后把 `bytes[触发头index...]` 存 `pendingToChild`、切 active 态；子进程就绪后先灌 pending 再实时转发（termio 线程写 stdin pipe）。
- [x] **遮乱码浮层**：硬约束——**没法阻止 ZMODEM 原始字节被终端渲染**（要改 Zig），故传输期屏幕刷乱码。控制器加 `zmodemOverlay`（盖满 surfaceContainer 的不透明终端背景色浮层 + 居中提示），传输时显、传完延时 0.25s 隐（等远端 Ctrl-L 重绘落地）。`ZmodemBridge.Activity{started/finished}` 回调驱动。
- [x] **lrzsz 缺失兜底**：逐候选路径探 `/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin` 的 rz/sz；找不到则向远端发 ZMODEM 取消序列（`CAN`×8 + `BS`×8）让远端干净中止 + 弹「请 brew install lrzsz」提示，**不留远端卡死**。
- [x] **接线**：`LayoutStore.zmodemEnabled`（默认关）+ 设置面板开关；`openTab` 仅 **ssh transport + 远端会话 + 开关开**时武装（`OpenTab.zmodem` 持有，分发器订阅 `bridge.feed`）；`closeTab` 撤订阅 + `teardown`（进行中则取消远端 + 杀子进程）。传完桥接器自动复位回扫描态，可连续多次传输。

**关键取舍/坑**：① **零改 Zig → 无法屏蔽渲染**，传输期必刷乱码，只能浮层遮 + 传完 Ctrl-L 清；这是 fork 不动核心的固有代价。② **下载不弹保存框**（直存 ~/Downloads）——ZMODEM 有 ~10s 超时，弹框选目录会超时断流；上传可弹框（rz 等得起）。③ **触发头方向位**：`**\x18B` 后两个 hex 位是帧类型，`00`=ZRQINIT(我们收/rz)、`01`=ZRINIT(我们发/sz)；扫描只会撞到首个握手头（数据帧是 binary `A`/`C` 头且那时已 active）。④ **sz 加 `-e`**（转义控制字符）防 pty 链路不 8-bit-clean；rz `-y -b`。⑤ 本机**未装 lrzsz**（已探测确认），用户测前需 `brew install lrzsz`。

**第一批范围**：核心桥接（下载+上传）+ 浮层 + 缺失兜底 + 开关。**待后续批**：传输进度条（解析 rz/sz stderr 的 `Bytes Sent/BPS`）、传输中「取消」按钮、后台 tab 传输的浮层归属、自定义下载目录、传完是否发 Ctrl-L 可配。

> **M3 ZMODEM 第一批落地（桥接 lrzsz）。** 待打磨：进度/取消/目录/后台归属。

> 拖拽（1、2）在扁平 `ScrollView + LazyVStack`（已替换原 List / DisclosureGroup）上做 `onDrag`/`onDrop` + drop 落点高亮；落地前先 spike 验证拖拽手势与现有单击选中/⌘⇧多选/双击不打架。

### 踩坑记录（换机/重做必看）

**A. Xcode duplicate macOS target（fileSystemSynchronized 同步组）会生成错误的成员例外集**
duplicate 把 **iOS target 的排除清单**错按给新 target，导致：
1. 错排 `App/macOS/main.swift` → 缺 `_main`，链接 `Undefined symbols: "_main"`；
2. 漏排 `Ghostty/Surface View/SurfaceView_UIKit.swift` → `ambiguous type name 'SurfaceView'`。
**解法**：把新 target 的 `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions` 改成与正牌 macOS `Ghostty`（例外集 `81F82CB1`）**一字不差**——排除 `App/iOS/iOSApp.swift`、`Features/Custom App Icon/DockTilePlugin.swift`、`Ghostty/Surface View/SurfaceView_UIKit.swift` 三个。备份在 `project.pbxproj.bak-xghostty`。

**B. setup-dev-cert.sh 的 p12 导入坑**（已在脚本注释）：非空中转密码 + OpenSSL3 需 `-legacy -macalg sha1`，否则 `security` 报 "MAC verification failed"。命令行导私钥还需 GUI 授权，最终用钥匙串访问「证书助理」一步到位最稳。
