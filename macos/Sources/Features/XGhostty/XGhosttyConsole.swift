#if XGHOSTTY
import Cocoa
import SwiftUI
import Combine
import GhosttyKit
import UniformTypeIdentifiers

/// 可见、易抓取的分隔条：6px 厚 + 淡灰色，深色背景上看得见也拖得动。
/// 经典 frame 模式（panes 用 translatesAutoresizingMaskIntoConstraints=true，
/// 由 split 直接设 frame）下，拖拽稳定，不与 NSHostingView 固有尺寸打架。
private final class ConsoleSplitView: NSSplitView {
    // 2px 实心分隔条：自绘填色，与批量发送条顶部线同宽；命中区 = thickness，拖拽稳定。
    override var dividerThickness: CGFloat { 2 }
    override func drawDivider(in rect: NSRect) {
        NSColor(white: 1.0, alpha: 0.16).setFill()
        rect.fill()
    }
}

extension Ghostty.SurfaceView {
    /// 座舱 ⌘F：确保 searchState 存在（空 needle），随后交给 Ghostty 原生 `SurfaceSearchOverlay`
    /// 接管输入 / 计数 / 上下翻页 / Esc。`total`/`selected` 由 C 回调回填到 searchState。
    func xghosttyStartSearch() {
        guard searchState == nil else { return }
        var c = ghostty_action_start_search_s()
        c.needle = nil
        searchState = Ghostty.OSSurfaceView.SearchState(
            from: Ghostty.Action.StartSearch(c: c))
    }
}


/// 左树交互回调集合（穿过递归 view 一路传到 controller）。
/// 作用范围 / 分组广播下拉的树形分组项（可折叠 submenu 用：有子组的渲染成子菜单）。
struct ScopeGroup: Identifiable {
    let id: UUID
    let name: String
    let children: [ScopeGroup]
}

private struct SessionTreeActions {
    var onOpen: (SessionNode) -> Void
    var onOpenSFTP: (SessionNode) -> Void        // 打开 SFTP 文件传输标签（右键）
    var onClose: (SessionNode) -> Void
    var onToggleGroup: (UUID) -> Void
    var onEdit: (SessionNode) -> Void
    var onDelete: (SessionNode) -> Void
    var onAddChild: (SessionNode, Bool) -> Void   // (父分组, 新建的是否为分组)
    var onAddRoot: (Bool) -> Void                 // 根级新建（是否为分组）
    var onCopy: (SessionNode) -> Void             // 复制到剪贴板
    var onPasteInto: (SessionNode) -> Void        // 分组→粘进内部；会话→粘为同级
    var onPasteRoot: () -> Void                   // 工具条：粘到根
    var onClick: (SessionNode, NSEvent.ModifierFlags) -> Void  // 单击选中（读修饰键多选）
    var onSwitch: (SessionNode) -> Void           // 切到已打开的会话（右键）
    var onCopySelected: () -> Void                // 批量复制选中
    var onDeleteSelected: () -> Void              // 批量删除选中
    var onOpenSelected: () -> Void                // 批量打开选中
    var onOpenGroupDirect: (SessionNode) -> Void  // 打开分组下一级会话
    var onOpenGroupAll: (SessionNode) -> Void     // 打开分组全部子集会话（递归）
    var onDrop: (UUID, SessionNode, DropPosition) -> Void   // 拖拽：把 dragged 移到 target 的前/后/内
    var onSettings: () -> Void                    // 打开座舱设置
    var onCredentials: () -> Void                 // 打开密码库
    var onJumpHosts: () -> Void                   // 打开跳板机管理
    var onWorkspaces: () -> Void                  // 打开工作区管理
    var onImport: (ImportSource) -> Void          // 从 WindTerm / XShell 导入会话
    var onExpandAll: () -> Void                   // 展开全部分组
    var onCollapseAll: () -> Void                 // 折叠全部分组
    var onExpandLevel: (SessionNode) -> Void      // 展开本级（只展开该分组一层，子组不递归）
    var onExpandSubtree: (SessionNode) -> Void    // 展开该分组的全部子组
    var onCollapseSubtree: (SessionNode) -> Void  // 折叠该分组的全部子组
}

/// 拖拽落点相对目标行的位置：之前（同级）/ 之后（同级）/ 移入（仅分组）。
private enum DropPosition { case before, after, into }

/// 会话树行拖拽落点代理：按落点在行内的纵向位置判定 before/after/into，驱动插入线 / 移入高亮。
private struct TreeDropDelegate: DropDelegate {
    let target: SessionNode
    let rowHeight: CGFloat
    @Binding var dragging: UUID?
    @Binding var dropTargetId: UUID?
    @Binding var dropPosition: DropPosition
    let onDrop: (UUID, SessionNode, DropPosition) -> Void

    /// 上 30% = 之前；下 30% = 之后；中间 40% → 分组移入、会话视为之后。
    private func position(_ info: DropInfo) -> DropPosition {
        let y = info.location.y
        if y < rowHeight * 0.30 { return .before }
        if y > rowHeight * 0.70 { return .after }
        return target.isGroup ? .into : .after
    }

    func dropEntered(info: DropInfo) {
        dropTargetId = target.id
        dropPosition = position(info)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropTargetId = target.id
        dropPosition = position(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if dropTargetId == target.id { dropTargetId = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        let pos = position(info)
        defer { dragging = nil; dropTargetId = nil }
        guard let dragging, dragging != target.id else { return false }
        onDrop(dragging, target, pos)
        return true
    }
}

/// 单个会话 / 分组行。供树形与搜索结果复用。双击行为由调用方决定
/// （分组→展开折叠，叶子→打开会话）；右键菜单做增删改。
private struct SessionRowView: View {
    let node: SessionNode
    let isOpen: Bool            // 有打开的 tab（含连接中/尸体）——驱动「切到已打开/关闭」菜单
    let isConnected: Bool       // 真正登录成功（远端 shell 起来/本地 shell）——才点绿
    let isSelected: Bool        // 多选高亮
    let selectedCount: Int      // 当前总选中数（决定右键是否走批量菜单）
    let showHost: Bool          // 搜索态下叶子补一行 host
    let canPaste: Bool          // 剪贴板非空（显式 Bool 才能让 clipboard 变化触发菜单重渲染）
    let depth: Int              // 层级缩进
    let isExpanded: Bool        // 分组是否展开（画三角）
    let dropHint: DropPosition? // 拖拽落点提示（before/after 画插入线，into 画移入边框）
    let actions: SessionTreeActions

    private var batchMenu: Bool { isSelected && selectedCount > 1 }

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth) * 14) }
            if node.isGroup {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
                    .onTapGesture { actions.onToggleGroup(node.id) }   // 点三角折叠/展开
            } else {
                Spacer().frame(width: 14)
            }
            Image(systemName: node.isGroup ? "folder.fill" : (isConnected ? "terminal.fill" : "terminal"))
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1)
                if showHost, let host = node.host, !host.isEmpty, host != node.name {
                    Text(host).lineLimit(1).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3)         // 填满整行 + 小圆角
            .fill(isSelected ? Color.accentColor.opacity(0.30) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 3)           // 移入分组：整行边框
            .stroke(dropHint == .into ? Color.accentColor : Color.clear, lineWidth: 2))
        .overlay(alignment: .top) {                          // 插到之前：顶部插入线
            if dropHint == .before {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {                       // 插到之后：底部插入线
            if dropHint == .after {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        // 单击即时选中：simultaneousGesture 让 count:1 不必等 count:2 超时（消除选中延迟）。
        // 双击时会先触发一次单击选中、再触发打开，符合直觉。
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if node.isGroup { actions.onToggleGroup(node.id) } else { actions.onOpen(node) }
        })
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            actions.onClick(node, NSEvent.modifierFlags)
        })
        .contextMenu {
            if batchMenu {
                Button("打开选中 \(selectedCount) 项") { actions.onOpenSelected() }
                Divider()
                Button("复制选中 \(selectedCount) 项") { actions.onCopySelected() }
                Button("删除选中 \(selectedCount) 项", role: .destructive) { actions.onDeleteSelected() }
                if canPaste {
                    Divider()
                    Button(node.isGroup ? "粘贴到此分组" : "粘贴为同级") { actions.onPasteInto(node) }
                }
            } else if node.isGroup {
                Button("打开本级会话") { actions.onOpenGroupDirect(node) }
                Button("打开全部会话") { actions.onOpenGroupAll(node) }
                Divider()
                Button("展开本级") { actions.onExpandLevel(node) }
                Button("展开全部子组") { actions.onExpandSubtree(node) }
                Button("折叠全部子组") { actions.onCollapseSubtree(node) }
                Divider()
                Button("新建会话…") { actions.onAddChild(node, false) }
                Button("新建分组…") { actions.onAddChild(node, true) }
                Button("粘贴到此分组") { actions.onPasteInto(node) }
                    .disabled(!canPaste)
                Divider()
                Button("复制分组") { actions.onCopy(node) }
                Button("重命名分组…") { actions.onEdit(node) }
                Button("删除分组", role: .destructive) { actions.onDelete(node) }
            } else {
                Button("打开会话") { actions.onOpen(node) }          // 总是新开一个 tab
                if !node.isLocalShell {                              // 本地节点无 sftp 目标
                    Button("打开 SFTP") { actions.onOpenSFTP(node) }  // 新开 sftp 文件传输标签
                }
                if isOpen { Button("切到已打开") { actions.onSwitch(node) } }
                if isOpen { Button("关闭会话", role: .destructive) { actions.onClose(node) } }
                Divider()
                Button("复制会话") { actions.onCopy(node) }
                Button("粘贴为同级") { actions.onPasteInto(node) }
                    .disabled(!canPaste)
                Button("编辑…") { actions.onEdit(node) }
                Button("删除", role: .destructive) { actions.onDelete(node) }
            }
        }
    }
}

/// 扁平可见行（节点 + 层级深度），驱动会话树的 ScrollView 渲染。
private struct SessionTreeRow: Identifiable {
    let node: SessionNode
    let depth: Int
    var id: UUID { node.id }
}

/// 左侧会话树。无搜索：递归 DisclosureGroup（双击分组展开/折叠）；有搜索：过滤树（全展开）。
private struct SessionTreeView: View {
    let roots: [SessionNode]
    let openIds: Set<UUID>          // 有 tab（含连接中/尸体）——菜单用
    let connectedIds: Set<UUID>     // 登录成功——绿图标用
    let expandedIds: Set<UUID>
    let selectedIds: Set<UUID>
    let canPaste: Bool
    let sortByName: Bool
    let actions: SessionTreeActions

    @State private var query: String = ""
    @State private var dragging: UUID?               // 正在拖拽的节点
    @State private var dropTargetId: UUID?           // 当前拖拽落点行
    @State private var dropPosition: DropPosition = .into  // 落点相对位置

