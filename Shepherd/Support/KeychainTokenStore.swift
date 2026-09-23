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
    private let storage: any KeychainStoring

    /// Creates a store.
    /// - Parameters:
    ///   - service: The Keychain service name.
    ///   - storage: Where the items are kept. The system Keychain everywhere except the Debug
    ///     demo mode, which must never read or write the developer's real token.
    init(
        service: String = AppConfig.githubKeychainService,
        storage: any KeychainStoring = SystemKeychain()
    ) {
        self.service = service
        self.storage = storage
    }

    func token(for login: String) async throws -> TokenSet? {
        guard let data = try storage.readData(service: service, account: login) else { return nil }
        do {
            return try JSONDecoder().decode(TokenSet.self, from: data)
        } catch {
            throw KeychainError.malformedItem
        }
    }

    func setToken(_ token: TokenSet, for login: String) async throws {
        let data = try JSONEncoder().encode(token)
        try storage.writeData(data, service: service, account: login)
    }

    func deleteToken(for login: String) async throws {
        try storage.delete(service: service, account: login)
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
        /// The shared secret webhook bodies are signed with (ADR 0012).
        static let webhookSecret = "automation.webhook.secret"
        /// The access key id of the settings-sync bucket (ADR 0014).
        static let settingsSyncAccessKeyID = "settingsSync.accessKeyId"
        /// The secret access key of the settings-sync bucket (ADR 0014).
        static let settingsSyncSecretAccessKey = "settingsSync.secretAccessKey"
        /// The sync passphrase, stored **only** when the user opts in (ADR 0014).
        ///
        /// It is the one secret in this list that Shepherd would rather not hold at all: it is
        /// the key to every other secret in the bucket, so remembering it is a checkbox that is
        /// off by default and clearing the checkbox deletes the item.
        static let settingsSyncPassphrase = "settingsSync.passphrase"
    }

    private let service: String
    private let storage: any KeychainStoring

    /// Creates a store.
    /// - Parameters:
    ///   - service: The Keychain service name.
    ///   - storage: Where the items are kept — see ``KeychainTokenStore/init(service:storage:)``.
    init(
        service: String = AppConfig.secretsKeychainService,
        storage: any KeychainStoring = SystemKeychain()
    ) {
        self.service = service
        self.storage = storage
    }

    /// Reads a secret.
    /// - Parameter key: The secret's key.
    /// - Returns: The stored string, or `nil` when nothing is stored.
    func secret(for key: String) throws -> String? {
        guard let data = try storage.readData(service: service, account: key) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw KeychainError.malformedItem }
        return text
    }

    /// Stores (or clears) a secret.
    /// - Parameters:
    ///   - value: The secret, or `nil`/empty to delete it.
    ///   - key: The secret's key.
    func setSecret(_ value: String?, for key: String) throws {
        guard let value, !value.isEmpty else {
            try storage.delete(service: service, account: key)
            return
        }
        try storage.writeData(Data(value.utf8), service: service, account: key)
    }
}

/// Where the two stores above keep their items.
///
/// A seam with exactly two implementations: ``SystemKeychain`` in every build, and the Debug
/// demo mode's in-memory stand-in (`DemoKeychain`, `Shepherd/Debug/DemoFakes.swift`). The second
/// exists because a Debug build shares the installed app's bundle id *and* its Keychain services:
/// the demo must never read or overwrite the developer's real token, and an ad-hoc-signed binary
/// reading it would also put a Keychain prompt on top of the window being screenshotted.
protocol KeychainStoring: Sendable {
    /// Reads the data of a generic-password item, or `nil` when there is none.
    func readData(service: String, account: String) throws -> Data?
    /// Creates or replaces a generic-password item.
    func writeData(_ data: Data, service: String, account: String) throws
    /// Deletes a generic-password item if it exists.
    func delete(service: String, account: String) throws
}

/// The macOS Keychain, through ``Keychain``'s raw calls.
struct SystemKeychain: KeychainStoring {
    func readData(service: String, account: String) throws -> Data? {
        try Keychain.readData(service: service, account: account)
    }

    func writeData(_ data: Data, service: String, account: String) throws {
        try Keychain.writeData(data, service: service, account: account)
    }

    func delete(service: String, account: String) throws {
        try Keychain.delete(service: service, account: account)
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
