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

### 第二十九批（2026-06-14，⚠️ 首次改 Zig 核心：输出 divert 去 ZMODEM 乱码 + trzsz 支持，已构建启动）

**用户授权改 Zig 核心**（此前铁律是"XGhostty 零改 src/"——虽然 session-sharing 早已往 src/ 加过 `output_callback`）。两件事：①给 ZMODEM 加"截流"彻底去乱码；②加 trzsz 支持。

**① 改 Zig 核心：输出 divert（纯加法、默认关、主 app 零影响）**
- 病根定位：`Termio.zig processOutputLocked` 在 `output_callback.invoke(buf)`（我们拿副本，705 行）之后、于 733-747 行把 `buf` 喂 VT 解析器写屏。XGhostty 只拿只读副本、拦不住解析 → ZMODEM 二进制刷成满屏乱码。
- 改动 4 处全是加法：`Termio.zig` 加 `output_diverted: bool = false` 字段 + `setOutputDiverted` + 在 invoke 后插 `if (self.output_diverted) return;`（截流时跳过 render+parse，屏幕冻结在传输前那帧）；`Surface.zig` 加 `setTermioOutputDiverted`（取 renderer 锁保证不在批中途翻转）；`embedded.zig` 导出 `ghostty_surface_set_output_diverted`；`include/ghostty.h` 声明。
- **安全保证**：字段默认 false，主 Ghostty.app 从不调该导出 → 早返回永不触发 → `processOutputLocked` 逐字节行为不变。是加法+默认关，非改逻辑。**C-ABI 变 → 重建 `GhosttyKit.xcframework`（`zig build -Demit-macos-app=false`，已做，新符号进了全平台头）**。
- XGhostty 侧：`SurfaceView.xghosttySetOutputDiverted(_:)` 包该导出；`ZmodemBridge` 传输确定开始（找到 rz/sz 后）`true`、失败/取消/结束/teardown `false`；**结束时先关 divert 再发 Ctrl-L**（否则重绘响应仍被截流、屏幕停在冻结帧）。**坑：divert 不能从 `feed`（在 `output_callback.invoke` 里、已持 renderer 锁的 termio 线程）调**——会同线程重锁死锁；只能主线程 dispatch 调（start/exit/teardown 都在主线程，OK）。代价：触发→主线程 dispatch 那点延迟内的极少首批字节仍会渲一下（ZRQINIT ~20B 一闪），可忽略。

**② trzsz 支持（包裹 ssh，无需 divert）**
- trzsz 设计上就是透明包 ssh：`trzsz ssh user@host` 让本机 trzsz 坐在 pty 与 ssh 之间，远端 trz/tsz 协议在到 XGhostty 前就被 trzsz 吃掉自理 → **XGhostty 端本就无乱码、连 divert 都用不上、自带进度条**。
- 实现：`LayoutStore.trzszEnabled`（默认关）+ 设置开关；`openTab` 仅 **ssh transport + 开关开 + 本机装了 trzsz** 时把 `built.command` 前缀成 `'<trzsz路径>' ssh …`（`trzszPath()` 逐候选路径探 brew bin，未装静默退回普通 ssh）；下载落点：trzsz 默认存进程 cwd → 给 trzsz 包裹的会话把 `cfg.workingDirectory` 设到 `~/Downloads` 兑现"下载到 ~/Downloads"。askpass/跳板/OSC7 全透传（trzsz 继承 env、转发普通输出）。
- 与 lrzsz 桥接**并存不冲突**：trzsz 拦 trzsz 协议，经典 ZMODEM(`**\x18B0`)穿过 trzsz 到 XGhostty 由 ZmodemBridge 接。
- 本机**未装 trzsz**（已探测），测前 `brew install trzsz`。**待验证**：trzsz CLI 实际下载落点是否真按 cwd（没装没法核 --help，先按 cwd 赌）、上传是否走拖文件进终端。

> **里程碑：XGhostty 不再"零改 Zig"**——改成"**改 Zig 但纯加法 + 默认关**"，对原版 app 仍是 provably 零行为变化。代价：①每次改 C-ABI 要重建 xcframework；②上游 merge 若动 `processOutputLocked` 要重贴那行 `if return`（就一行）。**ZMODEM 乱码已根治**（屏幕冻结干净）。

### 第三十批（2026-06-14，文件传输方案收敛：统一 `trzsz -z -d ssh`，真机验证通过）

真机迭代后大改方向。**关键发现**：`trzsz --help` 暴露 **`-z`「enable zmodem lrzsz (rz/sz)」** 与 **`-d`「dragfile」**——即 trzsz-go 的本地包裹器 `trzsz -z -d ssh` **一条命令原生接管全部四种**（trz/tsz **和** rz/sz），自带进度/无乱码/拖文件上传，比自绘桥接可靠得多。

- [x] **自绘 lrzsz 桥接（ZmodemBridge）证明不可靠**：管道桥接 rz/sz **握手跑不通**（lrzsz 要真 tty 做 tcsetattr/isatty），ZMODEM 响应漏给远端 shell（`bash: �: 未找到命令`）。已改成 **pty 桥接**（`posix_openpt`+slave 设 raw 防回显，stdin/stdout 接 slave、父读写 master）——但仅作 **「没装 trzsz-go」的兜底**。
- [x] **统一走 trzsz-go 包裹**：`openTab` 在 **ssh + 任一文件传输开关开 + 装了 trzsz-go** 时把 `built.command` 前缀成 `'<trzsz>' -z -d <ssh…>`，并把本机 cwd 设 `~/Downloads`（trzsz 下载落点）。包裹时**不**再武装 ZmodemBridge（`trzszWrapped` 标记）。askpass/跳板/OSC7/登录命令全透传（trzsz 继承 env + 转发普通输出）。
- [x] **Esc 取消**：keyMonitor 的 keyCode 53 在 `activeZmodemBridge != nil` 时调 `bridge.cancel()`（发 ZMODEM CAN + 杀 rz/sz + 撤截流 + 回车）。仅对兜底桥接路径有效（trzsz 包裹时 trzsz 自管）。
- [x] **设置开关理顺**：「文件传输（trz/tsz/rz/sz·推荐）」（=旧 trzszEnabled，开它即 `trzsz -z -d` 包裹，强烈推荐）+「ZMODEM 兜底（仅未装 trzsz-go 时）」（=旧 zmodemEnabled，pty 桥接兜底）。装了 trzsz-go 只开推荐那个。

**真机验证结论**：`sz 598MB` → trzsz 接管成功（`Transferred 598 MB, Speed 77.8 MB/s. Success!!`）；`tsz` → 存到 `~/Downloads`（同名自动加 `.1` 后缀防覆盖）。

**进度/总大小的取舍（trzsz-go 固有，XGhostty 改不了）**：trzsz-go 对两种协议两套进度——**trzsz 原生(tsz/trz)** 用带 `Progress.totalUnitCount` 的**完整进度条**（含总大小+百分比，协议握手带文件大小）；**ZMODEM(sz/rz 经 -z)** 硬编码成 `[2KTransferred %s, Speed %s.`——**只有已传量+速度、无总大小**。结论：**想要总大小就用 `tsz`/`trz` 替代 `sz`/`rz`**（效果一样、显示更全）；sz/rz 仅给只有 lrzsz 的老服务器兜底。

> **M3 文件传输至此收敛并真机通过**：统一 `trzsz -z -d ssh`（推荐），pty 桥接作无-trzsz-go 兜底，Esc 可取消，下载落 ~/Downloads。**Zig 核心的 divert 现仅服务兜底桥接**（trzsz 包裹路径用不上 divert，trzsz 自己消化协议字节）。

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

### 第三十一批（2026-06-14，出正式版 ReleaseFast + XGhostty Release 配置补全 + 图标加 X，真机装好启动通过）

用户要出「正式版」并装 /Applications。过程暴露并修复了 XGhostty 从没出过 Release 的配置缺口，并按需把图标加了 X 区分。

**① XGhostty 的 Release/ReleaseLocal 配置当初只配了 Debug（致命缺口）**
- duplicate 出 XGhostty target 时，差异化定制（`XGHOSTTY` 编译标志 / bundle id `top.niandui.xghostty` / 显示名 / `Ghostty Dev Cert`+Manual 签名）**只加在了 Debug 配置**；Release/ReleaseLocal 还是从主 Ghostty 原样复制（bundle id `com.mitchellh.ghostty`、ad-hoc、**无 XGHOSTTY 标志**）。
- 后果：直接 `-configuration ReleaseLocal` 出 XGhostty = 编成**普通 Ghostty 终端**（所有 `#if XGHOSTTY` 不编译）+ bundle id 撞主 app。从没出过 XGhostty Release，全部真机测试都是 Debug 构建。
- 修复：把 Debug 的 4 项定制平移到 **ReleaseLocal 块**（pbxproj `04775E4B`，整块用唯一 id 锚替换；两个 ReleaseLocal 块[主 Ghostty/XGhostty]共用 `GhosttyReleaseLocal.entitlements`，displayname/bundleid 段也全等，唯一可靠锚是块 id 行 `04775E4B` 与改出来的 `DisplayName="XGhostty"`+ReleaseLocal 独有 `AudioCapture`）。`SWIFT_ACTIVE_COMPILATION_CONDITIONS = "XGHOSTTY"`（不带 DEBUG）。
- **只改 ReleaseLocal、不碰 Release**：Release 用 `Ghostty.entitlements` **不带** `disable-library-validation`，自签证书 + hardened runtime 加载 GhosttyKit 会 SIGKILL；`GhosttyReleaseLocal.entitlements` 带（Debug/ReleaseLocal 都带）。macos/CLAUDE.md 正式版流水线本来就走 ReleaseLocal。

