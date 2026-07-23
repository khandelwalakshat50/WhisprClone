import Foundation
import SwiftUI

/// Persists non-secret settings in UserDefaults.
/// API keys: Settings UI → Keychain, seeded from `.env` / process environment.
@MainActor
final class ConfigurationStore: ObservableObject {
    @Published var configuration: Configuration {
        didSet { persist(configuration) }
    }

    @Published var geminiAPIKey: String = ""
    @Published var openAIAPIKey: String = ""
    @Published var groqAPIKey: String = ""

    /// True when keys were sourced from `.env` (shown in Settings).
    @Published private(set) var loadedKeysFromEnv = false

    private let defaults: UserDefaults

    private enum Keys {
        static let speechEngine = "speechEngine"
        static let formattingMode = "formattingMode"
        static let ollamaModel = "ollamaModel"
        static let geminiModel = "geminiModel"
        static let openAIModel = "openAIModel"
        static let groqModel = "groqModel"
        static let whisperModel = "whisperModel"
        static let whisperVocabularyBias = "whisperVocabularyBias"
        static let temperature = "temperature"
        static let ollamaTimeout = "ollamaTimeout"
        static let theme = "theme"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.configuration = Self.load(from: defaults)
        bootstrapAPIKeys()
    }

    /// Reloads `.env` and refreshes in-memory key fields (does not wipe Keychain overrides).
    func reloadEnvironment() {
        EnvLoader.reload()
        bootstrapAPIKeys()
        AppLogger.configuration.info("Environment reloaded")
    }

    func saveAPIKeysFromUI() {
        saveKey(geminiAPIKey, for: .geminiAPIKey, label: "Gemini")
        saveKey(openAIAPIKey, for: .openAIAPIKey, label: "OpenAI")
        saveKey(groqAPIKey, for: .groqAPIKey, label: "Groq")
    }

    func resolvedGeminiKey() -> String? {
        resolvedKey(ui: geminiAPIKey, keychain: .geminiAPIKey, env: EnvLoader.current.geminiAPIKey)
    }

    func resolvedOpenAIKey() -> String? {
        resolvedKey(ui: openAIAPIKey, keychain: .openAIAPIKey, env: EnvLoader.current.openAIAPIKey)
    }

    func resolvedGroqKey() -> String? {
        resolvedKey(ui: groqAPIKey, keychain: .groqAPIKey, env: EnvLoader.current.groqAPIKey)
    }

    // MARK: - Private

    private func bootstrapAPIKeys() {
        let env = EnvLoader.current
        loadedKeysFromEnv = env.hasAnyKey

        // Seed Keychain once from .env when empty (so keys survive without keeping the file).
        if let envKey = env.geminiAPIKey, !envKey.isEmpty,
           ((try? KeychainStore.load(.geminiAPIKey)) ?? nil) == nil {
            try? KeychainStore.save(envKey, for: .geminiAPIKey)
        }
        if let envKey = env.openAIAPIKey, !envKey.isEmpty,
           ((try? KeychainStore.load(.openAIAPIKey)) ?? nil) == nil {
            try? KeychainStore.save(envKey, for: .openAIAPIKey)
        }
        if let envKey = env.groqAPIKey, !envKey.isEmpty,
           ((try? KeychainStore.load(.groqAPIKey)) ?? nil) == nil {
            try? KeychainStore.save(envKey, for: .groqAPIKey)
        }

        geminiAPIKey = (try? KeychainStore.load(.geminiAPIKey))
            ?? env.geminiAPIKey
            ?? ""
        openAIAPIKey = (try? KeychainStore.load(.openAIAPIKey))
            ?? env.openAIAPIKey
            ?? ""
        groqAPIKey = (try? KeychainStore.load(.groqAPIKey))
            ?? env.groqAPIKey
            ?? ""
    }

    private func saveKey(_ value: String, for key: KeychainStore.Key, label: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try KeychainStore.delete(key)
            } else {
                try KeychainStore.save(trimmed, for: key)
            }
            AppLogger.configuration.info("\(label, privacy: .public) API key updated in Keychain")
        } catch {
            AppLogger.configuration.error("Keychain write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolvedKey(ui: String, keychain: KeychainStore.Key, env: String?) -> String? {
        let trimmed = ui.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let stored = try? KeychainStore.load(keychain), !stored.isEmpty { return stored }
        if let env, !env.isEmpty { return env }
        return nil
    }

    private func persist(_ config: Configuration) {
        defaults.set(config.speechEngine.rawValue, forKey: Keys.speechEngine)
        defaults.set(config.formattingMode.rawValue, forKey: Keys.formattingMode)
        defaults.set(config.ollamaModel, forKey: Keys.ollamaModel)
        defaults.set(config.geminiModel, forKey: Keys.geminiModel)
        defaults.set(config.openAIModel, forKey: Keys.openAIModel)
        defaults.set(config.groqModel, forKey: Keys.groqModel)
        defaults.set(config.whisperModel, forKey: Keys.whisperModel)
        defaults.set(config.whisperVocabularyBias, forKey: Keys.whisperVocabularyBias)
        defaults.set(config.temperature, forKey: Keys.temperature)
        defaults.set(config.ollamaTimeout, forKey: Keys.ollamaTimeout)
        defaults.set(config.theme.rawValue, forKey: Keys.theme)
    }

    private static func load(from defaults: UserDefaults) -> Configuration {
        var config = Configuration.default
        if let raw = defaults.string(forKey: Keys.speechEngine),
           let engine = SpeechEngine(rawValue: raw) {
            config.speechEngine = engine
        }
        if let raw = defaults.string(forKey: Keys.formattingMode),
           let mode = FormattingMode(rawValue: raw) {
            config.formattingMode = mode
        }
        if let model = defaults.string(forKey: Keys.ollamaModel) {
            config.ollamaModel = model
        }
        if let model = defaults.string(forKey: Keys.geminiModel) {
            config.geminiModel = model
        }
        if let model = defaults.string(forKey: Keys.openAIModel) {
            config.openAIModel = model
        }
        if let model = defaults.string(forKey: Keys.groqModel) {
            config.groqModel = model
        }
        if let model = defaults.string(forKey: Keys.whisperModel) {
            config.whisperModel = model
        }
        if let bias = defaults.string(forKey: Keys.whisperVocabularyBias) {
            config.whisperVocabularyBias = bias
        }
        if defaults.object(forKey: Keys.temperature) != nil {
            config.temperature = defaults.double(forKey: Keys.temperature)
        }
        if defaults.object(forKey: Keys.ollamaTimeout) != nil {
            config.ollamaTimeout = defaults.double(forKey: Keys.ollamaTimeout)
        }
        if let raw = defaults.string(forKey: Keys.theme),
           let theme = AppTheme(rawValue: raw) {
            config.theme = theme
        }
        return config
    }
}
