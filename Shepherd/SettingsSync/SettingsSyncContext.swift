import Foundation
import GitHubKit
import ShepherdCore

/// The Keychain seam settings sync reads and writes secrets through.
///
/// ``KeychainSecretStore`` already has exactly this shape, so the production conformance is
/// empty; the point is that the tests can drive the capture-and-apply logic with an in-memory
/// dictionary instead of prompting for Keychain access on a CI machine — the same seam idea as
/// ``WebhookPosting`` and ``AgentRunning``.
protocol SettingsSecretStoring: Sendable {
    /// Reads a secret.
    /// - Parameter key: The secret's key.
    /// - Returns: The stored string, or `nil` when nothing is stored.
    func secret(for key: String) throws -> String?

    /// Stores (or clears) a secret.
    /// - Parameters:
    ///   - value: The secret, or `nil`/empty to delete it.
    ///   - key: The secret's key.
    func setSecret(_ value: String?, for key: String) throws
}

extension KeychainSecretStore: SettingsSecretStoring {}

/// Everything settings sync needs from the rest of the app, gathered into one value.
///
/// The feature reaches into four different places — `UserDefaults`, the Keychain's secret items,
/// the Keychain's GitHub credential, and the local database's agent-registry table — and it must
/// be drivable in tests without any of them being real. Rather than threading four parameters
/// through every method, the model takes this.
///
/// The agent-registry closures are optional on purpose: registry extensions live in the local
/// database, which only exists while an account is signed in (ADR 0006), so a download performed
/// while signed out simply reports that it left them alone.
struct SettingsSyncContext {
    /// The preference store.
    var settings: AppSettings
    /// Where the API keys, webhook secret and bucket credentials live.
    var secrets: any SettingsSecretStoring
    /// Where the GitHub credential lives (ADR 0004).
    var tokens: any TokenStore
    /// Which account is signed in right now, if any.
    var signedInLogin: String?
    /// Reads the user's agent-registry extensions, when a database is available.
    ///
    /// `@Sendable` and capturing nothing but the `DatabaseManager` (which is itself `Sendable`),
    /// so the closure can be awaited without dragging the main actor along.
    var readAgentOverrides: (@Sendable () async -> [AgentRegistryEntry])?
    /// Replaces the user's agent-registry extensions, when a database is available.
    var writeAgentOverrides: (@Sendable ([AgentRegistryEntry]) async -> Void)?
    /// The S3 transport; tests pass a recorder.
    var transport: any S3Transporting
    /// Clock injection point.
    var now: @Sendable () -> Date
    /// The name that goes into the envelope.
    var deviceName: String

    /// Creates a context.
    init(
        settings: AppSettings,
        secrets: any SettingsSecretStoring,
        tokens: any TokenStore,
        signedInLogin: String? = nil,
        readAgentOverrides: (@Sendable () async -> [AgentRegistryEntry])? = nil,
        writeAgentOverrides: (@Sendable ([AgentRegistryEntry]) async -> Void)? = nil,
        transport: any S3Transporting = URLSessionS3Transport.shared,
        now: @escaping @Sendable () -> Date = { Date() },
        deviceName: String = SettingsSyncCrypto.currentDeviceName
    ) {
        self.settings = settings
        self.secrets = secrets
        self.tokens = tokens
        self.signedInLogin = signedInLogin
        self.readAgentOverrides = readAgentOverrides
        self.writeAgentOverrides = writeAgentOverrides
        self.transport = transport
        self.now = now
        self.deviceName = deviceName
    }

    /// The bucket credentials, read from the Keychain.
    var credentials: SigV4Signer.Credentials {
        SigV4Signer.Credentials(
            accessKeyID: storedSecret(KeychainSecretStore.Key.settingsSyncAccessKeyID),
            secretAccessKey: storedSecret(KeychainSecretStore.Key.settingsSyncSecretAccessKey)
        )
    }

    /// Builds the client for the configured bucket.
    ///
    /// Main-actor-isolated because it reads ``AppSettings``, which is; the client it returns is a
    /// `Sendable` value that can then be used from anywhere.
    /// - Returns: A client for the one settings object.
    /// - Throws: ``SettingsSyncError`` when the configuration or the credentials are incomplete.
    @MainActor
    func client() throws -> S3ObjectClient {
        // Defence in depth rather than trust in the UI: with the toggle off there is no way to
        // build a request at all, which is what makes ``AppSettings/settingsSyncEnabled`` a real
        // gate and not just a way of hiding fields.
        guard settings.settingsSyncEnabled else { throw SettingsSyncError.notConfigured }
        let location = try S3ObjectLocation.resolve(
            endpointText: settings.settingsSyncEndpoint,
            bucket: settings.settingsSyncBucket,
            region: settings.settingsSyncRegion,
            prefix: settings.settingsSyncKeyPrefix,
            addressing: settings.settingsSyncAddressing
        )
        let pair = credentials
        guard pair.isComplete else { throw SettingsSyncError.credentialsMissing }
        return S3ObjectClient(
            location: location,
            credentials: pair,
            transport: transport,
            now: now
        )
    }

    /// Reads a secret, treating a Keychain error as "not there".
    ///
    /// Deliberate: a Keychain read that fails must not stop a user from *typing* their key into
    /// the field and trying again, and there is no useful distinction to draw here between
    /// "empty" and "unreadable".
    /// - Parameter key: The secret's key.
    /// - Returns: The stored string, or an empty one.
    func storedSecret(_ key: String) -> String {
        ((try? secrets.secret(for: key)) ?? nil) ?? ""
    }
}
