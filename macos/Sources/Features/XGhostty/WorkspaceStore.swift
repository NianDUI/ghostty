#if XGHOSTTY
import Foundation
import Combine

/// 一个「工作区」= 一组会话的命名集合（按打开顺序存会话节点 id）。
/// 运维每天开固定一批生产机：存一次，以后一键全开。
struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 引用 `SessionNode.id`（按 tab 打开顺序）；打开时已删的节点跳过、重复的各开一个（保真）。
    var sessionIds: [UUID]

    init(id: UUID = UUID(), name: String, sessionIds: [UUID]) {
        self.id = id
        self.name = name
        self.sessionIds = sessionIds
    }
}

/// 工作区清单：持久化 `~/.config/xghostty/workspaces.json`（0600）。全局一份。
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [Workspace]
    let fileURL: URL

    init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/workspaces.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = list
        } else {
            workspaces = []
        }
    }

    func find(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    func add(_ w: Workspace) { workspaces.append(w); save() }

    func remove(_ id: UUID) { workspaces.removeAll { $0.id == id }; save() }

    func rename(_ id: UUID, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = name
        save()
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(workspaces) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
#endif
