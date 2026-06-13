#if XGHOSTTY
import Foundation
import Combine

/// 一台跳板机（堡垒机）：名称 + host + 可选 user/port。会话经它 `ssh -J` 跳。
/// 单独成清单管理（不混进几百台业务会话里），多台会话引用同一条、改一处全生效。
/// 跳板自身的认证走 OpenSSH 默认（你的 `~/.ssh` 默认密钥 / agent / `~/.ssh/config`）。
struct JumpHost: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var user: String?
    var port: Int?
    /// 跳板自身的登录凭据（引用密码库；密码或密钥）。nil=用 ~/.ssh 默认密钥。
    var credentialId: UUID?

    init(id: UUID = UUID(), name: String, host: String,
         user: String? = nil, port: Int? = nil, credentialId: UUID? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.credentialId = credentialId
    }

    /// 友好展示：`[user@]host[:port]`。
    var endpointDisplay: String {
        var s = ""
        if let user, !user.isEmpty { s += "\(user)@" }
        s += host
        if let port { s += ":\(port)" }
        return s
    }
}

/// 跳板机清单：持久化到 `~/.config/xghostty/jumphosts.json`（0600）。全局一份。
/// 会话 `SessionNode.proxyJumpId` 引用此清单条目（登录时解析成 `-J [user@]host[:port]`）。
final class JumpHostStore: ObservableObject {
    static let shared = JumpHostStore()

    @Published private(set) var hosts: [JumpHost]
    let fileURL: URL

    init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/jumphosts.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([JumpHost].self, from: data) {
            hosts = list
        } else {
            hosts = []
        }
    }

    func find(_ id: UUID) -> JumpHost? { hosts.first { $0.id == id } }

    /// 新增 / 更新。
    func upsert(_ h: JumpHost) {
        if let i = hosts.firstIndex(where: { $0.id == h.id }) {
            hosts[i] = h
        } else {
            hosts.append(h)
        }
        save()
    }

    /// 删除。引用它的会话会失去跳板（直连），登录时解析不到即跳过 `-J`。
    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
#endif
