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
        self.showsMenuBarExtra = defaults.object(forKey: Keys.showsMenuBarExtra) as? Bool ?? true
        self.sweepIntervalMinutes = defaults.object(forKey: Keys.sweepIntervalMinutes) as? Double ?? 2
        self.notifyOnReviewRequest = defaults.object(forKey: Keys.notifyReviewRequest) as? Bool ?? true
        self.notifyOnChecksFailed = defaults.object(forKey: Keys.notifyChecksFailed) as? Bool ?? true
        self.notifyOnDraftConflict = defaults.object(forKey: Keys.notifyDraftConflict) as? Bool ?? true
        self.digest = Self.readJSON(defaults, Keys.digest, default: DigestSchedule())
        self.digestLastDeliveredAt = defaults.object(forKey: Keys.digestLastDeliveredAt) as? Date
        self.intelligenceMode = Self.read(defaults, Keys.intelligenceMode, default: IntelligenceMode.off)
        self.cloudProviderKind = Self.read(defaults, Keys.cloudProviderKind, default: CloudProviderKind.anthropic)
        self.anthropicModel = defaults.string(forKey: Keys.anthropicModel) ?? "claude-haiku-4-5"
        self.openAICompatibleBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? ""
        self.openAICompatibleModel = defaults.string(forKey: Keys.openAIModel) ?? ""
        self.openAICompatibleSovereigntyCountries = defaults
            .stringArray(forKey: Keys.openAISovereigntyCountries) ?? []
        self.openAICompatibleZeroRetention = defaults
            .object(forKey: Keys.openAIZeroRetention) as? Bool ?? false
        self.structuredTriageEnabled = defaults
            .object(forKey: Keys.structuredTriage) as? Bool ?? true
        self.groupBy = Self.read(defaults, Keys.groupBy, default: InboxFacet.provenance)
        self.sortOrder = Self.read(defaults, Keys.sortOrder, default: InboxSortOrder.priority)
        self.defaultMergeMethod = Self.read(
            defaults,
            Keys.defaultMergeMethod,
            default: MergeMethod.squash
        )
        self.opensAgentPullRequestsOnConversation = defaults
            .object(forKey: Keys.opensAgentOnConversation) as? Bool ?? true
        self.deletesBranchAfterMerge = defaults
            .object(forKey: Keys.deletesBranchAfterMerge) as? Bool ?? false
        self.diffFontSize = defaults.object(forKey: Keys.diffFontSize) as? Double ?? 13
        self.diffWrapsLines = defaults.object(forKey: Keys.diffWraps) as? Bool ?? false
        self.diffUsesInlineMode = defaults.object(forKey: Keys.diffInline) as? Bool ?? false
        self.diffRenderer = Self.read(defaults, Keys.diffRenderer, default: DiffRenderer.automatic)
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
        self.autoDelegation = Self.readJSON(
            defaults,
            Keys.autoDelegation,
            default: AutoDelegationRules()
        )
        self.autoMerge = Self.readJSON(
            defaults,
            Keys.autoMerge,
            default: AutoMergeRules()
        )
        self.trustLaneMaxFiles = defaults.object(forKey: Keys.trustLaneMaxFiles) as? Int
            ?? TrustLaneConfiguration.default.maxFiles
        self.trustLaneMaxChangedLines = defaults
            .object(forKey: Keys.trustLaneMaxChangedLines) as? Int
            ?? TrustLaneConfiguration.default.maxChangedLines
        self.hasDismissedTrackRecordNotice = defaults
            .object(forKey: Keys.trackRecordNoticeDismissed) as? Bool ?? false
        self.semanticSearchEnabled = defaults
            .object(forKey: Keys.semanticSearch) as? Bool ?? true
        self.spotlightExportEnabled = defaults
            .object(forKey: Keys.spotlightExport) as? Bool ?? true
        self.ignoredPullRequests = Self.readJSON(
            defaults,
            Keys.ignoredPullRequests,
            default: InboxIgnoreList()
        )
        self.savedReplies = Self.readJSON(defaults, Keys.savedReplies, default: [SavedReply]())
        self.reviewTemplates = Self.readJSON(
            defaults,
            Keys.reviewTemplates,
            default: [ReviewTemplate]()
        )
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
        self.diagnosticsEnabled = defaults.object(forKey: Keys.diagnosticsEnabled) as? Bool ?? false
    }

    // MARK: - Appearance

    /// Dark, light or follow the system.
    var appearance: AppearanceSetting {
        didSet { Self.write(defaults, appearance, Keys.appearance) }
    }

    /// Whether the quick-inbox item sits in the menu bar (`Features/MenuBar`).
    ///
    /// On out of the box — unlike every *opt-in* flag in this type — because the item is the
    /// feature: a menu-bar quick inbox nobody knows to switch on is a menu-bar quick inbox
    /// nobody has. It is read straight by the `MenuBarExtra(isInserted:)` binding in
    /// ``ShepherdApp``, so switching it off removes the item rather than hiding it, and there is
    /// nothing to "apply" when a settings-sync document brings a new value.
    var showsMenuBarExtra: Bool {
        didSet { defaults.set(showsMenuBarExtra, forKey: Keys.showsMenuBarExtra) }
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

    // MARK: - Morning digest

    /// When the local morning digest is delivered, and whether it is delivered at all.
    ///
    /// Stored as one JSON blob, like ``agentCLI`` and ``autoDelegation``: three controls edited as
    /// one card in Settings → Sync, and one key keeps the tolerant-decoding story in one place.
    /// Off on a fresh install — ``ShepherdCore/DigestSchedule/isEnabled`` is what lets any of it
    /// run, and with it false the once-a-minute due check is a single `Bool` read.
    var digest: DigestSchedule {
        didSet { Self.writeJSON(defaults, digest, Keys.digest) }
    }

    /// When this Mac last delivered a morning digest, or `nil` if it never has.
    ///
    /// Device state, and deliberately **not** part of the encrypted settings document (ADR 0014) —
    /// for exactly the reason ``ShepherdCore/AutoDelegationLedger`` is not: two Macs sharing one
    /// "already delivered today" would let whichever one woke up first silence the other. It sits
    /// in ``AppSettings`` rather than in a store of its own because it is a single date with no
    /// counting rules attached, next to ``settingsSyncLastUploadAt``, which is device state living
    /// here for the same reason.
    ///
    /// It is also the digest's *window start*: the next digest reports on the span since this
    /// moment (``ShepherdCore/DigestSchedule/window(now:lastDeliveredAt:calendar:)``).
    var digestLastDeliveredAt: Date? {
        didSet { defaults.set(digestLastDeliveredAt, forKey: Keys.digestLastDeliveredAt) }
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

    /// ISO 3166-1 alpha-2 countries the OpenAI-compatible endpoint may serve a request from.
    ///
    /// The optional half of the sovereignty policy (plan §3.K), and **empty on a fresh install**
    /// — which is what makes it safe to have at all: an empty list is not sent, so a request to
    /// an endpoint that has never heard of the field is byte-identical to the request Shepherd
    /// sent before this setting existed.
    ///
    /// It is not a per-endpoint feature switch and there is no per-preset code path behind it:
    /// the two values travel as `provider.countries` / `provider.zero_retention` in the request
    /// body, an endpoint that understands them honours them, and one that does not refuses the
    /// request in its own words — which is the honest outcome for a constraint the user asked
    /// for and the endpoint cannot meet. Non-secret, so `UserDefaults` (ADR 0007) and the
    /// encrypted sync document (ADR 0014) both carry it.
    var openAICompatibleSovereigntyCountries: [String] {
        didSet {
            defaults.set(
                openAICompatibleSovereigntyCountries,
                forKey: Keys.openAISovereigntyCountries
            )
        }
    }

    /// Whether the OpenAI-compatible endpoint must pick an operator that retains nothing.
    ///
    /// Sent only when `true`, for the field's own reason: `false` and absent mean the same thing,
    /// so there is no reading of `false` as "prefer an operator that does retain".
    var openAICompatibleZeroRetention: Bool {
        didSet { defaults.set(openAICompatibleZeroRetention, forKey: Keys.openAIZeroRetention) }
    }

    /// Which known endpoint the OpenAI-compatible base URL belongs to.
    ///
    /// Derived from the URL rather than stored beside it. The base URL *is* the configuration —
    /// the intelligence layer reads it and never reads this — so a second, separately persisted
    /// copy of "which preset" could only ever drift out of agreement with it; this is purely the
    /// label, note, key link and placeholders Settings shows.
    ///
    /// One consequence is deliberate: a base URL that happens to equal a preset's URL now shows
    /// that preset even when the user reached it by typing rather than by picking, where the
    /// stored version could go on claiming "Custom". Since picking the preset would have written
    /// exactly this URL, the two configurations are identical in every way except the label, and
    /// naming the endpoint the user is actually talking to is the better of the two answers.
    var openAICompatiblePreset: IntelligenceEndpointPreset {
        .matching(baseURL: openAICompatibleBaseURL)
    }

    /// Selects an endpoint preset by writing the base URL that belongs to it.
    ///
    /// ``IntelligenceEndpointPreset/custom`` has no URL of its own and therefore keeps whatever
    /// is already in the field, so switching to it never erases a hand-typed endpoint.
    /// - Parameter preset: The preset the user picked.
    func applyEndpointPreset(_ preset: IntelligenceEndpointPreset) {
        guard let baseURL = preset.baseURL else { return }
        openAICompatibleBaseURL = baseURL
    }

    /// Whether the on-device classifier may give each pull request a kind and a risk (ADR 0007,
    /// plan §3.A).
    ///
    /// **On on a fresh install**, like the search index and the Spotlight export and for the same
    /// reason: the classification is on-device work over rows the sweep already wrote, it makes
    /// no request, and there is no code path from a verdict to a button — it sorts the inbox and
    /// fills a facet.
    ///
    /// The switch is not the whole condition. The classifier additionally requires the tiers to
    /// be on at all (``intelligenceMode`` other than ``IntelligenceMode/off``), because there is
    /// no model to ask otherwise; the plan words the default as "follows `intelligenceMode !=
    /// .off`", and it is stored as a plain `Bool` rather than derived from the mode so that
    /// switching the tiers on does not silently re-enable a classifier the user turned off. With
    /// the mode off the toggle is simply inert, and the inbox falls back to the tier-1 risk
    /// hints, which are always there.
    ///
    /// Read by ``TriageCoordinator`` and by nothing else (ADR 0023). Switching it off does not
    /// merely stop the pass: it empties `triage_verdicts`, for the reason the search index's
    /// switch empties its table — a switch that left its rows on disk would be lying about what
    /// it is named after.
    var structuredTriageEnabled: Bool {
        didSet { defaults.set(structuredTriageEnabled, forKey: Keys.structuredTriage) }
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

    /// The pull requests the inbox has been told to stop showing.
    ///
    /// Device-local on purpose: it is not in ``SyncedSettingsDocument``, which enumerates its
    /// fields one at a time (ADR 0014), because dismissing somebody else's year-old pull request
    /// is a decision about this inbox rather than a preference — the same reasoning that keeps
    /// the auto-delegation ledger off the settings document.
    var ignoredPullRequests: InboxIgnoreList {
        didSet { Self.writeJSON(defaults, ignoredPullRequests, Keys.ignoredPullRequests) }
    }

    /// The merge method the merge sheet and the bulk-triage dialog open on.
    ///
    /// Written by both of them, so it is "the last method you chose" rather than a preference
    /// buried in Settings — the choice a merge dialog needs is nearly always the previous one
    /// (ADR 0015).
    var defaultMergeMethod: MergeMethod {
        didSet { Self.write(defaults, defaultMergeMethod, Keys.defaultMergeMethod) }
    }

    // MARK: - Review screen

    /// Whether an agent's pull request opens on Conversation when its description claims something
    /// the claims-vs-evidence card can check (ADR 0026's amendment).
    ///
    /// On by default, because that card is the reason an agent's pull request looks different in
    /// Shepherd than it does on github.com. Off is for the reviewer who wants the diff first
    /// whatever wrote the description — ``ReviewModel/defaultTab(for:opensAgentPullRequestsOnConversation:)``
    /// then answers Files for everything, which is what the app always did.
    var opensAgentPullRequestsOnConversation: Bool {
        didSet {
            defaults.set(
                opensAgentPullRequestsOnConversation,
                forKey: Keys.opensAgentOnConversation
            )
        }
    }

    /// Whether the merge sheet opens with "delete the branch afterwards" ticked.
    ///
    /// Remembered the way ``defaultMergeMethod`` is, and for the same reason: the sheet writes
    /// straight through, so it is "what you did last time" rather than a preference nobody would
    /// go and find. Off by default — the irreversible half of an irreversible action is not
    /// something to opt people into — and read by the merge sheet alone: bulk triage (ADR 0015)
    /// and the automatic rules (ADR 0018) queue merges that delete nothing, whatever this says.
    var deletesBranchAfterMerge: Bool {
        didSet { defaults.set(deletesBranchAfterMerge, forKey: Keys.deletesBranchAfterMerge) }
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

    /// Which diff view renders changes: Monaco, the native list, or automatic between them.
    var diffRenderer: DiffRenderer {
        didSet { Self.write(defaults, diffRenderer, Keys.diffRenderer) }
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

    /// The opt-in rules that may start a delegation without being asked (ADR 0016).
    ///
    /// Stored as one JSON blob, like ``agentCLI``: the rule set is edited as a whole on one
    /// Settings card, and a single key keeps the tolerant-decoding story in one place. Off on a
    /// fresh install — ``AutoDelegationRules/isEnabled`` is what lets any of this run at all.
    var autoDelegation: AutoDelegationRules {
        didSet { Self.writeJSON(defaults, autoDelegation, Keys.autoDelegation) }
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

    // MARK: - Automatic merging (ADR 0018)

    /// The opt-in rules that let Shepherd queue a merge without being asked (ADR 0018).
    ///
    /// Stored as one JSON blob for the reason ``autoDelegation`` is: the rule set is edited as a
    /// whole on one Settings card, and a single key keeps the tolerant-decoding story in one
    /// place. Off on a fresh install — ``ShepherdCore/AutoMergeRules/isEnabled`` is what lets any
    /// of it run, and with it false a sweep costs one `Bool` read.
    ///
    /// It is edited on the *Automation* tab rather than beside ``autoDelegation`` because the two
    /// are siblings rather than variants: this one writes to GitHub and never touches an agent
    /// CLI, which also makes it the one automation the webhook layer reports on.
    var autoMerge: AutoMergeRules {
        didSet { Self.writeJSON(defaults, autoMerge, Keys.autoMerge) }
    }

    /// The merge method automatic merging uses, shared with the merge sheet and the bulk-triage
    /// dialog (``defaultMergeMethod``).
    ///
    /// Deliberately *not* a setting of its own. "The method you last merged with" is the answer
    /// every merge dialog in the app already opens on (ADR 0015), and a second copy for the
    /// automatic path could only ever disagree with what the user sees when they merge by hand —
    /// the same argument ``UpdateController/checksAutomatically`` makes about Sparkle's flag.
    var autoMergeMethod: MergeMethod { defaultMergeMethod }

    // MARK: - Trust lanes (ADR 0027)

    /// The largest number of changed files a *short look* may have.
    ///
    /// Two plain `Int`s rather than one JSON blob like ``autoMerge``, and the reason is what edits
    /// them: these are two steppers, each written on its own, and a blob would mean re-encoding
    /// both every time one moved. They are read back through
    /// ``ShepherdCore/TrustLaneConfiguration``, which clamps them, so a value a hostile or a
    /// hand-edited `defaults` write put out of range cannot empty the short lane.
    var trustLaneMaxFiles: Int {
        didSet { defaults.set(trustLaneMaxFiles, forKey: Keys.trustLaneMaxFiles) }
    }

    /// The largest number of added-plus-deleted lines a *short look* may have.
    var trustLaneMaxChangedLines: Int {
        didSet { defaults.set(trustLaneMaxChangedLines, forKey: Keys.trustLaneMaxChangedLines) }
    }

    /// Whether the inbox's one-time offer to load the track record has been answered
    /// (ADR 0027's 2026-09-05 amendment).
    ///
    /// The backfill stays manual — it reads up to five hundred closed pull requests per
    /// repository and the user did not ask for that — but until now nothing in the app said the
    /// button existed, so the badge, the LANES rail and the whole feature were invisible to
    /// anyone who never opened Settings → Automation. The inbox makes the offer once instead,
    /// and this is the "once": it is set by *Not now* and by a run that came back, so the
    /// question is asked exactly one time however it was answered.
    ///
    /// **Deliberately not carried in ``SyncedSettingsDocument``**, and it is not an exception to
    /// ADR 0014's obligation but the same category ``digestLastDeliveredAt`` and
    /// ``settingsSyncLastUploadAt`` are in: device state that happens to live here because it is
    /// one flag with no rules attached. Nothing about it is a preference — it records that a hint
    /// has been read on *this* Mac, which is the shape "this Mac has already delivered today"
    /// has.
    ///
    /// The second half of the argument is ADR 0027's own. The thing the hint offers is the
    /// stored history, which that ADR keeps off the wire for its own reasons and expects a second
    /// Mac to rebuild by pressing the same button there. A dismissal that travelled would
    /// therefore switch the offer off on exactly the Mac that still has no track record and no
    /// other way of learning that it could have one.
    var hasDismissedTrackRecordNotice: Bool {
        didSet {
            defaults.set(hasDismissedTrackRecordNotice, forKey: Keys.trackRecordNoticeDismissed)
        }
    }

    /// The two thresholds as the pure classifier wants them.
    ///
    /// The one place the lane's inputs are assembled from settings, so the inbox, the rail's
    /// counts and the Settings card's own preview cannot disagree about what "small" means. The
    /// initialiser clamps, which is why this is the accessor everything reads rather than the two
    /// stored properties.
    var trustLaneConfiguration: TrustLaneConfiguration {
        TrustLaneConfiguration(
            maxFiles: trustLaneMaxFiles,
            maxChangedLines: trustLaneMaxChangedLines
        )
    }

    // MARK: - Semantic ⌘K search (ADR 0019)

    /// Whether Shepherd keeps an on-device semantic index of the pull requests in the inbox.
    ///
    /// **On on a fresh install**, which makes it the only intelligence-shaped setting in the app
    /// that is. The reasoning is in ADR 0019 and comes down to what the toggle can cost: the index
    /// is built from rows the sweep already wrote, the embeddings are Apple's on-device model, and
    /// there is no code path from here to any endpoint — so the whole bill is some CPU in a
    /// low-priority task and a few hundred kilobytes of SQLite. The tiers that are off by default
    /// (ADR 0007) are off because they *send something somewhere* or cost money; neither applies.
    ///
    /// With it off, ⌘K still searches — the lexical ranker in `ShepherdCore` needs no model and
    /// keeps matching titles, labels, repositories, branches and authors — and the index table is
    /// emptied, because a switch named after an index that left one on disk would be a lie.
    var semanticSearchEnabled: Bool {
        didSet { defaults.set(semanticSearchEnabled, forKey: Keys.semanticSearch) }
    }

    // MARK: - Pull requests in Spotlight (ADR 0021)

    /// Whether the pull requests in the inbox appear in macOS Spotlight.
    ///
    /// **On on a fresh install**, for the reason the search index above is: the export is built
    /// from rows the sweep already wrote, it makes no request, and it costs a batched Core
    /// Spotlight call on the passes where something a result shows actually changed. A user who
    /// presses ⌘Space and types a pull-request title expects to find it.
    ///
    /// It is a separate switch from ``semanticSearchEnabled`` rather than a mode of it, because
    /// the two answer different questions. That one is about work done *inside* the app's own
    /// database; this one is about what leaves it: Spotlight's index is system-wide, backed up, and
    /// queryable by other processes. So what is exported is titles and metadata only
    /// (``SpotlightItemFields``) — and the switch that governs it says so on the same card, where a
    /// user deciding "do I want my pull-request titles in the system index" is standing.
    ///
    /// With it off, the whole `pullRequests` domain is deleted rather than left to expire, and ⌘K
    /// inside the app is unaffected.
    var spotlightExportEnabled: Bool {
        didSet { defaults.set(spotlightExportEnabled, forKey: Keys.spotlightExport) }
    }

    // MARK: - Saved replies & review templates

    /// The user's named, reusable comment bodies, in the order they chose.
    ///
    /// Stored as one JSON blob, like ``agentCLI`` and ``autoDelegation``: the list is edited as a
    /// whole on one Settings card, and the order is part of the data — it is the order of the insert
    /// menu, so the reply someone uses twenty times a day belongs at the top.
    var savedReplies: [SavedReply] {
        didSet { Self.writeJSON(defaults, savedReplies, Keys.savedReplies) }
    }

    /// The per-repository summary templates, in the order they chose.
    ///
    /// The order is load-bearing here too, but for a different reason: it is the last tie-breaker
    /// of ``ShepherdCore/ReviewTemplate/matching(_:repo:)`` when two patterns are equally specific.
    var reviewTemplates: [ReviewTemplate] {
        didSet { Self.writeJSON(defaults, reviewTemplates, Keys.reviewTemplates) }
    }

    /// The saved replies worth putting in a menu: named, and with something to insert.
    var usableSavedReplies: [SavedReply] {
        savedReplies.filter(\.isUsable)
    }

    /// Adds a saved reply, or replaces the one with the same identity.
    /// - Parameter reply: The reply to store.
    func upsert(savedReply reply: SavedReply) {
        var updated = savedReplies
        if let index = updated.firstIndex(where: { $0.id == reply.id }) {
            updated[index] = reply
        } else {
            updated.append(reply)
        }
        savedReplies = updated
    }

    /// Deletes a saved reply.
    /// - Parameter id: The reply's identity.
    func deleteSavedReply(id: UUID) {
        savedReplies.removeAll { $0.id == id }
    }

    /// Moves a saved reply one place up or down. Out-of-range moves are ignored.
    /// - Parameters:
    ///   - id: The reply's identity.
    ///   - offset: `-1` for up, `+1` for down.
    func moveSavedReply(id: UUID, by offset: Int) {
        savedReplies = Self.moving(savedReplies, id: id, by: offset)
    }

    /// Adds a review template, or replaces the one with the same identity.
    /// - Parameter template: The template to store.
    func upsert(reviewTemplate template: ReviewTemplate) {
        var updated = reviewTemplates
        if let index = updated.firstIndex(where: { $0.id == template.id }) {
            updated[index] = template
        } else {
            updated.append(template)
        }
        reviewTemplates = updated
    }

    /// Deletes a review template.
    /// - Parameter id: The template's identity.
    func deleteReviewTemplate(id: UUID) {
        reviewTemplates.removeAll { $0.id == id }
    }

    /// Moves a review template one place up or down. Out-of-range moves are ignored.
    /// - Parameters:
    ///   - id: The template's identity.
    ///   - offset: `-1` for up, `+1` for down.
    func moveReviewTemplate(id: UUID, by offset: Int) {
        reviewTemplates = Self.moving(reviewTemplates, id: id, by: offset)
    }

    /// One-place reordering shared by both lists.
    ///
    /// A swap rather than a remove-and-insert: for a single step they are the same result, and a
    /// swap cannot renumber the rest of the list if the index arithmetic is ever wrong.
    private static func moving<Element: Identifiable>(
        _ list: [Element],
        id: Element.ID,
        by offset: Int
    ) -> [Element] {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return list }
        let target = index + offset
        guard target >= 0, target < list.count else { return list }
        var updated = list
        updated.swapAt(index, target)
        return updated
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

    // MARK: - Diagnostics (ADR 0017)

    /// Whether Shepherd keeps MetricKit's crash and hang reports in a folder on this Mac.
    ///
    /// Off on a fresh install, and the only thing that registers the MetricKit subscriber at all:
    /// with this false, `MXMetricManager` has no subscriber, so nothing is delivered and nothing
    /// is stored — the same shape as ``webhooksEnabled`` and ``settingsSyncEnabled``. Nothing is
    /// ever uploaded either way; there is no uploader.
    var diagnosticsEnabled: Bool {
        didSet { defaults.set(diagnosticsEnabled, forKey: Keys.diagnosticsEnabled) }
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
        static let showsMenuBarExtra = "appearance.showsMenuBarExtra"
        static let sweepIntervalMinutes = "sync.sweepIntervalMinutes"
        static let notifyReviewRequest = "notify.reviewRequest"
        static let notifyChecksFailed = "notify.checksFailed"
        static let notifyDraftConflict = "notify.draftConflict"
        static let digest = "digest.schedule"
        static let digestLastDeliveredAt = "digest.lastDeliveredAt"
        static let intelligenceMode = "intelligence.mode"
        static let cloudProviderKind = "intelligence.cloudKind"
        static let anthropicModel = "intelligence.anthropic.model"
        static let openAIBaseURL = "intelligence.openaiCompatible.baseURL"
        static let openAIModel = "intelligence.openaiCompatible.model"
        static let openAISovereigntyCountries = "intelligence.openaiCompatible.sovereigntyCountries"
        static let openAIZeroRetention = "intelligence.openaiCompatible.zeroRetention"
        static let structuredTriage = "intelligence.structuredTriageEnabled"
        static let groupBy = "inbox.groupBy"
        static let sortOrder = "inbox.sortOrder"
        static let ignoredPullRequests = "inbox.ignoredPullRequests"
        static let defaultMergeMethod = "review.defaultMergeMethod"
        static let opensAgentOnConversation = "review.opensAgentPullRequestsOnConversation"
        static let deletesBranchAfterMerge = "merge.deletesBranchAfterMerge"
        static let diffFontSize = "diff.fontSize"
        static let diffWraps = "diff.wraps"
        static let diffInline = "diff.inline"
        static let diffRenderer = "diff.renderer"
        static let accountLogin = "account.login"
        static let accountAvatar = "account.avatarURL"
        static let accountAuthKind = "account.authKind"
        static let agentCLI = "delegation.agentCLI"
        static let localCheckouts = "delegation.localCheckouts"
        static let autoDelegation = "delegation.autoRules"
        static let autoMerge = "automation.autoMergeRules"
        static let trustLaneMaxFiles = "trust.laneMaxFiles"
        static let trustLaneMaxChangedLines = "trust.laneMaxChangedLines"
        static let trackRecordNoticeDismissed = "trust.trackRecordNoticeDismissed"
        static let semanticSearch = "search.semanticIndexEnabled"
        static let spotlightExport = "search.spotlightExportEnabled"
        static let savedReplies = "review.savedReplies"
        static let reviewTemplates = "review.templates"
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
        static let diagnosticsEnabled = "diagnostics.enabled"
    }

    /// Reads a `Codable` value stored as one JSON blob, falling back when the key is absent or
    /// no longer decodes.
    ///
    /// Internal rather than private because ``AutoDelegationStore`` stores its ledger the same
    /// way and in the same defaults suite; one pair of helpers keeps the tolerant-decoding
    /// behaviour — a value written by an older or newer build is a fallback, never a crash — in
    /// one place.
    /// - Parameters:
    ///   - defaults: The store to read from.
    ///   - key: The defaults key.
    ///   - fallback: What to return when nothing usable is stored.
    /// - Returns: The stored value, or `fallback`.
    static func readJSON<Value: Decodable>(
        _ defaults: UserDefaults,
        _ key: String,
        default fallback: Value
    ) -> Value {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else { return fallback }
        return value
    }

    /// Writes a `Codable` value as one JSON blob. A value that cannot be encoded leaves whatever
    /// was stored before in place rather than clearing it.
    /// - Parameters:
    ///   - defaults: The store to write to.
    ///   - value: The value to store.
    ///   - key: The defaults key.
    static func writeJSON<Value: Encodable>(
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
