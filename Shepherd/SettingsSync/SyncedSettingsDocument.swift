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

    /// When the local morning digest is delivered.
    ///
    /// The *schedule* travels; **when this Mac last delivered one does not**. That date is device
    /// state in the same category as the outbox and the auto-delegation ledger: sharing an "already
    /// delivered today" between two Macs would mean whichever one woke up first silenced the other,
    /// and a user who reviews from a laptop and a desktop wants the digest on whichever one they
    /// open. Carrying the schedule itself is what CONTRIBUTING.md asks of every setting, and it is
    /// the half worth carrying — nine o'clock on weekdays is a preference, not a machine fact.
    struct DigestGroup: Codable, Sendable, Equatable {
        /// The delivery schedule, including its opt-in flag.
        var schedule: DigestSchedule

        /// Creates the group.
        /// - Parameter schedule: The delivery schedule.
        init(schedule: DigestSchedule = DigestSchedule()) {
            self.schedule = schedule
        }

        private enum CodingKeys: String, CodingKey {
            case schedule
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schedule = container.syncedValue(.schedule, default: DigestSchedule())
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
        /// The OpenAI-compatible base URL.
        ///
        /// Which *preset* that URL belongs to does not travel and is not stored anywhere: it is
        /// derived from the URL on arrival (``AppSettings/openAICompatiblePreset``), so the two
        /// Macs cannot end up disagreeing about the name of the endpoint they both point at. An
        /// upload from a build that still wrote the field decodes fine — the tolerant decoder
        /// ignores keys it does not know — so the schema stays at `"v": 1`.
        var openAICompatibleBaseURL: String
        /// The model name sent to the OpenAI-compatible endpoint.
        var openAICompatibleModel: String
        /// ISO 3166-1 alpha-2 countries the OpenAI-compatible endpoint may serve a request from.
        ///
        /// It travels for the reason the base URL does: it is part of *what the request is*, so
        /// two Macs that disagree about it would send different requests to the same endpoint —
        /// and one of them would be sending a prompt to a country its owner asked it to stay out
        /// of. Empty by default, and an empty policy is never put on the wire (plan §3.K).
        var openAICompatibleSovereigntyCountries: [String]
        /// Whether that endpoint must pick an operator that retains neither prompt nor answer.
        var openAICompatibleZeroRetention: Bool
        /// Whether the on-device classifier may give each pull request a kind and a risk.
        ///
        /// A field of this group rather than of ``SearchGroup``, even though it is as on-device
        /// as the search index is, because it is the one on-device feature that *needs a model*:
        /// with ``mode`` off there is nothing to ask, so the two settings are read together and
        /// belong together. What travels is the switch; the verdicts do not — they are derived
        /// from local rows and re-derived when the pull request changes, exactly like the search
        /// vectors (ADR 0019's argument, applied to a second cache).
        var structuredTriageEnabled: Bool

        /// Creates the group.
        init(
            mode: IntelligenceMode = .off,
            cloudProviderKind: CloudProviderKind = .anthropic,
            anthropicModel: String = "",
            openAICompatibleBaseURL: String = "",
            openAICompatibleModel: String = "",
            openAICompatibleSovereigntyCountries: [String] = [],
            openAICompatibleZeroRetention: Bool = false,
            structuredTriageEnabled: Bool = true
        ) {
            self.mode = mode
            self.cloudProviderKind = cloudProviderKind
            self.anthropicModel = anthropicModel
            self.openAICompatibleBaseURL = openAICompatibleBaseURL
            self.openAICompatibleModel = openAICompatibleModel
            self.openAICompatibleSovereigntyCountries = openAICompatibleSovereigntyCountries
            self.openAICompatibleZeroRetention = openAICompatibleZeroRetention
            self.structuredTriageEnabled = structuredTriageEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case mode, cloudProviderKind, anthropicModel
            case openAICompatibleBaseURL, openAICompatibleModel
            case openAICompatibleSovereigntyCountries, openAICompatibleZeroRetention
            case structuredTriageEnabled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = container.syncedValue(.mode, default: IntelligenceMode.off)
            cloudProviderKind = container.syncedValue(
                .cloudProviderKind,
                default: CloudProviderKind.anthropic
            )
            anthropicModel = container.syncedValue(.anthropicModel, default: "")
            openAICompatibleBaseURL = container.syncedValue(.openAICompatibleBaseURL, default: "")
            openAICompatibleModel = container.syncedValue(.openAICompatibleModel, default: "")
            // Both default to "no policy", which is what a document written before the fields
            // existed means: an absent country list must not read as a constraint, and an absent
            // zero-retention flag must not read as one either (plan §3.K).
            openAICompatibleSovereigntyCountries = container.syncedValue(
                .openAICompatibleSovereigntyCountries,
                default: [String]()
            )
            openAICompatibleZeroRetention = container.syncedValue(
                .openAICompatibleZeroRetention,
                default: false
            )
            // Defaults to `true`, matching ``AppSettings/structuredTriageEnabled``: an upload
            // from a build that predates this field must not read as "the user switched it off".
            structuredTriageEnabled = container.syncedValue(
                .structuredTriageEnabled,
                default: true
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

    /// The rules that let Shepherd merge a pull request on its own (ADR 0018).
    ///
    /// A group of its own rather than a field of ``AutomationGroup``: that group is the webhook's
    /// non-secret configuration, and a reader should not have to know that "automation" happens to
    /// hold two unrelated features. The *rules* travel, exactly as auto-delegation's do; the
    /// ledger — which is also the audit log — does not, because "this Mac already queued that
    /// merge" is one machine's automation state and a shared copy would let one Mac silence the
    /// other's deduplication (ADR 0014, ADR 0016).
    struct AutoMergeGroup: Codable, Sendable, Equatable {
        /// The opt-in rule set.
        var rules: AutoMergeRules

        /// Creates the group.
        /// - Parameter rules: The rule set.
        init(rules: AutoMergeRules = AutoMergeRules()) {
            self.rules = rules
        }

        private enum CodingKeys: String, CodingKey {
            case rules
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rules = container.syncedValue(.rules, default: AutoMergeRules())
        }
    }

    /// Whether the on-device ⌘K search index is kept (ADR 0019).
    ///
    /// A group of its own rather than a field of ``IntelligenceGroup``, and the reason is the one
    /// ADR 0019 fixes in place: this feature never talks to a provider. `intelligence` carries a
    /// mode, a provider kind, an endpoint and a model — none of which this switch has or may ever
    /// have — and putting a purely on-device toggle inside the group that decides *where requests
    /// go* would invite exactly the confusion the ADR exists to prevent.
    ///
    /// The **switch** travels, because "I do not want an index" is a preference and belongs on
    /// both Macs. The **index** does not, for the same reason the auto-merge ledger does not
    /// (ADR 0018): it is device state, it is rebuildable from local rows in seconds, and a bucket
    /// object carrying a megabyte of embeddings per Mac would be absurd.
    ///
    /// The Spotlight export (ADR 0021) is the group's second field rather than a group of its own,
    /// because it is the same preference asked about a different index: "how do I want to find a
    /// pull request". Both switches are on the same Settings card, both are on by default, and
    /// both share the property that makes them safe to carry — the thing they govern is derived
    /// from local rows and is rebuilt, not restored. What travels is the two flags; neither the
    /// vectors nor the Spotlight items do, and the second one *cannot*: Spotlight's index belongs
    /// to the Mac it is on.
    struct SearchGroup: Codable, Sendable, Equatable {
        /// Whether the semantic index is kept on this Mac.
        var isSemanticIndexEnabled: Bool
        /// Whether the inbox's pull requests are exported to Spotlight on this Mac.
        var isSpotlightExportEnabled: Bool

        /// Creates the group.
        /// - Parameters:
        ///   - isSemanticIndexEnabled: The search-index opt-out flag.
        ///   - isSpotlightExportEnabled: The Spotlight-export opt-out flag.
        init(isSemanticIndexEnabled: Bool = true, isSpotlightExportEnabled: Bool = true) {
            self.isSemanticIndexEnabled = isSemanticIndexEnabled
            self.isSpotlightExportEnabled = isSpotlightExportEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case isSemanticIndexEnabled
            case isSpotlightExportEnabled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Defaults to `true`, matching ``AppSettings/semanticSearchEnabled``: a document from
            // a build that predates this field must not read as "the user switched it off".
            isSemanticIndexEnabled = container.syncedValue(.isSemanticIndexEnabled, default: true)
            // The same argument, one ADR later (0021).
            isSpotlightExportEnabled = container.syncedValue(
                .isSpotlightExportEnabled,
                default: true
            )
        }
    }

    /// Theme, inbox ordering, diff-viewer chrome and the menu-bar item.
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
        /// Whether the menu-bar quick inbox is inserted.
        ///
        /// The one field in this document that defaults to *true*: the item is on out of the box,
        /// so a document written before the quick inbox existed has to leave it on. Every other
        /// flag here is an opt-in, where an absent key correctly means "off".
        var showsMenuBarExtra: Bool

        /// Creates the group.
        init(
            appearance: AppearanceSetting = .system,
            inboxGroupBy: InboxFacet = .provenance,
            inboxSortOrder: InboxSortOrder = .priority,
            diffFontSize: Double = 13,
            diffWrapsLines: Bool = false,
            diffUsesInlineMode: Bool = false,
            showsMenuBarExtra: Bool = true
        ) {
            self.appearance = appearance
            self.inboxGroupBy = inboxGroupBy
            self.inboxSortOrder = inboxSortOrder
            self.diffFontSize = diffFontSize
            self.diffWrapsLines = diffWrapsLines
            self.diffUsesInlineMode = diffUsesInlineMode
            self.showsMenuBarExtra = showsMenuBarExtra
        }

        private enum CodingKeys: String, CodingKey {
            case appearance, inboxGroupBy, inboxSortOrder
            case diffFontSize, diffWrapsLines, diffUsesInlineMode
            case showsMenuBarExtra
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
            showsMenuBarExtra = container.syncedValue(.showsMenuBarExtra, default: true)
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

    /// The reusable review text the composer offers: saved replies and per-repo templates.
    ///
    /// A settings group of its own rather than a corner of ``TriageGroup``, which holds *remembered
    /// choices* (the last merge method). These are authored content: the user wrote them, they can
    /// be long, and they are exactly the sort of thing that is painful to retype on a second Mac —
    /// which makes them one of the better arguments for the whole sync feature.
    ///
    /// Both lists travel as arrays, so their order travels with them: it is the order of the insert
    /// menu, and for templates it is also the last tie-breaker of
    /// ``ShepherdCore/ReviewTemplate/matching(_:repo:)``. A list that arrives unreadable — a newer
    /// build changed the element shape — falls back to empty rather than costing the document.
    struct ComposerGroup: Codable, Sendable, Equatable {
        /// The named, reusable comment bodies.
        var savedReplies: [SavedReply]
        /// The per-repository summary templates.
        var reviewTemplates: [ReviewTemplate]

        /// Creates the group.
        /// - Parameters:
        ///   - savedReplies: The saved replies, in the user's order.
        ///   - reviewTemplates: The templates, in the user's order.
        init(savedReplies: [SavedReply] = [], reviewTemplates: [ReviewTemplate] = []) {
            self.savedReplies = savedReplies
            self.reviewTemplates = reviewTemplates
        }

        private enum CodingKeys: String, CodingKey {
            case savedReplies, reviewTemplates
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            savedReplies = container.syncedValue(.savedReplies, default: [])
            reviewTemplates = container.syncedValue(.reviewTemplates, default: [])
        }
    }

    /// Whether local crash and hang reports are kept on the Mac (ADR 0017).
    ///
    /// The *flag* travels; the reports never do. A diagnostic report is machine-local by
    /// definition — it describes one crash of one build on one Mac — and it is not a setting, so
    /// it belongs in the same category as the outbox and the auto-delegation ledger: state of one
    /// machine, deliberately left out of the document. Carrying the opt-in itself is what
    /// CONTRIBUTING.md asks of every setting, and it is also the useful half: a user who wants
    /// diagnostics wants them on every Mac they review from.
    struct DiagnosticsGroup: Codable, Sendable, Equatable {
        /// Whether the MetricKit subscriber is registered.
        var isEnabled: Bool

        /// Creates the group.
        /// - Parameter isEnabled: Whether diagnostics are kept.
        init(isEnabled: Bool = false) {
            self.isEnabled = isEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = container.syncedValue(.isEnabled, default: false)
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
    /// The morning digest's delivery schedule.
    var digest: DigestGroup
    /// Agent-registry extensions.
    var agents: AgentsGroup
    /// Intelligence configuration, without the key.
    var intelligence: IntelligenceGroup
    /// Delegation configuration.
    var delegation: DelegationGroup
    /// Webhook configuration, without the signing secret.
    var automation: AutomationGroup
    /// The opt-in automatic-merge rules.
    var autoMerge: AutoMergeGroup
    /// Whether the on-device search index is kept.
    var search: SearchGroup
    /// Theme, inbox ordering, diff chrome.
    var appearance: AppearanceGroup
    /// Remembered review/merge dialog choices.
    var triage: TriageGroup
    /// Saved replies and per-repository review templates.
    var composer: ComposerGroup
    /// Whether local crash and hang reports are kept.
    var diagnostics: DiagnosticsGroup
    /// Who the GitHub token belongs to.
    var account: AccountGroup
    /// The Keychain half.
    var secrets: Secrets

    /// Creates a document.
    init(
        v: Int = SyncedSettingsDocument.schemaVersion,
        sync: SyncGroup = SyncGroup(),
        notifications: NotificationGroup = NotificationGroup(),
        digest: DigestGroup = DigestGroup(),
        agents: AgentsGroup = AgentsGroup(),
        intelligence: IntelligenceGroup = IntelligenceGroup(),
        delegation: DelegationGroup = DelegationGroup(),
        automation: AutomationGroup = AutomationGroup(),
        autoMerge: AutoMergeGroup = AutoMergeGroup(),
        search: SearchGroup = SearchGroup(),
        appearance: AppearanceGroup = AppearanceGroup(),
        triage: TriageGroup = TriageGroup(),
        composer: ComposerGroup = ComposerGroup(),
        diagnostics: DiagnosticsGroup = DiagnosticsGroup(),
        account: AccountGroup = AccountGroup(),
        secrets: Secrets = Secrets()
    ) {
        self.v = v
        self.sync = sync
        self.notifications = notifications
        self.digest = digest
        self.agents = agents
        self.intelligence = intelligence
        self.delegation = delegation
        self.automation = automation
        self.autoMerge = autoMerge
        self.search = search
        self.appearance = appearance
        self.triage = triage
        self.composer = composer
        self.diagnostics = diagnostics
        self.account = account
        self.secrets = secrets
    }

    private enum CodingKeys: String, CodingKey {
        case v, sync, notifications, digest, agents, intelligence, delegation, automation
        case autoMerge
        case search
        case appearance, triage, composer, diagnostics, account, secrets
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
        digest = container.syncedValue(.digest, default: DigestGroup())
        agents = container.syncedValue(.agents, default: AgentsGroup())
        intelligence = container.syncedValue(.intelligence, default: IntelligenceGroup())
        delegation = container.syncedValue(.delegation, default: DelegationGroup())
        automation = container.syncedValue(.automation, default: AutomationGroup())
        autoMerge = container.syncedValue(.autoMerge, default: AutoMergeGroup())
        search = container.syncedValue(.search, default: SearchGroup())
        appearance = container.syncedValue(.appearance, default: AppearanceGroup())
        triage = container.syncedValue(.triage, default: TriageGroup())
        composer = container.syncedValue(.composer, default: ComposerGroup())
        diagnostics = container.syncedValue(.diagnostics, default: DiagnosticsGroup())
        account = container.syncedValue(.account, default: AccountGroup())
        secrets = container.syncedValue(.secrets, default: Secrets())
    }

    // MARK: - Bytes

    /// The plaintext bytes to seal.
    ///
    /// ``CanonicalJSON`` keeps the plaintext a pure function of the value, which is what lets the
    /// tests pin the shape, and keeps URLs readable for a user who decrypts their own backup.
    /// - Returns: The encoded document.
    /// - Throws: Whatever `JSONEncoder` throws.
    func canonicalJSON() throws -> Data {
        try CanonicalJSON.encoder().encode(self)
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
