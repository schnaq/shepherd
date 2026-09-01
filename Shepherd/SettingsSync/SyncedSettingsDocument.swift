import Foundation
import GitHubKit
import ShepherdCore

/// Tolerant decoding helpers used by every group of ``SyncedSettingsDocument``.
///
/// Forward compatibility is the whole point: a document written by a *newer* Shepherd carries
/// keys this build has never heard of, and a document written by an *older* one is missing keys
/// this build expects. Neither may throw away the rest of the document, so every field falls
/// back to the local default and unknown keys are simply never looked at.
extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is absent or unreadable.
    /// - Parameters:
    ///   - key: The coding key.
    ///   - fallback: What to use when the key is missing or of the wrong shape.
    /// - Returns: The decoded value, or `fallback`.
    func syncedValue<Value: Decodable>(_ key: Key, default fallback: Value) -> Value {
        (try? decodeIfPresent(Value.self, forKey: key)).flatMap { $0 } ?? fallback
    }

    /// Decodes an optional value, treating an unreadable one as absent.
    /// - Parameters:
    ///   - key: The coding key.
    ///   - type: The value type.
    /// - Returns: The decoded value, or `nil`.
    func syncedOptional<Value: Decodable>(_ key: Key, as type: Value.Type) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: key)).flatMap { $0 }
    }
}

/// The plaintext inside the encrypted envelope: every Shepherd setting, plus the secrets that
/// make a second Mac actually usable (ADR 0014).
///
/// This is the *only* type in the app that holds settings and secrets side by side, and it exists
/// exclusively to be sealed: it is created, encrypted and dropped within one function, and
/// nothing ever writes it to disk in the clear. The server sees the sealed envelope and nothing
/// else.
///
/// The shape is explicit per settings group rather than one flat bag, so a reviewer can see at a
/// glance which preference travels and which does not. What deliberately does *not* travel:
/// the local database (it is a cache GitHub can refill), the outbox (machine-local pending
/// work), viewed-file state, and window geometry.
struct SyncedSettingsDocument: Codable, Sendable, Equatable {
    /// The document version. Bumped only for a change a reader cannot ignore.
    static let schemaVersion = 1

    // MARK: - Groups

    /// Sweep cadence (Settings → Sync).
    struct SyncGroup: Codable, Sendable, Equatable {
        /// How often the inbox sweep runs, in minutes.
        var sweepIntervalMinutes: Double

        /// Creates the group.
        /// - Parameter sweepIntervalMinutes: The sweep interval.
        init(sweepIntervalMinutes: Double = 2) {
            self.sweepIntervalMinutes = sweepIntervalMinutes
        }

        private enum CodingKeys: String, CodingKey {
            case sweepIntervalMinutes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sweepIntervalMinutes = container.syncedValue(.sweepIntervalMinutes, default: 2)
        }
    }

    /// Which sync events become macOS notifications.
    struct NotificationGroup: Codable, Sendable, Equatable {
        /// Notify on a new review request.
        var onReviewRequest: Bool
        /// Notify when CI fails on one of the user's own pull requests.
        var onChecksFailed: Bool
        /// Notify when a queued review could not be submitted.
        var onDraftConflict: Bool

        /// Creates the group.
        init(onReviewRequest: Bool = true, onChecksFailed: Bool = true, onDraftConflict: Bool = true) {
            self.onReviewRequest = onReviewRequest
            self.onChecksFailed = onChecksFailed
            self.onDraftConflict = onDraftConflict
        }

        private enum CodingKeys: String, CodingKey {
            case onReviewRequest, onChecksFailed, onDraftConflict
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            onReviewRequest = container.syncedValue(.onReviewRequest, default: true)
            onChecksFailed = container.syncedValue(.onChecksFailed, default: true)
            onDraftConflict = container.syncedValue(.onDraftConflict, default: true)
        }
    }

