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
         zmodemEnabled: Bool? = nil) {
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
                               zmodemEnabled: layout.zmodemEnabled)
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
