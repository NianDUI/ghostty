#if XGHOSTTY
import AppKit
import Foundation

/// ZMODEM(rz/sz) 文件传输桥接器：复用本机 lrzsz 二进制，桥接到 Zig 核心的输出截流(divert)。
///
/// **原理**：远端跑 `sz file`(下载到本机) / `rz`(从本机上传) 会先发 ZMODEM 触发头——
/// `**\x18B00…`(ZRQINIT，远端要发、我们收) 或 `**\x18B01…`(ZRINIT，远端等、我们发)。我们在
/// 输出分发器([[OutputDispatch]])上侦测到触发头后，调 `xghosttySetOutputDiverted(true)` 让
/// Zig 核心把 pty 输出**截流**(只发回调、不喂解析器→屏幕冻结干净不刷乱码)，再 spawn 本机
/// `rz`/`sz`，把**触发头起的后续 pty 输出**喂给它的 stdin、它的 stdout 经 `send_bytes` 回灌远端
/// ——本机 lrzsz 充当 ZMODEM 端点跑完整协议。
///
/// **收尾(去残留乱码)**：子进程退出后远端可能还在吐 ZMODEM 收尾字节(OO/帧尾)。**保持截流**进入
/// draining 态，直到 pty 输出**静默 ~250ms**(收尾字节吐完)才恢复渲染、并发一个回车(`\r`)要个干净
/// 新提示符(不用 Ctrl-L——它在远端 readline 没就绪时会被当字面字符回显成 `�`)。
///
/// **进度**：不靠 lrzsz 的 stderr(管道里它未必输出)，直接**数桥接流过的文件字节**——下载数喂给 rz
/// 的字节、上传数 sz 吐出的字节，每 256KB 报一次「已接收/发送 X.X MB」。
///
/// **依赖**：本机需装 lrzsz(`brew install lrzsz`)；找不到 rz/sz 则向远端发 ZMODEM 取消序列
/// (`CAN`×8) 让远端干净中止并提示安装。
///
/// **线程模型**：`feed` 由分发器在 **termio 线程**调用；子进程 stdout 的 `readabilityHandler` 在
/// 私有队列读、切主线程 `send_bytes`；UI/启动/收尾/divert 全在主线程(divert 不能从 feed 调——那时
/// 已持 renderer 锁，会同线程死锁)。一个桥接器随会话常驻，每次传输结束复位回扫描态，可连续多传。
final class ZmodemBridge {
    /// download = 远端 sz → 本机 rz(接收)；upload = 远端 rz ← 本机 sz(发送)。
    enum Direction { case download, upload }

    /// 活动通知(主线程)：驱动控制器浮层。
    enum Activity {
        case started(Direction, String)     // 方向 + 文件名/描述
        case progress(String)               // 进度行(已接收/发送 X.X MB)
        case finished(String?)              // 完成提示(nil=静默)
    }

    private weak var surface: Ghostty.SurfaceView?
    private let onActivity: (Activity) -> Void

    private let lock = NSLock()
    private enum State { case scanning, active, draining }
    private var state: State = .scanning
    private var accum = Data()               // 扫描期累积(找触发头)，封顶 512B
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pendingToChild = Data()       // 子进程就绪前先缓存要喂给它的字节
    private var childReady = false

    private var direction: Direction = .download
    private var transferredBytes = 0          // 已传输文件字节(进度用)
    private var lastProgressBucket = -1        // 上次报告的 256KB 桶号
    private var drainWork: DispatchWorkItem?   // 收尾静默判定的延时撤截流(仅主线程访问)

    init(surface: Ghostty.SurfaceView, onActivity: @escaping (Activity) -> Void) {
        self.surface = surface
        self.onActivity = onActivity
    }

    // 触发头前缀：`*` `*` CAN `B` `0`，其后一位 `0`=ZRQINIT(下载) / `1`=ZRINIT(上传)。
    private static let triggerPrefix: [UInt8] = [0x2a, 0x2a, 0x18, 0x42, 0x30]

    // MARK: termio 线程入口