    /// The user's extensions to the bundled agent registry (ADR 0008).
    ///
    /// These live in the local database rather than `UserDefaults`, which is why applying them
    /// needs a signed-in session; a document downloaded while signed out keeps them and says so.
    struct AgentsGroup: Codable, Sendable, Equatable {
        /// The registry entries the user added.
        var registryOverrides: [AgentRegistryEntry]

        /// Creates the group.
        /// - Parameter registryOverrides: The user's entries.
        init(registryOverrides: [AgentRegistryEntry] = []) {
            self.registryOverrides = registryOverrides
        }

        private enum CodingKeys: String, CodingKey {
            case registryOverrides
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            registryOverrides = container.syncedValue(.registryOverrides, default: [])
        }
    }

    /// The non-secret half of the intelligence configuration (ADR 0007).
    struct IntelligenceGroup: Codable, Sendable, Equatable {
        /// Which tiers are on.
        var mode: IntelligenceMode
        /// Which cloud shape the BYOK tier uses.
        var cloudProviderKind: CloudProviderKind
        /// The Anthropic model id.
        var anthropicModel: String
        /// Which known endpoint the OpenAI-compatible configuration came from.
        var openAICompatiblePreset: IntelligenceEndpointPreset
        /// The OpenAI-compatible base URL.
        var openAICompatibleBaseURL: String
        /// The model name sent to the OpenAI-compatible endpoint.
        var openAICompatibleModel: String

        /// Creates the group.
        init(
            mode: IntelligenceMode = .off,
            cloudProviderKind: CloudProviderKind = .anthropic,
            anthropicModel: String = "",
            openAICompatiblePreset: IntelligenceEndpointPreset = .custom,
            openAICompatibleBaseURL: String = "",
            openAICompatibleModel: String = ""
        ) {
            self.mode = mode
            self.cloudProviderKind = cloudProviderKind
            self.anthropicModel = anthropicModel
            self.openAICompatiblePreset = openAICompatiblePreset
            self.openAICompatibleBaseURL = openAICompatibleBaseURL
            self.openAICompatibleModel = openAICompatibleModel
        }

        private enum CodingKeys: String, CodingKey {
            case mode, cloudProviderKind, anthropicModel
            case openAICompatiblePreset, openAICompatibleBaseURL, openAICompatibleModel
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = container.syncedValue(.mode, default: IntelligenceMode.off)
            cloudProviderKind = container.syncedValue(
                .cloudProviderKind,
                default: CloudProviderKind.anthropic
            )
            anthropicModel = container.syncedValue(.anthropicModel, default: "")
            let baseURL = container.syncedValue(.openAICompatibleBaseURL, default: "")
            openAICompatibleBaseURL = baseURL
            openAICompatibleModel = container.syncedValue(.openAICompatibleModel, default: "")
            // Same reasoning as `AppSettings.init`: a document written before presets existed
            // should show the endpoint it actually points at rather than "Custom".
            openAICompatiblePreset = container.syncedValue(
                .openAICompatiblePreset,
                default: IntelligenceEndpointPreset.matching(baseURL: baseURL)
            )
        }
    }

    /// How the local agent CLI is invoked, where the clones are (ADR 0011), and which rules may
    /// start a delegation unattended (ADR 0016).
    struct DelegationGroup: Codable, Sendable, Equatable {
        /// The command shape and its guardrails. Carries no credential by construction.
        var agentCLI: AgentCLIConfiguration
        /// Repository full name → local clone path.
        var localCheckouts: [String: String]
        /// The opt-in automatic-delegation rules.
        ///
        /// The *rules* travel; the ledger of what a rule already did does not — that is one
        /// machine's automation state, and sharing a day counter between two Macs would make one
        /// silently cap the other (ADR 0016).
        var autoDelegation: AutoDelegationRules

        /// Creates the group.
        init(
            agentCLI: AgentCLIConfiguration = AgentCLIConfiguration(),
            localCheckouts: [String: String] = [:],
            autoDelegation: AutoDelegationRules = AutoDelegationRules()
        ) {
            self.agentCLI = agentCLI
            self.localCheckouts = localCheckouts
            self.autoDelegation = autoDelegation
        }

