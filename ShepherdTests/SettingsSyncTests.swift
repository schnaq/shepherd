import Foundation
import GitHubKit
import ShepherdCore
import XCTest

@testable import Shepherd

// MARK: - Shared fixtures

/// Cheap enough to run in every test, still a real PBKDF2 run.
///
/// Sealing twice per test at the production 600 000 iterations would add seconds to the suite for
/// no extra coverage: the iteration count is a *parameter* of the format, and both "the parameter
/// is respected" and "the production constant is high enough" are asserted on their own.
private let syncTestIterations = 1_000

/// The passphrase every fixture is sealed with. Long enough to pass the minimum-length guard.
private let syncTestPassphrase = "correct horse battery staple"

/// `2026-09-01T10:15:00Z` — the moment every sealed fixture and every signed request claims.
///
/// A file-level constant rather than a property so the `@Sendable` clock closures the object
/// client takes can capture it without capturing the test case.
private let syncTestSealedAt = Date(timeIntervalSince1970: 1_788_257_700)

/// The same moment as ``GitHubKit/GitHubTimestamp`` writes it.
private let syncTestSealedAtISO = "2026-09-01T10:15:00Z"

/// Fixed identities for the saved replies and the review template in ``fullDocument()``.
///
/// Fixed rather than freshly generated because the capture-apply-capture test compares two whole
/// documents for equality: a random `UUID()` per call would make the fixture differ from itself.
private let syncTestReplyID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let syncTestSecondReplyID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let syncTestTemplateID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

