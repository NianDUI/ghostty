#if XGHOSTTY
import Foundation
import CoreGraphics

/// 座舱窗口布局快照：窗口位置/尺寸 + 三条分隔条位置 + 分组展开态。
/// 全部 Optional——缺失即用代码默认（首次启动 / 还原默认布局后）。
struct ConsoleLayout: Codable, Equatable {
    /// 是否在拖动分隔条 / 缩放窗口 / 展开折叠时自动保存布局。
    var autoSave: Bool
    var windowFrame: CGRect?       // 窗口 frame（位置 + 尺寸）
    var treeWidth: CGFloat?        // mainSplit divider：左会话树宽度（从左算）
    var terminalHeight: CGFloat?   // rightSplit divider：终端高度（从顶算）
    var topHeight: CGFloat?        // outerSplit divider：上部高度（从顶算；发送条高 = 总高 - 此值）
    var expandedGroups: [UUID]?    // 已展开的分组 id
    var sortByName: Bool?          // 会话树按名称排序展示（nil/false=按拖拽的自定义顺序）
    /// 折叠分组时是否连同其后代子组一并折叠（nil/false=只折叠本组、子组保持原状，再展开还原）。
    var collapseDescendants: Bool?
    /// 退出应用后是否全部折叠：开启则每次启动忽略已存展开态、全部分组收起（nil/false=按上次状态恢复）。
    var collapseAllOnExit: Bool?
    /// 是否对远端（ssh）会话把终端输出落盘到 ~/.config/xghostty/logs（nil/false=关）。
    var sessionLogging: Bool?
    /// 启动时是否自动恢复上次打开的会话集（nil/false=关，仅默认开第一个会话）。
    var restoreLastSession: Bool?
    /// 上次关闭窗口时打开的会话节点 id（供 restoreLastSession 恢复；仅有 nodeId 的会话）。
    var lastSessionIds: [UUID]?
    /// 密码会话是否启用 expect 式自动登录兜底（nil/false=关）：askpass 未生效、ssh 仍在终端问
    /// 密码时，监听到 `password:` 自动答密码。默认关——正常靠 askpass，本项是少数环境的退路。
    var expectAutoLogin: Bool?
    /// 是否启用 ZMODEM(rz/sz)文件传输（nil/false=关）：远端跑 sz/rz 时桥接本机 lrzsz 自动收发。
    /// 默认关——需本机装 lrzsz，且仅少数场景用；开启后对新打开的 ssh 会话生效。
    var zmodemEnabled: Bool?
    /// 是否启用 trzsz(trz/tsz)文件传输（nil/false=关）：把 ssh 命令包成 `trzsz ssh …`，由本机
    /// trzsz 透明拦截 trz/tsz 协议。默认关——需本机装 trzsz；开启后对新打开的 ssh 会话生效。
    var trzszEnabled: Bool?
    /// 是否对**本地 shell**也启用文件传输（trz/tsz/rz/sz）（nil/false=关）：开启后新开的本地 shell
    /// 用 `trzsz -z -d <登录 shell>` 包裹（装了 trzsz-go）或挂 ZMODEM 兜底（仅 lrzsz），让你在本地
    /// shell 里手动 ssh 进服务器后也能 rz/sz。默认关——且独立于 ssh 会话的文件传输开关：包裹会改用
    /// trzsz 启动本地 shell（丢 Ghostty 原生 shell-integration、起始目录落 ~/Downloads），副作用明确，
    /// 故单设开关、需显式打开。
    var localShellTransferEnabled: Bool?
    /// 终端选中后是否自动复制到剪贴板（nil/false=关）：拖选 / 双击选词 / 三击选行松开鼠标即复制。
    var copyOnSelect: Bool?
    /// 终端复制时是否去掉整段首尾空白（nil/false=关）：cmd+C 与「选中自动复制」都生效。
    var copyTrimWhitespace: Bool?

    init(autoSave: Bool = true,
         windowFrame: CGRect? = nil,
         treeWidth: CGFloat? = nil,
         terminalHeight: CGFloat? = nil,
         topHeight: CGFloat? = nil,
         expandedGroups: [UUID]? = nil,
         sortByName: Bool? = nil,
         collapseDescendants: Bool? = nil,
         collapseAllOnExit: Bool? = nil,
         sessionLogging: Bool? = nil,
         restoreLastSession: Bool? = nil,
         lastSessionIds: [UUID]? = nil,
         expectAutoLogin: Bool? = nil,
         zmodemEnabled: Bool? = nil,
         trzszEnabled: Bool? = nil,
         localShellTransferEnabled: Bool? = nil,
         copyOnSelect: Bool? = nil,
         copyTrimWhitespace: Bool? = nil) {
        self.autoSave = autoSave
        self.windowFrame = windowFrame
        self.treeWidth = treeWidth
        self.terminalHeight = terminalHeight
        self.topHeight = topHeight
        self.expandedGroups = expandedGroups
        self.sortByName = sortByName
        self.collapseDescendants = collapseDescendants
        self.collapseAllOnExit = collapseAllOnExit
        self.sessionLogging = sessionLogging
        self.restoreLastSession = restoreLastSession
        self.lastSessionIds = lastSessionIds
        self.expectAutoLogin = expectAutoLogin
        self.zmodemEnabled = zmodemEnabled
        self.trzszEnabled = trzszEnabled
        self.localShellTransferEnabled = localShellTransferEnabled
        self.copyOnSelect = copyOnSelect
        self.copyTrimWhitespace = copyTrimWhitespace
    }
}