        private enum CodingKeys: String, CodingKey {
            case agentCLI, localCheckouts, autoDelegation
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agentCLI = container.syncedValue(.agentCLI, default: AgentCLIConfiguration())
            localCheckouts = container.syncedValue(.localCheckouts, default: [:])
            autoDelegation = container.syncedValue(
                .autoDelegation,
                default: AutoDelegationRules()
            )
        }
    }

    /// The non-secret half of the outbound-webhook configuration (ADR 0012).
    struct AutomationGroup: Codable, Sendable, Equatable {
        /// Whether webhooks are on.
        var webhooksEnabled: Bool
        /// The webhook URL as typed.
        var webhookURL: String
        /// The subscribed event kinds, as their wire raw values, sorted.
        var webhookEvents: [String]

        /// Creates the group.
        init(
            webhooksEnabled: Bool = false,
            webhookURL: String = "",
            webhookEvents: [String] = []
        ) {
            self.webhooksEnabled = webhooksEnabled
            self.webhookURL = webhookURL
            self.webhookEvents = webhookEvents
        }

        private enum CodingKeys: String, CodingKey {
            case webhooksEnabled, webhookURL, webhookEvents
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            webhooksEnabled = container.syncedValue(.webhooksEnabled, default: false)
            webhookURL = container.syncedValue(.webhookURL, default: "")
            webhookEvents = container.syncedValue(.webhookEvents, default: [])
        }

        /// The event kinds this build understands, filtered to the user-selectable ones.
        ///
        /// An unknown raw value from a newer Shepherd is dropped rather than fatal — exactly
        /// what ``AppSettings/init(defaults:)`` does with a stored list.
        var knownEvents: Set<WebhookEventKind> {
            Set(webhookEvents.compactMap(WebhookEventKind.init(rawValue:)))
                .intersection(WebhookEventKind.userSelectable)
        }
    }

    /// Theme, inbox ordering and diff-viewer chrome.
    struct AppearanceGroup: Codable, Sendable, Equatable {
        /// Dark, light or system.
        var appearance: AppearanceSetting
        /// Which facet the inbox is sectioned by.
        var inboxGroupBy: InboxFacet
        /// How rows are ordered inside a section.
        var inboxSortOrder: InboxSortOrder
        /// Monaco's font size.
        var diffFontSize: Double
        /// Whether long lines wrap.
        var diffWrapsLines: Bool
        /// Whether the diff is shown inline.
        var diffUsesInlineMode: Bool

        /// Creates the group.
        init(
            appearance: AppearanceSetting = .system,
            inboxGroupBy: InboxFacet = .provenance,
            inboxSortOrder: InboxSortOrder = .priority,
            diffFontSize: Double = 13,
            diffWrapsLines: Bool = false,
            diffUsesInlineMode: Bool = false
        ) {
            self.appearance = appearance
            self.inboxGroupBy = inboxGroupBy
            self.inboxSortOrder = inboxSortOrder
            self.diffFontSize = diffFontSize
            self.diffWrapsLines = diffWrapsLines
            self.diffUsesInlineMode = diffUsesInlineMode
        }

        private enum CodingKeys: String, CodingKey {
            case appearance, inboxGroupBy, inboxSortOrder
            case diffFontSize, diffWrapsLines, diffUsesInlineMode
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appearance = container.syncedValue(.appearance, default: AppearanceSetting.system)
            inboxGroupBy = container.syncedValue(.inboxGroupBy, default: InboxFacet.provenance)
            inboxSortOrder = container.syncedValue(
                .inboxSortOrder,
                default: InboxSortOrder.priority
            )
            diffFontSize = container.syncedValue(.diffFontSize, default: 13)
            diffWrapsLines = container.syncedValue(.diffWrapsLines, default: false)
            diffUsesInlineMode = container.syncedValue(.diffUsesInlineMode, default: false)
        }
    }