/// An in-memory ``SettingsSecretStoring``, so nothing here prompts for Keychain access.
///
/// Locked rather than an actor so the assertions read straight through, the same shape
/// `RecordingPoster` and `ScriptedAgentRunner` use.
final class InMemorySecretStore: SettingsSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    private let failingKeys: Set<String>

    /// Creates a store.
    /// - Parameters:
    ///   - initial: Secrets to seed it with.
    ///   - failingKeys: Keys whose writes throw, to exercise a partial apply.
    init(initial: [String: String] = [:], failingKeys: Set<String> = []) {
        self.storage = initial
        self.failingKeys = failingKeys
    }

    /// Everything currently stored.
    var contents: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func secret(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func setSecret(_ value: String?, for key: String) throws {
        if failingKeys.contains(key) { throw KeychainError.malformedItem }
        lock.lock()
        defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}

/// A scripted S3 transport: records what was sent, answers from a script.
///
/// The answers list is not consumed past its end — the last one repeats — so a test that wants
/// "always 403" writes it once.
final class RecordingS3Transport: S3Transporting, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [S3ObjectResponse]
    private let failure: SettingsSyncError?
    private var recorded: [S3ObjectRequest] = []

    /// Creates a transport.
    /// - Parameters:
    ///   - answers: The answers to give, in order.
    ///   - failure: When set, every request throws this instead of answering.
    init(answers: [S3ObjectResponse] = [], failure: SettingsSyncError? = nil) {
        self.answers = answers
        self.failure = failure
    }

    /// Everything that was sent, in order.
    var requests: [S3ObjectRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The body of the last `PUT`, if any.
    var lastPutBody: Data? {
        requests.last { $0.method == "PUT" }?.body
    }

    func perform(_ request: S3ObjectRequest) async throws -> S3ObjectResponse {
        let answer = lock.withLock { () -> S3ObjectResponse in
            recorded.append(request)
            if answers.isEmpty {
                return S3ObjectResponse(status: 200, headers: [:], body: Data())
            } else if answers.count > 1 {
                return answers.removeFirst()
            } else {
                return answers[0]
            }
        }
        if let failure { throw failure }
        return answer
    }
}

/// Stands in for the `agent_registry_overrides` table, which normally lives in the local
/// database and therefore only exists while an account is signed in.
actor AgentOverrideBox {
    private var entries: [AgentRegistryEntry]

    /// Creates a box.
    /// - Parameter entries: The starting contents.
    init(entries: [AgentRegistryEntry] = []) {
        self.entries = entries
    }

    /// Reads the entries.
    func read() -> [AgentRegistryEntry] { entries }

    /// Replaces the entries.
    /// - Parameter entries: The new contents.
    func write(_ entries: [AgentRegistryEntry]) { self.entries = entries }
}

// MARK: - Tests

/// End-to-end encrypted settings sync (ADR 0014): the crypto, the envelope, the document, the
/// object client and the apply path.
///
/// Nothing here touches the network or the Keychain. `AppSettings` is built over a throwaway
/// `UserDefaults` suite — it already takes one for exactly this reason — and every call to
/// ``makeSettings()`` gets a *fresh* suite, so a test that models two Macs really models two.
@MainActor
final class SettingsSyncTests: XCTestCase {
    private var createdSuites: [String] = []

    override func tearDown() {
        for name in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "com.schnaq.shepherd.tests.settingsSync.\(UUID().uuidString)"
        createdSuites.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("a fresh suite name always opens")
        }
        return defaults
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: makeDefaults())
    }

    /// A settings store with a usable bucket configuration already filled in.
    private func makeConfiguredSettings() -> AppSettings {
        let settings = makeSettings()
        settings.settingsSyncEnabled = true
        settings.settingsSyncEndpoint = "https://object.storage.eu01.onstackit.cloud"
        settings.settingsSyncBucket = "my-bucket"
        settings.settingsSyncRegion = "eu01"
        settings.settingsSyncKeyPrefix = "shepherd"
        return settings
    }

    /// A secret store that already holds a usable access key pair.
    private func makeStoreWithKeys() -> InMemorySecretStore {
        InMemorySecretStore(initial: [
            KeychainSecretStore.Key.settingsSyncAccessKeyID: "SHEPHERDEXAMPLEKEYID",
            KeychainSecretStore.Key.settingsSyncSecretAccessKey: "shepherdExampleSecret",
        ])
    }

    /// A document with something non-default in every group, so a field that is captured but
    /// never applied (or the reverse) cannot hide behind a default that happens to match.
    private func fullDocument() -> SyncedSettingsDocument {
        var document = SyncedSettingsDocument()
        document.sync = SyncedSettingsDocument.SyncGroup(sweepIntervalMinutes: 7)
        document.notifications = SyncedSettingsDocument.NotificationGroup(
            onReviewRequest: false,
            onChecksFailed: true,
            onDraftConflict: false
        )
        // Non-default in every field, and for the digest "non-default" means switched *on*: the
        // schedule ships off, at nine, weekdays only.
        document.digest = SyncedSettingsDocument.DigestGroup(
            schedule: DigestSchedule(
                isEnabled: true,
                hour: 6,
                minute: 45,
                weekdaysOnly: false
            )
        )
        document.agents = SyncedSettingsDocument.AgentsGroup(registryOverrides: [
            AgentRegistryEntry(
                id: "my-agent",
                displayName: "My Agent",
                loginPatterns: ["my-agent[bot]"],
                branchPrefixes: ["my-agent/"],
                commitTrailers: ["Co-Authored-By: My Agent"]
            ),
        ])
        document.intelligence = SyncedSettingsDocument.IntelligenceGroup(
            mode: .onDeviceAndCloud,
            cloudProviderKind: .openAICompatible,
            anthropicModel: "some-model",
            openAICompatibleBaseURL: "https://api.example.eu/v1",
            openAICompatibleModel: "some-open-model",
            // Non-default means *set* here: the policy ships empty and off, and an empty policy
            // is never put on the wire (plan §3.K).
            openAICompatibleSovereigntyCountries: ["DE", "FR"],
            openAICompatibleZeroRetention: true,
            // Non-default means *off* here: structured triage ships on, because it is on-device
            // and costs nothing but CPU (plan §0.5).
            structuredTriageEnabled: false
        )
        var cli = AgentCLIConfiguration()
        cli.kind = .custom(commandTemplate: "/usr/local/bin/my-agent --task {prompt}")
        cli.maxTurns = 42
        cli.maxBudgetUSD = nil
        cli.permissionMode = .plan
        // The session back-channel's two commands travel with the rest of the invocation
        // (ADR 0030). Non-default in both directions here: the local one replaced, and the
        // remote one *set*, which is the field that ships empty.
        cli.sessionResumeTemplate = "/usr/local/bin/my-agent resume {sessionID} {message}"
        cli.remoteSessionTemplate = "/usr/local/bin/my-agent remote {sessionURL} {message}"
        document.delegation = SyncedSettingsDocument.DelegationGroup(
            agentCLI: cli,
            localCheckouts: ["schnaq/review": "/Users/someone/code/review"],
            autoDelegation: AutoDelegationRules(
                isEnabled: true,
                triggers: [.checksFailed, .changesRequested],
                promptTemplate: "fix #{number}",
                maxConcurrent: 2,
                maxPerDay: 9
            )
        )
        document.automation = SyncedSettingsDocument.AutomationGroup(
            webhooksEnabled: true,
            webhookURL: "https://n8n.example.com/webhook/shepherd",
            webhookEvents: ["pr.merged", "review.submitted"]
        )
        // The rules travel; the ledger that is also the audit log does not (ADR 0018).
        document.autoMerge = SyncedSettingsDocument.AutoMergeGroup(
            rules: AutoMergeRules(
                isEnabled: true,
                allowedRepositories: ["schnaq/*"],
                requiredLabels: ["automerge"]
            )
        )
        // Non-default in both thresholds, and deliberately in opposite directions: a wider file
        // ceiling with a narrower line ceiling proves the two travel independently rather than as
        // one "small" knob (ADR 0027).
        document.trust = SyncedSettingsDocument.TrustGroup(
            laneConfiguration: TrustLaneConfiguration(maxFiles: 9, maxChangedLines: 60)
        )
        // Non-default means *off* here: the index ships on, because it is on-device and costs
        // nothing but CPU (ADR 0019).
        document.search = SyncedSettingsDocument.SearchGroup(
            isSemanticIndexEnabled: false,
            isSpotlightExportEnabled: false
        )
        document.appearance = SyncedSettingsDocument.AppearanceGroup(
            appearance: .dark,
            inboxGroupBy: .repository,
            inboxSortOrder: .oldestFirst,
            diffFontSize: 16,
            diffWrapsLines: true,
            diffUsesInlineMode: true,
            diffRenderer: .native,
            // Non-default like every other field here, and non-default for this one means *off*:
            // the menu-bar item ships inserted.
            showsMenuBarExtra: false,
            // And the same again: an agent's pull request opens on Conversation out of the box,
            // so the non-default value of the reviewer who wants the diff first is *off*.
            opensAgentPullRequestsOnConversation: false
        )
        document.triage = SyncedSettingsDocument.TriageGroup(
            defaultMergeMethod: .rebase,
            // Non-default means *on* here: branch deletion ships off, because it is the
            // irreversible half of the one action Shepherd cannot undo (ADR 0005's 2026-09-05
            // amendment).
            deletesBranchAfterMerge: true
        )
        document.composer = SyncedSettingsDocument.ComposerGroup(
            savedReplies: [
                SavedReply(id: syncTestReplyID, name: "Needs a test", body: "Please add a test."),
                SavedReply(id: syncTestSecondReplyID, name: "Nit", body: "Naming nit."),
            ],
            reviewTemplates: [
                ReviewTemplate(
                    id: syncTestTemplateID,
                    pattern: "schnaq/*",
                    body: "## Checklist\n- [ ] tests"
                ),
            ]
        )
        document.diagnostics = SyncedSettingsDocument.DiagnosticsGroup(isEnabled: true)
        document.account = SyncedSettingsDocument.AccountGroup(login: "octocat", authKind: .pat)
        document.secrets = SyncedSettingsDocument.Secrets(
            githubToken: "ghp_example",
            anthropicKey: "sk-ant-example",
            openAICompatibleKey: "sk-example",
            webhookSecret: "hunter2hunter2"
        )
        return document
    }

    /// Seals with a fixed salt and nonce, so the ciphertext is a pure function of the inputs.
    private func seal(
        _ document: SyncedSettingsDocument,
        passphrase: String? = nil,
        iterations: Int? = nil
    ) throws -> SettingsEnvelope {
        try SettingsSyncCrypto.seal(
            document: document,
            passphrase: passphrase ?? syncTestPassphrase,
            deviceName: "Test Mac",
            createdAt: syncTestSealedAt,
            iterations: iterations ?? syncTestIterations,
            salt: Data(repeating: 0xAB, count: SettingsSyncCrypto.saltByteCount),
            nonce: Data(repeating: 0xCD, count: SettingsSyncCrypto.nonceByteCount)
        )
    }

    // MARK: - Envelope round trip

    func testAnEnvelopeRoundTripsThroughJSONAndBackToTheSameDocument() throws {
        let original = fullDocument()
        let envelope = try seal(original)
        let json = try envelope.json()
        let parsed = try SettingsEnvelope.parse(json)
        XCTAssertEqual(parsed, envelope)
        let reopened = try SettingsSyncCrypto.open(parsed, passphrase: syncTestPassphrase)
        XCTAssertEqual(reopened, original)
    }

    func testTheEnvelopeDescribesItsOwnParametersInTheClear() throws {
        let envelope = try seal(fullDocument())
        let json = try envelope.json()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(root["v"] as? Int, 1)
        XCTAssertEqual(root["deviceName"] as? String, "Test Mac")
        XCTAssertEqual(root["createdAt"] as? String, syncTestSealedAtISO)
        let kdf = try XCTUnwrap(root["kdf"] as? [String: Any])
        XCTAssertEqual(kdf["algo"] as? String, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(kdf["iterations"] as? Int, syncTestIterations)
        let cipher = try XCTUnwrap(root["cipher"] as? [String: Any])
        XCTAssertEqual(cipher["algo"] as? String, "AES-256-GCM")
        let nonceText = try XCTUnwrap(cipher["nonce"] as? String)
        XCTAssertEqual(
            Data(base64Encoded: nonceText)?.count,
            SettingsSyncCrypto.nonceByteCount
        )
    }

    /// The one property the whole feature rests on: nothing recognisable from the plaintext is in
    /// the object. Checked against the actual secrets, because a mistake here would be a leak
    /// rather than a bug.
    func testNoSecretAppearsAnywhereInTheUploadedBytes() throws {
        let json = try seal(fullDocument()).json()
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        for secret in [
            "ghp_example", "sk-ant-example", "sk-example", "hunter2hunter2",
            syncTestPassphrase,
            "n8n.example.com", "api.example.eu", "octocat",
            // Saved replies and templates are the user's own words about their colleagues' code.
            // Not a credential, but nothing the bucket operator gets to read either.
            "Please add a test.", "Naming nit.", "## Checklist",
        ] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into the envelope")
        }
    }

    func testTwoUploadsOfTheSameDocumentUseDifferentSaltsAndNonces() throws {
        let document = fullDocument()
        let first = try SettingsSyncCrypto.seal(
            document: document,
            passphrase: syncTestPassphrase,
            deviceName: "Test Mac",
            createdAt: syncTestSealedAt,
            iterations: syncTestIterations
        )
        let second = try SettingsSyncCrypto.seal(
            document: document,
            passphrase: syncTestPassphrase,
            deviceName: "Test Mac",
            createdAt: syncTestSealedAt,
            iterations: syncTestIterations
        )
        XCTAssertNotEqual(first.kdf.salt, second.kdf.salt)
        XCTAssertNotEqual(first.cipher.nonce, second.cipher.nonce)
        XCTAssertNotEqual(first.payload, second.payload)
        XCTAssertEqual(first.kdf.salt.count, SettingsSyncCrypto.saltByteCount)
        XCTAssertEqual(first.cipher.nonce.count, SettingsSyncCrypto.nonceByteCount)
    }

    // MARK: - The failure modes that must be exact

    func testAWrongPassphraseIsReportedAsSuchAndYieldsNoPlaintext() throws {
        let envelope = try seal(fullDocument())
        XCTAssertThrowsError(
            try SettingsSyncCrypto.open(envelope, passphrase: "not the passphrase")
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .wrongPassphraseOrCorruptedData)
        }
    }

    func testAnEmptyPassphraseIsRefusedBeforeAnyKeyDerivation() throws {
        let envelope = try seal(fullDocument())
        XCTAssertThrowsError(try SettingsSyncCrypto.open(envelope, passphrase: "   ")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .passphraseMissing)
        }
        let document = fullDocument()
        XCTAssertThrowsError(
            try SettingsSyncCrypto.seal(
                document: document,
                passphrase: "",
                deviceName: "Test Mac",
                createdAt: syncTestSealedAt,
                iterations: syncTestIterations
            )
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .passphraseMissing)
        }
    }

    func testAShortPassphraseIsRefusedOnUpload() {
        XCTAssertThrowsError(try seal(fullDocument(), passphrase: "short")) { error in
            XCTAssertEqual(
                error as? SettingsSyncError,
                .passphraseTooShort(minimum: SettingsSyncCrypto.minimumPassphraseLength)
            )
        }
    }

    func testASurroundingSpaceInThePassphraseDoesNotBreakARoundTrip() throws {
        let envelope = try seal(fullDocument(), passphrase: "  \(syncTestPassphrase)  ")
        XCTAssertNoThrow(try SettingsSyncCrypto.open(envelope, passphrase: syncTestPassphrase))
    }

    func testFlippingOneCiphertextByteBreaksDecryption() throws {
        var envelope = try seal(fullDocument())
        var payload = Array(envelope.payload)
        payload[0] ^= 0x01
        envelope.payload = Data(payload)
        XCTAssertThrowsError(
            try SettingsSyncCrypto.open(envelope, passphrase: syncTestPassphrase)
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .wrongPassphraseOrCorruptedData)
        }
    }

    /// Every field the envelope authenticates, one at a time. This is what the AAD buys: an
    /// attacker with write access to the bucket cannot lower the key-derivation cost, swap the
    /// salt, or relabel which Mac wrote the object without the tag failing.
    func testEditingAnyAuthenticatedMetadataFieldBreaksDecryption() throws {
        let sealed = try seal(fullDocument())

        var loweredCost = sealed
        loweredCost.kdf.iterations = 1
        var swappedSalt = sealed
        swappedSalt.kdf.salt = Data(repeating: 0x00, count: SettingsSyncCrypto.saltByteCount)
        var relabelled = sealed
        relabelled.deviceName = "Someone Else's Mac"
        var backdated = sealed
        backdated.createdAt = Date(timeIntervalSince1970: 0)
        var renamedCipher = sealed
        renamedCipher.cipher.algorithm = "AES-128-GCM"
        var movedNonce = sealed
        movedNonce.cipher.nonce = Data(repeating: 0x01, count: SettingsSyncCrypto.nonceByteCount)

        for tampered in [
            loweredCost, swappedSalt, relabelled, backdated, renamedCipher, movedNonce,
        ] {
            XCTAssertThrowsError(
                try SettingsSyncCrypto.open(tampered, passphrase: syncTestPassphrase)
            ) { error in
                XCTAssertEqual(error as? SettingsSyncError, .wrongPassphraseOrCorruptedData)
            }
        }
    }

    func testTheAuthenticatedDataIsTheDocumentedByteString() throws {
        let envelope = try seal(fullDocument())
        let salt = Data(repeating: 0xAB, count: SettingsSyncCrypto.saltByteCount)
        let expected = [
            "shepherd.settings-sync/1",
            "v=1",
            "kdf=PBKDF2-HMAC-SHA256",
            "iterations=\(syncTestIterations)",
            "salt=\(salt.base64EncodedString())",
            "cipher=AES-256-GCM",
            "createdAt=\(syncTestSealedAtISO)",
            "deviceName=Test Mac",
        ].joined(separator: "\n")
        XCTAssertEqual(String(data: envelope.authenticatedData, encoding: .utf8), expected)
    }

    // MARK: - Key-derivation parameters

    func testTheIterationCountInTheEnvelopeIsWhatIsActuallyUsed() throws {
        let cheap = try seal(fullDocument(), iterations: 1_000)
        let dearer = try seal(fullDocument(), iterations: 2_000)
        // Same salt, same nonce, same plaintext, different cost — so a different key and
        // therefore a different ciphertext. If the parameter were ignored these would match.
        XCTAssertNotEqual(cheap.payload, dearer.payload)
        XCTAssertEqual(cheap.kdf.iterations, 1_000)
        XCTAssertEqual(dearer.kdf.iterations, 2_000)
    }

    func testKeyDerivationIsDeterministicForTheSameInputs() throws {
        let salt = Data(repeating: 0x11, count: 32)
        let first = try SettingsSyncCrypto.derivedKey(
            passphrase: syncTestPassphrase,
            salt: salt,
            iterations: syncTestIterations
        )
        let second = try SettingsSyncCrypto.derivedKey(
            passphrase: syncTestPassphrase,
            salt: salt,
            iterations: syncTestIterations
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.bitCount, SettingsSyncCrypto.keyByteCount * 8)

        let otherSalt = try SettingsSyncCrypto.derivedKey(
            passphrase: syncTestPassphrase,
            salt: Data(repeating: 0x22, count: 32),
            iterations: syncTestIterations
        )
        XCTAssertNotEqual(first, otherSalt)

        let otherPassphrase = try SettingsSyncCrypto.derivedKey(
            passphrase: syncTestPassphrase + "!",
            salt: salt,
            iterations: syncTestIterations
        )
        XCTAssertNotEqual(first, otherPassphrase)
    }

    /// The production cost is a constant rather than something a test may lower, so it gets its
    /// own assertion — the whole point of a password KDF is the number.
    func testTheProductionParametersMeetTheDocumentedFloors() {
        XCTAssertGreaterThanOrEqual(SettingsSyncCrypto.productionIterations, 600_000)
        XCTAssertEqual(SettingsSyncCrypto.saltByteCount, 32)
        XCTAssertEqual(SettingsSyncCrypto.nonceByteCount, 12)
        XCTAssertEqual(SettingsSyncCrypto.keyByteCount, 32)
        XCTAssertEqual(SettingsSyncCrypto.tagByteCount, 16)
        XCTAssertTrue(
            SettingsSyncCrypto.acceptedIterations.contains(
                SettingsSyncCrypto.productionIterations
            )
        )
    }

    func testAnAbsurdIterationCountIsRefusedRatherThanAttempted() {
        XCTAssertThrowsError(
            try SettingsSyncCrypto.derivedKey(
                passphrase: syncTestPassphrase,
                salt: Data(repeating: 0x11, count: 32),
                iterations: 2_000_000_000
            )
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .iterationsOutOfRange(2_000_000_000))
        }
    }

    // MARK: - Envelope parsing is strict

    func testANewerEnvelopeVersionIsRefusedWithAnActionableError() throws {
        var root = try envelopeObject()
        root["v"] = 2
        let data = try json(root)
        XCTAssertThrowsError(try SettingsEnvelope.parse(data)) { error in
            XCTAssertEqual(error as? SettingsSyncError, .unsupportedEnvelopeVersion(2))
        }
    }

    func testAnUnknownAlgorithmIsRefusedByName() throws {
        var root = try envelopeObject()
        var kdf = try XCTUnwrap(root["kdf"] as? [String: Any])
        kdf["algo"] = "scrypt"
        root["kdf"] = kdf
        let data = try json(root)
        XCTAssertThrowsError(try SettingsEnvelope.parse(data)) { error in
            XCTAssertEqual(error as? SettingsSyncError, .unsupportedAlgorithm("scrypt"))
        }
    }

    func testAnIterationCountFromAHostileBucketIsRefusedAtParseTime() throws {
        var root = try envelopeObject()
        var kdf = try XCTUnwrap(root["kdf"] as? [String: Any])
        kdf["iterations"] = 2_000_000_000
        root["kdf"] = kdf
        let data = try json(root)
        XCTAssertThrowsError(try SettingsEnvelope.parse(data)) { error in
            XCTAssertEqual(error as? SettingsSyncError, .iterationsOutOfRange(2_000_000_000))
        }
    }

    func testAnEnvelopeMissingAFieldOrWithABadLengthIsMalformed() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["payload"] = nil },
            { $0["deviceName"] = nil },
            { $0["kdf"] = nil },
            { $0["createdAt"] = "not a timestamp" },
            { $0["payload"] = "!!! not base64 !!!" },
            { root in
                var cipher = root["cipher"] as? [String: Any] ?? [:]
                cipher["nonce"] = Data(repeating: 0, count: 8).base64EncodedString()
                root["cipher"] = cipher
            },
            { root in
                // A payload that is nothing but a tag cannot be a document.
                root["payload"] = Data(repeating: 0, count: SettingsSyncCrypto.tagByteCount)
                    .base64EncodedString()
            },
        ]
        for mutate in mutations {
            var root = try envelopeObject()
            mutate(&root)
            let data = try json(root)
            XCTAssertThrowsError(try SettingsEnvelope.parse(data)) { error in
                XCTAssertEqual(error as? SettingsSyncError, .malformedEnvelope)
            }
        }
    }

    func testGarbageIsNotAnEnvelope() {
        for body in ["", "<html>404</html>", "[]", "{}"] {
            XCTAssertThrowsError(try SettingsEnvelope.parse(Data(body.utf8))) { error in
                XCTAssertEqual(error as? SettingsSyncError, .malformedEnvelope)
            }
        }
    }

    private func envelopeObject() throws -> [String: Any] {
        let data = try seal(fullDocument()).json()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Document codec

    func testEveryFieldSurvivesTheDocumentCodec() throws {
        let original = fullDocument()
        let bytes = try original.canonicalJSON()
        let decoded = try SyncedSettingsDocument.decode(from: bytes)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownFieldsAreIgnoredAndMissingOnesFallBackToDefaults() throws {
        // A document from a newer Shepherd: an unknown top-level group, an unknown field inside a
        // known group, and an unknown enum case. None of it may cost us the rest.
        let json = """
            {
              "v": 1,
              "sync": {"sweepIntervalMinutes": 9, "somethingNew": true},
              "appearance": {"appearance": "solarized", "diffFontSize": 15},
              "quantumSettings": {"entangled": true},
              "secrets": {"webhookSecret": "s3cr3tsecret", "futureKey": "x"}
            }
            """
        let document = try SyncedSettingsDocument.decode(from: Data(json.utf8))
        XCTAssertEqual(document.sync.sweepIntervalMinutes, 9)
        XCTAssertEqual(document.appearance.diffFontSize, 15)
        // An unknown appearance raw value falls back rather than failing the document.
        XCTAssertEqual(document.appearance.appearance, .system)
        // A document written before the menu-bar item existed must leave it *on*: its default is
        // true, because the item ships inserted rather than as an opt-in.
        XCTAssertTrue(document.appearance.showsMenuBarExtra)
        // And a document written before an agent's pull request could open on Conversation must
        // leave that on too, for the same reason — an absent key is an older writer, never a
        // reviewer who switched it off (ADR 0026's amendment).
        XCTAssertTrue(document.appearance.opensAgentPullRequestsOnConversation)
        // A group that is absent entirely is the local default.
        XCTAssertEqual(document.notifications, SyncedSettingsDocument.NotificationGroup())
        XCTAssertEqual(document.delegation.agentCLI, AgentCLIConfiguration())
        // A document written before the session back-channel existed brings the *defaults* for
        // its two commands — not an empty local one, which would read as "the other Mac switched
        // the local button off" (ADR 0030).
        XCTAssertEqual(
            document.delegation.agentCLI.sessionResumeTemplate,
            AgentCLIConfiguration.defaultSessionResumeTemplate
        )
        XCTAssertTrue(document.delegation.agentCLI.remoteSessionTemplate.isEmpty)
        XCTAssertEqual(document.delegation.autoDelegation, AutoDelegationRules())
        // A document written before saved replies existed carries neither list, and an absent list
        // is empty rather than a decoding failure.
        XCTAssertEqual(document.composer, SyncedSettingsDocument.ComposerGroup())
        XCTAssertTrue(document.composer.savedReplies.isEmpty)
        XCTAssertTrue(document.composer.reviewTemplates.isEmpty)
        // A document written before automatic merging existed must leave it off — and, just as
        // importantly, must not arrive with an empty allow-list that reads as "every repository"
        // for a feature that is not even on (ADR 0018).
        XCTAssertEqual(document.autoMerge, SyncedSettingsDocument.AutoMergeGroup())
        XCTAssertFalse(document.autoMerge.rules.isEnabled)
        XCTAssertTrue(document.autoMerge.rules.allowedRepositories.isEmpty)
        // The search index is the other field whose default is *true*: a document written before
        // ADR 0019 must not read as "this user switched the index off".
        XCTAssertEqual(document.search, SyncedSettingsDocument.SearchGroup())
        XCTAssertTrue(document.search.isSemanticIndexEnabled)
        // Same for the Spotlight export, one ADR later (0021).
        XCTAssertTrue(document.search.isSpotlightExportEnabled)
        // And the third such default: a document written before structured triage existed says
        // nothing about it, which must not read as "switched off" either (plan §0.5).
        XCTAssertTrue(document.intelligence.structuredTriageEnabled)
        // A document written before the sovereignty policy existed says nothing about it, which
        // must read as "no policy" — an empty list is never sent, and a `false` zero-retention
        // flag is not a constraint (plan §3.K).
        XCTAssertTrue(document.intelligence.openAICompatibleSovereigntyCountries.isEmpty)
        XCTAssertFalse(document.intelligence.openAICompatibleZeroRetention)
        // A document written before branch deletion existed must leave it off: the box is the
        // irreversible half of the one irreversible action, and an absent key is not consent
        // (ADR 0005's 2026-09-05 amendment).
        XCTAssertFalse(document.triage.deletesBranchAfterMerge)
        // A document written before diagnostics existed leaves them off rather than on.
        XCTAssertEqual(document.diagnostics, SyncedSettingsDocument.DiagnosticsGroup())
        XCTAssertFalse(document.diagnostics.isEnabled)
        // Same for the morning digest: an absent group is the opt-in in its off position, which is
        // what a document written before the digest existed has to mean.
        XCTAssertEqual(document.digest, SyncedSettingsDocument.DigestGroup())
        XCTAssertFalse(document.digest.schedule.isEnabled)
        XCTAssertEqual(document.secrets.webhookSecret, "s3cr3tsecret")
        XCTAssertNil(document.secrets.githubToken)
        XCTAssertEqual(document.secrets.count, 1)
    }

    func testADocumentWithoutAVersionOrWithANewerOneIsRefused() {
        XCTAssertThrowsError(
            try SyncedSettingsDocument.decode(from: Data(#"{"sync":{}}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .malformedDocument)
        }
        XCTAssertThrowsError(
            try SyncedSettingsDocument.decode(from: Data(#"{"v":2}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .unsupportedDocumentVersion(2))
        }
        XCTAssertThrowsError(
            try SyncedSettingsDocument.decode(from: Data("not json".utf8))
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .malformedDocument)
        }
    }

    func testAnUnknownWebhookEventKindIsDroppedRatherThanFatal() {
        let group = SyncedSettingsDocument.AutomationGroup(
            webhooksEnabled: true,
            webhookURL: "https://example.com",
            webhookEvents: ["review.submitted", "shepherd.test", "checks.turned_red"]
        )
        // `shepherd.test` is not user-selectable, and the third does not exist in this build.
        XCTAssertEqual(group.knownEvents, [.reviewSubmitted])
    }

    func testAnUnreadableSavedReplyListCostsOnlyThatListAndNotTheDocument() throws {
        let json = """
            {
              "v": 1,
              "composer": {
                "savedReplies": "not an array",
                "reviewTemplates": [
                  {
                    "id": "33333333-3333-4333-8333-333333333333",
                    "pattern": "schnaq/*",
                    "body": "## Checklist"
                  }
                ]
              }
            }
            """
        let document = try SyncedSettingsDocument.decode(from: Data(json.utf8))
        XCTAssertTrue(document.composer.savedReplies.isEmpty)
        XCTAssertEqual(document.composer.reviewTemplates.map(\.pattern), ["schnaq/*"])
    }

    // MARK: - Object location

    func testPathStyleIsTheDefaultAndProducesTheProviderShapedURL() throws {
        let location = try S3ObjectLocation.resolve(
            endpointText: "https://object.storage.eu01.onstackit.cloud",
            bucket: "my-bucket",
            region: "eu01",
            prefix: "shepherd",
            addressing: .path
        )
        XCTAssertEqual(location.host, "object.storage.eu01.onstackit.cloud")
        XCTAssertEqual(location.path, "/my-bucket/shepherd/settings.enc.json")
        XCTAssertEqual(
            location.url?.absoluteString,
            "https://object.storage.eu01.onstackit.cloud/my-bucket/shepherd/settings.enc.json"
        )
        XCTAssertEqual(AppSettings(defaults: makeDefaults()).settingsSyncAddressing, .path)
    }

    func testVirtualHostedStyleMovesTheBucketIntoTheHostAndTheSignature() throws {
        let location = try S3ObjectLocation.resolve(
            endpointText: "https://object.storage.eu01.onstackit.cloud",
            bucket: "my-bucket",
            region: "eu01",
            prefix: "shepherd",
            addressing: .virtualHosted
        )
        XCTAssertEqual(location.host, "my-bucket.object.storage.eu01.onstackit.cloud")
        XCTAssertEqual(location.path, "/shepherd/settings.enc.json")
        XCTAssertEqual(
            location.url?.absoluteString,
            "https://my-bucket.object.storage.eu01.onstackit.cloud/shepherd/settings.enc.json"
        )
    }

    func testThePrefixIsAFolderHoweverTheUserPunctuatesIt() {
        for prefix in ["shepherd", "/shepherd", "shepherd/", "/shepherd/", " shepherd "] {
            XCTAssertEqual(
                S3ObjectLocation.objectKey(prefix: prefix),
                "shepherd/settings.enc.json"
            )
        }
        XCTAssertEqual(S3ObjectLocation.objectKey(prefix: ""), "settings.enc.json")
        XCTAssertEqual(
            S3ObjectLocation.objectKey(prefix: "team/macs"),
            "team/macs/settings.enc.json"
        )
    }

    func testAnIncompleteOrInsecureConfigurationIsRefusedInSettings() {
        func resolve(_ endpoint: String, _ bucket: String, _ region: String) throws {
            _ = try S3ObjectLocation.resolve(
                endpointText: endpoint,
                bucket: bucket,
                region: region,
                prefix: "shepherd",
                addressing: .path
            )
        }
        XCTAssertThrowsError(try resolve("", "b", "eu01")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .notConfigured)
        }
        XCTAssertThrowsError(try resolve("https://example.com", "", "eu01")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .notConfigured)
        }
        XCTAssertThrowsError(try resolve("https://example.com", "b", "")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .notConfigured)
        }
        // http is refused even for this machine: the object carries the user's GitHub token.
        XCTAssertThrowsError(try resolve("http://localhost:9000", "b", "eu01")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try resolve("not a url", "b", "eu01")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try resolve("https://example.com", "a/b", "eu01")) { error in
            XCTAssertEqual(error as? SettingsSyncError, .invalidBucket)
        }
    }

    // MARK: - The three signed requests

    /// The exact signatures Shepherd sends for its three operations, computed independently from
    /// the specification. If canonicalisation ever drifts — a header added to the request but not
    /// to the signed set, the payload hash dropped — these change and the test says so, rather
    /// than a real bucket answering 403 for a reason nobody can see.
    func testTheThreeOperationsAreSignedExactlyAsExpected() throws {
        let client = try makeClient(transport: RecordingS3Transport())

        let get = try client.signedRequest(method: "GET", body: nil, date: syncTestSealedAt)
        XCTAssertEqual(get.headers["x-amz-date"], "20260901T101500Z")
        XCTAssertEqual(get.headers["x-amz-content-sha256"], SigV4Signer.emptyPayloadHash)
        XCTAssertNil(get.headers["content-type"])
        XCTAssertEqual(
            get.headers["authorization"],
            "AWS4-HMAC-SHA256 "
                + "Credential=SHEPHERDEXAMPLEKEYID/20260901/eu01/s3/aws4_request, "
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                + "Signature=7591baf5d620ec290c958e688deb821b4006c566fdba749fcf98a422bc9f8c39"
        )

        let head = try client.signedRequest(method: "HEAD", body: nil, date: syncTestSealedAt)
        XCTAssertEqual(
            head.headers["authorization"],
            "AWS4-HMAC-SHA256 "
                + "Credential=SHEPHERDEXAMPLEKEYID/20260901/eu01/s3/aws4_request, "
                + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                + "Signature=0af2e9349fb16737521c73705da41bded2f5c7dbcb60c909ff3460ff1b4adc24"
        )

        let body = Data(#"{"v":1}"#.utf8)
        let put = try client.signedRequest(method: "PUT", body: body, date: syncTestSealedAt)
        XCTAssertEqual(put.headers["content-type"], "application/json")
        XCTAssertEqual(
            put.headers["x-amz-content-sha256"],
            "afbf9d0f3560b0fd7795e81c42a0a79ee6b6fc67e064f77826aee642cad28d91"
        )
        XCTAssertEqual(
            put.headers["authorization"],
            "AWS4-HMAC-SHA256 "
                + "Credential=SHEPHERDEXAMPLEKEYID/20260901/eu01/s3/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, "
                + "Signature=38a6a69cd70aade386b527c8e181467a5ab664c10b2c87889bdd798c363c9e75"
        )
    }

    func testAMissingKeyPairIsRefusedBeforeAnythingIsSent() throws {
        let client = S3ObjectClient(
            location: try S3ObjectLocation.resolve(
                endpointText: "https://example.com",
                bucket: "b",
                region: "eu01",
                prefix: "",
                addressing: .path
            ),
            credentials: SigV4Signer.Credentials(accessKeyID: "", secretAccessKey: ""),
            transport: RecordingS3Transport()
        )
        XCTAssertThrowsError(
            try client.signedRequest(method: "GET", body: nil, date: syncTestSealedAt)
        ) { error in
            XCTAssertEqual(error as? SettingsSyncError, .credentialsMissing)
        }
    }

    // MARK: - Responses

    func testA404OnHeadMeansNothingHasBeenUploadedRatherThanAnError() async throws {
        let transport = RecordingS3Transport(
            answers: [S3ObjectResponse(status: 404, headers: [:], body: Data())]
        )
        let client = try makeClient(transport: transport)
        let state = try await client.head()
        XCTAssertNil(state)
    }

    func testHeadReportsWhatTheServiceSaidAboutTheObject() async throws {
        let transport = RecordingS3Transport(answers: [
            S3ObjectResponse(
                status: 200,
                headers: [
                    "last-modified": "Tue, 01 Sep 2026 10:15:00 GMT",
                    "content-length": "1234",
                ],
                body: Data()
            ),
        ])
        let client = try makeClient(transport: transport)
        let state = try await client.head()
        XCTAssertEqual(state?.byteCount, 1234)
        XCTAssertEqual(state?.lastModified, syncTestSealedAt)
    }

    func testAnS3ErrorBodyBecomesTheMessageInTheStatusLine() async throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>SignatureDoesNotMatch</Code>\
            <Message>The request signature we calculated does not match</Message></Error>
            """
        let transport = RecordingS3Transport(answers: [
            S3ObjectResponse(status: 403, headers: [:], body: Data(xml.utf8)),
        ])
        let client = try makeClient(transport: transport)
        do {
            _ = try await client.get()
            XCTFail("a 403 must not be reported as success")
        } catch {
            XCTAssertEqual(
                error as? SettingsSyncError,
                .remoteRejected(
                    status: 403,
                    message: "The request signature we calculated does not match"
                )
            )
        }
    }

    func testA404OnGetMeansThereIsNothingToDownload() async throws {
        let transport = RecordingS3Transport(answers: [
            S3ObjectResponse(status: 404, headers: [:], body: Data()),
        ])
        let client = try makeClient(transport: transport)
        do {
            _ = try await client.get()
            XCTFail("a 404 must not be reported as success")
        } catch {
            XCTAssertEqual(error as? SettingsSyncError, .noRemoteDocument)
        }
    }

    private func makeClient(transport: RecordingS3Transport) throws -> S3ObjectClient {
        S3ObjectClient(
            location: try S3ObjectLocation.resolve(
                endpointText: "https://object.storage.eu01.onstackit.cloud",
                bucket: "my-bucket",
                region: "eu01",
                prefix: "shepherd",
                addressing: .path
            ),
            credentials: SigV4Signer.Credentials(
                accessKeyID: "SHEPHERDEXAMPLEKEYID",
                secretAccessKey: "shepherdExampleSecretAccessKey0000000000"
            ),
            transport: transport,
            now: { syncTestSealedAt }
        )
    }

    // MARK: - Capture and apply

    private func makeContext(
        settings: AppSettings,
        secrets: InMemorySecretStore,
        tokens: any TokenStore,
        signedInLogin: String? = nil,
        overrides: AgentOverrideBox? = nil,
        transport: RecordingS3Transport = RecordingS3Transport()
    ) -> SettingsSyncContext {
        var reader: (@Sendable () async -> [AgentRegistryEntry])?
        var writer: (@Sendable ([AgentRegistryEntry]) async -> Void)?
        if let overrides {
            reader = { await overrides.read() }
            writer = { entries in await overrides.write(entries) }
        }
        return SettingsSyncContext(
            settings: settings,
            secrets: secrets,
            tokens: tokens,
            signedInLogin: signedInLogin,
            readAgentOverrides: reader,
            writeAgentOverrides: writer,
            transport: transport,
            now: { syncTestSealedAt },
            deviceName: "Test Mac"
        )
    }

    func testApplyingADocumentWritesEverySettingAndEverySecret() async throws {
        let settings = makeSettings()
        let secrets = InMemorySecretStore()
        let tokens = InMemoryTokenStore()
        let box = AgentOverrideBox()
        let context = makeContext(
            settings: settings,
            secrets: secrets,
            tokens: tokens,
            signedInLogin: nil,
            overrides: box
        )

        let outcome = await SettingsSyncApplier.apply(fullDocument(), context: context)

        XCTAssertEqual(settings.sweepIntervalMinutes, 7)
        XCTAssertFalse(settings.notifyOnReviewRequest)
        XCTAssertTrue(settings.notifyOnChecksFailed)
        XCTAssertFalse(settings.notifyOnDraftConflict)
        // The digest's schedule travels; when this Mac last delivered one does not — that is the
        // device state the applier deliberately leaves alone.
        XCTAssertTrue(settings.digest.isEnabled)
        XCTAssertEqual(settings.digest.hour, 6)
        XCTAssertEqual(settings.digest.minute, 45)
        XCTAssertFalse(settings.digest.weekdaysOnly)
        XCTAssertNil(settings.digestLastDeliveredAt)
        XCTAssertEqual(settings.intelligenceMode, .onDeviceAndCloud)
        XCTAssertEqual(settings.cloudProviderKind, .openAICompatible)
        XCTAssertEqual(settings.openAICompatibleBaseURL, "https://api.example.eu/v1")
        // The preset is not a field in the document: it follows from the URL that was applied,
        // and this one is nobody's preset.
        XCTAssertEqual(settings.openAICompatiblePreset, .custom)
        XCTAssertEqual(settings.openAICompatibleModel, "some-open-model")
        // The sovereignty policy is part of what the request is, so it travels with the endpoint
        // (plan §3.K).
        XCTAssertEqual(settings.openAICompatibleSovereigntyCountries, ["DE", "FR"])
        XCTAssertTrue(settings.openAICompatibleZeroRetention)
        XCTAssertEqual(settings.anthropicModel, "some-model")
        // The switch travels; the verdicts it produces never do — they are rebuildable device
        // state, like the search vectors (plan §3.A).
        XCTAssertFalse(settings.structuredTriageEnabled)
        XCTAssertEqual(settings.agentCLI.maxTurns, 42)
        XCTAssertNil(settings.agentCLI.maxBudgetUSD)
        XCTAssertEqual(settings.agentCLI.permissionMode, .plan)
        // Both session commands arrive; neither is a credential, which is why they may (ADR 0030).
        XCTAssertEqual(
            settings.agentCLI.sessionResumeTemplate,
            "/usr/local/bin/my-agent resume {sessionID} {message}"
        )
        XCTAssertEqual(
            settings.agentCLI.remoteSessionTemplate,
            "/usr/local/bin/my-agent remote {sessionURL} {message}"
        )
        XCTAssertEqual(settings.localCheckouts["schnaq/review"], "/Users/someone/code/review")
        // The rules travel (ADR 0016); the ledger of what a rule already did deliberately does
        // not — it is one Mac's automation state.
        XCTAssertTrue(settings.autoDelegation.isEnabled)
        XCTAssertEqual(settings.autoDelegation.triggers, [.checksFailed, .changesRequested])
        XCTAssertEqual(settings.autoDelegation.promptTemplate, "fix #{number}")
        XCTAssertEqual(settings.autoDelegation.maxConcurrent, 2)
        XCTAssertEqual(settings.autoDelegation.maxPerDay, 9)
        XCTAssertTrue(settings.webhooksEnabled)
        XCTAssertEqual(settings.webhookURL, "https://n8n.example.com/webhook/shepherd")
        XCTAssertEqual(settings.webhookEvents, [.reviewSubmitted, .pullRequestMerged])
        // The auto-merge rules travel too; the audit log they are deduplicated against does not —
        // it is this Mac's record of what it already queued (ADR 0018).
        XCTAssertTrue(settings.autoMerge.isEnabled)
        XCTAssertEqual(settings.autoMerge.allowedRepositories, ["schnaq/*"])
        XCTAssertEqual(settings.autoMerge.requiredLabels, ["automerge"])
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.groupBy, .repository)
        XCTAssertEqual(settings.sortOrder, .oldestFirst)
        XCTAssertEqual(settings.diffFontSize, 16)
        XCTAssertTrue(settings.diffWrapsLines)
        XCTAssertTrue(settings.diffUsesInlineMode)
        XCTAssertEqual(settings.diffRenderer, .native)
        // A Mac that hid the menu-bar item hides it here too; the scene's `isInserted` binding
        // reads this setting, so there is nothing else to apply.
        XCTAssertFalse(settings.showsMenuBarExtra)
        // The tab a review opens on is a preference, not per-Mac UI state, so it travels with the
        // rest of them (ADR 0026's amendment).
        XCTAssertFalse(settings.opensAgentPullRequestsOnConversation)
        XCTAssertEqual(settings.defaultMergeMethod, .rebase)
        XCTAssertTrue(settings.deletesBranchAfterMerge)
        // Saved replies and templates travel in their own order — it is the order of the insert
        // menu and the last tie-breaker of the template match.
        XCTAssertEqual(settings.savedReplies.map(\.name), ["Needs a test", "Nit"])
        XCTAssertEqual(settings.savedReplies.first?.id, syncTestReplyID)
        XCTAssertEqual(settings.savedReplies.first?.body, "Please add a test.")
        XCTAssertEqual(settings.reviewTemplates.map(\.pattern), ["schnaq/*"])
        XCTAssertEqual(settings.reviewTemplates.first?.body, "## Checklist\n- [ ] tests")
        // The lane thresholds travel; the ninety days of outcomes behind the badges never do —
        // they are rebuildable device state, like the search vectors (ADR 0027).
        XCTAssertEqual(settings.trustLaneMaxFiles, 9)
        XCTAssertEqual(settings.trustLaneMaxChangedLines, 60)
        XCTAssertEqual(settings.trustLaneConfiguration.maxFiles, 9)
        XCTAssertEqual(settings.trustLaneConfiguration.maxChangedLines, 60)
        // The switch travels; the vectors it produces never do — they are rebuildable device
        // state (ADR 0019).
        XCTAssertFalse(settings.semanticSearchEnabled)
        // And the Spotlight switch, whose items are as unsyncable as the vectors (ADR 0021).
        XCTAssertFalse(settings.spotlightExportEnabled)
        // The opt-in travels; the reports themselves never do (ADR 0017).
        XCTAssertTrue(settings.diagnosticsEnabled)

        XCTAssertEqual(
            secrets.contents[KeychainSecretStore.Key.anthropicAPIKey],
            "sk-ant-example"
        )
        XCTAssertEqual(
            secrets.contents[KeychainSecretStore.Key.openAICompatibleAPIKey],
            "sk-example"
        )
        XCTAssertEqual(secrets.contents[KeychainSecretStore.Key.webhookSecret], "hunter2hunter2")
        let stored = try await tokens.token(for: "octocat")
        XCTAssertEqual(stored?.accessToken, "ghp_example")
        // Signed out, so the account is adopted and the sign-in flow still has to be run.
        XCTAssertEqual(settings.accountLogin, "octocat")
        XCTAssertEqual(settings.accountAuthKind, .pat)
        XCTAssertTrue(outcome.needsSignInRestart)
        XCTAssertEqual(outcome.secretsWritten, 4)
        XCTAssertEqual(outcome.agentOverridesApplied, 1)
        XCTAssertFalse(outcome.skippedAgentRegistry)
        let applied = await box.read()
        XCTAssertEqual(applied.map(\.id), ["my-agent"])
    }

    func testCaptureThenApplyIsIdentityAcrossTwoMacs() async throws {
        // Mac A: a fully configured install.
        let macA = makeSettings()
        let secretsA = InMemorySecretStore()
        let tokensA = InMemoryTokenStore()
        let boxA = AgentOverrideBox()
        let contextA = makeContext(
            settings: macA,
            secrets: secretsA,
            tokens: tokensA,
            signedInLogin: nil,
            overrides: boxA
        )
        _ = await SettingsSyncApplier.apply(fullDocument(), context: contextA)

        // Seal what Mac A now has, and open it on a blank Mac B.
        let captured = await SettingsSyncApplier.capture(context: contextA)
        XCTAssertEqual(captured.secrets.githubToken, "ghp_example")
        XCTAssertEqual(captured.agents.registryOverrides.map(\.id), ["my-agent"])
        let envelope = try seal(captured)
        let reopened = try SettingsSyncCrypto.open(envelope, passphrase: syncTestPassphrase)
        XCTAssertEqual(reopened, captured)

        let macB = makeSettings()
        let secretsB = InMemorySecretStore()
        let tokensB = InMemoryTokenStore()
        let boxB = AgentOverrideBox()
        let contextB = makeContext(
            settings: macB,
            secrets: secretsB,
            tokens: tokensB,
            overrides: boxB
        )
        _ = await SettingsSyncApplier.apply(reopened, context: contextB)

        let recaptured = await SettingsSyncApplier.capture(context: contextB)
        XCTAssertEqual(recaptured, captured)
    }

    func testAnAbsentSecretLeavesThisMacsAloneRatherThanDeletingIt() async {
        let settings = makeSettings()
        let secrets = InMemorySecretStore(initial: [
            KeychainSecretStore.Key.webhookSecret: "keep-me-please",
        ])
        let context = makeContext(
            settings: settings,
            secrets: secrets,
            tokens: InMemoryTokenStore()
        )
        var document = fullDocument()
        document.secrets = SyncedSettingsDocument.Secrets(anthropicKey: "sk-ant-new")

        let outcome = await SettingsSyncApplier.apply(document, context: context)

        XCTAssertEqual(secrets.contents[KeychainSecretStore.Key.webhookSecret], "keep-me-please")
        XCTAssertEqual(secrets.contents[KeychainSecretStore.Key.anthropicAPIKey], "sk-ant-new")
        XCTAssertEqual(outcome.secretsWritten, 1)
        XCTAssertFalse(outcome.needsSignInRestart)
    }

    func testReplacingTheTokenOfTheSignedInAccountNeedsNoRestart() async {
        let settings = makeSettings()
        settings.accountLogin = "octocat"
        let context = makeContext(
            settings: settings,
            secrets: InMemorySecretStore(),
            tokens: InMemoryTokenStore(),
            signedInLogin: "octocat"
        )
        let outcome = await SettingsSyncApplier.apply(fullDocument(), context: context)
        XCTAssertFalse(outcome.needsSignInRestart)
    }

    func testATokenForADifferentAccountAsksForASignInRestartAndKeepsTheCurrentOne() async throws {
        let settings = makeSettings()
        settings.accountLogin = "someone-else"
        let tokens = InMemoryTokenStore(
            initial: ["someone-else": TokenSet(accessToken: "keep-this")]
        )
        let context = makeContext(
            settings: settings,
            secrets: InMemorySecretStore(),
            tokens: tokens,
            signedInLogin: "someone-else"
        )
        let outcome = await SettingsSyncApplier.apply(fullDocument(), context: context)
        XCTAssertTrue(outcome.needsSignInRestart)
        // The signed-in account is not silently switched, and its credential is untouched.
        XCTAssertEqual(settings.accountLogin, "someone-else")
        let kept = try await tokens.token(for: "someone-else")
        XCTAssertEqual(kept?.accessToken, "keep-this")
        let arrived = try await tokens.token(for: "octocat")
        XCTAssertEqual(arrived?.accessToken, "ghp_example")
    }

    func testRegistryEntriesAreReportedAsSkippedWhenThereIsNoDatabase() async {
        let context = makeContext(
            settings: makeSettings(),
            secrets: InMemorySecretStore(),
            tokens: InMemoryTokenStore(),
            overrides: nil
        )
        let outcome = await SettingsSyncApplier.apply(fullDocument(), context: context)
        XCTAssertTrue(outcome.skippedAgentRegistry)
        XCTAssertEqual(outcome.agentOverridesApplied, 0)
    }

    func testAKeychainRefusalForOneSecretDoesNotStopTheOthers() async {
        let secrets = InMemorySecretStore(
            failingKeys: [KeychainSecretStore.Key.anthropicAPIKey]
        )
        let context = makeContext(
            settings: makeSettings(),
            secrets: secrets,
            tokens: InMemoryTokenStore()
        )
        let outcome = await SettingsSyncApplier.apply(fullDocument(), context: context)
        XCTAssertNil(secrets.contents[KeychainSecretStore.Key.anthropicAPIKey])
        XCTAssertEqual(secrets.contents[KeychainSecretStore.Key.webhookSecret], "hunter2hunter2")
        // Three of the four: the two remaining string secrets plus the GitHub token.
        XCTAssertEqual(outcome.secretsWritten, 3)
    }

    func testCaptureCarriesOnlyTheAccessTokenAndNotTheRefreshToken() async throws {
        let settings = makeSettings()
        settings.accountLogin = "octocat"
        settings.accountAuthKind = .deviceFlow
        let tokens = InMemoryTokenStore(initial: [
            "octocat": TokenSet(
                accessToken: "ghu_access",
                refreshToken: "ghr_refresh",
                scopes: ["repo"]
            ),
        ])
        let context = makeContext(
            settings: settings,
            secrets: InMemorySecretStore(),
            tokens: tokens,
            signedInLogin: "octocat"
        )
        let document = await SettingsSyncApplier.capture(context: context)
        XCTAssertEqual(document.secrets.githubToken, "ghu_access")
        XCTAssertEqual(document.account.login, "octocat")
        XCTAssertEqual(document.account.authKind, .deviceFlow)
        let text = try XCTUnwrap(String(data: try document.canonicalJSON(), encoding: .utf8))
        XCTAssertFalse(text.contains("ghr_refresh"))
    }

    func testCaptureOnAFreshInstallCarriesNoAccountAndNoSecrets() async {
        let context = makeContext(
            settings: makeSettings(),
            secrets: InMemorySecretStore(),
            tokens: InMemoryTokenStore()
        )
        let document = await SettingsSyncApplier.capture(context: context)
        XCTAssertNil(document.account.login)
        XCTAssertNil(document.account.authKind)
        XCTAssertTrue(document.secrets.isEmpty)
        XCTAssertEqual(document.v, SyncedSettingsDocument.schemaVersion)
        // Nothing opt-in is on in a captured fresh install, diagnostics included (ADR 0017).
        XCTAssertFalse(document.diagnostics.isEnabled)
        XCTAssertFalse(document.automation.webhooksEnabled)
        XCTAssertFalse(document.autoMerge.rules.isEnabled)
        // The menu-bar quick inbox is the exception: it ships on, so a fresh install carries it
        // as on rather than as an unset opt-in. So does the search index, for the reason ADR 0019
        // argues — it is on-device and costs nothing but CPU.
        XCTAssertTrue(document.appearance.showsMenuBarExtra)
        XCTAssertTrue(document.search.isSemanticIndexEnabled)
        // Same for the Spotlight export, one ADR later (0021).
        XCTAssertTrue(document.search.isSpotlightExportEnabled)
        // And for structured triage, which is on-device for the same reason (plan §0.5) — even
        // though nothing classifies anything until the tiers are switched on.
        XCTAssertTrue(document.intelligence.structuredTriageEnabled)
    }

    // MARK: - The model's flow

    func testUploadSealsWhatIsCapturedAndDownloadStopsForConfirmation() async throws {
        let settings = makeConfiguredSettings()
        settings.diffFontSize = 17
        let secrets = makeStoreWithKeys()
        let transport = RecordingS3Transport()
        let context = makeContext(
            settings: settings,
            secrets: secrets,
            tokens: InMemoryTokenStore(),
            transport: transport
        )

        let model = SettingsSyncModel()
        model.load(context: context)
        XCTAssertTrue(model.hasStoredCredentials)
        model.passphraseField = syncTestPassphrase

        await model.upload(context: context)
        guard case .success = model.state else {
            return XCTFail("the upload should have succeeded, got \(model.state)")
        }
        XCTAssertEqual(settings.settingsSyncLastUploadAt, syncTestSealedAt)
        XCTAssertEqual(transport.requests.map(\.method), ["PUT"])
        XCTAssertEqual(
            transport.requests.first?.url.absoluteString,
            "https://object.storage.eu01.onstackit.cloud/my-bucket/shepherd/settings.enc.json"
        )

        // Feed the uploaded bytes back as the download, onto a blank Mac.
        let uploaded = try XCTUnwrap(transport.lastPutBody)
        let downloadTransport = RecordingS3Transport(answers: [
            S3ObjectResponse(status: 200, headers: [:], body: uploaded),
        ])
        let blank = makeConfiguredSettings()
        let blankContext = makeContext(
            settings: blank,
            secrets: makeStoreWithKeys(),
            tokens: InMemoryTokenStore(),
            transport: downloadTransport
        )
        let second = SettingsSyncModel()
        second.load(context: blankContext)
        second.passphraseField = syncTestPassphrase

        await second.prepareDownload(context: blankContext)
        // Nothing has been applied yet: that is the whole point of the confirmation step.
        XCTAssertEqual(second.pendingDownload?.deviceName, "Test Mac")
        XCTAssertEqual(second.pendingDownload?.createdAt, syncTestSealedAt)
        XCTAssertEqual(blank.diffFontSize, 13)

        let outcome = await second.confirmDownload(context: blankContext)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(blank.diffFontSize, 17)
        XCTAssertEqual(blank.settingsSyncLastDownloadAt, syncTestSealedAt)
        XCTAssertNil(second.pendingDownload)
    }

    func testAWrongPassphraseOnDownloadChangesNothingLocally() async throws {
        let settings = makeConfiguredSettings()
        settings.diffFontSize = 11

        let envelope = try seal(fullDocument())
        let transport = RecordingS3Transport(answers: [
            S3ObjectResponse(status: 200, headers: [:], body: try envelope.json()),
        ])
        let context = makeContext(
            settings: settings,
            secrets: makeStoreWithKeys(),
            tokens: InMemoryTokenStore(),
            transport: transport
        )

        let model = SettingsSyncModel()
        model.load(context: context)
        model.passphraseField = "definitely not it"
        await model.prepareDownload(context: context)

        XCTAssertNil(model.pendingDownload)
        XCTAssertEqual(
            model.state,
            .failure(SettingsSyncError.wrongPassphraseOrCorruptedData.errorDescription ?? "")
        )
        XCTAssertEqual(settings.diffFontSize, 11)
        XCTAssertNil(settings.settingsSyncLastDownloadAt)
    }

    func testCheckRemoteReportsAnEmptyBucketAsEmptyRatherThanBroken() async throws {
        let transport = RecordingS3Transport(answers: [
            S3ObjectResponse(status: 404, headers: [:], body: Data()),
        ])
        let context = makeContext(
            settings: makeConfiguredSettings(),
            secrets: makeStoreWithKeys(),
            tokens: InMemoryTokenStore(),
            transport: transport
        )
        let model = SettingsSyncModel()
        model.load(context: context)
        await model.checkRemote(context: context)
        XCTAssertTrue(model.remoteIsEmpty)
        XCTAssertNil(model.remote)
        XCTAssertEqual(transport.requests.map(\.method), ["HEAD"])
        guard case .success = model.state else {
            return XCTFail("an empty bucket is not a failure, got \(model.state)")
        }
    }

    /// With the toggle off — or the fields empty — no request is built at all. The gate is in
    /// ``SettingsSyncContext/client()``, not only in the view that hides the buttons.
    func testAnUnconfiguredBucketFailsWithoutSendingAnything() async {
        let transport = RecordingS3Transport()
        let context = makeContext(
            settings: makeSettings(),
            secrets: InMemorySecretStore(),
            tokens: InMemoryTokenStore(),
            transport: transport
        )
        let model = SettingsSyncModel()
        model.passphraseField = syncTestPassphrase
        await model.upload(context: context)
        XCTAssertEqual(
            model.state,
            .failure(SettingsSyncError.notConfigured.errorDescription ?? "")
        )
        XCTAssertTrue(transport.requests.isEmpty)

        // Fully configured but switched off is still refused.
        let disabled = makeConfiguredSettings()
        disabled.settingsSyncEnabled = false
        let disabledContext = makeContext(
            settings: disabled,
            secrets: makeStoreWithKeys(),
            tokens: InMemoryTokenStore(),
            transport: transport
        )
        let second = SettingsSyncModel()
        second.load(context: disabledContext)
        second.passphraseField = syncTestPassphrase
        await second.upload(context: disabledContext)
        XCTAssertEqual(
            second.state,
            .failure(SettingsSyncError.notConfigured.errorDescription ?? "")
        )
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTheRememberCheckboxIsWhatDecidesWhetherThePassphraseIsStored() {
        let settings = makeSettings()
        let secrets = InMemorySecretStore()
        let context = makeContext(
            settings: settings,
            secrets: secrets,
            tokens: InMemoryTokenStore()
        )
        let model = SettingsSyncModel()
        model.passphraseField = syncTestPassphrase

        // Off by default: nothing is written.
        model.savePassphrase(context: context)
        XCTAssertNil(secrets.contents[KeychainSecretStore.Key.settingsSyncPassphrase])
        XCTAssertFalse(model.hasStoredPassphrase)

        settings.settingsSyncRemembersPassphrase = true
        model.savePassphrase(context: context)
        XCTAssertEqual(
            secrets.contents[KeychainSecretStore.Key.settingsSyncPassphrase],
            syncTestPassphrase
        )
        XCTAssertTrue(model.hasStoredPassphrase)

        // Unticking it deletes the stored copy rather than merely stopping new writes.
        settings.settingsSyncRemembersPassphrase = false
        model.savePassphrase(context: context)
        XCTAssertNil(secrets.contents[KeychainSecretStore.Key.settingsSyncPassphrase])
        XCTAssertFalse(model.hasStoredPassphrase)
    }

    func testThePassphraseIsNeverWrittenToPreferences() async {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.settingsSyncEnabled = true
        settings.settingsSyncEndpoint = "https://object.storage.eu01.onstackit.cloud"
        settings.settingsSyncBucket = "my-bucket"
        settings.settingsSyncRegion = "eu01"
        let context = makeContext(
            settings: settings,
            secrets: makeStoreWithKeys(),
            tokens: InMemoryTokenStore()
        )
        let model = SettingsSyncModel()
        model.load(context: context)
        model.passphraseField = syncTestPassphrase
        await model.upload(context: context)

        for (_, value) in defaults.dictionaryRepresentation() {
            guard let text = value as? String else { continue }
            XCTAssertFalse(text.contains(syncTestPassphrase))
        }
        XCTAssertNil(defaults.string(forKey: "settingsSync.passphrase"))
    }

    func testTheAccessKeyPairIsStoredInTheSecretStoreAndNowhereElse() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let secrets = InMemorySecretStore()
        let context = makeContext(
            settings: settings,
            secrets: secrets,
            tokens: InMemoryTokenStore()
        )
        let model = SettingsSyncModel()
        model.accessKeyIDField = "SHEPHERDEXAMPLEKEYID"
        model.secretAccessKeyField = "shepherdExampleSecret"
        XCTAssertNil(model.saveCredentials(context: context))
        XCTAssertTrue(model.hasStoredCredentials)
        XCTAssertEqual(
            secrets.contents[KeychainSecretStore.Key.settingsSyncSecretAccessKey],
            "shepherdExampleSecret"
        )
        for (_, value) in defaults.dictionaryRepresentation() {
            guard let text = value as? String else { continue }
            XCTAssertFalse(text.contains("shepherdExampleSecret"))
        }
    }

    // MARK: - Device name

    func testTheDeviceNameIsSingleLineAndBounded() {
        XCTAssertEqual(
            SettingsSyncCrypto.sanitisedDeviceName("Christian's MacBook"),
            "Christian's MacBook"
        )
        XCTAssertEqual(SettingsSyncCrypto.sanitisedDeviceName("two\nlines"), "twolines")
        XCTAssertEqual(SettingsSyncCrypto.sanitisedDeviceName("  "), "Mac")
        XCTAssertEqual(SettingsSyncCrypto.sanitisedDeviceName(""), "Mac")
        XCTAssertEqual(
            SettingsSyncCrypto.sanitisedDeviceName(String(repeating: "a", count: 200)).count,
            SettingsSyncCrypto.deviceNameLimit
        )
        XCTAssertFalse(SettingsSyncCrypto.currentDeviceName.isEmpty)
    }
}
