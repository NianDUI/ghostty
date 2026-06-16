#if XGHOSTTY
import SwiftUI

/// 座舱设置面板（⌘, 打开的 sheet）。当前含布局自动保存开关 + 还原默认布局。
/// 风格与 `SessionEditView` 一致（手工 VStack + 透明背景透出座舱 sheet 底色）。
struct ConsoleSettingsView: View {
    @State private var autoSave: Bool
    @State private var sortByName: Bool
    @State private var collapseDescendants: Bool
    @State private var collapseAllOnExit: Bool
    @State private var sessionLogging: Bool
    @State private var restoreLastSession: Bool
    @State private var expectAutoLogin: Bool
    @State private var zmodemEnabled: Bool
    @State private var trzszEnabled: Bool
    @State private var localShellTransfer: Bool
    @State private var copyOnSelect: Bool
    @State private var copyTrimWhitespace: Bool
    @State private var selectionWordChars: String
    var onToggleAutoSave: (Bool) -> Void
    var onToggleSort: (Bool) -> Void
    var onToggleCollapseDescendants: (Bool) -> Void
    var onToggleCollapseAllOnExit: (Bool) -> Void
    var onToggleSessionLogging: (Bool) -> Void
    var onToggleRestoreLastSession: (Bool) -> Void
    var onToggleExpectAutoLogin: (Bool) -> Void
    var onToggleZmodem: (Bool) -> Void
    var onToggleTrzsz: (Bool) -> Void
    var onToggleLocalShellTransfer: (Bool) -> Void
    var onToggleCopyOnSelect: (Bool) -> Void
    var onToggleCopyTrimWhitespace: (Bool) -> Void
    var onCommitSelectionWordChars: (String) -> Void
    var onViewLogs: () -> Void
    var onResetLayout: () -> Void
    var onClose: () -> Void

    init(autoSave: Bool,
         sortByName: Bool,
         collapseDescendants: Bool,
         collapseAllOnExit: Bool,
         sessionLogging: Bool,
         restoreLastSession: Bool,
         expectAutoLogin: Bool,
         zmodemEnabled: Bool,
         trzszEnabled: Bool,
         localShellTransfer: Bool,
         copyOnSelect: Bool,
         copyTrimWhitespace: Bool,
         selectionWordChars: String,
         onToggleAutoSave: @escaping (Bool) -> Void,
         onToggleSort: @escaping (Bool) -> Void,
         onToggleCollapseDescendants: @escaping (Bool) -> Void,
         onToggleCollapseAllOnExit: @escaping (Bool) -> Void,
         onToggleSessionLogging: @escaping (Bool) -> Void,
         onToggleRestoreLastSession: @escaping (Bool) -> Void,
         onToggleExpectAutoLogin: @escaping (Bool) -> Void,
         onToggleZmodem: @escaping (Bool) -> Void,
         onToggleTrzsz: @escaping (Bool) -> Void,
         onToggleLocalShellTransfer: @escaping (Bool) -> Void,
         onToggleCopyOnSelect: @escaping (Bool) -> Void,
         onToggleCopyTrimWhitespace: @escaping (Bool) -> Void,
         onCommitSelectionWordChars: @escaping (String) -> Void,
         onViewLogs: @escaping () -> Void,
         onResetLayout: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        _autoSave = State(initialValue: autoSave)
        _sortByName = State(initialValue: sortByName)
        _collapseDescendants = State(initialValue: collapseDescendants)
        _collapseAllOnExit = State(initialValue: collapseAllOnExit)
        _sessionLogging = State(initialValue: sessionLogging)
        _restoreLastSession = State(initialValue: restoreLastSession)
        _expectAutoLogin = State(initialValue: expectAutoLogin)
        _zmodemEnabled = State(initialValue: zmodemEnabled)
        _trzszEnabled = State(initialValue: trzszEnabled)
        _localShellTransfer = State(initialValue: localShellTransfer)
        _copyOnSelect = State(initialValue: copyOnSelect)
        _copyTrimWhitespace = State(initialValue: copyTrimWhitespace)
        _selectionWordChars = State(initialValue: selectionWordChars)
        self.onToggleAutoSave = onToggleAutoSave
        self.onToggleSort = onToggleSort
        self.onToggleCollapseDescendants = onToggleCollapseDescendants
        self.onToggleCollapseAllOnExit = onToggleCollapseAllOnExit
        self.onToggleSessionLogging = onToggleSessionLogging
        self.onToggleRestoreLastSession = onToggleRestoreLastSession
        self.onToggleExpectAutoLogin = onToggleExpectAutoLogin
        self.onToggleZmodem = onToggleZmodem
        self.onToggleTrzsz = onToggleTrzsz
        self.onToggleLocalShellTransfer = onToggleLocalShellTransfer
        self.onToggleCopyOnSelect = onToggleCopyOnSelect
        self.onToggleCopyTrimWhitespace = onToggleCopyTrimWhitespace
        self.onCommitSelectionWordChars = onCommitSelectionWordChars
        self.onViewLogs = onViewLogs
        self.onResetLayout = onResetLayout
        self.onClose = onClose
    }

