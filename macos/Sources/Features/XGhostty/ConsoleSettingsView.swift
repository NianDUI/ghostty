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
    var onToggleAutoSave: (Bool) -> Void
    var onToggleSort: (Bool) -> Void
    var onToggleCollapseDescendants: (Bool) -> Void
    var onToggleCollapseAllOnExit: (Bool) -> Void
    var onToggleSessionLogging: (Bool) -> Void
    var onToggleRestoreLastSession: (Bool) -> Void
    var onViewLogs: () -> Void
    var onResetLayout: () -> Void
    var onClose: () -> Void

    init(autoSave: Bool,
         sortByName: Bool,
         collapseDescendants: Bool,
         collapseAllOnExit: Bool,
         sessionLogging: Bool,
         restoreLastSession: Bool,
         onToggleAutoSave: @escaping (Bool) -> Void,
         onToggleSort: @escaping (Bool) -> Void,
         onToggleCollapseDescendants: @escaping (Bool) -> Void,
         onToggleCollapseAllOnExit: @escaping (Bool) -> Void,
         onToggleSessionLogging: @escaping (Bool) -> Void,
         onToggleRestoreLastSession: @escaping (Bool) -> Void,
         onViewLogs: @escaping () -> Void,
         onResetLayout: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        _autoSave = State(initialValue: autoSave)
        _sortByName = State(initialValue: sortByName)
        _collapseDescendants = State(initialValue: collapseDescendants)
        _collapseAllOnExit = State(initialValue: collapseAllOnExit)
        _sessionLogging = State(initialValue: sessionLogging)
        _restoreLastSession = State(initialValue: restoreLastSession)
        self.onToggleAutoSave = onToggleAutoSave
        self.onToggleSort = onToggleSort
        self.onToggleCollapseDescendants = onToggleCollapseDescendants
        self.onToggleCollapseAllOnExit = onToggleCollapseAllOnExit
        self.onToggleSessionLogging = onToggleSessionLogging
        self.onToggleRestoreLastSession = onToggleRestoreLastSession
        self.onViewLogs = onViewLogs
        self.onResetLayout = onResetLayout
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("座舱设置").font(.headline)

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
                Text("开启后，之后打开的 ssh 会话会把终端输出（含控制序列）追加到 ~/.config/xghostty/logs/。仅对新打开的会话生效；与 ⌃⇧S 会话共享互斥（同一会话别同时用）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("查看会话日志…") { onViewLogs() }
                    Button("打开日志目录") { openLogsDir() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button("还原默认布局") { onResetLayout() }
                Text("把分隔条、窗口尺寸、分组展开态恢复到初始状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("查看广播审计日志") { openAuditLog() }
                Text("批量发送条向「全部 / 分组」群发的命令会留痕到 broadcast-audit.log（JSON Lines），可追溯哪条命令打到了哪些机器。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
