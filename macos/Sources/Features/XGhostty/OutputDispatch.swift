#if XGHOSTTY
import Foundation
import GhosttyKit

/// 单个 surface 的「pty 输出多订阅分发器」。
///
/// **背景**：Zig 侧 `ghostty_surface_set_output_callback` 是**单槽**——一个 surface 只能挂一个
/// C 回调，后挂的覆盖前者、`detach` 直接置 nil 把对方也清掉。于是会话日志、⌃⇧S 会话共享、expect
/// 自动登录这三个都想监听同一会话输出的功能彼此**互斥**（谁后挂谁赢，另一个静默失效）。
///
/// **做法**：在 Swift 侧加一层分发——每个 surface 只向 Zig 注册**一个** trampoline，trampoline 把
/// 收到的每批 pty 字节转发给该 surface 的**全部订阅者**。这样多个功能可同时挂同一会话的输出。
/// **零改 Zig 核心**（仍只用既有的 set_output_callback C ABI）。
///
/// **线程模型**：
/// - 订阅 `add` / 退订 `remove` 在**主线程**调用。
/// - `dispatch` 由 trampoline 在 **termio 线程**（每批 pty 读取后）调用。
/// - 订阅者集合用 `lock` 保护；回调里先取快照、出锁后再逐个调用（订阅者都只做快速的
///   enqueue/scan，不会回头改订阅集，故快照即可）。
///
/// **生命周期**：dispatcher 一旦为某 surface 建立就**常驻**注册表（不随订阅清零而销毁）。这是为了
/// 回避「termio 线程正在回调、主线程把 dispatcher 释放」的 use-after-free——`passUnretained` 的
/// context 必须在回调期间一直有效。订阅清零时只把 Zig 回调置 nil（此后无任何开销），下次有订阅者
/// 再挂回同一个 dispatcher。每个曾打开的 surface 至多留一个极小对象（一个字典 + 锁），可忽略。
/// 这与既有单槽 detach 的竞态同一量级，但用「不释放」把 UAF 彻底消除。
final class XGhosttyOutputDispatch {
    /// surface 指针（`void*` → Swift `UnsafeMutableRawPointer`，Hashable）→ 该 surface 的分发器。常驻。
    private static var registry: [ghostty_surface_t: XGhosttyOutputDispatch] = [:]
    private static let registryLock = NSLock()

    private let surface: ghostty_surface_t
    /// 订阅者：key = 订阅方对象的 `ObjectIdentifier`（用对象本身做退订凭据），value = 输出 sink。
    private var sinks: [ObjectIdentifier: (Data) -> Void] = [:]
    private let lock = NSLock()

    private init(surface: ghostty_surface_t) { self.surface = surface }

    /// 订阅某 surface 的输出。`key` 用订阅方对象本身（同一对象重复订阅会覆盖）。
    /// 首个订阅者到来时把唯一 trampoline 挂到 Zig 单槽。
    static func add(surface: ghostty_surface_t, key: AnyObject, sink: @escaping (Data) -> Void) {
        let dispatch = dispatcher(for: surface)
        dispatch.lock.lock()
        let wasEmpty = dispatch.sinks.isEmpty
        dispatch.sinks[ObjectIdentifier(key)] = sink
        dispatch.lock.unlock()
        if wasEmpty {
            ghostty_surface_set_output_callback(
                surface, xghosttyOutputDispatchCallback,
                Unmanaged.passUnretained(dispatch).toOpaque())
        }
    }

    /// 退订。订阅清零时把 Zig 回调置 nil（dispatcher 对象保留在注册表，不释放）。
    static func remove(surface: ghostty_surface_t, key: AnyObject) {
        registryLock.lock()
        let dispatch = registry[surface]
        registryLock.unlock()
        guard let dispatch else { return }
        dispatch.lock.lock()
        dispatch.sinks.removeValue(forKey: ObjectIdentifier(key))
        let nowEmpty = dispatch.sinks.isEmpty
        dispatch.lock.unlock()
        if nowEmpty {
            ghostty_surface_set_output_callback(surface, nil, nil)
        }
    }

    private static func dispatcher(for surface: ghostty_surface_t) -> XGhosttyOutputDispatch {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[surface] { return existing }
        let created = XGhosttyOutputDispatch(surface: surface)
        registry[surface] = created
        return created
    }

    /// termio 线程：取订阅者快照后逐个转发。
    fileprivate func dispatch(_ data: Data) {
        lock.lock()
        let snapshot = Array(sinks.values)
        lock.unlock()
        for sink in snapshot { sink(data) }
    }
}

/// 顶层无捕获函数 → 可直接桥接为 C 函数指针（同 `sessionSharingOutputCallback` 范式）。
/// 每批 pty 输出在 termio 线程触发，转交对应 surface 的分发器。
func xghosttyOutputDispatchCallback(
    _ context: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    guard let context, let bytes, length > 0 else { return }
    let dispatch = Unmanaged<XGhosttyOutputDispatch>.fromOpaque(context).takeUnretainedValue()
    dispatch.dispatch(Data(bytes: bytes, count: Int(length)))
}
#endif
