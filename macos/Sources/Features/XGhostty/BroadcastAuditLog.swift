#if XGHOSTTY
import Foundation

/// 广播审计日志：每次「批量发送条」向多台会话群发命令时留痕（谁、何时、发了什么）。
///
/// **为什么**：对几十上百台生产机批量发命令是高危操作，事后要能追溯「那条 `rm` 到底打到了哪些机器」。
/// 单发当前会话不记（噪音大、且终端 scrollback / 会话日志已覆盖）——只记目标为「全部 / 分组」的**真广播**。
///
/// 追加写到 `~/.config/xghostty/broadcast-audit.log`（0600），**JSON Lines**（每行一条独立 JSON），
/// 便于将来做「审计查看」UI，也方便 `jq` / `grep` 直接分析。命令含换行会被 JSON 转义成 `\n`，不破坏逐行。
final class BroadcastAuditLog {
    static let shared = BroadcastAuditLog()
    let fileURL: URL

    /// 串行写队列：避免群发后主线程同步落盘卡 UI，多条记录也不会交错。
    private let queue = DispatchQueue(label: "top.niandui.xghostty.audit")
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current   // 带本地时区偏移（如 +08:00），运维看本地时间
        return f
    }()

    init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/broadcast-audit.log")
    }

    /// 记一条广播。`targets` = 命中会话的 (名称, host?)；`targetLabel` = 「全部」/「分组：xxx」。
    func record(command: String, targetLabel: String,
                targets: [(name: String, host: String?)]) {
        let entry: [String: Any] = [
            "ts": stamp.string(from: Date()),
            "target": targetLabel,
            "count": targets.count,
            "sessions": targets.map { ["name": $0.name, "host": $0.host ?? ""] },
            "command": command,
        ]
        queue.async { [fileURL] in
            guard var line = try? JSONSerialization.data(
                withJSONObject: entry, options: [.sortedKeys]) else { return }
            line.append(0x0A)   // '\n'：JSON Lines 行尾
            Self.append(line, to: fileURL)
        }
    }

    /// 追加写（文件不存在则以 0600 新建，目录 0700）。
    private static func append(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
#endif
