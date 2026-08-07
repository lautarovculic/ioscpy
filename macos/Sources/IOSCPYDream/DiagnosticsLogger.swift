import AppKit
import Darwin
import Foundation

/// Persistent JSON-lines diagnostics for real-device performance work.
///
/// The active run is always written to ~/Library/Logs/ioscpy/latest.log so the
/// user can attach one stable file after a bad session or even after a crash.
/// On the next launch the previous latest.log is archived with a timestamp.
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private let queue = DispatchQueue(label: "com.ioscpy.diagnostics", qos: .utility)
    private let startedAtNanos = DispatchTime.now().uptimeNanoseconds
    private var handle: FileHandle?
    private var activeURL: URL?

    private init() {}

    var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ioscpy", isDirectory: true)
    }

    var latestLogURL: URL {
        logDirectory.appendingPathComponent("latest.log")
    }

    func start() {
        queue.sync {
            guard handle == nil else { return }
            do {
                try FileManager.default.createDirectory(
                    at: logDirectory,
                    withIntermediateDirectories: true
                )
                try archivePreviousLatestLocked()
                FileManager.default.createFile(atPath: latestLogURL.path, contents: nil)
                let opened = try FileHandle(forWritingTo: latestLogURL)
                try opened.seekToEnd()
                handle = opened
                activeURL = latestLogURL
                writeLocked(category: "app_start", fields: [
                    "release": "0.3.0-dream.9",
                    "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                    "machine": Self.machineIdentifier(),
                    "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
                    "processor_count": ProcessInfo.processInfo.processorCount,
                ])
            } catch {
                NSLog("[ioscpy] diagnostics start failed: %@", error.localizedDescription)
            }
        }
    }

    func log(_ category: String, fields: [String: Any] = [:]) {
        guard let line = makeLine(category: category, fields: fields) else { return }
        queue.async { [weak self] in
            self?.writeDataLocked(line)
        }
    }

    func logMessage(_ category: String, _ message: String) {
        log(category, fields: ["message": message])
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    @MainActor
    func revealInFinder() {
        start()
        NSWorkspace.shared.activateFileViewerSelecting([latestLogURL])
    }

    private func writeLocked(category: String, fields: [String: Any]) {
        guard let line = makeLine(category: category, fields: fields) else { return }
        writeDataLocked(line)
    }

    private func makeLine(category: String, fields: [String: Any]) -> Data? {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(nowNanos &- startedAtNanos) / 1_000_000
        var object = fields
        object["category"] = category
        object["elapsed_ms"] = (elapsedMs * 1000).rounded() / 1000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        object["timestamp"] = formatter.string(from: Date())
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    private func writeDataLocked(_ data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            NSLog("[ioscpy] diagnostics write failed: %@", error.localizedDescription)
        }
    }

    private func archivePreviousLatestLocked() throws {
        guard FileManager.default.fileExists(atPath: latestLogURL.path) else {
            pruneArchivesLocked()
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: latestLogURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let archive = logDirectory.appendingPathComponent("ioscpy-\(formatter.string(from: Date())).log")
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: latestLogURL, to: archive)
        } else {
            try? FileManager.default.removeItem(at: latestLogURL)
        }
        pruneArchivesLocked()
    }

    private func pruneArchivesLocked() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let archives = urls.filter { $0.lastPathComponent.hasPrefix("ioscpy-") && $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for stale in archives.dropFirst(12) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func machineIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
