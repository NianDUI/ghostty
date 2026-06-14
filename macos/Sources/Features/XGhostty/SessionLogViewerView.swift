#if XGHOSTTY
import SwiftUI

/// 会话日志查看器 sheet（座舱设置「查看会话日志…」进入）：选日志文件 → 原始/纯文本切换查看，
/// 不用去 Finder 翻文件。raw 保真落盘不变，「纯文本」是查看时按需剥离 ANSI（不改磁盘内容）。
struct SessionLogViewerView: View {
    var onClose: () -> Void

    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var plain = false
    @State private var content = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会话日志").font(.headline)

            if files.isEmpty {
                Text("还没有会话日志。在设置里开启「记录会话日志」后，打开 ssh 会话即生成。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(files, id: \.self) { u in
                            Button(u.lastPathComponent) { selected = u; reload() }
                        }
                    } label: {
                        HStack {
                            Text(selected?.lastPathComponent ?? "选择日志文件").lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .consoleFieldBox()
                    }
                    .buttonStyle(.plain)

                    Picker("", selection: $plain) {
                        Text("原始").tag(false)
                        Text("纯文本").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: plain) { _ in reload() }
                }

                ScrollView {
                    Text(content.isEmpty ? "（空）" : content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 320)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))

                if plain {
                    Text("纯文本为简单剥离 ANSI；交互式程序（vim/top 等）的输出剥离后布局可能仍不完美。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if let selected {
                    Button("在 Finder 显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([selected])
                    }
                    Button("删除") { deleteSelected() }.foregroundStyle(.red)
                }
                Spacer()
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 600)
        .onAppear {
            files = SessionLogStore.shared.logFiles()
            selected = files.first
            reload()
        }
    }

    private func reload() {
        guard let selected else { content = ""; return }
        content = SessionLogStore.shared.readLog(selected, plain: plain)
    }

    private func deleteSelected() {
        guard let url = selected else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除日志「\(url.lastPathComponent)」？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: url)
        files = SessionLogStore.shared.logFiles()
        selected = files.first
        reload()
    }
}
#endif