**② 图标加 X（用户要在原 Ghostty 图标上加 X 区分，不是单纯染色）**
- XGhostty 复用主 app 的 AppIcon 资源（`ASSETCATALOG_COMPILER_APPICON_NAME = Ghostty`），所以图标与 Ghostty 完全相同（一直没换）。
- 实现：`AppIconUpdater.update`（`Features/Custom App Icon/AppIcon.swift`）加 `#if XGHOSTTY` 分支，对最终图标叠加红底白「X」角标（新 `Features/XGhostty/XGhosttyAppIcon.swift` 的 `withXBadge`：右下角红圆+白描边+白 X，主线程 lockFocus 合成）；走原有 `NSWorkspace.setIcon(forFile: bundlePath)` → **Dock 与 Finder 都带 X**。
- **不会累加**：setIcon 写的是 bundle 的 Finder 自定义图标 xattr（com.apple.FinderInfo），**不动 Assets.car**；底图取自 `NSImage(named: NSImage.applicationIconName)`（asset 原图，无 X），每次启动重新合成。
- `update` 因加 `await MainActor.run`（lockFocus 要主线程）改成 `async`；唯一调用方 AppDelegate:890 已 `await`，主 app `#else` 分支行为零变。

**③ 出正式版 + 安装（真机通过）**
- Zig：`zig build -Doptimize=ReleaseFast -Demit-macos-app=false`（两个 app 共享 xcframework）。
- 主 Ghostty：`xcodebuild -scheme Ghostty -configuration ReleaseLocal` → 48M ReleaseFast 二进制（universal）、adhoc；装前 `codesign --force --deep --sign -` 重签再**原子替换** `/Applications`（cp 到 `.new` 再 `rm+mv`，删除正在运行 bundle 窗口压到毫秒，**不 kill 正跑 Claude Code 的 Ghostty**，重启才生效）。
- XGhostty：`xcodebuild -scheme XGhostty -configuration ReleaseLocal` → 49M ReleaseFast、真座舱（20951 个 XGhostty 符号）、bundle id top.niandui.xghostty、Authority=Ghostty Dev Cert、显示名 XGhostty；**直接 cp 装、绝不重签**（证书签名 xcodebuild 已签好，再 `--sign -` 会 SIGKILL）；先 kill 旧 XGhostty PID 再装再 open。
- 验证：XGhostty 启动存活（PID 在、启动时间 > 二进制 mtime 非 stale）、`--verify --deep --strict` OK、图标 X 生效（bundle 写了 FinderInfo）。首启动读保险库会因 cdhash 变弹一次钥匙串授权（已知，点「始终允许」）。

**关键取舍/坑**：① **duplicate target 的非 Debug 配置必须手动补全定制**——否则出 Release 是「普通终端 + 撞 bundle id」废品；`xcodebuild -showBuildSettings` 是 ground truth，别猜 pbxproj。② **签名两套规则别搞混**：自签证书 app（XGhostty）xcodebuild 已签、**禁止再 codesign**；adhoc app（主 Ghostty）按流水线重签。③ **Release entitlements 不带 disable-library-validation** → 自签证书出 Release 必崩，只改带它的 ReleaseLocal。④ 图标走 setIcon(forFile:) 同时管 Dock+Finder，且写 xattr 不动 asset → 不累加。

### 第三十二批（2026-06-14，XGhostty 专属绿图标——拆掉三层真凶才显示，真机通过）

用户要 XGhostty 用一张自做的绿色 neon 成品图（左上幽灵 + 右下 `X_`，`docs/design/XGhostty_APPICON_source.zip`）作图标，与原版蓝 Ghostty 区分。**期间踩了 macOS 26 图标的三层坑，逐层拆掉才显示**（中途试过运行时 `setIcon`/`applicationIconImage` 合成 + 红圈白 X 角标等多版，全废弃）。最终方案 = **传统 appiconset + 拆掉继承自 Ghostty 的两个图标机制 + 重建 LaunchServices**。

- [x] **图标资源**：把成品图做成传统 `XGhosttyAppIcon.appiconset`（16→1024 各尺寸，四角透明 + 标准留白，放 `macos/Assets.xcassets/`），pbxproj 把 **XGhostty 三配置**的 `ASSETCATALOG_COMPILER_APPICON_NAME` 从 `Ghostty` 改 `XGhosttyAppIcon`（只改 04775E49/4A/4B 三块，主 Ghostty 的 6 处不动）。`AppIcon.swift` 撤回上游原始（删掉之前那版 `#if XGHOSTTY` 角标合成 hack）、删 `XGhosttyAppIcon.swift`。
- [x] **真凶①：`Ghostty.icon`（macOS 26 Icon Composer `.icon` 格式）被 duplicate 继承** → 编译生成 `Ghostty.icns` 进 bundle，**优先级盖过 appiconset 的 `XGhosttyAppIcon.icns`**（bundle 里两个 icns 并存，显示 Ghostty 蓝）。解法：从 XGhostty 的 Copy Bundle Resources **移除 `Ghostty.icon`**（删 pbxproj 的 PBXBuildFile `04775E3A` + Resources phase 引用）。**必须 clean 构建**——增量构建不清旧 `Ghostty.icns` 残留。
- [x] **真凶②：`DockTilePlugin`（NSDockTilePlugIn）被继承** → 它在 **Dock 进程**里跑、用自定义 `contentView` 自绘图标（硬编码读 `com.mitchellh.ghostty` 配置 → 画原版蓝），**盖过 bundle 图标**。典型症状：**Finder 绿、Dock 蓝**——`NSWorkspace.icon(forFile:)` 和 `NSRunningApplication.icon` 都返回绿（读 bundle icns），唯独 Dock 视觉蓝（插件的 contentView 覆盖）。解法：① `Ghostty copy-Info.plist` 删 `NSDockTilePlugIn` 键；② pbxproj 从 XGhostty 的 "Copy DockTilePlugin" 阶段移除插件 embed（清空 `04775E46` phase 的 files）→ clean 构建 → bundle 无 `Contents/PlugIns/`（签名仍有效，证书签名自动重签）。
- [x] **真凶③：LaunchServices 脏注册 + 顽固图标缓存** → 多次重装在 LS 留下 DerivedData(Debug/ReleaseLocal) 的脏路径注册；`killall Dock`、清 `com.apple.iconservices`/`com.apple.dock.iconcache`、`lsregister -f`、甚至**重启**（但重启那会儿 bundle 还带旧 Ghostty.icns/plugin，不算数）都刷不掉。**终极解法：`lsregister -kill -r -domain local -domain system -domain user` 重建整个 LS 数据库**（约 30-60s）+ `killall Dock iconservicesagent` → 绿图标显示。

**关键诊断法**：图标"装了不显示"时，先用脚本把 `NSWorkspace.shared.icon(forFile: app)` 和 `NSRunningApplication(...).icon` 导成 png 看——**若都绿但 Dock 蓝 → 锁定 DockTilePlugin 自绘 + LS 缓存**（不是 bundle 问题，别再改 bundle）。`assetutil --info Assets.car` 看 appiconset 是否编进，`PlistBuddy Print :NSDockTilePlugIn` 看插件键，`lsregister -dump | grep` 看脏注册。

**铁律/教训**：① **duplicate 来的 macOS app 出专属图标，必须拆掉两个继承机制**——`.icon`（Icon Composer 资源，盖过 appiconset）和 `DockTilePlugin`（Dock 自绘，盖过 bundle 图标）。② **`.icon` 是成品分层格式**（gloss/screen/ghost/bevel 多图层 + 系统套容器），用户的扁平成品图塞 `.icon` 当单图层会被系统再套一层容器（双重边框）→ 用**传统 appiconset**（成品图原样显示）反而对。③ **macOS 图标缓存顽固到变态**：bundle 全对、所有 API 返回新图，Dock 仍显旧图时，认准是 LS/Dock 缓存，`lsregister -kill -r` 重建 LS DB 是核武器，别再瞎改 bundle。④ 全程只改 XGhostty 专属文件（`Ghostty copy-Info.plist`、pbxproj 的 04775Exx 块、新 appiconset），**主 Ghostty 零影响**（APPICON 仍 Ghostty、AppIcon.swift 回上游原始、主 app 的 .icon/DockTilePlugin 都没动）。