    var body: some View {
        VStack(spacing: 0) {
            // 搜索框：按名称 / IP 过滤。
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("搜索名称 / IP", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            // 扁平 ScrollView（非 List）：行距强制 0，选中块连续贴合；展开/缩进手动管。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleRows) { row in
                        SessionRowView(node: row.node,
                                       isOpen: openIds.contains(row.node.id),
                                       isConnected: connectedIds.contains(row.node.id),
                                       isSelected: selectedIds.contains(row.node.id),
                                       selectedCount: selectedIds.count,
                                       showHost: !query.isEmpty, canPaste: canPaste,
                                       depth: row.depth,
                                       isExpanded: expandedIds.contains(row.node.id),
                                       dropHint: dropTargetId == row.node.id ? dropPosition : nil,
                                       actions: actions)
                            .onDrag {
                                dragging = row.node.id
                                return NSItemProvider(object: row.node.id.uuidString as NSString)
                            } preview: {
                                // 透明 drag 预览：drop 后系统对 drag image 的淡出不可见 → 无尾影。
                                // 拖拽过程的反馈完全靠落点插入线 / 移入蓝框（跟手显示）。
                                Color.clear.frame(width: 1, height: 1)
                            }
                            .onDrop(of: [.text],
                                    delegate: TreeDropDelegate(
                                        target: row.node,
                                        rowHeight: query.isEmpty ? 25 : 34,
                                        dragging: $dragging,
                                        dropTargetId: $dropTargetId,
                                        dropPosition: $dropPosition,
                                        onDrop: actions.onDrop))
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }

            // 底部工具条：新建到根（＋ 弹菜单：会话 / 分组）。
            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("新建会话…") { actions.onAddRoot(false) }
                    Button("新建分组…") { actions.onAddRoot(true) }
                    Button("粘贴到根") { actions.onPasteRoot() }
                        .disabled(!canPaste)
                    Divider()
                    Button("从 WindTerm 导入…") { actions.onImport(.windterm) }
                    Button("从 XShell 导入…") { actions.onImport(.xshell) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button { actions.onExpandAll() } label: {
                    Image(systemName: "arrowtriangle.down.square")
                }
                .buttonStyle(.borderless)
                .help("展开全部分组")
                Button { actions.onCollapseAll() } label: {
                    Image(systemName: "arrowtriangle.right.square")
                }
                .buttonStyle(.borderless)
                .help("折叠全部分组")
                Spacer()
                Button { actions.onCredentials() } label: {
                    Image(systemName: "key")
                }
                .buttonStyle(.borderless)
                .help("密码库")
                Button { actions.onJumpHosts() } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .help("跳板机管理")
                Button { actions.onWorkspaces() } label: {
                    Image(systemName: "rectangle.stack")
                }
                .buttonStyle(.borderless)
                .help("工作区（保存/恢复一组会话）")
                Button { actions.onSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("座舱设置（⌘,）")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    /// 当前可见行（扁平 + 层级）：无搜索按 expandedIds 折叠，有搜索过滤树并全展开。
    private var visibleRows: [SessionTreeRow] {
        if query.isEmpty {
            return Self.flatten(roots, depth: 0, expanded: expandedIds, sortByName: sortByName)
        } else {
            return Self.flatten(filtered(roots), depth: 0, expanded: nil, sortByName: sortByName)
        }
    }

    private static func flatten(_ nodes: [SessionNode], depth: Int,
                                expanded: Set<UUID>?, sortByName: Bool) -> [SessionTreeRow] {
        // 按名称排序仅影响展示层（不动存储顺序）：分组在前、组内/会话按名称；关则按存储（拖拽）顺序。
        let ordered = sortByName
            ? nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            : nodes
        var out: [SessionTreeRow] = []
        for n in ordered {
            out.append(SessionTreeRow(node: n, depth: depth))
            if let c = n.children, expanded == nil || expanded!.contains(n.id) {
                out += flatten(c, depth: depth + 1, expanded: expanded, sortByName: sortByName)
            }
        }
        return out
    }

    /// 过滤树：保留匹配叶子 + 其祖先分组；分组名命中则整组保留。
    private func filtered(_ nodes: [SessionNode]) -> [SessionNode] {
        let q = query.lowercased()
        func match(_ n: SessionNode) -> Bool {
            n.name.lowercased().contains(q) || (n.host?.lowercased().contains(q) ?? false)
        }
        return nodes.compactMap { node -> SessionNode? in
            if let children = node.children {
                if match(node) { return node }          // 分组名命中 → 整组保留
                let fc = filtered(children)
                guard !fc.isEmpty else { return nil }
                var copy = node
                copy.children = fc
                return copy
            }
            return match(node) ? node : nil
        }
    }
}

/// 顶部会话 Tab 栏：每个已开会话一个 tab（终端图标 + 名称 + 关闭✕）；空白处双击新建本地 shell。
private struct SessionTabBar: View {
    enum State { case connecting, connected, exited }
    struct Tab: Identifiable { let id: UUID; let name: String; let state: State }
    let tabs: [Tab]
    let currentId: UUID?
    var onSelect: (UUID) -> Void
    var onClose: (UUID) -> Void
    var onNewTab: () -> Void

    private func tabIcon(_ s: State) -> String {
        switch s {
        case .connecting: return "terminal"
        case .connected: return "terminal.fill"
        case .exited: return "exclamationmark.triangle.fill"
        }
    }
    private func tabIconColor(_ s: State) -> Color {
        switch s {
        case .connecting: return .secondary
        case .connected: return .green
        case .exited: return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(tabs) { tab in
                        ZStack(alignment: .trailing) {
                            // 底层：点整条 tab → 选中。
                            Button { onSelect(tab.id) } label: {
                                HStack(spacing: 6) {
                                    // 灰=连接中/认证中；绿=登录成功存活；红=已断开/登录失败的尸体 tab。
                                    Image(systemName: tabIcon(tab.state))
                                        .font(.system(size: 10))
                                        .foregroundStyle(tabIconColor(tab.state))
                                    Text(tab.name).lineLimit(1).font(.system(size: 12))
                                        .foregroundStyle(tab.state == .exited ? Color.secondary : Color.primary)
                                    Color.clear.frame(width: 14)   // 给关闭 ✕ 留位
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // 顶层：关闭 ✕（独立 Button，命中区放大，盖在 select 之上才点得到）。
                            Button { onClose(tab.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).opacity(0.55)
                            .padding(.trailing, 4)
                        }
                        .background(tab.id == currentId ? Color.white.opacity(0.12) : Color.clear)
                        .overlay(alignment: .top) {
                            if tab.id == currentId {
                                Rectangle().fill(Color.accentColor).frame(height: 2)
                            }
                        }
                        .id(tab.id)   // 供 ScrollViewReader 定位（标签多时滚到当前）
                    }
                    // tab 右侧空白：双击新建本地 shell。
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onNewTab() }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: geo.size.width, maxHeight: .infinity, alignment: .leading)
            }
            // 当前标签变化（新开 / 切换）时滚到可视区——标签过多时焦点标签不再被挤出看不见。
            .onChange(of: currentId) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let id = currentId { proxy.scrollTo(id, anchor: .center) }
            }
            }
        }
    }
}

/// 底部快捷命令栏：最左 `+` 新增；每条命令一个按钮——左键发送（只当前会话）、
/// 右键菜单（编辑/删除）、长按拖动排序（三者共存，互不打架）。
private struct QuickCommandBar: View {
    let commands: [QuickCommand]
    var onRun: (QuickCommand) -> Void
    var onAdd: () -> Void
    var onEdit: (QuickCommand) -> Void
    var onDelete: (QuickCommand) -> Void
    var onReorder: ([QuickCommand]) -> Void

    // 本地可变顺序：拖拽时实时重排做动画；commands 变化（增删改）经 onChange 同步。
    @State private var ordered: [QuickCommand]
    @State private var dragging: QuickCommand?

    init(commands: [QuickCommand],
         onRun: @escaping (QuickCommand) -> Void,
         onAdd: @escaping () -> Void,
         onEdit: @escaping (QuickCommand) -> Void,
         onDelete: @escaping (QuickCommand) -> Void,
         onReorder: @escaping ([QuickCommand]) -> Void) {
        self.commands = commands
        self.onRun = onRun
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onReorder = onReorder
        _ordered = State(initialValue: commands)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { onAdd() } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("新增快捷命令")
                Divider().frame(height: 16)
                ForEach(ordered) { c in
                    Button(c.label) { onRun(c) }
                        .controlSize(.small)
                        .contextMenu {
                            Button("编辑…") { onEdit(c) }
                            Button("删除", role: .destructive) { onDelete(c) }
                        }
                        .onDrag {
                            dragging = c
                            return NSItemProvider(object: c.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: QuickReorderDelegate(
                                    item: c, items: $ordered, dragging: $dragging,
                                    onCommit: onReorder))
                }
                Spacer(minLength: 0)
            }
        }
        .onChange(of: commands) { newValue in ordered = newValue }
    }
}

/// 快捷条按钮拖动重排：手柄 onDrag 设 `dragging`，落点按钮 onDrop 实时移动；松手提交回写 store。
private struct QuickReorderDelegate: DropDelegate {
    let item: QuickCommand
    @Binding var items: [QuickCommand]
    @Binding var dragging: QuickCommand?
    let onCommit: ([QuickCommand]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id,
              let from = items.firstIndex(where: { $0.id == dragging.id }),
              let to = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            items.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onCommit(items)
        return true
    }
}

/// 批量发送目标选择器（替代系统 NSPopUpButton）：仿命令面板 `.menuStyle(.borderlessButton)`，
/// label 用与座舱输入框一致的半透明圆角背景 + chevron，深色主题协调。
/// 广播目标：当前会话 / 全部已开 / 某分组下已开的会话。
private enum BroadcastTarget: Equatable {
    case current
    case all
    case group(UUID)
}

private struct BroadcastTargetPicker: View {
    let label: String                              // 当前选中显示文案
    let groups: [ScopeGroup]                       // 分组树（可折叠，供选「分组广播」）
    let bg: Color                                  // 座舱终端背景色（自绘弹层用）
    let selected: ScopeValue                       // 当前选中（弹层打 ✓）
    var onCurrent: () -> Void
    var onAll: () -> Void
    var onGroup: (UUID) -> Void

    @State private var popupOpen = false

    /// 弹出列表行：当前会话 / 全部已开 + 分组树。
    private var rows: [ScopeRow] {
        [ScopeRow(title: "当前会话", value: .current),
         ScopeRow(title: "全部已开", value: .all)] + ScopeRow.from(groups)
    }

    var body: some View {
        Button { popupOpen = true } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $popupOpen, arrowEdge: .bottom) {
            ScopePopupList(rows: rows, bg: bg, selected: selected) { value in
                switch value {
                case .current: onCurrent()
                case .all: onAll()
                case .group(let id): onGroup(id)
                case .global: break
                }
                popupOpen = false
            }
        }
    }
}

/// 标签的连接方式：普通 ssh 登录 shell / sftp 文件传输会话。本地 shell（node==nil）按 .ssh 处理（无意义）。
private enum TabTransport { case ssh, sftp }

/// 一个打开的标签。nodeId 关联会话树节点（nil = tab 栏空白双击的临时本地 shell）。
/// 用独立 tabId 索引（而非 node.id），以支持同一会话/多个本地 shell 同时多开。
private final class OpenTab {
    let tabId: UUID
    let nodeId: UUID?
    let title: String
    let transport: TabTransport         // ssh / sftp（决定是否入群发、重连用哪种、连接判定方式）
    let surface: Ghostty.SurfaceView
    let scroll: SurfaceScrollView
    var exited = false                  // ssh 已断开/登录失败的「尸体 tab」
    var connected = false               // 真正登录成功（本地 shell 创建即真；ssh 等 OSC7 pwd；sftp 等 sftp> 提示符）
    var exitCancellable: AnyCancellable?
    var connectCancellable: AnyCancellable?   // ssh 首次 pwd（登录成功信号）订阅
    /// ⌘T 复制 ssh 会话时，等登录就绪后 cd 的一次性订阅。
    var pendingCancellable: AnyCancellable?
    /// expect 自动登录兜底（opt-in）：登录阶段监听 password: 自动答密码，连接成功/关闭时解除武装。
    var expect: ExpectAutoLogin?
    /// sftp「已连接」探测器（sftp 不发 OSC7，靠扫 `sftp>` 提示符判定）；命中后撤订阅置 nil。
    var sftpWatcher: SFTPReadyWatcher?
    /// ZMODEM(rz/sz)文件传输桥接器（开关开 + ssh 会话时常驻订阅，侦测触发头桥接本机 lrzsz）。
    var zmodem: ZmodemBridge?
    /// sftp 标签：不入「全部/分组」群发（sftp 提示符不接受 shell 命令，群发到它无意义且危险）。
    var isSFTP: Bool { transport == .sftp }
    init(tabId: UUID, nodeId: UUID?, title: String, transport: TabTransport,
         surface: Ghostty.SurfaceView, scroll: SurfaceScrollView) {
        self.tabId = tabId
        self.nodeId = nodeId
        self.title = title
        self.transport = transport
        self.surface = surface
        self.scroll = scroll
    }
}

/// 可成为 first responder 的 NSHostingView：点会话树后让树获取键盘焦点，
/// 这样 ⌘A 全选才不会被占着 first responder 的终端 surface 吞掉。
private final class FocusableHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
}

/// XGhostty 座舱：左会话树 + 顶部会话 Tab + 右终端 + 快捷栏 + 底部广播条。
class XGhosttyConsoleController: NSWindowController {
    /// 所有活动座舱窗口（⌘N 多窗口）。
    static private(set) var all: [XGhosttyConsoleController] = []

    private let ghostty: Ghostty.App
    private let store = SessionStore.shared
    private let layoutStore = LayoutStore.shared
    private var layoutSaveWork: DispatchWorkItem?   // 布局保存防抖
    private var titlePwdCancellable: AnyCancellable?   // 标题栏跟随当前终端目录

    private var treeHosting: NSHostingView<SessionTreeView>!
    private let surfaceContainer = NSView()
    private let exitBar = NSView()                   // ssh 断开/登录失败横幅（重连/关闭）
    private let exitBarLabel = NSTextField(labelWithString: "")
    private let zmodemOverlay = NSView()             // ZMODEM 传输期遮挡终端乱码的不透明浮层
    private let zmodemLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private let inputBg = NSView()              // 批量发送框的圆角背景容器（仿座舱输入框样式）
    private var targetMenuHosting: NSHostingView<BroadcastTargetPicker>!
    private var broadcastTarget: BroadcastTarget = .current   // 广播目标：当前 / 全部 / 某分组

