#if XGHOSTTY
import SwiftUI

/// 跳板机管理 sheet：列出/增删改跳板机。单 sheet 内「列表↔编辑」模式切换。
struct JumpHostLibraryView: View {
    var onClose: () -> Void

    @ObservedObject private var store = JumpHostStore.shared
    @State private var editing: JumpHost?
    @State private var editingIsNew = false

    var body: some View {
        Group {
            if let editing {
                JumpHostEditView(
                    host: editing,
                    isNew: editingIsNew,
                    onSave: { h in store.upsert(h); self.editing = nil },
                    onCancel: { self.editing = nil })
            } else {
                listBody
            }
        }
        .frame(width: 420)
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("跳板机").font(.headline)
            Text("少数堡垒机单独管理，会话在「跳板 ProxyJump」里引用。跳板自身用你的 ~/.ssh 默认密钥登录。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.hosts.isEmpty {
                Text("还没有跳板机，点左下角 ＋ 新增。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.hosts) { h in row(h) }
                    }
                }
                .frame(height: min(CGFloat(store.hosts.count) * 46 + 4, 260))
            }

            HStack {
                Button { startNew() } label: { Image(systemName: "plus") }
                    .help("新增跳板机")
                Spacer()
                Button("取消") { onClose() }.keyboardShortcut(.cancelAction)
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func row(_ h: JumpHost) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).lineLimit(1)
                Text(h.endpointDisplay).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("编辑") { startEdit(h) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { delete(h) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
    }

    private func startNew() {
        editing = JumpHost(name: "", host: "")
        editingIsNew = true
    }

    private func startEdit(_ h: JumpHost) {
        editing = h
        editingIsNew = false
    }

    private func delete(_ h: JumpHost) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除跳板机「\(h.name)」？"
        alert.informativeText = "引用它的会话将改为直连（不再经跳板）。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(h.id)
    }
}

/// 单条跳板机编辑：名称 + host + user + port。
private struct JumpHostEditView: View {
    let isNew: Bool
    private let original: JumpHost
    var onSave: (JumpHost) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var user: String
    @State private var port: String
    @State private var credentialId: UUID?
    @State private var errorText: String?

    init(host h: JumpHost, isNew: Bool,
         onSave: @escaping (JumpHost) -> Void,
         onCancel: @escaping () -> Void) {
        self.original = h
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: h.name)
        _host = State(initialValue: h.host)
        _user = State(initialValue: h.user ?? "")
        _port = State(initialValue: h.port.map(String.init) ?? "")
        _credentialId = State(initialValue: h.credentialId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "新增跳板机" : "编辑跳板机").font(.headline)

            field("名称", text: $name, placeholder: "如：生产堡垒机")
            field("主机 / IP", text: $host, placeholder: "必填，如 10.0.0.1")
            HStack(alignment: .bottom, spacing: 10) {
                field("端口", text: $port, placeholder: "22").frame(width: 100)
                field("用户名", text: $user, placeholder: "如 root，可空")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("登录凭据").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    // 默认密钥 / 引用密码库凭据（密码或密钥都可）。
                    Menu {
                        Button("默认密钥（~/.ssh）") { credentialId = nil }
                        let creds = CredentialLibrary.shared.credentials
                        if !creds.isEmpty {
                            Divider()
                            ForEach(creds) { c in
                                Button(c.isKey ? "\(c.name)（密钥）" : c.name) { credentialId = c.id }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(credentialLabel)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Text("跳板自身用此凭据登录（经 ProxyCommand 携带）。默认密钥=用你 ~/.ssh 里的默认私钥。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).consoleFieldBox()
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { errorText = "名称不能为空"; return }
        guard !h.isEmpty else { errorText = "主机 / IP 不能为空"; return }
        var pInt: Int?
        let pt = port.trimmingCharacters(in: .whitespaces)
        if !pt.isEmpty {
            guard let p = Int(pt), (1...65535).contains(p) else {
                errorText = "端口需为 1–65535 的数字"; return
            }
            pInt = p
        }
        var jh = original
        jh.name = n
        jh.host = h
        jh.user = user.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        jh.port = pInt
        jh.credentialId = credentialId
        onSave(jh)
    }

    private var credentialLabel: String {
        guard let credentialId else { return "默认密钥（~/.ssh）" }
        return CredentialLibrary.shared.find(credentialId)?.name ?? "未知凭据"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