### 第三十三批（2026-06-15，批量「仅用密码」+ 批量发送框 ⌘X/默认空值/命令历史，正式版已替换 /Applications）

- [x] **批量「仅用密码」**（分组右键）：`SessionStore.setPasswordOnly(_:inGroup:)`（遍历重建子树，只对 `!isLocalShell && isPasswordLogin` 叶子设值，一次 save）+ `passwordLoginLeafCount` + `static isPasswordLogin`（有 identityFile 或引用 isKey 凭据 = 密钥，与 SessionEditView 判定一致）；分组 contextMenu「本组全部/取消『仅用密码』」→ NSAlert 预览数量 + 二次确认。
- [x] **批量发送框 ⌘X 剪切**：`inputField` 改自定义 `BroadcastInputField`（override `performKeyEquivalent`，仅 `currentEditor()!=nil`[聚焦编辑]时拦 ⌘X/C/V/A 走 field editor，未聚焦放行不夺终端快捷键）——根因：座舱把 ⌘C/V 绑给终端复制粘贴，普通 NSTextField 编辑时被吞。删掉调试默认值（NSTextField 初值本就空）。
- [x] **批量发送框命令历史**：发送后清空 + ↑/↓ 回滚（多行友好，`recordAndClear`/`recallPrev`/`recallNext` + `cursorInFirstLine`/`cursorInLastLine`）。
- [x] **部署脚本 `scripts/xghostty-deploy.sh`**：把出正式版固化成一条命令（`[xghostty|ghostty|both]`，不带参交互 select；`--core/--skip-core/--build-only/--yes/-h`），自动判 zig 重建 + 签名两套规则按 target 自动切 + 验证后才询问替换 + `pid_is_my_ancestor` 保护宿主。详见踩坑记录 C。

### 第三十四批（2026-06-15，根治 XGhostty cmd+w/关窗后 surface 不释放 —— CPU 不降 + SSH 僵尸，已部署）

关标签/关窗后 UI 层都释放，但 `SurfaceView`+`Surface`+C surface 不释放 → `ghostty_surface_free` 永不调 → 渲染/IO 线程 + CVDisplayLink + pty/ssh 全泄漏（CPU 不降、SSH 僵尸）。修复 = 新增 `SurfaceView.teardownSurfaceForClose()`（早期名 `xghosttyCloseSurface`），`closeTab` + `windowWillClose`（对残余标签遍历）调用，置空 `surfaceModel` 确定性触发 `ghostty_surface_free`。验证（单实例 8 会话）：关后 SurfaceView/Surface/CVDisplayLink/ssh 全归零、线程回落、CPU 0%。**完整诊断技法（`leak --trace` 反向引用树）与根因见踩坑记录 D**。

### 第三十五批（2026-06-15，把泄漏修复扩到主 Ghostty —— undo 感知版，已 ReleaseFast 部署，运行时验证通过）

主 Ghostty 同病但**不能照搬**：它关标签/窗/split 后故意把 surface 塞 undo 栈多活 `undo-timeout`（默认 5s，`src/config/Config.zig:@"undo-timeout"`）供 ⌘Z 复活，无脑置空 surfaceModel 会让 ⌘Z 复活成死 surface。**正确解 = undo 感知，卡在 undo 真过期那刻才拆、⌘Z 撤销的绝不拆**（commit `320491ab1`）：

- [x] `ExpiringUndoManager.registerUndo` 加 `onExpire`——只在真过期（定时器 / `isUndoRegistrationEnabled` false / `duration<=0` / 清空）触发，**⌘Z 执行时不触发**（`ExpiringTarget.invoked` 标志，执行 undo 的 `super.registerUndo` 闭包里先 `markInvoked()`；`expire()` 里 `!invoked` 才调 onExpire；`didExpire` 去重 timer/手动/deinit 三路）；`duration<=0`/禁注册时立即 onExpire（等价即时拆）。
- [x] `SurfaceView.xghosttyCloseSurface` 去 `#if` 改名 `teardownSurfaceForClose()` 两端共用，清理升级为 deinit 超集（补 `searchNeedleCancellable`/`trackingAreas`/`SecureInput.removeScoped`/`invalidateRestorableState`/删通知）+ `guard surfaceModel != nil` 幂等。
- [x] `BaseTerminalController.teardownOrphanedSurfaces<S:Sequence>`（static）——`DispatchQueue.main.async` 派发，**只拆「已不在任何 `TerminalController.all` 的 surfaceTree 里」的**（liveness 守卫双保险，⌘Z 拉回活树的不动；`SplitTree` 是 Sequence/Collection 故 `Set(tree).subtracting`/`tree.contains(view)` 可用）。
- [x] 四个 undo 注册点挂 onExpire：`replaceSurfaceTree`（关 split 的 undo 拆 `oldTree−newTree` + 内层 redo 拆 `newTree−oldTree`[覆盖「建 split 又撤销」]）、`closeTabImmediately`、`registerUndoForCloseWindow`（单窗口 `undoState.surfaceTree` + 多标签 `undoStates.flatMap`）。
- [x] 纯 Swift 零 C-ABI 改动，但出生产仍重跑 ReleaseFast zig（主 Ghostty 是日常驱动，不能降 Debug-hybrid）。运行时验证通过（重启后开标签 cmd+w 全关、等 >5s，heap SurfaceView 降到 = 活会话数）。

### 第三十六批（2026-06-16，本地 shell 文件传输[独立开关] + 终端复制三件套[cmd+C 修复 / 选中自动复制 / 复制去首尾空白]，纯 Swift 复用 xcframework 已部署真机验证通过）

**① 本地 shell 文件传输（rz/sz）——补「本地 shell 手动 ssh」盲区**
- 病根：本地 shell tab（`node==nil`）走 `openTab` 的 `else` 分支，**既不包 trzsz 也不武装 ZmodemBridge**（后者原条件 `!node.isLocalShell` 显式排除）→ 你在本地 shell 里手动 `ssh` 进服务器后，远端 `sz`/`rz` 吐的 ZMODEM 触发头无人接管 → 渲成满屏乱码。SSH 会话节点能用是因为走了 `trzsz -z -d ssh` 包裹那条路。
- [x] **新独立开关 `localShellTransferEnabled`**（`LayoutStore`，默认关，**独立于** SSH 会话的 trzsz/zmodem 开关——因副作用明确不可隐式联动）。座舱设置「本地 shell 文件传输（手动 ssh 后 rz/sz）」。
- [x] **包裹路径**：开关开 + 装了 trzsz-go → `cfg.command = /bin/sh -c 'exec <trzsz> -z -d <登录 shell> -l'`（封装同 ssh 路径，Ghostty 对 `.shell` 命令按 shell 词法解析）；`trzszWrapped=true` 复用 `~/Downloads` cwd。trzsz 坐最外层 pty，手动 ssh 几跳后远端 trz/tsz/rz/sz 全在字节流被它接管。登录 shell 读 `getpwuid(getuid()).pw_shell` 兜底 `/bin/zsh`。
- [x] **兜底路径**：没装 trzsz-go → 放开 ZmodemBridge 武装条件（新增 `isLocalShellTab = node==nil || isLocalShell`，本地 shell 看 `localShellTransferEnabled`、ssh 会话仍看 `zmodemEnabled`，sftp 排除）→ 本地 shell 也能挂 ZMODEM 兜底（仅 rz/sz）。
- **取舍（已写进开关说明）**：本地 shell 包裹后 cwd=~/Downloads（trzsz-go 下载落进程 cwd、无 output-dir 参数）= zsh 起始目录，**绑死**（ssh 会话无此副作用，因 cwd 只影响本地下载落点、不影响远端目录）；且 argv[0] 变 trzsz → 丢 Ghostty 自动 shell-integration。故默认关、需显式开。用户拍板维持 ~/Downloads 现状（备选「zsh 起在家目录 + 下载仍落 Downloads」需内层 `cd ~`、依赖 trzsz 下载读父进程 cwd，未做）。

