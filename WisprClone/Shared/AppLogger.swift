import Foundation
import os
import OSLog

/// Unified logging surface (Phase 11).
/// Prefer these category loggers over ad-hoc `Logger` instances.
enum AppLogger {
    static let subsystem = Constants.bundleIdentifier

    static let app = Logger(subsystem: subsystem, category: "App")
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let keychain = Logger(subsystem: subsystem, category: "Keychain")
    static let configuration = Logger(subsystem: subsystem, category: "Configuration")
    static let hotkeys = Logger(subsystem: subsystem, category: "Hotkeys")
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let vad = Logger(subsystem: subsystem, category: "VAD")
    static let speech = Logger(subsystem: subsystem, category: "Speech")
    static let llm = Logger(subsystem: subsystem, category: "LLM")
    static let injection = Logger(subsystem: subsystem, category: "Injection")
    static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    static let menuBar = Logger(subsystem: subsystem, category: "MenuBar")
    static let pipeline = Logger(subsystem: subsystem, category: "Pipeline")
    static let env = Logger(subsystem: subsystem, category: "Env")

    /// Measures an async operation and logs elapsed milliseconds.
    ///
    /// `isolation` defaults to `#isolation` so callers on `@MainActor` (or any actor)
    /// can pass non-Sendable closures without crossing isolation boundaries.
    @discardableResult
    static func measure<T>(
        _ operationName: String,
        logger: Logger,
        level: OSLogType = .info,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let start = ContinuousClock.now
        do {
            let value = try await work()
            let ms = elapsedMilliseconds(since: start)
            logger.log(level: level, "\(operationName, privacy: .public) completed in \(ms, format: .fixed(precision: 1)) ms")
            return value
        } catch {
            let ms = elapsedMilliseconds(since: start)
            logger.error("\(operationName, privacy: .public) failed after \(ms, format: .fixed(precision: 1)) ms — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Measures a synchronous operation and logs elapsed milliseconds.
    @discardableResult
    static func measureSync<T>(
        _ operationName: String,
        logger: Logger,
        level: OSLogType = .info,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () throws -> T
    ) rethrows -> T {
        let start = ContinuousClock.now
        do {
            let value = try work()
            let ms = elapsedMilliseconds(since: start)
            logger.log(level: level, "\(operationName, privacy: .public) completed in \(ms, format: .fixed(precision: 1)) ms")
            return value
        } catch {
            let ms = elapsedMilliseconds(since: start)
            logger.error("\(operationName, privacy: .public) failed after \(ms, format: .fixed(precision: 1)) ms — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
