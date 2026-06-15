/// An UndoManager subclass that supports registering undo operations that automatically expire after a specified duration.
///
/// This class extends the standard UndoManager to add time-based expiration for undo operations.
/// When an undo operation expires, it is automatically removed from the undo stack and cannot be invoked.
///
/// Example usage:
/// ```swift
/// let undoManager = ExpiringUndoManager()
/// undoManager.registerUndo(withTarget: myObject, expiresAfter: .seconds(30)) { target in
///     // Undo operation that expires after 30 seconds
///     target.restorePreviousState()
/// }
/// ```
class ExpiringUndoManager: UndoManager {
    /// The set of expiring targets so we can properly clean them up when removeAllActions
    /// is called with the real target.
    private lazy var expiringTargets: Set<ExpiringTarget> = []

    /// Registers an undo operation that automatically expires after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object for the undo operation. The undo operation will be removed
    ///             if this object is deallocated before the operation is invoked.
    ///   - duration: The duration after which the undo operation should expire and be removed from the undo stack.
    ///   - onExpire: An optional closure invoked when the undo operation expires *without* being
    ///              performed — i.e. the timer fired, undo registration was disabled, or the actions
    ///              were otherwise cleared. It is **not** called when the undo is actually invoked.
    ///              Callers use this to deterministically release resources the undo action was only
    ///              keeping alive so the operation could be reverted (e.g. terminal surfaces preserved
    ///              for ⌘Z). Always invoked on the same thread the expiration happens on (main).
    ///   - handler: The closure to execute when the undo operation is invoked. The closure receives
    ///              the target object as its parameter.
    func registerUndo<TargetType: AnyObject>(
        withTarget target: TargetType,
        expiresAfter duration: Duration,
        onExpire: (() -> Void)? = nil,
        handler: @escaping (TargetType) -> Void
    ) {
        // Ignore instantly expiring undos. The operation can never be reverted, so
        // whatever it was preserving is immediately unreachable: expire it right now.
        guard duration.timeInterval > 0 else {
            onExpire?()
            return
        }

        // Ignore when undo registration is disabled. UndoManager still lets
        // registration happen then cancels later but I was seeing some
        // weird behavior with this so let's just guard on it. Same reasoning as
        // above: no undo will exist, so let the caller release what it held.
        guard self.isUndoRegistrationEnabled else {
            onExpire?()
            return
        }

        let expiringTarget = ExpiringTarget(
            target,
            expiresAfter: duration,
            in: self,
            onExpire: onExpire)
        expiringTargets.insert(expiringTarget)

        super.registerUndo(withTarget: expiringTarget) { [weak self] expiringTarget in
            // The undo is being performed (not lost): mark it so that the
            // subsequent expiration does not also fire the onExpire teardown.
            expiringTarget.markInvoked()
            self?.expiringTargets.remove(expiringTarget)
            guard let target = expiringTarget.target as? TargetType else { return }
            handler(target)
        }
    }

    /// Removes all undo and redo operations from the undo manager.
    ///
    /// This override ensures that all expiring targets are also cleared when
    /// the undo manager is reset.
    override func removeAllActions() {
        super.removeAllActions()
        expiringTargets = []
    }

    /// Removes all undo and redo operations involving the specified target.
    ///
    /// This override ensures that when actions are removed for a target, any associated
    /// expiring targets are also properly cleaned up.
    ///
    /// - Parameter target: The target object whose actions should be removed.
    override func removeAllActions(withTarget target: Any) {
        // Call super to handle standard removal
        super.removeAllActions(withTarget: target)

        // If the target is an expiring target, remove it.
        if let expiring = target as? ExpiringTarget {
            expiringTargets.remove(expiring)
        } else {
            // Find and remove any ExpiringTarget instances that wrap this target.
            expiringTargets
                .filter { $0.target == nil || $0.target === (target as AnyObject) }
                .forEach {
                    // Technically they'll always expire when they get deinitialized
                    // but we want to make sure it happens right now.
                    $0.expire()
                    expiringTargets.remove($0)
                }
        }
    }
}

/// A target object for ExpiringUndoManager that removes itself from the
/// undo manager after it expires.
///
/// This class acts as a proxy for the real target object in undo operations.
/// It holds a weak reference to the actual target and automatically removes
/// all associated undo operations when either:
/// - The specified duration expires
/// - The ExpiringTarget instance is deallocated
/// - The expire() method is called manually
private class ExpiringTarget {
    /// The actual target object for the undo operation, held weakly to avoid retain cycles.
    private(set) weak var target: AnyObject?

    /// Timer that triggers expiration after the specified duration.
    private var timer: Timer?

    /// The undo manager from which to remove actions when this target expires.
    private weak var undoManager: UndoManager?

    /// Called when this target expires *without* the undo having been performed.
    /// See `ExpiringUndoManager.registerUndo(withTarget:expiresAfter:onExpire:handler:)`.
    private let onExpire: (() -> Void)?

    /// Set to true once the undo operation is actually performed. Suppresses `onExpire`,
    /// since the operation is being reverted (resources restored) rather than lost.
    private var invoked = false

    /// Guards `onExpire` so it fires at most once across timer fire, manual `expire()`, and `deinit`.
    private var didExpire = false

    /// Creates an expiring target that will automatically remove undo actions after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object to hold weakly.
    ///   - duration: The time after which the target should expire.
    ///   - undoManager: The UndoManager from which to remove actions when expired.
    ///   - onExpire: Closure to run when the target expires without the undo being performed.
    init(_ target: AnyObject? = nil, expiresAfter duration: Duration, in undoManager: UndoManager, onExpire: (() -> Void)? = nil) {
        self.target = target
        self.undoManager = undoManager
        self.onExpire = onExpire
        self.timer = Timer.scheduledTimer(
            withTimeInterval: duration.timeInterval,
            repeats: false) { [weak self] _ in
            self?.expire()
        }
    }

    /// Marks that the undo operation was actually performed, so that the subsequent
    /// expiration does not fire `onExpire` (the operation is reverted, not discarded).
    func markInvoked() {
        invoked = true
    }

    /// Manually expires the target, removing all associated undo actions and invalidating the timer.
    ///
    /// This method is called automatically when the timer fires, but can also be called manually
    /// to expire the target before the timer duration has elapsed.
    func expire() {
        target = nil
        undoManager?.removeAllActions(withTarget: self)
        timer?.invalidate()
        timer = nil

        // Fire the expiration callback exactly once, and only if the undo was
        // discarded (timer / cleared) rather than performed.
        guard !didExpire else { return }
        didExpire = true
        if !invoked {
            onExpire?()
        }
    }

    deinit {
        expire()
    }
}

extension ExpiringTarget: Hashable, Equatable {
    static func == (lhs: ExpiringTarget, rhs: ExpiringTarget) -> Bool {
        return lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