**② 终端复制三件套**
- **cmd+C 失灵根因**：Ghostty surface 的 `performKeyEquivalent` 在 `!focused` 时 `return false`（`SurfaceView_AppKit.swift:1465`）；座舱自定义窗口里 surface 的 `focused` 没正确同步 → cmd+C（performable binding）走不到 keyDown 的 `copy_to_clipboard`，且座舱无 Edit 菜单兜底 → 复制失灵。
- [x] **cmd+C 修复（无条件，非开关）**：keyMonitor 接管 `cmd+c`——焦点在 `surfaceContainer` 且有选区 → 读 `currentSurface.accessibilitySelectedText()`（Ghostty 原生 NSAccessibility override，同 module 可调）自己写 `NSPasteboard.general`，**绕过 surface focus 链路**；无选区 / 焦点在文本框 → 放行默认。
- [x] **选中自动复制（开关 `copyOnSelect`）**：`leftMouseUp` local monitor，终端区域内松手 → `DispatchQueue.main.async` 延到选区结算后读选区复制（拖选 / 双击选词 / 三击选行通吃）；不拦事件（return event 让 surface 正常结算选区）。
- [x] **复制去首尾空白（开关 `copyTrimWhitespace`）**：复制时 `trimmingCharacters(in: .whitespacesAndNewlines)` 去**整段**首尾（cmd+C 与自动复制共用 `copyTerminalSelection(trim:)`）。两开关默认关、座舱设置面板。
- 真机验证：cmd+C / 自动复制 / 去空格 / 本地 shell 手动 ssh 后 rz/sz **四项全过**。

**③ 纯 Swift 零 C-ABI**：复用现有 ReleaseFast xcframework（跳 zig，只 `xcodebuild XGhostty ReleaseLocal`），`scripts/xghostty-deploy.sh xghostty -y` 一键，48MB / Dev Cert / ReleaseFast。改动集中在 `LayoutStore`（2 字段 +1 / setter / reset）、`ConsoleSettingsView`（3 开关）、`XGhosttyConsole`（本地 shell 包裹 + ZmodemBridge 放开 + `copyTerminalSelection` + cmd+C/mouseUp 两 monitor + `loginShellPath`）。

### 第三十七批（2026-06-16，XGhostty 专属 ghostty 覆盖配置机制 + selection-word-chars 设置面板，纯 Swift 已部署）

诉求：双击日志里 `CdWOQmOGJ9EtbmL6UfI~currentCount：…` 这种串，ID 会连选到 `~currentCount：`，想只给 XGhostty 改双击选词边界、不动主 Ghostty。
- **根因**：Ghostty 双击选词（`Screen.zig:selectWord`）只把字符**二分**为「边界 / 非边界」（无字母/数字/CJK 细分），连续非边界字符 = 一个词。默认边界集（含 tab 空格 引号 竖线 冒号分号逗号 各种括号 `$` 等，见 `Config.zig:755`）**不含 `~`、不含全角 `：`** → `~` 被当词字符跨选；停在全角 `：` 是因它是宽字符、其占位 cell 终止了向右扩展。Ghostty 有意把 `~` 当词字符（方便选 `~/path`）。
- **病根（只改 XGhostty 的拦路虎）**：XGhostty 的 `Ghostty.App(configPath: nil)` → `loadConfig(at: nil)` → `ghostty_config_load_default_files` → 读 `~/.config/ghostty/config`，**与主 Ghostty 共享同一文件**，改它两个 app 都变。
- [x] **通用「XGhostty 专属覆盖配置」机制**：`Ghostty.Config.loadConfig` 的 `#if XGHOSTTY` 分支在 `load_default_files` 之后叠加加载 `~/.config/xghostty/ghostty.config`（存在才加，后加载覆盖先加载）→ XGhostty = 主 config 继承 + 专属覆盖，主 Ghostty 零影响。**首次改共享 `Ghostty.Config.swift`，但纯加法 + `#if XGHOSTTY` 隔离**。以后任何「只给 XGhostty 的 ghostty 设置」都写这个文件。
- [x] **selection-word-chars 进座舱设置面板**：`~/.config/xghostty/ghostty.config` 的 `selection-word-chars` 行**即真相源**（不进 layout.json）；面板 `TextField` 是这一行的编辑器（`readSelectionWordChars` 读初值 / `writeSelectionWordChars` 只重写该行、保留其它行）+「填推荐值」按钮（默认集 + `~` + 全角标点）；提交即 `ghostty.reloadConfig()`（hard，重读所有 config 含专属文件、apply 到所有活 surface）**即时生效无需重启**。TextField 内容 = config 字符串语法（`\t` / `\"`），原样读写不转义。
- 纯 Swift 零 C-ABI（复用 xcframework），`scripts/xghostty-deploy.sh xghostty -y` 部署。

### 第三十八批（2026-06-16，修「启动默认本地 shell 不吃文件传输开关」+ 标签切换快捷键，纯 Swift 已部署）

诉求一：为什么启动软件时默认打开的本地 shell 没用上「本地 shell 文件传输（手动 ssh 后 rz/sz）」开关。
- **根因**：本地 shell 有**两条**进入路径，trzsz 包裹却只写在其中一条上——① 手动点「+」=`openTab(node: nil)` → 走 `else` 分支（读 `localShellTransferEnabled` ✓）；② **启动默认 / 恢复会话** = `restoreOrOpenInitialSession()` → `openSession(store.allHosts.first)`（`XGhosttyConsole.swift:1552`），传进去的是会话树里的 `SessionNode`，即便它 `isLocalShell`（无 host，`SessionStore.swift:28`），`node != nil` → 走 `if let node` 分支。该分支里 `SessionCommandBuilder.build` 对本地 shell 节点返回 `command: nil`（`SessionCommandBuilder.swift:52`）→ `if let cmd` 整段跳过、`cfg.command` 保持 nil 走原生 shell；而这分支的 trzsz 包裹只认 `transport == .ssh && (trzszEnabled || zmodemEnabled)`，**从不读 `localShellTransferEnabled`**。故会话树本地 shell 节点 tab 接不上 trzsz 全协议包裹（trz/tsz + `~/Downloads` 落点）。注：rz/sz 的 **ZMODEM 兜底** 反而生效——`isLocalShellTab`（`:1912`）已含 `node?.isLocalShell`。失效的只是 trzsz-go 透明包裹。
- [x] **修**：把本地 shell 的 trzsz 包裹从 `else` 分支**抽到两分支汇合处**，`cfg.command == nil` 守卫（不误碰已构造命令的 ssh 标签）+ `node == nil || node?.isLocalShell` 覆盖两种本地 shell。会话树本地 shell 节点 build 返回 command==nil 走到汇合处时 `cfg.command` 恰为 nil → 命中包裹；`trzszWrapped` 后续照样驱动 `~/Downloads` cwd 与跳过 ZmodemBridge，逻辑一致。

诉求二：同一 XGhostty 窗口内用快捷键切换终端标签。
- [x] **键位（主 Ghostty 同款）**：`⌘⇧]` 下一标签 / `⌘⇧[` 上一标签；`⌃Tab` / `⌃⇧Tab` 等价；`⌘1`..`⌘8` 跳第 N 个、`⌘9` 跳最后一个。均在 `tabOrder` 内环绕。
- **实现**：keyMonitor（window-level local monitor，先于 surface 收 keyDown）里判定 → 即便焦点在终端也优先切标签、`return nil` 吞事件。两个 helper：`selectRelativeTab(_:)`（环绕相对移动）、`selectTabAt(_:)`（跳第 N）。
- **坑**：`⌘⇧]`/`⌘⇧[` 不能靠 `charactersIgnoringModifiers`——shift **不**被它忽略，会把 `]`/`[` 变成 `}`/`{`，故按**物理键位** keyCode 30/33 判定。`⌃Tab` 加 `tabOrder.count > 1` 守卫：单标签时放行给终端，避免抢占 vim/tmux 的 `⌃Tab`。
- 纯 Swift 零 C-ABI（复用 xcframework），`scripts/xghostty-deploy.sh xghostty -y` 部署。

### 第三十九批（2026-06-16，座舱系统菜单栏整治——重定向/接通/禁用，纯 Swift 已部署）

