#if XGHOSTTY
import SwiftUI

/// 密码库管理 sheet：列出具名凭据，增删改。密码进保险库、不显示明文。
/// 单 sheet 内「列表 ↔ 编辑」模式切换（不嵌套 sheet，避免与座舱单一 editorSheet 槽冲突）。
struct CredentialLibraryView: View {
    var onClose: () -> Void

    @ObservedObject private var library = CredentialLibrary.shared
    @State private var editing: Credential?     // 非 nil = 编辑模式
    @State private var editingIsNew = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if let editing {
                CredentialEditView(
                    credential: editing,
                    isNew: editingIsNew,
                    onSave: { cred, pw in
                        library.upsert(cred, password: pw)   // 列表随 @Published 自动刷新
                        self.editing = nil
                    },
                    onCancel: { self.editing = nil })
            } else {
                listBody
            }
        }
        .frame(width: 420)
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("密码库").font(.headline)
            Text("具名凭据可被多台会话共用（改一处全生效）。密码只存系统钥匙串，不写入配置文件。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            if library.credentials.isEmpty {
                Text("还没有凭据，点左下角 ＋ 新增。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                // 确定高度（按条数算，封顶 260）：ScrollView 在自适应尺寸的 NSHostingController 里
                // 没有确定高度会塌成 ~0、行被裁掉看不见（之前「列表不显示」的真因）。
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(library.credentials) { c in row(c) }
                    }
                }
                .frame(height: min(CGFloat(library.credentials.count) * 46 + 4, 260))
            }

            HStack {
                Button { startNew() } label: { Image(systemName: "plus") }
                    .help("新增凭据")
                Spacer()
                Button("取消") { onClose() }.keyboardShortcut(.cancelAction)
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func row(_ c: Credential) -> some View {
        let refCount = Self.usage(of: c.id).total
        return HStack(spacing: 8) {
            Image(systemName: c.isKey ? "key.horizontal.fill" : "key.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.name).lineLimit(1)
                    if c.isKey {
                        Text("密钥").font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                // 密钥凭据显示私钥路径，密码凭据显示用户名。
                if c.isKey, let p = c.keyPath, !p.isEmpty {
                    Text(p).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else if let u = c.username, !u.isEmpty {
                    Text(u).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if refCount > 0 {
                Text("\(refCount) 处引用").font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
                    .help("被 \(refCount) 台会话/跳板机引用")
            }
            Button("编辑") { startEdit(c) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { delete(c) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
    }

    /// 统计某凭据被哪些会话 / 跳板机引用（密码库行徽标、删除确认、编辑页清单共用）。
    static func usage(of id: UUID) -> (sessions: [String], jumpHosts: [String], total: Int) {
        let sessions = SessionStore.shared.sessionsReferencing(credentialId: id).map(\.path)
        let jumpHosts = JumpHostStore.shared.hosts
            .filter { $0.credentialId == id }
            .map { $0.name.isEmpty ? $0.endpointDisplay : $0.name }
        return (sessions, jumpHosts, sessions.count + jumpHosts.count)
    }

    private func startNew() {
        editing = Credential(name: "")
        editingIsNew = true
    }

    private func startEdit(_ c: Credential) {
        editing = c
        editingIsNew = false
    }

    private func delete(_ c: Credential) {
        let u = Self.usage(of: c.id)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除凭据「\(c.name)」？"
        if u.total == 0 {
            alert.informativeText = "当前没有会话或跳板机引用它。"
        } else {
            // 列出引用方（封顶 10 条，余数省略），让用户删前看清影响面。
            let names = (u.sessions + u.jumpHosts.map { "跳板机：\($0)" })
            let shown = names.prefix(10).joined(separator: "\n")
            let more = names.count > 10 ? "\n…等 \(names.count) 处" : ""
            alert.informativeText =
                "以下 \(u.total) 处将失去自动登录密码（改为交互登录）：\n\(shown)\(more)"
        }
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.remove(c.id)   // 列表随 @Published 自动刷新
    }
}

/// 单条凭据编辑（密码库内部）：名称 + 用户名 + 类型（密码 / 密钥）。
/// - 密码：一个密码字段（自动切英文）。
/// - 密钥：私钥路径（可浏览选择）+ 可选 passphrase。
private struct CredentialEditView: View {
    let isNew: Bool
    private let original: Credential
    var onSave: (Credential, String?) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var username: String
    @State private var kind: CredentialKind
    @State private var keyPath: String
    @State private var secret: String = ""          // 密码 or passphrase（按类型）
    @State private var hadSecret: Bool
    @State private var revealed = false             // 是否已展开「查看已存」
    @State private var revealedText = ""            // 从保险库读出的明文（展开时填充）
    @State private var errorText: String?

    /// 引用此凭据的会话路径 / 跳板机名（init 时一次性算好，编辑页「被引用」清单用）。
    private let refSessions: [String]
    private let refJumpHosts: [String]

    init(credential: Credential, isNew: Bool,
         onSave: @escaping (Credential, String?) -> Void,
         onCancel: @escaping () -> Void) {
        self.original = credential
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: credential.name)
        _username = State(initialValue: credential.username ?? "")
        _kind = State(initialValue: credential.kind ?? .password)
        _keyPath = State(initialValue: credential.keyPath ?? "")
        _hadSecret = State(initialValue:
            XGhosttyCredentialStore.shared.hasPassword(for: credential.id))
        let u = CredentialLibraryView.usage(of: credential.id)
        self.refSessions = u.sessions
        self.refJumpHosts = u.jumpHosts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "新增凭据" : "编辑凭据").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("如：服务器 root", text: $name).consoleFieldBox()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("用户名（可选，仅标识用）").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("如：root", text: $username).consoleFieldBox()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("类型").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $kind) {
                    Text("密码").tag(CredentialKind.password)
                    Text("密钥").tag(CredentialKind.key)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            if kind == .key {
                VStack(alignment: .leading, spacing: 4) {
                    Text("私钥文件路径").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("~/.ssh/id_rsa", text: $keyPath).consoleFieldBox()
                        Button("选择…") { chooseKey() }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Passphrase（可选，密钥有口令才填）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ASCIISecureField(
                        placeholder: hadSecret ? "已保存，留空保持不变" : "无口令可留空",
                        text: $secret)
                        .consoleFieldBox()
                    revealRow
                    Text("私钥本身留在磁盘，这里只存路径；passphrase 存系统钥匙串。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("密码").font(.system(size: 11)).foregroundStyle(.secondary)
                    ASCIISecureField(
                        placeholder: hadSecret ? "已保存，留空保持不变" : "密码",
                        text: $secret)
                        .consoleFieldBox()
                    revealRow
                    Text("只存系统钥匙串；输入时已自动切英文输入法。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            usageSection

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// 「查看已存密码 / passphrase」依类型变化的称呼。
    private var secretNoun: String { kind == .key ? "passphrase" : "密码" }

    /// eye 切换：点开从保险库读明文（触发一次 Keychain 授权），再点收起；附复制按钮。
    /// 仅当确有已存秘密（`hadSecret`）时出现——新建/空壳不显示。
    @ViewBuilder private var revealRow: some View {
        if hadSecret {
            HStack(spacing: 8) {
                Button {
                    if revealed {
                        revealed = false
                    } else {
                        revealedText = XGhosttyCredentialStore.shared.password(for: original.id) ?? ""
                        revealed = true
                    }
                } label: {
                    Label(revealed ? "隐藏" : "查看已存\(secretNoun)",
                          systemImage: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)

                if revealed {
                    Text(revealedText.isEmpty ? "（空）" : revealedText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(revealedText, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("复制到剪贴板")
                }
            }
        }
    }

    /// 「被引用」清单：列出引用此凭据的会话路径 + 跳板机，让用户改/删前看清影响面。
    @ViewBuilder private var usageSection: some View {
        let total = refSessions.count + refJumpHosts.count
        if total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("被引用（\(total)）").font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(refSessions, id: \.self) { p in
                            Label(p, systemImage: "terminal")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        ForEach(refJumpHosts, id: \.self) { nm in
                            Label("跳板机：\(nm)", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(total) * 18 + 4, 110))
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { errorText = "名称不能为空"; return }

        var cred = original
        cred.name = n
        cred.username = username.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if kind == .key {
            let k = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { errorText = "请填写私钥文件路径"; return }
            let expanded = (k as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                errorText = "密钥文件不存在：\(k)"; return
            }
            cred.kind = .key
            cred.keyPath = k
        } else {
            // 新建密码凭据必须给密码（空壳无意义）；编辑时留空 = 保持原密码。
            if isNew && secret.isEmpty { errorText = "请输入密码"; return }
            cred.kind = .password
            cred.keyPath = nil
        }
        onSave(cred, secret.isEmpty ? nil : secret)
    }

    /// 弹 NSOpenPanel 选私钥（默认 ~/.ssh，显示隐藏文件）。
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDir.path) { panel.directoryURL = sshDir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyPath = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
