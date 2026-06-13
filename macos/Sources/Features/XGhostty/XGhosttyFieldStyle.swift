#if XGHOSTTY
import SwiftUI
import AppKit

/// 强制 Roman(ASCII)输入源的密码框：聚焦时系统自动把输入法切到英文、失焦还原，
/// 防止全角/中文标点混进 SSH 密码（曾因一个全角字符导致 13 字符密码变 15 字节、认证失败）。
/// 外观仍交给 `.consoleFieldBox()`——field 自身无边框透明，露出 SwiftUI 圆角背景。
struct ASCIISecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.wraps = false
            // 关键：限制输入源为 Roman → 聚焦自动切英文输入法（macOS 登录框同理）。
            cell.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            text.wrappedValue = f.stringValue
        }
    }
}

extension View {
    /// 座舱表单单行输入框外观：plain 文本 + 半透明圆角背景 + 细描边。
    ///
    /// 替代系统 `.roundedBorder`——后者的 `textBackgroundColor` bezel 在暗色下≈纯黑，铺在
    /// 终端色 sheet 上会突兀（用户反馈「单行输入框背景纯黑」）。仿 Ghostty 命令面板的
    /// `.textFieldStyle(.plain)` 做法，让输入框融入座舱主题；`Color.primary.opacity` 明暗自适配。
    func consoleFieldBox() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.18)))
    }

    /// 座舱表单多行文本框（TextEditor）外观：与 `consoleFieldBox` 同一套填充/描边，单行多行统一。
    func consoleEditorBox() -> some View {
        self
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.18)))
    }
}
#endif