诉求：座舱里「文件/编辑/显示/窗口」系统菜单大量灰色，问哪些能用、哪些该开、终端右键哪些可用。
- **根因**：菜单来自主 Ghostty 的 `MainMenu.xib`，action 全是 `target=First Responder` 沿响应链派发。座舱用自管窗口/标签，**不在** 原生 `TerminalController`/`BaseTerminalController` 响应链上 → 依赖原生终端窗口/分屏的项无人响应 = 灰；`newWindow:`/`newTab:` 沿链落到 `AppDelegate` → **点菜单会开原生 Ghostty 终端**（而快捷键 ⌘N/⌘T 被座舱 keyMonitor 拦截走座舱，键与菜单行为不一致）；分屏 `splitRight:` 等由 `SurfaceView` 自己响应 → 座舱里**亮着但无 SplitTree 容器接管 → 点了无效**。
- [x] **重定向 / 接通**（座舱 `XGhosttyConsoleController: NSWindowController` 在响应链上、位于 window 之后、AppDelegate 之前，于此拦截）：`newWindow:`→座舱新窗口、`newTab:`→`duplicateCurrentTab`、`closeTab:`/`close:`→关当前标签（关到空再关窗）、`closeWindow:`→关座舱窗口、`toggleSessionSharing:`→当前 surface 共享。全部与 keyMonitor 同名快捷键行为一致。
- [x] **禁用分屏**（座舱不支持）：`SurfaceView.validateMenuItem` 加 `#if XGHOSTTY` 对 `splitRight/Left/Down/Up` 返回 false（菜单灰）；右键 `menu(for:)` 加 `#if !XGHOSTTY` 去掉分屏 4 项 +「更改标签页标题」（`BaseTerminalController.changeTabTitle`，座舱不在链恒灰）。**首次改共享 `SurfaceView_AppKit.swift`，纯 `#if` 隔离、主 Ghostty 零影响**。
- [x] **`validateMenuItem`**（座舱端 `NSMenuItemValidation`）：无标签禁 `closeTab/close`、无 surface 禁共享；其余 true 不干预链上其它判定。
- **坑**：`closeTab` 重载歧义——类里已有 `closeTab(_ tabId: UUID)`，新加 `closeTab(_ sender: Any?)` 在 `closeTab(id)` 调用点报 `ambiguous use of 'closeTab'`（且 ObjC selector 只看「方法名+参数 label」不看类型，两个 @objc `closeTab:` 还会 selector 冲突）。解法：Swift 名改 `menuCloseTab(_:)`，用 `@objc(closeTab:)` 保 selector 仍是 `closeTab:` 匹配 xib。
- **现状对照**：✅ 本就可用（粘贴/全选/查找/复制[有选区]/更改终端标题/终端只读/快速终端/检查器/最小化缩放/显示隐藏所有/全部到前/关闭所有窗口）；🟩 接通后新亮（新建窗口[座舱]/新建标签/关闭/关闭标签页/关闭窗口/共享此会话）；🟥 保持灰=座舱无此能力（撤销重做/字体缩放/命令面板/更改标签页标题/从组移除窗口/放大分屏/选择上下分屏 ⌘[ ⌘]/切换全屏）；分屏由「亮但无效」改为灰（杜绝误导）。
- 纯 Swift 零 C-ABI（复用 xcframework），`scripts/xghostty-deploy.sh xghostty -y` 部署。

### 第四十批（2026-06-16，座舱接通字体缩放——增大/减小/重置 + 快捷键，纯 Swift 已部署）

诉求：增大字体 / 减小字体 / 重置字体大小（⌘+ / ⌘- / ⌘0）在座舱也要支持（第三十九批曾归为「🟥 保持灰」，本批订正为接通）。
- [x] **接通 action**：座舱菜单 extension 加 `increaseFontSize:`/`decreaseFontSize:`/`resetFontSize:`，对 `currentSurface?.surface` 发 `ghostty.changeFontSize(surface:, .increase(1)/.decrease(1)/.reset)`（与主 Ghostty `BaseTerminalController` 同实现，enum `Ghostty.App.FontSizeModification`）。`validateMenuItem`：有 surface 才启用。`SurfaceView` 未实现这三 selector → 响应链落到座舱 `NSWindowController`。
- [x] **快捷键自动随之生效**：菜单项 enabled 后，运行时按 keybind 填的 `keyEquivalent`（⌘+/⌘-/⌘0）即触发——**无需改 keyMonitor**。已核 keyMonitor 不拦这三键：⌘0 被 `⌘1..⌘9` 的 `d>=1` 排除、⌘+/⌘- 非数字放行。事件顺序：local keyMonitor 先于菜单 `performKeyEquivalent`，放行后由菜单接管 → 落座舱 action。
- **订正**：第三十九批「现状对照」里字体缩放（⌘0/⌘+/⌘-）由 🟥（保持灰）改为 🟩（接通后可用）。
- 纯 Swift 零 C-ABI（复用 xcframework），`scripts/xghostty-deploy.sh xghostty -y` 部署。

### 第四十一批（2026-06-23，⌘F 搜索框焦点对齐主 Ghostty——聚焦 + 点终端切回 + 按钮可点，纯 Swift 已部署）

诉求：座舱 ⌘F 与主 Ghostty 行为对齐——打开即聚焦搜索框、点终端能立刻切回输入（搜索栏保留）、搜索条按钮可点。复用主 app 的 `Ghostty.SurfaceSearchOverlay`，但座舱把它单独塞进**全屏 `NSHostingView`** 挂在 `surfaceContainer` 上（≠ 主 app「在 SwiftUI 大树内」），由此引出三个叠加 bug，逐个解开：

- **bug1 焦点不进搜索框**：独立 `NSHostingView` 里 SwiftUI `@FocusState`（`onAppear isSearchFieldFocused=true`）不会把 first responder 下放到底层文本框；而 `makeFirstResponder(hosting)` 会卡在容器上（容器不处理键盘 → 终端+搜索框都哑）。→ `focusSearchField(in:)` 绕过 SwiftUI focus，DFS 找浮层里第一个可成 first responder 的文本控件（优先 `NSTextField/NSTextView`）直接 `makeFirstResponder`，下一帧 layout 后找、找不到再兜一帧。
- **bug2 搜索开着点终端切不回**：浮层 `.gesture(DragGesture())` 加在占满终端的 `.frame(maxWidth:.infinity,maxHeight:.infinity)` 上（`SurfaceView.swift`），让独立 `NSHostingView.hitTest` 把整块（含搜索条以外透明区）都返回自己 → 主 app「点终端切回」依赖的 `SurfaceView` 鼠标 monitor（`localEventLeftMouseDown` 判 `window.contentView.hitTest==self`，`SurfaceView_AppKit.swift:798`）永不成立。又因现代 SwiftUI 按钮也扁平渲染、`hitTest` 同返回 hosting 自己，按返回值分不清「条外透明」与「条上按钮」（直接穿透会误杀按钮，原注释踩过这坑）。→ 共享浮层加可选 `onBarFrameChange`（默认 `nil`、主 app 零影响）经命名坐标系上报搜索条 frame；座舱 `SearchOverlayHostingView` 子类据此**只放行条内点击、条外返回 nil 穿透**到终端。
- **bug3 点搜索框/按钮没反应（坐标系坑）**：`NSView.hitTest(point)` 的 `point` 在**父视图 `surfaceContainer`（非 flipped、y 从底）** 坐标系，而上报 frame 是 SwiftUI（y 从顶）→ y 反了恒判条外，条内点击全被穿透。→ 改 `convert(point, from: superview)` 转本视图局部坐标再比对（实测点 TextField `pt.y=890 → 34`，落在条 `y 8~52` 内 ✓；点终端 `459 → 465` 在条外穿透 ✓）。
- **调试技法（呼应踩坑 D）**：XGhostty 进程**完全不进 unified log**（`log show --predicate 'processImagePath CONTAINS "XGhostty"'` 0 行）→ `NSLog`/`log stream` 探针全废。改**写文件**（`/tmp/xgsearch_debug.txt`，`FileHandle.seekToEnd` append）一次拿到 `searchBarFrame` 实测值 + 命中判定，立即定位坐标系反向。**座舱内调试一律写文件，别指望 unified log / NSLog。**
- 改动：`SurfaceView.swift`（共享浮层 `onBarFrameChange` + 命名坐标系上报，主 Ghostty scheme 已验证编译通过、零行为变化）、`XGhosttyConsole.swift`（`focusSearchField` + `SearchOverlayHostingView` 子类 + `openSearch`）。纯 Swift 零 C-ABI（复用 xcframework），`scripts/xghostty-deploy.sh xghostty --skip-core -y` 部署，真机验证：⌘F 聚焦 / 点搜索框输入 / 按钮可点 / 点终端切回 / 翻页 全通。

### 第四十二批（2026-06-23，⌘F 搜索框「拖动后点不动」bug4——三轮误诊→实测定位，纯 Swift 已部署）

承第四十一批同一套机制（座舱浮层靠**上报 frame 重建命中区**）。主 app 搜索条可拖动 snap-to-corner；座舱**拖动松手后点搜索条部分位置点不动**（点中部命中、点左/下边缘穿透）。**连错两轮诊断**，教训值钱：