    /// Choices the review and bulk-triage dialogs remember (ADR 0015).
    struct TriageGroup: Codable, Sendable, Equatable {
        /// The merge method the merge sheet and the bulk-triage dialog open on.
        var defaultMergeMethod: MergeMethod

        /// Creates the group.
        /// - Parameter defaultMergeMethod: The remembered merge method.
        init(defaultMergeMethod: MergeMethod = .squash) {
            self.defaultMergeMethod = defaultMergeMethod
        }

        private enum CodingKeys: String, CodingKey {
            case defaultMergeMethod
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultMergeMethod = container.syncedValue(
                .defaultMergeMethod,
                default: MergeMethod.squash
            )
        }
    }

    /// Who the token in ``Secrets`` belongs to.
    ///
    /// The identity is *not* a secret and lives here rather than under `secrets` on purpose: a
    /// Keychain item is keyed by login, so the applier needs the login to store the token under
    /// the right account (ADR 0004).
    struct AccountGroup: Codable, Sendable, Equatable {
        /// The GitHub login.
        var login: String?
        /// How that account authenticates.
        var authKind: AuthKind?

        /// Creates the group.
        init(login: String? = nil, authKind: AuthKind? = nil) {
            self.login = login
            self.authKind = authKind
        }

        private enum CodingKeys: String, CodingKey {
            case login, authKind
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            login = container.syncedOptional(.login, as: String.self)
            authKind = container.syncedOptional(.authKind, as: AuthKind.self)
        }
    }

    /// The Keychain half: everything a fresh Mac cannot re-derive on its own.
    ///
    /// This is what makes the feature worth having and what makes the encryption mandatory.
    /// Every field is optional because a user who never configured a webhook has no webhook
    /// secret to carry, and an absent field means "leave whatever this Mac has alone" — never
    /// "delete it".
    struct Secrets: Codable, Sendable, Equatable {
        /// The GitHub access token (ADR 0004).
        var githubToken: String?
        /// The Anthropic API key (ADR 0007).
        var anthropicKey: String?
        /// The API key of the user's OpenAI-compatible endpoint (ADR 0007).
        var openAICompatibleKey: String?
        /// The webhook signing secret (ADR 0012).
        var webhookSecret: String?

        /// Creates the secret bundle.
        init(
            githubToken: String? = nil,
            anthropicKey: String? = nil,
            openAICompatibleKey: String? = nil,
            webhookSecret: String? = nil
        ) {
            self.githubToken = githubToken
            self.anthropicKey = anthropicKey
            self.openAICompatibleKey = openAICompatibleKey
            self.webhookSecret = webhookSecret
        }

        /// Whether anything at all is carried.
        var isEmpty: Bool {
            [githubToken, anthropicKey, openAICompatibleKey, webhookSecret]
                .allSatisfy { ($0 ?? "").isEmpty }
        }

        /// How many secrets are carried, for the status line — never *which*.
        var count: Int {
            [githubToken, anthropicKey, openAICompatibleKey, webhookSecret]
                .filter { !($0 ?? "").isEmpty }
                .count
        }

        private enum CodingKeys: String, CodingKey {
            case githubToken, anthropicKey, openAICompatibleKey, webhookSecret
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            githubToken = container.syncedOptional(.githubToken, as: String.self)
            anthropicKey = container.syncedOptional(.anthropicKey, as: String.self)
            openAICompatibleKey = container.syncedOptional(.openAICompatibleKey, as: String.self)
            webhookSecret = container.syncedOptional(.webhookSecret, as: String.self)
        }
    }

    // MARK: - Fields

