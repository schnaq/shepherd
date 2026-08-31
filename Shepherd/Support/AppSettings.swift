import Foundation
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
        self.openAICompatibleBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? ""
        self.openAICompatibleModel = defaults.string(forKey: Keys.openAIModel) ?? ""
        self.groupBy = Self.read(defaults, Keys.groupBy, default: InboxFacet.provenance)
        self.sortOrder = Self.read(defaults, Keys.sortOrder, default: InboxSortOrder.priority)
        self.diffFontSize = defaults.object(forKey: Keys.diffFontSize) as? Double ?? 13
        self.diffWrapsLines = defaults.object(forKey: Keys.diffWraps) as? Bool ?? false
        self.diffUsesInlineMode = defaults.object(forKey: Keys.diffInline) as? Bool ?? false
        self.accountLogin = defaults.string(forKey: Keys.accountLogin)
        self.accountAvatarURL = defaults.url(forKey: Keys.accountAvatar)
        self.accountAuthKind = Self.read(defaults, Keys.accountAuthKind, default: AuthKind.pat)
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

    // MARK: - Inbox

    /// Which facet the inbox is sectioned by.
    var groupBy: InboxFacet {
        didSet { Self.write(defaults, groupBy, Keys.groupBy) }
    }

    /// How rows are ordered inside a section.
    var sortOrder: InboxSortOrder {
        didSet { Self.write(defaults, sortOrder, Keys.sortOrder) }
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
        static let groupBy = "inbox.groupBy"
        static let sortOrder = "inbox.sortOrder"
        static let diffFontSize = "diff.fontSize"
        static let diffWraps = "diff.wraps"
        static let diffInline = "diff.inline"
        static let accountLogin = "account.login"
        static let accountAvatar = "account.avatarURL"
        static let accountAuthKind = "account.authKind"
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
