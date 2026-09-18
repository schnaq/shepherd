import Foundation

/// The thirteen events Shepherd may send, and nothing else (ADR 0036).
///
/// Adding a case here is the only way to send anything, and every associated value is an enum or a
/// bucket. That is the allow-list made structural: there is no code path from a repository name,
/// a branch, a title or a path to a payload, because no case would hold one.
enum TelemetryEvent: Sendable {
    /// One per installation per UTC day: emitted at launch and again when a running app crosses
    /// midnight, de-duplicated by ``TelemetryHeartbeat``. The count of these per day *is* the
    /// number of active installations that day.
    case appActiveDay(
        repoCount: CountBucket,
        inboxSize: CountBucket,
        diffRenderer: DiffRendererChoice,
        intelligence: IntelligenceChoice,
        webhooks: Bool,
        settingsSync: Bool,
        autoMerge: Bool,
        autoDelegation: Bool,
        digest: Bool,
        menuBar: Bool,
        diagnostics: Bool
    )
    case reviewSubmitted(kind: ReviewKind, inlineComments: CountBucket, usedTemplate: Bool, usedSavedReply: Bool)
    case pullRequestMerged(method: MergeMethodChoice, source: MergeSource)
    case focusSessionCompleted(queueSize: CountBucket, completed: Bool)
    case bulkTriagePerformed(action: TriageAction, size: CountBucket)
    case searchUsed(kind: SearchKind, openedResult: Bool)
    case delegationStarted(trigger: DelegationTrigger)
    case delegationFinished(outcome: DelegationOutcomeChoice)
    case intelligenceUsed(feature: IntelligenceFeature, tier: IntelligenceTier, outcome: IntelligenceOutcomeChoice)
    case autoMergeRuleFired(outcome: AutoMergeOutcome)
    case issuesInboxUsed(action: IssuesAction)
    case fleetViewed(scope: FleetScope)
    case digestOpened(source: DigestSource)

    /// The event name PostHog stores.
    var name: String {
        switch self {
        case .appActiveDay: return "app_active_day"
        case .reviewSubmitted: return "review_submitted"
        case .pullRequestMerged: return "pull_request_merged"
        case .focusSessionCompleted: return "focus_session_completed"
        case .bulkTriagePerformed: return "bulk_triage_performed"
        case .searchUsed: return "search_used"
        case .delegationStarted: return "delegation_started"
        case .delegationFinished: return "delegation_finished"
        case .intelligenceUsed: return "intelligence_used"
        case .autoMergeRuleFired: return "auto_merge_rule_fired"
        case .issuesInboxUsed: return "issues_inbox_used"
        case .fleetViewed: return "fleet_viewed"
        case .digestOpened: return "digest_opened"
        }
    }

    /// The event's own properties. The four every event carries — app version, macOS major,
    /// language, `distinct_id` — are added by ``PostHogSender``, not here.
    var properties: [String: TelemetryValue] {
        switch self {
        case .appActiveDay(
            let repoCount, let inboxSize, let diffRenderer, let intelligence,
            let webhooks, let settingsSync, let autoMerge, let autoDelegation,
            let digest, let menuBar, let diagnostics
        ):
            return [
                "repo_count": TelemetryValue(repoCount),
                "inbox_size": TelemetryValue(inboxSize),
                "diff_renderer": TelemetryValue(diffRenderer),
                "intelligence": TelemetryValue(intelligence),
                "webhooks": .flag(webhooks),
                "settings_sync": .flag(settingsSync),
                "auto_merge": .flag(autoMerge),
                "auto_delegation": .flag(autoDelegation),
                "digest": .flag(digest),
                "menu_bar": .flag(menuBar),
                "diagnostics": .flag(diagnostics),
            ]
        case .reviewSubmitted(let kind, let inlineComments, let usedTemplate, let usedSavedReply):
            return [
                "kind": TelemetryValue(kind),
                "inline_comments": TelemetryValue(inlineComments),
                "used_template": .flag(usedTemplate),
                "used_saved_reply": .flag(usedSavedReply),
            ]
        case .pullRequestMerged(let method, let source):
            return ["method": TelemetryValue(method), "source": TelemetryValue(source)]
        case .focusSessionCompleted(let queueSize, let completed):
            return ["queue_size": TelemetryValue(queueSize), "completed": .flag(completed)]
        case .bulkTriagePerformed(let action, let size):
            return ["action": TelemetryValue(action), "size": TelemetryValue(size)]
        case .searchUsed(let kind, let openedResult):
            return ["kind": TelemetryValue(kind), "opened_result": .flag(openedResult)]
        case .delegationStarted(let trigger):
            return ["trigger": TelemetryValue(trigger)]
        case .delegationFinished(let outcome):
            return ["outcome": TelemetryValue(outcome)]
        case .intelligenceUsed(let feature, let tier, let outcome):
            return [
                "feature": TelemetryValue(feature),
                "tier": TelemetryValue(tier),
                "outcome": TelemetryValue(outcome),
            ]
        case .autoMergeRuleFired(let outcome):
            return ["outcome": TelemetryValue(outcome)]
        case .issuesInboxUsed(let action):
            return ["action": TelemetryValue(action)]
        case .fleetViewed(let scope):
            return ["scope": TelemetryValue(scope)]
        case .digestOpened(let source):
            return ["source": TelemetryValue(source)]
        }
    }

