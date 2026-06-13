import AppKit
import Combine
import SwiftUI
import CoreText
import UserNotifications
import Security
import Network
import CryptoKit
import GhosttyKit

extension Ghostty {
    /// The NSView implementation for a terminal surface.
    class SurfaceView: OSSurfaceView, Codable, Identifiable {
        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published private(set) var title: String = "" {
            didSet {
                if !title.isEmpty {
                    titleFallbackTimer?.invalidate()
                    titleFallbackTimer = nil
                }
            }
        }

        // The progress report (if any)
        override var progressReport: Action.ProgressReport? {
            didSet {
                // Cancel any existing timer
                progressReportTimer?.invalidate()
                progressReportTimer = nil

                // If we have a new progress report, start a timer to remove it after 15 seconds
                if progressReport != nil {
                    progressReportTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                        self?.progressReport = nil
                        self?.progressReportTimer = nil
                    }
                }
            }
        }

        // The currently active key sequence. The sequence is not active if this is empty.
        @Published var keySequence: [KeyboardShortcut] = []

        // The current search state. When non-nil, the search overlay should be shown.
        override var searchState: SearchState? {
            didSet {
                if let searchState {
                    // I'm not a Combine expert so if there is a better way to do this I'm
                    // all ears. What we're doing here is grabbing the latest needle. If the
                    // needle is less than 3 chars, we debounce it for a few hundred ms to
                    // avoid kicking off expensive searches.
                    searchNeedleCancellable = searchState.$needle
                        .removeDuplicates()
                        .map { needle -> AnyPublisher<String, Never> in
                            if needle.isEmpty || needle.count >= 3 {
                                return Just(needle).eraseToAnyPublisher()
                            } else {
                                return Just(needle)
                                    .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                                    .eraseToAnyPublisher()
                            }
                        }
                        .switchToLatest()
                        .sink { [weak self] needle in
                            guard let surface = self?.surface else { return }
                            let action = "search:\(needle)"
                            ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                        }
                } else if oldValue != nil {
                    searchNeedleCancellable = nil
                    guard let surface = self.surface else { return }
                    let action = "end_search"
                    ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                }
            }
        }

        // Cancellable for search state needle changes
        private var searchNeedleCancellable: AnyCancellable?

        // Cancellable for the debounced accessibility selection-change post.
        private var accessibilitySelectionCancellable: AnyCancellable?

        // Whether the pointer should be visible or not
        @Published private(set) var pointerStyle: CursorStyle = .horizontalText

        // Whether the mouse is currently over this surface
        @Published private(set) var mouseOverSurface: Bool = false

        // The last known mouse location in the surface's local coordinate space,
        // used by overlays such as the split drag handle reveal region.
        @Published private(set) var mouseLocationInSurface: CGPoint?

        // Whether the cursor is currently visible (not hidden by typing, etc.)
        @Published private(set) var cursorVisible: Bool = true

        /// Whether the belonging window is visible
        ///
        /// We track this to restore surface occlusion state
        /// after this surface is dragged to another window
        var isWindowVisible = false

        /// The configuration derived from the Ghostty config so we don't need to rely on references.
        @Published private(set) var derivedConfig: DerivedConfig

        /// The background color within the color palette of the surface. This is only set if it is
        /// dynamically updated. Otherwise, the background color is the default background color.
        @Published private(set) var backgroundColor: Color?

        /// True when the bell is active. This is set inactive on focus or event.
        @Published private(set) var bell: Bool = false

        // An initial size to request for a window. This will only affect
        // then the view is moved to a new window.
        var initialSize: NSSize?

        // A content size received through sizeDidChange that may in some cases
        // be different from the frame size.
        private var contentSizeBacking: NSSize?
        private var contentSize: NSSize {
            get { return contentSizeBacking ?? frame.size }
            set { contentSizeBacking = newValue }
        }

        // Set whether the surface is currently on a password input or not. This is
        // detected with the set_password_input_cb on the Ghostty state.
        var passwordInput: Bool = false {
            didSet {
                // We need to update our state within the SecureInput manager.
                let input = SecureInput.shared
                let id = ObjectIdentifier(self)
                if passwordInput {
                    input.setScoped(id, focused: focused)
                } else {
                    input.removeScoped(id)
                }
            }
        }

        // Returns true if quit confirmation is required for this surface to
        // exit safely.
        var needsConfirmQuit: Bool {
            guard let surface = self.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }

        // Returns true if the process in this surface has exited.
        var processExited: Bool {
            guard let surface = self.surface else { return true }
            return ghostty_surface_process_exited(surface)
        }

        // Returns the inspector instance for this surface, or nil if the
        // surface has been closed or no inspector is active.
        var inspector: Ghostty.Inspector? {
            guard let surface = self.surface else { return nil }
            guard let cInspector = ghostty_surface_inspector(surface) else { return nil }
            return Ghostty.Inspector(cInspector: cInspector)
        }

        // True if the inspector should be visible
        @Published var inspectorVisible: Bool = false {
            didSet {
                if oldValue && !inspectorVisible {
                    guard let surface = self.surface else { return }
                    ghostty_inspector_free(surface)
                }
            }
        }

        /// Returns the data model for this surface.
        ///
        /// Note: eventually, all surface access will be through this, but presently its in a transition
        /// state so we're mixing this with direct surface access.
        private(set) var surfaceModel: Ghostty.Surface?

        /// Returns the underlying C value for the surface. See "note" on surfaceModel.
        override var surface: ghostty_surface_t? {
            surfaceModel?.unsafeCValue
        }
        /// Current scrollbar state, cached here for persistence across rebuilds
        /// of the SwiftUI view hierarchy, for example when changing splits
        var scrollbar: Ghostty.Action.Scrollbar?

        // Notification identifiers associated with this surface
        var notificationIdentifiers: Set<String> = []

        private lazy var sessionSharing = SessionSharingController(surfaceView: self)

        private var markedText: NSMutableAttributedString
        private(set) var focused: Bool = true
        private var prevPressureStage: Int = 0
        private var appearanceObserver: NSKeyValueObservation?

        // This is set to non-null during keyDown to accumulate insertText contents
        private var keyTextAccumulator: [String]?

        // True when we've consumed a left mouse-down only to move focus and
        // should suppress the matching mouse-up from being reported.
        private var suppressNextLeftMouseUp: Bool = false

        // A small delay that is introduced before a title change to avoid flickers
        private var titleChangeTimer: Timer?

        // A timer to fallback to ghost emoji if no title is set within the grace period
        private var titleFallbackTimer: Timer?

        // Timer to remove progress report after 15 seconds
        private var progressReportTimer: Timer?

        // This is the title from the terminal. This is nil if we're currently using
        // the terminal title as the main title property. If the title is set manually
        // by the user, this is set to the prior value (which may be empty, but non-nil).
        private var titleFromTerminal: String?

        // The cached contents of the screen.
        private(set) var cachedScreenContents: CachedValue<String>
        private(set) var cachedVisibleContents: CachedValue<String>

        /// Event monitor (see individual events for why)
        private var eventMonitor: Any?

        // We need to support being a first responder so that we can get input events
        override var acceptsFirstResponder: Bool { return true }

        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.markedText = NSMutableAttributedString()

            // Our initial config always is our application wide config.
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                self.derivedConfig = DerivedConfig(appDelegate.ghostty.config)
            } else {
                self.derivedConfig = DerivedConfig()
            }

            // We need to initialize this so it does something but we want to set
            // it back up later so we can reference `self`. This is a hack we should
            // fix at some point.
            self.cachedScreenContents = .init(duration: .milliseconds(500)) { "" }
            self.cachedVisibleContents = self.cachedScreenContents

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(id: uuid, frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            // Our cache of screen data
            cachedScreenContents = .init(duration: .milliseconds(500)) { [weak self] in
                guard let self else { return "" }
                guard let surface = self.surface else { return "" }
                var text = ghostty_text_s()
                let sel = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_SCREEN,
                        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                        x: 0,
                        y: 0),
                    bottom_right: ghostty_point_s(
                        tag: GHOSTTY_POINT_SCREEN,
                        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                        x: 0,
                        y: 0),
                    rectangle: false)
                guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
                defer { ghostty_surface_free_text(surface, &text) }
                return String(cString: text.text)
            }
            cachedVisibleContents = .init(duration: .milliseconds(500)) { [weak self] in
                guard let self else { return "" }
                guard let surface = self.surface else { return "" }
                var text = ghostty_text_s()
                let sel = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                        x: 0,
                        y: 0),
                    bottom_right: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                        x: 0,
                        y: 0),
                    rectangle: false)
                guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
                defer { ghostty_surface_free_text(surface, &text) }
                return String(cString: text.text)
            }

            // Set a timer to show the ghost emoji after 500ms if no title is set
            titleFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                if let self = self, self.title.isEmpty {
                    self.title = "👻"
                }
            }

            // A drag can emit multiple selection changes. Debounce so screen
            // readers hear one announcement once the selection settles.
            accessibilitySelectionCancellable = NotificationCenter.default
                .publisher(for: .ghosttySelectionDidChange, object: self)
                .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    NSAccessibility.post(element: self, notification: .selectedTextChanged)
                }

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(onUpdateRendererHealth),
                name: Ghostty.Notification.didUpdateRendererHealth,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidContinueKeySequence),
                name: Ghostty.Notification.didContinueKeySequence,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidEndKeySequence),
                name: Ghostty.Notification.didEndKeySequence,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeKeyTable),
                name: Ghostty.Notification.didChangeKeyTable,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyConfigDidChange(_:)),
                name: .ghosttyConfigDidChange,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyColorDidChange(_:)),
                name: .ghosttyColorDidChange,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyBellDidRing(_:)),
                name: .ghosttyBellDidRing,
                object: self)
            center.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: nil)

            // Listen for local events that we need to know of outside of
            // single surface handlers.
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    // We need keyUp because command+key events don't trigger keyUp.
                    .keyUp,

                    // We need leftMouseDown to determine if we should focus ourselves
                    // when the app/window isn't in focus. We do this instead of
                    // "acceptsFirstMouse" because that forces us to also handle the
                    // event and encode the event to the pty which we want to avoid.
                    // (Issue 2595)
                    .leftMouseDown,
                ]
            ) { [weak self] event in self?.localEventHandler(event) }

            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            let surface = surface_cfg.withCValue(view: self) { surface_cfg_c in
                ghostty_surface_new(app, &surface_cfg_c)
            }
            guard let surface = surface else {
                self.error = Ghostty.Error.apiFailed
                return
            }
            self.surfaceModel = Ghostty.Surface(cSurface: surface)

            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()

            // The UTTypes that can be dragged onto this view.
            registerForDraggedTypes(Array(Self.dropTypes))

            // A sharing session may have just asked the host to create
            // this surface (create_session control frame). The window
            // and tab creation paths hand the new view to AppKit via
            // notification plumbing with no return value to capture, so
            // the requester arms a one-shot instead and the next surface
            // to initialize consumes it (and starts sharing itself).
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let handler = SessionSharingPendingAutoShare.consume()
                else { return }
                handler(self)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            sessionSharing.prepareForSurfaceShutdown()

            // Remove all of our notificationcenter subscriptions
            let center = NotificationCenter.default
            center.removeObserver(self)

            // Remove our event monitor
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }

            // Whenever the surface is removed, we need to note that our restorable
            // state is invalid to prevent the surface from being restored.
            invalidateRestorableState()

            trackingAreas.forEach { removeTrackingArea($0) }

            // Remove ourselves from secure input if we have to
            SecureInput.shared.removeScoped(ObjectIdentifier(self))

            // Remove any notifications associated with this surface
            let identifiers = Array(self.notificationIdentifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)

            // Cancel progress report timer
            progressReportTimer?.invalidate()
        }

        func toggleSessionSharing(from parentWindow: NSWindow?) {
            sessionSharing.toggle(from: parentWindow)
        }

        func stopSessionSharing() {
            sessionSharing.stopSharing(userInitiated: true)
        }

        /// Try to auto-restart sharing using the last persisted relay
        /// + token. Returns false when there's nothing to resume with
        /// (caller drops the breadcrumb entry).
        @discardableResult
        func resumeSessionSharingIfPossible() -> Bool {
            return sessionSharing.resumeFromPersistedConfig()
        }

        /// Start sharing on behalf of a remote create_session request,
        /// using the requesting session's live relay/token. Returns the
        /// new session id, nil when this surface is already sharing.
        func startSessionSharingFromRemoteCreate(
            relay: String,
            userToken: String,
            uploadEnabled: Bool
        ) -> String? {
            sessionSharing.startForRemoteCreate(
                relay: relay,
                userToken: userToken,
                uploadEnabled: uploadEnabled
            )
        }

        /// Disable upload acceptance for the current share session.
        /// Idempotent. The user has no opt-back-in path inside the same
        /// share session — they have to stop & restart sharing to flip
        /// it back on. That's a deliberate one-way switch: it matches
        /// the "I notice something off, kill the door" mental model.
        func stopAcceptingUploadsForSession() {
            sessionSharing.setUploadPolicy(.disabled)
        }

        fileprivate func sendSharedBytes(_ data: Data) {
            guard let surface else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.bindMemory(to: CChar.self).baseAddress else { return }
                ghostty_surface_send_bytes(surface, ptr, UInt(rawBuffer.count))
            }
        }

#if XGHOSTTY
        /// XGhostty spike：对外开放的 send_bytes（座舱广播用，绕过 bracketed-paste 直写 pty）。
        func xghosttySendBytes(_ data: Data) {
            guard let surface else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.bindMemory(to: CChar.self).baseAddress else { return }
                ghostty_surface_send_bytes(surface, ptr, UInt(rawBuffer.count))
            }
        }
