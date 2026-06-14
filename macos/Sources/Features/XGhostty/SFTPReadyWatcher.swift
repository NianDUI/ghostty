#if XGHOSTTY
import Foundation

/// SFTP 标签的「已连接」探测器。
///
/// **背景**：sftp 不会发 OSC 7（远端没有交互登录 shell 上报 `$PWD`），所以 ssh 那套靠 `$pwd`
/// 首次上报来判定「登录成功」的机制对 sftp 失效——sftp 标签会永远停在「连接中」转圈。
///
/// **做法**：复用输出多订阅分发器（[[OutputDispatch]]，与会话日志 / expect 并存），扫描 pty 输出里
/// 首个 `sftp>` 提示符，命中即视为已登录、在主线程回调一次（之后自动失活，撤订阅由控制器负责）。
///
/// **线程模型**：`feed` 由分发器在 termio 线程调用；`fired`/`tail` 用 `lock` 保护，回调切回主线程。
final class SFTPReadyWatcher {
    private let onReady: () -> Void
    private let lock = NSLock()
    private var fired = false
    private var tail = ""

    init(onReady: @escaping () -> Void) { self.onReady = onReady }

    /// termio 线程：累积近窗扫描 `sftp>`，命中后主线程回调一次（仅一次）。
    func feed(_ data: Data) {
        lock.lock()
        if fired { lock.unlock(); return }
        // 只保留尾部 64 字符即可覆盖跨读取批边界的提示符，避免 tail 无界增长。
        tail = String((tail + String(decoding: data, as: UTF8.self)).suffix(64))
        guard tail.contains("sftp>") else { lock.unlock(); return }
        fired = true
        lock.unlock()
        DispatchQueue.main.async { [onReady] in onReady() }
    }
}
#endif
