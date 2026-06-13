#if os(macOS)
import SwiftUI

/// 「共享设置」表单 sheet 收集到的结果（点击「启动共享」时回传）。
struct SessionSharingSheetResult {
    let name: String
    let relay: String
    let token: String
    let saveConfig: Bool
    let uploadEnabled: Bool
    let autoCleanEnabled: Bool
    let autoCleanDays: Int
}

/// session-sharing「共享设置」的 SwiftUI 表单（替代旧的 NSAlert + AppKit 控件）。
///
/// 风格对齐 Ghostty 命令面板 / XGhostty 座舱：`.textFieldStyle(.plain)` + 半透明圆角输入框，
/// sheet 背景由调用方铺成当前终端背景色（见 `presentSettingsSheet`）。逻辑（校验 / Keychain /
/// relay 历史 / 自动清理）全部保留，仅 UI 重写。
struct SessionSharingSheetView: View {
    let relayHistory: [String]
    let allowedDays: [Int]
    let validate: (_ name: String, _ relay: String, _ token: String) -> String?
    let onStart: (SessionSharingSheetResult) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var relay: String
    @State private var token: String
    @State private var saveConfig: Bool
    @State private var uploadEnabled: Bool
    @State private var autoCleanEnabled: Bool
    @State private var autoCleanDays: Int

    init(name: String, relay: String, token: String,
         saveConfig: Bool, uploadEnabled: Bool,
         autoCleanEnabled: Bool, autoCleanDays: Int,
         relayHistory: [String], allowedDays: [Int],
         validate: @escaping (String, String, String) -> String?,
         onStart: @escaping (SessionSharingSheetResult) -> Void,
         onCancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        _relay = State(initialValue: relay)
        _token = State(initialValue: token)
        _saveConfig = State(initialValue: saveConfig)
        _uploadEnabled = State(initialValue: uploadEnabled)
        _autoCleanEnabled = State(initialValue: autoCleanEnabled)
        _autoCleanDays = State(initialValue: autoCleanDays)
        self.relayHistory = relayHistory
        self.allowedDays = allowedDays
        self.validate = validate
        self.onStart = onStart
        self.onCancel = onCancel
    }

    private var validationMessage: String? { validate(name, relay, token) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("共享设置").font(.headline)
            Text("将当前终端会话共享到中转服务器。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            labeled("会话名称") {
                TextField("Ghostty-时间戳", text: $name).sharingFieldBox()
            }
            labeled("中转服务器") {
                HStack(spacing: 6) {
                    TextField("relay.example.com:443", text: $relay).sharingFieldBox()
                    if !relayHistory.isEmpty {
                        Menu {
                            ForEach(relayHistory, id: \.self) { h in
                                Button(h) { relay = h }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("最近使用的中转服务器")
                    }
                }
            }
            labeled("认证令牌") {
                SecureField("认证令牌", text: $token).sharingFieldBox()
            }

            Divider()

            Toggle("保存配置", isOn: $saveConfig)
            Toggle("允许 Web 客户端上传文件", isOn: $uploadEnabled)
                .help("Web 客户端上传完成后会在终端光标处注入文件路径。")
            HStack(spacing: 6) {
                Toggle("自动清理", isOn: $autoCleanEnabled)
                Menu {
                    ForEach(allowedDays, id: \.self) { d in
                        Button("\(d) 天前") { autoCleanDays = d }
                    }
                } label: {
                    Text("\(autoCleanDays) 天前")
                }
                .fixedSize()
                .disabled(!autoCleanEnabled)
                Text("的上传文件").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .help("每天 03:15 通过 launchd 清理早于设定天数的上传文件。")

            if let msg = validationMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("启动共享") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private func start() {
        guard validationMessage == nil else { return }
        onStart(SessionSharingSheetResult(
            name: name, relay: relay, token: token,
            saveConfig: saveConfig, uploadEnabled: uploadEnabled,
            autoCleanEnabled: autoCleanEnabled, autoCleanDays: autoCleanDays))
    }
}

private extension View {
    /// Ghostty 风格输入框：plain + 半透明圆角，融入 sheet 背景（明暗自适配）。
    func sharingFieldBox() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
    }
}
#endif
