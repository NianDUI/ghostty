import Foundation
import os

private let resumeStoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
    category: "session-sharing-resume"
)

/// Persists the set of `SurfaceView.id`s that are currently in the
/// `.sharing` state so the next launch can auto-restart sharing for
/// them. We deliberately do NOT persist the relay URL / agent token /
/// session name — the resume flow re-runs the full `startSharing`
/// path and mints fresh credentials.
///
/// Storage: `<Application Support>/com.mitchellh.ghostty/sharing-resume.json`.
/// Schema: `{"surfaceIDs": ["<uuid>", ...]}` with UUIDs lowercased
/// and sorted so diffs stay stable across writes.
///
/// All writes are atomic (FileManager rename). Failures are logged
/// and swallowed — sharing must keep working even if the resume
/// breadcrumb can't be written.
final class SessionSharingResumeStore {
    private struct Payload: Codable {
        var surfaceIDs: [String]
    }

    static let shared = SessionSharingResumeStore()

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        fileURL: URL = SessionSharingResumeStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(for fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("sharing-resume.json", isDirectory: false)
    }

    func add(_ id: UUID) {
        mutate { current in
            current.insert(id)
        }
    }

    func remove(_ id: UUID) {
        mutate { current in
            current.remove(id)
        }
    }

    /// Overwrite the stored set with `ids`. Used by the launch-time
    /// reconciler to drop UUIDs whose surfaces were not restored
    /// (user closed those tabs before quitting).
    func replace(_ ids: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        write(ids)
    }

    func load() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    private func mutate(_ body: (inout Set<UUID>) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var current = readLocked()
        let before = current
        body(&current)
        guard current != before else { return }
        write(current)
    }

    private func readLocked() -> Set<UUID> {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return Set(payload.surfaceIDs.compactMap(UUID.init(uuidString:)))
        } catch {
            resumeStoreLog.warning(
                "session-sharing resume: failed to read \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func write(_ ids: Set<UUID>) {
        let payload = Payload(
            surfaceIDs: ids.map { $0.uuidString.lowercased() }.sorted()
        )
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            resumeStoreLog.warning(
                "session-sharing resume: failed to write \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