#endif

        fileprivate func applySharedResize(cols: Int, rows: Int) {
            guard let surface, cols > 0, rows > 0 else { return }
            sessionSharing.captureOriginalSharedResizeIfNeeded(cols: Int(ghostty_surface_size(surface).columns), rows: Int(ghostty_surface_size(surface).rows))
            let size = ghostty_surface_size(surface)
            let width = UInt32(cols) * max(size.cell_width_px, 1)
            let height = UInt32(rows) * max(size.cell_height_px, 1)
            setSurfaceSize(width: width, height: height)
        }

        fileprivate func restoreSharedResize(cols: Int, rows: Int) {
            guard let surface, cols > 0, rows > 0 else { return }
            let size = ghostty_surface_size(surface)
            let width = UInt32(cols) * max(size.cell_width_px, 1)
            let height = UInt32(rows) * max(size.cell_height_px, 1)
            setSurfaceSize(width: width, height: height)
        }

        override func endSearch() {
            Ghostty.moveFocus(to: self)
            super.endSearch()
        }

        override func focusDidChange(_ focused: Bool) {
            guard let surface = self.surface else { return }
            guard self.focused != focused else { return }
            self.focused = focused

            // If we lost our focus then remove the mouse event suppression so
            // our mouse release event leaving the surface can properly be
            // sent to stop things like mouse selection.
            if !focused {
                suppressNextLeftMouseUp = false
            }

            // Notify libghostty
            ghostty_surface_set_focus(surface, focused)

            // Update our secure input state if we are a password input
            if passwordInput {
                SecureInput.shared.setScoped(ObjectIdentifier(self), focused: focused)
            }

            if focused {
                // On macOS 13+ we can store our continuous clock...
                focusInstant = ContinuousClock.now

                // We unset our bell state if we gained focus
                bell = false

                // Remove any notifications for this surface once we gain focus.
                if !notificationIdentifiers.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(
                            withIdentifiers: Array(notificationIdentifiers))
                    self.notificationIdentifiers = []
                }
            }
        }

        override func sizeDidChange(_ size: CGSize) {
            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scaledSize = self.convertToBacking(size)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
            // Store this size so we can reuse it when backing properties change
            contentSize = size
        }

        private func setSurfaceSize(width: UInt32, height: UInt32) {
            guard let surface = self.surface else { return }

            // Update our core surface
            ghostty_surface_set_size(surface, width, height)

            // Update our cached size metrics
            let size = ghostty_surface_size(surface)
            DispatchQueue.main.async {
                // DispatchQueue required since this may be called by SwiftUI off
                // the main thread and Published changes need to be on the main
                // thread. This caused a crash on macOS <= 14.
                self.surfaceSize = size
            }
        }

        func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_DEFAULT:
                pointerStyle = .default

            case GHOSTTY_MOUSE_SHAPE_TEXT:
                pointerStyle = .horizontalText

            case GHOSTTY_MOUSE_SHAPE_GRAB:
                pointerStyle = .grabIdle

            case GHOSTTY_MOUSE_SHAPE_GRABBING:
                pointerStyle = .grabActive

            case GHOSTTY_MOUSE_SHAPE_POINTER:
                pointerStyle = .link

            case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
                pointerStyle = .resizeLeft

            case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
                pointerStyle = .resizeRight

            case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
                pointerStyle = .resizeUp

            case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
                pointerStyle = .resizeDown

            case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
                pointerStyle = .resizeUpDown

            case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
                pointerStyle = .resizeLeftRight

            case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
                pointerStyle = .verticalText

            case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
                pointerStyle = .contextMenu

            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                pointerStyle = .crosshair

            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
                pointerStyle = .operationNotAllowed

            default:
                // We ignore unknown shapes.
                return
            }
        }

        func setCursorVisibility(_ visible: Bool) {
            cursorVisible = visible
            // Technically this action could be called anytime we want to
            // change the mouse visibility but at the time of writing this
            // mouse-hide-while-typing is the only use case so this is the
            // preferred method.
            NSCursor.setHiddenUntilMouseMoves(!visible)
        }

        /// Set the title by prompting the user.
        func promptTitle() {
            // Create an alert dialog
            let alert = NSAlert()
            alert.messageText = LocalizedString.text("Change Terminal Title")
            alert.informativeText = LocalizedString.text("Leave blank to restore the default.")
            alert.alertStyle = .informational

            // Add a text field to the alert
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            textField.stringValue = title
            alert.accessoryView = textField

            // Add buttons
            alert.addButton(withTitle: LocalizedString.text("OK"))
            alert.addButton(withTitle: LocalizedString.text("Cancel"))

            // Make the text field the first responder so it gets focus
            alert.window.initialFirstResponder = textField

            let completionHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }

                // Check if the user clicked "OK"
                guard response == .alertFirstButtonReturn  else { return }

                // Get the input text
                let newTitle = textField.stringValue
                if newTitle.isEmpty {
                    // Empty means that user wants the title to be set automatically
                    // We also need to reload the config for the "title" property to be
                    // used again by this tab.
                    let prevTitle = titleFromTerminal ?? "👻"
                    titleFromTerminal = nil
                    setTitle(prevTitle)
                } else {
                    // Set the title and prevent it from being changed automatically
                    titleFromTerminal = title
                    title = newTitle
                }
            }

            // We prefer to run our alert in a sheet modal if we have a window.
            if let window {
                alert.beginSheetModal(for: window, completionHandler: completionHandler)
            } else {
                // On macOS 26 RC, this codepath results in the "OK" button not being
                // visible. The above codepath should be taken most times but I'm just
                // noting this as something I noticed consistently.
                completionHandler(alert.runModal())
            }
        }

        func setTitle(_ title: String) {
            // This fixes an issue where very quick changes to the title could
            // cause an unpleasant flickering. We set a timer so that we can
            // coalesce rapid changes. The timer is short enough that it still
            // feels "instant".
            titleChangeTimer?.invalidate()
            titleChangeTimer = Timer.scheduledTimer(
                withTimeInterval: 0.075,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                // Forward the PTY title to the sharing controller. It
                // internally gates on whether sharing is active and
                // whether the user supplied an explicit name, so it's
                // safe to call unconditionally.
                self.sessionSharing.notifyTitleChanged(title)
                // Set the title if it wasn't manually set.
                guard self.titleFromTerminal == nil else {
                    self.titleFromTerminal = title
                    return
                }
                self.title = title
            }
        }

        // MARK: Local Events

        private func localEventHandler(_ event: NSEvent) -> NSEvent? {
            return switch event.type {
            case .keyUp:
                localEventKeyUp(event)

            case .leftMouseDown:
                localEventLeftMouseDown(event)

            default:
                event
            }
        }

        private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            let isCommandPaletteVisible = (event.window?.windowController as? BaseTerminalController)?
                .commandPaletteIsShowing == true
            guard !isCommandPaletteVisible else {
                // We don't want to process events that
                // are supposed to be handled by CommandPaletteView
                return event
            }

            // We only want to process events that are on this window.
            guard let window,
                  event.window != nil,
                  window == event.window else { return event }

            // The clicked location in this window should be this view.
            guard
                let location = window.contentView?.convert(event.locationInWindow, from: nil)
            else {
                return event
            }
            // We should use window to perform hitTest here,
            // because there could be some other overlays on top, like search bar
            guard window.contentView?.hitTest(location) == self else { return event }

            // We always assume that we're resetting our mouse suppression
            // unless we see the specific scenario below to set it.
            suppressNextLeftMouseUp = false

            // If we're already the first responder then no focus transfer is
            // happening, so the click should continue as normal.
            guard window.firstResponder !== self else {
                return event
            }

            // If our window/app is already focused, then this click is only
            // being used to transfer split focus. Consume it so it does not
            // get forwarded to the terminal as a mouse click.
            if NSApp.isActive && window.isKeyWindow {
                window.makeFirstResponder(self)
                suppressNextLeftMouseUp = true
                return nil
            }

            // Make ourselves the first responder
            window.makeFirstResponder(self)

            // We have to keep processing the event so that AppKit can properly
            // focus the window and dispatch events. If you return nil here then
            // nobody gets a windowDidBecomeKey event and so on.
            return event
        }

        private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
            // We only care about events with "command" because all others will
            // trigger the normal responder chain.
            if !event.modifierFlags.contains(.command) { return event }

            // Command keyUp events are never sent to the normal responder chain
            // so we send them here.
            guard focused else { return event }
            self.keyUp(with: event)
            return nil
        }

        // MARK: - Notifications

        @objc private func onUpdateRendererHealth(notification: SwiftUI.Notification) {
            guard let healthAny = notification.userInfo?["health"] else { return }
            guard let health = healthAny as? ghostty_action_renderer_health_e else { return }
            DispatchQueue.main.async { [weak self] in
                self?.healthy = health == GHOSTTY_RENDERER_HEALTH_HEALTHY
            }
        }

        @objc private func ghosttyDidContinueKeySequence(notification: SwiftUI.Notification) {
            guard let keyAny = notification.userInfo?[Ghostty.Notification.KeySequenceKey] else { return }
            guard let key = keyAny as? KeyboardShortcut else { return }
            DispatchQueue.main.async { [weak self] in
                self?.keySequence.append(key)
            }
        }

        @objc private func ghosttyDidEndKeySequence(notification: SwiftUI.Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.keySequence = []
            }
        }

        @objc private func ghosttyDidChangeKeyTable(notification: SwiftUI.Notification) {
            guard let action = notification.userInfo?[Ghostty.Notification.KeyTableKey] as? Ghostty.Action.KeyTable else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch action {
                case .activate(let name):
                    self.keyTables.append(name)
                case .deactivate:
                    _ = self.keyTables.popLast()
                case .deactivateAll:
                    self.keyTables.removeAll()
                }
            }
        }

        @objc private func ghosttyConfigDidChange(_ notification: SwiftUI.Notification) {
            // Get our managed configuration object out
            guard let config = notification.userInfo?[
                SwiftUI.Notification.Name.GhosttyConfigChangeKey
            ] as? Ghostty.Config else { return }

            // Update our derived config
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.derivedConfig = DerivedConfig(config)

                // If the cached OSC 11 background color disagrees with the new
                // config-derived background, drop it so window chrome follows
                // the new config (e.g., on light/dark theme auto-switch). The
                // cached value is restored next time the terminal emits a
                // color_change.
                if let cached = self.backgroundColor,
                   cached != self.derivedConfig.backgroundColor {
                    self.backgroundColor = nil
                }
            }
        }

        @objc private func ghosttyColorDidChange(_ notification: SwiftUI.Notification) {
            guard let change = notification.userInfo?[
                SwiftUI.Notification.Name.GhosttyColorChangeKey
            ] as? Ghostty.Action.ColorChange else { return }

            switch change.kind {
            case .background:
                DispatchQueue.main.async { [weak self] in
                    self?.backgroundColor = change.color
                }

            default:
                // We don't do anything for the other colors yet.
                break
            }
        }

        @objc private func ghosttyBellDidRing(_ notification: SwiftUI.Notification) {
            // Bell state goes to true
            bell = true
        }

        @objc private func windowDidChangeScreen(notification: SwiftUI.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            guard let screen = window.screen else { return }
            guard let surface = self.surface else { return }

            // When the window changes screens, we need to update libghostty with the screen
            // ID. If vsync is enabled, this will be used with the CVDisplayLink to ensure
            // the proper refresh rate is going.
            ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

            // We also just trigger a backing property change. Just in case the screen has
            // a different scaling factor, this ensures that we update our content scale.
            // Issue: https://github.com/ghostty-org/ghostty/issues/2731
            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        // MARK: - NSView

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { focusDidChange(true) }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()

            // We sometimes call this manually (see SplitView) as a way to force us to
            // yield our focus state.
            if result { focusDidChange(false) }

            return result
        }

        override func updateTrackingAreas() {
            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // This tracking area is across the entire frame to notify us of mouse movements.
            addTrackingArea(NSTrackingArea(
                rect: frame,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,

                    // Only send mouse events that happen in our visible (not obscured) rect
                    .inVisibleRect,

                    // We want active always because we want to still send mouse reports
                    // even if we're not focused or key.
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            // The Core Animation compositing engine uses the layer's contentsScale property
            // to determine whether to scale its contents during compositing. When the window
            // moves between a high DPI display and a low DPI display, or the user modifies
            // the DPI scaling for a display in the system settings, this can result in the
            // layer being scaled inappropriately. Since we handle the adjustment of scale
            // and resolution ourselves below, we update the layer's contentsScale property
            // to match the window's backingScaleFactor, so as to ensure it is not scaled by
            // the compositor.
            //
            // Ref: High Resolution Guidelines for OS X
            // https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/CapturingScreenContents/CapturingScreenContents.html#//apple_ref/doc/uid/TP40012302-CH10-SW27
            if let window = window {
                CATransaction.begin()
                // Disable the implicit transition animation that Core Animation applies to
                // property changes. Otherwise it will apply a scale animation to the layer
                // contents which looks pretty janky.
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }

            guard let surface = self.surface else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)

            // When our scale factor changes, so does our fb size so we send that too
            let scaledSize = self.convertToBacking(contentSize)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
        }

        override func mouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            // If this mouse-up corresponds to a focus-only click transfer,
            // suppress it so we don't emit a release without a press.
            if suppressNextLeftMouseUp {
                suppressNextLeftMouseUp = false
                return
            }

            // Always reset our pressure when the mouse goes up
            prevPressureStage = 0

            // If we have an active surface, report the event
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)

            // Release pressure
            ghostty_surface_mouse_pressure(surface, 0, 0)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            let button = Ghostty.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button.cMouseButton, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            let button = Ghostty.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button.cMouseButton, mods)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return super.rightMouseDown(with: event) }

            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            if ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                GHOSTTY_MOUSE_RIGHT,
                mods
            ) {
                // Consumed
                return
            }

            // Mouse event not consumed
            super.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return super.rightMouseUp(with: event) }

            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            if ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_RELEASE,
                GHOSTTY_MOUSE_RIGHT,
                mods
            ) {
                // Handled
                return
            }

            // Mouse event not consumed
            super.rightMouseUp(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            mouseOverSurface = true
            super.mouseEntered(with: event)

            let pos = self.convert(event.locationInWindow, from: nil)
            mouseLocationInSurface = pos

            guard let surfaceModel else { return }

            // On mouse enter we need to reset our cursor position. This is
            // super important because we set it to -1/-1 on mouseExit and
            // lots of mouse logic (i.e. whether to send mouse reports) depend
            // on the position being in the viewport if it is.
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseExited(with event: NSEvent) {
            mouseOverSurface = false
            mouseLocationInSurface = nil
            guard let surfaceModel else { return }

            // If the mouse is being dragged then we don't have to emit
            // this because we get mouse drag events even if we've already
            // exited the viewport (i.e. mouseDragged)
            if NSEvent.pressedMouseButtons != 0 {
                return
            }

            // Negative values indicate cursor has left the viewport
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: -1,
                y: -1,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseMoved(with event: NSEvent) {
            let pos = self.convert(event.locationInWindow, from: nil)
            mouseLocationInSurface = pos

            guard let surfaceModel else { return }

            // Convert window position to view position. Note (0, 0) is bottom left.
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)

            // Handle focus-follows-mouse
            if let window,
               let controller = window.windowController as? BaseTerminalController,
               !controller.commandPaletteIsShowing,
               window.isKeyWindow &&
                    !self.focused &&
                    controller.focusFollowsMouse {
                Ghostty.moveFocus(to: self)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surfaceModel else { return }

            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            let precision = event.hasPreciseScrollingDeltas

            if precision {
                // We do a 2x speed multiplier. This is subjective, it "feels" better to me.
                x *= 2
                y *= 2

                // TODO(mitchellh): do we have to scale the x/y here by window scale factor?
            }

            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: x,
                y: y,
                mods: .init(precision: precision, momentum: .init(event.momentumPhase))
            )
            surfaceModel.sendMouseScroll(scrollEvent)
        }

        override func pressureChange(with event: NSEvent) {
            guard let surface = self.surface else { return }

            // Notify Ghostty first. We do this because this will let Ghostty handle
            // state setup that we'll need for later pressure handling (such as
            // QuickLook)
            ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))

            // Pressure stage 2 is force click. We only want to execute this on the
            // initial transition to stage 2, and not for any repeated events.
            guard self.prevPressureStage < 2 else { return }
            prevPressureStage = event.stage
            guard event.stage == 2 else { return }

            // If the user has force click enabled then we do a quick look. There
            // is no public API for this as far as I can tell.
            guard UserDefaults.ghostty.bool(forKey: "com.apple.trackpad.forceClick") else { return }
            quickLook(with: event)
        }

        override func keyDown(with event: NSEvent) {
            guard let surface = self.surface else {
                self.interpretKeyEvents([event])
                return
            }

            // On any keyDown event we unset our bell state
            bell = false

            // We need to translate the mods (maybe) to handle configs such as option-as-alt
            let translationModsGhostty = Ghostty.eventModifierFlags(
                mods: ghostty_surface_key_translation_mods(
                    surface,
                    Ghostty.ghosttyMods(event.modifierFlags)
                )
            )

            // There are hidden bits set in our event that matter for certain dead keys
            // so we can't use translationModsGhostty directly. Instead, we just check
            // for exact states and set them.
            var translationMods = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if translationModsGhostty.contains(flag) {
                    translationMods.insert(flag)
                } else {
                    translationMods.remove(flag)
                }
            }

            // If the translation modifiers are not equal to our original modifiers
            // then we need to construct a new NSEvent. If they are equal we reuse the
            // old one. IMPORTANT: we MUST reuse the old event if they're equal because
            // this keeps things like Korean input working. There must be some object
            // equality happening in AppKit somewhere because this is required.
            let translationEvent: NSEvent
            if translationMods == event.modifierFlags {
                translationEvent = event
            } else {
                translationEvent = NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
            }

            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // By setting this to non-nil, we note that we're in a keyDown event. From here,
            // we call interpretKeyEvents so that we can handle complex input such as Korean
            // language.
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }

            // We need to know what the length of marked text was before this event to
            // know if these events cleared it.
            let markedTextBefore = markedText.length > 0

            // We need to know the keyboard layout before below because some keyboard
            // input events will change our keyboard layout and we don't want those
            // going to the terminal.
            let keyboardIdBefore: String? = if !markedTextBefore {
                KeyboardLayout.id
            } else {
                nil
            }

            // If we are in a keyDown then we don't need to redispatch a command-modded
            // key event (see docs for this field) so reset this to nil because
            // `interpretKeyEvents` may dispatch it.
            self.lastPerformKeyEvent = nil

            self.interpretKeyEvents([translationEvent])

            // If our keyboard changed from this we just assume an input method
            // grabbed it and do nothing.
            if !markedTextBefore && keyboardIdBefore != KeyboardLayout.id {
                return
            }

            // If we have marked text, we're in a preedit state. The order we
            // do this and the key event callbacks below doesn't matter since
            // we control the preedit state only through the preedit API.
            syncPreedit(clearIfNeeded: markedTextBefore)

            // We're composing if we have preedit (the obvious case). But we're also
            // composing if we don't have preedit and we had marked text before,
            // because this input probably just reset the preedit state. It shouldn't
            // be encoded. Example: Japanese begin composing, then press backspace
            // or ctrl+h. This should only cancel the composing state but not
            // actually delete the prior input characters (prior to the composing).
            let composing = markedText.length > 0 || markedTextBefore

            // The input method may commit all or part of the preedit text via
            // insertText while handling a key that should not itself be
            // encoded. Send that committed text separately, then only replay
            // keys that should still affect the terminal after committing.
            if markedTextBefore,
               let list = keyTextAccumulator,
               list.count > 0 {
                for text in list {
                    if Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                        text,
                        composing: composing
                    ) {
                        continue
                    }

                    _ = committedPreeditTextAction(action, text: text)
                }

                if shouldReplayCommittedPreeditKey(translationEvent) {
                    _ = keyAction(
                        action,
                        event: event,
                        translationEvent: translationEvent,
                        composing: false
                    )
                }
                return
            }

            if let list = keyTextAccumulator, list.count > 0 {
                // Accumulated text from interpretKeyEvents (committed by the IME).
                for text in list {
                    // Drop bare control characters the IME accumulated while
                    // composing so they don't leak through to the terminal.
                    if Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                        text,
                        composing: composing
                    ) {
                        continue
                    }

                    // We've composed a character; send it down. keyAction's
                    // default composing=false applies because this is the
                    // committed result of a composition, not in-progress preedit.
                    _ = keyAction(
                        action,
                        event: event,
                        translationEvent: translationEvent,
                        text: text
                    )
                }
            } else {
                // Raw control characters (e.g. ctrl+h) arriving during
                // composition belong to the IME, not the terminal.
                if Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                    event.characters,
                    composing: composing
                ) {
                    return
                }

                // We have no accumulated text so this is a normal key event.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: translationEvent.ghosttyCharacters,
                    composing: composing
                )
            }
        }

        override func keyUp(with event: NSEvent) {
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
        }

        /// Records the timestamp of the last event to performKeyEquivalent that we need to save.
        /// We currently save all commands with command or control set.
        ///
        /// For command+key inputs, the AppKit input stack calls performKeyEquivalent to give us a chance
        /// to handle them first. If we return "false" then it goes through the standard AppKit responder chain.
        /// For an NSTextInputClient, that may redirect some commands _before_ our keyDown gets called.
        /// Concretely: Command+Period will do: performKeyEquivalent, doCommand ("cancel:"). In doCommand,
        /// we need to know that we actually want to handle that in keyDown, so we send it back through the
        /// event dispatch system and use this timestamp as an identity to know to actually send it to keyDown.
        ///
        /// Why not send it to keyDown always? Because if the user rebinds a command to something we
        /// actually handle then we do want the standard response chain to handle the key input. Unfortunately,
        /// we can't know what a command is bound to at a system level until we let it flow through the system.
        /// That's the crux of the problem.
        ///
        /// So, we have to send it back through if we didn't handle it.
        ///
        /// The next part of the problem is comparing NSEvent identity seems pretty nasty. I couldn't
        /// find a good way to do it. I originally stored a weak ref and did identity comparison but that
        /// doesn't work and for reasons I couldn't figure out the value gets mangled (fields don't match
        /// before/after the assignment). I suspect it has something to do with the fact an NSEvent is wrapping
        /// a lower level event pointer and its just not surviving the Swift runtime somehow. I don't know.
        ///
        /// The best thing I could find was to store the event timestamp which has decent granularity
        /// and compare that. To further complicate things, some events are synthetic and have a zero
        /// timestamp so we have to protect against that. Fun!
        var lastPerformKeyEvent: TimeInterval?

        /// Special case handling for some control keys
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // We only care about key down events. It might not even be possible
            // to receive any other event type here.
            guard event.type == .keyDown else { return false }

            // Let AppKit text inputs keep their normal edit shortcuts when a sheet
            // or panel field editor owns focus, such as the session sharing dialog.
            if SessionSharingKeyEquivalentPolicy.shouldUseStandardResponderChain(
                firstResponder: NSApp.keyWindow?.firstResponder,
                hasAttachedSheet: window?.attachedSheet != nil
            ) {
                return false
            }

            // Only process events if we're focused. Some key events like C-/ macOS
            // appears to send to the first view in the hierarchy rather than the
            // the first responder (I don't know why). This prevents us from handling it.
            // Besides C-/, its important we don't process key equivalents if unfocused
            // because there are other event listeners for that (i.e. AppDelegate's
            // local event handler).
            if !focused {
                return false
            }

            // Get information about if this is a binding.
            let bindingFlags = surfaceModel.flatMap { surface in
                var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
                return (event.characters ?? "").withCString { ptr in
                    ghosttyEvent.text = ptr
                    return surface.keyIsBinding(ghosttyEvent)
                }
            }

            // If this is a binding then we want to perform it.
            if let bindingFlags {
                // Attempt to trigger a menu item for this key binding. We only do this if:
                //   - We're not in a key sequence or table (those are separate bindings)
                //   - The binding is NOT `all` (menu uses FirstResponder chain)
                //   - The binding is NOT `performable` (menu will always consume)
                //   - The binding is `consumed` (unconsumed bindings should pass through
                //     to the terminal, so we must not intercept them for the menu)
                if keySequence.isEmpty,
                   keyTables.isEmpty,
                   bindingFlags.isDisjoint(with: [.all, .performable]),
                   bindingFlags.contains(.consumed) {
                    if let appDelegate = NSApp.delegate as? AppDelegate,
                       appDelegate.performGhosttyBindingMenuKeyEquivalent(with: event) {
                        return true
                    }
                }

                self.keyDown(with: event)
                return true
            }

            let equivalent: String
            switch event.charactersIgnoringModifiers {
            case "\r":
                // Pass C-<return> through verbatim
                // (prevent the default context menu equivalent)
                if !event.modifierFlags.contains(.control) {
                    return false
                }

                equivalent = "\r"

            case "/":
                // Treat C-/ as C-_. We do this because C-/ makes macOS make a beep
                // sound and we don't like the beep sound.
                if !event.modifierFlags.contains(.control) ||
                    !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                    return false
                }

                equivalent = "_"

            default:
                // It looks like some part of AppKit sometimes generates synthetic NSEvents
                // with a zero timestamp. We never process these at this point. Concretely,
                // this happens for me when pressing Cmd+period with default bindings. This
                // binds to "cancel" which goes through AppKit to produce a synthetic "escape".
                //
                // Question: should we be ignoring all synthetic events? Should we be finding
                // synthetic escape and ignoring it? I feel like Cmd+period could map to a
                // escape binding by accident, but it hasn't happened yet...
                if event.timestamp == 0 {
                    return false
                }

                // All of this logic here re: lastCommandEvent is to workaround some
                // nasty behavior. See the docs for lastCommandEvent for more info.

                // Ignore all other non-command events. This lets the event continue
                // through the AppKit event systems.
                if !event.modifierFlags.contains(.command) &&
                    !event.modifierFlags.contains(.control) {
                    // Reset since we got a non-command event.
                    lastPerformKeyEvent = nil
                    return false
                }

                // If we have a prior command binding and the timestamp matches exactly
                // then we pass it through to keyDown for encoding.
                if let lastPerformKeyEvent {
                    self.lastPerformKeyEvent = nil
                    if lastPerformKeyEvent == event.timestamp {
                        equivalent = event.characters ?? ""
                        break
                    }
                }

                lastPerformKeyEvent = event.timestamp
                return false
            }

            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )

            self.keyDown(with: finalEvent!)
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            let mod: UInt32
            switch event.keyCode {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            // If we're in the middle of a preedit, don't do anything with mods.
            if hasMarkedText() { return }

            // The keyAction function will do this AGAIN below which sucks to repeat
            // but this is super cheap and flagsChanged isn't that common.
            let mods = Ghostty.ghosttyMods(event.modifierFlags)

            // If the key that pressed this is active, its a press, else release.
            var action = GHOSTTY_ACTION_RELEASE
            if mods.rawValue & mod != 0 {
                // If the key is pressed, its slightly more complicated, because we
                // want to check if the pressed modifier is the correct side. If the
                // correct side is pressed then its a press event otherwise its a release
                // event with the opposite modifier still held.
                let sidePressed: Bool
                switch event.keyCode {
                case 0x3C:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
                case 0x3E:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
                case 0x3D:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
                case 0x36:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
                default:
                    sidePressed = true
                }

                if sidePressed {
                    action = GHOSTTY_ACTION_PRESS
                }
            }

            _ = keyAction(action, event: event)
        }

        private func keyAction(
            _ action: ghostty_input_action_e,
            event: NSEvent,
            translationEvent: NSEvent? = nil,
            text: String? = nil,
            composing: Bool = false
        ) -> Bool {
            guard let surface = self.surface else { return false }

            var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
            key_ev.composing = composing

            // For text, we only encode UTF8 if we don't have a single control
            // character. Control characters are encoded by Ghostty itself.
            // Without this, `ctrl+enter` does the wrong thing.
            if let text, text.count > 0,
               let codepoint = text.utf8.first, codepoint >= 0x20 {
                return text.withCString { ptr in
                    key_ev.text = ptr
                    return ghostty_surface_key(surface, key_ev)
                }
            } else {
                return ghostty_surface_key(surface, key_ev)
            }
        }

        private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
            guard let key = Ghostty.Input.Key(keyCode: event.keyCode) else { return false }
            switch key {
            case .arrowDown, .arrowRight, .arrowUp:
                return true
            case .arrowLeft:
                // Don't replay plain left-arrow because AppKit already leaves
                // the caret in place after Korean IMEs commit preedit text.
                return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
            default:
                return false
            }
        }

        private func committedPreeditTextAction(
            _ action: ghostty_input_action_e,
            text: String
        ) -> Bool {
            guard let surface = self.surface else { return false }

            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.keycode = 0
            key_ev.text = nil
            key_ev.composing = false
            key_ev.mods = GHOSTTY_MODS_NONE
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.unshifted_codepoint = 0

            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        }

        override func quickLook(with event: NSEvent) {
            guard let surface = self.surface else { return super.quickLook(with: event) }

            // Grab the text under the cursor
            var text = ghostty_text_s()
            guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
            defer { ghostty_surface_free_text(surface, &text) }
            guard text.text_len > 0  else { return super.quickLook(with: event) }

            // If we can get a font then we use the font. This should always work
            // since we always have a primary font. The only scenario this doesn't
            // work is if someone is using a non-CoreText build which would be
            // unofficial.
            var attributes: [ NSAttributedString.Key: Any ] = [:]
            if let fontRaw = ghostty_surface_quicklook_font(surface) {
                // Memory management here is wonky: ghostty_surface_quicklook_font
                // will create a copy of a CTFont, Swift will auto-retain the
                // unretained value passed into the dict, so we release the original.
                let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
                attributes[.font] = font.takeUnretainedValue()
                font.release()
            }

            // Ghostty coordinate system is top-left, convert to bottom-left for AppKit
            let pt = NSPoint(x: text.tl_px_x, y: frame.size.height - text.tl_px_y)
            let str = NSAttributedString.init(string: String(cString: text.text), attributes: attributes)
            self.showDefinition(for: str, at: pt)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            // We only support right-click menus
            switch event.type {
            case .rightMouseDown:
                // Good
                break

            case .leftMouseDown:
                if !event.modifierFlags.contains(.control) {
                    return nil
                }

                // In this case, AppKit calls menu BEFORE calling any mouse events.
                // If mouse capturing is enabled then we never show the context menu
                // so that we can handle ctrl+left-click in the terminal app.
                guard let surfaceModel else { return nil }
                if surfaceModel.mouseCaptured {
                    return nil
                }

                // If we return a non-nil menu then mouse events will never be
                // processed by the core, so we need to manually send a right
                // mouse down event.
                //
                // Note this never sounds a right mouse up event but that's the
                // same as normal right-click with capturing disabled from AppKit.
                surfaceModel.sendMouseButton(.init(
                    action: .press,
                    button: .right,
                    mods: .init(nsFlags: event.modifierFlags)))

            default:
                return nil
            }

            let menu = NSMenu()

            // We just use a floating var so we can easily setup metadata on each item
            // in a row without storing it all.
            var item: NSMenuItem

            // If we have a selection, add copy
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                menu.addItem(withTitle: LocalizedString.text("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
            }
            menu.addItem(withTitle: LocalizedString.text("Paste"), action: #selector(paste(_:)), keyEquivalent: "")

            menu.addItem(.separator())
            item = menu.addItem(withTitle: LocalizedString.text("Split Right"), action: #selector(splitRight(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
            item = menu.addItem(withTitle: LocalizedString.text("Split Left"), action: #selector(splitLeft(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
            item = menu.addItem(withTitle: LocalizedString.text("Split Down"), action: #selector(splitDown(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
            item = menu.addItem(withTitle: LocalizedString.text("Split Up"), action: #selector(splitUp(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")

            menu.addItem(.separator())
            item = menu.addItem(withTitle: LocalizedString.text("Reset Terminal"), action: #selector(resetTerminal(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise")
            item = menu.addItem(withTitle: LocalizedString.text("Toggle Terminal Inspector"), action: #selector(toggleTerminalInspector(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "scope")
            item = menu.addItem(withTitle: LocalizedString.text("Terminal Read-only"), action: #selector(toggleReadonly(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "eye.fill")
            item.state = readonly ? .on : .off
            menu.addItem(.separator())
            item = menu.addItem(withTitle: LocalizedString.text("Change Tab Title..."), action: #selector(BaseTerminalController.changeTabTitle(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "pencil.line")
            item = menu.addItem(withTitle: LocalizedString.text("Change Terminal Title..."), action: #selector(changeTitle(_:)), keyEquivalent: "")

            return menu
        }

        // MARK: Menu Handlers

        @IBAction func copy(_ sender: Any?) {
            if forwardEditActionToAttachedSheet(#selector(NSText.copy(_:)), sender: sender) { return }
            guard let surface = self.surface else { return }
            let action = "copy_to_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func paste(_ sender: Any?) {
            if forwardEditActionToAttachedSheet(#selector(NSText.paste(_:)), sender: sender) { return }
            guard let surface = self.surface else { return }
            let action = "paste_from_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func pasteAsPlainText(_ sender: Any?) {
            if forwardEditActionToAttachedSheet(#selector(NSText.paste(_:)), sender: sender) { return }
            guard let surface = self.surface else { return }
            let action = "paste_from_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func pasteSelection(_ sender: Any?) {
            if forwardEditActionToAttachedSheet(#selector(NSText.paste(_:)), sender: sender) { return }
            guard let surface = self.surface else { return }
            let action = "paste_from_selection"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction override func selectAll(_ sender: Any?) {
            if forwardEditActionToAttachedSheet(#selector(NSResponder.selectAll(_:)), sender: sender) { return }
            guard let surface = self.surface else { return }
            let action = "select_all"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        /// Forwards a standard edit action to the attached sheet's responder chain when one is present.
        ///
        /// `NSApp.sendAction` walks the key window's responder chain first, then falls back to the
        /// main window's chain. The session sharing settings sheet is the key window while the
        /// terminal window remains main, so when the sheet's first responder is a non-text control
        /// like the default button, edit actions cascade into the surface and hijack the dialog.
        /// This redirects them back to the sheet so the field editor can handle them.
        ///
        /// - Returns: `true` when the action has been forwarded (or swallowed) for the sheet,
        ///   so the caller should not run its terminal-side fallback.
        @discardableResult
        private func forwardEditActionToAttachedSheet(_ action: Selector, sender: Any?) -> Bool {
            guard let sheet = window?.attachedSheet else { return false }
            guard NSApp.keyWindow === sheet else { return false }
            if let handler = SessionSharingEditActionPolicy.handler(
                for: action,
                startingAt: sheet.firstResponder,
                excluding: self
            ) {
                _ = handler.perform(action, with: sender)
            }
            return true
        }

        @IBAction func find(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "start_search"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func selectionForFind(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "search_selection"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func scrollToSelection(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "scroll_to_selection"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func findNext(_ sender: Any?) {
            _ = self.navigateSearchToNext()
        }

        @IBAction func findPrevious(_ sender: Any?) {
            _ = navigateSearchToPrevious()
        }

        @IBAction func findHide(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "end_search"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func toggleReadonly(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "toggle_readonly"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func splitRight(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_RIGHT)
        }

        @IBAction func splitLeft(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_LEFT)
        }

        @IBAction func splitDown(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_DOWN)
        }

        @IBAction func splitUp(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_UP)
        }

        @objc func resetTerminal(_ sender: Any) {
            guard let surface = self.surface else { return }
            let action = "reset"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @objc func toggleTerminalInspector(_ sender: Any) {
            guard let surface = self.surface else { return }
            let action = "inspector:toggle"
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                AppDelegate.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func changeTitle(_ sender: Any) {
            promptTitle()
        }

        /// Show a user notification and associate it with this surface
        func showUserNotification(title: String, body: String, requireFocus: Bool = true) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = self.title
            content.body = body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = Ghostty.userNotificationCategory
            content.userInfo = [
                "surface": self.id.uuidString,
                "requireFocus": requireFocus,
            ]

            let uuid = UUID().uuidString
            let request = UNNotificationRequest(
                identifier: uuid,
                content: content,
                trigger: nil
            )

            // Note the callback may be executed on a background thread as documented
            // so we need @MainActor since we're reading/writing view state.
            UNUserNotificationCenter.current().add(request) { @MainActor error in
                if let error = error {
                    AppDelegate.logger.error("Error scheduling user notification: \(error, privacy: .public)")
                    return
                }

                // We need to keep track of this notification so we can remove it
                // under certain circumstances
                self.notificationIdentifiers.insert(uuid)

                // If we're focused then we schedule to remove the notification
                // after a few seconds. If we gain focus we automatically remove it
                // in focusDidChange.
                if self.focused {
                    Task { @MainActor [weak self] in
                        try await Task.sleep(for: .seconds(3))
                        self?.notificationIdentifiers.remove(uuid)
                        UNUserNotificationCenter.current()
                            .removeDeliveredNotifications(withIdentifiers: [uuid])
                    }
                }
            }
        }

        /// Handle a user notification click
        func handleUserNotification(notification: UNNotification, focus: Bool) {
            let id = notification.request.identifier
            guard self.notificationIdentifiers.remove(id) != nil else { return }
            if focus {
                self.window?.makeKeyAndOrderFront(self)
                Ghostty.moveFocus(to: self)
            }
        }

        struct DerivedConfig {
            let backgroundColor: Color
            let backgroundOpacity: Double
            let backgroundBlur: Ghostty.Config.BackgroundBlur
            let macosWindowShadow: Bool
            let windowTitleFontFamily: String?
            let windowAppearance: NSAppearance?
            let scrollbar: Ghostty.Config.Scrollbar

            init() {
                self.backgroundColor = Color(NSColor.windowBackgroundColor)
                self.backgroundOpacity = 1
                self.backgroundBlur = .disabled
                self.macosWindowShadow = true
                self.windowTitleFontFamily = nil
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            init(_ config: Ghostty.Config) {
                self.backgroundColor = config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
                self.backgroundBlur = config.backgroundBlur
                self.macosWindowShadow = config.macosWindowShadow
                self.windowTitleFontFamily = config.windowTitleFontFamily
                self.windowAppearance = .init(ghosttyConfig: config)
                self.scrollbar = config.scrollbar
            }
        }

        // MARK: - Codable

        enum CodingKeys: String, CodingKey {
            case pwd
            case uuid
            case title
            case isUserSetTitle
        }

        required convenience init(from decoder: Decoder) throws {
            // Decoding uses the global Ghostty app
            guard let del = NSApplication.shared.delegate,
                  let appDel = del as? AppDelegate,
                  let app = appDel.ghostty.app else {
                throw TerminalRestoreError.delegateInvalid
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            let uuid = UUID(uuidString: try container.decode(String.self, forKey: .uuid))
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = try container.decode(String?.self, forKey: .pwd)
            let savedTitle = try container.decodeIfPresent(String.self, forKey: .title)
            let isUserSetTitle = try container.decodeIfPresent(Bool.self, forKey: .isUserSetTitle) ?? false

            self.init(app, baseConfig: config, uuid: uuid)

            // Restore the saved title after initialization
            if let title = savedTitle {
                self.title = title
                // If this was a user-set title, we need to prevent it from being overwritten
                if isUserSetTitle {
                    self.titleFromTerminal = title
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pwd, forKey: .pwd)
            try container.encode(id.uuidString, forKey: .uuid)
            try container.encode(title, forKey: .title)
            try container.encode(titleFromTerminal != nil, forKey: .isUserSetTitle)
        }
    }
}

private func sessionSharingOutputCallback(
    _ context: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    guard let context, let bytes, length > 0 else { return }
    let controller = Unmanaged<SessionSharingController>.fromOpaque(context).takeUnretainedValue()
    let data = Data(bytes: bytes, count: Int(length))
    controller.enqueueOutgoing(data)
}

/// One-shot bridge for "create a surface and immediately share it"
/// (the create_session control frame). The requesting session's
/// controller arms it right before triggering a new_window/new_tab/
/// split binding action; the next SurfaceView to initialize consumes
/// it on the main thread. The TTL bounds the blast radius when surface
/// creation fails: a surface the user creates by hand seconds later
/// won't accidentally start sharing. Main thread only.
enum SessionSharingPendingAutoShare {
    private static var armedAt: Date?
    private static var handler: ((Ghostty.SurfaceView) -> Void)?
    private static let ttl: TimeInterval = 5

    static func arm(_ callback: @escaping (Ghostty.SurfaceView) -> Void) {
        armedAt = Date()
        handler = callback
    }

    static func consume() -> ((Ghostty.SurfaceView) -> Void)? {
        defer {
            armedAt = nil
            handler = nil
        }
        guard let armedAt, Date().timeIntervalSince(armedAt) < ttl else { return nil }
        return handler
    }
}

private final class SessionSharingController {
    private struct SharedResizeCheckpoint: Equatable {
        let cols: Int
        let rows: Int
    }

    private weak var surfaceView: Ghostty.SurfaceView?
    private let networkClient: any SessionSharingNetworkClient
    private let outputBridge: SessionSharingOutputBridge
    private let reconnectScheduler: SessionSharingReconnectScheduler
    private let outgoingQueue = DispatchQueue(label: "com.mitchellh.ghostty.session-sharing.outgoing")
    private let store: SessionSharingConfigStore

    private var webSocket: URLSessionWebSocketTask?
    private var reconnectTask: SessionSharingScheduledTask?
    private var relayAddress = ""
    private var userToken = ""
    private var sessionID = ""
    private var sessionName = ""
    private var shouldReconnect = false
    private var reconnectPolicy = SessionSharingReconnectPolicy()
    private var reconnectCoordinator = SessionSharingReconnectCoordinator()
    private var isStopping = false
    private var didPersistConfig = false
    private var originalSharedResizeCheckpoint: SharedResizeCheckpoint?
    // Last PTY-derived title we pushed to the relay as a `name_update`
    // frame. Used to suppress no-op resends so each title change only
    // emits a single control frame.
    private var lastSentTitleUpdate: String?
    private var uploadManager: SessionSharingUploadManager?
    private var uploadPolicy: SessionSharingUploadPolicy = .defaultEnabled
    private var settingsSheet: NSWindow?   // 共享设置 SwiftUI sheet

    init(
        surfaceView: Ghostty.SurfaceView,
        dependencies: SessionSharingControllerDependencies = .live(),
        store: SessionSharingConfigStore = SessionSharingConfigStore()
    ) {
        self.surfaceView = surfaceView
        networkClient = dependencies.networkClient
        outputBridge = dependencies.outputBridge
        reconnectScheduler = dependencies.reconnectScheduler
        self.store = store
    }

    func prepareForSurfaceShutdown() {
        stopSharing(userInitiated: true)
    }

    func toggle(from parentWindow: NSWindow?) {
        guard let surfaceView else { return }
        if surfaceView.sharingState.isActive {
            stopSharing(userInitiated: true)
            return
        }

        presentSettingsSheet(on: parentWindow)
    }

    /// Restart sharing using the last persisted relay/token without
    /// showing the settings sheet. Used by the launch-time resume flow
    /// after `TerminalWindowRestoration` brought back the surface.
    /// Returns false when no usable config is on disk (caller should
    /// drop the resume entry for this surface).
    @discardableResult
    func resumeFromPersistedConfig() -> Bool {
        guard let surfaceView else { return false }
        if surfaceView.sharingState.isActive { return true }

        let persisted = store.load()
        guard let relay = persisted.relay, !relay.isEmpty else { return false }
        let token: String = {
            if let t = persisted.token, !t.isEmpty { return t }
            return store.readKeychainToken(forRelay: relay)
        }()
        guard !token.isEmpty else { return false }

        // Reuse the auto-clean install on resume too — keep the
        // background prune job in sync with what the user last opted
        // into, in case it got removed since last quit.
        SessionSharingUploadAutoCleanInstaller.reconcile(
            enabled: persisted.uploadsAutoCleanEnabled,
            days: persisted.uploadsAutoCleanDays
        )

        startSharing(
            relay: relay,
            userToken: token,
            sessionName: "",
            persistConfig: true,
            uploadEnabled: persisted.webUploadEnabled
        )
        return true
    }

    /// Start sharing a surface that was just created on behalf of a
    /// remote client (create_session). Mirrors the resume path but uses
    /// the live relay/token of the requesting session, so it works even
    /// when the user never persisted a config. Returns the new session
    /// id, nil when this surface is already sharing.
    func startForRemoteCreate(
        relay: String,
        userToken: String,
        uploadEnabled: Bool
    ) -> String? {
        guard let surfaceView else { return nil }
        if surfaceView.sharingState.isActive { return nil }
        startSharing(
            relay: relay,
            userToken: userToken,
            sessionName: "",
            persistConfig: true,
            uploadEnabled: uploadEnabled
        )
        return sessionID
    }

    /// Remote "create_session": open a new surface anchored to this one
    /// and share it with this session's live relay/token. The one-shot
    /// must be armed before triggering the action because the window and
    /// tab paths build the new SurfaceView through notification plumbing
    /// — there is no return value to capture. Main thread only.
    private func createSessionOnHost(mode: SessionSharingCreateSessionMode) {
        guard let surface = surfaceView?.surface else { return }
        let relay = relayAddress
        let token = userToken
        guard !relay.isEmpty, !token.isEmpty else { return }
        let uploadEnabled = uploadPolicy.enabled
        SessionSharingPendingAutoShare.arm { [weak self] newView in
            guard let self,
                  let newSessionID = newView.startSessionSharingFromRemoteCreate(
                      relay: relay,
                      userToken: token,
                      uploadEnabled: uploadEnabled
                  )
            else { return }
            self.sendSessionCreatedIfPossible(newSessionID: newSessionID)
        }
        switch mode {
        case .window:
            performBindingAction("new_window", on: surface)
        case .tab:
            performBindingAction("new_tab", on: surface)
        case .splitRight:
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_RIGHT)
        case .splitDown:
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_DOWN)
        }
    }

    private func performBindingAction(_ action: String, on surface: ghostty_surface_t) {
        _ = ghostty_surface_binding_action(
            surface,
            action,
            UInt(action.lengthOfBytes(using: .utf8))
        )
    }

    /// Tell this (anchor) session's clients that the surface they asked
    /// for is up, carrying the new session id so the web client can jump
    /// straight to it. The frame can sit in the relay backlog until the
    /// next screen checkpoint prunes it, so the web side must dedupe by
    /// the new session id.
    private func sendSessionCreatedIfPossible(newSessionID: String) {
        guard let webSocket else { return }
        struct Frame: Codable {
            let type: String
            let sessionId: String
            let newSessionId: String

            enum CodingKeys: String, CodingKey {
                case type
                case sessionId = "session_id"
                case newSessionId = "new_session_id"
            }
        }
        let frame = Frame(
            type: "session_created",
            sessionId: sessionID,
            newSessionId: newSessionID
        )
        guard let data = try? JSONEncoder().encode(frame),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { _ in }
    }

    /// Remote "close_session": the app-side user already confirmed, so
    /// close the mac surface without the local "process is running"
    /// alert. Stop sharing first so the relay drops the session right
    /// away instead of waiting out the agent-offline grace. Main thread
    /// only.
    private func closeHostSurface() {
        guard let view = surfaceView else { return }
        let controller = view.window?.windowController as? BaseTerminalController
        stopSharing(userInitiated: true)
        controller?.closeSurface(view, withConfirmation: false)
    }

    func stopSharing(userInitiated: Bool) {
        shouldReconnect = false
        isStopping = true
        cancelPendingReconnectIfNeeded()
        setState(.stopping)
        detachOutputCallback()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        reconnectPolicy.reset()
        // Drop the title-sync dedupe key so the next session re-publishes
        // even if the title hasn't changed in the meantime.
        lastSentTitleUpdate = nil
        // Releasing the upload manager prevents already-dispatched pulls
        // from injecting paths into a torn-down surface; in-flight work
        // is allowed to finish (it captures `self?` weakly).
        uploadManager = nil
        restoreOriginalSharedResizeIfNeeded()
        isStopping = false
        setState(SessionSharingLifecycle.stateAfterStop(userInitiated: userInitiated))
    }

    /// Update the session-scoped upload policy. Called when the user
    /// flips the badge menu's "停止接受上传" toggle. New uploads see the
    /// new policy immediately; in-flight pulls finish under whatever
    /// policy they started with.
    func setUploadPolicy(_ next: SessionSharingUploadPolicy) {
        uploadPolicy = next
        uploadManager?.updatePolicy(next)
    }

    func captureOriginalSharedResizeIfNeeded(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, originalSharedResizeCheckpoint == nil else { return }
        originalSharedResizeCheckpoint = .init(cols: cols, rows: rows)
    }

    private func restoreOriginalSharedResizeIfNeeded() {
        guard let checkpoint = originalSharedResizeCheckpoint else { return }
        originalSharedResizeCheckpoint = nil
        DispatchQueue.main.async { [weak self] in
            self?.surfaceView?.restoreSharedResize(cols: checkpoint.cols, rows: checkpoint.rows)
        }
    }

    func enqueueOutgoing(_ data: Data) {
        outgoingQueue.async { [weak self] in
            guard let self, let webSocket = self.webSocket else { return }
            webSocket.send(.data(data)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.handleDisconnect(error: error)
                }
            }
        }
    }

    private func presentSettingsSheet(on parentWindow: NSWindow?) {
        let persisted = store.load()
        // Always open the sheet with an empty name field so the choice is
        // per-session: leaving it blank opts into live-syncing the macOS
        // tab title to the relay's session list, while typing a name
        // locks it. We deliberately ignore persisted.lastSessionName so
        // a name set in one tab does not bleed into another.
        let defaults = SessionSharingSheetDefaults(
            name: "",
            relay: persisted.relay ?? persisted.relayHistory.first ?? "",
            token: persisted.token ?? store.readKeychainToken(forRelay: persisted.relay ?? ""),
            relayHistory: persisted.relayHistory,
            webUploadEnabled: persisted.webUploadEnabled,
            uploadsAutoCleanEnabled: persisted.uploadsAutoCleanEnabled,
            uploadsAutoCleanDays: persisted.uploadsAutoCleanDays
        )

        let view = SessionSharingSheetView(
            name: defaults.name,
            relay: defaults.relay,
            token: defaults.token,
            saveConfig: true,
            uploadEnabled: defaults.webUploadEnabled,
            autoCleanEnabled: defaults.uploadsAutoCleanEnabled,
            autoCleanDays: defaults.uploadsAutoCleanDays,
            relayHistory: defaults.relayHistory,
            allowedDays: SessionSharingUploadAutoCleanInstaller.allowedDays,
            validate: { name, relay, token in
                SessionSharingSheetValidation.message(name: name, relay: relay, token: token)
            },
            onStart: { [weak self] result in
                guard let self else { return }
                self.dismissSettingsSheet(on: parentWindow)
                let relay = result.relay.trimmingCharacters(in: .whitespacesAndNewlines)
                let token = result.token.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)

                if let validationMessage = SessionSharingSheetValidation.message(
                    name: name, relay: relay, token: token) {
                    self.presentError(validationMessage, on: parentWindow)
                    return
                }

                // Reconcile the LaunchAgent every time the sheet is OK'd — even when
                // "保存配置" is off — so a one-off share still gives the user the cleaner
                // they ticked. The installer is idempotent so calling it on every OK is cheap.
                SessionSharingUploadAutoCleanInstaller.reconcile(
                    enabled: result.autoCleanEnabled, days: result.autoCleanDays)

                if result.saveConfig {
                    self.store.save(.init(
                        relay: relay,
                        token: token,
                        relayHistory: self.store.updatedHistory(relay, existing: defaults.relayHistory),
                        lastSessionName: nil,
                        webUploadEnabled: result.uploadEnabled,
                        uploadsAutoCleanEnabled: result.autoCleanEnabled,
                        uploadsAutoCleanDays: result.autoCleanDays
                    ))
                }

                self.startSharing(
                    relay: relay,
                    userToken: token,
                    sessionName: name,
                    persistConfig: result.saveConfig,
                    uploadEnabled: result.uploadEnabled
                )
            },
            onCancel: { [weak self] in
                self?.dismissSettingsSheet(on: parentWindow)
            }
        )

        // 主题：sheet 背景铺当前终端背景色（与命令面板 / XGhostty 风格统一）；
        // 单设 window.backgroundColor 会被 NSHostingController 内容盖住，故 SwiftUI 内容也铺一层。
        let bg = surfaceView.map { NSColor($0.derivedConfig.backgroundColor) } ?? .windowBackgroundColor
        let host = NSHostingController(rootView: AnyView(view.background(Color(nsColor: bg))))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = bg.cgColor
        let sheet = NSWindow(contentViewController: host)
        sheet.appearance = NSAppearance(named: bg.isLightColor ? .aqua : .darkAqua)
        sheet.backgroundColor = bg
        settingsSheet = sheet

        if let parentWindow {
            parentWindow.beginSheet(sheet)
        } else {
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    private func dismissSettingsSheet(on parentWindow: NSWindow?) {
        guard let sheet = settingsSheet else { return }
        if let parentWindow {
            parentWindow.endSheet(sheet)
        } else {
            sheet.close()
        }
        settingsSheet = nil
    }

    private func startSharing(
        relay: String,
        userToken: String,
        sessionName: String,
        persistConfig: Bool,
        uploadEnabled: Bool = true
    ) {
        stopActiveConnectionForRestart()
        self.relayAddress = relay
        self.userToken = userToken
        self.sessionName = sessionName
        self.didPersistConfig = persistConfig
        self.sessionID = UUID().uuidString.lowercased()
        self.shouldReconnect = true
        self.reconnectPolicy.reset()
        self.isStopping = false
        // Snapshot the share-time decision into the policy that the
        // upload manager will read on every upload_ready frame. The
        // sizes come from the defaults — the share sheet doesn't expose
        // them in v0 to keep the dialog simple.
        self.uploadPolicy = uploadEnabled
            ? .defaultEnabled
            : .disabled
        attachOutputCallback()
        setState(.connecting)

        Task { [weak self] in
            await self?.registerAndConnect(initialAttempt: true)
        }
    }

    private func stopActiveConnectionForRestart() {
        cancelPendingReconnectIfNeeded()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        detachOutputCallback()
    }

    private func registerAndConnect(initialAttempt: Bool) async {
        do {
            let request = try SessionSharingRequestBuilder.registerRequest(
                relayAddress: relayAddress,
                payload: SessionSharingRegisterRequest(
                sessionID: sessionID,
                name: sessionName,
                token: userToken
            ))

            let (data, response) = try await networkClient.data(for: request)
            let registerResponse = try SessionSharingResponseParser.parseRegisterResponse(
                data: data,
                response: response,
                expectedSessionID: sessionID
            )
            try connectWebSocket(agentToken: registerResponse.agentToken)
        } catch {
            handleConnectFailure(error, initialAttempt: initialAttempt)
        }
    }

    private func connectWebSocket(agentToken: String) throws {
        let request = try SessionSharingRequestBuilder.agentWebSocketRequest(
            relayAddress: relayAddress,
            sessionID: sessionID,
            agentToken: agentToken
        )
        let webSocket = networkClient.webSocketTask(with: request)
        self.webSocket = webSocket
        webSocket.resume()
        setState(.sharing)
        ensureUploadManager()
        sendHelloIfPossible()
        sendAppearanceIfPossible()
        sendScreenSnapshotIfPossible()
        // Try to publish the current PTY title right away so the relay's
        // session list isn't stuck at an empty name during the gap before
        // the next `setTitle` callback fires.
        if let currentTitle = surfaceView?.title {
            notifyTitleChanged(currentTitle)
        }
        receiveNextMessage()
    }

    private func ensureUploadManager() {
        if uploadManager != nil { return }
        let manager = SessionSharingUploadManager(
            sessionID: sessionID,
            relayAddress: relayAddress,
            uploadsRoot: SessionSharingUploadPaths.defaultUploadsRoot(),
            auditLogURL: SessionSharingUploadPaths.defaultAuditLogURL(),
            policy: uploadPolicy,
            injectPath: { [weak self] payload in
                // The upload manager runs its pull on a background task,
                // so hop to the main queue before touching the AppKit
                // view. We follow the same pattern as handleIncoming.
                let data = Data(payload.utf8)
                DispatchQueue.main.async { [weak self] in
                    self?.surfaceView?.sendSharedBytes(data)
                }
            },
            sendAck: { [weak self] envelope in
                self?.sendUploadAck(envelope)
            }
        )
        uploadManager = manager
    }

    private func sendUploadAck(_ envelope: SessionSharingUploadAckEnvelope) {
        guard let webSocket else { return }
        guard let data = try? JSONEncoder().encode(envelope),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func sendHelloIfPossible() {
        guard let webSocket, let surface = surfaceView?.surface else { return }
        let size = ghostty_surface_size(surface)
        let payload = SessionSharingControlFrame.hello(
            id: sessionID,
            name: sessionName,
            cols: Int(size.columns),
            rows: Int(size.rows)
        )
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func sendAppearanceIfPossible() {
        guard let webSocket else { return }
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let cfg = appDelegate.ghostty.config.config,
              let payload = SessionSharingAppearancePayload.capture(
                from: cfg,
                sessionID: sessionID
              )
        else { return }
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func sendScreenSnapshotIfPossible() {
        guard let webSocket, let surface = surfaceView?.surface else { return }
        guard let payload = SessionSharingScreenSnapshotPayload.capture(
            from: surface,
            sessionID: sessionID
        ) else { return }
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func sendScrollbackResponseIfPossible(before: Int, count: Int) {
        guard let webSocket, let surface = surfaceView?.surface else { return }
        guard let payload = SessionSharingScrollbackPayload.respond(
            from: surface,
            sessionID: sessionID,
            before: before,
            requestedCount: count
        ) else { return }
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    /// Called from `SurfaceView.setTitle`'s debounced callback whenever
    /// the PTY-reported title changes. When the user opted into title
    /// sync by leaving the sharing sheet's name field blank, we forward
    /// the new value to the relay as a `name_update` control frame so
    /// the relay's session list reflects the macOS tab title (e.g.
    /// `~/WorkSpace`). When the user supplied an explicit name the
    /// choice is locked and nothing is sent.
    func notifyTitleChanged(_ value: String) {
        guard sessionName.isEmpty else { return }
        sendNameUpdateIfPossible(value)
    }

    private func sendNameUpdateIfPossible(_ value: String) {
        guard let webSocket else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip empty values: register already left Session.name empty
        // and there is nothing meaningful to publish until the PTY
        // actually reports a title.
        guard !trimmed.isEmpty else { return }
        guard trimmed != lastSentTitleUpdate else { return }
        let payload = SessionSharingControlFrame.nameUpdate(id: sessionID, name: trimmed)
        guard let data = try? JSONEncoder().encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        lastSentTitleUpdate = trimmed
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func receiveNextMessage() {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleDisconnect(error: error)
            case .success(let message):
                self.handleIncoming(message)
                self.receiveNextMessage()
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            DispatchQueue.main.async { [weak self] in
                self?.surfaceView?.sendSharedBytes(data)
            }

        case .string(let text):
            if handleControlFrame(text) {
                return
            }

            guard let data = text.data(using: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.surfaceView?.sendSharedBytes(data)
            }

        @unknown default:
            break
        }
    }

    private func handleControlFrame(_ text: String) -> Bool {
        switch SessionSharingInboundFrameAction.parse(text: text, sessionID: sessionID) {
        case .forwardToTerminal:
            return false

        case .ignore:
            return true

        case .resize(let cols, let rows):
            DispatchQueue.main.async { [weak self] in
                self?.surfaceView?.applySharedResize(cols: cols, rows: rows)
            }
            return true

        case .restoreOriginalSize:
            restoreOriginalSharedResizeIfNeeded()
            return true

        case .clientConnected:
            // Relay tells us a fresh client just joined. Re-emit the
            // metadata the browser needs to bootstrap (hello carries
            // host cols/rows, appearance carries colours / font size)
            // alongside the screen snapshot. The relay only retains
            // hello/appearance across screen checkpoints (relay
            // `_is_essential_metadata`), so without re-sending them
            // here a client that reconnects after the initial burst
            // would land on whatever the relay still has backlogged —
            // typically just binary PTY bytes, which doesn't include
            // grid dimensions and forces FitAddon to pick a width
            // narrower than the host, causing wrap.
            sendHelloIfPossible()
            sendAppearanceIfPossible()
            sendScreenSnapshotIfPossible()
            return true

        case .fetchScrollback(let before, let count):
            sendScrollbackResponseIfPossible(before: before, count: count)
            return true

        case .createSession(let mode):
            DispatchQueue.main.async { [weak self] in
                self?.createSessionOnHost(mode: mode)
            }
            return true

        case .closeSession:
            DispatchQueue.main.async { [weak self] in
                self?.closeHostSurface()
            }
            return true

        case .handleUploadReady(let envelope):
            // The relay has staged a browser-side upload and is asking us
            // to pull it. Hand off to the upload manager; it owns policy,
            // disk, hashing and the path-injection ack.
            ensureUploadManager()
            uploadManager?.handle(envelope)
            return true

        case .sendPong(let pong):
            guard let webSocket else { return true }
            guard let pongData = try? JSONEncoder().encode(pong),
                  let pongText = String(data: pongData, encoding: .utf8) else { return true }
            webSocket.send(.string(pongText)) { _ in }
            return true
        }
    }

    private func handleConnectFailure(_ error: Error, initialAttempt: Bool) {
        let plan = SessionSharingControllerRecovery.connectFailurePlan(
            initialAttempt: initialAttempt,
            shouldReconnect: shouldReconnect,
            isStopping: isStopping,
            reconnectPolicy: &reconnectPolicy
        )
        if plan.shouldPresentError {
            presentError(
                SessionSharingErrorPresentation.actionableMessage(for: error),
                on: surfaceView?.window
            )
        }
        applyRecoveryAction(plan.action)
    }

    private func handleDisconnect(error: Error) {
        // Read the close code before nil-ing the task. Application close
        // frames (e.g. relay's 4401 token_expired) land here in
        // URLSessionWebSocketTask.closeCode; raw network failures keep
        // the default `.invalid` (raw value 0).
        let closeCode = webSocket?.closeCode.rawValue ?? 0
        webSocket = nil
        let action = SessionSharingControllerRecovery.disconnectAction(
            closeCode: closeCode,
            shouldReconnect: shouldReconnect,
            isStopping: isStopping,
            reconnectPolicy: &reconnectPolicy
        )
        applyRecoveryAction(action)
    }

    private func applyRecoveryAction(_ action: SessionSharingRecoveryAction) {
        switch action {
        case .idle:
            setState(.idle)
            return
        case .reconnect(let seconds):
            scheduleReconnect(after: seconds)
        }
    }

    private func scheduleReconnect(after seconds: TimeInterval) {
        let plan = reconnectCoordinator.prepareToSchedule(after: seconds)
        if plan.shouldCancelExisting {
            reconnectTask?.cancel()
        }
        // Surface the actual scheduled delay (which may differ from the
        // requested one if the coordinator collapsed it), so the badge
        // can show "重连中（${X}s 后）" instead of a constant "重连中...".
        setState(.reconnecting(after: plan.delay))
        reconnectTask = reconnectScheduler.schedule(after: plan.delay) { [weak self] in
            self?.reconnectCoordinator.markReconnectFired()
            Task { [weak self] in
                await self?.registerAndConnect(initialAttempt: false)
            }
        }
    }

    private func cancelPendingReconnectIfNeeded() {
        if reconnectCoordinator.cancelScheduledReconnect() {
            reconnectTask?.cancel()
        }
        reconnectTask = nil
    }

    private func attachOutputCallback() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        outputBridge.attach(surface: surfaceView?.surface, context: context)
    }

    private func detachOutputCallback() {
        outputBridge.detach(surface: surfaceView?.surface)
    }

    private func setState(_ state: Ghostty.OSSurfaceView.SharingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let surfaceView = self.surfaceView else { return }
            surfaceView.sharingState = state
            surfaceView.sharingWindowTitleSuffix = state.titleSuffix
            // Breadcrumb for auto-resume on next launch. `.sharing` is
            // the only point we know the relay actually accepted us;
            // `.idle`/`.error` are the only terminal states. Transient
            // states (.connecting/.reconnecting/.stopping) intentionally
            // leave the breadcrumb untouched so a mid-reconnect quit
            // still gets resumed.
            switch state {
            case .sharing:
                SessionSharingResumeStore.shared.add(surfaceView.id)
            case .idle, .error:
                SessionSharingResumeStore.shared.remove(surfaceView.id)
            case .connecting, .reconnecting, .stopping:
                break
            }
        }
    }

    private func presentError(_ message: String, on parentWindow: NSWindow?) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "会话共享"
            alert.informativeText = message
            alert.alertStyle = .warning
            if let parentWindow {
                alert.beginSheetModal(for: parentWindow)
            } else {
                alert.runModal()
            }
        }
    }

}

struct SessionSharingReconnectPolicy {
    private(set) var attempt: Int = 0

    mutating func reset() {
        attempt = 0
    }

    mutating func nextDelay() -> TimeInterval {
        attempt += 1
        return min(pow(2.0, Double(max(0, attempt - 1))), 30.0)
    }
}

enum SessionSharingInboundFrameAction: Equatable {
    case forwardToTerminal
    case ignore
    case sendPong(SessionSharingControlFrame)
    case resize(cols: Int, rows: Int)
    case restoreOriginalSize
    case clientConnected
    case fetchScrollback(before: Int, count: Int)
    case handleUploadReady(SessionSharingUploadReadyEnvelope)
    case createSession(mode: SessionSharingCreateSessionMode)
    case closeSession

    static func parse(text: String, sessionID: String) -> Self {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(SessionSharingInboundControlFrame.self, from: data) else {
            return .forwardToTerminal
        }

        switch frame.type {
        case "ping":
            return .sendPong(.pong(id: sessionID))
        case "resize":
            if let cols = frame.cols, let rows = frame.rows, cols > 0, rows > 0 {
                return .resize(cols: cols, rows: rows)
            }
            return .ignore
        case "client_disconnect":
            return .restoreOriginalSize
        case "client_connected":
            return .clientConnected
        case "fetch_scrollback":
            if let before = frame.before, let count = frame.count, before >= 0, count > 0 {
                return .fetchScrollback(before: before, count: count)
            }
            return .ignore
        case "upload_ready":
            // upload_ready carries its own dense schema (upload_id, name,
            // size, sha256, pull_token, pull_url); decode against the
            // dedicated envelope rather than overload
            // SessionSharingInboundControlFrame with upload fields. If the
            // envelope is malformed we *consume* the frame (.ignore)
            // instead of letting bogus bytes leak into the terminal.
            if let envelope = try? JSONDecoder().decode(
                SessionSharingUploadReadyEnvelope.self, from: data
            ), envelope.isValid {
                return .handleUploadReady(envelope)
            }
            return .ignore
        case "create_session":
            // mode is validated against the enum so a malformed frame
            // can't trigger surface creation; consume (.ignore) rather
            // than letting the JSON leak into the terminal.
            if let raw = frame.mode,
               let mode = SessionSharingCreateSessionMode(rawValue: raw) {
                return .createSession(mode: mode)
            }
            return .ignore
        case "close_session":
            return .closeSession
        case "hello", "pong", "scrollback":
            return .ignore
        default:
            return .forwardToTerminal
        }
    }
}

/// How a remotely requested surface opens relative to the surface that
/// received the create_session frame: tab joins its window, splits
/// divide the surface itself.
enum SessionSharingCreateSessionMode: String, Equatable {
    case window
    case tab
    case splitRight = "split_right"
    case splitDown = "split_down"
}

enum SessionSharingRelayURLBuilder {
    private enum RelayHostTrust {
        case local
        case remote
    }

    private enum Transport {
        case http
        case websocket
    }

    static func url(
        for relay: String,
        scheme: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        try url(
            for: relay,
            transport: scheme == "wss" || scheme == "ws" ? .websocket : .http,
            defaultScheme: scheme,
            path: path,
            queryItems: queryItems
        )
    }

    private static func url(
        for relay: String,
        transport: Transport,
        defaultScheme: String,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionSharingError.invalidRelayAddress }
        let raw = trimmed.contains("://") ? trimmed : "\(defaultScheme)://\(trimmed)"
        guard var components = URLComponents(string: raw) else {
            throw SessionSharingError.invalidRelayAddress
        }
        try validateExplicitScheme(components.scheme, host: components.host)
        components.scheme = try scheme(for: components.scheme, transport: transport, defaultScheme: defaultScheme)
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard components.host?.isEmpty == false else {
            throw SessionSharingError.invalidRelayAddress
        }
        guard let url = components.url else {
            throw SessionSharingError.invalidRelayAddress
        }
        return url
    }

    private static func validateExplicitScheme(_ explicitScheme: String?, host: String?) throws {
        guard let explicitScheme else { return }
        switch explicitScheme.lowercased() {
        case "http", "ws":
            guard trust(for: host) == .local else {
                throw SessionSharingError.insecureRelayAddress
            }
        default:
            break
        }
    }

    private static func scheme(
        for explicitScheme: String?,
        transport: Transport,
        defaultScheme: String
    ) throws -> String {
        guard let explicitScheme else { return defaultScheme }
        switch (transport, explicitScheme.lowercased()) {
        case (.http, "http"), (.http, "https"):
            return explicitScheme.lowercased()
        case (.http, "ws"):
            return "http"
        case (.http, "wss"):
            return "https"
        case (.websocket, "ws"), (.websocket, "wss"):
            return explicitScheme.lowercased()
        case (.websocket, "http"):
            return "ws"
        case (.websocket, "https"):
            return "wss"
        default:
            throw SessionSharingError.invalidRelayAddress
        }
    }

    private static func trust(for host: String?) -> RelayHostTrust {
        guard let host else { return .remote }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" {
            return .local
        }
        if let ipv4 = IPv4Address(normalized) {
            let octets = ipv4.rawValue
            if octets[0] == 127 {
                return .local
            }
            if octets[0] == 10 {
                return .local
            }
            if octets[0] == 192, octets[1] == 168 {
                return .local
            }
            if octets[0] == 172, (16...31).contains(octets[1]) {
                return .local
            }
            return .remote
        }
        if let ipv6 = IPv6Address(normalized) {
            if ipv6.isLoopback || ipv6.isLinkLocal || ipv6.isUniqueLocal {
                return .local
            }
            return .remote
        }
        return .remote
    }
}

enum SessionSharingRequestBuilder {
    static func registerRequest(
        relayAddress: String,
        payload: SessionSharingRegisterRequest
    ) throws -> URLRequest {
        let registerURL = try SessionSharingRelayURLBuilder.url(
            for: relayAddress,
            scheme: "https",
            path: "/api/register"
        )
        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    static func agentWebSocketRequest(
        relayAddress: String,
        sessionID: String,
        agentToken: String
    ) throws -> URLRequest {
        let wsURL = try SessionSharingRelayURLBuilder.url(
            for: relayAddress,
            scheme: "wss",
            path: "/ws/agent",
            queryItems: [URLQueryItem(name: "id", value: sessionID)]
        )
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(agentToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

enum SessionSharingResponseParser {
    static func parseRegisterResponse(
        data: Data,
        response: URLResponse,
        expectedSessionID: String
    ) throws -> SessionSharingRegisterResponse {
        guard let http = response as? HTTPURLResponse else {
            throw SessionSharingError.invalidResponse
        }
        if http.statusCode == 401 {
            // The relay rejected the user token. Surface this as a
            // distinct error so the sheet can tell the user to fix
            // their token instead of pointing them at "invalid
            // response", which sounds like a server bug.
            throw SessionSharingError.userTokenRejected
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionSharingError.invalidResponse
        }

        let registerResponse = try JSONDecoder().decode(SessionSharingRegisterResponse.self, from: data)
        guard !registerResponse.agentToken.isEmpty else {
            throw SessionSharingError.invalidResponse
        }
        if let responseSessionID = registerResponse.sessionID, responseSessionID != expectedSessionID {
            throw SessionSharingError.invalidResponse
        }

        return registerResponse
    }
}

enum SessionSharingKeyEquivalentPolicy {
    static func shouldUseStandardResponderChain(
        firstResponder: NSResponder?,
        hasAttachedSheet: Bool = false
    ) -> Bool {
        if hasAttachedSheet {
            return true
        }
        guard let textView = firstResponder as? NSTextView else { return false }
        return textView.isFieldEditor
    }
}

enum SessionSharingEditActionPolicy {
    /// Walks the responder chain rooted at `firstResponder` to find the first responder
    /// that handles `action`. `excluded` is skipped so the surface view never recurses
    /// into itself when redispatching.
    static func handler(
        for action: Selector,
        startingAt firstResponder: NSResponder?,
        excluding excluded: NSResponder? = nil
    ) -> NSResponder? {
        var current = firstResponder
        while let responder = current {
            if responder !== excluded, responder.responds(to: action) {
                return responder
            }
            current = responder.nextResponder
        }
        return nil
    }
}

enum SessionSharingDisconnectTransition: Equatable {
    case idle
    case reconnect
}

enum SessionSharingRecoveryAction: Equatable {
    case idle
    case reconnect(after: TimeInterval)
}

struct SessionSharingConnectFailurePlan: Equatable {
    let shouldPresentError: Bool
    let action: SessionSharingRecoveryAction
}

struct SessionSharingReconnectSchedulePlan: Equatable {
    let delay: TimeInterval
    let shouldCancelExisting: Bool
}

protocol SessionSharingNetworkClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask
}

extension URLSession: SessionSharingNetworkClient {}

final class SessionSharingScheduledTask {
    private let cancelHandler: @Sendable () -> Void

    init(cancelHandler: @escaping @Sendable () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        cancelHandler()
    }
}

struct SessionSharingReconnectScheduler {
    let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> SessionSharingScheduledTask

    static func live(queue: DispatchQueue = .main) -> Self {
        .init { delay, action in
            let workItem = DispatchWorkItem(block: action)
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
            return SessionSharingScheduledTask {
                workItem.cancel()
            }
        }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> SessionSharingScheduledTask {
        schedule(delay, action)
    }
}

struct SessionSharingOutputBridge {
    let attach: (_ surface: ghostty_surface_t?, _ context: UnsafeMutableRawPointer?) -> Void
    let detach: (_ surface: ghostty_surface_t?) -> Void

    static let live = Self(
        attach: { surface, context in
            guard let surface else { return }
            ghostty_surface_set_output_callback(surface, sessionSharingOutputCallback, context)
        },
        detach: { surface in
            guard let surface else { return }
            ghostty_surface_set_output_callback(surface, nil, nil)
        }
    )

    func attach(surface: ghostty_surface_t?, context: UnsafeMutableRawPointer?) {
        attach(surface, context)
    }

    func detach(surface: ghostty_surface_t?) {
        detach(surface)
    }
}

struct SessionSharingControllerDependencies {
    let networkClient: any SessionSharingNetworkClient
    let outputBridge: SessionSharingOutputBridge
    let reconnectScheduler: SessionSharingReconnectScheduler

    static func live(session: URLSession = URLSession(configuration: .default)) -> Self {
        .init(
            networkClient: session,
            outputBridge: .live,
            reconnectScheduler: .live()
        )
    }
}

struct SessionSharingReconnectCoordinator {
    private(set) var hasScheduledReconnect = false

    mutating func prepareToSchedule(after delay: TimeInterval) -> SessionSharingReconnectSchedulePlan {
        let plan = SessionSharingReconnectSchedulePlan(
            delay: delay,
            shouldCancelExisting: hasScheduledReconnect
        )
        hasScheduledReconnect = true
        return plan
    }

    mutating func cancelScheduledReconnect() -> Bool {
        let didCancel = hasScheduledReconnect
        hasScheduledReconnect = false
        return didCancel
    }

    mutating func markReconnectFired() {
        hasScheduledReconnect = false
    }
}

/// Private WebSocket close codes that the relay uses to tell the host
/// something the host can act on. Mirrors the relay's
/// `ws_close_with_code` constants in
/// `contrib/session-sharing/relay/server.py` and the matching browser
/// handling in `ghostty-web-client/src/main.js`.
enum SessionSharingCloseCode {
    /// `watch_token_expiry` fires when `session.expires_at` lapses.
    /// The host has to re-register to get a fresh agent token; there is
    /// no point ramping an exponential backoff for it.
    static let tokenExpired = 4401

    /// Heartbeat timeout or slow-consumer drop. Transient, normal
    /// reconnect with backoff is the right behavior.
    static let timeoutOrSlow = 4408
}

enum SessionSharingControllerRecovery {
    static func connectFailurePlan(
        initialAttempt: Bool,
        shouldReconnect: Bool,
        isStopping: Bool,
        reconnectPolicy: inout SessionSharingReconnectPolicy
    ) -> SessionSharingConnectFailurePlan {
        .init(
            shouldPresentError: SessionSharingLifecycle.shouldPresentConnectFailure(initialAttempt: initialAttempt),
            action: disconnectAction(
                closeCode: 0,
                shouldReconnect: shouldReconnect,
                isStopping: isStopping,
                reconnectPolicy: &reconnectPolicy
            )
        )
    }

    static func disconnectAction(
        closeCode: Int,
        shouldReconnect: Bool,
        isStopping: Bool,
        reconnectPolicy: inout SessionSharingReconnectPolicy
    ) -> SessionSharingRecoveryAction {
        switch SessionSharingLifecycle.transitionAfterDisconnect(
            shouldReconnect: shouldReconnect,
            isStopping: isStopping
        ) {
        case .idle:
            return .idle
        case .reconnect:
            // 4401 = the relay's session token expired. The host has to
            // re-register before any reconnect can succeed and the relay
            // has already told us the previous backoff history is
            // irrelevant for this case, so reset the backoff and try
            // immediately. Other codes (heartbeat / slow consumer / raw
            // network errors) keep the existing exponential ramp.
            if closeCode == SessionSharingCloseCode.tokenExpired {
                reconnectPolicy.reset()
                return .reconnect(after: 0)
            }
            return .reconnect(after: reconnectPolicy.nextDelay())
        }
    }
}

enum SessionSharingLifecycle {
    static func stateAfterStop(userInitiated: Bool) -> Ghostty.OSSurfaceView.SharingState {
        userInitiated ? .idle : .error("共享已停止")
    }

    static func shouldPresentConnectFailure(initialAttempt: Bool) -> Bool {
        initialAttempt
    }

    static func transitionAfterDisconnect(
        shouldReconnect: Bool,
        isStopping: Bool
    ) -> SessionSharingDisconnectTransition {
        guard shouldReconnect, !isStopping else { return .idle }
        return .reconnect
    }
}

struct SessionSharingPersistedConfig: Codable, Equatable {
    // Hoisted up so SessionSharingSheetDefaults can reference the type.
    // The actual implementation still lives below; this is just a
    // compile-time forward declaration via `typealias`.
    var relay: String?
    var token: String?
    var relayHistory: [String]
    var lastSessionName: String?
    var webUploadEnabled: Bool
    var uploadsAutoCleanEnabled: Bool
    var uploadsAutoCleanDays: Int

    init(
        relay: String? = nil,
        token: String? = nil,
        relayHistory: [String] = [],
        lastSessionName: String? = nil,
        webUploadEnabled: Bool = true,
        uploadsAutoCleanEnabled: Bool = true,
        uploadsAutoCleanDays: Int = SessionSharingUploadAutoCleanInstaller.defaultDays
    ) {
        self.relay = relay
        self.token = token
        self.relayHistory = relayHistory
        self.lastSessionName = lastSessionName
        self.webUploadEnabled = webUploadEnabled
        self.uploadsAutoCleanEnabled = uploadsAutoCleanEnabled
        self.uploadsAutoCleanDays = uploadsAutoCleanDays
    }

    enum CodingKeys: String, CodingKey {
        case relay, token, relayHistory, lastSessionName, webUploadEnabled
        case uploadsAutoCleanEnabled, uploadsAutoCleanDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relay = try container.decodeIfPresent(String.self, forKey: .relay)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        relayHistory = try container
            .decodeIfPresent([String].self, forKey: .relayHistory) ?? []
        lastSessionName = try container.decodeIfPresent(
            String.self, forKey: .lastSessionName)
        // Older configs (pre-upload) don't have this key; default to
        // true so existing users get the new feature out of the box.
        // If you'd rather have opt-in, flip this default.
        webUploadEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .webUploadEnabled) ?? true
        // Same logic for the auto-clean fields. Older configs default to
        // enabled with the installer's default retention window so
        // existing users start getting tidy uploads/ trees automatically.
        uploadsAutoCleanEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .uploadsAutoCleanEnabled) ?? true
        let storedDays = try container.decodeIfPresent(
            Int.self, forKey: .uploadsAutoCleanDays)
            ?? SessionSharingUploadAutoCleanInstaller.defaultDays
        // Snap to one of the allowed retention buckets so a corrupted
        // config (or a manual edit) can never schedule a 0-day prune.
        uploadsAutoCleanDays = SessionSharingUploadAutoCleanInstaller
            .allowedDays.contains(storedDays)
            ? storedDays
            : SessionSharingUploadAutoCleanInstaller.defaultDays
    }
}

private struct SessionSharingSheetDefaults {
    let name: String
    let relay: String
    let token: String
    let relayHistory: [String]
    let webUploadEnabled: Bool
    let uploadsAutoCleanEnabled: Bool
    let uploadsAutoCleanDays: Int
}

enum SessionSharingSheetValidation {
    static func message(name: String, relay: String, token: String) -> String? {
        _ = name
        let trimmedRelay = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRelay.isEmpty, !trimmedToken.isEmpty else {
            return "共享配置不完整"
        }

        do {
            _ = try SessionSharingRelayURLBuilder.url(
                for: trimmedRelay,
                scheme: "https",
                path: "/api/register"
            )
            return nil
        } catch let error as SessionSharingError {
            return error.localizedDescription
        } catch {
            return "共享配置不完整"
        }
    }
}

struct SessionSharingConfigStore {
    private let fileManager: FileManager
    private let keychainService: String
    private let fileURL: URL
    private let keychainTokenReader: (String, String) -> String?
    private let keychainTokenWriter: (String, String, String) -> Bool
    private let logError: (String) -> Void

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        keychainService: String = "com.mitchellh.ghostty.session-sharing",
        keychainTokenReader: @escaping (String, String) -> String? = SessionSharingConfigStore.defaultKeychainTokenReader,
        keychainTokenWriter: @escaping (String, String, String) -> Bool = SessionSharingConfigStore.defaultKeychainTokenWriter,
        logError: @escaping (String) -> Void = { message in
            AppDelegate.logger.error("\(message)")
        }
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.keychainService = keychainService
        self.keychainTokenReader = keychainTokenReader
        self.keychainTokenWriter = keychainTokenWriter
        self.logError = logError
    }

    func load() -> SessionSharingPersistedConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return .init() }

        let attributes = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let permissions = attributes[.posixPermissions] as? NSNumber
        var config = (try? JSONDecoder().decode(SessionSharingPersistedConfig.self, from: data)) ?? .init()
        if permissions?.intValue != 0o600 {
            config.token = nil
        }
        return config
    }

    @discardableResult
    func save(_ config: SessionSharingPersistedConfig) -> Bool {
        let fileSucceeded: Bool
        do {
            let dir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            fileSucceeded = true
        } catch {
            logError("failed to save session sharing config: \(SessionSharingTokenRedaction.redact(error: error))")
            fileSucceeded = false
        }

        // Best-effort Keychain mirror so the token survives a 0o600
        // permission breakage on the on-disk config (the load path
        // already drops the in-file token in that case and falls back
        // to the Keychain reader). Keychain failure does not fail save.
        if let token = config.token, !token.isEmpty,
           let relay = config.relay, !relay.isEmpty {
            _ = writeKeychainToken(token, forRelay: relay)
        }

        return fileSucceeded
    }

    func updatedHistory(_ relay: String, existing: [String]) -> [String] {
        var history = existing.filter { $0 != relay }
        history.insert(relay, at: 0)
        return Array(history.prefix(8))
    }

    func readKeychainToken(forRelay relay: String) -> String {
        guard !relay.isEmpty else { return "" }
        return keychainTokenReader(keychainService, relay) ?? ""
    }

    @discardableResult
    func writeKeychainToken(_ token: String, forRelay relay: String) -> Bool {
        guard !relay.isEmpty, !token.isEmpty else { return false }
        return keychainTokenWriter(keychainService, relay, token)
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("sharing.conf", isDirectory: false)
    }

    private static func defaultKeychainTokenReader(service: String, relay: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: relay,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    private static func defaultKeychainTokenWriter(service: String, relay: String, token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        // Try update first so we don't churn the Keychain item every save.
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: relay,
        ]
        let updateAttrs: [CFString: Any] = [
            kSecValueData: data,
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        // No prior entry — insert a fresh one. WhenUnlocked matches the
        // user-visible "active terminal session" lifetime; we don't want
        // the token surviving a logout/reboot in clear text.
        var insertAttrs = lookup
        insertAttrs[kSecValueData] = data
        insertAttrs[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insertAttrs as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}

struct SessionSharingRegisterRequest: Codable, Equatable {
    let sessionID: String
    let name: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case name
        case token
    }
}

struct SessionSharingRegisterResponse: Codable, Equatable {
    let sessionID: String?
    let agentToken: String
    let clientToken: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agentToken = "agent_token"
        case clientToken = "client_token"
        case expiresAt = "expires_at"
    }
}

struct SessionSharingControlFrame: Codable, Equatable {
    let type: String
    let id: String
    let name: String?
    let cols: Int?
    let rows: Int?

    static func hello(id: String, name: String, cols: Int, rows: Int) -> Self {
        .init(type: "hello", id: id, name: name, cols: cols, rows: rows)
    }

    static func pong(id: String) -> Self {
        .init(type: "pong", id: id, name: nil, cols: nil, rows: nil)
    }

    /// Live-sync of the macOS tab title into the relay's `Session.name`.
    /// The relay consumes this frame to update its session list and does
    /// not forward it to web clients; see `ws_agent_loop` in
    /// `contrib/session-sharing/relay/server.py`.
    static func nameUpdate(id: String, name: String) -> Self {
        .init(type: "name_update", id: id, name: name, cols: nil, rows: nil)
    }
}

private struct SessionSharingInboundControlFrame: Codable {
    let type: String
    let cols: Int?
    let rows: Int?
    let before: Int?
    let count: Int?
    let mode: String?
}

/// Relay → agent: a browser-uploaded file is staged on the relay and the
/// agent should pull it. The agent is the one that decides whether to
/// accept (per `SessionSharingUploadPolicy`), so the relay only stages
/// the file; nothing lands on disk until the agent calls the pull URL.
struct SessionSharingUploadReadyEnvelope: Codable, Equatable {
    let type: String
    let uploadID: String
    let name: String
    let size: Int64
    let sha256: String?
    let pullToken: String
    let pullURL: String

    private enum CodingKeys: String, CodingKey {
        case type
        case uploadID = "upload_id"
        case name
        case size
        case sha256
        case pullToken = "pull_token"
        case pullURL = "pull_url"
    }

    /// Minimum-viable shape check. Anything beyond this is the manager's
    /// job — e.g. policy/size/extension rules — but `parse` short-circuits
    /// on these so we don't ack on a frame that's literally unusable.
    var isValid: Bool {
        type == "upload_ready"
            && Self.isWellFormedUploadID(uploadID)
            && !name.isEmpty
            && size > 0
            && !pullToken.isEmpty
            && pullURL.hasPrefix("/api/upload/")
    }

    /// Defense-in-depth: the relay is supposed to generate uploadID via
    /// `secrets.token_urlsafe(16)`, but the agent must not trust that.
    /// A compromised / spoofed relay could send anything here, and we
    /// later splice the value into a file path
    /// (`finalURL.appendingPathExtension("partial-<uploadID>")`). If the
    /// uploadID contained `/`, `..`, NUL, or other path metacharacters
    /// the partial file could land outside the per-session uploads
    /// directory. We whitelist the base64url charset that
    /// `token_urlsafe` actually emits.
    static func isWellFormedUploadID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        for scalar in value.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
                continue
            default:
                return false
            }
        }
        return true
    }
}

/// agent → relay → all clients: result of a single upload attempt.
struct SessionSharingUploadAckEnvelope: Codable, Equatable {
    let type: String
    let uploadID: String
    let ok: Bool
    let path: String?
    let bytesWritten: Int64?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case uploadID = "upload_id"
        case ok
        case path
        case bytesWritten = "bytes_written"
        case reason
    }

    static func success(
        uploadID: String, path: String, bytesWritten: Int64
    ) -> Self {
        .init(
            type: "upload_ack",
            uploadID: uploadID,
            ok: true,
            path: path,
            bytesWritten: bytesWritten,
            reason: nil
        )
    }

    static func failure(uploadID: String, reason: String) -> Self {
        .init(
            type: "upload_ack",
            uploadID: uploadID,
            ok: false,
            path: nil,
            bytesWritten: nil,
            reason: reason
        )
    }
}

enum SessionSharingUploadRejectionReason: String {
    case agentDisabled = "agent_disabled"
    case sizeExceedsFile = "size_exceeds_file_limit"
    case sizeExceedsSession = "size_exceeds_session_limit"
    case sanitizeFailed = "sanitize_failed"
    case pullFailed = "pull_failed"
    case hashMismatch = "hash_mismatch"
    case diskFull = "disk_full"
    case writeFailed = "write_failed"
}

/// Per-session upload policy decided at share-sheet time. The user is
/// remote when uploads happen, so we deliberately do *not* prompt on
/// every transfer; the policy is the one and only authorisation gate.
struct SessionSharingUploadPolicy: Equatable {
    /// Master switch. `false` rejects every upload_ready immediately.
    var enabled: Bool
    /// Per-file cap. Files larger than this never get pulled.
    var maxFileBytes: Int64
    /// Cumulative cap across the session lifetime. The manager keeps a
    /// running counter; once exceeded, further uploads are rejected even
    /// if individually below maxFileBytes.
    var maxSessionBytes: Int64

    static let defaultEnabled = SessionSharingUploadPolicy(
        enabled: true,
        maxFileBytes: 100 * 1024 * 1024,
        maxSessionBytes: 2 * 1024 * 1024 * 1024
    )

    static let disabled = SessionSharingUploadPolicy(
        enabled: false,
        maxFileBytes: 0,
        maxSessionBytes: 0
    )
}

/// Filename sanitization rules for the per-session upload directory.
///
/// The relay already does a light pass (rejects path-separators and the
/// obvious bad characters) but we re-do it here. Defense in depth: a
/// compromised relay should not be able to write outside the session's
/// upload directory.
enum SessionSharingUploadNameSanitizer {
    static let maxLength = 200

    static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed == "." || trimmed == ".." { return nil }
        if trimmed.hasPrefix(".") { return nil }
        if trimmed.utf8.count > maxLength { return nil }
        for scalar in trimmed.unicodeScalars {
            // Reject path separators (POSIX `/` and Windows `\`), NUL,
            // and any C0 control character. Spaces and CJK are fine.
            if scalar.value < 0x20 { return nil }
            if scalar == "/" || scalar == "\\" { return nil }
            if scalar == "\u{7F}" { return nil }
        }
        return trimmed
    }

    /// Pick a non-colliding final name inside `directory`. On collision
    /// we append `-1`, `-2`, ... before the extension, capping retries
    /// so a pathological directory can't loop forever.
    static func uniquePath(
        for sanitizedName: String, in directory: URL, retries: Int = 1024
    ) -> URL? {
        let baseURL = directory.appendingPathComponent(sanitizedName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        for n in 1...retries {
            let candidateName = ext.isEmpty
                ? "\(stem)-\(n)"
                : "\(stem)-\(n).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Build a single POSIX-shell-safe token for an absolute path. Wraps in
/// single quotes and escapes embedded single quotes the canonical way
/// (`'` → `'\''`). A trailing space is intentional so the cursor lands
/// past the path, mirroring `printf '%q '`.
enum SessionSharingShellEscape {
    static func quoteForPasteWithTrailingSpace(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)' "
    }
}

/// Network surface the upload manager talks to. Wraps the existing
/// SessionSharingNetworkClient + adds raw byte download (URLSession's
/// `data(for:)` returns Data which is what we want).
protocol SessionSharingUploadTransport {
    func download(from request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: SessionSharingUploadTransport {
    func download(from request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Pulls files staged on the relay onto disk, then injects the resulting
/// path into the PTY. One instance per SessionSharingController, lives
/// for the duration of a single share session.
///
/// `@unchecked Sendable` is safe because every mutable field
/// (`bytesAcceptedTotal`, `inflightUploadIDs`, `policy`) is only
/// read/written from the private serial `queue`, and the immutable
/// dependencies (transport / fileManager / closures) are Sendable by
/// construction.
final class SessionSharingUploadManager: @unchecked Sendable {
    struct Dependencies {
        let transport: SessionSharingUploadTransport
        let fileManager: FileManager
        let now: () -> Date

        static func live() -> Dependencies {
            Dependencies(
                transport: URLSession.shared,
                fileManager: .default,
                now: { Date() }
            )
        }
    }

    private let sessionID: String
    private let relayAddress: String
    private let dependencies: Dependencies
    private let uploadsRoot: URL
    private let auditLogURL: URL?
    private let injectPath: (String) -> Void
    private let sendAck: (SessionSharingUploadAckEnvelope) -> Void

    private let queue = DispatchQueue(label: "ghostty.session-sharing.upload", qos: .utility)
    private var policy: SessionSharingUploadPolicy
    private var bytesAcceptedTotal: Int64 = 0
    private var inflightUploadIDs: Set<String> = []

    init(
        sessionID: String,
        relayAddress: String,
        uploadsRoot: URL,
        auditLogURL: URL?,
        policy: SessionSharingUploadPolicy,
        dependencies: Dependencies = .live(),
        injectPath: @escaping (String) -> Void,
        sendAck: @escaping (SessionSharingUploadAckEnvelope) -> Void
    ) {
        self.sessionID = sessionID
        self.relayAddress = relayAddress
        self.uploadsRoot = uploadsRoot
        self.auditLogURL = auditLogURL
        self.policy = policy
        self.dependencies = dependencies
        self.injectPath = injectPath
        self.sendAck = sendAck
    }

    /// Update the per-session policy in response to a UI toggle (e.g.
    /// the user hit "stop accepting uploads" from the badge menu). New
    /// uploads see the new policy immediately; in-flight pulls finish
    /// under whatever policy they started with — they've already passed
    /// the gate.
    func updatePolicy(_ next: SessionSharingUploadPolicy) {
        queue.async { [weak self] in self?.policy = next }
    }

    /// Entry point invoked by the controller for every `upload_ready`
    /// frame received over /ws/agent.
    func handle(_ envelope: SessionSharingUploadReadyEnvelope) {
        queue.async { [weak self] in
            self?.processOnQueue(envelope)
        }
    }

    private func processOnQueue(_ envelope: SessionSharingUploadReadyEnvelope) {
        if inflightUploadIDs.contains(envelope.uploadID) {
            // Relay re-pushed the same upload_ready (e.g. after an agent
            // reconnect drained the pending list). We already started
            // pulling — drop the duplicate to avoid double-pulling.
            return
        }
        if !policy.enabled {
            reject(envelope, reason: .agentDisabled)
            return
        }
        if envelope.size > policy.maxFileBytes {
            reject(envelope, reason: .sizeExceedsFile)
            return
        }
        let projected = bytesAcceptedTotal &+ envelope.size
        if projected > policy.maxSessionBytes {
            reject(envelope, reason: .sizeExceedsSession)
            return
        }
        guard SessionSharingUploadNameSanitizer.sanitize(envelope.name) != nil else {
            reject(envelope, reason: .sanitizeFailed)
            return
        }
        inflightUploadIDs.insert(envelope.uploadID)
        Task { [weak self] in
            await self?.pullAndPersist(envelope)
        }
    }

    private func pullAndPersist(_ envelope: SessionSharingUploadReadyEnvelope) async {
        defer {
            queue.async { [weak self] in
                self?.inflightUploadIDs.remove(envelope.uploadID)
            }
        }

        guard let sanitized = SessionSharingUploadNameSanitizer.sanitize(envelope.name) else {
            reject(envelope, reason: .sanitizeFailed)
            return
        }

        let request: URLRequest
        do {
            request = try SessionSharingUploadRequestBuilder.pullRequest(
                relayAddress: relayAddress,
                pullURL: envelope.pullURL,
                pullToken: envelope.pullToken
            )
        } catch {
            reject(envelope, reason: .pullFailed)
            return
        }

        let data: Data
        do {
            let (received, response) = try await dependencies.transport.download(from: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                reject(envelope, reason: .pullFailed)
                return
            }
            data = received
        } catch {
            reject(envelope, reason: .pullFailed)
            return
        }

        if Int64(data.count) != envelope.size {
            reject(envelope, reason: .pullFailed)
            return
        }
        if let advertised = envelope.sha256 {
            let observedHex = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            if observedHex != advertised.lowercased() {
                reject(envelope, reason: .hashMismatch)
                return
            }
        }

        let sessionDir = uploadsRoot.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try dependencies.fileManager.createDirectory(
                at: sessionDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            reject(envelope, reason: .writeFailed)
            return
        }

        guard let finalURL = SessionSharingUploadNameSanitizer.uniquePath(
            for: sanitized, in: sessionDir
        ) else {
            reject(envelope, reason: .sanitizeFailed)
            return
        }

        let partial = finalURL.appendingPathExtension("partial-\(envelope.uploadID)")
        do {
            try data.write(to: partial, options: [.atomic])
            try dependencies.fileManager.moveItem(at: partial, to: finalURL)
        } catch let error as NSError {
            try? dependencies.fileManager.removeItem(at: partial)
            let reason: SessionSharingUploadRejectionReason =
                error.code == NSFileWriteOutOfSpaceError ? .diskFull : .writeFailed
            reject(envelope, reason: reason)
            return
        }

        queue.async { [weak self] in
            self?.bytesAcceptedTotal &+= envelope.size
        }

        injectPath(
            SessionSharingShellEscape.quoteForPasteWithTrailingSpace(finalURL.path)
        )

        let ack = SessionSharingUploadAckEnvelope.success(
            uploadID: envelope.uploadID,
            path: finalURL.path,
            bytesWritten: envelope.size
        )
        sendAck(ack)
        appendAudit(
            uploadID: envelope.uploadID,
            name: sanitized,
            size: envelope.size,
            path: finalURL.path,
            ok: true,
            reason: nil
        )
    }

    private func reject(
        _ envelope: SessionSharingUploadReadyEnvelope,
        reason: SessionSharingUploadRejectionReason
    ) {
        sendAck(
            .failure(uploadID: envelope.uploadID, reason: reason.rawValue)
        )
        appendAudit(
            uploadID: envelope.uploadID,
            name: envelope.name,
            size: envelope.size,
            path: nil,
            ok: false,
            reason: reason.rawValue
        )
    }

    private func appendAudit(
        uploadID: String,
        name: String,
        size: Int64,
        path: String?,
        ok: Bool,
        reason: String?
    ) {
        guard let auditLogURL else { return }
        var record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: dependencies.now()),
            "session_id": sessionID,
            "upload_id": uploadID,
            "name": name,
            "size": size,
            "ok": ok,
        ]
        if let path { record["path"] = path }
        if let reason { record["reason"] = reason }
        guard let line = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys]
        ) else { return }

        let dir = auditLogURL.deletingLastPathComponent()
        try? dependencies.fileManager.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        let payload = line + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: auditLogURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: auditLogURL, options: [.atomic])
        }
    }
}

enum SessionSharingUploadRequestBuilder {
    static func pullRequest(
        relayAddress: String,
        pullURL: String,
        pullToken: String
    ) throws -> URLRequest {
        guard pullURL.hasPrefix("/api/upload/"), pullURL.hasSuffix("/pull") else {
            throw SessionSharingError.invalidResponse
        }
        let url = try SessionSharingRelayURLBuilder.url(
            for: relayAddress,
            scheme: "https",
            path: pullURL,
            queryItems: [URLQueryItem(name: "token", value: pullToken)]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }
}

/// Resolves the on-disk locations used by the upload manager. Lives at
/// module scope so SessionSharingTests can stub them with tmpdirs.
enum SessionSharingUploadPaths {
    static func defaultUploadsRoot(for fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("uploads", isDirectory: true)
    }

    static func defaultAuditLogURL(for fileManager: FileManager = .default) -> URL {
        let logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return logs
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Ghostty", isDirectory: true)
            .appendingPathComponent("uploads.log", isDirectory: false)
    }
}

/// Installs/uninstalls the user-scoped LaunchAgent that prunes uploads
/// older than N days. We use launchd rather than an in-app timer because
/// (a) it runs even when ghostty is not running, (b) the cron-style
/// schedule is the macOS-native way to express daily maintenance, and
/// (c) it survives force-quits and crashes — neither of which would run
/// an in-app `applicationWillTerminate` hook.
///
/// All operations are idempotent: calling `install` twice in a row is
/// equivalent to calling it once. The implementation deliberately
/// bootouts before bootstrapping so changing the retention period
/// re-loads the agent with the new schedule.
enum SessionSharingUploadAutoCleanInstaller {
    static let label = "com.mitchellh.ghostty.uploads-prune"

    /// Days values the share-sheet picker exposes. The installer
    /// rejects anything outside this list so a corrupted persisted
    /// config can never schedule a 0-day or 99999-day prune.
    static let allowedDays: [Int] = [3, 7, 30]
    static let defaultDays: Int = 7

    static func plistURL(for fileManager: FileManager = .default) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// Sync the on-disk LaunchAgent to match the requested policy.
    /// Returns true on success. Failures are logged but not fatal — the
    /// share sheet keeps the user's preference even if launchctl misfires
    /// (e.g. on a sandboxed CI runner) so the next launch can retry.
    @discardableResult
    static func reconcile(enabled: Bool, days: Int) -> Bool {
        if enabled {
            let clamped = allowedDays.contains(days) ? days : defaultDays
            return install(days: clamped)
        } else {
            return uninstall()
        }
    }

    @discardableResult
    static func install(days: Int) -> Bool {
        let plistFile = plistURL()
        do {
            try FileManager.default.createDirectory(
                at: plistFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try renderPlist(days: days).write(to: plistFile, atomically: true, encoding: .utf8)
        } catch {
            AppDelegate.logger.error(
                "session-sharing: failed to write uploads-prune plist: \(error.localizedDescription)"
            )
            return false
        }
        // launchctl bootstrap errors out if the label is already loaded;
        // bootout first so a days change re-loads with the new schedule.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], ignoreFailure: true)
        let bootstrapStatus = runLaunchctl(
            ["bootstrap", "gui/\(getuid())", plistFile.path])
        return bootstrapStatus == 0
    }

    @discardableResult
    static func uninstall() -> Bool {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"], ignoreFailure: true)
        let plistFile = plistURL()
        try? FileManager.default.removeItem(at: plistFile)
        return true
    }

    /// True if a plist with our label currently exists on disk. Note we
    /// do *not* try to ask launchd whether it's loaded — `launchctl
    /// print` would force the share sheet thread to fork and is fragile
    /// across macOS versions. Disk presence is enough for the UI to
    /// reconcile against persisted config.
    static func isInstalled(_ fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: plistURL().path)
    }

    /// Pure helper exposed for tests: build the plist text for a given
    /// retention. The script body is intentionally a single one-liner so
    /// nothing about it depends on which shell launchd ends up using.
    static func renderPlist(days: Int) -> String {
        // Both the uploads tree and the empty-dir cleanup run as the
        // same one-line shell command. We use `find -mtime +Ndays -delete`
        // for files first, then prune the now-empty per-session dirs.
        let uploadsDir = SessionSharingUploadPaths.defaultUploadsRoot().path
        // No user input flows into this script — `days` was already
        // clamped to allowedDays — so there's nothing to escape that
        // a normal POSIX path doesn't already cover.
        let script = """
            find \(quoteForShell(uploadsDir)) -type f -mtime +\(days) -delete; \
            find \(quoteForShell(uploadsDir)) -mindepth 1 -type d -empty -delete
            """
        let logPath = "/tmp/ghostty-uploads-prune.log"
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/bin/sh</string>
                    <string>-c</string>
                    <string>\(escapeXML(script))</string>
                </array>
                <key>StartCalendarInterval</key>
                <dict>
                    <key>Hour</key><integer>3</integer>
                    <key>Minute</key><integer>15</integer>
                </dict>
                <key>RunAtLoad</key>
                <true/>
                <key>StandardOutPath</key>
                <string>\(escapeXML(logPath))</string>
                <key>StandardErrorPath</key>
                <string>\(escapeXML(logPath))</string>
            </dict>
            </plist>
            """
    }

    private static func quoteForShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    private static func runLaunchctl(
        _ args: [String], ignoreFailure: Bool = false
    ) -> Int32 {
        let proc = Process()
        proc.launchPath = "/bin/launchctl"
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            if !ignoreFailure {
                AppDelegate.logger.error(
                    "session-sharing: launchctl \(args.joined(separator: " ")) failed to spawn: \(error.localizedDescription)"
                )
            }
            return -1
        }
        proc.waitUntilExit()
        let status = proc.terminationStatus
        if status != 0 && !ignoreFailure {
            // try? readToEnd() yields Data?? — outer nil = threw, inner
            // nil = empty stream. Flatten then decode.
            let raw: Data? = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
            let output = raw.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            AppDelegate.logger.warning(
                "session-sharing: launchctl \(args.joined(separator: " ")) exit=\(status) output=\(output)"
            )
        }
        return status
    }
}

struct SessionSharingAppearancePayload: Codable, Equatable {
    let type: String
    let id: String
    let background: String
    let foreground: String
    let palette: [String]?
    let fontSize: Double?

    private enum CodingKeys: String, CodingKey {
        case type, id, background, foreground, palette
        case fontSize = "font_size"
    }

    static func capture(
        from config: ghostty_config_t,
        sessionID: String
    ) -> SessionSharingAppearancePayload? {
        var bg = ghostty_config_color_s()
        var fg = ghostty_config_color_s()
        let bgKey = "background"
        let fgKey = "foreground"
        guard ghostty_config_get(config, &bg, bgKey, UInt(bgKey.utf8.count)),
              ghostty_config_get(config, &fg, fgKey, UInt(fgKey.utf8.count))
        else { return nil }

        var fontSize: Float = 0
        let fsKey = "font-size"
        let haveFont = ghostty_config_get(
            config, &fontSize, fsKey, UInt(fsKey.utf8.count)
        )

        var palette = ghostty_config_palette_s()
        let paletteKey = "palette"
        let havePalette = ghostty_config_get(
            config, &palette, paletteKey, UInt(paletteKey.utf8.count)
        )
        var paletteHex: [String]?
        if havePalette {
            paletteHex = withUnsafePointer(to: &palette.colors) { tuplePtr in
                tuplePtr.withMemoryRebound(
                    to: ghostty_config_color_s.self,
                    capacity: 256
                ) { colorsPtr in
                    var out: [String] = []
                    out.reserveCapacity(16)
                    for i in 0..<16 {
                        out.append(SessionSharingAppearancePayload.hexString(colorsPtr[i]))
                    }
                    return out
                }
            }
        }

        return .init(
            type: "appearance",
            id: sessionID,
            background: hexString(bg),
            foreground: hexString(fg),
            palette: paletteHex,
            fontSize: haveFont ? Double(fontSize) : nil
        )
    }

    static func hexString(_ c: ghostty_config_color_s) -> String {
        String(format: "#%02x%02x%02x", c.r, c.g, c.b)
    }
}

struct SessionSharingScreenSnapshotPayload: Codable, Equatable {
    /// Soft cap on the raw VT byte stream we emit. Sized so the JSON +
    /// base64 wrapping still fits inside the relay's default 64 KiB
    /// per-session backlog (`SESSION_BACKLOG_LIMIT`); larger snapshots
    /// would be evicted immediately and never reach a fresh client.
    static let snapshotByteBudget = 32 * 1024

    let type: String
    let id: String
    /// Base64-encoded VT byte stream. Already prefixed with
    /// `\x1b[2J\x1b[H` (clear + home) and uses `\r\n` separators so the
    /// browser can pipe it directly through `term.write` after a
    /// `terminal.reset()`.
    let content: String

    static func capture(
        from surface: ghostty_surface_t,
        sessionID: String
    ) -> SessionSharingScreenSnapshotPayload? {
        // GHOSTTY_POINT_SCREEN spans the full scrollback (history) plus
        // the active grid, oldest line first. Writing the result back
        // through term.write naturally recreates the host's scrollback
        // on the browser: the older rows scroll off into xterm.js's
        // scrollback buffer as the newer rows fill the visible area —
        // mobile clients in live-mirror mode rely on this since the
        // lazy `fetch_scrollback` path is disabled there. We rely on
        // a trailing-blank-row padding step in `encode` to keep the
        // cursor anchor aligned even after the formatter's trailing
        // blank trim (see `formatter.zig` "Trailing blank lines are
        // always trimmed").
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        var cursor = ghostty_surface_cursor_s()
        var trailingBlankRows: UInt16 = 0
        // Atomic read: text dump + cursor position + trailing blank
        // count must all come from the same mutex hold. With separate
        // lock/unlock pairs the PTY reader thread could advance the
        // cursor or rewrite the bottom rows between calls, leaving the
        // appended `\x1b[<row>;<col>H` anchor disagreeing with the
        // dumped grid. The trailing blank count tells us how many
        // `\r\n` padding rows to re-add so xterm's viewport bottom
        // lines up with host's active screen bottom (formatter drops
        // trailing blank rows unconditionally).
        guard ghostty_surface_read_text_styled_with_cursor_and_trim(
            surface, selection, &text, &cursor, &trailingBlankRows
        ) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        let body: String
        if text.text_len > 0 {
            body = String(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: text.text),
                length: Int(text.text_len),
                encoding: .utf8,
                freeWhenDone: false
            ) ?? ""
        } else {
            body = ""
        }
        return encode(
            body: body,
            sessionID: sessionID,
            trailingBlankRows: Int(trailingBlankRows),
            cursorRow: Int(cursor.y),
            cursorCol: Int(cursor.x)
        )
    }

    static func encode(
        body: String,
        sessionID: String,
        trailingBlankRows: Int = 0,
        cursorRow: Int? = nil,
        cursorCol: Int? = nil
    ) -> SessionSharingScreenSnapshotPayload {
        // \x1b[2J clears the screen, \x1b[H moves the cursor to (1,1).
        // The browser receives this and term.write reproduces the same
        // grid contents along with the agent's SGR escapes (host
        // colours land for free because xterm.js parses SGR natively).
        let prefix = "\u{1b}[2J\u{1b}[H"
        let prefixData = Data(prefix.utf8)
        // VT cursor positioning is 1-indexed (rows + columns); the C
        // API exposes the 0-indexed grid offset. Tail the snapshot
        // with `\x1b[<y+1>;<x+1>H` so xterm's cursor lands at the
        // host's actual position after replaying the bytes — without
        // it, relative cursor moves emitted by TUIs (e.g. Ink-based
        // spinner redraws) land on the wrong row in the mirror and
        // stack rather than overwrite.
        let cursorSuffixData: Data
        if let row = cursorRow, let col = cursorCol, row >= 0, col >= 0 {
            cursorSuffixData = Data("\u{1b}[\(row + 1);\(col + 1)H".utf8)
        } else {
            cursorSuffixData = Data()
        }
        // Trailing-blank padding. The formatter strips blank rows from
        // the bottom of the dump unconditionally, so an active screen
        // that ends in empty rows leaves xterm's viewport bottom on
        // the last non-blank row instead of the actual active bottom.
        // Replaying one `\r\n` per trimmed row before the cursor
        // anchor restores the alignment so `\x1b[<cursor.y+1>;..H`
        // maps to the same grid cell on both sides.
        let paddingData: Data
        if trailingBlankRows > 0 {
            paddingData = Data(
                String(repeating: "\r\n", count: trailingBlankRows).utf8
            )
        } else {
            paddingData = Data()
        }
        var bodyData = Data(normaliseLineEndings(body).utf8)
        let budget = snapshotByteBudget
            - prefixData.count
            - cursorSuffixData.count
            - paddingData.count
        if budget > 0, bodyData.count > budget {
            bodyData = trimToTail(bodyData, byteBudget: budget)
        }
        let bytes = prefixData + bodyData + paddingData + cursorSuffixData
        return .init(
            type: "screen",
            id: sessionID,
            content: bytes.base64EncodedString()
        )
    }

    /// Collapse `\r\n` -> `\n`, then expand back to `\r\n`. Idempotent
    /// — works for both the legacy plaintext path and the styled
    /// `.vt` formatter (which already emits `\r\n`) without doubling
    /// up. Without this, switching the agent to the styled readback
    /// would have produced `\r\r\n` separators and confused xterm.
    static func normaliseLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func trimToTail(_ data: Data, byteBudget: Int) -> Data {
        precondition(byteBudget >= 0)
        if data.count <= byteBudget { return data }
        var cutIndex = data.count - byteBudget
        // Snap forward to the next \n so we never split a line in half.
        // Worst case the loop walks to the end and we keep nothing.
        let lf: UInt8 = 0x0A
        while cutIndex < data.count, data[cutIndex] != lf {
            cutIndex += 1
        }
        if cutIndex < data.count {
            cutIndex += 1
        }
        return data.subdata(in: cutIndex..<data.count)
    }
}

struct SessionSharingScrollbackPayload: Codable, Equatable {
    /// Maximum raw VT bytes we'll return per response. Mirrors the
    /// snapshot budget so the JSON+base64 wrapping fits in the relay
    /// frame cap (256 KiB hard, 64 KiB backlog).
    static let responseByteBudget = 32 * 1024

    let type: String
    let id: String
    /// Echoes the request's `before` so the browser can match the
    /// response to the right slot in its history buffer.
    let before: Int
    /// Number of history rows actually returned in `content`. May be
    /// smaller than the request when we hit the top of the agent's
    /// scrollback or when the byte budget clipped the slice.
    let count: Int
    /// The agent's current total history-line count, computed at
    /// response time. The browser uses it to detect "no more older
    /// rows available" (when `before + count >= total`).
    let total: Int
    /// Base64-encoded VT byte stream — the requested rows joined by
    /// `\r\n`, no clear/home prefix. The browser combines this with
    /// the snapshot body and live buffer at replay time.
    let content: String

    static func respond(
        from surface: ghostty_surface_t,
        sessionID: String,
        before: Int,
        requestedCount: Int
    ) -> SessionSharingScrollbackPayload? {
        guard before >= 0, requestedCount > 0 else { return nil }

        // Read the entire history, oldest line first. The styled
        // variant emits SGR escapes alongside cell text so colours
        // survive the trip to the browser.
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SURFACE,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        let ok = ghostty_surface_read_text_styled(surface, selection, &text)
        defer {
            if ok { ghostty_surface_free_text(surface, &text) }
        }
        let body: String
        if ok, text.text_len > 0 {
            body = String(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: text.text),
                length: Int(text.text_len),
                encoding: .utf8,
                freeWhenDone: false
            ) ?? ""
        } else {
            body = ""
        }
        return slice(
            history: body,
            sessionID: sessionID,
            before: before,
            requestedCount: requestedCount
        )
    }

    /// Pure helper: given the full history text (lines separated by
    /// `\n` or `\r\n`, oldest first), return the slice the browser
    /// asked for. Exposed for testing — the on-device path goes
    /// through `respond`.
    static func slice(
        history: String,
        sessionID: String,
        before: Int,
        requestedCount: Int
    ) -> SessionSharingScrollbackPayload {
        // The styled `.vt` readback emits `\r\n`; the legacy plaintext
        // path emits `\n`. Collapse to `\n` so split / slice / rejoin
        // produces the same shape regardless of source.
        let collapsed = history.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = collapsed.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        let total = lines.count

        // `before == 0` -> include the newest history row. Larger
        // `before` skips that many newest rows. Indices map oldest
        // first: lines[0] is oldest, lines[total-1] is newest.
        let upperExclusive = max(0, total - before)
        let lowerInclusive = max(0, upperExclusive - requestedCount)
        let slice = Array(lines[lowerInclusive..<upperExclusive])

        var content = slice.joined(separator: "\r\n")
        var contentBytes = Data(content.utf8)
        var emittedCount = slice.count
        if contentBytes.count > responseByteBudget {
            // Tail-truncate at line boundary to keep the *newest*
            // rows in the slice — those are the ones the browser
            // will scroll into view next.
            let trimmed = SessionSharingScreenSnapshotPayload
                .tailWithinByteBudget(
                    lines: slice,
                    byteBudget: responseByteBudget
                )
            content = trimmed.text
            contentBytes = Data(content.utf8)
            emittedCount = trimmed.count
        }

        return .init(
            type: "scrollback",
            id: sessionID,
            before: before,
            count: emittedCount,
            total: total,
            content: contentBytes.base64EncodedString()
        )
    }
}

extension SessionSharingScreenSnapshotPayload {
    /// Trim a `\n`-separated tail of `lines` whose joined `\r\n` form
    /// fits within `byteBudget`. Used by the scrollback response path
    /// so the byte budget logic stays in one place.
    static func tailWithinByteBudget(
        lines: [String],
        byteBudget: Int
    ) -> (text: String, count: Int) {
        precondition(byteBudget >= 0)
        var bytes = 0
        var keepFromIndex = lines.count
        let separatorBytes = "\r\n".utf8.count
        // Walk newest -> oldest accumulating budget.
        for index in (0..<lines.count).reversed() {
            let lineBytes = lines[index].utf8.count
            let extra = bytes == 0 ? lineBytes : lineBytes + separatorBytes
            if bytes + extra > byteBudget {
                break
            }
            bytes += extra
            keepFromIndex = index
        }
        let kept = Array(lines[keepFromIndex..<lines.count])
        return (kept.joined(separator: "\r\n"), kept.count)
    }
}

enum SessionSharingError: LocalizedError {
    case invalidRelayAddress
    case invalidResponse
    case insecureRelayAddress
    case userTokenRejected

    var errorDescription: String? {
        switch self {
        case .invalidRelayAddress:
            return "中转服务器地址无效"
        case .invalidResponse:
            return "中转服务器返回了无效响应"
        case .insecureRelayAddress:
            return "远程中转服务器必须使用 https:// 或 wss://；仅 localhost 或局域网开发地址允许使用 http://"
        case .userTokenRejected:
            return "用户令牌被中转服务器拒绝"
        }
    }
}

/// Maps an `Error` from the start-sharing pipeline to a single
/// user-facing message. The previous code interpolated
/// `error.localizedDescription` directly, which produced messages like
/// "启动共享失败：A server with the specified hostname could not be
/// found." that don't tell the user what to do next. This collapses
/// the common cases (bad relay config, network unreachable, TLS,
/// HTTP 401, timeouts) to actionable instructions while still
/// redacting tokens on the unknown-error fallback.
enum SessionSharingErrorPresentation {
    static func actionableMessage(for error: Error) -> String {
        if let sharingError = error as? SessionSharingError {
            return sharingError.actionableMessage
        }
        if let urlError = error as? URLError {
            return URLErrorPresentation.message(for: urlError)
        }
        return "启动共享失败：\(SessionSharingTokenRedaction.redact(error: error))"
    }
}

private extension SessionSharingError {
    var actionableMessage: String {
        switch self {
        case .invalidRelayAddress:
            return "中转服务器地址无效，请检查后重新启动共享。"
        case .invalidResponse:
            return "中转服务器返回了无效响应，请确认服务器版本是否匹配。"
        case .insecureRelayAddress:
            return "远程中转服务器必须使用 https:// 或 wss://；仅 localhost 或局域网开发地址允许使用 http://。"
        case .userTokenRejected:
            return "用户令牌被中转服务器拒绝，请确认令牌已加入服务器允许列表（GHOSTTY_RELAY_USER_TOKENS）。"
        }
    }
}

private enum URLErrorPresentation {
    static func message(for error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "找不到中转服务器主机，请检查地址或 DNS 配置。"
        case .cannotConnectToHost, .networkConnectionLost:
            return "无法连接到中转服务器，请确认服务已启动并允许该端口。"
        case .timedOut:
            return "连接中转服务器超时，请检查网络后重试。"
        case .notConnectedToInternet:
            return "当前没有可用网络，请重新连接后再启动共享。"
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .serverCertificateHasBadDate,
             .clientCertificateRejected:
            return "中转服务器 TLS 证书校验失败，请确认证书是否已被信任。"
        default:
            return "启动共享失败：\(SessionSharingTokenRedaction.redact(error: error))"
        }
    }
}

/// Scrubs session-sharing tokens out of strings that are about to hit a
/// user-visible surface (NSAlert, log line, status field). The session
/// sharing protocol carries tokens in `Authorization: Bearer …` headers
/// and as `?token=` / `?client_token=` / `?agent_token=` query params,
/// and an `Error` from URLSession or URLSessionWebSocketTask can include
/// the URL it failed against. We don't construct user-facing strings
/// from token state ourselves, but `error.localizedDescription` is a
/// black box, so we run it through this scrubber as a defensive layer.
///
/// Mirrors the browser-side `redactSensitiveText` in
/// `contrib/session-sharing/ghostty-web-client/src/redaction.js`.
enum SessionSharingTokenRedaction {
    private static let bearerRegex: NSRegularExpression = {
        // Static patterns; force-try is safe.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "Bearer\\s+\\S+", options: [.caseInsensitive])
    }()

    private static let queryRegexes: [NSRegularExpression] = ["token", "client_token", "agent_token"].map { key in
        let pattern = "([?&]\(NSRegularExpression.escapedPattern(for: key))=)[^&\\s]+"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func redact(_ value: String) -> String {
        var result = value
        let bearerRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = bearerRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: bearerRange,
            withTemplate: "Bearer [REDACTED]"
        )
        for regex in queryRegexes {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1[REDACTED]"
            )
        }
        return result
    }

    static func redact(error: Error) -> String {
        redact(error.localizedDescription)
    }
}

// MARK: - NSTextInputClient

extension Ghostty.SurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }

    func selectedRange() -> NSRange {
        guard let surface = self.surface else { return NSRange() }

        // Get our range from the Ghostty API. There is a race condition between getting the
        // range and actually using it since our selection may change but there isn't a good
        // way I can think of to solve this for AppKit.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)

        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)

        default:
            print("unknown marked text: \(string)")
        }

        // If we're not in a keyDown event, then we want to update our preedit
        // text immediately. This can happen due to external events, for example
        // changing keyboard layouts while composing: (1) set US intl (2) type '
        // to enter dead key state (3)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Ghostty.logger.warning("pressure substring range=\(range) selectedRange=\(self.selectedRange())")
        guard let surface = self.surface else { return nil }

        // If the range is empty then we don't need to return anything
        guard range.length > 0 else { return nil }

        // I used to do a bunch of testing here that the range requested matches the
        // selection range or contains it but a lot of macOS system behaviors request
        // bogus ranges I truly don't understand so we just always return the
        // attributed string containing our selection which is... weird but works?

        // Get our selection text
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        // If we can get a font then we use the font. This should always work
        // since we always have a primary font. The only scenario this doesn't
        // work is if someone is using a non-CoreText build which would be
        // unofficial.
        var attributes: [ NSAttributedString.Key: Any ] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // Memory management here is wonky: ghostty_surface_quicklook_font
            // will create a copy of a CTFont, Swift will auto-retain the
            // unretained value passed into the dict, so we release the original.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return .init(string: String(cString: text.text), attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Ghostty will tell us where it thinks an IME keyboard should render.
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // QuickLook never gives us a matching range to our selection so if we detect
        // this then we return the top-left selection point rather than the cursor point.
        // This is hacky but I can't think of a better way to get the right IME vs. QuickLook
        // point right now. I'm sure I'm missing something fundamental...
        if range.length > 0 && range != self.selectedRange() {
            // QuickLook
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                // The -2/+2 here is subjective. QuickLook seems to offset the rectangle
                // a bit and I think these small adjustments make it look more natural.
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2

                // Free our text
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            // This fixes #8493 while speaking
            // My guess is that positive width doesn't make sense
            // for the dictation microphone indicator
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // Ghostty coordinates are in top-left (0, 0) so we have to convert to
        // bottom-left since that is what UIKit expects
        // when there's is no characters selected,
        // width should be 0 so that dictation indicator
        // can start in the right place
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height))

        // Convert the point to the window coordinates
        let winRect = self.convert(viewRect, to: nil)

        // Convert from view to screen coordinates
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event
        guard NSApp.currentEvent != nil else { return }
        guard let surfaceModel else { return }

        // We want the string view of the any value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in another key event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        surfaceModel.sendText(chars)
    }

    /// This function needs to exist for two reasons:
    /// 1. Prevents an audible NSBeep for unimplemented actions.
    /// 2. Allows us to properly encode super+key input events that we don't handle
    override func doCommand(by selector: Selector) {
        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                markedText.string.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// True when `text` is a single C0 control character (U+0000-U+001F)
    /// arriving while the IME is composing. Such input belongs to the IME
    /// and must not be forwarded to the terminal.
    static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }
}

// MARK: Services

// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html
extension Ghostty.SurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // This function confused me a bit so I'm going to add my own commentary on
        // how this works. macOS sends this callback with the given send/return types and
        // we must return the responder capable of handling the COMBINATION of those send
        // and return types (or super up if we can't handle it).
        //
        // The "COMBINATION" bit is key: we might get sent a string (we can handle that)
        // but get requested an image (we can't handle that at the time of writing this),
        // so we must bubble up.

        // Types we can receive
        let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]

        // Types that we can send. Currently the same as receivable but I'm separating
        // this out so we can modify this in the future.
        let sendable: [NSPasteboard.PasteboardType] = receivable

        // The sendable types that require a selection (currently all)
        let sendableRequiresSelection = sendable

        // If we expect no data to be sent/received we can obviously handle it (that's
        // the nil check), otherwise it must conform to the types we support on both sides.
        if (returnType == nil || receivable.contains(returnType!)) &&
            (sendType == nil || sendable.contains(sendType!)) {
            // If we're expected to send back a type that requires selection, then
            // verify that we have a selection. We do this within this block because
            // validateRequestor is called a LOT and we want to prevent unnecessary
            // performance hits because `ghostty_surface_has_selection` isn't free.
            if let sendType, sendableRequiresSelection.contains(sendType) {
                if surface == nil || !ghostty_surface_has_selection(surface) {
                    return super.validRequestor(forSendType: sendType, returnType: returnType)
                }
            }

            return self
        }

        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface = self.surface else { return false }

        // Read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }

        pboard.declareTypes([.string], owner: nil)
        pboard.setString(String(cString: text.text), forType: .string)
        return true
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = pboard.getOpinionatedStringContents() else { return false }

        let len = str.utf8CString.count
        if len == 0 { return true }
        str.withCString { ptr in
            // len includes the null terminator so we do len - 1
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }

        return true
    }
}

// MARK: NSMenuItemValidation

extension Ghostty.SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pasteSelection):
            let pb = NSPasteboard.ghosttySelection
            guard let str = pb.getOpinionatedStringContents() else { return false }
            return !str.isEmpty

        case #selector(findHide):
            return searchState != nil

        case #selector(toggleReadonly):
            item.state = readonly ? .on : .off
            return true

        case #selector(copy(_:)):
            // We only enable copy menu item when there're actual selected text
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                return true
            } else {
                return false
            }

        default:
            return true
        }
    }
}

// MARK: NSDraggingDestination

extension Ghostty.SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return none.
        // This shouldn't happen because AppKit should guarantee that we only
        // receive types we registered for but its good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content: String?
        if let url = pb.string(forType: .URL) {
            // URLs first, they get escaped as-is.
            content = Ghostty.Shell.escape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            // File URLs next. They get escaped individually and then joined by a
            // space if there are multiple.
            content = urls
                .map { Ghostty.Shell.escape($0.path) }
                .joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            // Strings are not escaped because they may be copy/pasting a
            // command they want to execute.
            content = str
        } else {
            content = nil
        }

        if let content {
            DispatchQueue.main.async {
                self.insertText(
                    content,
                    replacementRange: NSRange(location: 0, length: 0)
                )
            }
            return true
        }

        return false
    }
}

// MARK: Accessibility

extension Ghostty.SurfaceView {
    /// Indicates that this view should be exposed to accessibility tools like VoiceOver.
    /// By returning true, we make the terminal surface accessible to screen readers
    /// and other assistive technologies.
    override func isAccessibilityElement() -> Bool {
         return true
     }

    /// Defines the accessibility role for this view, which helps assistive technologies
    /// understand what kind of content this view contains and how users can interact with it.
    override func accessibilityRole() -> NSAccessibility.Role? {
        /// We use .textArea because the terminal surface is essentially an editable text area
        /// where users can input commands and view output.
        return .textArea
    }

    override func accessibilityHelp() -> String? {
        return "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        return cachedScreenContents.get()
    }

    /// Returns the range of text that is currently selected in the terminal.
    /// This allows VoiceOver and other assistive technologies to understand
    /// what text the user has selected.
    override func accessibilitySelectedTextRange() -> NSRange {
        return selectedRange()
    }

    /// Returns the currently selected text as a string.
    /// This allows assistive technologies to read the selected content.
    override func accessibilitySelectedText() -> String? {
        guard let surface = self.surface else { return nil }

        // Attempt to read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }

    /// Returns the number of characters in the terminal content.
    /// This helps assistive technologies understand the size of the content.
    override func accessibilityNumberOfCharacters() -> Int {
        let content = cachedScreenContents.get()
        return content.count
    }

    /// Returns the visible character range for the terminal.
    /// For terminals, we typically show all content as visible.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let content = cachedScreenContents.get()
        return NSRange(location: 0, length: content.count)
    }

    /// Returns the line number for a given character index.
    /// This helps assistive technologies navigate by line.
    override func accessibilityLine(for index: Int) -> Int {
        let content = cachedScreenContents.get()
        let substring = String(content.prefix(index))
        return substring.components(separatedBy: .newlines).count - 1
    }

    /// Returns a substring for the given range.
    /// This allows assistive technologies to read specific portions of the content.
    override func accessibilityString(for range: NSRange) -> String? {
        let content = cachedScreenContents.get()
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
    }

    /// Returns an attributed string for the given range.
    ///
    /// Note: right now this only applies font information. One day it'd be nice to extend
    /// this to copy styling information as well but we need to augment Ghostty core to
    /// expose that.
    ///
    /// This provides styling information to assistive technologies.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = self.surface else { return nil }
        guard let plainString = accessibilityString(for: range) else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [:]

        // Try to get the font from the surface
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return NSAttributedString(string: plainString, attributes: attributes)
    }

}

/// Caches a value for some period of time, evicting it automatically when that time expires.
/// We use this to cache our surface content. This probably should be extracted some day
/// to a more generic helper.
class CachedValue<T> {
    private var value: T?
    private let fetch: () -> T
    private let duration: Duration
    private var expiryTask: Task<Void, Never>?

    init(duration: Duration, fetch: @escaping () -> T) {
        self.duration = duration
        self.fetch = fetch
    }

    deinit {
        expiryTask?.cancel()
    }

    func get() -> T {
        if let value {
            return value
        }

        // We don't have a value (or it expired). Fetch and store.
        let result = fetch()
        let now = ContinuousClock.now
        let expires = now + duration
        self.value = result

        // Schedule a task to clear the value
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(until: expires)
                self?.value = nil
                self?.expiryTask = nil
            } catch {
                // Task was cancelled, do nothing
            }
        }

        return result
    }
}
