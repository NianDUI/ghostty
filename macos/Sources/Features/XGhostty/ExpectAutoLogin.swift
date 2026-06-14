#if XGHOSTTY
import Foundation

/// SSH 密码自动登录的 **expect 式兜底**（opt-in，默认关）。
///
/// **正常路径**：`SSH_ASKPASS_REQUIRE=force` 让 ssh 不在 tty 上问密码、直接调 askpass 脚本注入 →
/// 终端里**根本不出现** `password:` 提示 → 本兜底永不触发。少数环境的 ssh 不认 askpass（仍在 tty
/// 上 `getpass` 提示密码），此时 `password:` 会出现在终端输出里 → 本兜底监听到后用 `send_bytes` 把
/// 密码答进去（复用已验证的广播原语，行尾 `\r`，绕 bracketed-paste）。两条路径互斥：askpass 生效则
/// 无提示、兜底静默；askpass 失效才由兜底接管。
///
/// **只在登录阶段武装**（关键防误答）：连接成功（首个 OSC7 pwd）/ 45s 超时 / 关闭标签后立即解除
/// 武装。否则登录后用户跑 `sudo`（提示 `[sudo] password for ...` 也含 `password:`）会被误答 ssh 密码。
/// 另最多答 2 次（密码错 → `Permission denied` → 再问一次即止），防反复喷密码。
///
/// **线程**：`feed` 由 `XGhosttyOutputDispatch` 在 **termio 线程**调用；匹配/发送都很轻
/// （send_bytes 线程安全、同广播）。`disarm` 在主线程调用。`armed` 等状态用 `lock` 保护。
final class ExpectAutoLogin {
    private weak var surface: Ghostty.SurfaceView?
    private let password: String
    private let lock = NSLock()
    private var armed = true
    private var attemptsLeft = 2
    /// 最近输出的尾巴（小写、裁到 ~120 字符，够覆盖一行 `user@host's password:` 提示且跨批拼接）。
    private var tail = ""

    init(surface: Ghostty.SurfaceView, password: String) {
        self.surface = surface
        self.password = password
        // 兜底解除：即便始终没等到「连接成功」（如登录失败留尸 tab），45s 后也强制解除武装，
        // 避免一直挂着监听把后续误当登录提示。
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.disarm() }
    }

    /// 输出分发器回调（termio 线程）：累积尾巴 → 末尾出现 `password:` 即答密码。
    func feed(_ data: Data) {
        lock.lock()
        guard armed, attemptsLeft > 0 else { lock.unlock(); return }
        let chunk = String(decoding: data, as: UTF8.self).lowercased()
        tail = String((tail + chunk).suffix(120))
        guard tail.contains("password:") else { lock.unlock(); return }
        attemptsLeft -= 1
        tail = ""                       // 清尾：同一条提示不再重复触发
        lock.unlock()
        let payload = Data((password + "\r").utf8)
        DispatchQueue.main.async { [weak surface] in surface?.xghosttySendBytes(payload) }
    }

    /// 解除武装（连接成功 / 超时 / 关闭标签时调用）。幂等。
    func disarm() {
        lock.lock(); armed = false; lock.unlock()
    }
}
#endif
