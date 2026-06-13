#if XGHOSTTY
import SwiftUI
import AppKit

/// 会话/分组编辑表单（座舱左树右键「新建/编辑」弹出的 sheet）。
///
/// - 分组：仅名称。
/// - 主机：名称 + host/port/user/proxyJump + 登录命令；host 留空即「本地 shell」。
///
/// 保存前复用 `SessionCommandBuilder.build` 做白名单校验（防 shell 注入）：
/// 主机字段非法直接拦在表单里，本地 shell（host 空）放行。
struct SessionEditView: View {
    /// 认证方式（密码 / 密钥 二选一，互斥）。
    private enum AuthMethod: Hashable { case password, key }

    /// 编辑锁定类型（分组 ↔ 主机不可互转）；新建时为 false，可在表单里选类型。
    let lockType: Bool
    /// 保留原 id 与 children，保存时带回。
    private let original: SessionNode
    var onSave: (SessionNode) -> Void
    var onCancel: () -> Void

    @State private var isGroup: Bool
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var user: String
    @State private var proxyJump: String
    @State private var proxyJumpId: UUID?               // 引用作跳板的已存主机（nil=无/手动）
    @State private var manualJump: Bool                 // true=手动填 proxyJump，false=无或引用
    @State private var identityFile: String
    @State private var password: String = ""          // 永远空起步，不把密文读进字段
    @State private var hadPassword: Bool               // Keychain 是否已存密码
    @State private var clearPassword: Bool = false      // 点了「清除已存密码」
    @State private var credentialId: UUID?              // 引用的密码库凭据（nil=直接输入）
    @State private var authMethod: AuthMethod           // 密码 / 密钥 二选一
    @State private var passwordStrict: Bool             // 仅用密码（不尝试 SSH 密钥）
    @State private var loginText: String
    @State private var errorText: String?

    init(node: SessionNode,
         lockType: Bool,
         onSave: @escaping (SessionNode) -> Void,
         onCancel: @escaping () -> Void) {
        self.original = node
        self.lockType = lockType
        self.onSave = onSave
        self.onCancel = onCancel
        _isGroup = State(initialValue: node.isGroup)
        _name = State(initialValue: node.name)
        _host = State(initialValue: node.host ?? "")
        _port = State(initialValue: node.port.map(String.init) ?? "")
        _user = State(initialValue: node.user ?? "")
        _proxyJump = State(initialValue: node.proxyJump ?? "")
        _proxyJumpId = State(initialValue: node.proxyJumpId)
        _manualJump = State(initialValue: node.proxyJumpId == nil && !(node.proxyJump ?? "").isEmpty)
        _identityFile = State(initialValue: node.identityFile ?? "")
        _hadPassword = State(initialValue: XGhosttyCredentialStore.shared.hasPassword(for: node.id))
        // 认证方式判定：① 会话级密钥路径 → 密钥（会话指定路径）；② 引用了密钥库凭据 → 密钥（库凭据）；
        // ③ 其余 → 密码（含直接输入 / 密码库凭据 / 都没配）。
        let cred = node.credentialId.flatMap { CredentialLibrary.shared.find($0) }
        if node.identityFile != nil {
            _authMethod = State(initialValue: .key)
            _credentialId = State(initialValue: nil)        // 会话路径模式不引用凭据
        } else if cred?.isKey == true {
            _authMethod = State(initialValue: .key)
            _credentialId = State(initialValue: node.credentialId)
        } else {
            _authMethod = State(initialValue: .password)
            _credentialId = State(initialValue: node.credentialId)
        }
        _passwordStrict = State(initialValue: node.passwordOnly == true)
        _loginText = State(initialValue: node.loginCommands.joined(separator: "\n"))
    }