- **误诊 1（offset 不进 frame）**：先猜 `.offset(dragOffset)` 是纯视觉变换、不反映进 `GeometryReader.frame(in:)`，在 `SurfaceView` 加 `.offsetBy` 叠加上报——**证伪**：实测 `REPORT` 拖动中是跟手的（bar 从 `(1383,8)` 平滑变到 `(-52,957)`），offset 确实进了命名坐标系 frame。
- **误诊 2（safe area 偏移）**：再猜 `NSHostingView` 避让 window safe area（top≈52）致坐标系错位，hitTest 减 `safeAreaInsets` 并集判定——**证伪**：实测 `safe=NSEdgeInsets(top:0,...)`，safe area 根本是 0。
- **实测真因**：松手 `onEnded` 用 `withAnimation { dragOffset = .zero }` 把条**弹回角落**；这步是渲染层动画，`GeometryReader` 在动画**最后一帧**（offset 尚未归零）触发一次 `onChange` 上报后，真正归零那帧的 `onChange` 不再触发（SwiftUI 老毛病）→ 上报的 `bar` **卡在动画中间帧**（`(38.9,860)` = snap `(8,872)` + 残留 offset `(30.9,-12)`），而搜索条**视觉**已落到 snap，两者错位 → 点条边缘落在过时 bar 外被穿透。决定性日志：`ONCHANGE measured=(1106,822) report=(1383.5,872) drag=(0,0)`。
- **修复（`SurfaceView.swift` 一处）**：上报逻辑不信动画期间的测量值——`dragOffset`（@State）在松手瞬间即归零（动画只是渲染插值），故 `onChange` 里 **`dragOffset==.zero` 时按 `corner` 上报 `snappedFrame` 落位值（=动画终点视觉位置），否则跟手上报测量值**；无论动画哪帧触发 `onChange` 都得同一稳定 snap，彻底消除中间帧错位。`snappedFrame(for:in:barSize:)` 公式与初始布局一致（贴角、离边 `padding`，实测 topRight `x=1712-8-320.5=1383.5` 吻合）；`onEnded` 另显式上报 snap 兜底。**纯 XGhostty 行为**：主 app `onBarFrameChange=nil`、`?.` 短路、零影响。
- **坑：辅助方法名 `barFrame` 撞局部变量** `let barFrame = barGeo.frame(...)` → Swift 把方法调用当成对 CGRect 变量调用、类型推断爆炸（`unable to type-check this expression in reasonable time`，报在 body 起始行误导）。改名 `snappedFrame` 解决。
- **调试技法（强化 D）**：这次**双文件双向探针**——`SurfaceView`(上报侧：`APPEAR / ONCHANGE measured+report+drag / ENDED snap`) + `XGhosttyConsole`(接收侧：`RECV` + `HIT local/bar/cl/super`) 写**同一** `/tmp/xgsearch.log`，时序交错一眼看穿「上报什么→收到什么→点击命中什么」（`super=_SystemTextFieldFieldEditor` 证实点中真实输入框）。**纯推理在 SwiftUI 微妙几何（offset / 动画 / 坐标系）上连错两轮，写文件探针实测一轮定位**——座舱调试别赌行为，插桩取真值。

#### 方案选型（命中架构，2026-06-23 复盘定调）

本 bug 暴露的是**座舱跨 AppKit↔SwiftUI 边界、两个「搜索条在哪」事实来源失同步**的结构问题。根因背景：两边终端 surface 都是 NSView（`SurfaceView_AppKit.swift:13` `class SurfaceView: OSSurfaceView`），分界在「包 surface 的外层容器」——主 app 用 SwiftUI `ZStack`（`SurfaceWrapper`，`SurfaceView.swift:36`，搜索浮层是 ZStack 兄弟层，SwiftUI 原生命中、单一事实来源）；座舱用纯 AppKit（`NSSplitView`/`ConsoleSplitView`，要 IDE 式多窗格可拖布局），没有 SwiftUI 父树，只能把浮层塞独立全屏 `NSHostingView`（`XGhosttyConsole.swift:2755`）靠上报 frame 手动重建命中 → 两个事实来源。三个候选：

- **方案 B（已证伪，勿再试）**：让 `SearchOverlayHostingView.hitTest` 委托 `super.hitTest` + `hit === self ? nil` 穿透、删 `searchBarFrame`。**死路**——`SurfaceSearchOverlay` 的 ‹›✕ 是 SwiftUI 纯绘制（无 backing NSView），`super.hitTest` 对按钮区也返回 hosting `self`，`hit===self?nil` 把按钮点击当透明区吞掉（现象「框能输入、按钮点不动」，本文件「自定义 hitTest 穿透会误杀 SwiftUI Button」一条已记）。当前 `searchBarFrame.contains` 方案正是被「占满 hosting 吃掉终端点击」⊕「纯绘制按钮无 backing view」两头夹出来的合理解。
- **方案 C（现状，已部署）**：保留两个事实来源，但上报从「动画终点稳定值」拿（`snappedFrame`）。**治标**。唯一长期债务：`snappedFrame` 是对上游 `corner.alignment + padding` 落位的**手算镜像**，与上游实现隐性耦合——上游改搜索框 snap 落位算法时会静默算错、又 desync。
- **方案 A（彻底解，暂不做）**：把座舱「终端格」重构成 SwiftUI 复合视图（仿 `SurfaceWrapper`：`ZStack{ SurfaceRepresentable; SurfaceSearchOverlay }` 用 NSHostingView 托管挂进 NSSplitView），命中回归 SwiftUI 原生，删除全部 fork 侵入。**结构性根治**两个事实来源，但要动座舱最核心、反复踩坑才稳定的终端格挂载（resize/`SurfaceScrollView`、focus、cmd+C monitor、拖分隔条、undo 拆 surface 全挂在它上面），成本/风险大。
- **结论：维持 C，不上 A。** 依据：① fork 侵入实测小——搜索条拖动/snap **全是上游的**（`git blame`：`b87d57f029` Mitchell + `cbcd52846c` Lukas），我们只**搭车**加了 `onBarFrameChange` 可选回调（默认 nil、主 app `?.` 短路零影响）+ `snappedFrame`（`bc3fce4e93`/`36e2d3e137`）；② 上游搜索框拖动是 2025-11 才进的边角功能、变动低频，C 的债务触发概率低、后果可控（最坏「拖动后又点不准」，可感知可修，不崩）；③ A 的成本/风险与「边角浮层命中精度」收益严重不成比例。
- **方案 A 触发条件**：当搜索浮层交互显著变复杂（多个可拖浮层 / 浮层可缩放 / 浮层内更多需精确命中的控件）使手算镜像维护成本 > 重构成本时，再启动 A，一次性回到「画在哪点在哪」单一事实来源。**详细可落地执行方案见下「方案 A 执行预案（多角度评审）」。**
- **护栏（已落地，零运行时风险）**：① `snappedFrame` 注释补「上游耦合警示」；② 根 `CLAUDE.md` 合上游清单加一条——合上游若 `SurfaceSearchOverlay` 拖动/snap 落位被动过，必须回核 `snappedFrame` 是否还对得上。把隐性耦合从「埋着」变「合并时必检」。

#### 方案 A 执行预案（多角度评审，2026-06-23，暂不实施）

四个 agent 并行评审（resize 路径 / SwiftUI 环境依赖 / 回归风险红队 / 迁移与收益）综合产出。**一句话定调**：方案 A 收益明确（共享文件 fork 侵入清零、隐性耦合消除），但它**不是简单重构**——承重墙集中在三处「项目历史上已踩坑写过血泪注释」的 AppKit 交界，三道墙缺一项就**回归已修复的 bug**。故定为「预案」：满足触发条件再启动，且必须先在不碰共享文件的前提下验证三道墙可破。

**A. 目标架构**：把座舱终端格从「`surfaceContainer`(NSView) + 裸挂 `SurfaceScrollView`」重构为单个 `NSHostingView<ZStack{ SurfaceRepresentable(view:sv,size:geo.size); if searchState { SurfaceSearchOverlay(...) } }>` 作为 `rSplit` 的 pane 0。**直接复用上游** `Ghostty.SurfaceRepresentable`（`SurfaceView.swift:693`，其 `makeOSView` 内部就 `new SurfaceScrollView` → scrollback 滚动条 + resize 全白送、零自研）与 `SurfaceSearchOverlay`（零 `Ghostty.App` 依赖，lite ZStack **无需** `.environmentObject` 注入）。命中回归 SwiftUI 原生 Z 序穿透。

**B. 收益（量化）**：共享文件 `SurfaceView.swift` 的 **8 处 fork 侵入 / ~41 行代码 + 16 行注释 → 0**（回归纯上游，此文件未来合上游零冲突面）；消除 2 类隐性耦合（`snappedFrame` 手算镜像 = 静默偏移源、`barSize` 测量块结构依赖）；console 侧删 ~80 行 hack（`SearchOverlayHostingView` 子类 + 自定义 hitTest + DFS 聚焦 + frame 回填）。