    /// tabId -> 打开的标签（一会话可多开，故按 tabId 而非 node.id 索引）。
    private var tabs: [UUID: OpenTab] = [:]
    /// 标签顺序（驱动顶部 tab 栏）。
    private var tabOrder: [UUID] = []
    private var currentTabId: UUID?
    /// 已展开的分组（双击分组切换）；放 controller 避免 refreshTree 重置。
    private var expandedGroups: Set<UUID> = []
    private var tabBarHosting: NSHostingView<SessionTabBar>!
    private var quickBarHosting: NSHostingView<QuickCommandBar>!
    private var mainSplit: NSSplitView!
    private var rightSplit: NSSplitView!
    private var outerSplit: NSSplitView!
    private var sendBarView: NSView!

    // 终端搜索（⌘F 唤出，浮在终端右上角）
    private var searchOverlayHosting: NSView?   // Ghostty 原生搜索浮层（⌘F），nil = 未开
    private var keyMonitor: Any?
    /// 当前打开的会话编辑 sheet（增删改），由 controller 持有避免 view→sheet 循环引用。
    private var editorSheet: NSWindow?
    /// 会话/分组复制粘贴的剪贴板（深拷贝快照；粘贴时再换新 id）。支持批量。
    private var clipboard: [SessionNode] = []
    /// 会话树当前多选集合（普通单击单选、⌘单击多选、⇧范围选；批量复制/删除、⌘⌫）。
    private var selectedIds: Set<UUID> = []
    /// ⇧范围选的锚点（上一次单选/⌘选的位置）。
    private var selectionAnchor: UUID?

    private var currentSurface: Ghostty.SurfaceView? {
        guard let id = currentTabId else { return nil }
        return tabs[id]?.surface
    }

    static func presentInitial(ghostty: Ghostty.App) {
        if let existing = all.last {
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(ghostty: ghostty)
        }
    }

    /// ⌘N：新建一个 XGhostty 座舱窗口。
    @discardableResult
    static func newWindow(ghostty: Ghostty.App) -> XGhosttyConsoleController {
        let c = XGhosttyConsoleController(ghostty: ghostty)
        all.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        return c
    }

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "XGhostty 座舱"
        // 首个窗口还原上次保存的位置/尺寸；后续窗口居中（避免完全重叠）。
        if XGhosttyConsoleController.all.isEmpty,
           let frame = LayoutStore.shared.layout.windowFrame {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        // 分组展开态：「退出后全部折叠」开启 → 启动即全收起；否则有保存用保存的、没有则默认全展开。
        if layoutStore.layout.collapseAllOnExit == true {
            expandedGroups = []
        } else if let saved = layoutStore.layout.expandedGroups {
            expandedGroups = Set(saved)
        } else {
            expandedGroups = Set(allGroupIds(store.roots))
        }
        buildUI()
        applyTheme()
        updateBroadcastWarning()
        installKeyMonitor()
        // 启动会话：恢复上次会话集（若开关开）或默认开第一个，避免空白。
        restoreOrOpenInitialSession()
        // 初始分隔位置（延后到布局完成后）。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 有保存的分隔条位置用保存值，否则用代码默认。先定最外层再定内层，bounds 才准确。
            let l = self.layoutStore.layout
            let oh = self.outerSplit.bounds.height
            if oh > 0 { self.outerSplit.setPosition(l.topHeight ?? (oh - 40), ofDividerAt: 0) }
            self.outerSplit.layoutSubtreeIfNeeded()
            self.mainSplit.setPosition(l.treeWidth ?? 220, ofDividerAt: 0)
            self.mainSplit.layoutSubtreeIfNeeded()
            let rh = self.rightSplit.bounds.height
            if rh > 0 { self.rightSplit.setPosition(l.terminalHeight ?? (rh - 38), ofDividerAt: 0) }
            self.applyTitlebarTheme()   // 布局完成后标题栏视图才稳定，重应用一次
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        treeHosting = FocusableHostingView(rootView: makeTreeView())
        tabBarHosting = NSHostingView(rootView: makeTabBar())
        quickBarHosting = NSHostingView(rootView: makeQuickBar())
        surfaceContainer.wantsLayer = true

        inputField.stringValue = "echo XGHOSTTY_OK"
        // 多行输入：默认一行高（随 sendBar 高度，分隔条可拖高看多行）；⏎ 换行、⌘⏎ 发送。
        // 发送时多行会按「每行一条命令」逐行执行（见 sendBytes(for:)）。
        inputField.usesSingleLineMode = false
        inputField.maximumNumberOfLines = 0
        inputField.cell?.wraps = true
        inputField.cell?.isScrollable = false
        // 去系统 bezel（暗色下纯黑、突兀），改用 inputBg 圆角半透明背景包裹（仿命令面板 .plain）。
        inputField.isBezeled = false
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputBg.wantsLayer = true
        inputBg.layer?.cornerRadius = 6
        inputBg.layer?.borderWidth = 1
        // 背景色/边框色在 applyTheme 里按座舱 appearance 解析（CALayer 的 dynamic cgColor 不会
        // 自动跟随明暗，若此刻解析会按 light 出「6% 黑」→ 与 SwiftUI 输入框「6% 白」不一致）。
        targetMenuHosting = NSHostingView(rootView: makeTargetPicker())
        let sendBtn = NSButton(title: "发送 ⌘⏎", target: self, action: #selector(onBroadcast))
        sendBtn.bezelStyle = .rounded
        sendBtn.keyEquivalent = "\r"
        sendBtn.keyEquivalentModifierMask = [.command]   // ⌘⏎ 发送（让 ⏎ 留给多行换行）

        // ── 批量发送条（独立界面）：整窗宽，作为最外层竖 split 的下格 → 高度可拖 ──
        let sendBar = NSView()
        sendBar.wantsLayer = true
        sendBar.translatesAutoresizingMaskIntoConstraints = true   // outerSplit 的 pane，frame 由 split 管
        for v in [targetMenuHosting!, inputBg, sendBtn] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sendBar.addSubview(v)
        }
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputBg.addSubview(inputField)          // 文字框透明，inset 在圆角背景内（留 padding）
        NSLayoutConstraint.activate([
            targetMenuHosting.leadingAnchor.constraint(equalTo: sendBar.leadingAnchor, constant: 8),
            targetMenuHosting.centerYAnchor.constraint(equalTo: sendBar.centerYAnchor),
            targetMenuHosting.widthAnchor.constraint(equalToConstant: 124),
            targetMenuHosting.heightAnchor.constraint(equalToConstant: 30),

            // inputBg 充满发送条高度（留 6 margin）；拖高分隔条即可显示多行。最低一行高度。
            inputBg.leadingAnchor.constraint(equalTo: targetMenuHosting.trailingAnchor, constant: 8),
            inputBg.topAnchor.constraint(equalTo: sendBar.topAnchor, constant: 6),
            inputBg.bottomAnchor.constraint(equalTo: sendBar.bottomAnchor, constant: -6),
            inputBg.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            inputBg.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -8),

            // 文字框在背景容器内留内边距，文字不贴边。
            inputField.leadingAnchor.constraint(equalTo: inputBg.leadingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: inputBg.trailingAnchor, constant: -8),
            inputField.topAnchor.constraint(equalTo: inputBg.topAnchor, constant: 5),
            inputField.bottomAnchor.constraint(equalTo: inputBg.bottomAnchor, constant: -5),

            sendBtn.trailingAnchor.constraint(equalTo: sendBar.trailingAnchor, constant: -8),
            sendBtn.centerYAnchor.constraint(equalTo: sendBar.centerYAnchor),
            sendBtn.widthAnchor.constraint(equalToConstant: 96),
        ])

        // ── 右区竖 split（经典 frame 模式）：终端 | 终端宽快捷命令条 ──
        // 两个 pane 用 translatesAutoresizingMask=true，frame 全权交给 split，拖拽才稳。
        surfaceContainer.translatesAutoresizingMaskIntoConstraints = true
        quickBarHosting.translatesAutoresizingMaskIntoConstraints = true
        let rSplit = ConsoleSplitView()
        rSplit.isVertical = false                  // 横向分隔条 → 上下两格，可拖调终端高度
        rSplit.delegate = self
        rSplit.translatesAutoresizingMaskIntoConstraints = false   // 自身由约束钉在 rightColumn 内
        rSplit.addSubview(surfaceContainer)        // pane 0 = 终端（上）
        rSplit.addSubview(quickBarHosting)         // pane 1 = 快捷命令条（下）
        setupExitBar()                             // 终端容器顶部「会话已断开」横幅
        setupZmodemOverlay()                       // ZMODEM 传输期遮乱码的不透明浮层

        // ── 右栏：顶部 tab（固定）+ 竖 split（填充） ──
        let rightColumn = NSView()
        rightColumn.translatesAutoresizingMaskIntoConstraints = true   // mSplit 的 pane → split 管 frame
        tabBarHosting.translatesAutoresizingMaskIntoConstraints = false
        rightColumn.addSubview(tabBarHosting)
        rightColumn.addSubview(rSplit)
        NSLayoutConstraint.activate([
            tabBarHosting.topAnchor.constraint(equalTo: rightColumn.topAnchor),
            tabBarHosting.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            tabBarHosting.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            tabBarHosting.heightAnchor.constraint(equalToConstant: 34),
            rSplit.topAnchor.constraint(equalTo: tabBarHosting.bottomAnchor),
            rSplit.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            rSplit.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            rSplit.bottomAnchor.constraint(equalTo: rightColumn.bottomAnchor),
        ])

        // ── 主水平 split（经典 frame 模式）：左会话树 | 右栏，可拖调左树宽度 ──
        treeHosting.translatesAutoresizingMaskIntoConstraints = true   // mSplit 的 pane
        let mSplit = ConsoleSplitView()
        mSplit.isVertical = true                   // 纵向分隔条 → 左右两格
        mSplit.delegate = self
        mSplit.translatesAutoresizingMaskIntoConstraints = true   // outerSplit 的上格 pane
        mSplit.addSubview(treeHosting)             // pane 0 = 左树
        mSplit.addSubview(rightColumn)             // pane 1 = 右栏

        // ── 最外层竖 split：上部（左树+终端整块）| 批量发送条，分隔条可拖调发送条高度 ──
        let outerSplit = ConsoleSplitView()
        outerSplit.isVertical = false              // 横向分隔条 → 上下两格
        outerSplit.delegate = self
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        outerSplit.addSubview(mSplit)              // pane 0 = 上部
        outerSplit.addSubview(sendBar)             // pane 1 = 批量发送条

