#if XGHOSTTY
import AppKit
import Foundation

/// ZMODEM(rz/sz) 文件传输桥接器：复用本机 lrzsz 二进制，桥接到 Zig 核心的输出截流(divert)。
///
/// **原理**：远端跑 `sz file`(下载到本机) / `rz`(从本机上传) 会先发 ZMODEM 触发头——
/// `**\x18B00…`(ZRQINIT) 或 `**\x18B01…`(ZRINIT)。我们在输出分发器([[OutputDispatch]])上侦测到
/// 触发头后，调 `xghosttySetOutputDiverted(true)` 让 Zig 核心**截流**(只发回调、不喂解析器→屏幕冻结
/// 干净)，再 spawn 本机 `rz`/`sz`，把**触发头起的后续 pty 输出**喂给它、它的输出经 `send_bytes`
/// 回灌远端——本机 lrzsz 充当 ZMODEM 端点跑完整协议。
///
/// **必须用伪终端(pty)而非管道**：lrzsz 的 rz/sz 要在一个真正的 tty 上做 `tcsetattr` 设原始模式 +
/// `isatty` 判定，给它普通管道会导致握手跑不通、ZMODEM 响应漏给远端 shell(出现 `bash: �: 未找到
/// 命令`)。故这里 `posix_openpt` 开一对 pty：子进程 stdin/stdout 接 slave(并预置 raw 防回显),
/// 父进程读写 master 在「远端 ↔ rz/sz」之间搬字节。
///
/// **收尾(去残留乱码)**：子进程退出后远端可能还在吐收尾字节。进 draining 态保持截流，直到 pty 输出
/// **静默 ~250ms** 才撤截流 + 发回车要个干净新提示符(不用 Ctrl-L——它会被当字面字符回显成 `�`)。
///
/// **取消**：用户按 Esc → `cancel()` 向远端发 ZMODEM 取消序列 + 杀本机 rz/sz + 恢复渲染。
///
/// **进度**：数桥接流过的文件字节，每 256KB 报一次「已接收/发送 X.X MB」。
///
/// **线程模型**：`feed` 在 termio 线程；master 的读在私有队列；UI/启动/收尾/divert/cancel 全在主线程
/// (divert 不能从 feed 调——那时已持 renderer 锁会死锁)。桥接器随会话常驻，每传完复位可连续多传。
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
    /// 活动回调，创建后由控制器回填(好让回调闭包能弱引用本桥接器，供 Esc 取消定位当前传输)。
    var onActivity: (Activity) -> Void = { _ in }

    private let lock = NSLock()
    private enum State { case scanning, active, draining }
    private var state: State = .scanning
    private var accum = Data()               // 扫描期累积(找触发头)，封顶 512B
    private var process: Process?
    private var masterFD: Int32 = -1          // pty master：父进程读写端
    private var masterHandle: FileHandle?     // 包 masterFD 做读(readabilityHandler)
    private var pendingToChild = Data()       // 子进程就绪前先缓存要喂给它的字节
    private var childReady = false

    private var direction: Direction = .download
    private var transferredBytes = 0          // 已传输文件字节(进度用)
    private var lastProgressBucket = -1        // 上次报告的 256KB 桶号
    private var drainWork: DispatchWorkItem?   // 收尾静默判定的延时撤截流(仅主线程访问)

    init(surface: Ghostty.SurfaceView) {
        self.surface = surface
    }

    // 触发头前缀：`*` `*` CAN `B` `0`，其后一位 `0`=ZRQINIT(下载) / `1`=ZRINIT(上传)。
    private static let triggerPrefix: [UInt8] = [0x2a, 0x2a, 0x18, 0x42, 0x30]

    // MARK: termio 线程入口

    func feed(_ data: Data) {
        lock.lock()
        switch state {
        case .active:
            // 已接管：pty 字节全写给子进程的 master(未就绪先缓存)。下载方向顺带计入进度。
            let dir = direction
            if childReady, masterFD >= 0 {
                let fd = masterFD
                lock.unlock()
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress, raw.count > 0 {
                        _ = write(fd, base, raw.count)
                    }
                }
            } else {
                pendingToChild.append(data)
                lock.unlock()
            }
            if dir == .download { bumpProgress(data.count) }

        case .draining:
            // 收尾排空中：字节仍被 Zig 截流丢弃；来一批就重置静默计时器，等真正安静再撤截流。
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.scheduleDrainFinish() }

        case .scanning:
            accum.append(data)
            if accum.count > 512 { accum.removeFirst(accum.count - 512) }
            let bytes = [UInt8](accum)
            guard let hit = Self.findTrigger(bytes) else { lock.unlock(); return }
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
        state = .scanning
        lock.unlock()
        closeMaster()
        if wasActive { cancelRemote() }
        if wasTransfer { surface?.xghosttySetOutputDiverted(false) }
        proc?.terminationHandler = nil
        if proc?.isRunning == true { proc?.terminate() }
    }

    /// 用户 Esc 取消进行中的传输：发 ZMODEM 取消 + 杀 rz/sz + 恢复渲染 + 回车要新提示符 + 提示。
    func cancel() {
        drainWork?.cancel()
        lock.lock()
        let proc = process
        let wasActive = (state == .active)
        let wasTransfer = (state == .active || state == .draining)
        process = nil
        state = .scanning
        accum = Data()
        pendingToChild = Data()
        lock.unlock()
        closeMaster()
        if wasActive { cancelRemote() }
        if wasTransfer {
            surface?.xghosttySetOutputDiverted(false)
            surface?.xghosttySendBytes(Data([0x0d]))
        }
        proc?.terminationHandler = nil
        if proc?.isRunning == true { proc?.terminate() }
        onActivity(.finished(wasTransfer ? "已取消传输" : nil))
    }

    // MARK: 主线程：启动子进程(伪终端)

    private func start(direction: Direction) {
        guard let surface else { resetToScanning(); return }
        let toolName = direction == .download ? "rz" : "sz"
        guard let bin = Self.lrzszPath(toolName) else {
            cancelRemote(); resetToScanning(); onActivity(.finished(nil)); Self.alertMissingLrzsz(); return
        }

        surface.xghosttySetOutputDiverted(true)   // 截流：传输期屏幕冻结干净

        var fileArgs: [String] = []
        let downloadsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        var label: String
        if direction == .upload {
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
            try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            label = "接收文件 → ~/Downloads"
        }

        // 开 pty：master(父读写) + slave(子 stdin/stdout)。slave 预置 raw 模式防回显/行处理。
        guard let pty = Self.openPTY() else {
            surface.xghosttySetOutputDiverted(false)
            cancelRemote(); resetToScanning(); onActivity(.finished("无法分配伪终端")); return
        }
        let (master, slave) = pty

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        // rz: -y 覆盖同名 / -b 二进制；sz: -b 二进制 / -e 转义控制字符。
        proc.arguments = direction == .download ? ["-y", "-b"] : (["-b", "-e"] + fileArgs)
        if direction == .download { proc.currentDirectoryURL = downloadsDir }
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = FileHandle.nullDevice   // rz/sz 的进度/诊断丢弃，不混进 ZMODEM 流

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleChildExit() }
        }

        do {
            try proc.run()
        } catch {
            close(master); close(slave)
            surface.xghosttySetOutputDiverted(false)
            cancelRemote(); resetToScanning(); onActivity(.finished("启动 \(toolName) 失败")); return
        }
        close(slave)   // 父进程关 slave；子进程持自己的 dup → 子退出时 master 收到 EOF。

        // master 读端：rz/sz 写到 slave 的字节(ZMODEM 响应 / 上传文件数据) → send_bytes 回灌远端。
        let mh = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        mh.readabilityHandler = { [weak self] handle in
            let d = handle.availableData
            guard let self else { return }
            if d.isEmpty { handle.readabilityHandler = nil; return }   // EOF
            DispatchQueue.main.async { self.surface?.xghosttySendBytes(d) }
            if self.direction == .upload { self.bumpProgress(d.count) }
        }

        lock.lock()
        process = proc
        masterFD = master
        masterHandle = mh
        childReady = true
        let pending = pendingToChild
        pendingToChild = Data()
        lock.unlock()
        if !pending.isEmpty {
            pending.withUnsafeBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 { _ = write(master, base, raw.count) }
            }
            if direction == .download { bumpProgress(pending.count) }
        }

        onActivity(.started(direction, label))
    }

    // MARK: 主线程：进度 / 子进程退出 / 收尾

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
        // 子进程已退，但远端可能还在吐 ZMODEM 收尾字节。进 draining 保持截流，等输出静默 ~250ms
        // 才在 finishDrain 撤截流 + 回车——避免尾字节漏渲成残留乱码。
        lock.lock()
        state = .draining
        process = nil
        childReady = false
        lock.unlock()
        closeMaster()
        scheduleDrainFinish()
    }

    private func scheduleDrainFinish() {
        drainWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishDrain() }
        drainWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishDrain() {
        surface?.xghosttySetOutputDiverted(false)            // 恢复渲染
        surface?.xghosttySendBytes(Data([0x0d]))             // 回车 → 干净新提示符
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
        childReady = false
        pendingToChild = Data()
        accum = Data()
        transferredBytes = 0
        lastProgressBucket = -1
        lock.unlock()
        closeMaster()
    }

    /// 关 pty master(撤读 handler + 关 fd)。
    private func closeMaster() {
        masterHandle?.readabilityHandler = nil
        masterHandle = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
    }

    /// 向远端发 ZMODEM 取消序列(8×CAN + 8×BS)，让远端 sz/rz 干净中止。
    private func cancelRemote() {
        let can = [UInt8](repeating: 0x18, count: 8)
        let bs = [UInt8](repeating: 0x08, count: 8)
        surface?.xghosttySendBytes(Data(can + bs))
    }

    // MARK: 工具

    /// 开一对 pty，slave 预置 raw 模式(关回显/行处理/输出加工)。返回 (master, slave) fd。
    private static func openPTY() -> (master: Int32, slave: Int32)? {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0, let namePtr = ptsname(master) else {
            close(master); return nil
        }
        let slave = open(String(cString: namePtr), O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); return nil }
        var tio = termios()
        if tcgetattr(slave, &tio) == 0 {
            cfmakeraw(&tio)
            _ = tcsetattr(slave, TCSANOW, &tio)
        }
        return (master, slave)
    }

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
