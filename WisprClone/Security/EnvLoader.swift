import Foundation
import Synchronization

/// Loads API keys from a `.env` file and the process environment.
///
/// Supported keys: `DEEPGRAM_API_KEY`, `GEMINI_API_KEY` (alias `GOOGLE_API_KEY`), `OPENAI_API_KEY`, `GROQ_API_KEY`.
///
/// Search order:
/// 1. Process environment
/// 2. Current working directory `.env`
/// 3. Walk up from the app bundle looking for `.env` (finds the repo root in many Debug layouts)
/// 4. Path beside the `.app` bundle
/// 5. `~/Library/Application Support/WisprClone/.env`
enum EnvLoader {
    struct Values: Equatable, Sendable {
        var deepgramAPIKey: String?
        var geminiAPIKey: String?
        var openAIAPIKey: String?
        var groqAPIKey: String?

        var hasAnyKey: Bool {
            !(deepgramAPIKey ?? "").isEmpty
                || !(geminiAPIKey ?? "").isEmpty
                || !(openAIAPIKey ?? "").isEmpty
                || !(groqAPIKey ?? "").isEmpty
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
        if let deepgram = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !deepgram.isEmpty {
            values.deepgramAPIKey = deepgram
        }
        if let gemini = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !gemini.isEmpty {
            values.geminiAPIKey = gemini
        } else if let google = ProcessInfo.processInfo.environment["GOOGLE_API_KEY"], !google.isEmpty {
            values.geminiAPIKey = google
        }
        if let openAI = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !openAI.isEmpty {
            values.openAIAPIKey = openAI
        }
        if let groq = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !groq.isEmpty {
            values.groqAPIKey = groq
        }

        for url in candidateFileURLs() {
            guard let fileValues = parseFile(at: url) else { continue }
            AppLogger.env.info("Loaded .env from \(url.path, privacy: .public)")
            if values.deepgramAPIKey == nil, let key = fileValues.deepgramAPIKey, !key.isEmpty {
                values.deepgramAPIKey = key
            }
            if values.geminiAPIKey == nil, let key = fileValues.geminiAPIKey, !key.isEmpty {
                values.geminiAPIKey = key
            }
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

        // Common local clone path when the app is launched from /Applications
        // (cwd / bundle walk never reach the repo).
        let home = fm.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent("OpenWhisper/.env"))
        urls.append(home.appendingPathComponent("Developer/OpenWhisper/.env"))
        urls.append(home.appendingPathComponent("Documents/OpenWhisper/.env"))

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
            case "DEEPGRAM_API_KEY":
                values.deepgramAPIKey = value
            case "GEMINI_API_KEY", "GOOGLE_API_KEY":
                if values.geminiAPIKey == nil || values.geminiAPIKey?.isEmpty == true {
                    values.geminiAPIKey = value
                }
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

            // Merge into any existing Application Support .env so adding one
            // new key (e.g. Gemini) never wipes OpenAI/Groq already mirrored.
            var merged = parseFile(at: dest) ?? Values()
            if let deepgram = values.deepgramAPIKey, !deepgram.isEmpty { merged.deepgramAPIKey = deepgram }
            if let gemini = values.geminiAPIKey, !gemini.isEmpty { merged.geminiAPIKey = gemini }
            if let openAI = values.openAIAPIKey, !openAI.isEmpty { merged.openAIAPIKey = openAI }
            if let groq = values.groqAPIKey, !groq.isEmpty { merged.groqAPIKey = groq }

            var lines: [String] = []
            if let deepgram = merged.deepgramAPIKey, !deepgram.isEmpty { lines.append("DEEPGRAM_API_KEY=\(deepgram)") }
            if let gemini = merged.geminiAPIKey, !gemini.isEmpty { lines.append("GEMINI_API_KEY=\(gemini)") }
            if let openAI = merged.openAIAPIKey, !openAI.isEmpty { lines.append("OPENAI_API_KEY=\(openAI)") }
            if let groq = merged.groqAPIKey, !groq.isEmpty { lines.append("GROQ_API_KEY=\(groq)") }
            try lines.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
            AppLogger.env.info(
                "Mirrored .env → Application Support (deepgram=\(!(merged.deepgramAPIKey ?? "").isEmpty), gemini=\(!(merged.geminiAPIKey ?? "").isEmpty), openai=\(!(merged.openAIAPIKey ?? "").isEmpty), groq=\(!(merged.groqAPIKey ?? "").isEmpty))"
            )
            DiagnosticLog.write(
                "env keys deepgram=\(!(merged.deepgramAPIKey ?? "").isEmpty) gemini=\(!(merged.geminiAPIKey ?? "").isEmpty) openai=\(!(merged.openAIAPIKey ?? "").isEmpty) groq=\(!(merged.groqAPIKey ?? "").isEmpty)"
            )
        } catch {
            AppLogger.env.error("Failed to mirror .env: \(error.localizedDescription, privacy: .public)")
        }
    }
}
