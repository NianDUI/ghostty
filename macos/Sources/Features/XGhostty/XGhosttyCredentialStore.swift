#if XGHOSTTY
import Foundation
import Security

/// XGhostty SSH 密码存储：单一 Keychain「保险库」+ 内存缓存 + 明文索引。
///
/// **为什么单一 item**：密码若各占一个 Keychain item，各自独立 ACL → 每台会话首次读都单独
/// 弹一次授权框（用户反馈「不同会话反复输密码」）。改成所有密码塞进一个 item
/// （account=`vault`，值=JSON `[id: 密码]`）：一次「始终允许」即覆盖全部，且首次读后常驻内存
/// 缓存 → 每次启动至多弹一次（ad-hoc 签名下重建会重弹一次，由自签证书签名根治）。
///
/// **明文索引**（`~/.config/xghostty/.cred-index.json`，只存"哪些 id 有密码"，无密文）：
/// 让 `hasPassword`（编辑表单显"已保存"用）不必读 Keychain、不弹框。
///
/// **懒迁移**：历史的逐会话 item（旧 service `…ssh`）在首次被读到时迁进保险库并删除旧项。
///
/// 密码绝不进 sessions.json。
final class XGhosttyCredentialStore {
    static let shared = XGhosttyCredentialStore()

    private let service = "top.niandui.xghostty"
    private let account = "vault"
    private let legacyService = "top.niandui.xghostty.ssh"   // 旧逐会话 item
    private let indexURL: URL

    private var cache: [String: String]?     // nil=未从 Keychain 载入；非 nil=已载入（含空）
    private var index: Set<String>           // 有密码的 id（明文，hasPassword 用）

    private init() {
        indexURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/.cred-index.json")
        index = Self.loadIndex(indexURL)
        // 把旧逐会话 item 的 account 列表并进索引（只读属性、不读密文 → 不弹框），
        // 使 hasPassword 对历史密码也准确；真正迁移在 password(for:) 懒触发。
        index.formUnion(Self.legacyAccounts(service: legacyService))
        saveIndex()
    }

    // MARK: 读

    /// 读取会话密码（首次触发一次 Keychain 授权，之后走内存缓存）。无则 nil。
    func password(for id: UUID) -> String? {
        let key = id.uuidString
        ensureLoaded()
        if let pw = cache?[key] { return pw }
        // 懒迁移：旧逐会话 item → 保险库，迁完删旧项。
        if let pw = Self.readLegacy(service: legacyService, account: key) {
            cache?[key] = pw
            persistVault()
            Self.deleteLegacy(service: legacyService, account: key)
            return pw
        }
        return nil
    }

    /// 仅查存在性：走明文索引，不碰 Keychain → 不弹授权框。
    func hasPassword(for id: UUID) -> Bool { index.contains(id.uuidString) }

    // MARK: 修复钥匙串授权（治"每次启动都弹授权框"）

    /// 在**当前签名身份**下重建保险库项的 ACL：删旧项 → 用内存里的密码重新 `SecItemAdd`。
    ///
    /// **病根**：保险库项最早可能是 **ad-hoc 签名时代**创建的，其 ACL 信任的是当时的 cdhash；换成
    /// 自签证书后身份对不上 → 每次启动读保险库都弹「XGhostty 想访问钥匙串」。重复证书又让
    /// 「始终允许」追加的授权粘不稳。**删项重建**让新项的默认 ACL 只信任**创建它的本 app**——而本
    /// app 的指定要求是 cert-leaf（跨重建稳定），故此后同证书签名的构建读取保险库**根本不弹框**。
    ///
    /// 返回 (修复成功, 迁移的密码条数)。`ensureLoaded` 那一步若旧 ACL 仍脏会弹**最后一次**授权框
    /// （点「始终允许」放行即可），之后永不再弹。
    @discardableResult
    func repairKeychainACL() -> (ok: Bool, count: Int) {
        ensureLoaded()                       // 读出现有密码进内存（启动时多半已载入；脏 ACL 在此弹最后一次）
        guard let snapshot = cache else { return (false, 0) }
        Self.deleteVault(service: service, account: account)   // 连同脏 ACL 删掉旧项
        cache = snapshot                     // 用内存快照重建（writeVault 找不到项→走 SecItemAdd 新建干净 ACL）
        return (persistVault(), snapshot.count)
    }

    // MARK: 写

    /// 写入/更新会话密码。
    @discardableResult
    func setPassword(_ password: String, for id: UUID) -> Bool {
        ensureLoaded()
        cache?[id.uuidString] = password
        index.insert(id.uuidString)
        saveIndex()
        return persistVault()
    }

    /// 删除会话密码（清空字段 / 切密钥 / 删会话时调用）。
    @discardableResult
    func removePassword(for id: UUID) -> Bool {
        let key = id.uuidString
        index.remove(key)
        saveIndex()
        Self.deleteLegacy(service: legacyService, account: key)   // 旧逐会话残留（若有）
        ensureLoaded()
        guard cache?[key] != nil else { return true }
        cache?[key] = nil
        return persistVault()
    }

    // MARK: 保险库（Keychain 单 item） + 缓存

    private func ensureLoaded() {
        if cache != nil { return }
        cache = Self.readVault(service: service, account: account) ?? [:]
    }

    @discardableResult
    private func persistVault() -> Bool {
        guard let cache else { return false }
        return Self.writeVault(service: service, account: account, dict: cache)
    }

    // MARK: Keychain 原语

    private static func readVault(service: String, account: String) -> [String: String]? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict
    }

    private static func writeVault(service: String, account: String, dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update != errSecItemNotFound { return false }
        var insert = lookup
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// 删掉保险库项本身（连其 ACL）；修复授权时先删后重建用。
    private static func deleteVault(service: String, account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }

    /// 旧逐会话 item 的 account（id）列表——只读属性、不读密文，**不弹授权框**。
    private static func legacyAccounts(service: String) -> Set<String> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount] as? String })
    }

    private static func readLegacy(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacy(service: String, account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }

    // MARK: 明文索引文件

    private static func loadIndex(_ url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private func saveIndex() {
        let dir = indexURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(Array(index).sorted()) else { return }
        try? data.write(to: indexURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}
#endif
