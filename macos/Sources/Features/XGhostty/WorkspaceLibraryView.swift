#if XGHOSTTY
import SwiftUI

/// 工作区管理 sheet（左树底部 ▦ 入口）：列出工作区（一键打开 / 删除）+ 把当前打开的会话存为新工作区。
/// 风格对齐密码库 / 跳板机清单（确定高度的 ScrollView + ObservableObject 直接观察）。
struct WorkspaceLibraryView: View {
    let currentSessionCount: Int
    var onOpen: (Workspace) -> Void
    var onSaveCurrent: (String) -> Void
    var onClose: () -> Void

    @ObservedObject private var store = WorkspaceStore.shared
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工作区").font(.headline)
            Text("把当前打开的一组会话存成命名工作区，以后一键全部打开（运维每天开固定一批机器的刚需）。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.workspaces.isEmpty {
                Text("还没有工作区。下方输入名称，把当前打开的会话存为第一个。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.workspaces) { w in row(w) }
                    }
                }
                .frame(height: min(CGFloat(store.workspaces.count) * 42 + 4, 220))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("保存当前 \(currentSessionCount) 个会话为新工作区")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("工作区名称", text: $newName).consoleFieldBox()
                    Button("保存") { saveCurrent() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || currentSessionCount == 0)
                }
                if currentSessionCount == 0 {
                    Text("当前没有打开的会话可保存。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func row(_ w: Workspace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(w.name).lineLimit(1)
                Text("\(w.sessionIds.count) 个会话")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开") { onOpen(w); onClose() }
                .controlSize(.small)
            Button { delete(w) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red)
                .help("删除工作区")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
    }

    private func saveCurrent() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        onSaveCurrent(n)
        newName = ""
    }

    private func delete(_ w: Workspace) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除工作区「\(w.name)」？"
        alert.informativeText = "只删这个工作区分组，里面引用的会话本身不受影响。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(w.id)
    }
}
#endif
