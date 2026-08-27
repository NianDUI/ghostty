#if XGHOSTTY
import SwiftUI
import Foundation
import AppKit

/// 下拉选中值（作用范围 / 分组广播共用）。
enum ScopeValue: Equatable {
    case global      // 作用范围：全局
    case current     // 广播：当前会话
    case all         // 广播：全部已开
    case group(UUID) // 某分组
}

/// 弹出列表的一行：标题 + 选中值 + 子行（分组可折叠）。
struct ScopeRow: Identifiable {
    let id: UUID
    let title: String
    let value: ScopeValue
    let children: [ScopeRow]

    init(id: UUID = UUID(), title: String, value: ScopeValue, children: [ScopeRow] = []) {
        self.id = id
        self.title = title
        self.value = value
        self.children = children
    }

    /// 从分组树构建（每个分组可点标题选中 `.group(id)`、点 ▶ 展开子组）。
    static func from(_ groups: [ScopeGroup]) -> [ScopeRow] {
        groups.map { g in
            ScopeRow(id: g.id, title: g.name, value: .group(g.id), children: from(g.children))
        }
    }
}

/// 座舱自绘下拉弹出内容：背景/圆角/字体全座舱化（不走系统 NSMenu）。
/// 分组可折叠（▶/▼），点标题选中、点三角展开；hover 高亮，仿菜单手感。
/// 配 `.popover(isPresented:)` + 本视图的 `.presentationBackground` 使整个弹层 = 座舱终端色。
struct ScopePopupList: View {
    let rows: [ScopeRow]
    let bg: Color
    let selected: ScopeValue       // 当前选中值（打 ✓，仿系统组件）
    var onSelect: (ScopeValue) -> Void

    @State private var openSub: UUID?     // 当前在右侧弹出子浮层的父组（复刻系统 submenu 的 flyout）
    @State private var hovered: UUID?
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row($0) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 240)
        .frame(maxHeight: 360)
        .environment(\.colorScheme, NSColor(bg).isLightColor ? .light : .dark)
        .modifier(ScopePopupBackground(bg: bg))
        .onAppear {
            // 展示上次选择：选中项若在某父组子树里，自动展开它的子页（逐层 onAppear 接力到选中项）。
            if let r = rows.first(where: { !$0.children.isEmpty && Self.subtreeContains($0, selected) }) {
                openSub = r.id
            }
        }
    }

    /// selected 是否落在 r 的子树里（含 r 自身）。
    private static func subtreeContains(_ r: ScopeRow, _ value: ScopeValue) -> Bool {
        r.value == value || r.children.contains { subtreeContains($0, value) }
    }

    private func row(_ r: ScopeRow) -> some View {
        let isSel = r.value == selected
        let active = hovered == r.id || openSub == r.id
        return HStack(spacing: 6) {
            Text(r.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            // 有子组：右侧 ▸（系统 submenu 同款，提示鼠标停上去右边弹子页）。
            if !r.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 整行高亮（命令面板同款）：选中 = accent 蓝条；hover / 子页打开 = secondary 灰条。
        .background(RoundedRectangle(cornerRadius: 5).fill(
            isSel ? Color.accentColor.opacity(0.22)
            : active ? Color.secondary.opacity(0.18)
            : Color.clear))
        .onHover { inside in
            hoverWork?.cancel()
            if inside {
                hovered = r.id
                if r.children.isEmpty {
                    openSub = nil                                  // hover 叶子：立即收子页
                } else if openSub != r.id {
                    // hover 父组：延时 ~0.05s 再弹子页——只挡极快划过的误触发，几乎跟手。
                    let work = DispatchWorkItem { openSub = r.id }
                    hoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                }
            } else if hovered == r.id {
                hovered = nil
            }
        }
        .onTapGesture { onSelect(r.value) }
        // 子浮层：递归同一组件，弹在本行右侧（系统 submenu 的 flyout）。
        .popover(isPresented: Binding(
            get: { openSub == r.id && !r.children.isEmpty },
            set: { show in if !show, openSub == r.id { openSub = nil } }),
            arrowEdge: .trailing) {
            ScopePopupList(rows: r.children, bg: bg, selected: selected, onSelect: onSelect)
        }
    }
}

/// 把整个 popover 背景刷成命令面板同款：毛玻璃材质 + 终端色调混合（`.ultraThinMaterial`
/// 叠 `bg.blendMode(.color)`，仿 `CommandPalette.swift`）。13.3+ 用 `presentationBackground`
/// 覆盖整个弹层；更低版本 fallback 到内容 `.background`。
private struct ScopePopupBackground: ViewModifier {
    let bg: Color
    func body(content: Content) -> some View {
        if #available(macOS 13.3, *) {
            content.presentationBackground {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(bg).blendMode(.color)
                }
            }
        } else {
            content.background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(bg).blendMode(.color)
                })
        }
    }
}
#endif
