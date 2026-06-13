#if XGHOSTTY
import SwiftUI

/// 单条快捷命令编辑表单（快捷条 `+` 新增 / 右键「编辑…」弹出的 sheet）。
///
/// 样式 1:1 复刻 `SessionEditView`（同一套手工 VStack + roundedBorder 名称框 + TextEditor 命令框 +
/// 透明背景透出座舱深色 sheet + Return 保存），两个表单视觉完全统一。命令可多行（TextEditor
/// 内回车换行，发送时按「每行一条」逐行执行）。
struct QuickCommandEditView: View {
    private let id: UUID
    private let isNew: Bool
    var onSave: (QuickCommand) -> Void
    var onCancel: () -> Void

    @State private var label: String
    @State private var command: String
    @State private var errorText: String?

    init(command: QuickCommand?,
         onSave: @escaping (QuickCommand) -> Void,
         onCancel: @escaping () -> Void) {
        let c = command ?? QuickCommand(label: "", command: "")
        self.id = c.id
        self.isNew = command == nil
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: c.label)
        _command = State(initialValue: c.command)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "新建快捷命令" : "编辑快捷命令").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称（快捷条按钮文字）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("如 重启 nginx", text: $label)
                    .consoleFieldBox()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("命令（可多行，每行一条逐行执行）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $command)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .consoleEditorBox()
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

    private func save() {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { errorText = "名称不能为空"; return }
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { errorText = "命令不能为空"; return }
        onSave(QuickCommand(id: id, label: l, command: c))
    }
}
#endif