    /// The document version.
    var v: Int
    /// Sweep cadence.
    var sync: SyncGroup
    /// Notification toggles.
    var notifications: NotificationGroup
    /// Agent-registry extensions.
    var agents: AgentsGroup
    /// Intelligence configuration, without the key.
    var intelligence: IntelligenceGroup
    /// Delegation configuration.
    var delegation: DelegationGroup
    /// Webhook configuration, without the signing secret.
    var automation: AutomationGroup
    /// Theme, inbox ordering, diff chrome.
    var appearance: AppearanceGroup
    /// Remembered review/merge dialog choices.
    var triage: TriageGroup
    /// Who the GitHub token belongs to.
    var account: AccountGroup
    /// The Keychain half.
    var secrets: Secrets

    /// Creates a document.
    init(
        v: Int = SyncedSettingsDocument.schemaVersion,
        sync: SyncGroup = SyncGroup(),
        notifications: NotificationGroup = NotificationGroup(),
        agents: AgentsGroup = AgentsGroup(),
        intelligence: IntelligenceGroup = IntelligenceGroup(),
        delegation: DelegationGroup = DelegationGroup(),
        automation: AutomationGroup = AutomationGroup(),
        appearance: AppearanceGroup = AppearanceGroup(),
        triage: TriageGroup = TriageGroup(),
        account: AccountGroup = AccountGroup(),
        secrets: Secrets = Secrets()
    ) {
        self.v = v
        self.sync = sync
        self.notifications = notifications
        self.agents = agents
        self.intelligence = intelligence
        self.delegation = delegation
        self.automation = automation
        self.appearance = appearance
        self.triage = triage
        self.account = account
        self.secrets = secrets
    }

    private enum CodingKeys: String, CodingKey {
        case v, sync, notifications, agents, intelligence, delegation, automation
        case appearance, triage, account, secrets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `v` is the one field that is *not* tolerated: a document with no version, or with a
        // version this build does not understand, is refused rather than half-applied.
        guard let version = container.syncedOptional(.v, as: Int.self) else {
            throw SettingsSyncError.malformedDocument
        }
        guard version == SyncedSettingsDocument.schemaVersion else {
            throw SettingsSyncError.unsupportedDocumentVersion(version)
        }
        v = version
        sync = container.syncedValue(.sync, default: SyncGroup())
        notifications = container.syncedValue(.notifications, default: NotificationGroup())
        agents = container.syncedValue(.agents, default: AgentsGroup())
        intelligence = container.syncedValue(.intelligence, default: IntelligenceGroup())
        delegation = container.syncedValue(.delegation, default: DelegationGroup())
        automation = container.syncedValue(.automation, default: AutomationGroup())
        appearance = container.syncedValue(.appearance, default: AppearanceGroup())
        triage = container.syncedValue(.triage, default: TriageGroup())
        account = container.syncedValue(.account, default: AccountGroup())
        secrets = container.syncedValue(.secrets, default: Secrets())
    }

    // MARK: - Bytes

    /// The one encoder documents are produced with.
    ///
    /// `sortedKeys` keeps the plaintext a pure function of the value, which is what lets the
    /// tests pin the shape; `withoutEscapingSlashes` keeps URLs and paths readable for a user
    /// who decrypts their own backup with a script.
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The plaintext bytes to seal.
    /// - Returns: The encoded document.
    /// - Throws: Whatever `JSONEncoder` throws.
    func canonicalJSON() throws -> Data {
        try SyncedSettingsDocument.canonicalEncoder().encode(self)
    }

    /// Decodes a document from sealed-then-opened plaintext.
    /// - Parameter data: The decrypted bytes.
    /// - Returns: The document.
    /// - Throws: ``SettingsSyncError/malformedDocument`` or
    ///   ``SettingsSyncError/unsupportedDocumentVersion(_:)``.
    static func decode(from data: Data) throws -> SyncedSettingsDocument {
        do {
            return try JSONDecoder().decode(SyncedSettingsDocument.self, from: data)
        } catch let error as SettingsSyncError {
            throw error
        } catch {
            throw SettingsSyncError.malformedDocument
        }
    }
}