    /// 「填推荐值」按钮预填：ghostty 默认边界集 + 波浪号 ~ + 常见全角标点（config 字符串语法，原样写文件）。
    static let recommendedWordChars = #"\t '\"│`|:;,()[]{}<>$~：，。；！？"#

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("座舱设置").font(.headline)

            // 内容多、面板会超屏 → 套固定高度 ScrollView，标题与底部「取消/完成」常驻可见。
            // 自适应 sheet 里的 ScrollView 必须给确定高度，否则塌成 0（见密码库那次坑）。
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("自动保存窗口布局", isOn: $autoSave)
                    .onChange(of: autoSave) { onToggleAutoSave($0) }
                Text("记住左树宽度、终端 / 快捷条 / 发送条分隔条位置、窗口尺寸与分组展开态，下次启动自动还原。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("会话树按名称排序", isOn: $sortByName)
                    .onChange(of: sortByName) { onToggleSort($0) }
                Text("开启后会话树按名称展示；关闭则按你拖拽的自定义顺序。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("折叠分组时同时折叠其子分组", isOn: $collapseDescendants)
                    .onChange(of: collapseDescendants) { onToggleCollapseDescendants($0) }
                Text("开启后折叠一个分组会连同它下面所有子分组一起收起，再展开时子分组也是收起的；关闭则只折叠本组、子分组保持原展开状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("退出应用后全部折叠", isOn: $collapseAllOnExit)
                    .onChange(of: collapseAllOnExit) { onToggleCollapseAllOnExit($0) }
                Text("开启后每次启动座舱时全部分组收起，不恢复上次的展开状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("启动时恢复上次打开的会话", isOn: $restoreLastSession)
                    .onChange(of: restoreLastSession) { onToggleRestoreLastSession($0) }
                Text("开启后，下次启动座舱自动重新打开上次关闭时的会话集（ssh 会话会重新登录）；关闭则只默认打开第一个会话。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("记录会话日志（ssh 输出落盘）", isOn: $sessionLogging)
                    .onChange(of: sessionLogging) { onToggleSessionLogging($0) }
                Text("开启后，之后打开的 ssh 会话会把终端输出（含控制序列）追加到 ~/.config/xghostty/logs/。仅对新打开的会话生效；可与 ⌃⇧S 会话共享同时开（输出经分发器多路转发）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("查看会话日志…") { onViewLogs() }
                    Button("打开日志目录") { openLogsDir() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("SSH 自动登录兜底（expect）", isOn: $expectAutoLogin)
                    .onChange(of: expectAutoLogin) { onToggleExpectAutoLogin($0) }
                Text("正常用 SSH_ASKPASS 注入密码、终端不会出现密码提示。少数服务器的 ssh 不认 askpass、仍在终端问密码时，开启本项会在登录阶段监听到「password:」后自动答密码（登录成功 / 45 秒后即停，避免误答 sudo 等提示）。仅对新打开的密码会话生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("文件传输（trz/tsz/rz/sz · 推荐）", isOn: $trzszEnabled)
                    .onChange(of: trzszEnabled) { onToggleTrzsz($0) }
                Text("开启后新打开的 ssh 会话用 trzsz-go 透明包裹（trzsz -z -d ssh …）：远端跑 trz/tsz **和** rz/sz 都由本机 trzsz 原生处理——进度条、总大小、无乱码、拖文件上传全都有，最可靠。需先 brew install trzsz-go。下载落到 ~/Downloads。**这一个就够了**，强烈推荐只用它。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("ZMODEM 兜底（仅未装 trzsz-go 时）", isOn: $zmodemEnabled)
                    .onChange(of: zmodemEnabled) { onToggleZmodem($0) }
                Text("仅当本机**没装 trzsz-go**、又想要 rz/sz 时才开：用内置伪终端桥接本机 lrzsz（需 brew install lrzsz）。可靠性不如上面的 trzsz，传输中可按 Esc 取消。装了 trzsz-go 的话开上面那个即可，本项无需开。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("本地 shell 文件传输（手动 ssh 后 rz/sz）", isOn: $localShellTransfer)
                    .onChange(of: localShellTransfer) { onToggleLocalShellTransfer($0) }
                Text("默认关。开启后新开的「本地 shell」标签会被 trzsz-go 包裹（装了就走 `trzsz -z -d <登录 shell>`，trz/tsz + rz/sz 全协议；没装则挂 ZMODEM 兜底，仅 rz/sz）——这样你在本地 shell 里**手动 ssh** 进服务器后，远端的 rz/sz · trz/tsz 也能用。代价：包裹会改用 trzsz 启动本地 shell，丢 Ghostty 原生 shell-integration、起始目录落 ~/Downloads，故独立于上面两个会话开关、需单独打开。配置好的 SSH 会话仍用上面两个开关。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("选中自动复制", isOn: $copyOnSelect)
                    .onChange(of: copyOnSelect) { onToggleCopyOnSelect($0) }
                Text("默认关。在终端里拖选 / 双击选词 / 三击选行后松开鼠标即把选中内容复制到剪贴板（无需 cmd+C）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("复制时去掉首尾空白", isOn: $copyTrimWhitespace)
                    .onChange(of: copyTrimWhitespace) { onToggleCopyTrimWhitespace($0) }
                Text("默认关。复制（cmd+C 或「选中自动复制」）时去掉整段内容开头和结尾的空格 / 换行——避免选区多带的首尾空白进剪贴板。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("双击选词边界字符（selection-word-chars · 仅 XGhostty）")
                    .font(.system(size: 13, weight: .medium))
                HStack {
                    TextField("留空 = Ghostty 默认", text: $selectionWordChars)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onCommitSelectionWordChars(selectionWordChars) }
                    Button("应用") { onCommitSelectionWordChars(selectionWordChars) }
                    Button("填推荐值") {
                        selectionWordChars = Self.recommendedWordChars
                        onCommitSelectionWordChars(selectionWordChars)
                    }
                }
                Text("双击选词遇到这些字符就停，仅 XGhostty 生效。回车或「应用」写入 ~/.config/xghostty/ghostty.config 并自动 reload，不影响主 Ghostty。内容是 ghostty config 字符串语法（\\t=制表符等）。不熟就点「填推荐值」——默认集 + 波浪号 ~ + 全角标点，让 ID~字段、中文冒号也断词。留空 = 用 Ghostty 默认。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button("还原默认布局") { onResetLayout() }
                Text("把分隔条、窗口尺寸、分组展开态恢复到初始状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("修复钥匙串授权") { repairKeychain() }
                Text("把密码保险库的钥匙串授权重置到当前构建（清理 ad-hoc 时代遗留的旧授权）。注意：自签证书下每次「重新构建」二进制哈希都会变，仍会重新弹一次授权框——这是固有限制，重建后点一次「始终允许」即可；单纯重开同一版不弹。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("查看广播审计日志") { openAuditLog() }
                Text("批量发送条向「全部 / 分组」群发的命令会留痕到 broadcast-audit.log（JSON Lines），可追溯哪条命令打到了哪些机器。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
              }                       // 关 ScrollView 内 VStack
            }                         // 关 ScrollView
            .frame(height: 440)       // 确定高度：内容超出则滚动，标题/按钮常驻不被挤出屏

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// 打开会话日志目录（不存在则先建一个空目录再打开）。
    private func openLogsDir() {
        let dir = SessionLogStore.shared.dir
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(dir)
    }

    /// 在当前签名下重建保险库钥匙串项的 ACL（治"每次启动弹授权框"），弹结果反馈。
    private func repairKeychain() {
        let result = XGhosttyCredentialStore.shared.repairKeychainACL()
        let alert = NSAlert()
        if result.ok {
            alert.messageText = "已修复钥匙串授权"
            alert.informativeText = "已在当前签名下重建密码保险库（含 \(result.count) 条密码）。"
                + "之后同一证书签名的构建读取保险库不再弹授权框。"
        } else {
            alert.messageText = "修复未完成"
            alert.informativeText = "读取或写回保险库失败。若刚才的授权框点了「拒绝」，请重试并点「始终允许」。"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 在 Finder 中定位审计日志文件（让用户自选用什么打开）；还没有记录则提示。
    private func openAuditLog() {
        let url = BroadcastAuditLog.shared.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let alert = NSAlert()
            alert.messageText = "还没有广播记录"
            alert.informativeText = "向「全部」或某个分组群发命令后，这里会生成审计日志。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
#endif
