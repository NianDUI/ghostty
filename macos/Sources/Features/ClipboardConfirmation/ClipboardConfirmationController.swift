import Foundation
import Cocoa
import SwiftUI

/// This initializes a clipboard confirmation warning window. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationController: NSWindowController {
    override var windowNibName: NSNib.Name? { "ClipboardConfirmation" }

    private(set) var confirmation: Ghostty.ClipboardConfirmationRequest
    weak private var delegate: ClipboardConfirmationViewDelegate?

    init(
        confirmation: Ghostty.ClipboardConfirmationRequest,
        delegate: ClipboardConfirmationViewDelegate
    ) {
        self.confirmation = confirmation
        self.delegate = delegate
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// Replace the request represented by the visible sheet without changing
    /// the sheet's focus state. The previous request is cancelled by its
    /// SurfaceView before this method is called.
    func replaceConfirmation(with confirmation: Ghostty.ClipboardConfirmationRequest) {
        guard self.confirmation !== confirmation else { return }
        self.confirmation = confirmation

        guard isWindowLoaded, let window else { return }
        configure(window)
    }

    // MARK: - NSWindowController

    override func windowDidLoad() {
        guard let window = window else { return }

        // AppKit otherwise ignores quit requests, including those from logout
        // and shutdown, for as long as this window is presented as a sheet.
        window.preventsApplicationTerminationWhenModal = false

        configure(window)
    }

    private func configure(_ window: NSWindow) {
        switch confirmation.kind {
        case .paste:
            window.title = LocalizedString.text("Warning: Potentially Unsafe Paste")
        case .osc_52_read, .osc_52_write, .kitty_read, .kitty_write:
            window.title = LocalizedString.text("Authorize Clipboard Access")
        }

        // A sheet has its own appearance and SwiftUI paints over the window
        // background. Pass the terminal theme through both layers, as the
        // other terminal settings sheets do.
        let parent = confirmation.surface?.window
        let background = parent?.backgroundColor
            ?? confirmation.surface.map { NSColor($0.derivedConfig.backgroundColor) }
            ?? .windowBackgroundColor
        let appearance = parent?.effectiveAppearance
            ?? NSAppearance(named: background.isLightColor ? .aqua : .darkAqua)
        let isDark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let previewBackground = background.blended(withFraction: 0.05, of: isDark ? .white : .black)
            ?? background
        window.appearance = appearance
        window.backgroundColor = background

        let hostingView = NSHostingView(rootView: ClipboardConfirmationView(
            contents: confirmation.contents,
            request: confirmation.kind,
            canRemember: confirmation.canRemember,
            previewImage: confirmation.previewImage,
            backgroundColor: Color(nsColor: background),
            previewBackgroundColor: Color(nsColor: previewBackground),
            delegate: delegate
        ).environment(\.colorScheme, isDark ? .dark : .light))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = background.cgColor
        window.contentView = hostingView
        let size = NSSize(width: 560, height: hostingView.fittingSize.height)
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 480, height: size.height)
    }
}
