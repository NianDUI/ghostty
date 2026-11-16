import SwiftUI

/// This delegate is notified of the completion result of the clipboard confirmation dialog.
protocol ClipboardConfirmationViewDelegate: AnyObject {
    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, remember: Bool)
}

/// The SwiftUI view for showing a clipboard confirmation dialog.
struct ClipboardConfirmationView: View {
    enum Action: String {
        case cancel
        case confirm

        static func text(_ action: Action, _ reason: Ghostty.ClipboardRequest) -> String {
            switch (action, reason) {
            case (.cancel, .paste):
                return LocalizedString.text("Cancel")
            case (.cancel, .osc_52_read), (.cancel, .osc_52_write),
                 (.cancel, .kitty_read), (.cancel, .kitty_write):
                return LocalizedString.text("Deny")
            case (.confirm, .paste):
                return LocalizedString.text("Paste")
            case (.confirm, .osc_52_read), (.confirm, .osc_52_write),
                 (.confirm, .kitty_read), (.confirm, .kitty_write):
                return LocalizedString.text("Allow")
            }
        }
    }

    /// The contents of the paste.
    let contents: String

    /// The type of the clipboard request
    let request: Ghostty.ClipboardRequest

    /// True when the user's decision may be remembered as a session
    /// grant, showing the remember toggle.
    var canRemember: Bool = false

    /// An image decoded from the request contents, shown scaled in
    /// place of most of the text area when present.
    var previewImage: NSImage?

    /// Supplied by the controller so the sheet matches its terminal window.
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var previewBackgroundColor: Color = Color(nsColor: .textBackgroundColor)

    /// Optional delegate to get results. If this is nil, then this view will never close on its own.
    weak var delegate: ClipboardConfirmationViewDelegate?

    /// Whether the user's decision should be remembered for the session.
    @State private var remember: Bool = false

    /// Used to track if we should rehide on disappear
    @State private var cursorHiddenCount: UInt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 24))

                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedString.text(request == .paste
                        ? "Confirm Paste" : "Authorize Clipboard Access"))
                        .font(.headline)
                    Text(request.text())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
                    .padding(12)
                    .background(previewBackgroundColor, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: contents)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(minHeight: 196, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(height: 220)
                .background(previewBackgroundColor, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            }

            if canRemember {
                Toggle(LocalizedString.text("Remember this choice for the session"), isOn: $remember)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(Action.text(.cancel, request)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(Action.text(.confirm, request)) { onPaste() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity)
        .background(backgroundColor)
        .onAppear {
            // I can't find a better way to handle this. There is no API to detect
            // if the cursor is hidden and OTHER THINGS do unhide the cursor. So we
            // try to unhide it completely here and hope for the best. Issue #1516.
            cursorHiddenCount = Cursor.unhideCompletely()

            // If we didn't unhide anything, we just send an unhide to be safe.
            // I don't think the count can go negative on NSCursor so this handles
            // scenarios cursor is hidden outside of our own NSCursor usage.
            if cursorHiddenCount == 0 {
                _ = Cursor.unhide()
            }
        }
        .onDisappear {
            // Rehide if we unhid
            for _ in 0..<cursorHiddenCount {
                Cursor.hide()
            }
        }
    }

    private func onCancel() {
        delegate?.clipboardConfirmationComplete(.cancel, remember: false)
    }

    private func onPaste() {
        delegate?.clipboardConfirmationComplete(.confirm, remember: remember)
    }
}