    func feed(_ data: Data) {
        lock.lock()
        switch state {
        case .active:
            // 已接管：pty 字节全喂给子进程(未就绪先缓存)。下载方向顺带计入进度。
            let dir = direction
            if childReady, let h = stdinHandle {
                lock.unlock()
                try? h.write(contentsOf: data)
            } else {
                pendingToChild.append(data)
                lock.unlock()
            }
            if dir == .download { bumpProgress(data.count) }

        case .draining:
            // 收尾排空中：字节仍被 Zig 截流丢弃(不渲染)；来一批就重置静默计时器，等真正安静再撤截流。
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.scheduleDrainFinish() }

        case .scanning:
            accum.append(data)
            if accum.count > 512 { accum.removeFirst(accum.count - 512) }
            let bytes = [UInt8](accum)
            guard let hit = Self.findTrigger(bytes) else { lock.unlock(); return }
            // 命中：从触发头起的字节要喂给子进程；切到接管态。
            pendingToChild = Data(bytes[hit.index...])
            accum = Data()
            direction = hit.direction
            transferredBytes = 0
            lastProgressBucket = -1
            state = .active
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.start(direction: hit.direction) }
        }
    }

    /// 会话关闭：若正在传输/收尾则取消远端 + 杀子进程 + 恢复渲染。
    func teardown() {
        drainWork?.cancel()
        lock.lock()
        let proc = process
        let wasActive = (state == .active)
        let wasTransfer = (state == .active || state == .draining)
        process = nil
        stdinHandle = nil
        state = .scanning
        lock.unlock()
        if wasActive { cancelRemote() }
        if wasTransfer { surface?.xghosttySetOutputDiverted(false) }
        proc?.terminationHandler = nil
        if proc?.isRunning == true { proc?.terminate() }
    }

    // MARK: 主线程：启动子进程

    private func start(direction: Direction) {
        guard let surface else { resetToScanning(); return }
        let toolName = direction == .download ? "rz" : "sz"
        guard let bin = Self.lrzszPath(toolName) else {
            cancelRemote()
            resetToScanning()
            onActivity(.finished(nil))
            Self.alertMissingLrzsz()
            return
        }

        // 截流：从这一刻起 pty 输出不再喂解析器 → 屏幕冻结干净，ZMODEM 二进制不刷乱码。
        // 失败/取消/收尾/teardown 各路径都会恢复(false)。
        surface.xghosttySetOutputDiverted(true)

        var fileArgs: [String] = []
        let downloadsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        var label: String
        if direction == .upload {
            // 选要上传的文件(远端 rz 会耐心等 ZRINIT 重发，故弹框延时安全)。
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.prompt = "上传"
            panel.message = "选择要上传到远端当前目录的文件"
            guard panel.runModal() == .OK, !panel.urls.isEmpty else {
                surface.xghosttySetOutputDiverted(false)
                cancelRemote(); resetToScanning(); onActivity(.finished("已取消上传")); return
            }
            fileArgs = panel.urls.map { $0.path }
            label = fileArgs.count == 1
                ? (fileArgs[0] as NSString).lastPathComponent
                : "\(fileArgs.count) 个文件"
        } else {
            try? FileManager.default.createDirectory(
                at: downloadsDir, withIntermediateDirectories: true)
            label = "接收文件 → ~/Downloads"
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        // rz: -y 覆盖同名 / -b 二进制；sz: -b 二进制 / -e 转义控制字符(pty 链路更稳)。
        proc.arguments = direction == .download
            ? ["-y", "-b"]
            : (["-b", "-e"] + fileArgs)
        if direction == .download { proc.currentDirectoryURL = downloadsDir }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // 子进程 stdout(ZMODEM 响应/上传文件数据) → send_bytes 回灌远端。上传方向顺带计入进度。
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let d = handle.availableData
            guard !d.isEmpty, let self else { return }
            DispatchQueue.main.async { self.surface?.xghosttySendBytes(d) }
            if self.direction == .upload { self.bumpProgress(d.count) }
        }
        // stderr 读空避免管道塞满阻塞子进程(进度改用字节计数，不解析 stderr)。
        errPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleChildExit() }
        }

        do {
            try proc.run()
        } catch {
            surface.xghosttySetOutputDiverted(false)
            cancelRemote(); resetToScanning(); onActivity(.finished("启动 \(toolName) 失败")); return
        }

        // 就绪：登记句柄并把扫描期缓存的(触发头起)字节灌进去。
        lock.lock()
        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        childReady = true
        let pending = pendingToChild
        pendingToChild = Data()
        lock.unlock()
        if !pending.isEmpty {
            try? stdinHandle?.write(contentsOf: pending)
            if direction == .download { bumpProgress(pending.count) }
        }

        onActivity(.started(direction, label))
    }

    // MARK: 主线程：进度 / 子进程退出 / 收尾

    /// 累加文件字节，跨 256KB 桶时报一次进度(下载在 termio 线程、上传在管道队列调，各自单线程)。
    private func bumpProgress(_ n: Int) {
        transferredBytes += n
        let bucket = transferredBytes / (256 * 1024)
        guard bucket != lastProgressBucket else { return }
        lastProgressBucket = bucket
        let mb = Double(transferredBytes) / (1024 * 1024)
        let verb = direction == .download ? "已接收" : "已发送"
        let txt = String(format: "%@ %.1f MB", verb, mb)
        DispatchQueue.main.async { [weak self] in self?.onActivity(.progress(txt)) }
    }

    private func handleChildExit() {
        // 子进程已退，但远端可能还在吐 ZMODEM 收尾字节。进入 draining 态保持截流，直到输出静默
        // ~250ms(收尾吐完)才在 finishDrain 撤截流 + 回车要新提示符——避免尾字节漏渲成残留乱码。
        lock.lock()
        state = .draining
        process = nil
        stdinHandle = nil
        childReady = false
        lock.unlock()
        scheduleDrainFinish()
    }

    /// 重置静默计时器：每次收到收尾字节就把"撤截流"往后推 250ms，真正安静后才执行。
    private func scheduleDrainFinish() {
        drainWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishDrain() }
        drainWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishDrain() {
        surface?.xghosttySetOutputDiverted(false)            // 恢复渲染
        surface?.xghosttySendBytes(Data([0x0d]))             // 回车 → 干净新提示符(不用 Ctrl-L)
        lock.lock()
        if state == .draining { state = .scanning }
        accum = Data()
        pendingToChild = Data()
        transferredBytes = 0
        lastProgressBucket = -1
        lock.unlock()
        onActivity(.finished(nil))   // 屏幕已恢复干净，这才隐浮层
    }

    private func resetToScanning() {
        lock.lock()
        state = .scanning
        process = nil
        stdinHandle = nil
        childReady = false
        pendingToChild = Data()
        accum = Data()
        transferredBytes = 0
        lastProgressBucket = -1
        lock.unlock()
    }

    /// 向远端发 ZMODEM 取消序列(8×CAN + 8×BS)，让远端 sz/rz 干净中止。
    private func cancelRemote() {
        let can = [UInt8](repeating: 0x18, count: 8)
        let bs = [UInt8](repeating: 0x08, count: 8)
        surface?.xghosttySendBytes(Data(can + bs))
    }

    // MARK: 工具

    /// 在 accum 字节里找触发头，返回(起始索引, 方向)。
    private static func findTrigger(_ bytes: [UInt8]) -> (index: Int, direction: Direction)? {
        let t = triggerPrefix
        guard bytes.count >= t.count + 1 else { return nil }
        let last = bytes.count - (t.count + 1)
        var i = 0
        while i <= last {
            if Array(bytes[i..<i + t.count]) == t {
                switch bytes[i + t.count] {
                case 0x30: return (i, .download)   // "00" ZRQINIT → 远端 sz → 本机 rz
                case 0x31: return (i, .upload)     // "01" ZRINIT → 远端 rz → 本机 sz
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    /// 查找本机 rz/sz(应用环境未必带 brew PATH，逐候选路径探)。
    private static func lrzszPath(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",   // Apple Silicon brew
            "/usr/local/bin/\(name)",      // Intel brew
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func alertMissingLrzsz() {
        let alert = NSAlert()
        alert.messageText = "未找到 rz/sz"
        alert.informativeText = "ZMODEM 文件传输需要本机 lrzsz。请在终端执行：\n\n    brew install lrzsz\n\n装好后重试即可（已向远端发送取消，远端不会卡住）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
#endif
