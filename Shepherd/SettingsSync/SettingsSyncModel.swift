import Foundation
import GitHubKit
import Observation
import ShepherdCore

/// Backs the "Sync across Macs (encrypted)" section of Settings → Sync (ADR 0014).
///
/// Four actions, all user-initiated: save the credentials, check what is in the bucket, upload,
/// download. There is no timer and no background task anywhere in this file, and that is the v1
/// decision rather than an omission — an automatic sync needs a conflict story, and this one
/// deliberately does not have one yet.
///
/// The passphrase lives in ``passphraseField`` and, when the user opted in, in the Keychain. It
/// is never written to `UserDefaults`, never put in a log, never uploaded, and never included in
/// the document it protects.
@MainActor
@Observable
final class SettingsSyncModel {
    /// A decrypted document waiting for the user to confirm that it may overwrite this Mac.
    ///
    /// The download is split in two — fetch-and-decrypt, then apply — precisely so that the
    /// confirmation dialog can name what is about to happen (which Mac wrote it, when, how many
    /// secrets it carries) instead of asking the user to approve an unopened box.
    struct PendingDownload: Equatable {
        /// The document that will be applied.
        var document: SyncedSettingsDocument
        /// Which Mac sealed it.
        var deviceName: String
        /// When it was sealed.
        var createdAt: Date

        /// How many secrets it will write.
        var secretCount: Int { document.secrets.count }
    }

    /// The access key id in the editor.
    var accessKeyIDField = ""
    /// The secret access key in the editor.
    var secretAccessKeyField = ""
    /// The passphrase in the editor. Never persisted from here except through the checkbox.
    var passphraseField = ""

    /// Whether the Keychain holds a complete access key pair.
    private(set) var hasStoredCredentials = false
    /// Whether the Keychain holds a passphrase.
    private(set) var hasStoredPassphrase = false
    /// The last action's result.
    private(set) var state: AsyncActionState = .idle
    /// What the last "Check remote" found, or `nil` when nothing has been checked.
    private(set) var remote: S3ObjectClient.RemoteState?
    /// Whether the last check found no object at all.
    private(set) var remoteIsEmpty = false
    /// The download awaiting confirmation.
    var pendingDownload: PendingDownload?

    /// Creates the model.
    init() {}

    // MARK: - Credentials and passphrase

    /// Loads the stored credentials and passphrase into the editors.
    /// - Parameter context: The app surfaces to read from.
    func load(context: SettingsSyncContext) {
        let keyID = context.storedSecret(KeychainSecretStore.Key.settingsSyncAccessKeyID)
        let secret = context.storedSecret(KeychainSecretStore.Key.settingsSyncSecretAccessKey)
        accessKeyIDField = keyID
        secretAccessKeyField = secret
        hasStoredCredentials = !keyID.isEmpty && !secret.isEmpty
        let stored = context.storedSecret(KeychainSecretStore.Key.settingsSyncPassphrase)
        hasStoredPassphrase = !stored.isEmpty
        if context.settings.settingsSyncRemembersPassphrase, !stored.isEmpty {
            passphraseField = stored
        }
    }

    /// Writes the editors' access key pair to the Keychain.
    /// - Parameter context: The app surfaces to write to.
    /// - Returns: An error message on failure.
    @discardableResult
    func saveCredentials(context: SettingsSyncContext) -> String? {
        do {
            try context.secrets.setSecret(
                accessKeyIDField,
                for: KeychainSecretStore.Key.settingsSyncAccessKeyID
            )
            try context.secrets.setSecret(
                secretAccessKeyField,
                for: KeychainSecretStore.Key.settingsSyncSecretAccessKey
            )
            hasStoredCredentials = !accessKeyIDField.isEmpty && !secretAccessKeyField.isEmpty
            return nil
        } catch {
            return SettingsSyncModel.message(for: error)
        }
    }

    /// Stores or forgets the passphrase according to the checkbox.
    ///
    /// Called both when the checkbox changes and after a successful upload or download, so
    /// "remember" means "remember the one that actually worked" rather than "remember whatever
    /// is in the field".
    /// - Parameter context: The app surfaces to write to.
    func savePassphrase(context: SettingsSyncContext) {
        let key = KeychainSecretStore.Key.settingsSyncPassphrase
        if context.settings.settingsSyncRemembersPassphrase {
            try? context.secrets.setSecret(passphraseField, for: key)
            hasStoredPassphrase = !passphraseField.isEmpty
        } else {
            try? context.secrets.setSecret(nil, for: key)
            hasStoredPassphrase = false
        }
    }

    // MARK: - Actions

    /// Asks the bucket whether an object is there and when it changed.
    /// - Parameter context: The app surfaces to use.
    func checkRemote(context: SettingsSyncContext) async {
        state = .running
        do {
            let client = try context.client()
            let found = try await client.head()
            remote = found
            remoteIsEmpty = found == nil
            if let found {
                state = .success(SettingsSyncModel.remoteSummary(found))
            } else {
                state = .success(String(localized: "No settings in this bucket yet."))
            }
        } catch {
            remote = nil
            remoteIsEmpty = false
            state = .failure(SettingsSyncModel.message(for: error))
        }
    }

    /// Captures this Mac's settings, seals them and uploads them.
    /// - Parameter context: The app surfaces to use.
    func upload(context: SettingsSyncContext) async {
        state = .running
        do {
            let client = try context.client()
            let document = await SettingsSyncApplier.capture(context: context)
            let envelope = try await SettingsSyncModel.seal(
                document,
                passphrase: passphraseField,
                deviceName: context.deviceName,
                createdAt: context.now()
            )
            let body = try envelope.json()
            try await client.put(body)
            context.settings.settingsSyncLastUploadAt = context.now()
            savePassphrase(context: context)
            remote = S3ObjectClient.RemoteState(
                lastModified: context.now(),
                byteCount: nil
            )
            remoteIsEmpty = false
            let count = document.secrets.count
            state = .success(String(
                localized: "Uploaded. The bucket now holds your settings and \(count) secrets, encrypted."
            ))
        } catch {
            state = .failure(SettingsSyncModel.message(for: error))
        }
    }

