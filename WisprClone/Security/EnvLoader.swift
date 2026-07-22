import Foundation
import Synchronization

/// Loads `OPENAI_API_KEY` / `GROQ_API_KEY` from a `.env` file and the process environment.
///
/// Search order:
/// 1. Process environment
/// 2. `~/Library/Application Support/WisprClone/.env`
/// 3. Current working directory `.env`
/// 4. Walk up from the app bundle looking for `.env` (finds the repo root in many Debug layouts)
/// 5. Path beside the `.app` bundle
enum EnvLoader {
    struct Values: Equatable, Sendable {
        var openAIAPIKey: String?
        var groqAPIKey: String?

        var hasAnyKey: Bool {
            !(openAIAPIKey ?? "").isEmpty || !(groqAPIKey ?? "").isEmpty
        }
    }

    private static let cached = Mutex<Values?>(nil)

    /// Parsed keys (cached for the process lifetime; call `reload()` after editing `.env`).
    static var current: Values {
        cached.withLock { storage in
            if let storage { return storage }
            let loaded = load()
            storage = loaded
            return loaded
        }
    }

    static func reload() {
        cached.withLock { $0 = nil }
        _ = current
    }

    static func load() -> Values {
        var values = Values()

        // Process environment wins for CI / launchd wrappers.
        if let openAI = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !openAI.isEmpty {
            values.openAIAPIKey = openAI
        }
        if let groq = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !groq.isEmpty {
            values.groqAPIKey = groq
        }

        for url in candidateFileURLs() {
            guard let fileValues = parseFile(at: url) else { continue }
            AppLogger.env.info("Loaded .env from \(url.path, privacy: .public)")
            if values.openAIAPIKey == nil, let key = fileValues.openAIAPIKey, !key.isEmpty {
                values.openAIAPIKey = key
            }
            if values.groqAPIKey == nil, let key = fileValues.groqAPIKey, !key.isEmpty {
                values.groqAPIKey = key
            }
        }

        // Ensure Application Support copy exists for future launches outside Xcode.
        mirrorToApplicationSupportIfNeeded(values)
        return values
    }

    // MARK: - Candidates

    private static func candidateFileURLs() -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default

        // Repo / working-directory copies win over the Application Support mirror,
        // so editing the project .env always takes effect on next launch.
        urls.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env"))

        let bundleURL = Bundle.main.bundleURL
        urls.append(contentsOf: walkUpForEnv(startingAt: bundleURL))
        urls.append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(appSupport.appendingPathComponent("WisprClone/.env", isDirectory: false))
        }

        // Deduplicate while preserving order.
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return fm.isReadableFile(atPath: path)
        }
    }

    private static func walkUpForEnv(startingAt start: URL, maxDepth: Int = 10) -> [URL] {
        var result: [URL] = []
        var url = start.standardizedFileURL
        for _ in 0..<maxDepth {
            result.append(url.appendingPathComponent(".env"))
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return result
    }

    // MARK: - Parse

    private static func parseFile(at url: URL) -> Values? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values = Values()
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "OPENAI_API_KEY":
                values.openAIAPIKey = value
            case "GROQ_API_KEY":
                values.groqAPIKey = value
            default:
                break
            }
        }
        return values
    }

    private static func mirrorToApplicationSupportIfNeeded(_ values: Values) {
        guard values.hasAnyKey else { return }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("WisprClone", isDirectory: true)
        let dest = dir.appendingPathComponent(".env")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines: [String] = []
            if let openAI = values.openAIAPIKey { lines.append("OPENAI_API_KEY=\(openAI)") }
            if let groq = values.groqAPIKey { lines.append("GROQ_API_KEY=\(groq)") }
            try lines.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
            AppLogger.env.info("Mirrored .env → Application Support")
        } catch {
            AppLogger.env.error("Failed to mirror .env: \(error.localizedDescription, privacy: .public)")
        }
    }
}
