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
    private let groups: [ScopeGroup]
    private let bg: Color
    var onSave: (QuickCommand) -> Void
    var onCancel: () -> Void

    @State private var label: String
    @State private var command: String
    @State private var groupId: UUID?
    @State private var popupOpen = false
    @State private var errorText: String?

    init(command: QuickCommand?,
         groups: [ScopeGroup],
         bg: Color,
         defaultGroupId: UUID?,
         onSave: @escaping (QuickCommand) -> Void,
         onCancel: @escaping () -> Void) {
        // 新建时默认作用范围 = 当前会话直接所属分组（在某组下按 + 新增自然挂到该组）。
        let c = command ?? QuickCommand(label: "", command: "", groupId: defaultGroupId)
        self.id = c.id
        self.isNew = command == nil
        self.groups = groups
        self.bg = bg
        self.onSave = onSave
        self.onCancel = onCancel
        _label = State(initialValue: c.label)
        _command = State(initialValue: c.command)
        _groupId = State(initialValue: c.groupId)
    }

    /// 弹出列表行：全局 + 分组树。
    private var scopeRows: [ScopeRow] {
        [ScopeRow(title: "全局（所有会话）", value: .global)] + ScopeRow.from(groups)
    }

    /// 作用范围下拉的显示文案（递归找选中分组名）。
    private var scopeLabel: String {
        guard let groupId else { return "全局（所有会话）" }
        return Self.findName(groupId, in: groups) ?? "已删除的分组"
    }

    private static func findName(_ id: UUID, in groups: [ScopeGroup]) -> String? {
        for g in groups {
            if g.id == id { return g.name }
            if let n = findName(id, in: g.children) { return n }
        }
        return nil
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

            VStack(alignment: .leading, spacing: 4) {
                Text("作用范围").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { popupOpen = true } label: {
                    HStack {
                        Text(scopeLabel)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .consoleFieldBox()
                }
                .buttonStyle(.plain)
                .popover(isPresented: $popupOpen, arrowEdge: .bottom) {
                    ScopePopupList(rows: scopeRows, bg: bg,
                                   selected: groupId.map(ScopeValue.group) ?? .global) { value in
                        if case .group(let id) = value { groupId = id } else { groupId = nil }
                        popupOpen = false
                    }
                }
                Text("选某分组后，仅在「当前会话属于该分组（含子分组）」时，此命令才出现在快捷条；全局则始终显示。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        onSave(QuickCommand(id: id, label: l, command: c, groupId: groupId))
    }
}
#endif
