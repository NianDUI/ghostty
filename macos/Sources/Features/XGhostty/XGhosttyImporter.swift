#if XGHOSTTY
import Foundation

/// 会话导入来源。
enum ImportSource {
    case windterm
    case xshell

    var displayName: String {
        switch self {
        case .windterm: return "WindTerm"
        case .xshell: return "XShell"
        }
    }

    /// 导入后包裹用的顶层分组名。
    var wrapperGroupName: String { "\(displayName) 导入" }
}

/// 导入结果：建好的会话子树（通常一个顶层分组）+ 统计 + 待建密码库凭据。
struct ImportResult {
    var roots: [SessionNode]        // 顶层导入分组（含嵌套）
    var sessionCount: Int           // 叶子（主机）总数
    var groupCount: Int             // 分组总数（含顶层包裹组）
    /// 本次导入**新建**的密码库凭据（密码留空，待用户填一次）。已存在的同名凭据被复用、不在此列。
    /// 叶子的 `credentialId` 已指向对应凭据（含复用的）。
    var credentials: [Credential]
}

enum ImportError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case parseFailure(String)
    case empty(String)

    var description: String {
        switch self {
        case .fileNotFound(let s): return "找不到文件：\(s)"
        case .parseFailure(let s): return "解析失败：\(s)"
        case .empty(let s): return s
        }
    }
}

/// 从 WindTerm / XShell 的本地配置目录解析出 XGhostty 会话树。纯函数（只读文件），可单测。
///
/// 两边的密码都是加密存储（WindTerm onekeys.config 的 `auth`、XShell 的会话密文），
/// **无法迁移**——导入只搬主机/端口/用户/分组/登录命令/密钥路径，密码由用户导入后另设。
enum XGhosttyImporter {

    // MARK: 公开入口

    /// WindTerm：用户选 `~/.wind`（或任意含 `user.sessions` 的目录）。
    /// 字段映射：target→host、port→port、label→name、group(`a>b>c`)→嵌套分组、
    /// oneKey→user（查 onekeys.config 的 name，取首个 `-` 前的段去掉凭据变体后缀）、
    /// ssh.identityFilePath.macos→identityFile、autoExecution→loginCommands。
    /// 只导 `session.protocol == "SSH"`（跳过 WindTerm 内置的本地 Shell 会话）。
    ///
    /// **密码批量映射**：每个 oneKey → 一条密码库凭据（按 oneKey 全名去重，如 `root-Nn` 与
    /// `root` 视为两条，保留你原有区分）；会话 `credentialId` 指过去。密钥登录（有 identityFile）
    /// 的会话不挂凭据。密文无法解密 → 新建凭据密码留空，用户填一次即覆盖所有引用会话。
    /// - existingCredentials: 已有密码库凭据（同名复用、不重建）。
    static func importWindTerm(from dir: URL,
                              existingCredentials: [Credential] = []) throws -> ImportResult {
        let sessionsURL = try locate("user.sessions", under: dir)
        let oneKeyURL = sessionsURL.deletingLastPathComponent()
            .appendingPathComponent("onekeys.config")
        let oneKeyInfo = parseOneKeys(oneKeyURL)

        guard let data = try? Data(contentsOf: sessionsURL) else {
            throw ImportError.fileNotFound(sessionsURL.path)
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw ImportError.parseFailure("user.sessions 不是预期的 JSON 数组")
        }

        var credCache = credentialCache(existingCredentials)
        var created: [Credential] = []
        var flats: [FlatSession] = []
        for s in arr {
            guard (s["session.protocol"] as? String) == "SSH" else { continue }
            guard let host = (s["session.target"] as? String)?.trimmed, !host.isEmpty else { continue }
            let port = intValue(s["session.port"])
            let label = (s["session.label"] as? String)?.trimmed
            let name = (label?.isEmpty == false) ? label! : host
            let groupPath = splitGroup((s["session.group"] as? String) ?? "", by: ">")
            let info = (s["session.oneKey"] as? String).flatMap { oneKeyInfo[$0] }
            let user = info?.user
            let identity = (s["ssh.identityFilePath.macos"] as? String)?.trimmed.nilIfEmpty
            // 会话级密钥登录（有 identityFile）不挂凭据。否则按 oneKey 建凭据：
            // 名字像私钥 → 密钥凭据（路径默认 ~/.ssh/...，passphrase 留空）；否则密码凭据。
            var credId: UUID?
            if identity == nil, let info {
                credId = resolveCredential(name: info.name, username: info.user,
                                           keyPath: keyPathHint(for: info.name),
                                           cache: &credCache, created: &created)
            }
            let cmds = multiline((s["session.autoExecution"] as? String) ?? "")
            let leaf = SessionNode(name: name, host: host, port: port, user: user,
                                   identityFile: identity, credentialId: credId, loginCommands: cmds)
            flats.append(FlatSession(groupPath: groupPath, node: leaf))
        }

        guard !flats.isEmpty else {
            throw ImportError.empty("未在 user.sessions 找到 SSH 会话")
        }
        return buildTree(wrapperName: ImportSource.windterm.wrapperGroupName,
                         flats: flats, credentials: created)
    }