        content.addSubview(outerSplit)
        NSLayoutConstraint.activate([
            outerSplit.topAnchor.constraint(equalTo: content.topAnchor),
            outerSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outerSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outerSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        self.mainSplit = mSplit
        self.rightSplit = rSplit
        self.outerSplit = outerSplit
        self.sendBarView = sendBar
    }

    private func makeTreeView() -> SessionTreeView {
        SessionTreeView(
            roots: store.roots,
            openIds: Set(tabs.values.compactMap { $0.nodeId }),
            connectedIds: Set(tabs.values.filter { $0.connected && !$0.exited }.compactMap { $0.nodeId }),
            expandedIds: expandedGroups,
            selectedIds: selectedIds,
            canPaste: !clipboard.isEmpty,
            sortByName: layoutStore.layout.sortByName ?? false,
            actions: SessionTreeActions(
                onOpen: { [weak self] in self?.openSession($0) },
                onOpenSFTP: { [weak self] in self?.openSFTP($0) },
                onClose: { [weak self] in self?.closeSession($0) },
                onToggleGroup: { [weak self] in self?.toggleGroup($0) },
                onEdit: { [weak self] in self?.editNode($0) },
                onDelete: { [weak self] in self?.deleteNode($0) },
                onAddChild: { [weak self] parent, isGroup in
                    self?.presentEditor(forNew: isGroup, parentId: parent.id) },
                onAddRoot: { [weak self] isGroup in
                    self?.presentEditor(forNew: isGroup, parentId: nil) },
                onCopy: { [weak self] in self?.copyOne($0) },
                onPasteInto: { [weak self] in self?.pasteRelativeTo($0) },
                onPasteRoot: { [weak self] in self?.paste(intoParent: nil) },
                onClick: { [weak self] node, mods in self?.handleClick(node, mods) },
                onSwitch: { [weak self] in self?.switchToSession($0) },
                onCopySelected: { [weak self] in self?.copySelected() },
                onDeleteSelected: { [weak self] in self?.deleteSelected() },
                onOpenSelected: { [weak self] in self?.openSelected() },
                onOpenGroupDirect: { [weak self] in self?.openGroup($0, recursive: false) },
                onOpenGroupAll: { [weak self] in self?.openGroup($0, recursive: true) },
                onDrop: { [weak self] dragged, target, pos in
                    self?.handleDrop(dragged: dragged, onto: target, position: pos) },
                onSettings: { [weak self] in self?.presentSettings() },
                onCredentials: { [weak self] in self?.presentCredentials() },
                onJumpHosts: { [weak self] in self?.presentJumpHosts() },
                onWorkspaces: { [weak self] in self?.presentWorkspaces() },
                onImport: { [weak self] source in self?.presentImport(source) },
                onExpandAll: { [weak self] in self?.expandAllGroups() },
                onCollapseAll: { [weak self] in self?.collapseAllGroups() },
                onExpandLevel: { [weak self] in self?.expandLevel($0) },
                onExpandSubtree: { [weak self] in self?.setSubtreeExpanded($0, expanded: true) },
                onCollapseSubtree: { [weak self] in self?.setSubtreeExpanded($0, expanded: false) }))
    }

    /// 展开本级：只展开该分组一层（露出直接子项；内部子组保持收起）——分组右键「展开本级」。
    private func expandLevel(_ node: SessionNode) {
        guard node.isGroup else { return }
        expandedGroups.insert(node.id)
        refreshTree()
        scheduleSaveLayout()
    }

    /// 展开 / 折叠全部分组（左树底部按钮）。
    private func expandAllGroups() {
        expandedGroups = Set(allGroupIds(store.roots))
        refreshTree()
        scheduleSaveLayout()
    }

    private func collapseAllGroups() {
        expandedGroups = []
        refreshTree()
        scheduleSaveLayout()
    }

    /// 展开 / 折叠某分组的子树——分组右键「展开/折叠全部子组」。
    /// 展开：本组 + 全部后代分组都铺开；折叠：只收起后代子组、保留本组展开（仍看得到本组内容）。
    private func setSubtreeExpanded(_ node: SessionNode, expanded: Bool) {
        guard node.isGroup else { return }
        if expanded {
            expandedGroups.formUnion(allGroupIds([node]))            // 含自身，才看得到子组
        } else {
            expandedGroups.subtract(allGroupIds(node.children ?? []))  // 仅后代，本组保持展开
        }
        refreshTree()
        scheduleSaveLayout()
    }

    /// 拖拽落点处理：into=移进分组末尾（分组）；before/after=插到 target 同级的前/后。
    /// 多选拖拽：被拖节点在选区内且选区 >1 → 移动整批顶层选中节点（按树序保持视觉顺序）。
    /// 同步刷新（drag 预览已透明，不存在尾影问题；同步让顺序立即更新、不闪）。
    private func handleDrop(dragged: UUID, onto target: SessionNode, position: DropPosition) {
        let movers = (selectedIds.contains(dragged) && selectedIds.count > 1)
            ? orderedSelectedTopLevelIds()
            : [dragged]
        // 落点是被移动项之一 → 放弃（不能拖到自身/选区上）。
        guard !movers.contains(target.id) else { return }

        switch position {
        case .into where target.isGroup:
            for id in movers { store.move(id, toParent: target.id, atIndex: nil) }  // 顺序追加
            expandedGroups.insert(target.id)
        case .before:
            // 依次插到 target 前：每次以 target 为锚重算下标 → 最终为 movers 原序。
            for id in movers { insertSibling(id, near: target, after: false) }
        default:   // .after 或 .into 落到会话上
            // 逆序插到 target 后：每次紧贴 target 之后插入，逆序处理后恢复 movers 原序。
            for id in movers.reversed() { insertSibling(id, near: target, after: true) }
        }
        refreshTree()
        scheduleSaveLayout()
    }

    /// 选中集合里的「顶层」节点 id，按可见树序（多选拖拽保持视觉顺序）。
    private func orderedSelectedTopLevelIds() -> [UUID] {
        let top = Set(selectedTopLevel().map { $0.id })
        return visibleOrder().filter { top.contains($0) }
    }

    /// 把 dragged 插到 target 的同级（target 的父分组）前/后。
    /// move 先删后插：若与 target 同父且原本在 target 之前，删除会让 target 下标左移 1，插入点 -1。
    private func insertSibling(_ dragged: UUID, near target: SessionNode, after: Bool) {
        let parent = store.parentId(of: target.id)
        let targetIdx = store.indexInParent(of: target.id) ?? 0
        let sameParent = store.parentId(of: dragged) == parent
        let draggedIdx = store.indexInParent(of: dragged)
        var insertIdx = after ? targetIdx + 1 : targetIdx
        if sameParent, let di = draggedIdx, di < targetIdx { insertIdx -= 1 }
        store.move(dragged, toParent: parent, atIndex: insertIdx)
    }

    /// 双击分组：展开 / 折叠。
    private func toggleGroup(_ id: UUID) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
            // 设置「折叠时同时折叠子分组」（默认开启，nil 视为开）→ 连同后代子组一起收起。
            if layoutStore.layout.collapseDescendants != false, let node = store.find(id) {
                expandedGroups.subtract(allGroupIds(node.children ?? []))
            }
        } else {
            expandedGroups.insert(id)
        }
        refreshTree()
        scheduleSaveLayout()   // 展开态变化 → 持久化
    }

    private func allGroupIds(_ nodes: [SessionNode]) -> [UUID] {
        nodes.flatMap { n -> [UUID] in
            guard let c = n.children else { return [] }
            return [n.id] + allGroupIds(c)
        }
    }

    private func refreshTree() {
        treeHosting?.rootView = makeTreeView()
        // 选中的广播分组被删 → 回退到「当前会话」。
        if case .group(let id) = broadcastTarget, store.find(id) == nil {
            broadcastTarget = .current
        }
        targetMenuHosting?.rootView = makeTargetPicker()   // 分组增删改 → 刷新下拉
        updateBroadcastWarning()
    }

    private func makeTabBar() -> SessionTabBar {
        let bars = tabOrder.compactMap { id -> SessionTabBar.Tab? in
            guard let t = tabs[id] else { return nil }
            let state: SessionTabBar.State = t.exited ? .exited : (t.connected ? .connected : .connecting)
            return SessionTabBar.Tab(id: id, name: t.title, state: state)
        }
        return SessionTabBar(
            tabs: bars,
            currentId: currentTabId,
            onSelect: { [weak self] in self?.select($0) },
            onClose: { [weak self] in self?.closeTab($0) },
            onNewTab: { [weak self] in self?.newLocalShellTab() })
    }

    private func refreshTabBar() {
        tabBarHosting?.rootView = makeTabBar()
    }

    private func makeQuickBar() -> QuickCommandBar {
        QuickCommandBar(
            commands: visibleQuickCommands(),
            onRun: { [weak self] in self?.runQuickCommand($0) },
            onAdd: { [weak self] in self?.presentQuickCommandEditor(editing: nil) },
            onEdit: { [weak self] in self?.presentQuickCommandEditor(editing: $0) },
            onDelete: { [weak self] in self?.deleteQuickCommand($0) },
            onReorder: { [weak self] in self?.reorderVisibleQuickCommands($0) })
    }

    /// 当前会话可见的快捷命令 = 全局（groupId=nil）+ 当前会话所属分组链上的组级命令。
    private func visibleQuickCommands() -> [QuickCommand] {
        let ancestors = currentSessionAncestorGroupIds()
        return store.quickCommands.filter { $0.groupId == nil || ancestors.contains($0.groupId!) }
    }

    /// 当前会话所属的所有祖先分组 id（直接父组到根）。本地 shell / 无 node → 空集（只剩全局命令）。
    private func currentSessionAncestorGroupIds() -> Set<UUID> {
        guard let id = currentTabId, let nodeId = tabs[id]?.nodeId else { return [] }
        var out: Set<UUID> = []
        var cur = store.parentId(of: nodeId)
        while let p = cur { out.insert(p); cur = store.parentId(of: p) }
        return out
    }

    /// 当前会话的直接父分组（新建快捷命令时作默认作用范围）。
    private func currentSessionDirectParentGroupId() -> UUID? {
        guard let id = currentTabId, let nodeId = tabs[id]?.nodeId else { return nil }
        return store.parentId(of: nodeId)
    }

    /// 拖拽重排「可见子集」→ 合并回完整数组：可见项按新序填回其原槽位，隐藏项原位不动。
    private func reorderVisibleQuickCommands(_ reordered: [QuickCommand]) {
        let visibleIds = Set(reordered.map(\.id))
        var it = reordered.makeIterator()
        let merged = store.quickCommands.map { visibleIds.contains($0.id) ? (it.next() ?? $0) : $0 }
        store.setQuickCommands(merged)
    }

    private func refreshQuickBar() {
        quickBarHosting?.rootView = makeQuickBar()
    }

    private func makeTargetPicker() -> BroadcastTargetPicker {
        BroadcastTargetPicker(
            label: broadcastTargetLabel,
            groups: scopeGroupTree(),
            bg: consoleBgColor,
            selected: broadcastScopeValue,
            onCurrent: { [weak self] in self?.setBroadcastTarget(.current) },
            onAll: { [weak self] in self?.setBroadcastTarget(.all) },
            onGroup: { [weak self] id in self?.setBroadcastTarget(.group(id)) })
    }

    private func setBroadcastTarget(_ t: BroadcastTarget) {
        broadcastTarget = t
        targetMenuHosting?.rootView = makeTargetPicker()
        updateBroadcastWarning()
    }

    /// 广播目标下拉的显示文案。
    private var broadcastTargetLabel: String {
        switch broadcastTarget {
        case .current: return "当前会话"
        case .all: return "全部已开"
        case .group(let id): return "分组：\(store.find(id)?.name ?? "已删除")"
        }
    }

    /// 分组树（只含分组节点，保留父子层级），供「作用范围」/「分组广播」可折叠 submenu 下拉。
    private func scopeGroupTree() -> [ScopeGroup] {
        func build(_ nodes: [SessionNode]) -> [ScopeGroup] {
            nodes.compactMap { n in
                guard let c = n.children else { return nil }      // 只要分组节点
                return ScopeGroup(id: n.id, name: n.name, children: build(c))
            }
        }
        return build(store.roots)
    }

    /// 座舱终端背景色（自绘下拉弹层背景 = 此色，与主窗口一致）。
    private var consoleBgColor: Color {
        Color(nsColor: OSColor(ghostty.config.backgroundColor))
    }

    /// 当前广播目标 → 弹层选中值（打 ✓ 用）。
    private var broadcastScopeValue: ScopeValue {
        switch broadcastTarget {
        case .current: return .current
        case .all: return .all
        case .group(let id): return .group(id)
        }
    }

    /// 座舱左侧/底部与终端用同一主题（背景取终端背景色，明暗选 appearance）。
    private func applyTheme() {
        let bg = OSColor(ghostty.config.backgroundColor)
        window?.appearance = NSAppearance(named: bg.isLightColor ? .aqua : .darkAqua)
        window?.backgroundColor = bg
        if let content = window?.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = bg.cgColor
        }
        surfaceContainer.wantsLayer = true
        surfaceContainer.layer?.backgroundColor = bg.cgColor
        surfaceContainer.layer?.masksToBounds = true  // 防终端渲染溢出盖住下方快捷栏
        // 横幅必须不透明，否则下层终端文字会透出来和横幅文案糊在一起；
        // 用终端背景混一点固定红（非 dynamic systemRed，免 CALayer 明暗解析坑），既贴主题又遮挡。
        let barBase = bg.usingColorSpace(.sRGB) ?? bg
        let barRed = NSColor(srgbRed: 0.85, green: 0.26, blue: 0.26, alpha: 1)
        exitBar.layer?.backgroundColor = (barBase.blended(withFraction: 0.30, of: barRed) ?? barRed).cgColor
        zmodemOverlay.layer?.backgroundColor = bg.cgColor   // 浮层用终端背景色，遮挡时不突兀
        zmodemLabel.textColor = bg.isLightColor ? .black : .white

        // 顶部 tab 栏 / 快捷命令条 / 批量发送条给不透明背景，避免终端内容透出。
        tabBarHosting?.wantsLayer = true
        tabBarHosting?.layer?.backgroundColor = bg.cgColor
        quickBarHosting?.wantsLayer = true
        quickBarHosting?.layer?.backgroundColor = bg.cgColor
        sendBarView?.layer?.backgroundColor = bg.cgColor
        applyInputBgColors()
        applyTitlebarTheme()
    }

    /// 标题栏与窗口背景同色（仿 Ghostty `TransparentTitlebarTerminalWindow`，macOS 26 Tahoe 路径）：
    /// 透明标题栏 + 给 NSTitlebarView 染终端背景色 + 隐藏强制底色的 NSTitlebarBackgroundView。
    /// 系统在窗口激活/失活、布局变化时会重置标题栏视图，故 windowDidBecomeKey + 延迟也各重应用一次。
    private func applyTitlebarTheme() {
        guard let window else { return }
        let bgCG = window.backgroundColor.cgColor
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        guard let container = window.contentView?.superview?
                .firstDescendant(withClassName: "NSTitlebarContainerView") else { return }
        container.wantsLayer = true
        container.layer?.backgroundColor = bgCG
        if let titlebarView = container.firstDescendant(withClassName: "NSTitlebarView") {
            titlebarView.wantsLayer = true
            titlebarView.layer?.backgroundColor = bgCG
        }
        container.firstDescendant(withClassName: "NSTitlebarBackgroundView")?.isHidden = true
    }

    /// 批量发送框的半透明背景/边框，在座舱 appearance 上下文里解析 dynamic 色，
    /// 与 SwiftUI `consoleFieldBox`（primary.opacity 0.06/0.18）对齐，明暗一致。
    private func applyInputBgColors() {
        let run = {
            self.inputBg.layer?.backgroundColor =
                NSColor.labelColor.withAlphaComponent(0.06).cgColor
            self.inputBg.layer?.borderColor =
                NSColor.labelColor.withAlphaComponent(0.18).cgColor
        }
        if let ap = window?.appearance {
            ap.performAsCurrentDrawingAppearance(run)
        } else {
            run()
        }
    }

    // MARK: 布局持久化

    /// 当前窗口布局快照（窗口 frame + 三条分隔条位置 + 分组展开态）。
    private func captureLayout() -> ConsoleLayout {
        var l = layoutStore.layout
        if let w = window { l.windowFrame = w.frame }
        l.treeWidth = mainSplit?.subviews.first?.frame.width
        l.terminalHeight = rightSplit?.subviews.first?.frame.height
        l.topHeight = outerSplit?.subviews.first?.frame.height
        l.expandedGroups = Array(expandedGroups)
        return l
    }

    /// 防抖保存布局（拖分隔条 / 缩放/移动窗口 / 展开折叠时调用）。autoSave 关则跳过。
    private func scheduleSaveLayout() {
        guard layoutStore.layout.autoSave else { return }
        layoutSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layoutStore.save(self.captureLayout())
        }
        layoutSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// ⌘,：座舱设置 sheet（自动保存开关 + 还原默认布局）。
    @objc private func presentSettings() {
        let view = ConsoleSettingsView(
            autoSave: layoutStore.layout.autoSave,
            sortByName: layoutStore.layout.sortByName ?? false,
            collapseDescendants: layoutStore.layout.collapseDescendants ?? true,
            collapseAllOnExit: layoutStore.layout.collapseAllOnExit ?? false,
            sessionLogging: layoutStore.layout.sessionLogging ?? false,
            restoreLastSession: layoutStore.layout.restoreLastSession ?? false,
            expectAutoLogin: layoutStore.layout.expectAutoLogin ?? false,
            zmodemEnabled: layoutStore.layout.zmodemEnabled ?? false,
            onToggleAutoSave: { [weak self] on in
                self?.layoutStore.setAutoSave(on)
                if on { self?.scheduleSaveLayout() }
            },
            onToggleSort: { [weak self] on in
                self?.layoutStore.setSortByName(on)
                self?.refreshTree()
            },
            onToggleCollapseDescendants: { [weak self] on in
                self?.layoutStore.setCollapseDescendants(on)
            },
            onToggleCollapseAllOnExit: { [weak self] on in
                self?.layoutStore.setCollapseAllOnExit(on)
            },
            onToggleSessionLogging: { [weak self] on in
                self?.layoutStore.setSessionLogging(on)
            },
            onToggleRestoreLastSession: { [weak self] on in
                self?.layoutStore.setRestoreLastSession(on)
            },
            onToggleExpectAutoLogin: { [weak self] on in
                self?.layoutStore.setExpectAutoLogin(on)
            },
            onToggleZmodem: { [weak self] on in
                self?.layoutStore.setZmodemEnabled(on)
            },
            onViewLogs: { [weak self] in
                // 关设置 sheet 再开日志查看器（座舱单 editorSheet 槽，不嵌套）。
                self?.dismissEditor()
                DispatchQueue.main.async { self?.presentSessionLogViewer() }
            },
            onResetLayout: { [weak self] in self?.resetLayout() },
            onClose: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    /// 打开密码库管理 sheet（左下🔑）。
    @objc private func presentCredentials() {
        let view = CredentialLibraryView(onClose: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    /// 打开会话日志查看器 sheet（座舱设置「查看会话日志…」进入）。
    @objc private func presentSessionLogViewer() {
        let view = SessionLogViewerView(onClose: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    /// 打开工作区管理 sheet（左下 ▦）。
    @objc private func presentWorkspaces() {
        let view = WorkspaceLibraryView(
            currentSessionCount: currentOpenSessionIds().count,
            onOpen: { [weak self] w in self?.openWorkspace(w) },
            onSaveCurrent: { [weak self] name in self?.saveCurrentWorkspace(name: name) },
            onClose: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    /// 当前打开的会话节点 id（按 tab 顺序，只含有 nodeId 的会话；临时本地 shell 不计）。
    private func currentOpenSessionIds() -> [UUID] {
        tabOrder.compactMap { tabs[$0]?.nodeId }
    }

    /// 把当前打开的会话集存为新工作区。
    private func saveCurrentWorkspace(name: String) {
        WorkspaceStore.shared.add(Workspace(name: name, sessionIds: currentOpenSessionIds()))
    }

    /// 打开工作区：按存的顺序逐个 openSession（已删节点跳过；追加到现有 tab，不关已开的）。
    private func openWorkspace(_ w: Workspace) {
        for sid in w.sessionIds {
            if let node = store.find(sid), !node.isGroup { openSession(node) }
        }
    }

    /// 启动时决定开哪些会话：首个窗口 + 「恢复上次会话」开 + 有记录 → 恢复那组；
    /// 没恢复到任何会话（开关关 / 无记录 / 节点已删）→ 兜底开第一个，避免空白。
    private func restoreOrOpenInitialSession() {
        if XGhosttyConsoleController.all.isEmpty,
           layoutStore.layout.restoreLastSession == true,
           let last = layoutStore.layout.lastSessionIds, !last.isEmpty {
            for sid in last {
                if let node = store.find(sid), !node.isGroup { openSession(node) }
            }
        }
        if tabOrder.isEmpty, let first = store.allHosts.first { openSession(first) }
    }

    /// 打开跳板机管理 sheet（左下分叉图标）。
    @objc private func presentJumpHosts() {
        let view = JumpHostLibraryView(onClose: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    // MARK: 导入（WindTerm / XShell）

    /// 选目录 → 解析 → 二次确认 → 合并进会话树。密码不迁移（两边均加密存储）。
    private func presentImport(_ source: ImportSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择 \(source.displayName) 的会话目录"
        if let initial = defaultImportDirectory(for: source) { panel.directoryURL = initial }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 非沙盒应用其实直接可读；仍按安全作用域包裹一次，沙盒化时也安全。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let existing = CredentialLibrary.shared.credentials
        do {
            let result: ImportResult
            switch source {
            case .windterm:
                result = try XGhosttyImporter.importWindTerm(from: url, existingCredentials: existing)
            case .xshell:
                result = try XGhosttyImporter.importXshell(from: url, existingCredentials: existing)
            }
            confirmAndMergeImport(result, source: source)
        } catch {
            presentImportError(error, source: source)
        }
    }

    /// 各来源的默认起始目录（存在才用，否则交给系统默认）。
    private func defaultImportDirectory(for source: ImportSource) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate: URL
        switch source {
        case .windterm:
            candidate = home.appendingPathComponent(".wind", isDirectory: true)
        case .xshell:
            candidate = home
                .appendingPathComponent("WorkSpace/NetSarang/NetSarang Computer/8/Xshell/Sessions",
                                        isDirectory: true)
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// 二次确认后把导入分组追加到会话树根、新建密码库凭据（密码留空）、落盘、展开并刷新。
    private func confirmAndMergeImport(_ result: ImportResult, source: ImportSource) {
        let wrapperName = result.roots.first?.name ?? source.wrapperGroupName
        let credLine: String
        if result.credentials.isEmpty {
            credLine = "已复用密码库现有凭据。"
        } else {
            let names = result.credentials.map { $0.name }.joined(separator: "、")
            credLine = "已按登录身份创建 \(result.credentials.count) 条密码库凭据（\(names)），"
                + "去密码库给它们各填一次密码，所有引用会话即可自动登录。"
        }
        let alert = NSAlert()
        alert.messageText = "从 \(source.displayName) 导入 \(result.sessionCount) 个会话？"
        alert.informativeText = """
            将作为「\(wrapperName)」分组添加到会话树（含 \(result.groupCount) 个分组）。
            \(credLine)
            密文密码两边均无法解密，故凭据密码留空待填。
            """
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 先建凭据（密码留空），会话的 credentialId 已指向它们。
        for cred in result.credentials {
            CredentialLibrary.shared.upsert(cred, password: nil)
        }
        var roots = store.roots
        roots.append(contentsOf: result.roots)
        store.replace(roots: roots)
        for r in result.roots where r.isGroup { expandedGroups.insert(r.id) }
        refreshTree()
    }

    private func presentImportError(_ error: Error, source: ImportSource) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(source.displayName) 导入失败"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 还原默认布局：清空保存值 + 分隔条/窗口/展开态恢复初始。
    private func resetLayout() {
        layoutStore.resetLayout()
        expandedGroups = Set(allGroupIds(store.roots))
        refreshTree()
        window?.setContentSize(NSSize(width: 1000, height: 640))
        window?.center()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oh = self.outerSplit.bounds.height
            if oh > 0 { self.outerSplit.setPosition(oh - 40, ofDividerAt: 0) }
            self.outerSplit.layoutSubtreeIfNeeded()
            self.mainSplit.setPosition(220, ofDividerAt: 0)
            self.mainSplit.layoutSubtreeIfNeeded()
            let rh = self.rightSplit.bounds.height
            if rh > 0 { self.rightSplit.setPosition(rh - 38, ofDividerAt: 0) }
        }
        dismissEditor()
    }

    // MARK: 会话生命周期

    /// 双击树叶子 / 右键「打开会话」：总是新开一个 tab（允许同一会话多开）。
    func openSession(_ node: SessionNode) {
        openTab(node: node)
    }

    /// 右键「打开 SFTP」：总是新开一个 sftp 文件传输标签（与同会话的 ssh 标签并存）。
    func openSFTP(_ node: SessionNode) {
        openTab(node: node, transport: .sftp)
    }

    /// 右键「切到已打开」：已开则切到其首个 tab，否则新开。
    func switchToSession(_ node: SessionNode) {
        if let id = tabOrder.first(where: { tabs[$0]?.nodeId == node.id }) {
            select(id)
        } else {
            openTab(node: node)
        }
    }

    /// 一个会话解析出的有效认证。
    private struct ResolvedAuth {
        var identityFile: String?   // ssh -i（会话级路径 或 密钥凭据路径）
        var password: String?       // 密码登录（SSH_ASKPASS）
        var passphrase: String?     // 密钥 passphrase（SSH_ASKPASS）
        /// 注入 askpass 的秘密：密码或 passphrase（密钥无口令时为 nil）。
        var secret: String? { password ?? passphrase }
    }

    /// 解析会话认证：① 会话级密钥路径 > ② 引用的密码库凭据（密钥取路径+passphrase / 密码取密码）
    /// > ③ 会话内联密码（按 node.id）。本地 shell 返回空。
    private func resolveAuth(for node: SessionNode) -> ResolvedAuth {
        guard !node.isLocalShell else { return ResolvedAuth() }
        if let id = node.identityFile, !id.isEmpty {
            return ResolvedAuth(identityFile: id)
        }
        if let credId = node.credentialId,
           let cred = CredentialLibrary.shared.find(credId) {
            if cred.isKey {
                let pass = XGhosttyCredentialStore.shared.password(for: credId)   // passphrase（可空）
                return ResolvedAuth(identityFile: cred.keyPath, passphrase: pass)
            }
            return ResolvedAuth(password: XGhosttyCredentialStore.shared.password(for: credId))
        }
        return ResolvedAuth(password: XGhosttyCredentialStore.shared.password(for: node.id))
    }

    /// 新建一个标签。
    /// - node: nil 表示临时本地 shell（tab 栏空白双击）。
    /// - workingDirectory: 本地 cwd（本地 shell 复制时用）。
    /// - remoteInitial: 连上后发给（远端/本地）shell 的初始输入（如复制 ssh 会话后 cd 远端目录）。
    @discardableResult
    private func openTab(node: SessionNode?,
                         workingDirectory: String? = nil,
                         transport: TabTransport = .ssh) -> UUID? {
        guard let app = ghostty.app else { return nil }
        do {
            var cfg = Ghostty.SurfaceConfiguration()
            let title: String
            var expectPassword: String?   // 供 expect 兜底武装（仅密码会话、开关开时用）
            if let node {
                // 解析有效认证（会话级密钥 > 引用凭据[密钥/密码] > 内联密码）。
                // 密钥凭据的私钥路径并入 effective.identityFile，让命令构造器走 `ssh -i`。
                let auth = resolveAuth(for: node)
                expectPassword = auth.password
                var effective = node
                effective.identityFile = auth.identityFile
                // 引用式跳板：proxyJumpId → 跳板机清单条目，解析它自己的登录凭据。
                // 密钥→ProxyCommand 带 -i;密码→给跳板单独备一份 askpass(与目标机互不干扰);无凭据→默认密钥。
                var jump: SessionCommandBuilder.Jump?
                var jumpDisplay: String?
                if let jid = node.proxyJumpId, let jh = JumpHostStore.shared.find(jid),
                   let endpoint = SessionCommandBuilder.jumpEndpoint(for: jh) {
                    jumpDisplay = jh.endpointDisplay
                    var spec = SessionCommandBuilder.Jump(endpoint: endpoint, port: jh.port)
                    if let cid = jh.credentialId, let cred = CredentialLibrary.shared.find(cid) {
                        if cred.isKey {
                            spec.identityFile = cred.keyPath
                        } else if let pw = XGhosttyCredentialStore.shared.password(for: cid),
                                  let ap = XGhosttyAskpass.prepare(password: pw) {
                            spec.askpassEnv = ap.environment
                            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: ap.cleanup)
                        }
                    }
                    jump = spec
                }
                // 有密码 → 按会话的「仅用密码」开关选 strict/auto；无密码（密钥/无凭据）→ none。
                let policy: SessionCommandBuilder.PasswordPolicy =
                    auth.password == nil ? .none
                    : (node.passwordOnly == true ? .strict : .auto)
                // sftp 标签走 buildSFTP（换二进制 + 端口 -P + 去 OSC7 bootstrap），其余 ssh。
                let built = transport == .sftp
                    ? try SessionCommandBuilder.buildSFTP(for: effective, policy: policy, jump: jump)
                    : try SessionCommandBuilder.build(for: effective, policy: policy, jump: jump)
                if let cmd = built.command {
                    // 终端首行打印连接信息（本地 printf，暗灰色；不发给远端、不影响登录）。
                    // Ghostty 对 command 是 `exec -l <argv0>`，不能用 `;` 串联（否则只 exec 到
                    // printf、跑完即退 → tab 闪退），必须把「printf + ssh」整段裹进一个 sh -c 脚本。
                    let info = transport == .sftp
                        ? SessionCommandBuilder.displaySFTPCommand(for: effective, viaJump: jumpDisplay)
                        : SessionCommandBuilder.displayCommand(for: effective, viaJump: jumpDisplay)
                    if let info {
                        let script = "printf '\\033[2m%s\\033[0m\\n' \(Self.shellQuote(info)); " + cmd
                        cfg.command = "/bin/sh -c " + Self.shellQuote(script)
                    } else {
                        cfg.command = cmd
                    }
                }
                var env = built.environment
                // 秘密（密码或密钥 passphrase）经临时文件 + SSH_ASKPASS 注入（秘密不进环境变量，只传文件路径）。
                if let secret = auth.secret,
                   let askpass = XGhosttyAskpass.prepare(password: secret) {
                    env.merge(askpass.environment) { _, new in new }
                    // 兜底：20s 后删临时文件（脚本正常读后即自删；pubkey 等先成功则无人删）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: askpass.cleanup)
                }
                cfg.environmentVariables = env
                title = transport == .sftp ? "\(node.name) · SFTP" : node.name
                // 登录命令是远端 shell 命令——只对 ssh 标签发；sftp> 提示符不接受它们，跳过。
                if transport == .ssh, !node.loginCommands.isEmpty {
                    cfg.initialInput = node.loginCommands.joined(separator: "\n") + "\n"
                }
                // ssh 退出/登录失败后保留终端（留尸 tab 展示错误），不闪退；由 handleProcessExited 接管。
                if built.command != nil { cfg.waitAfterCommand = true }
            } else {
                cfg.environmentVariables = SessionCommandBuilder.baseEnv
                title = "本地 shell"
            }
            if let workingDirectory, !workingDirectory.isEmpty {
                cfg.workingDirectory = workingDirectory
            }

            let sv = Ghostty.SurfaceView(app, baseConfig: cfg)
            // 用 SurfaceScrollView 包裹：它在 layout() 里把 frame 变化喂给 surface.sizeDidChange
            // （否则终端 grid 卡在初始尺寸，不随窗口缩放），同时提供 Ghostty 原生 scrollback 滚动条。
            let scroll = SurfaceScrollView(
                contentSize: surfaceContainer.bounds.size, surfaceView: sv)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.isHidden = true
            // 终端插到 exitBar 之下：保证「会话已断开」横幅（及更上层的 ⌘F 浮层）始终在终端之上。
            surfaceContainer.addSubview(scroll, positioned: .below, relativeTo: exitBar)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
            ])

            let tabId = UUID()
            let tab = OpenTab(tabId: tabId, nodeId: node?.id, title: title,
                              transport: node == nil ? .ssh : transport,
                              surface: sv, scroll: scroll)
            // 子进程退出（在终端里 exit / ssh 断开）→ 自动关闭该 tab。
            tab.exitCancellable = sv.$childExitedMessage
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.handleProcessExited(tabId) }
                }
            // 「已连接」标记（驱动绿图标）：本地 shell 创建即真；ssh 等远端首次上报 pwd
            // （OSC7，精确卡在登录成功——bootstrap 登录瞬间会 emit 一次），认证阶段保持灰。
            if node == nil || (node?.isLocalShell ?? true) {
                tab.connected = true
            } else if transport == .sftp {
                // sftp 不发 OSC7，靠扫描输出里首个 `sftp>` 提示符判定登录成功（经分发器，与日志/expect 并存）。
                let watcher = SFTPReadyWatcher { [weak self, weak tab] in
                    guard let tab, let watcher = tab.sftpWatcher else { return }
                    tab.connected = true
                    tab.surface.xghosttyRemoveOutputSink(key: watcher)   // 已就绪，撤探测订阅
                    tab.sftpWatcher = nil
                    tab.expect?.disarm()        // sftp 登录成功 → 解除 expect 武装
                    self?.refreshTree()
                    self?.refreshTabBar()
                }
                tab.sftpWatcher = watcher
                sv.xghosttyAddOutputSink(key: watcher) { [weak watcher] data in watcher?.feed(data) }
            } else {
                tab.connectCancellable = sv.$pwd
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .first()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak tab] _ in
                        tab?.connected = true
                        tab?.connectCancellable = nil
                        tab?.expect?.disarm()   // 登录成功 → 解除 expect 武装（防误答登录后的 sudo 等提示）
                        self?.refreshTree()
                        self?.refreshTabBar()
                    }
            }
            tabs[tabId] = tab
            tabOrder.append(tabId)
            // 会话日志：仅对远端（ssh）会话挂输出落盘（本地 shell 不记）；开关在座舱设置，默认关。
            if let node, !node.isLocalShell {
                SessionLogStore.shared.start(tabId: tabId, title: title, surface: sv)
            }
            // expect 自动登录兜底（opt-in，默认关）：仅密码会话武装。askpass 生效则终端无 password:
            // 提示、兜底静默；askpass 失效时监听到提示自动答密码。与日志/共享经分发器并存。
            if let pw = expectPassword, layoutStore.layout.expectAutoLogin == true {
                let expect = ExpectAutoLogin(surface: sv, password: pw)
                sv.xghosttyAddOutputSink(key: expect) { [weak expect] data in expect?.feed(data) }
                tab.expect = expect
            }
            // ZMODEM(rz/sz)文件传输（opt-in，默认关）：仅 ssh 远端会话武装；侦测到触发头桥接本机 lrzsz。
            // 与日志/共享/expect 经分发器并存（不互斥）。
            if let node, !node.isLocalShell, transport == .ssh,
               layoutStore.layout.zmodemEnabled == true {
                let bridge = ZmodemBridge(surface: sv) { [weak self] activity in
                    self?.handleZmodemActivity(activity)
                }
                sv.xghosttyAddOutputSink(key: bridge) { [weak bridge] data in bridge?.feed(data) }
                tab.zmodem = bridge
            }
            select(tabId)
            refreshTree()
            return tabId
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开会话「\(node?.name ?? "本地 shell")」"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
    }

    /// ⌘T：复制当前标签，并停在当前目录。
    private func duplicateCurrentTab() {
        guard let id = currentTabId, let tab = tabs[id] else { return }
        let pwd = tab.surface.pwd
        guard let nodeId = tab.nodeId, let node = store.find(nodeId) else {
            openTab(node: nil, workingDirectory: pwd)   // 临时本地 shell
            return
        }
        if node.isLocalShell {
            openTab(node: node, workingDirectory: pwd)
        } else {
            // ssh：本地 shell 立即就绪可用 workingDirectory，但 ssh 要等登录完成。
            // 故在新会话「登录就绪」（远端首次上报目录 OSC7）后才发 cd —— 避免 cd 在
            // ssh 认证阶段被吞；远端不上报目录则读不到目标、自然不 cd。
            guard let newId = openTab(node: node), let newTab = tabs[newId],
                  let pwd, !pwd.isEmpty else { return }
            newTab.pendingCancellable = newTab.surface.$pwd
                .compactMap { $0 }
                .first()
                .sink { [weak newTab] _ in
                    newTab?.surface.xghosttySendBytes(Data("cd \(Self.shellQuote(pwd))\r".utf8))
                    newTab?.pendingCancellable = nil
                }
        }
    }

    /// tab 栏空白双击：新建一个本地 shell。
    private func newLocalShellTab() {
        openTab(node: nil)
    }

    /// 单引号包裹 + 转义，安全拼进 `cd '…'`。
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 命令文本 → 发送字节：多行视为「每行一条命令」逐行执行（\n→\r），末尾补一个 \r。
    /// 用 send_bytes 直写 pty（绕过 bracketed-paste），故逐行 \r 会被远端 shell 当独立命令。
    private static func sendBytes(for command: String) -> Data {
        let normalized = command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
        let body = normalized.hasSuffix("\r") ? String(normalized.dropLast()) : normalized
        return Data((body + "\r").utf8)
    }

    /// 树右键“关闭会话”：关闭该会话的所有 tab。
    func closeSession(_ node: SessionNode) {
        for id in tabOrder.filter({ tabs[$0]?.nodeId == node.id }) { closeTab(id) }
    }

    func closeTab(_ tabId: UUID) {
        guard let tab = tabs[tabId] else { return }
        SessionLogStore.shared.stop(tabId: tabId, surface: tab.surface)   // 撤回调 + flush 关日志
        if let expect = tab.expect {                                      // 撤 expect 订阅 + 解除武装
            tab.surface.xghosttyRemoveOutputSink(key: expect)
            expect.disarm()
        }
        if let watcher = tab.sftpWatcher {                                // 撤 sftp「已连接」探测订阅
            tab.surface.xghosttyRemoveOutputSink(key: watcher)
        }
        if let bridge = tab.zmodem {                                      // 撤 ZMODEM 订阅 + 取消进行中的传输
            tab.surface.xghosttyRemoveOutputSink(key: bridge)
            bridge.teardown()
        }
        tab.scroll.removeFromSuperview()
        tabs[tabId] = nil
        tabOrder.removeAll { $0 == tabId }
        if currentTabId == tabId {
            currentTabId = nil
            if let next = tabOrder.last { select(next) } else { updateExitBar() }
        }
        refreshTree()
        refreshTabBar()
    }

    /// 子进程退出：
    /// - ssh 会话 → 保留「尸体 tab」展示错误（如 Permission denied）+ 顶部重连/关闭条，**不静默关闭**；
    /// - 本地 shell（用户敲 exit）→ 正常关闭，焦点落到剩余最后一个 tab，无 tab 则关窗口。
    private func handleProcessExited(_ tabId: UUID) {
        guard let tab = tabs[tabId] else { return }
        if let nodeId = tab.nodeId, let node = store.find(nodeId), !node.isLocalShell {
            tab.exited = true
            refreshTabBar()
            refreshTree()       // 树图标由绿转灰（不再算「已连接」）
            if tabId == currentTabId { updateExitBar() }
            return
        }
        closeTab(tabId)
        if tabOrder.isEmpty { window?.close() }
    }

    /// 终端容器顶部挂「会话已断开」横幅（默认隐藏；ssh 退出/失败时显示，带重连/关闭）。
    private func setupExitBar() {
        exitBar.wantsLayer = true
        exitBar.translatesAutoresizingMaskIntoConstraints = false
        exitBar.isHidden = true

        exitBarLabel.translatesAutoresizingMaskIntoConstraints = false
        exitBarLabel.lineBreakMode = .byTruncatingTail
        exitBarLabel.font = .systemFont(ofSize: 12)

        let reconnect = NSButton(title: "重连", target: self, action: #selector(reconnectExitedTab))
        let close = NSButton(title: "关闭", target: self, action: #selector(closeExitedTab))
        for b in [reconnect, close] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
        }

        exitBar.addSubview(exitBarLabel)
        exitBar.addSubview(reconnect)
        exitBar.addSubview(close)
        surfaceContainer.addSubview(exitBar)

        NSLayoutConstraint.activate([
            exitBar.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
            exitBar.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
            exitBar.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            exitBar.heightAnchor.constraint(equalToConstant: 30),
            exitBarLabel.leadingAnchor.constraint(equalTo: exitBar.leadingAnchor, constant: 10),
            exitBarLabel.centerYAnchor.constraint(equalTo: exitBar.centerYAnchor),
            exitBarLabel.trailingAnchor.constraint(lessThanOrEqualTo: reconnect.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: exitBar.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: exitBar.centerYAnchor),
            reconnect.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            reconnect.centerYAnchor.constraint(equalTo: exitBar.centerYAnchor),
        ])
    }

    /// ZMODEM 传输期遮乱码的不透明浮层：盖满终端容器、居中提示，传输时显示、传完隐藏。
    private func setupZmodemOverlay() {
        zmodemOverlay.wantsLayer = true
        zmodemOverlay.translatesAutoresizingMaskIntoConstraints = false
        zmodemOverlay.isHidden = true

        zmodemLabel.translatesAutoresizingMaskIntoConstraints = false
        zmodemLabel.alignment = .center
        zmodemLabel.font = .systemFont(ofSize: 13, weight: .medium)
        zmodemLabel.lineBreakMode = .byTruncatingMiddle
        zmodemLabel.usesSingleLineMode = false       // 允许两行（文件名 + 提示）
        zmodemLabel.maximumNumberOfLines = 2

        zmodemOverlay.addSubview(zmodemLabel)
        surfaceContainer.addSubview(zmodemOverlay)   // 最后加 → 盖在终端与 exitBar 之上
        NSLayoutConstraint.activate([
            zmodemOverlay.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
            zmodemOverlay.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
            zmodemOverlay.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            zmodemOverlay.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
            zmodemLabel.centerXAnchor.constraint(equalTo: zmodemOverlay.centerXAnchor),
            zmodemLabel.centerYAnchor.constraint(equalTo: zmodemOverlay.centerYAnchor),
            zmodemLabel.leadingAnchor.constraint(greaterThanOrEqualTo: zmodemOverlay.leadingAnchor, constant: 20),
            zmodemLabel.trailingAnchor.constraint(lessThanOrEqualTo: zmodemOverlay.trailingAnchor, constant: -20),
        ])
    }

    /// 桥接器活动（主线程）：开始传输 → 显浮层遮乱码；结束 → 隐浮层（短延时等远端 Ctrl-L 重绘落地）。
    private func handleZmodemActivity(_ activity: ZmodemBridge.Activity) {
        switch activity {
        case .started(let dir, let label):
            let verb = dir == .download ? "接收" : "发送"
            zmodemLabel.stringValue = "ZMODEM \(verb)中：\(label)\n（传输期间请勿操作终端）"
            zmodemOverlay.isHidden = false
            surfaceContainer.addSubview(zmodemOverlay)   // 提到最上层（防新 tab 的 scroll 后插盖住）
        case .finished(let message):
            // 等远端 Ctrl-L 的重绘到达再撤浮层，避免一撤就露出旧乱码。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.zmodemOverlay.isHidden = true
            }
            if let message {
                let alert = NSAlert()
                alert.messageText = message
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    /// 按当前 tab 是否「尸体」刷新横幅显隐与文案。
    private func updateExitBar() {
        guard let id = currentTabId, let tab = tabs[id], tab.exited else {
            exitBar.isHidden = true; return
        }
        exitBarLabel.stringValue = "⚠ 「\(tab.title)」会话已断开或登录失败"
        exitBar.isHidden = false
    }

    @objc private func reconnectExitedTab() {
        guard let id = currentTabId, let tab = tabs[id], tab.exited,
              let nodeId = tab.nodeId, let node = store.find(nodeId) else { return }
        let transport = tab.transport       // sftp 尸体重连仍开 sftp，不退回 ssh
        closeTab(id)
        openTab(node: node, transport: transport)
    }

    @objc private func closeExitedTab() {
        guard let id = currentTabId else { return }
        closeTab(id)
        if tabOrder.isEmpty { window?.close() }
    }

    private func select(_ tabId: UUID) {
        for (k, t) in tabs { t.scroll.isHidden = (k != tabId) }
        currentTabId = tabId
        if let sv = tabs[tabId]?.surface { window?.makeFirstResponder(sv) }
        refreshTabBar()
        refreshQuickBar()         // 组级快捷命令随当前会话所属分组刷新
        // 窗口标题 = 当前 tab 名 + 当前目录；订阅 pwd 变化（OSC7 跟踪）实时更新。
        titlePwdCancellable = tabs[tabId]?.surface.$pwd
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateWindowTitle() }
        updateWindowTitle()
        updateExitBar()           // 切到的 tab 若是尸体则显横幅，否则隐藏
        // 搜索浮层绑定的是切换前的 surface，切 tab 时关闭它（避免悬挂在错误的终端上）。
        if searchOverlayHosting != nil { closeSearch() }
    }

    /// 窗口标题 =「当前会话名 — 当前目录（~ 缩写）」，无目录时仅会话名。
    private func updateWindowTitle() {
        guard let id = currentTabId, let tab = tabs[id] else {
            window?.title = "XGhostty 座舱"; return
        }
        if let pwd = tab.surface.pwd, !pwd.isEmpty {
            window?.title = "\(tab.title) · \((pwd as NSString).abbreviatingWithTildeInPath)"
        } else {
            window?.title = tab.title
        }
    }

    // MARK: 会话增删改（sheet）

    /// 新建：弹空白表单。`parentId == nil` 加到根，否则加到该分组下。
    private func presentEditor(forNew isGroup: Bool, parentId: UUID?) {
        let template = isGroup ? SessionNode(name: "", children: []) : SessionNode(name: "")
        presentEditor(node: template, isNew: true, parentId: parentId)
    }

    /// 编辑既有节点（重命名分组 / 改主机字段）。
    private func editNode(_ node: SessionNode) {
        presentEditor(node: node, isNew: false, parentId: nil)
    }

    /// 创建继承座舱主题的 sheet：appearance + **内容背景铺满座舱终端背景色**。
    /// 系统 sheet 默认深灰窗口材质，与纯黑座舱不一致；`window.backgroundColor` 会被
    /// NSHostingController 内容盖住不生效，故在 SwiftUI 内容外层显式铺一层座舱背景色。
    private func makeThemedSheet(_ rootView: some View) -> NSWindow {
        let bg = window?.backgroundColor ?? .windowBackgroundColor
        let host = NSHostingController(rootView: rootView.background(Color(nsColor: bg)))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = bg.cgColor
        let sheet = NSWindow(contentViewController: host)
        sheet.appearance = window?.appearance
        sheet.backgroundColor = bg
        return sheet
    }

    private func presentEditor(node: SessionNode, isNew: Bool, parentId: UUID?) {
        let view = SessionEditView(
            node: node,
            lockType: true,                       // 类型由「新建会话/分组」入口决定，表单内锁定
            onSave: { [weak self] updated in
                self?.commitEditor(updated, isNew: isNew, parentId: parentId)
            },
            onCancel: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    private func commitEditor(_ node: SessionNode, isNew: Bool, parentId: UUID?) {
        if isNew {
            store.add(node, toParent: parentId)
            if node.isGroup { expandedGroups.insert(node.id) }    // 新分组默认展开
        } else {
            store.update(node)
        }
        refreshTree()
        dismissEditor()
    }

    private func dismissEditor() {
        if let sheet = editorSheet { window?.endSheet(sheet) }
        editorSheet = nil
    }

    /// 单条快捷命令编辑（`+` 新增 existing=nil / 右键「编辑…」existing!=nil）。
    private func presentQuickCommandEditor(editing existing: QuickCommand?) {
        let view = QuickCommandEditView(
            command: existing,
            groups: scopeGroupTree(),
            bg: consoleBgColor,
            defaultGroupId: currentSessionDirectParentGroupId(),
            onSave: { [weak self] cmd in
                guard let self else { return }
                if existing == nil {
                    self.store.addQuickCommand(cmd)
                } else {
                    self.store.updateQuickCommand(cmd)
                }
                self.refreshQuickBar()
                self.dismissEditor()
            },
            onCancel: { [weak self] in self?.dismissEditor() })
        let sheet = makeThemedSheet(view)
        editorSheet = sheet
        window?.beginSheet(sheet)
    }

    /// 删除一条快捷命令（右键「删除」）；二次确认。
    private func deleteQuickCommand(_ c: QuickCommand) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除快捷命令「\(c.label)」？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeQuickCommand(c.id)
        refreshQuickBar()
    }

    /// 删除节点（分组连子树）；二次确认。
    private func deleteNode(_ node: SessionNode) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除\(node.isGroup ? "分组" : "会话")「\(node.name)」？"
        if node.isGroup, let c = node.children, !c.isEmpty {
            alert.informativeText = "该分组下的 \(c.count) 项也会一并删除。已打开的终端不受影响。"
        } else {
            alert.informativeText = "已打开的终端不受影响。"
        }
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Self.purgePasswords(in: node)
        store.remove(node.id)
        expandedGroups.remove(node.id)
        refreshTree()
    }

    /// 删除节点（含子树）前，清掉子树内所有主机的 Keychain 密码，避免留孤儿项。
    private static func purgePasswords(in node: SessionNode) {
        if node.isGroup {
            node.children?.forEach { purgePasswords(in: $0) }
        } else if !node.isLocalShell {
            XGhosttyCredentialStore.shared.removePassword(for: node.id)
        }
    }

    /// 「粘贴」相对某节点：分组→粘进其内部；会话→粘为其同级（粘到它所在的父分组）。
    private func pasteRelativeTo(_ node: SessionNode) {
        let parent = node.isGroup ? node.id : store.parentId(of: node.id)
        paste(intoParent: parent)
    }

    /// 把剪贴板内容（可批量）深拷贝（换新 id）后粘到指定分组（nil=根）。
    private func paste(intoParent parentId: UUID?) {
        guard !clipboard.isEmpty else { return }
        for src in clipboard {
            var idMap: [UUID: UUID] = [:]
            let copy = SessionStore.cloneWithNewIds(src, idMap: &idMap)
            store.add(copy, toParent: parentId)
            Self.copyPasswords(idMap: idMap)        // 把原节点的 Keychain 密码搬到新 id 下
            if copy.isGroup { expandedGroups.insert(copy.id) }
        }
        if let parentId { expandedGroups.insert(parentId) }    // 展开目标分组看到结果
        refreshTree()
    }

    /// 复制粘贴时把原节点的 Keychain 密码按「旧→新 id」映射搬到新节点（子树内所有主机）。
    private static func copyPasswords(idMap: [UUID: UUID]) {
        let store = XGhosttyCredentialStore.shared
        for (oldId, newId) in idMap {
            guard store.hasPassword(for: oldId),
                  let pw = store.password(for: oldId) else { continue }
            store.setPassword(pw, for: newId)
        }
    }

    // MARK: 多选 / 批量

    /// 单击行：普通=单选；⌘=切换多选；⇧=从锚点到当前的范围选。
    private func handleClick(_ node: SessionNode, _ mods: NSEvent.ModifierFlags) {
        if mods.contains(.shift), let anchor = selectionAnchor {
            let order = visibleOrder()
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: node.id) {
                selectedIds = Set(order[min(a, b)...max(a, b)])   // 区间全选；锚点不变
            } else {
                selectedIds = [node.id]; selectionAnchor = node.id
            }
        } else if mods.contains(.command) {
            if selectedIds.contains(node.id) { selectedIds.remove(node.id) }
            else { selectedIds.insert(node.id) }
            selectionAnchor = node.id
        } else {
            selectedIds = [node.id]
            selectionAnchor = node.id
        }
        // 点树即把键盘焦点移到树（脱离终端 surface），让随后的 ⌘A 全选生效。
        if let tree = treeHosting { window?.makeFirstResponder(tree) }
        refreshTree()
    }

    /// ⌘A：全选当前可见的会话行（焦点在树时；焦点在终端/文本框则不拦）。
    private func selectAllSessions() {
        let all = visibleOrder()
        guard !all.isEmpty else { return }
        selectedIds = Set(all)
        selectionAnchor = all.first
        refreshTree()
    }

    /// 当前可见行的有序 id（深度优先，仅展开的分组递归）。⇧范围选用。
    private func visibleOrder() -> [UUID] {
        var out: [UUID] = []
        func walk(_ nodes: [SessionNode]) {
            for n in nodes {
                out.append(n.id)
                if let c = n.children, expandedGroups.contains(n.id) { walk(c) }
            }
        }
        walk(store.roots)
        return out
    }

    /// 右键「复制会话/分组」：单个存入剪贴板。
    private func copyOne(_ node: SessionNode) {
        clipboard = [node]
        refreshTree()
    }

    /// 批量复制：取选中的顶层节点（祖先已选中的子节点跳过，避免重复）存入剪贴板。
    private func copySelected() {
        let nodes = selectedTopLevel()
        guard !nodes.isEmpty else { return }
        clipboard = nodes
        refreshTree()
    }

    /// 批量删除选中（分组连子树）；二次确认。
    private func deleteSelected() {
        guard !selectedIds.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除选中的 \(selectedIds.count) 项？"
        alert.informativeText = "分组会连同其下所有项一并删除。已打开的终端不受影响。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for id in selectedIds {
            if let node = store.find(id) { Self.purgePasswords(in: node) }
            store.remove(id)
        }
        expandedGroups.subtract(selectedIds)
        selectedIds.removeAll()
        refreshTree()
    }

    /// 选中集合里的「顶层」节点：祖先也被选中的节点跳过（复制时避免父子重复）。
    private func selectedTopLevel() -> [SessionNode] {
        selectedIds.compactMap { id -> SessionNode? in
            var p = store.parentId(of: id)
            while let pid = p {
                if selectedIds.contains(pid) { return nil }
                p = store.parentId(of: pid)
            }
            return store.find(id)
        }
    }

    /// 批量打开选中：选中的会话各开一个 tab；选中的分组递归开其下全部会话。
    private func openSelected() {
        for node in selectedTopLevel() {
            if node.isGroup { openGroup(node, recursive: true) }
            else { openTab(node: node) }
        }
    }

    /// 打开分组下的会话：recursive=false 只开直接子级会话，true 递归所有子集会话。
    private func openGroup(_ node: SessionNode, recursive: Bool) {
        guard let children = node.children else { openTab(node: node); return }
        for child in children {
            if child.children != nil {
                if recursive { openGroup(child, recursive: true) }
            } else {
                openTab(node: child)
            }
        }
    }

    // MARK: 广播

    /// 广播目标：按下拉选择（当前 / 全部 / 某分组）+ 三态过滤。
    private func broadcastTargets() -> [Ghostty.SurfaceView] {
        // sftp 标签一律排除在「全部 / 分组」群发外：sftp 提示符不接受 shell 命令，群发到它
        // 无意义且危险（如把 rm 打进文件传输会话）。`.current` 单发不排除——让用户能在底栏
        // 对着当前 sftp 会话直接敲 put/get 等 sftp 命令。
        let candidates: [Ghostty.SurfaceView]
        switch broadcastTarget {
        case .all:
            candidates = tabOrder.compactMap { tabs[$0] }
                .filter { !$0.isSFTP }.map { $0.surface }
        case .current:
            if let id = currentTabId, let sv = tabs[id]?.surface { candidates = [sv] }
            else { candidates = [] }
        case .group(let gid):
            let leaves = leafIds(inGroup: gid)                       // 该组下已开的会话
            candidates = tabOrder.compactMap { tabs[$0] }
                .filter { tab in !tab.isSFTP && (tab.nodeId.map { leaves.contains($0) } ?? false) }
                .map { $0.surface }
        }
        // 跳过已退出 / 密码输入态，避免命令打进密码框或丢进死会话。
        return candidates.filter { !$0.processExited && !$0.passwordInput }
    }

    /// 某分组子树下的所有叶子（会话）节点 id。
    private func leafIds(inGroup groupId: UUID) -> Set<UUID> {
        guard let group = store.find(groupId), let children = group.children else { return [] }
        var out: Set<UUID> = []
        func walk(_ nodes: [SessionNode]) {
            for n in nodes {
                if let c = n.children { walk(c) } else { out.insert(n.id) }
            }
        }
        walk(children)
        return out
    }

    /// 防误发：目标≠当前会话时红框 + 显示命中数。
    private func updateBroadcastWarning() {
        if broadcastTarget != .current {
            let n = broadcastTargets().count
            inputBg.layer?.borderColor = NSColor.systemRed.cgColor   // 固定色，无需 appearance 解析
            inputBg.layer?.borderWidth = 2
            inputField.placeholderString = "⚠️ 将广播到\(broadcastTargetLabel)的 \(n) 个会话 · ⌘⏎ 发送"
        } else {
            applyInputBgColors()                                     // 恢复 neutral 边框（按 appearance 解析）
            inputBg.layer?.borderWidth = 1
            inputField.placeholderString = "发到当前会话 · ⌘⏎ 发送 · ⏎ 换行"
        }
    }

    /// 广播：send_bytes + 回车；多目标且 >3 个二次确认。
    @objc private func onBroadcast() {
        let cmd = inputField.stringValue
        guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let targets = broadcastTargets()
        guard !targets.isEmpty else { return }
        if broadcastTarget != .current && targets.count > 3 {
            let alert = NSAlert()
            alert.messageText = "确认广播到\(broadcastTargetLabel)的 \(targets.count) 个会话？"
            alert.informativeText = "命令：\(cmd)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "发送")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let data = Self.sendBytes(for: cmd)
        for sv in targets { sv.xghosttySendBytes(data) }
        // 审计：只记真广播（全部/分组），单发当前会话不记（噪音大）。反查命中 tab 取会话名/host。
        if broadcastTarget != .current {
            let hit = tabOrder.compactMap { tabs[$0] }
                .filter { tab in targets.contains { $0 === tab.surface } }
                .map { (name: $0.title, host: $0.nodeId.flatMap { store.find($0)?.host }) }
            BroadcastAuditLog.shared.record(
                command: cmd, targetLabel: broadcastTargetLabel, targets: hit)
        }
    }

    /// 快捷命令：**只发当前会话**（不随广播目标下拉变化，避免点一下就喷所有机器）。
    private func runQuickCommand(_ c: QuickCommand) {
        guard let id = currentTabId, let sv = tabs[id]?.surface,
              !sv.processExited, !sv.passwordInput else { return }
        let data = Self.sendBytes(for: c.command)
        sv.xghosttySendBytes(data)
    }

    // MARK: 终端搜索（复用 Ghostty 原生 SurfaceSearchOverlay）

    /// ⌘F 切换：未开则给当前 surface 建 searchState 并挂原生搜索浮层；已开则关闭。
    @objc private func toggleSearch() {
        if searchOverlayHosting != nil { closeSearch() } else { openSearch() }
    }

    private func openSearch() {
        guard let sv = currentSurface else { return }
        sv.xghosttyStartSearch()
        guard let ss = sv.searchState else { return }
        // Ghostty 原生搜索浮层：needle 输入 / 计数 / 上下翻页 / Esc 全由它处理，样式与主 app 一致。
        let overlay = Ghostty.SurfaceSearchOverlay(
            surfaceView: sv,
            searchState: ss,
            onClose: { [weak self] in self?.closeSearch() })
        // 普通 NSHostingView：SwiftUI 自身的命中测试会让搜索条本体拦截、透明区返回 nil 穿透到终端，
        // 按钮（SwiftUI 绘制）也由 SwiftUI 内部正确分发——不能自行 override hitTest（会误杀按钮）。
        let hosting = NSHostingView(rootView: overlay)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        surfaceContainer.addSubview(hosting)   // 叠在终端最上层
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
        ])
        searchOverlayHosting = hosting
        // overlay 内部 @FocusState 在 onAppear 自动聚焦搜索框。
    }

    @objc private func closeSearch() {
        currentSurface?.endSearch()            // 清 searchState + 高亮
        searchOverlayHosting?.removeFromSuperview()
        searchOverlayHosting = nil
        if let sv = currentSurface { window?.makeFirstResponder(sv) }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let cmd = event.modifierFlags.contains(.command)
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if cmd && ch == "t" {        // 复制当前标签并 cd 到当前目录
                self.duplicateCurrentTab()
                return nil
            }
            if cmd && ch == "n" {        // 新建 XGhostty 窗口
                XGhosttyConsoleController.newWindow(ghostty: self.ghostty)
                return nil
            }
            if cmd && ch == "f" {        // 终端查找
                self.toggleSearch()
                return nil
            }
            if cmd && ch == "," {        // ⌘, 座舱设置
                self.presentSettings()
                return nil
            }
            if cmd && ch == "w" {        // 关闭当前标签（无标签则关窗口）
                if let id = self.currentTabId {
                    self.closeTab(id)
                    if self.tabOrder.isEmpty { self.window?.close() }
                }
                return nil
            }
            if cmd && ch == "a" {        // ⌘A 全选会话（焦点在终端/文本框时不拦，交给它们）
                if let r = self.window?.firstResponder as? NSView,
                   r.isDescendant(of: self.surfaceContainer) {
                    return event         // 焦点在终端 → ⌘A 交给终端
                }
                if self.window?.firstResponder is NSText { return event }  // 搜索框等 → 选文本
                self.selectAllSessions()
                return nil
            }
            if cmd && event.keyCode == 51 && !self.selectedIds.isEmpty {  // ⌘⌫ 删除选中会话
                self.deleteSelected()
                return nil
            }
            if event.modifierFlags.contains(.control), event.modifierFlags.contains(.shift),
               !cmd, ch == "s" {        // ⌃⇧S 共享此会话（主 app 同款；座舱主菜单项走不到响应链）
                self.currentSurface?.toggleSessionSharing(from: self.window)
                return nil
            }
            if event.keyCode == 53, self.searchOverlayHosting != nil {   // Esc 关搜索
                self.closeSearch()
                return nil
            }
            return event
        }
    }

}

// MARK: - 分隔条约束（经典 frame 模式下限定最小尺寸 + 缩窗口行为）

extension XGhosttyConsoleController: NSSplitViewDelegate {
    /// 分隔条能拖到的最小坐标（从顶/左算）。
    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === mainSplit { return 160 }      // 左树最窄
        if splitView === rightSplit { return 140 }     // 终端最矮
        if splitView === outerSplit { return 200 }     // 上部最矮
        return proposedMin
    }

    /// 分隔条能拖到的最大坐标。
    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === mainSplit { return splitView.bounds.width - 360 }   // 右栏至少 360
        if splitView === rightSplit { return splitView.bounds.height - 32 }  // 快捷条至少 32
        if splitView === outerSplit { return splitView.bounds.height - 40 }  // 发送条至少 40（≈一行输入框）
        return proposedMax
    }

    /// 窗口缩放时：左树宽度 / 快捷条高度 / 发送条高度保持不变，把空间全给终端区。
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        if splitView === mainSplit { return view !== treeHosting }
        if splitView === rightSplit { return view === surfaceContainer }
        if splitView === outerSplit { return view === mainSplit }
        return true
    }

    /// 分隔条拖动后 → 持久化布局（防抖）。
    func splitViewDidResizeSubviews(_ notification: Notification) {
        scheduleSaveLayout()
    }
}

// MARK: - 多窗口生命周期

extension XGhosttyConsoleController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 关窗口前 flush 一次布局（防抖有 0.4s 延迟，拖完立即关可能没存上）。
        if layoutStore.layout.autoSave { layoutStore.save(captureLayout()) }
        // 记录当前会话集，供下次「启动恢复上次会话」。
        layoutStore.setLastSessionIds(currentOpenSessionIds())
        XGhosttyConsoleController.all.removeAll { $0 === self }
    }

    /// 系统在窗口激活时会重置标题栏外观 → 重新染成终端背景色，保持标题栏与窗口同色。
    func windowDidBecomeKey(_ notification: Notification) {
        applyTitlebarTheme()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleSaveLayout()
    }

    func windowDidMove(_ notification: Notification) {
        scheduleSaveLayout()
    }
}
#endif
