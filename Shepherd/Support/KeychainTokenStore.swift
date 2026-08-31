import Foundation
import GitHubKit
import Security

/// Errors the Keychain wrappers can produce.
enum KeychainError: LocalizedError, Equatable {
    /// The Security framework returned an unexpected status code.
    case unexpectedStatus(OSStatus)
    /// A stored item could not be decoded.
    case malformedItem

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "Keychain error: \(message)")
        case .malformedItem:
            return String(localized: "A stored Keychain item could not be read.")
        }
    }
}

/// The app-side ``GitHubKit/TokenStore``: GitHub credentials live in the macOS Keychain and
/// nowhere else (ADR 0004).
///
/// Items are `kSecClassGenericPassword` rows keyed by service + account, where the account is
/// the GitHub login, so multiple accounts can coexist even though v1 signs in one.
final class KeychainTokenStore: TokenStore, Sendable {
    private let service: String

    /// Creates a store.
    /// - Parameter service: The Keychain service name.
    init(service: String = AppConfig.githubKeychainService) {
        self.service = service
    }

    func token(for login: String) async throws -> TokenSet? {
        guard let data = try Keychain.readData(service: service, account: login) else { return nil }
        do {
            return try JSONDecoder().decode(TokenSet.self, from: data)
        } catch {
            throw KeychainError.malformedItem
        }
    }

    func setToken(_ token: TokenSet, for login: String) async throws {
        let data = try JSONEncoder().encode(token)
        try Keychain.writeData(data, service: service, account: login)
    }

    func deleteToken(for login: String) async throws {
        try Keychain.delete(service: service, account: login)
    }
}

/// A tiny string-secret store on top of the same Keychain primitives.
///
/// Used for the BYOK API keys of the intelligence layer (ADR 0007): they are secrets like the
/// GitHub token and must never reach `UserDefaults` or the database.
struct KeychainSecretStore: Sendable {
    /// Well-known secret keys.
    enum Key {
        /// The Anthropic API key.
        static let anthropicAPIKey = "intelligence.anthropic.apiKey"
        /// The API key of the user-configured OpenAI-compatible endpoint.
        static let openAICompatibleAPIKey = "intelligence.openaiCompatible.apiKey"
    }

    private let service: String

    /// Creates a store.
    /// - Parameter service: The Keychain service name.
    init(service: String = AppConfig.secretsKeychainService) {
        self.service = service
    }

    /// Reads a secret.
    /// - Parameter key: The secret's key.
    /// - Returns: The stored string, or `nil` when nothing is stored.
    func secret(for key: String) throws -> String? {
        guard let data = try Keychain.readData(service: service, account: key) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw KeychainError.malformedItem }
        return text
    }

    /// Stores (or clears) a secret.
    /// - Parameters:
    ///   - value: The secret, or `nil`/empty to delete it.
    ///   - key: The secret's key.
    func setSecret(_ value: String?, for key: String) throws {
        guard let value, !value.isEmpty else {
            try Keychain.delete(service: service, account: key)
            return
        }
        try Keychain.writeData(Data(value.utf8), service: service, account: key)
    }
}

/// The raw Security-framework calls, in one place.
enum Keychain {
    /// Reads the data of a generic-password item.
    static func readData(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.malformedItem }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Creates or replaces a generic-password item.
    static func writeData(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var insert = query
        for (key, value) in attributes {
            insert[key] = value
        }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Deletes a generic-password item if it exists.
    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