    /// XShell：用户选 `…/Xshell/Sessions` 目录，递归找 `*.xsh`（UTF-16LE INI）。
    /// 字段映射：CONNECTION.Host→host、CONNECTION.Port→port、UserName→user、
    /// 文件名（去 .xsh）→name、相对目录层级→嵌套分组、ExpectSend（Count==1 时 Send_0）→loginCommands。
    ///
    /// **密码批量映射**：XShell 无 oneKey 概念，按 UserName 去重建凭据（同名用户名共一条），
    /// 会话 `credentialId` 指过去。密文无法解密 → 凭据密码留空，用户按用户名填一次即可。
    static func importXshell(from dir: URL,
                            existingCredentials: [Credential] = []) throws -> ImportResult {
        let xshFiles = filesRecursively(under: dir, ext: "xsh").sorted { $0.path < $1.path }
        guard !xshFiles.isEmpty else {
            throw ImportError.empty("目录下未找到 .xsh 会话文件")
        }

        var credCache = credentialCache(existingCredentials)
        var created: [Credential] = []
        var flats: [FlatSession] = []
        for f in xshFiles {
            guard let info = parseXsh(f) else { continue }
            guard let host = info["CONNECTION.Host"]?.trimmed, !host.isEmpty else { continue }
            let port = Int(info["CONNECTION.Port"]?.trimmed ?? "") ?? 22
            let user = info["CONNECTION:AUTHENTICATION.UserName"]?.trimmed.nilIfEmpty
            let name = f.deletingPathExtension().lastPathComponent
            let groupPath = Array(relativeParts(of: f, under: dir).dropLast())   // 去掉文件名
            var credId: UUID?
            if let user {
                credId = resolveCredential(name: user, username: user,
                                           cache: &credCache, created: &created)
            }
            var cmds: [String] = []
            if (Int(info["CONNECTION:AUTHENTICATION.ExpectSend_Count"]?.trimmed ?? "0") ?? 0) == 1,
               let send = info["CONNECTION:AUTHENTICATION.ExpectSend_Send_0"]?.nilIfEmpty {
                cmds = multiline(send)
            }
            let leaf = SessionNode(name: name, host: host, port: port, user: user,
                                   credentialId: credId, loginCommands: cmds)
            flats.append(FlatSession(groupPath: groupPath, node: leaf))
        }

        guard !flats.isEmpty else {
            throw ImportError.empty("未能从 .xsh 解析出有效主机")
        }
        return buildTree(wrapperName: ImportSource.xshell.wrapperGroupName,
                         flats: flats, credentials: created)
    }

    // MARK: 树构建

    /// 一条扁平会话：分组路径 + 叶子节点。
    private struct FlatSession {
        var groupPath: [String]
        var node: SessionNode
    }

    /// 把扁平会话按 groupPath 装进一个顶层包裹分组（find-or-create 各级子分组）。
    private static func buildTree(wrapperName: String, flats: [FlatSession],
                                  credentials: [Credential]) -> ImportResult {
        var wrapper = SessionNode(name: wrapperName, children: [])
        var groupCount = 1   // 包裹组自身
        for f in flats {
            insert(f.node, path: f.groupPath, into: &wrapper, groupCount: &groupCount)
        }
        return ImportResult(roots: [wrapper], sessionCount: flats.count,
                            groupCount: groupCount, credentials: credentials)
    }

    // MARK: 凭据去重映射

    /// 用现有密码库凭据播种缓存（按名字小写去重，已存在的同名直接复用、不重建）。
    private static func credentialCache(_ existing: [Credential]) -> [String: Credential] {
        var cache: [String: Credential] = [:]
        for c in existing { cache[c.name.lowercased()] = c }
        return cache
    }

    /// 按名字找凭据：命中缓存（含已有库 + 本次已建）→ 返回其 id；否则新建一条。
    /// `keyPath != nil` → 建密钥凭据（passphrase 留空待填）；否则建密码凭据（密码留空待填）。
    private static func resolveCredential(name: String, username: String?,
                                          keyPath: String? = nil,
                                          cache: inout [String: Credential],
                                          created: inout [Credential]) -> UUID {
        let key = name.lowercased()
        if let hit = cache[key] { return hit.id }
        let cred = Credential(name: name, username: username,
                              kind: keyPath != nil ? .key : nil, keyPath: keyPath)
        cache[key] = cred
        created.append(cred)
        return cred.id
    }

