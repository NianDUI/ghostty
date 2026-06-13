#if XGHOSTTY
import Foundation
import Combine

/// 凭据类型：密码 / 密钥。
enum CredentialKind: String, Codable {
    case password
    case key
}

/// 一条具名凭据：名称 + 用户名（可选，标识/区分用）+ 秘密。
/// - 密码凭据：秘密 = 登录密码，进保险库 Keychain（account = 凭据 id）。
/// - 密钥凭据：私钥**路径** `keyPath`（明文存元数据，`ssh -i`）+ 秘密 = 可选 passphrase（进保险库）。
/// 秘密统一存 `XGhosttyCredentialStore`（account = 凭据 id），**不入此元数据文件**。
struct Credential: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var username: String?
    /// nil/`.password` = 密码凭据（向后兼容旧 JSON，旧条目无此字段）；`.key` = 密钥凭据。
    var kind: CredentialKind?
    /// 密钥凭据的私钥文件路径（存 `~` 缩写）；密码凭据为 nil。
    var keyPath: String?

    var isKey: Bool { kind == .key }

    init(id: UUID = UUID(), name: String, username: String? = nil,
         kind: CredentialKind? = nil, keyPath: String? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.kind = kind
        self.keyPath = keyPath
    }
}

/// 密码库：具名凭据的元数据（名称/用户名）持久化到 `~/.config/xghostty/credentials.json`（0600）；
/// 密码本身存进 `XGhosttyCredentialStore` 保险库（与会话内联密码同库、UUID 不撞）。
///
/// 会话可引用一条凭据（`SessionNode.credentialId`）共用密码——多台机改一处全生效。
final class CredentialLibrary: ObservableObject {
    static let shared = CredentialLibrary()

    /// `@Published` → 视图（`@ObservedObject`）直接观察，增删改后自动刷新，
    /// 不再依赖 `@State` 快照 + `.onAppear`（曾导致首次打开列表为空）。
    @Published private(set) var credentials: [Credential]
    let fileURL: URL

    init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/credentials.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Credential].self, from: data) {
            credentials = list
        } else {
            credentials = []
        }
    }

    func find(_ id: UUID) -> Credential? { credentials.first { $0.id == id } }

    /// 新增 / 更新凭据。`password` = 该凭据的秘密（密码凭据=密码，密钥凭据=passphrase）：
    /// 非空才写保险库；nil/空 = 不动已存秘密（编辑时保留）。keyPath 等元数据随结构落盘。
    func upsert(_ cred: Credential, password: String?) {
        if let i = credentials.firstIndex(where: { $0.id == cred.id }) {
            credentials[i] = cred
        } else {
            credentials.append(cred)
        }
        if let password, !password.isEmpty {
            XGhosttyCredentialStore.shared.setPassword(password, for: cred.id)
        }
        save()
    }

    /// 删除凭据连同其保险库密码。引用它的会话会自然降级为「无存储密码」（交互登录）。
    func remove(_ id: UUID) {
        credentials.removeAll { $0.id == id }
        XGhosttyCredentialStore.shared.removePassword(for: id)
        save()
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(credentials) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
#endif
