import Foundation
import GitHubKit
import Observation
import ShepherdCore
import SwiftUI

/// Which intelligence tiers the user has turned on (ADR 0007).
enum IntelligenceMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Heuristics only. The app is fully functional here — nothing may hard-depend on an LLM.
    case off
    /// Apple's on-device Foundation Model, when the machine has it.
    case onDevice
    /// On-device, plus a user-supplied cloud key for whole-PR analysis.
    case onDeviceAndCloud

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .onDevice: return String(localized: "On-device")
        case .onDeviceAndCloud: return String(localized: "On-device + API key")
        }
    }

    /// A one-line explanation shown under the picker.
    var explanation: String {
        switch self {
        case .off:
            return String(localized: "Only local heuristics: file priority, agent detection, risk hints.")
        case .onDevice:
            return String(localized: "Adds short summaries from Apple's on-device model. Nothing leaves the Mac.")
        case .onDeviceAndCloud:
            return String(localized: "Adds whole-pull-request analysis through the endpoint you configure below.")
        }
    }
}

/// Which cloud provider shape the BYOK tier talks to (ADR 0007).
enum CloudProviderKind: String, CaseIterable, Sendable, Codable, Identifiable {
    /// `api.anthropic.com/v1/messages`.
    case anthropic
    /// Any endpoint that speaks `POST {base}/chat/completions`.
    case openAICompatible

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .anthropic: return String(localized: "Anthropic")
        case .openAICompatible: return String(localized: "OpenAI-compatible")
        }
    }
}

