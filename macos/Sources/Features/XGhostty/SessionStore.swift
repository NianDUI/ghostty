#if XGHOSTTY
import Foundation

/// XGhostty 会话树节点。`children != nil` 表示分组，`nil` 表示叶子（主机）。
/// 叶子的 `host == nil` 视为本地 shell（spike 兼容，免 ssh 即可测试）。
struct SessionNode: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var children: [SessionNode]?

    var host: String?
    var port: Int?
    var user: String?
    /// 手动填写的跳板 `[user@]host[:port]`（与 proxyJumpId 二选一，后者优先）。
    var proxyJump: String?
    /// 引用作跳板的已存会话 id（非空=用该主机当跳板，登录时解析成 `[user@]host[:port]`）。
    var proxyJumpId: UUID?
    /// SSH 私钥文件路径（`-i`，可空；空=密码/agent 登录）。仅存路径，不碰 Keychain。
    var identityFile: String?
    /// 引用的密码库凭据 id（可空）。非空=密码取自该凭据；空=用会话内联密码（按 node.id 存保险库）。
    var credentialId: UUID?
    /// 密码登录时是否「仅用密码」（关 pubkey）。nil/false = 自动（先试默认密钥再密码）；true = 仅密码。
    /// 仅对密码登录有意义；密钥登录忽略。向后兼容（旧数据无此字段 → nil = 自动）。
    var passwordOnly: Bool?
    var loginCommands: [String]

    var isGroup: Bool { children != nil }
    var isLocalShell: Bool { !isGroup && (host?.isEmpty ?? true) }

    init(id: UUID = UUID(),
         name: String,
         children: [SessionNode]? = nil,
         host: String? = nil,
         port: Int? = nil,
         user: String? = nil,
         proxyJump: String? = nil,
         proxyJumpId: UUID? = nil,
         identityFile: String? = nil,
         credentialId: UUID? = nil,
         passwordOnly: Bool? = nil,
         loginCommands: [String] = []) {
        self.id = id
        self.name = name
        self.children = children
        self.host = host
        self.port = port
        self.user = user
        self.proxyJump = proxyJump
        self.proxyJumpId = proxyJumpId
        self.identityFile = identityFile
        self.credentialId = credentialId
        self.passwordOnly = passwordOnly
        self.loginCommands = loginCommands
    }
}

/// 快捷命令（底部快捷栏一个按钮）。全局一套（M2 再做组级覆盖）。
struct QuickCommand: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var command: String
    /// 作用范围：nil = 全局（所有会话可见）；非 nil = 仅当前会话属于该分组（含后代子组）时显示。
    /// Optional 向后兼容旧 JSON（缺字段 → nil = 全局）。
    var groupId: UUID?
    init(id: UUID = UUID(), label: String, command: String, groupId: UUID? = nil) {
        self.id = id
        self.label = label
        self.command = command
        self.groupId = groupId
    }
}

/// 持久化文档：会话树 + 快捷命令。
private struct StoreDocument: Codable {
    var sessions: [SessionNode]
    var quickCommands: [QuickCommand]
}

/// 会话树 + 快捷命令的内存模型 + JSON 持久化（~/.config/xghostty/sessions.json，0600）。
final class SessionStore {
    static let shared = SessionStore()

    private(set) var roots: [SessionNode]
    private(set) var quickCommands: [QuickCommand]
    let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("sessions.json")