    /// One example of every case, so a test can walk the whole vocabulary.
    static var allExamples: [TelemetryEvent] {
        [
            .appActiveDay(
                repoCount: .oneToThree, inboxSize: .fourToTen, diffRenderer: .native,
                intelligence: .onDevice, webhooks: false, settingsSync: true, autoMerge: false,
                autoDelegation: false, digest: true, menuBar: true, diagnostics: false
            ),
            .reviewSubmitted(kind: .approve, inlineComments: .oneToThree, usedTemplate: true, usedSavedReply: false),
            .pullRequestMerged(method: .squash, source: .detail),
            .focusSessionCompleted(queueSize: .elevenPlus, completed: true),
            .bulkTriagePerformed(action: .approve, size: .fourToTen),
            .searchUsed(kind: .semantic, openedResult: true),
            .delegationStarted(trigger: .manual),
            .delegationFinished(outcome: .applied),
            .intelligenceUsed(feature: .brief, tier: .onDevice, outcome: .ok),
            .autoMergeRuleFired(outcome: .merged),
            .issuesInboxUsed(action: .viewed),
            .fleetViewed(scope: .all),
            .digestOpened(source: .notification),
        ]
    }
}

/// A count, coarsened until it stops identifying anybody.
enum CountBucket: String, TelemetryChoice {
    case none = "0"
    case oneToThree = "1-3"
    case fourToTen = "4-10"
    case elevenPlus = "11+"

    /// Buckets a count.
    /// - Parameter count: The real number, which never leaves the Mac.
    init(count: Int) {
        switch count {
        case ..<1: self = .none
        case 1...3: self = .oneToThree
        case 4...10: self = .fourToTen
        default: self = .elevenPlus
        }
    }
}

enum ReviewKind: String, TelemetryChoice {
    case approve, requestChanges = "request_changes", comment
}

/// How a merge was performed.
///
/// Deliberately *not* GitHubKit's `MergeMethod`, whose cases happen to match today. The allow-list
/// is only structural if the vocabulary is written here and reviewed here; conforming a type from
/// another module would let a case added over there widen the payload without anyone noticing.
/// The one-line mapping at the call site is where that check happens.
enum MergeMethodChoice: String, TelemetryChoice {
    case merge, squash, rebase
}

enum MergeSource: String, TelemetryChoice {
    case detail, bulk, autoRule = "auto_rule"
}

enum TriageAction: String, TelemetryChoice {
    case approve, merge
}

enum DiffRendererChoice: String, TelemetryChoice {
    case monaco, native
}

enum IntelligenceChoice: String, TelemetryChoice {
    case none, onDevice = "on_device", cloud, both
}

enum SearchKind: String, TelemetryChoice {
    case semantic, reference
}

enum DelegationTrigger: String, TelemetryChoice {
    case manual, ciRedRule = "ci_red_rule"
}

/// How a delegation ended, coarsened for the payload.
///
/// `Choice` because `DelegationOutcome` is already the real thing — the struct a finished run
/// hands back. This is the four-way summary of it that may leave the Mac.
enum DelegationOutcomeChoice: String, TelemetryChoice {
    case applied, discarded, budgetExceeded = "budget_exceeded", failed
}

enum IntelligenceFeature: String, TelemetryChoice {
    case brief, draftComment = "draft_comment", explain
    case ciDiagnosis = "ci_diagnosis", threadDigest = "thread_digest", claims
}

enum IntelligenceTier: String, TelemetryChoice {
    case onDevice = "on_device", pcc, cloud
}

/// How an intelligence request ended, coarsened for the payload.
///
/// `Choice` because `IntelligenceOutcome<Value>` is already the router's own generic result type.
enum IntelligenceOutcomeChoice: String, TelemetryChoice {
    case ok, tooLarge = "too_large", unavailable, error
}

enum AutoMergeOutcome: String, TelemetryChoice {
    case merged, skipped
}

enum IssuesAction: String, TelemetryChoice {
    case viewed, commented, labeled, assigned, closed
}

enum FleetScope: String, TelemetryChoice {
    case all, repo
}

enum DigestSource: String, TelemetryChoice {
    case notification, menuBar = "menu_bar", app
}
