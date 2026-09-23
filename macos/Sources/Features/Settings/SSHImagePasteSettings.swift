#if os(macOS)
import Foundation
import SwiftUI

struct SSHImagePasteSettings: Codable, Equatable {
    static let defaultMaxImageBytes = 20 * 1024 * 1024

    var enabled: Bool = false
    var maxImageBytes: Int = defaultMaxImageBytes
    var remoteBaseDirectory: String = "/tmp"
}

final class SSHImagePasteSettingsStore {
    static let shared = SSHImagePasteSettingsStore()

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = "ssh-image-paste-settings") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SSHImagePasteSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(SSHImagePasteSettings.self, from: data) else {
            return .init()
        }
        return value
    }

    func save(_ value: SSHImagePasteSettings) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

enum SSHImagePasteSettingsValidation {
    static func message(remoteBaseDirectory raw: String) -> String? {
        let directory = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return "请输入远程临时目录。" }
        guard directory.hasPrefix("/") else { return "远程临时目录必须是绝对路径。" }
        guard !directory.contains("\n"), !directory.contains("\r"), !directory.contains("\0") else {
            return "远程临时目录不能包含控制字符。"
        }
        return nil
    }
}

enum SSHImagePastePath {
    static func remotePath(baseDirectory: String, surfaceID: UUID, imageID: UUID) -> String {
        let base = baseDirectory == "/"
            ? ""
            : baseDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/\(base)/\(surfaceID.uuidString.lowercased())/\(imageID.uuidString.lowercased()).png"
            .replacingOccurrences(of: "//", with: "/")
    }
}

/// 从本地 shell 的前台 `ssh ...` 命令提取建立第二条上传连接所需的参数。
/// 只保留连接相关选项，丢弃 `-t` 和目标后的远端命令。
enum SSHImagePasteRunningSSH {
    static func uploadArguments(commandLine: String) -> [String]? {
        let tokens = shellWords(commandLine)
        guard let executable = tokens.first,
              (executable as NSString).lastPathComponent == "ssh" else { return nil }

        let valueOptions: Set<String> = ["-F", "-i", "-J", "-l", "-o", "-p"]
        let flagOptions: Set<String> = ["-4", "-6", "-C", "-q"]
        var connection: [String] = []
        var index = 1

        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            if !token.hasPrefix("-") { break }
            if token == "-t" || token == "-tt" || token == "-T" {
                index += 1
                continue
            }
            if flagOptions.contains(token) {
                connection.append(token)
                index += 1
                continue
            }
            if valueOptions.contains(token) {
                guard index + 1 < tokens.count else { return nil }
                connection += [token, tokens[index + 1]]
                index += 2
                continue
            }
            if valueOptions.contains(where: { token.hasPrefix($0) && token.count > $0.count }) {
                connection.append(token)
                index += 1
                continue
            }
            // 未识别的 ssh 选项可能带参数，猜测会把远端命令误当目标，因此安全降级。
            return nil
        }

        guard index < tokens.count else { return nil }
        let target = tokens[index]
        return [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
        ] + connection + [target]
    }

    /// Ghostty 返回的前台 PID 可能是 trzsz/login 包装层；沿它的子进程树寻找真正的 ssh。
    static func uploadArguments(processList: String, rootPID: Int) -> [String]? {
        struct Entry {
            var pid: Int
            var parentPID: Int
            var command: String
        }

        let entries: [Entry] = processList.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3,
                  let pid = Int(fields[0]),
                  let parentPID = Int(fields[1]) else { return nil }
            return Entry(pid: pid, parentPID: parentPID, command: String(fields[2]))
        }
        let byPID = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) })
        let children = Dictionary(grouping: entries, by: \Entry.parentPID)
        var queue = [rootPID]
        var visited: Set<Int> = []

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard visited.insert(pid).inserted else { continue }
            if let entry = byPID[pid],
               let arguments = uploadArguments(commandLine: entry.command) {
                return arguments
            }
            queue.append(contentsOf: children[pid, default: []].map(\.pid))
        }
        return nil
    }

    private static func shellWords(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

struct SSHImagePasteSettingsView: View {
    let allowedImageSizes: [Int]
    let onSave: (SSHImagePasteSettings) -> Void
    let onCancel: () -> Void

    @State private var enabled: Bool
    @State private var maxImageBytes: Int
    @State private var remoteBaseDirectory: String

    init(settings: SSHImagePasteSettings,
         allowedImageSizes: [Int] = [5, 10, 20, 50].map { $0 * 1024 * 1024 },
         onSave: @escaping (SSHImagePasteSettings) -> Void,
         onCancel: @escaping () -> Void) {
        _enabled = State(initialValue: settings.enabled)
        _maxImageBytes = State(initialValue: settings.maxImageBytes)
        _remoteBaseDirectory = State(initialValue: settings.remoteBaseDirectory)
        self.allowedImageSizes = allowedImageSizes
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var validationMessage: String? {
        enabled
            ? SSHImagePasteSettingsValidation.message(remoteBaseDirectory: remoteBaseDirectory)
            : nil
    }

    private var normalizedDirectory: String {
        let value = remoteBaseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 1 else { return value }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SSH 图片粘贴设置").font(.headline)
            Text("在直接运行 SSH 的终端中，把 macOS 剪贴板图片上传到远端并填入文件路径。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Toggle("用 Ctrl+V 上传剪贴板图片", isOn: $enabled)

            Divider()

            labeled("单张图片上限") {
                Picker("单张图片上限", selection: $maxImageBytes) {
                    ForEach(allowedImageSizes, id: \.self) { bytes in
                        Text("\(bytes / 1024 / 1024) MiB").tag(bytes)
                    }
                }
                .labelsHidden()
                .frame(width: 120, alignment: .leading)
                .disabled(!enabled)
            }

            labeled("远程临时目录") {
                TextField("/tmp", text: $remoteBaseDirectory)
                    .sshImagePasteFieldBox()
                    .disabled(!enabled)
            }

            Text("实际路径：\(normalizedDirectory)/<会话 ID>/<图片 ID>.png")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("仅图片剪贴板会触发上传；文本、非 SSH 会话和无法识别目标的连接保持原有 Ctrl+V 行为。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let validationMessage {
                Text(validationMessage).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        guard validationMessage == nil else { return }
        let directory = normalizedDirectory.isEmpty ? "/tmp" : normalizedDirectory
        onSave(.init(
            enabled: enabled,
            maxImageBytes: maxImageBytes,
            remoteBaseDirectory: directory))
    }
}

private extension View {
    func sshImagePasteFieldBox() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
    }
}
#endif