**C. 三道承重墙（前置必解，缺一不可上）——核心难点**：
- **墙 1｜firstResponder 必须下放到内层 surface**：`Ghostty.SurfaceView.focused` 只由 NSView `becomeFirstResponder` 驱动（`SurfaceView_AppKit.swift:968-982/579`）。包进 hosting 后若 `makeFirstResponder(hosting)` 会卡在容器、内层 surface `focused` 恒 false → `performKeyEquivalent`（`:1465` `if !focused return false`）全 false → **cmd+C 失灵（`docs:604` 复发）、终端可能收不到键盘**。项目已在搜索浮层踩过同一坑（`XGhosttyConsole.swift:2808-2811` 注释原话）。解：representable 让内层 surface 真正成 first responder，座舱 `makeFirstResponder(内层 sv)` 而非 hosting；或 hosting override `becomeFirstResponder` forward 给内层 surface。
- **墙 2｜三个 event monitor 命中锚点**：cmd+C / leftMouseUp / ⌘A 用同一谓词 `(firstResponder as? NSView)?.isDescendant(of: surfaceContainer)`（`:2914/2924/2967`）。换容器 + 墙 1 未解 → 复制三件套 + ⌘A **静默失效**（不崩不报、点了没反应，极易蒙混过测）。解：谓词锚点统一改指新 hosting 容器（建议固化一个 `terminalPaneView` 引用集中这 3 处），且依赖墙 1 让内层 surface 是该容器子孙。
- **墙 3｜NSSplitView 经典 frame 模式 vs NSHostingView 固有尺寸顶牛**：`ConsoleSplitView` 注释（`:8-10`）正是为规避这个才用裸 NSView 做 pane。pane 0 换 hosting 正面撞禁忌 → 拖分隔条回弹/抖动、终端格被 SwiftUI 内容尺寸反推、`captureLayout`（`:1477`）存错 frame、重启布局漂移。解：新 hosting pane `translatesAutoresizingMaskIntoConstraints=true`（对齐 `:1032`）+ 压制 intrinsic（`.frame(maxWidth/maxHeight:.infinity)` + representable `intrinsicContentSize=.noIntrinsicMetric`）+ delegate 身份判断（`:3079/3085`）与 `captureLayout` subview 引用统一改指新容器。

**D. 中风险项**：① **teardown/泄漏回归**——`teardownSurfaceForClose` 的 `removeFromSuperview`（`:469`）与 SwiftUI `dismantleNSView` 可能双重 remove / 持有竞争 → 第三十四/三十五批 surface 泄漏回归。解：拆前先解 representable 绑定、明确所有权、**复用同一 `Ghostty.SurfaceView` 实例不 new**；关 N 标签后按第三十四批 `heap` 计数复测。② **exitBar / zmodemOverlay**：搬进 ZStack 用 z-index 重表层序，或先留 AppKit 兄弟（改动最小，推荐先留）。

**E. 零风险项（确认无需动，前提=复用同一 surface 实例）**：输出订阅（SessionLog/expect/sftp/zmodem）以 C `ghostty_surface_t` 指针为键（`OutputDispatch.swift:28`），与视图层级正交；broadcast/readonly/passwordInput 过滤读 surface model；`applyTitlebarTheme`/`applyColors` 走 window/contentView。**澄清**：座舱**无 undo-close**（`docs:443`），`closeTab` 即时 teardown；undo 感知那套是主 Ghostty 的 SplitTree 路径，座舱不进——红队报告纠正了任务里「undo 拆 surface」的概念混淆。

**F. 增量可回退迁移（4 步，关键：Step 1/2 不碰共享文件、可安全停手）**：
- **Step 0**：`git tag` 基线锚点 + 方案 C 全功能基线手测。
- **Step 1**：console 新建终端格 SwiftUI 视图（先**只含** `SurfaceRepresentable`、不含浮层），hosting 替换裸 `SurfaceScrollView` 直挂（`:1957-1968`）。**不改 `SurfaceView.swift`**。验证渲染/缩放/滚动/cmd+C/focus/拖分隔条/多 tab 照旧 + 探针确认 `sizeDidChange` 仍调。**这一步就会正面撞墙 1/2/3**——过不了即停手回滚，零共享文件改动。
- **Step 2**：浮层并入同一 ZStack（先仍传 `onBarFrameChange` 双保险），删 console `SearchOverlayHostingView` 挂载（`:2782-2807`）。验证 ⌘F 自动获焦（`@FocusState` 跨 hosting 是否工作）、条内按钮可点、点终端切回焦点（原生穿透）、拖动后命中。**仍不改共享文件，不如预期可停手。**（连带：Esc 关搜索现判 `searchOverlayHosting != nil`（`:2956`），删该字段后须改判 `searchState`，否则 Esc 关不掉浮层——验证 spike 实读确认。）
- **Step 3**：**仅 Step 2 运行时验证通过后**——`SurfaceView.swift` 删 8 处侵入还原上游，`git diff <upstream-base> -- SurfaceView.swift` 应为零。收益落地。
- **Step 4**：清 console 死代码（`SearchOverlayHostingView`/`searchBarFrame`/`focusSearchField` DFS 兜底等）。
- 收益与功能解耦、可分别 `git revert`。

**G. 手测清单**：拖动后命中 / 点终端切回焦点 / ⌘F 自动获焦 / scrollback 滚动 / cmd+C 复制（浮层开关各一次）/ focus 基线 / 拖三条分隔条 + 缩放 + 重启恢复布局 / 多 tab 切换 searchState / 关 tab 重开后再 ⌘F（座舱无 undo，等价复活）/ Esc 行为 / 翻页 Enter·Shift+Enter。座舱不进 unified log → 凡需观测内部状态配 `/tmp` 文件探针。

**H. 约束**：文件探针调试；`scripts/xghostty-deploy.sh xghostty --skip-core -y`（纯 Swift 复用 ReleaseFast xcframework、自动 kill+重启）；XGhostty Dev Cert **绝不 `--deep` 重签**；泄漏用 `heap` 计数复测。

**结论重申**：维持 C。方案 A 工时中等但回归风险集中且隐蔽（墙 2 静默失效极易漏测），**承重墙是三处历史血泪坑的正面放大**。触发条件（上游改落位 / 浮层变复杂 / 合上游连续冲突 / 终端格本就要 SwiftUI 化）满足任一再启动，且**必须 Step 1/2 先验证三道墙可破，方可推进 Step 3 清零共享文件**。

### 第四十三批（2026-06-25，⌘F 搜索框切 tab 跟随/独立[开关] + 切 tab 不跳右上角 + ⌘⏎ 编辑会话/重命名分组 + 设置面板按类别分组，纯 Swift 已部署）

诉求三件：① 第五批「切 tab 自动关搜索」用户反馈不便——切标签后搜索框不该消失，且要开关二选一；② ⌘⏎ 选中会话/分组快速打开编辑（分组=重命名）；③ 设置面板 13 个开关平铺偏长，按类别分组整理。

- **搜索框切 tab 跟随/独立（`searchPerSession` 开关，`LayoutStore`）**：默认 `false`=**模式 A 跟随当前会话**（切 tab 搜索框保持打开、搜索词带到新会话继续搜，全局一个框）；`true`=**模式 B 每会话独立**（切走保留该 surface 的 `searchState`、切回还原，互不影响）。`select()` 末尾的无条件 `closeSearch()` 改成 `migrateSearchOverlay(from: oldSurface)`（须在 `currentTabId` 改前抓 `oldSurface`）。
- **关键机制实证（agent 调查 + 实读）**：`searchState` 本就挂在每个 `SurfaceView` 上（per-surface，`OSSurfaceView.swift`）；给 `searchState.needle` **赋值即自动触发搜索**——`SurfaceView_AppKit.swift:46` 的 `searchState.didSet` 建 Combine 订阅 `$needle`（`removeDuplicates`→防抖→`ghostty_surface_binding_action("search:<needle>")`），与 overlay 是否挂载**无关**。故模式 A 切 tab：`oldSurface.endSearch()` 清旧 → 新 `sv.xghosttyStartSearch()` 建空 searchState → `ss.needle = 旧 needle` 自动重搜。模式 B 复用：`xghosttyStartSearch()` 的 `guard searchState == nil` 天然保留每会话 searchState，切回直接挂浮层、needle 原样不动。
- **bug：切 tab 后搜索框跳回右上角**（用户反馈）。**根因**：首版 migrate 用 `removeFromSuperview()` + `openSearch()` **重建浮层** → `SurfaceSearchOverlay` 里管 snap 落位的 `@State private var corner`（`SurfaceView.swift:443`，默认 `.topRight`）随重建归零。**修复**：模式 A **复用同一个 `SearchOverlayHostingView` 实例、只 `hosting.rootView = 新 overlay`** 绑新 surface——NSHostingView 实例不销毁，SwiftUI 对**同类型根 View** 的更新保留 `@State`（`corner`/`dragOffset`），搜索框停在用户拖到的角。成立前提：`surfaceContainer` **全局唯一**（`:846`，所有 tab 的 scroll 靠 `isHidden` 切换可见），浮层一直覆盖当前可见 surface、切 tab 无需 reparent；且 `SurfaceSearchOverlay.surfaceView` 是 `let`（非 `@StateObject`），换 rootView 不扰动位置 `@State`。
- **⌘⏎ 编辑会话/重命名分组**：`keyMonitor` 加 `keyCode==36`——`treeHasFocus()` 且有选中（`selectionAnchor ?? selectedIds.first`）→ `editNode(node)`（会话=编辑表单、分组=重命名表单，`SessionEditView` 对两者通用）；否则 `return event` **放行给发送条的 `sendBtn.keyEquivalent="\r"+.command`**。能拦得住是因 **local keyDown monitor 先于 NSButton 的 `performKeyEquivalent`**（现有 ⌘W/⌘C 同理），故树聚焦时拦成编辑、焦点在终端/发送框时不破坏「⌘⏎ 发送」。
- **设置面板按类别分组**：`ConsoleSettingsView` body 把 13 开关 + 选词字符 + 4 维护按钮重排成 5 组——`会话树与布局` / `终端·复制·搜索` / `文件传输` / `连接与日志` / `维护`，每组 `sectionHeader(_:)`（semibold secondary 小标题）+ `Divider()`。纯 UI 重排，`@State`/`onToggle` 回调零改动；「还原默认设置」仍靠 `dismiss + 重开 presentSettings` 刷新 @State（面板 init 一次性赋值）。
- **顺带核查「复制软换行变多行」**：用户先报「多行选中（内容一行）cmd+c 粘贴变多行」。实测 `formatter.zig` 加临时 selection 测试（已还原）——XGhostty 本地软换行复制**正确**：cmd+C 走 `Surface.zig:copySelectionToClipboards` 硬编码 `unwrap=true` → formatter `if (!row.wrap or !unwrap)` 对 soft-wrap 行不插换行。是**主 Ghostty 才有**的问题，本批按用户意见不处理（之前 agent 推测的「formatter.zig:1111 缺 end_y 检查」为误判，已否）。
- **新护栏 / 隐性耦合（写进根 `CLAUDE.md`）**：`migrateSearchOverlay` 复用 `rootView` 保位置，隐性依赖上游「`SurfaceSearchOverlay` 的拖动落位是其内部 `@State corner`、同类型根 View 重建即保留」。上游若把位置状态外置/重构 `SurfaceSearchOverlay` 的 `@State` 结构，座舱切 tab 后会**静默跳回右上角**（不报错）——与第四十二批 `snappedFrame` 同类的上游耦合，合上游需回核。
- 改动：`LayoutStore.swift`（`searchPerSession` 字段/setter/Defaults/reset）、`XGhosttyConsole.swift`（`select`→`migrateSearchOverlay`、`openSearch`、keyMonitor ⌘⏎、presentSettings 接线）、`ConsoleSettingsView.swift`（搜索开关 + 5 组重排）。纯 Swift 零 C-ABI，`scripts/xghostty-deploy.sh xghostty --skip-core -y` 部署，三轮迭代真机：搜索框跟随/独立 + 位置保留 + ⌘⏎ + 分组。