    /// oneKey 名字像私钥（含 id_rsa/id_ed25519/id_ecdsa/id_dsa/.pem）→ 返回猜测的私钥路径；
    /// 否则 nil（按密码处理）。密文里的真实路径解不出 → 给个 `~/.ssh/...` 默认值，用户可在密码库改。
    /// 进一步：名字里其它词若对应 `~/.ssh/<词>/<stem>` 实际存在的钥匙，优先用它
    /// （如 `www-id_rsa-jenkins` → `~/.ssh/jenkins/id_rsa`）。
    private static func keyPathHint(for name: String) -> String? {
        let lower = name.lowercased()
        let stems = ["id_ed25519", "id_ecdsa", "id_dsa", "id_rsa"]
        guard stems.contains(where: { lower.contains($0) }) || lower.contains(".pem") else {
            return nil
        }
        let stem = stems.first(where: { lower.contains($0) }) ?? "id_rsa"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tokens = lower.split(whereSeparator: { "-_ .".contains($0) }).map(String.init)
        for t in tokens where t.count > 1 && !t.hasPrefix("id") && t != "rsa"
            && t != "ed25519" && t != "ecdsa" && t != "dsa" && t != "pem" {
            let candidate = home.appendingPathComponent(".ssh/\(t)/\(stem)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return "~/.ssh/\(t)/\(stem)"
            }
        }
        return "~/.ssh/\(stem)"
    }

    private static func insert(_ leaf: SessionNode, path: [String],
                               into group: inout SessionNode, groupCount: inout Int) {
        var children = group.children ?? []
        if path.isEmpty {
            children.append(leaf)
            group.children = children
            return
        }
        let head = path[0]
        let rest = Array(path.dropFirst())
        if let idx = children.firstIndex(where: { $0.isGroup && $0.name == head }) {
            insert(leaf, path: rest, into: &children[idx], groupCount: &groupCount)
        } else {
            var newGroup = SessionNode(name: head, children: [])
            groupCount += 1
            insert(leaf, path: rest, into: &newGroup, groupCount: &groupCount)
            children.append(newGroup)
        }
        group.children = children
    }

    // MARK: WindTerm 辅助

    /// 在 dir 下定位 `name`（如 user.sessions）：先看 dir 直接子；否则递归找，
    /// 优先 `/terminal/` 路径下的，再退而取层级最浅的。
    private static func locate(_ name: String, under dir: URL) throws -> URL {
        let direct = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let matches = filesRecursively(under: dir, name: name)
        if let t = matches.first(where: { $0.path.contains("/terminal/") }) { return t }
        if let s = matches.min(by: { $0.pathComponents.count < $1.pathComponents.count }) { return s }
        throw ImportError.fileNotFound("\(name)（在 \(dir.lastPathComponent) 下未找到）")
    }

    /// 一条 oneKey 的关键信息：全名（做密码库凭据名，保留 `root-Nn` 区分）+ 推断用户名。
    private struct OneKeyInfo { var name: String; var user: String }

    /// 解析 onekeys.config → `oneKeyUUID : OneKeyInfo`。用户名取 name 在首个 `-` 前的段，
    /// 去掉 `root-Nn` / `www-id_rsa-jenkins` 这类凭据变体后缀。
    private static func parseOneKeys(_ url: URL) -> [String: OneKeyInfo] {
        guard let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: OneKeyInfo] = [:]
        for o in arr {
            guard let uuid = o["uuid"] as? String, let rawName = o["name"] as? String else { continue }
            let user = rawName.split(separator: "-", maxSplits: 1).first.map(String.init) ?? rawName
            map[uuid] = OneKeyInfo(name: rawName.trimmed, user: user.trimmed)
        }
        return map
    }

    // MARK: XShell 辅助

    /// 解析 XShell `.xsh`（UTF-16LE INI，带 BOM）→ `section.key : value`。
    private static func parseXsh(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf8)
        guard let text else { return nil }
        return parseINI(text)
    }

    private static func parseINI(_ raw: String) -> [String: String] {
        var section = ""
        var out: [String: String] = [:]
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "\u{FEFF}", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...])
            out["\(section).\(key)"] = val
        }
        return out
    }

    /// file 相对 dir 的路径段（含文件名）。算不出相对就回退为 [文件名]。
    private static func relativeParts(of file: URL, under dir: URL) -> [String] {
        let dirComps = dir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComps = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if fileComps.count > dirComps.count,
           Array(fileComps.prefix(dirComps.count)) == dirComps {
            return Array(fileComps.dropFirst(dirComps.count))
        }
        return [file.lastPathComponent]
    }

    // MARK: 文件遍历

    private static func filesRecursively(under dir: URL, ext: String) -> [URL] {
        enumerate(dir) { $0.pathExtension.lowercased() == ext.lowercased() }
    }

    private static func filesRecursively(under dir: URL, name: String) -> [URL] {
        enumerate(dir) { $0.lastPathComponent == name }
    }

    private static func enumerate(_ dir: URL, where match: (URL) -> Bool) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where match(u) { out.append(u) }
        return out
    }

    // MARK: 字符串

    /// 把含字面 `\r\n` / 真换行的多行串拆成非空行数组（trim 每行）。
    private static func multiline(_ s: String) -> [String] {
        let unescaped = s
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return unescaped.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func splitGroup(_ s: String, by sep: Character) -> [String] {
        s.split(separator: sep)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}
#endif