/// 布局持久化（~/.config/xghostty/layout.json，0600）。全局一份，多窗口最后交互者写入。
final class LayoutStore {
    static let shared = LayoutStore()

    private(set) var layout: ConsoleLayout
    let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty", isDirectory: true)
        fileURL = dir.appendingPathComponent("layout.json")
        if let data = try? Data(contentsOf: fileURL),
           let l = try? JSONDecoder().decode(ConsoleLayout.self, from: data) {
            layout = l
        } else {
            layout = ConsoleLayout()
        }
    }

    func save(_ l: ConsoleLayout) {
        layout = l
        persist()
    }

    /// 仅改 autoSave 开关（其余布局保留）。
    func setAutoSave(_ on: Bool) {
        layout.autoSave = on
        persist()
    }

    /// 仅改「按名称排序」偏好。
    func setSortByName(_ on: Bool) {
        layout.sortByName = on
        persist()
    }

    /// 仅改「折叠时连同子组一起折叠」偏好。
    func setCollapseDescendants(_ on: Bool) {
        layout.collapseDescendants = on
        persist()
    }

    /// 仅改「退出后全部折叠」偏好。
    func setCollapseAllOnExit(_ on: Bool) {
        layout.collapseAllOnExit = on
        persist()
    }

    /// 仅改「会话日志落盘」偏好。
    func setSessionLogging(_ on: Bool) {
        layout.sessionLogging = on
        persist()
    }

    /// 仅改「启动恢复上次会话」偏好。
    func setRestoreLastSession(_ on: Bool) {
        layout.restoreLastSession = on
        persist()
    }

    /// 仅改「expect 自动登录兜底」偏好。
    func setExpectAutoLogin(_ on: Bool) {
        layout.expectAutoLogin = on
        persist()
    }

    /// 仅改「ZMODEM 文件传输」偏好。
    func setZmodemEnabled(_ on: Bool) {
        layout.zmodemEnabled = on
        persist()
    }

    /// 仅改「trzsz 文件传输」偏好。
    func setTrzszEnabled(_ on: Bool) {
        layout.trzszEnabled = on
        persist()
    }

    /// 仅改「本地 shell 文件传输」偏好。
    func setLocalShellTransferEnabled(_ on: Bool) {
        layout.localShellTransferEnabled = on
        persist()
    }

    /// 仅改「选中自动复制」偏好。
    func setCopyOnSelect(_ on: Bool) {
        layout.copyOnSelect = on
        persist()
    }

    /// 仅改「复制去首尾空白」偏好。
    func setCopyTrimWhitespace(_ on: Bool) {
        layout.copyTrimWhitespace = on
        persist()
    }

    /// 记录上次打开的会话集（关窗口时调用，供下次启动恢复）。
    func setLastSessionIds(_ ids: [UUID]) {
        layout.lastSessionIds = ids
        persist()
    }

    /// 清空布局字段（保留偏好开关 + 上次会话），用于「还原默认布局」。
    func resetLayout() {
        layout = ConsoleLayout(autoSave: layout.autoSave, sortByName: layout.sortByName,
                               collapseDescendants: layout.collapseDescendants,
                               collapseAllOnExit: layout.collapseAllOnExit,
                               sessionLogging: layout.sessionLogging,
                               restoreLastSession: layout.restoreLastSession,
                               lastSessionIds: layout.lastSessionIds,
                               expectAutoLogin: layout.expectAutoLogin,
                               zmodemEnabled: layout.zmodemEnabled,
                               trzszEnabled: layout.trzszEnabled,
                               localShellTransferEnabled: layout.localShellTransferEnabled,
                               copyOnSelect: layout.copyOnSelect,
                               copyTrimWhitespace: layout.copyTrimWhitespace)
        persist()
    }

    /// 偏好开关的出厂默认（即「还原默认设置」恢复到的那套）。窗口布局/分隔条/展开态/上次会话不在此列。
    enum Defaults {
        static let autoSave = true
        static let sortByName = false
        static let collapseDescendants = true
        static let collapseAllOnExit = false
        static let sessionLogging = false
        static let restoreLastSession = false
        static let expectAutoLogin = false
        static let zmodemEnabled = true
        static let trzszEnabled = true
        static let localShellTransferEnabled = true
        static let copyOnSelect = false
        static let copyTrimWhitespace = true
    }

    /// 「还原默认设置」：把所有偏好开关写回出厂默认（保留窗口布局/分隔条/展开态/上次会话——那归 resetLayout）。
    /// 显式写值（而非置 nil）：功能侧多处用 `== true` 判定，写显式 true 才能让 trzsz 等立即生效。
    /// selection-word-chars 存独立的 ghostty.config，由 XGhosttyConsole 在还原时一并写回，不在此处理。
    func resetPreferences() {
        layout.autoSave = Defaults.autoSave
        layout.sortByName = Defaults.sortByName
        layout.collapseDescendants = Defaults.collapseDescendants
        layout.collapseAllOnExit = Defaults.collapseAllOnExit
        layout.sessionLogging = Defaults.sessionLogging
        layout.restoreLastSession = Defaults.restoreLastSession
        layout.expectAutoLogin = Defaults.expectAutoLogin
        layout.zmodemEnabled = Defaults.zmodemEnabled
        layout.trzszEnabled = Defaults.trzszEnabled
        layout.localShellTransferEnabled = Defaults.localShellTransferEnabled
        layout.copyOnSelect = Defaults.copyOnSelect
        layout.copyTrimWhitespace = Defaults.copyTrimWhitespace
        persist()
    }

    private func persist() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(layout) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
#endif
