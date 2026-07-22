import Foundation
import Security

/// Thin Keychain wrapper for sensitive secrets (OpenAI / Groq API keys).
/// Values never touch UserDefaults. `.env` can seed Keychain via `ConfigurationStore`.
enum KeychainStore {
    enum Key: String {
        case openAIAPIKey = "openai_api_key"
        case groqAPIKey = "groq_api_key"
    }

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversionFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain error (\(status))"
            case .dataConversionFailed:
                return "Unable to encode or decode Keychain data"
            }
        }
    }

    private static let logger = AppLogger.keychain
    private static let service = Constants.bundleIdentifier

    static func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status: OSStatus
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else if existing == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        } else {
            throw KeychainError.unexpectedStatus(existing)
        }

        guard status == errSecSuccess else {
            logger.error("Keychain save failed: \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func load(_ key: Key) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return string
    }

    static func delete(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