    var body: some View {
        // 手工 VStack（不用 Form）：每个字段高度确定，sheet 才能按 fittingSize 撑开。
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            if !lockType {
                Picker("类型", selection: $isGroup) {
                    Text("主机").tag(false)
                    Text("分组").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            field("名称", text: $name, placeholder: isGroup ? "分组名" : "会话名")

            if !isGroup {
                field("主机 / IP", text: $host, placeholder: "必填，如 192.0.2.10")
                HStack(alignment: .bottom, spacing: 10) {
                    field("端口", text: $port, placeholder: "22").frame(width: 100)
                    field("用户名", text: $user, placeholder: "必填，如 root")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("跳板 ProxyJump").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        // 无 / 引用跳板机清单里的一条（自动带它的 user@host:port）/ 手动填写。
                        Menu {
                            Button("无") { proxyJumpId = nil; manualJump = false }
                            Button("手动填写") { manualJump = true; proxyJumpId = nil }
                            let jumps = JumpHostStore.shared.hosts
                            if !jumps.isEmpty {
                                Divider()
                                ForEach(jumps) { j in
                                    Button(j.name) { proxyJumpId = j.id; manualJump = false }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(jumpSourceLabel)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    if manualJump {
                        TextField("user@host[:port]，可空", text: $proxyJump).consoleFieldBox()
                    } else if let jid = proxyJumpId, let j = JumpHostStore.shared.find(jid) {
                        Text("经跳板「\(j.name)」（\(j.endpointDisplay)）；跳板自身用你的默认密钥登录。在左下跳板机管理里增删。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !manualJump {
                        Text("跳板机在左下「跳板机管理」里维护，这里引用。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("认证方式").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: $authMethod) {
                        Text("密码").tag(AuthMethod.password)
                        Text("密钥").tag(AuthMethod.key)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    // 切换认证方式时重置「来源」，避免把密码凭据带到密钥侧（反之亦然）。
                    .onChange(of: authMethod) { _ in credentialId = nil }
                }

                if authMethod == .key {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("密钥来源").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            // 会话指定路径 / 从密码库选密钥凭据（多台共用一把钥匙、改一处全生效）。
                            Menu {
                                Button("会话指定路径") { credentialId = nil }
                                let keys = CredentialLibrary.shared.credentials.filter { $0.isKey }
                                if !keys.isEmpty {
                                    Divider()
                                    ForEach(keys) { c in Button(c.name) { credentialId = c.id } }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(keySourceLabel)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        if credentialId == nil {
                            HStack(spacing: 8) {
                                TextField("~/.ssh/id_rsa", text: $identityFile)
                                    .consoleFieldBox()
                                Button("选择…") { chooseIdentityFile() }
                            }
                            Text("私钥文件路径（ssh -i），私钥本身留在磁盘。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text("使用密钥库凭据「\(keySourceLabel)」——在密码库（左下🔑）里改路径 / passphrase，所有引用会话同步生效。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("密码来源").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            // 直接输入 / 从密码库选具名凭据（多台共用、改一处全生效）。
                            Menu {
                                Button("直接输入") { credentialId = nil }
                                // 密码侧只列密码凭据（密钥凭据在密钥侧选）。
                                let creds = CredentialLibrary.shared.credentials.filter { !$0.isKey }
                                if !creds.isEmpty {
                                    Divider()
                                    ForEach(creds) { c in
                                        Button(c.name) { credentialId = c.id }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(credentialSourceLabel)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }

                        Toggle(isOn: $passwordStrict) {
                            Text("仅用密码（不尝试 SSH 密钥）").font(.system(size: 11))
                        }
                        .toggleStyle(.checkbox)
                        .help("不勾（默认）：先试你的 SSH 默认密钥、失败再用密码——兼容只收密钥的主机。勾选：只走密码。")

                        if credentialId == nil {
                            HStack {
                                Spacer()
                                if hadPassword {
                                    if clearPassword {
                                        Text("将在保存时清除")
                                            .font(.system(size: 11)).foregroundStyle(.red)
                                        Button("撤销") { clearPassword = false }
                                            .buttonStyle(.plain).font(.system(size: 11))
                                    } else {
                                        Button("清除已存密码") { clearPassword = true }
                                            .buttonStyle(.plain).font(.system(size: 11))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            ASCIISecureField(
                                placeholder: hadPassword ? "已保存，留空保持不变" : "留空＝不存密码",
                                text: $password)
                                .consoleFieldBox()
                            Text("密码只存系统钥匙串（Keychain），不写入配置文件；输入时已自动切英文输入法。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text("使用密码库凭据「\(credentialSourceLabel)」——在密码库（左下🔑）里改密码，所有引用它的会话同步生效。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录后执行（每行一条，可空）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $loginText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 60)
                        .consoleEditorBox()
                }
            }

            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// 带上标签的输入行（标签 + 圆角 TextField）。
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>,
                       placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).consoleFieldBox()
        }
    }

    private var title: String {
        let kind = isGroup ? "分组" : "主机"
        return original.name.isEmpty ? "新建\(kind)" : "编辑\(kind)「\(original.name)」"
    }

    /// 密码来源下拉的当前显示文案。
    private var credentialSourceLabel: String {
        guard let credentialId else { return "直接输入" }
        return CredentialLibrary.shared.find(credentialId)?.name ?? "未知凭据"
    }

    /// 密钥来源下拉的当前显示文案。
    private var keySourceLabel: String {
        guard let credentialId else { return "会话指定路径" }
        return CredentialLibrary.shared.find(credentialId)?.name ?? "未知凭据"
    }

    /// 跳板来源下拉的当前显示文案。
    private var jumpSourceLabel: String {
        if manualJump { return "手动填写" }
        if let proxyJumpId { return JumpHostStore.shared.find(proxyJumpId)?.name ?? "未知跳板" }
        return "无"
    }

    private func save() {
        var node = original
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if isGroup {
            guard !trimmedName.isEmpty else { errorText = "分组名不能为空"; return }
            node.name = trimmedName
            // 新建分组 children 为 nil → 给空数组（isGroup 靠 children != nil 判定）。
            node.children = original.children ?? []
            node.host = nil; node.port = nil; node.user = nil; node.proxyJump = nil
            node.loginCommands = []
            onSave(node)
            return
        }

        // 主机：组装字段。host 必填（本地 shell 走 tab 空白双击创建，不在此表单建）。
        node.children = nil
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { errorText = "主机 / IP 不能为空"; return }
        node.host = h
        // 名称留空：用 IP/host 顶上。
        node.name = trimmedName.isEmpty ? h : trimmedName
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { errorText = "用户名不能为空"; return }
        node.user = u
        // 跳板：引用主机优先；手动则存字符串；无则都清空。
        if manualJump {
            node.proxyJump = proxyJump.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            node.proxyJumpId = nil
        } else {
            node.proxyJumpId = proxyJumpId
            node.proxyJump = nil
        }

        // 认证方式二选一（互斥）。密钥侧再分「会话路径」与「密钥库凭据」两种来源。
        if authMethod == .key {
            if let credentialId {
                node.credentialId = credentialId   // 引用密钥库凭据（路径/passphrase 在库里）
                node.identityFile = nil
            } else {
                let key = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    node.identityFile = nil
                } else {
                    let expanded = (key as NSString).expandingTildeInPath
                    guard FileManager.default.fileExists(atPath: expanded) else {
                        errorText = "密钥文件不存在：\(key)"; return
                    }
                    node.identityFile = key
                }
                node.credentialId = nil
            }
            node.passwordOnly = nil           // 密钥登录与「仅用密码」无关
        } else {
            node.identityFile = nil
            node.credentialId = credentialId  // 密码认证：可引用凭据（nil=直接输入）
            node.passwordOnly = passwordStrict ? true : nil
        }

        node.loginCommands = loginText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let pt = port.trimmingCharacters(in: .whitespaces)
        if pt.isEmpty {
            node.port = nil
        } else if let p = Int(pt), (1...65535).contains(p) {
            node.port = p
        } else {
            errorText = "端口需为 1–65535 的数字"; return
        }

        // 复用命令构造器做白名单校验（本地 shell host 空 → command nil，不抛）。
        do {
            _ = try SessionCommandBuilder.build(for: node)
        } catch {
            errorText = "\(error)"; return
        }

        // 凭据写入 Keychain（密码绝不写 sessions.json）。密钥 / 用密码库凭据 → 清掉本会话内联密码
        // （避免残留）；直接输入 → 非空设置 / 空且点清除则删除 / 否则不动。
        if authMethod == .key || credentialId != nil {
            XGhosttyCredentialStore.shared.removePassword(for: node.id)
        } else if !password.isEmpty {
            XGhosttyCredentialStore.shared.setPassword(password, for: node.id)
        } else if clearPassword {
            XGhosttyCredentialStore.shared.removePassword(for: node.id)
        }

        onSave(node)
    }

    /// 弹 NSOpenPanel 选本地 SSH 私钥（默认定位 ~/.ssh，显示隐藏文件）。
    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true                 // ~/.ssh 是点目录，默认隐藏
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDir.path) {
            panel.directoryURL = sshDir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 存成 ~ 缩写形式，跨用户/可读；构造命令时再展开。
        identityFile = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