/// How the inbox list is ordered inside its sections.
enum InboxSortOrder: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Review-blocking rows first, then failing CI, then recency.
    case priority
    /// Most recently updated first.
    case recentlyUpdated
    /// Oldest first — the "nothing must rot" order.
    case oldestFirst

    var id: String { rawValue }

    /// The label shown in the header control.
    var title: String {
        switch self {
        case .priority: return String(localized: "Priority")
        case .recentlyUpdated: return String(localized: "Recently updated")
        case .oldestFirst: return String(localized: "Oldest first")
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
///
/// Secrets never live here (ADR 0004/0006): API keys and GitHub tokens are Keychain-only, and
/// this type stores just the non-secret shape of the configuration.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Creates the settings store.
    /// - Parameter defaults: The backing store. Injectable for tests and previews.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance = Self.read(defaults, Keys.appearance, default: AppearanceSetting.system)
        self.sweepIntervalMinutes = defaults.object(forKey: Keys.sweepIntervalMinutes) as? Double ?? 2
        self.notifyOnReviewRequest = defaults.object(forKey: Keys.notifyReviewRequest) as? Bool ?? true
        self.notifyOnChecksFailed = defaults.object(forKey: Keys.notifyChecksFailed) as? Bool ?? true
        self.notifyOnDraftConflict = defaults.object(forKey: Keys.notifyDraftConflict) as? Bool ?? true
        self.intelligenceMode = Self.read(defaults, Keys.intelligenceMode, default: IntelligenceMode.off)
        self.cloudProviderKind = Self.read(defaults, Keys.cloudProviderKind, default: CloudProviderKind.anthropic)
        self.anthropicModel = defaults.string(forKey: Keys.anthropicModel) ?? "claude-haiku-4-5"
        let storedBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? ""
        self.openAICompatibleBaseURL = storedBaseURL
        self.openAICompatibleModel = defaults.string(forKey: Keys.openAIModel) ?? ""
        // A configuration written before presets existed has no stored preset; deriving it from
        // the base URL means such an install shows "Konduit (EU)" rather than "Custom".
        self.openAICompatiblePreset = Self.read(
            defaults,
            Keys.openAIPreset,
            default: IntelligenceEndpointPreset.matching(baseURL: storedBaseURL)
        )
        self.groupBy = Self.read(defaults, Keys.groupBy, default: InboxFacet.provenance)
        self.sortOrder = Self.read(defaults, Keys.sortOrder, default: InboxSortOrder.priority)
        self.defaultMergeMethod = Self.read(
            defaults,
            Keys.defaultMergeMethod,
            default: MergeMethod.squash
        )
        self.diffFontSize = defaults.object(forKey: Keys.diffFontSize) as? Double ?? 13
        self.diffWrapsLines = defaults.object(forKey: Keys.diffWraps) as? Bool ?? false
        self.diffUsesInlineMode = defaults.object(forKey: Keys.diffInline) as? Bool ?? false
        self.accountLogin = defaults.string(forKey: Keys.accountLogin)
        self.accountAvatarURL = defaults.url(forKey: Keys.accountAvatar)
        self.accountAuthKind = Self.read(defaults, Keys.accountAuthKind, default: AuthKind.pat)
        self.agentCLI = Self.readJSON(
            defaults,
            Keys.agentCLI,
            default: AgentCLIConfiguration()
        )
        self.localCheckouts = defaults.dictionary(forKey: Keys.localCheckouts) as? [String: String]
            ?? [:]
        self.webhooksEnabled = defaults.object(forKey: Keys.webhookEnabled) as? Bool ?? false
        self.webhookURL = defaults.string(forKey: Keys.webhookURL) ?? ""
        // A fresh install subscribes to everything, because the enable toggle is what actually
        // gates delivery — an install that switches webhooks on should not then have to tick
        // four boxes before anything arrives.
        if let stored = defaults.array(forKey: Keys.webhookEvents) as? [String] {
            self.webhookEvents = Set(stored.compactMap(WebhookEventKind.init(rawValue:)))
                .intersection(WebhookEventKind.userSelectable)
        } else {
            self.webhookEvents = Set(WebhookEventKind.userSelectable)
        }
        self.settingsSyncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? false
        self.settingsSyncEndpoint = defaults.string(forKey: Keys.syncEndpoint) ?? ""
        self.settingsSyncBucket = defaults.string(forKey: Keys.syncBucket) ?? ""
        self.settingsSyncRegion = defaults.string(forKey: Keys.syncRegion) ?? ""
        self.settingsSyncKeyPrefix = defaults.string(forKey: Keys.syncPrefix)
            ?? S3ObjectLocation.defaultPrefix
        self.settingsSyncAddressing = Self.read(
            defaults,
            Keys.syncAddressing,
            default: S3AddressingStyle.path
        )
        self.settingsSyncRemembersPassphrase = defaults
            .object(forKey: Keys.syncRemembersPassphrase) as? Bool ?? false
        self.settingsSyncLastUploadAt = defaults.object(forKey: Keys.syncLastUpload) as? Date
        self.settingsSyncLastDownloadAt = defaults.object(forKey: Keys.syncLastDownload) as? Date
    }

    // MARK: - Appearance

    /// Dark, light or follow the system.
    var appearance: AppearanceSetting {
        didSet { Self.write(defaults, appearance, Keys.appearance) }
    }

    // MARK: - Sync

    /// How often the inbox sweep runs, in minutes (1…10).
    var sweepIntervalMinutes: Double {
        didSet { defaults.set(sweepIntervalMinutes, forKey: Keys.sweepIntervalMinutes) }
    }

    /// Notify when a new review request arrives.
    var notifyOnReviewRequest: Bool {
        didSet { defaults.set(notifyOnReviewRequest, forKey: Keys.notifyReviewRequest) }
    }

    /// Notify when CI fails on one of the user's own pull requests.
    var notifyOnChecksFailed: Bool {
        didSet { defaults.set(notifyOnChecksFailed, forKey: Keys.notifyChecksFailed) }
    }

    /// Notify when a queued review could not be submitted.
    var notifyOnDraftConflict: Bool {
        didSet { defaults.set(notifyOnDraftConflict, forKey: Keys.notifyDraftConflict) }
    }

    // MARK: - Intelligence

    /// Which tiers are enabled.
    var intelligenceMode: IntelligenceMode {
        didSet { Self.write(defaults, intelligenceMode, Keys.intelligenceMode) }
    }

    /// Which cloud shape the BYOK tier uses.
    var cloudProviderKind: CloudProviderKind {
        didSet { Self.write(defaults, cloudProviderKind, Keys.cloudProviderKind) }
    }

    /// The Anthropic model id.
    var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: Keys.anthropicModel) }
    }

    /// The base URL of the OpenAI-compatible endpoint, e.g. `https://api.konduit.eu/v1`.
    var openAICompatibleBaseURL: String {
        didSet { defaults.set(openAICompatibleBaseURL, forKey: Keys.openAIBaseURL) }
    }

    /// The model name to send to the OpenAI-compatible endpoint.
    var openAICompatibleModel: String {
        didSet { defaults.set(openAICompatibleModel, forKey: Keys.openAIModel) }
    }

    /// Which known endpoint the OpenAI-compatible configuration came from.
    ///
    /// Purely a UI convenience — the intelligence layer reads the base URL, never this — but it
    /// is remembered so Settings can keep showing the endpoint's note and key link.
    var openAICompatiblePreset: IntelligenceEndpointPreset {
        didSet { Self.write(defaults, openAICompatiblePreset, Keys.openAIPreset) }
    }

    /// Selects an endpoint preset and fills in the base URL that belongs to it.
    ///
    /// ``IntelligenceEndpointPreset/custom`` keeps whatever URL is already in the field, so
    /// switching to it never erases a hand-typed endpoint.
    /// - Parameter preset: The preset the user picked.
    func applyEndpointPreset(_ preset: IntelligenceEndpointPreset) {
        openAICompatiblePreset = preset
        if let baseURL = preset.baseURL {
            openAICompatibleBaseURL = baseURL
        }
    }

    // MARK: - Inbox

    /// Which facet the inbox is sectioned by.
    var groupBy: InboxFacet {
        didSet { Self.write(defaults, groupBy, Keys.groupBy) }
    }

    /// How rows are ordered inside a section.
    var sortOrder: InboxSortOrder {
        didSet { Self.write(defaults, sortOrder, Keys.sortOrder) }
    }

    /// The merge method the merge sheet and the bulk-triage dialog open on.
    ///
    /// Written by both of them, so it is "the last method you chose" rather than a preference
    /// buried in Settings — the choice a merge dialog needs is nearly always the previous one
    /// (ADR 0015).
    var defaultMergeMethod: MergeMethod {
        didSet { Self.write(defaults, defaultMergeMethod, Keys.defaultMergeMethod) }
    }

    // MARK: - Diff viewer

    /// Monaco's font size.
    var diffFontSize: Double {
        didSet { defaults.set(diffFontSize, forKey: Keys.diffFontSize) }
    }

    /// Whether long lines wrap.
    var diffWrapsLines: Bool {
        didSet { defaults.set(diffWrapsLines, forKey: Keys.diffWraps) }
    }

    /// Whether the diff is shown inline rather than side by side.
    var diffUsesInlineMode: Bool {
        didSet { defaults.set(diffUsesInlineMode, forKey: Keys.diffInline) }
    }

    // MARK: - Delegation (ADR 0011)

    /// How the local agent CLI is invoked.
    ///
    /// No secret lives here: the CLI carries its own authentication and Shepherd never
    /// collects, stores or injects any (ADR 0011).
    var agentCLI: AgentCLIConfiguration {
        didSet { Self.writeJSON(defaults, agentCLI, Keys.agentCLI) }
    }

    /// Repository full name (`owner/name`) → the path of the user's local clone.
    ///
    /// Delegation needs a checkout to build a worktree from; without one the sheet refuses and
    /// points at this setting.
    var localCheckouts: [String: String] {
        didSet { defaults.set(localCheckouts, forKey: Keys.localCheckouts) }
    }

    /// The local clone configured for a repository, if any.
    /// - Parameter repo: The repository.
    /// - Returns: The checkout directory, or `nil` when none is configured.
    func localCheckoutURL(for repo: RepoRef) -> URL? {
        guard let path = localCheckouts[repo.fullName]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Sets (or clears) the local clone for a repository.
    /// - Parameters:
    ///   - url: The checkout directory, or `nil` to forget it.
    ///   - fullName: The repository's `owner/name`.
    func setLocalCheckout(_ url: URL?, forRepoNamed fullName: String) {
        var updated = localCheckouts
        if let url {
            updated[fullName] = url.path
        } else {
            updated.removeValue(forKey: fullName)
        }
        localCheckouts = updated
    }

    // MARK: - Automation (ADR 0012)

    /// Whether Shepherd posts events to the configured webhook URL.
    ///
    /// Off on a fresh install, and the only thing that lets any outbound request happen: with
    /// this false, no event ever leaves the Mac.
    var webhooksEnabled: Bool {
        didSet { defaults.set(webhooksEnabled, forKey: Keys.webhookEnabled) }
    }

    /// The webhook URL, e.g. an n8n Webhook node's production URL.
    ///
    /// Stored as typed; ``WebhookConfiguration/destination(_:)`` is what decides whether it is
    /// usable. No secret lives here — the signing secret is Keychain-only.
    var webhookURL: String {
        didSet { defaults.set(webhookURL, forKey: Keys.webhookURL) }
    }

    /// Which events are subscribed to.
    var webhookEvents: Set<WebhookEventKind> {
        didSet {
            defaults.set(
                webhookEvents.map(\.rawValue).sorted(),
                forKey: Keys.webhookEvents
            )
        }
    }

    /// Subscribes to (or unsubscribes from) one event kind.
    /// - Parameters:
    ///   - kind: The event kind.
    ///   - isOn: Whether it should be delivered.
    func setWebhookEvent(_ kind: WebhookEventKind, isOn: Bool) {
        var updated = webhookEvents
        if isOn {
            updated.insert(kind)
        } else {
            updated.remove(kind)
        }
        webhookEvents = updated
    }

    // MARK: - Encrypted settings sync (ADR 0014)

    /// Whether the encrypted settings-sync section is in use.
    ///
    /// Off on a fresh install, and the only thing that lets the app talk to a bucket at all:
    /// with this false, no request is ever built, exactly as ``webhooksEnabled`` gates webhooks.
    var settingsSyncEnabled: Bool {
        didSet { defaults.set(settingsSyncEnabled, forKey: Keys.syncEnabled) }
    }

    /// The S3-compatible endpoint, e.g. `https://object.storage.eu01.onstackit.cloud`.
    var settingsSyncEndpoint: String {
        didSet { defaults.set(settingsSyncEndpoint, forKey: Keys.syncEndpoint) }
    }

    /// The bucket the settings object lives in.
    var settingsSyncBucket: String {
        didSet { defaults.set(settingsSyncBucket, forKey: Keys.syncBucket) }
    }

    /// The signing region, e.g. `eu01`.
    var settingsSyncRegion: String {
        didSet { defaults.set(settingsSyncRegion, forKey: Keys.syncRegion) }
    }

    /// The key prefix the object is stored under; the object itself is always
    /// ``S3ObjectLocation/objectName``.
    var settingsSyncKeyPrefix: String {
        didSet { defaults.set(settingsSyncKeyPrefix, forKey: Keys.syncPrefix) }
    }

    /// Whether the bucket is addressed path-style or virtual-hosted-style.
    var settingsSyncAddressing: S3AddressingStyle {
        didSet { Self.write(defaults, settingsSyncAddressing, Keys.syncAddressing) }
    }

    /// Whether the passphrase may be kept in the Keychain on this Mac.
    ///
    /// Opt-in, and the passphrase itself is *never* written here — only this flag is. Turning it
    /// off deletes the stored passphrase (``SettingsSyncModel/savePassphrase(context:)``).
    var settingsSyncRemembersPassphrase: Bool {
        didSet { defaults.set(settingsSyncRemembersPassphrase, forKey: Keys.syncRemembersPassphrase) }
    }

    /// When this Mac last uploaded, for the status line.
    var settingsSyncLastUploadAt: Date? {
        didSet { defaults.set(settingsSyncLastUploadAt, forKey: Keys.syncLastUpload) }
    }

    /// When this Mac last applied a download, for the status line.
    var settingsSyncLastDownloadAt: Date? {
        didSet { defaults.set(settingsSyncLastDownloadAt, forKey: Keys.syncLastDownload) }
    }

    /// The validated object location, or `nil` while the fields are incomplete.
    var settingsSyncLocation: S3ObjectLocation? {
        try? S3ObjectLocation.resolve(
            endpointText: settingsSyncEndpoint,
            bucket: settingsSyncBucket,
            region: settingsSyncRegion,
            prefix: settingsSyncKeyPrefix,
            addressing: settingsSyncAddressing
        )
    }

    // MARK: - Account (never the token — ADR 0004)

    /// The login of the signed-in account, if any.
    var accountLogin: String? {
        didSet { defaults.set(accountLogin, forKey: Keys.accountLogin) }
    }

    /// The signed-in account's avatar.
    var accountAvatarURL: URL? {
        didSet { defaults.set(accountAvatarURL, forKey: Keys.accountAvatar) }
    }

    /// How the signed-in account authenticates.
    var accountAuthKind: AuthKind {
        didSet { Self.write(defaults, accountAuthKind, Keys.accountAuthKind) }
    }

    /// The signed-in account, reassembled from the stored fields.
    var account: Account? {
        guard let accountLogin else { return nil }
        return Account(login: accountLogin, avatarURL: accountAvatarURL, authKind: accountAuthKind)
    }

    /// Records a successful sign-in.
    /// - Parameter account: The account that signed in.
    func store(account: Account) {
        accountLogin = account.login
        accountAvatarURL = account.avatarURL
        accountAuthKind = account.authKind
    }

    /// Forgets the signed-in account (the token is deleted separately from the Keychain).
    func clearAccount() {
        accountLogin = nil
        accountAvatarURL = nil
    }

    // MARK: - Storage plumbing

    private enum Keys {
        static let appearance = "appearance"
        static let sweepIntervalMinutes = "sync.sweepIntervalMinutes"
        static let notifyReviewRequest = "notify.reviewRequest"
        static let notifyChecksFailed = "notify.checksFailed"
        static let notifyDraftConflict = "notify.draftConflict"
        static let intelligenceMode = "intelligence.mode"
        static let cloudProviderKind = "intelligence.cloudKind"
        static let anthropicModel = "intelligence.anthropic.model"
        static let openAIBaseURL = "intelligence.openaiCompatible.baseURL"
        static let openAIModel = "intelligence.openaiCompatible.model"
        static let openAIPreset = "intelligence.openaiCompatible.preset"
        static let groupBy = "inbox.groupBy"
        static let sortOrder = "inbox.sortOrder"
        static let defaultMergeMethod = "review.defaultMergeMethod"
        static let diffFontSize = "diff.fontSize"
        static let diffWraps = "diff.wraps"
        static let diffInline = "diff.inline"
        static let accountLogin = "account.login"
        static let accountAvatar = "account.avatarURL"
        static let accountAuthKind = "account.authKind"
        static let agentCLI = "delegation.agentCLI"
        static let localCheckouts = "delegation.localCheckouts"
        static let webhookEnabled = "automation.webhook.enabled"
        static let webhookURL = "automation.webhook.url"
        static let webhookEvents = "automation.webhook.events"
        static let syncEnabled = "settingsSync.enabled"
        static let syncEndpoint = "settingsSync.endpoint"
        static let syncBucket = "settingsSync.bucket"
        static let syncRegion = "settingsSync.region"
        static let syncPrefix = "settingsSync.keyPrefix"
        static let syncAddressing = "settingsSync.addressing"
        static let syncRemembersPassphrase = "settingsSync.remembersPassphrase"
        static let syncLastUpload = "settingsSync.lastUploadAt"
        static let syncLastDownload = "settingsSync.lastDownloadAt"
    }

    private static func readJSON<Value: Decodable>(
        _ defaults: UserDefaults,
        _ key: String,
        default fallback: Value
    ) -> Value {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else { return fallback }
        return value
    }

    private static func writeJSON<Value: Encodable>(
        _ defaults: UserDefaults,
        _ value: Value,
        _ key: String
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func read<Value: RawRepresentable>(
        _ defaults: UserDefaults,
        _ key: String,
        default fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = Value(rawValue: raw) else {
            return fallback
        }
        return value
    }

    private static func write<Value: RawRepresentable>(
        _ defaults: UserDefaults,
        _ value: Value,
        _ key: String
    ) where Value.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }
}
