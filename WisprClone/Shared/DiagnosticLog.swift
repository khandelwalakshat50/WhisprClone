import Foundation
import os

/// Appends plain-text diagnostics to Application Support so we can debug
/// when Console/OSLog isn't available.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "\(Constants.bundleIdentifier).diag")
    private static let lock = NSLock()

    private static var fileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Constants.appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        // Synchronous write so the log is always complete when we read it.
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        AppLogger.app.info("\(message, privacy: .public)")
    }
}