        if let doc = SessionStore.load(from: fileURL) {
            self.roots = doc.sessions
            self.quickCommands = doc.quickCommands
        } else {
            let seed = SessionStore.seed()
            self.roots = seed.sessions
            self.quickCommands = seed.quickCommands
            save()
        }
    }

    // MARK: 持久化

    private static func load(from url: URL) -> StoreDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let doc = try? JSONDecoder().decode(StoreDocument.self, from: data) {
            return doc
        }
        // 兼容旧格式（纯 sessions 数组）：补上默认快捷命令。
        if let sessions = try? JSONDecoder().decode([SessionNode].self, from: data) {
            return StoreDocument(sessions: sessions, quickCommands: seed().quickCommands)
        }
        return nil
    }

    func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let doc = StoreDocument(sessions: roots, quickCommands: quickCommands)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func replace(roots: [SessionNode]) {
        self.roots = roots
        save()
    }

    /// 整体替换快捷命令（拖拽排序后回写）。
    func setQuickCommands(_ cmds: [QuickCommand]) {
        quickCommands = cmds
        save()
    }

    /// 新增一条快捷命令（追加到末尾）。
    func addQuickCommand(_ c: QuickCommand) {
        quickCommands.append(c)
        save()
    }

    /// 按 id 更新一条快捷命令（编辑保存）。
    func updateQuickCommand(_ c: QuickCommand) {
        guard let i = quickCommands.firstIndex(where: { $0.id == c.id }) else { return }
        quickCommands[i] = c
        save()
    }

    /// 按 id 删除一条快捷命令。
    func removeQuickCommand(_ id: UUID) {
        quickCommands.removeAll { $0.id == id }
        save()
    }

    // MARK: 增删改（递归重建不可变树 + 落盘）

    /// 新增节点。`parentId == nil` 加到根；否则加到指定分组末尾。
    func add(_ node: SessionNode, toParent parentId: UUID?) {
        if let parentId {
            roots = SessionStore.insert(node, into: parentId, nodes: roots)
        } else {
            roots.append(node)
        }
        save()
    }

    /// 按 id 整体替换匹配节点（表单已带回原 id 与 children）。
    func update(_ node: SessionNode) {
        roots = SessionStore.replace(node, in: roots)
        save()
    }

    /// 叶子是否「密码登录」（非密钥）。密钥 = 会话指定 `identityFile`，或引用了密钥库（`isKey`）凭据。
    /// 与 `SessionEditView` 的认证方式判定保持一致。
    static func isPasswordLogin(_ n: SessionNode) -> Bool {
        if n.identityFile != nil { return false }
        if let cid = n.credentialId, CredentialLibrary.shared.find(cid)?.isKey == true { return false }
        return true
    }

    /// 分组（含后代）下「密码登录」叶子数（排除本地 shell / 密钥会话）。批量「仅用密码」前预览用。
    func passwordLoginLeafCount(inGroup groupId: UUID) -> Int {
        guard let g = find(groupId), let c = g.children else { return 0 }
        return SessionStore.leaves(c).filter { !$0.isLocalShell && SessionStore.isPasswordLogin($0) }.count
    }

    /// 分组（含后代）下所有叶子会话的非空 host，按树序（深度优先）一行一个。
    /// 跳过本地 shell / 无 host 的叶子。分组右键「复制全部 IP」用（不去重，一个会话一行）。
    func hosts(inGroup groupId: UUID) -> [String] {
        guard let g = find(groupId), let c = g.children else { return [] }
        return SessionStore.leaves(c).compactMap { leaf in
            guard let host = leaf.host, !host.isEmpty else { return nil }
            return host
        }
    }

    /// 批量把分组（含后代）下所有「密码登录」叶子的 `passwordOnly` 设为 `value`
    /// （`true` = 仅用密码；`nil` = 自动：先试默认密钥再密码）。本地 shell / 密钥会话跳过。
    /// 一次遍历重建树 + 一次落盘。返回实际改动的会话数。
    @discardableResult
    func setPasswordOnly(_ value: Bool?, inGroup groupId: UUID) -> Int {
        var changed = 0
        func transform(_ nodes: [SessionNode]) -> [SessionNode] {
            nodes.map { n in
                var n = n
                if let c = n.children {
                    n.children = transform(c)
                } else if !n.isLocalShell, SessionStore.isPasswordLogin(n) {
                    if n.passwordOnly != value { changed += 1 }
                    n.passwordOnly = value
                }
                return n
            }
        }
        func locate(_ nodes: [SessionNode]) -> [SessionNode] {
            nodes.map { n in
                var n = n
                if n.id == groupId, n.children != nil {
                    n.children = transform(n.children!)
                } else if let c = n.children {
                    n.children = locate(c)
                }
                return n
            }
        }
        roots = locate(roots)
        if changed > 0 { save() }
        return changed
    }

    /// 按 id 删除节点（连带其子树）。
    func remove(_ id: UUID) {
        roots = SessionStore.delete(id, from: roots)
        save()
    }

    /// 移动节点到目标父分组的指定位置（拖拽改层级 / 同级重排）。parentId=nil 移到根；
    /// index=nil 追加末尾。防止把分组移进自己的子树（循环）。
    func move(_ id: UUID, toParent parentId: UUID?, atIndex index: Int? = nil) {
        guard let node = find(id) else { return }
        if let parentId {
            if parentId == id { return }
            if node.isGroup, SessionStore.contains(parentId, inSubtreeOf: node) { return }
        }
        var next = SessionStore.delete(id, from: roots)
        if let parentId {
            next = SessionStore.insert(node, into: parentId, at: index, nodes: next)
        } else if let index, index <= next.count {
            next.insert(node, at: index)
        } else {
            next.append(node)
        }
        roots = next
        save()
    }

    /// 节点在其父分组（或根）children 数组中的下标。
    func indexInParent(of id: UUID) -> Int? {
        let siblings = parentId(of: id).flatMap { find($0)?.children } ?? roots
        return siblings.firstIndex { $0.id == id }
    }

    private static func insert(_ node: SessionNode, into parentId: UUID,
                               nodes: [SessionNode]) -> [SessionNode] {
        nodes.map { n in
            var n = n
            if n.id == parentId, n.children != nil {
                n.children!.append(node)
            } else if let c = n.children {
                n.children = insert(node, into: parentId, nodes: c)
            }
            return n
        }
    }

    private static func replace(_ node: SessionNode,
                                in nodes: [SessionNode]) -> [SessionNode] {
        nodes.map { n in
            if n.id == node.id { return node }
            var n = n
            if let c = n.children { n.children = replace(node, in: c) }
            return n
        }
    }

    private static func delete(_ id: UUID, from nodes: [SessionNode]) -> [SessionNode] {
        nodes.compactMap { n -> SessionNode? in
            if n.id == id { return nil }
            var n = n
            if let c = n.children { n.children = delete(id, from: c) }
            return n
        }
    }

    /// id 是否在 node 子树内（含 node 自身）。防止把分组移进自己子树（循环）。
    private static func contains(_ id: UUID, inSubtreeOf node: SessionNode) -> Bool {
        if node.id == id { return true }
        guard let c = node.children else { return false }
        return c.contains { contains(id, inSubtreeOf: $0) }
    }

    /// insert 的带下标变体（index=nil 或越界则追加末尾）。
    private static func insert(_ node: SessionNode, into parentId: UUID,
                               at index: Int?, nodes: [SessionNode]) -> [SessionNode] {
        nodes.map { n in
            var n = n
            if n.id == parentId, n.children != nil {
                if let index, index <= n.children!.count {
                    n.children!.insert(node, at: index)
                } else {
                    n.children!.append(node)
                }
            } else if let c = n.children {
                n.children = insert(node, into: parentId, at: index, nodes: c)
            }
            return n
        }
    }

    /// 深拷贝并为整棵子树重新生成 id（复制粘贴用，避免与原节点 id 冲突）。
    static func cloneWithNewIds(_ node: SessionNode) -> SessionNode {
        var map: [UUID: UUID] = [:]
        return cloneWithNewIds(node, idMap: &map)
    }

    /// 同上，并回填 `旧id→新id` 映射（用于把 Keychain 密码等附属数据搬到新节点）。
    static func cloneWithNewIds(_ node: SessionNode, idMap: inout [UUID: UUID]) -> SessionNode {
        var copy = node
        let newId = UUID()
        idMap[node.id] = newId
        copy.id = newId
        if let c = node.children { copy.children = c.map { cloneWithNewIds($0, idMap: &idMap) } }
        return copy
    }

    // MARK: 查询

    func find(_ id: UUID) -> SessionNode? { SessionStore.find(id, in: roots) }

    private static func find(_ id: UUID, in nodes: [SessionNode]) -> SessionNode? {
        for n in nodes {
            if n.id == id { return n }
            if let c = n.children, let hit = find(id, in: c) { return hit }
        }
        return nil
    }

    /// 查节点所属的父分组 id（根级节点返回 nil）。复制粘贴「粘为同级」用。
    func parentId(of id: UUID) -> UUID? { SessionStore.parentId(of: id, in: roots, parent: nil) }

    private static func parentId(of id: UUID, in nodes: [SessionNode],
                                 parent: UUID?) -> UUID? {
        for n in nodes {
            if n.id == id { return parent }
            if let c = n.children, let hit = parentId(of: id, in: c, parent: n.id) {
                return hit
            }
        }
        return nil
    }

    var allHosts: [SessionNode] { SessionStore.leaves(roots) }

    private static func leaves(_ nodes: [SessionNode]) -> [SessionNode] {
        nodes.flatMap { node -> [SessionNode] in
            if let c = node.children { return leaves(c) }
            return [node]
        }
    }

    /// 所有引用指定密码库凭据（`credentialId`）的叶子会话，附「分组 › … › 会话名」路径。
    /// 密码库「查看引用 / 删除前确认谁在用」用。
    func sessionsReferencing(credentialId id: UUID) -> [(node: SessionNode, path: String)] {
        var out: [(SessionNode, String)] = []
        func walk(_ nodes: [SessionNode], prefix: [String]) {
            for n in nodes {
                if let c = n.children {
                    walk(c, prefix: prefix + [n.name])
                } else if n.credentialId == id {
                    out.append((n, (prefix + [n.name]).joined(separator: " › ")))
                }
            }
        }
        walk(roots, prefix: [])
        return out
    }

    // MARK: 种子（首次启动）

    private static func seed() -> StoreDocument {
        StoreDocument(
            sessions: [
                SessionNode(name: "示例分组", children: [
                    SessionNode(name: "本机 shell"),
                    SessionNode(name: "示例主机",
                                host: "192.0.2.10", port: 22, user: "root"),
                ])
            ],
            quickCommands: [
                QuickCommand(label: "exit", command: "exit"),
                QuickCommand(label: "df -h", command: "df -h"),
                QuickCommand(label: "ps java", command: "ps aux | grep java"),
                QuickCommand(label: "清屏", command: "clear"),
            ])
    }
}
#endif