    /// Downloads and decrypts, then stops and asks.
    ///
    /// Nothing local has changed when this returns successfully — ``pendingDownload`` is set and
    /// the view raises its confirmation.
    /// - Parameter context: The app surfaces to use.
    func prepareDownload(context: SettingsSyncContext) async {
        state = .running
        do {
            let client = try context.client()
            let (body, _) = try await client.get()
            let envelope = try SettingsEnvelope.parse(body)
            let document = try await SettingsSyncModel.open(envelope, passphrase: passphraseField)
            pendingDownload = PendingDownload(
                document: document,
                deviceName: envelope.deviceName,
                createdAt: envelope.createdAt
            )
            state = .idle
        } catch {
            pendingDownload = nil
            state = .failure(SettingsSyncModel.message(for: error))
        }
    }

    /// Applies the download the user just confirmed.
    /// - Parameter context: The app surfaces to use.
    /// - Returns: What was applied, so the caller can refresh the parts of the app that cache
    ///   settings (appearance, the intelligence router).
    @discardableResult
    func confirmDownload(context: SettingsSyncContext) async -> SettingsSyncApplier.Outcome? {
        guard let pending = pendingDownload else { return nil }
        pendingDownload = nil
        state = .running
        let outcome = await SettingsSyncApplier.apply(pending.document, context: context)
        context.settings.settingsSyncLastDownloadAt = context.now()
        savePassphrase(context: context)
        state = .success(SettingsSyncModel.appliedSummary(outcome, from: pending))
        return outcome
    }

    /// Drops a prepared download without applying it.
    func cancelDownload() {
        pendingDownload = nil
        state = .idle
    }

    // MARK: - Off the main actor

    /// ``SettingsSyncCrypto/seal(document:passphrase:deviceName:createdAt:iterations:salt:nonce:)``,
    /// run somewhere the window can keep painting.
    ///
    /// 600 000 PBKDF2 iterations (``SettingsSyncCrypto/productionIterations``) is a fraction of a
    /// second of *uninterruptible* CPU, and on the main actor that is a fraction of a second in
    /// which the app is frozen — on the very button press that is supposed to feel deliberate and
    /// safe. Everything crossing the boundary is a `Sendable` value bound before the hop, so no
    /// main-actor state is read inside the task, and the caller touches none until it returns.
    /// - Parameters:
    ///   - document: The captured settings.
    ///   - passphrase: The user's passphrase.
    ///   - deviceName: The name to stamp the envelope with.
    ///   - createdAt: The seal timestamp.
    /// - Returns: The sealed envelope.
    /// - Throws: Whatever ``SettingsSyncCrypto`` throws.
    private static func seal(
        _ document: SyncedSettingsDocument,
        passphrase: String,
        deviceName: String,
        createdAt: Date
    ) async throws -> SettingsEnvelope {
        try await Task.detached(priority: .userInitiated) {
            try SettingsSyncCrypto.seal(
                document: document,
                passphrase: passphrase,
                deviceName: deviceName,
                createdAt: createdAt
            )
        }.value
    }

    /// ``SettingsSyncCrypto/open(_:passphrase:)`` off the main actor, for the same reason as
    /// ``seal(_:passphrase:deviceName:createdAt:)``: a download pays the KDF too.
    /// - Parameters:
    ///   - envelope: The parsed envelope.
    ///   - passphrase: The user's passphrase.
    /// - Returns: The decrypted document.
    /// - Throws: Whatever ``SettingsSyncCrypto`` throws.
    private static func open(
        _ envelope: SettingsEnvelope,
        passphrase: String
    ) async throws -> SyncedSettingsDocument {
        try await Task.detached(priority: .userInitiated) {
            try SettingsSyncCrypto.open(envelope, passphrase: passphrase)
        }.value
    }

    // MARK: - Copy

    /// The one line "Check remote" produces.
    /// - Parameter remote: What the service reported.
    /// - Returns: A status line.
    static func remoteSummary(_ remote: S3ObjectClient.RemoteState) -> String {
        guard let lastModified = remote.lastModified else {
            return String(localized: "Settings found in the bucket.")
        }
        let stamp = GitHubTimestamp.string(from: lastModified)
        return String(localized: "Settings in the bucket, last changed \(stamp).")
    }

    /// The one line a finished download produces.
    ///
    /// It names the source Mac because that is the question a user actually has afterwards
    /// ("did I just overwrite my laptop with my desk Mac's settings, or the other way round?").
    /// - Parameters:
    ///   - outcome: What was applied.
    ///   - pending: What was applied *from*.
    /// - Returns: A status line.
    static func appliedSummary(
        _ outcome: SettingsSyncApplier.Outcome,
        from pending: PendingDownload
    ) -> String {
        var line = String(localized: "Applied the settings written by \(pending.deviceName), including \(outcome.secretsWritten) secrets.")
        if outcome.needsSignInRestart {
            line += " " + String(localized: "The GitHub token changed for another account — sign out and sign in again to use it.")
        }
        if outcome.skippedAgentRegistry {
            line += " " + String(localized: "Agent-registry entries were left alone because no account is signed in.")
        }
        return line
    }

    /// The user-facing text of an error, whatever kind it is.
    static func message(for error: any Error) -> String {
        error.userFacingDescription
    }
}
