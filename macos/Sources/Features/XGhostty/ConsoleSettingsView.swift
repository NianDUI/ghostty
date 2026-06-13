#if XGHOSTTY
import SwiftUI

/// 座舱设置面板（⌘, 打开的 sheet）。当前含布局自动保存开关 + 还原默认布局。
/// 风格与 `SessionEditView` 一致（手工 VStack + 透明背景透出座舱 sheet 底色）。
struct ConsoleSettingsView: View {
    @State private var autoSave: Bool
    @State private var sortByName: Bool
    @State private var collapseDescendants: Bool
    @State private var collapseAllOnExit: Bool
    var onToggleAutoSave: (Bool) -> Void
    var onToggleSort: (Bool) -> Void
    var onToggleCollapseDescendants: (Bool) -> Void
    var onToggleCollapseAllOnExit: (Bool) -> Void
    var onResetLayout: () -> Void
    var onClose: () -> Void

    init(autoSave: Bool,
         sortByName: Bool,
         collapseDescendants: Bool,
         collapseAllOnExit: Bool,
         onToggleAutoSave: @escaping (Bool) -> Void,
         onToggleSort: @escaping (Bool) -> Void,
         onToggleCollapseDescendants: @escaping (Bool) -> Void,
         onToggleCollapseAllOnExit: @escaping (Bool) -> Void,
         onResetLayout: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        _autoSave = State(initialValue: autoSave)
        _sortByName = State(initialValue: sortByName)
        _collapseDescendants = State(initialValue: collapseDescendants)
        _collapseAllOnExit = State(initialValue: collapseAllOnExit)
        self.onToggleAutoSave = onToggleAutoSave
        self.onToggleSort = onToggleSort
        self.onToggleCollapseDescendants = onToggleCollapseDescendants
        self.onToggleCollapseAllOnExit = onToggleCollapseAllOnExit
        self.onResetLayout = onResetLayout
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("座舱设置").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("自动保存窗口布局", isOn: $autoSave)
                    .onChange(of: autoSave) { onToggleAutoSave($0) }
                Text("记住左树宽度、终端 / 快捷条 / 发送条分隔条位置、窗口尺寸与分组展开态，下次启动自动还原。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("会话树按名称排序", isOn: $sortByName)
                    .onChange(of: sortByName) { onToggleSort($0) }
                Text("开启后会话树按名称展示；关闭则按你拖拽的自定义顺序。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("折叠分组时同时折叠其子分组", isOn: $collapseDescendants)
                    .onChange(of: collapseDescendants) { onToggleCollapseDescendants($0) }
                Text("开启后折叠一个分组会连同它下面所有子分组一起收起，再展开时子分组也是收起的；关闭则只折叠本组、子分组保持原展开状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("退出应用后全部折叠", isOn: $collapseAllOnExit)
                    .onChange(of: collapseAllOnExit) { onToggleCollapseAllOnExit($0) }
                Text("开启后每次启动座舱时全部分组收起，不恢复上次的展开状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button("还原默认布局") { onResetLayout() }
                Text("把分隔条、窗口尺寸、分组展开态恢复到初始状态。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
#endif
