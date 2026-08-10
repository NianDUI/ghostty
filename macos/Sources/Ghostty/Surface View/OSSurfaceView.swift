import Foundation
import GhosttyKit
import SwiftUI

extension Ghostty {
    class OSSurfaceView: OSView, ObservableObject {
        typealias ID = UUID

        /// Unique ID per surface
        let id: UUID

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published var pwd: String?

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: CGSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Error?

        // The hovered URL string
        @Published var hoverUrl: String?

        // The progress report (if any)
        @Published var progressReport: Action.ProgressReport?

        // The currently active key tables. Empty if no tables are active.
        @Published var keyTables: [String] = []

        // The current search state. When non-nil, the search overlay should be shown.
        @Published var searchState: SearchState?

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        @Published var focusInstant: ContinuousClock.Instant?

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        @Published var surfaceSize: ghostty_surface_size_s?

        /// True when the surface is in readonly mode.
        @Published private(set) var readonly: Bool = false

        /// True when the surface should show a highlight effect (e.g., when presented via goto_split).
        @Published private(set) var highlighted: Bool = false

        /// A message sent from `ghostty_surface_t` when a child process exited
        @Published private(set) var childExitedMessage: ChildExitedMessage?

        /// Session sharing state for this surface.
        @Published var sharingState: SharingState = .idle

        /// Title suffix that should be appended to the window title for sharing status.
        @Published var sharingWindowTitleSuffix: String = ""

        var surface: ghostty_surface_t? {
            nil
        }

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeReadonly(_:)),
                name: .ghosttyDidChangeReadonly,
                object: self,
            )
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            NotificationCenter.default
                .removeObserver(self)
        }

        @objc private func ghosttyDidChangeReadonly(_ notification: Foundation.Notification) {
            guard let value = notification.userInfo?[Foundation.Notification.Name.ReadonlyKey] as? Bool else { return }
            readonly = value
        }

        /// Triggers a brief highlight animation on this surface.
        func highlight() {
            highlighted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.highlighted = false
            }
        }

        func setChildExitedMessage(_ message: ChildExitedMessage) {
            self.childExitedMessage = message
        }

        @MainActor
        func endSearch() {
            searchState = nil
        }

        // MARK: - Placeholders

        func focusDidChange(_ focused: Bool) {}

        func sizeDidChange(_ size: CGSize) {}
    }
}

extension Ghostty.OSSurfaceView {
    enum SharingState: Equatable {
        case idle
        case connecting
        case sharing
        /// `seconds` is the delay until the next reconnect attempt, so
        /// the badge can show "重连中（5s 后）" instead of a static
        /// "重连中...". Pass 0 for an immediate retry (e.g. the relay's
        /// 4401 token-expired fast path).
        case reconnecting(after: TimeInterval)
        case stopping
        case error(String)

        var statusText: String? {
            switch self {
            case .idle:
                return nil
            case .connecting:
                return "连接中"
            case .sharing:
                return "共享中"
            case .reconnecting(let seconds):
                // Guard on the *rounded* value, not `seconds > 0`: a sub-second
                // delay (e.g. 0.4) rounds to 0, and "重连中（0s 后）" claims a
                // delay that isn't there. Fall back to the "..." label instead.
                let rounded = Int(seconds.rounded())
                guard rounded > 0 else { return "重连中..." }
                return "重连中（\(rounded)s 后）"
            case .stopping:
                return "停止中"
            case .error:
                return "共享错误"
            }
        }

        var titleSuffix: String {
            guard let statusText else { return "" }
            return " [\(statusText)]"
        }

        var isActive: Bool {
            switch self {
            case .idle, .error:
                return false
            case .connecting, .sharing, .reconnecting, .stopping:
                return true
            }
        }
    }
}

// MARK: Search State

extension Ghostty.OSSurfaceView {
    @MainActor class SearchState: ObservableObject {
        /// The pasteboard used to persist the search needle.
        ///
        /// The `.find` pasteboard lets us sync our needle across the system and other find bars.
        private let pasteboard: OSPasteboard

        @Published private(set) var needle: String = ""
        @Published var selected: UInt?
        @Published var total: UInt?

        /// The range of the needle's text selection in the find bar.
        @Published private(set) var needleSelection: Range<String.Index>?

        init(
            from startSearch: Ghostty.Action.StartSearch,
            pasteboard: OSPasteboard = OSPasteboard.find
        ) {
            self.pasteboard = pasteboard
            if let needle = startSearch.needle, !needle.isEmpty {
                setNeedle(needle)
                writePasteboardNeedle()
            } else {
                readPasteboardNeedle()
            }
        }

        /// Replaces the search needle while keeping its selection valid.
        func setNeedle(_ needle: String, selectAll: Bool = false) {
            if needle != self.needle {
                // String.Index values are only valid for the string that created
                // them, so publish a nil selection before changing the string.
                needleSelection = nil
                self.needle = needle
            }

            if selectAll {
                needleSelection = self.needle.startIndex..<self.needle.endIndex
            }
        }

        /// Updates the selection only when both indices are valid for the needle.
        func setNeedleSelection(_ selection: Range<String.Index>?) {
            guard let selection else {
                needleSelection = nil
                return
            }

            guard
                let lowerBound = String.Index(selection.lowerBound, within: needle),
                let upperBound = String.Index(selection.upperBound, within: needle)
            else {
                needleSelection = nil
                return
            }

            needleSelection = lowerBound..<upperBound
        }

        func readPasteboardNeedle() {
            let pasteboardNeedle = pasteboard.string
            if let pasteboardNeedle, pasteboardNeedle != needle {
                setNeedle(pasteboardNeedle, selectAll: true)
            }
        }

        func writePasteboardNeedle() {
            pasteboard.string = needle
        }
    }

    func navigateSearchToNext() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:next"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
#if canImport(AppKit)
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
#endif
            return false
        }
        return true
    }

    func navigateSearchToPrevious() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:previous"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
#if canImport(AppKit)
            AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
#endif
            return false
        }
        return true
    }
}