### 踩坑记录（换机/重做必看）

**A. Xcode duplicate macOS target（fileSystemSynchronized 同步组）会生成错误的成员例外集**
duplicate 把 **iOS target 的排除清单**错按给新 target，导致：
1. 错排 `App/macOS/main.swift` → 缺 `_main`，链接 `Undefined symbols: "_main"`；
2. 漏排 `Ghostty/Surface View/SurfaceView_UIKit.swift` → `ambiguous type name 'SurfaceView'`。
**解法**：把新 target 的 `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions` 改成与正牌 macOS `Ghostty`（例外集 `81F82CB1`）**一字不差**——排除 `App/iOS/iOSApp.swift`、`Features/Custom App Icon/DockTilePlugin.swift`、`Ghostty/Surface View/SurfaceView_UIKit.swift` 三个。备份在 `project.pbxproj.bak-xghostty`。

**B. setup-dev-cert.sh 的 p12 导入坑**（已在脚本注释）：非空中转密码 + OpenSSL3 需 `-legacy -macalg sha1`，否则 `security` 报 "MAC verification failed"。命令行导私钥还需 GUI 授权，最终用钥匙串访问「证书助理」一步到位最稳。

**C. 出正式版 / 部署的硬规则（XGhostty 与主 Ghostty 相反，违反即 SIGKILL）**
- **ReleaseFast 才是真 release**：`zig build -Demit-macos-app=false` 默认 Debug → 出 Debug-hybrid（zig 核心慢、最终二进制 ~120MB）。出生产必 `-Doptimize=ReleaseFast`。标尺：ReleaseFast `ghostty-internal.a` ≈270–283MB（Debug ≈386MB）、最终二进制 ~48MB。**纯 Swift 改动可复用已有 ReleaseFast xcframework 跳过 zig**（只 `xcodebuild`）。
- **签名两套规则**：① **XGhostty** 用自签 `Ghostty Dev Cert`（`CODE_SIGN_STYLE=Manual`），`xcodebuild` 已自动签，**绝不要再手动 `codesign --force --deep --sign -`**——`--deep` 在 macOS 26 重签内嵌 dylib → 运行期 `SIGKILL (Code Signature Invalid)` / amfi 拒绝（诡异点：`codesign --verify` 仍报 valid）。② **主 Ghostty** 是 adhoc，`zig build` 直接换二进制后**必须** `codesign --force --deep --sign -` 重签再启动，否则 SIGKILL。
- **只改 ReleaseLocal 不碰 Release 配置**：Release 的 `Ghostty.entitlements` 无 `disable-library-validation` → 自签证书出 Release 必 SIGKILL；ReleaseLocal 的 entitlements 有，所以出生产走 `-configuration ReleaseLocal`。
- **原子替换 + 不杀宿主**：`cp .new → rm 旧 → mv` 替换 `/Applications`（运行中实例靠 mmap 旧 inode 不受影响）；别 `kill` 当前 Claude Code 宿主（=主 `Ghostty.app`）。**重建后 `open` 前先 kill 旧实例**——同 bundle id 时 LaunchServices 只激活旧实例、不换新二进制（现象：改了代码重建后 UI 毫无变化）。
- 全流程已固化进 `scripts/xghostty-deploy.sh`（坑：macOS 自带 `/bin/bash` 是 3.2 无 `declare -A` → 用 `eval` 间接变量；`stat -f%z`/`ps -o ppid=` 是 BSD 写法）。

**D. Surface 泄漏诊断技法（可复用）+ cmd+w/关窗不释放的根因**
- **现象**：关标签/关窗后 UI 层（控制器 / scroll view）都释放，但 `Ghostty.SurfaceView` + `Ghostty.Surface` + C surface 不释放 → `ghostty_surface_free` 永不调 → 渲染/IO 线程 + **CVDisplayLink（按刷新率空转 = CPU 元凶）** + pty/ssh 全泄漏。
- **诊断技法（hardened-runtime release 包 lldb / Xcode 内存图附不上[无 get-task-allow]、没开 MallocStackLogging 时的杀手锏）**：① `heap <pid> | grep -cE 'Ghostty.SurfaceView$'` 数活实例（**同一条命令里连开多次会冲突读 0 → 要么单次、要么快照到文件再 grep**）；② `leaks <pid>` 不报这些 = 它们「可从根可达」（非孤立环）→ 被全局/静态强引用；③ `leaks <pid> --outputGraph=/tmp/x.memgraph` 导内存图，`heap /tmp/x.memgraph -addresses 'Ghostty.SurfaceView'` 取地址，**`leaks /tmp/x.memgraph --trace=<addr>` = 反向引用树**（顶层=目标，下层=谁引用它，直指 ARC 持有者）。
- **根因（--trace 实测）**：SurfaceView 被 **AppKit 内部块 `-[NSView _commonAwake]_block_invoke`（`__strong [capture]`）+ 通知中心 + 运行中的 CVDisplayLink** 钉住，view 离窗/dealloc 时本该清却没触发；C surface 在 `+74184` 的 nsview 指针是 `Unmanaged.passUnretained`（弱回指，`SurfaceView.swift:withCValue`）被 `leaks` 保守扫描当成引用 → 既盖住真凶、也让 `leaks` 不报泄漏。
- **修复**：`SurfaceView.teardownSurfaceForClose()` 主动撤监听/计时器/订阅、`removeFromSuperview()`、**置空 `surfaceModel`** 确定性触发 `Ghostty.Surface.deinit → ghostty_surface_free`（停线程/CVDisplayLink/pty/ssh，不等迟来的 deinit；幂等）。XGhostty 关 tab 即调（第三十四批）；**主 Ghostty 有 undo-close 不能照搬**——见第三十五批的 undo 感知方案（卡 undo 真过期才拆、⌘Z 撤销不拆）。
- **诊断时务必单实例**：`open DerivedData/…app` 时若 `/Applications` 同 bundle id 实例也被启 / 误点 Dock，两实例打架污染测量（用 `lsof -p <pid> | awk '/txt/&&/MacOS\/ghostty/'` 看真实路径区分；曾靠 `mv /Applications/XGhostty.app .prodbak` 临时挪开生产版才测干净）。`log stream` 的 NSLog 探针可能被 unified log 级别过滤抓不到，**heap 计数才是可靠 oracle**。
