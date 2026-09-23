import Cocoa

private final class SSHImagePasteDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum SSHImagePasteUploadError: LocalizedError {
    case imageTooLarge(actual: Int, limit: Int)
    case cannotEncodeImage
    case cannotStart(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .imageTooLarge(actual, limit):
            return "剪贴板图片大小为 \(Self.mib(actual)) MiB，超过 \(Self.mib(limit)) MiB 上限。"
        case .cannotEncodeImage:
            return "无法把剪贴板图片转换为 PNG。"
        case let .cannotStart(message):
            return "无法启动 SSH 上传：\(message)"
        case let .uploadFailed(message):
            return message.isEmpty ? "SSH 图片上传失败。" : "SSH 图片上传失败：\(message)"
        }
    }

    private static func mib(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }
}

enum SSHImagePasteUploader {
    struct Request {
        var pngData: Data
        var sshArguments: [String]
        var environment: [String: String]
        var remoteBaseDirectory: String
        var surfaceID: UUID
        var imageID: UUID = UUID()
    }

    /// nil 表示当前剪贴板不是图片，此时调用方应把 Ctrl+V 原样交还终端。
    @MainActor static func clipboardPNGData(_ pasteboard: NSPasteboard = .general) throws -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }

        if let image = NSImage(pasteboard: pasteboard) {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw SSHImagePasteUploadError.cannotEncodeImage
            }
            return png
        }
        return nil
    }

    static func runningSSHArguments(foregroundPID: Int) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // 必须先持续读管道再 wait；全进程列表可能超过 pipe 缓冲区，反过来会与 ps 死锁。
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            guard let processList = String(data: data, encoding: .utf8) else { return nil }
            return SSHImagePasteRunningSSH.uploadArguments(
                processList: processList,
                rootPID: foregroundPID)
        } catch {
            return nil
        }
    }

    static func upload(_ request: Request,
                       completion: @escaping (Result<String, Error>) -> Void) {
        let path = SSHImagePastePath.remotePath(
            baseDirectory: request.remoteBaseDirectory,
            surfaceID: request.surfaceID,
            imageID: request.imageID)
        let directory = (path as NSString).deletingLastPathComponent
        let remoteCommand = "umask 077 && mkdir -p -- \(shellQuote(directory)) && cat > \(shellQuote(path))"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = request.sshArguments + [remoteCommand]
            process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }

            let input = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = error

            do {
                try process.run()
                let stderrBox = SSHImagePasteDataBox()
                let stderrGroup = DispatchGroup()
                stderrGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrBox.store(error.fileHandleForReading.readDataToEndOfFile())
                    stderrGroup.leave()
                }
                input.fileHandleForWriting.write(request.pngData)
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                stderrGroup.wait()
                let stderr = stderrBox.load()
                let message = String(data: stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        completion(.success(path))
                    } else {
                        completion(.failure(SSHImagePasteUploadError.uploadFailed(message)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(SSHImagePasteUploadError.cannotStart(error.localizedDescription)))
                }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
