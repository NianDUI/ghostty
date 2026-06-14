#if XGHOSTTY
import Foundation

/// 单个会话的日志 writer：把 pty 原始输出追加到一个 `.log` 文件。
///
/// **线程**：`ingest` 由 termio 输出回调在 **termio 线程**同步调用 → 立刻派发到自己的串行队列
/// 异步落盘，**绝不**在 termio 线程做文件 IO（否则拖慢 pty 读取、卡终端）。
///
/// **内容**：raw 字节，含 ANSI 转义 / 控制序列（保真）。`cat <file>` 在终端能彩色回放，
/// `less -R` 亦可；要纯文本可后续加「剥离 ANSI」选项。
final class SessionLogger {
    let fileURL: URL
    private let queue: DispatchQueue
    private var handle: FileHandle?
    private var opened = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "top.niandui.xghostty.sessionlog")
    }

    /// termio 线程调用：派发到串行队列异步追加。
    func ingest(_ data: Data) {
        queue.async { [weak self] in self?.append(data) }
    }

    private func append(_ data: Data) {
        if !opened { open() }
        guard let handle else { return }
        try? handle.write(contentsOf: data)
    }

    /// 懒创建：首批输出到来才建文件（避免空会话留空文件）。目录 0700、文件 0600。
    private func open() {
        opened = true
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    /// flush + 关闭文件句柄（串行队列上执行，确保排在所有 append 之后）。
    func close() {
        queue.async { [weak self] in
            try? self?.handle?.close()
            self?.handle = nil
        }
    }
}

/// 会话日志总管：按开关给**远端（ssh）会话**挂输出回调、落盘到 `~/.config/xghostty/logs/`。
///
/// 复用 session-sharing 在 Zig 侧建好的 `ghostty_surface_set_output_callback` C 机制——**零改
/// Zig 核心**。经 `XGhosttyOutputDispatch`（Swift 侧多订阅分发器）订阅输出，于是会话日志与
/// ⌃⇧S 共享、expect 自动登录可**同时**挂同一会话（不再互相覆盖单槽）。
final class SessionLogStore {
    static let shared = SessionLogStore()
    let dir: URL

    /// 在记的会话：tabId → logger（强持有，覆盖整个会话生命周期；`passUnretained(context)` 因此安全）。
    private var loggers: [UUID: SessionLogger] = [:]

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/logs", isDirectory: true)
    }

    /// 开关（存 layout.json）。
    var enabled: Bool { LayoutStore.shared.layout.sessionLogging == true }

    /// 开始记录（仅当开关开 + 该 tab 尚未在记）。文件名 = `<安全会话名>-<时间戳>.log`。
    func start(tabId: UUID, title: String, surface: Ghostty.SurfaceView) {
        guard enabled, loggers[tabId] == nil else { return }
        let url = dir.appendingPathComponent("\(Self.safeName(title))-\(stamp.string(from: Date())).log")
        let logger = SessionLogger(fileURL: url)
        loggers[tabId] = logger   // 先强持有再订阅（logger 作 sink 的退订 key）
        surface.xghosttyAddOutputSink(key: logger) { [weak logger] data in logger?.ingest(data) }
    }

    /// 停止记录（退订 + flush 关文件）。会话关闭时调用。
    func stop(tabId: UUID, surface: Ghostty.SurfaceView) {
        guard let logger = loggers[tabId] else { return }
        surface.xghosttyRemoveOutputSink(key: logger)
        logger.close()
        loggers[tabId] = nil
    }

    /// logs 目录下的 .log 文件，按修改时间倒序（查看器用）。
    func logFiles() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "log" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db
        }
    }

    /// 读日志内容（plain=剥离 ANSI 成纯文本）。超大只取末尾 ~500KB，避免卡 UI。
    func readLog(_ url: URL, plain: Bool) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let maxBytes = 500_000
        let truncated = data.count > maxBytes
        let slice = truncated ? data.suffix(maxBytes) : data
        let raw = String(decoding: slice, as: UTF8.self)
        let head = truncated ? "…（文件较大，仅显示末尾 \(maxBytes / 1000) KB）\n\n" : ""
        return head + (plain ? Self.stripANSI(raw) : raw)
    }

    /// 简单剥离 ANSI：去 CSI(ESC[…) / OSC(ESC]…) / 其他 ESC 序列 + 控制字符（留 \n \t）。
    /// 交互式程序（vim/top）的光标定位输出剥离后布局仍可能不完美——简单剥离的固有局限。
    static func stripANSI(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" {                                            // ESC
                if i + 1 < scalars.count, scalars[i + 1] == "[" {         // CSI: ESC [ … 终止符 0x40–0x7E
                    i += 2
                    while i < scalars.count {
                        let f = scalars[i]; i += 1
                        if f.value >= 0x40 && f.value <= 0x7E { break }
                    }
                    continue
                }
                if i + 1 < scalars.count, scalars[i + 1] == "]" {         // OSC: ESC ] … BEL 或 ESC \
                    i += 2
                    while i < scalars.count {
                        if scalars[i] == "\u{07}" { i += 1; break }
                        if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "\\" {
                            i += 2; break
                        }
                        i += 1
                    }
                    continue
                }
                i += 2                                                   // 其他 ESC 序列：跳过 ESC + 1 字节
                continue
            }
            if c.value < 0x20 {                                          // 控制字符：留换行/制表，余（含 \r）丢弃
                if c == "\n" || c == "\t" { out.append(c) }
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    /// 会话名 → 安全文件名（去路径分隔/非法字符/控制符，截断 60，空则 session）。
    private static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "session" : String(cleaned.prefix(60))
    }
}
#endif
