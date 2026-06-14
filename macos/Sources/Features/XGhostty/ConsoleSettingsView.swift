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
    var onToggleAutoSave: (Bool) -> Void
    var onToggleSort: (Bool) -> Void
    var onToggleCollapseDescendants: (Bool) -> Void
    var onToggleCollapseAllOnExit: (Bool) -> Void
    var onToggleSessionLogging: (Bool) -> Void
    var onToggleRestoreLastSession: (Bool) -> Void
    var onToggleExpectAutoLogin: (Bool) -> Void
    var onToggleZmodem: (Bool) -> Void
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
         onToggleAutoSave: @escaping (Bool) -> Void,
         onToggleSort: @escaping (Bool) -> Void,
         onToggleCollapseDescendants: @escaping (Bool) -> Void,
         onToggleCollapseAllOnExit: @escaping (Bool) -> Void,
         onToggleSessionLogging: @escaping (Bool) -> Void,
         onToggleRestoreLastSession: @escaping (Bool) -> Void,
         onToggleExpectAutoLogin: @escaping (Bool) -> Void,
         onToggleZmodem: @escaping (Bool) -> Void,
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
        self.onToggleAutoSave = onToggleAutoSave
        self.onToggleSort = onToggleSort
        self.onToggleCollapseDescendants = onToggleCollapseDescendants
        self.onToggleCollapseAllOnExit = onToggleCollapseAllOnExit
        self.onToggleSessionLogging = onToggleSessionLogging
        self.onToggleRestoreLastSession = onToggleRestoreLastSession
        self.onToggleExpectAutoLogin = onToggleExpectAutoLogin
        self.onToggleZmodem = onToggleZmodem
        self.onViewLogs = onViewLogs
        self.onResetLayout = onResetLayout
        self.onClose = onClose
    }

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
                Toggle("ZMODEM 文件传输（rz/sz）", isOn: $zmodemEnabled)
                    .onChange(of: zmodemEnabled) { onToggleZmodem($0) }
                Text("开启后，在 ssh 会话里跑远端的 sz（下载到 ~/Downloads）/ rz（上传，弹框选文件）会自动桥接本机 lrzsz 完成传输。需先 brew install lrzsz。传输时屏幕会被「传输中」浮层遮住（底层是无法屏蔽的 ZMODEM 原始字节）。仅对新打开的 ssh 会话生效。")
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
                Text("若每次启动都弹「XGhostty 想访问你的钥匙串」框：点这里在当前签名下重建密码保险库的授权（删项重建），之后同一证书签名的构建读取保险库不再弹框。会先读一次现有密码（旧授权仍脏时可能弹最后一次，点「始终允许」放行）。")
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
