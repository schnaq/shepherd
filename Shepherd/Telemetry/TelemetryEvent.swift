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
    /// A verdict that reached the outbox.
    ///
    /// The spec also listed `used_template` and `used_saved_reply`. Neither is recorded: nothing
    /// in the composer remembers that a template or a saved reply was inserted, and sending
    /// `false` for both would publish "nobody uses templates" as a finding. Adding them needs
    /// that state first, which is a change to the composer rather than to telemetry.
    case reviewSubmitted(kind: ReviewKind, inlineComments: CountBucket)
    case pullRequestMerged(method: MergeMethodChoice, source: MergeSource)
    case focusSessionCompleted(queueSize: CountBucket, completed: Bool)
    case bulkTriagePerformed(action: TriageAction, size: CountBucket)
    case searchUsed(kind: SearchKind, openedResult: Bool)
    case delegationStarted(trigger: DelegationTrigger)
    case delegationFinished(outcome: DelegationOutcomeChoice)
    /// Which intelligence feature ran, on which tier, and how it ended.
    ///
    /// **Not recorded yet, deliberately.** The plan assumed `IntelligenceRouter` was "the single
    /// place all six features pass through"; it is not. `thread_digest` and `claims` are served by
    /// `OnDeviceThreadDigester` and `OnDeviceClaimExtractor` and never reach the router at all, and
    /// the router's own callers are scattered across models that hold no `AppEnvironment`. Wiring
    /// only the four that do pass through would publish "nobody uses claims" as a finding about
    /// users when it is a fact about the wiring — so this stays unrecorded until all six can be,
    /// which needs a hook on the router plus one on each of the two on-device types.
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
                "repo_count": repoCount.telemetryValue,
                "inbox_size": inboxSize.telemetryValue,
                "diff_renderer": diffRenderer.telemetryValue,
                "intelligence": intelligence.telemetryValue,
                "webhooks": .flag(webhooks),
                "settings_sync": .flag(settingsSync),
                "auto_merge": .flag(autoMerge),
                "auto_delegation": .flag(autoDelegation),
                "digest": .flag(digest),
                "menu_bar": .flag(menuBar),
                "diagnostics": .flag(diagnostics),
            ]
        case .reviewSubmitted(let kind, let inlineComments):
            return [
                "kind": kind.telemetryValue,
                "inline_comments": inlineComments.telemetryValue,
            ]
        case .pullRequestMerged(let method, let source):
            return ["method": method.telemetryValue, "source": source.telemetryValue]
        case .focusSessionCompleted(let queueSize, let completed):
            return ["queue_size": queueSize.telemetryValue, "completed": .flag(completed)]
        case .bulkTriagePerformed(let action, let size):
            return ["action": action.telemetryValue, "size": size.telemetryValue]
        case .searchUsed(let kind, let openedResult):
            return ["kind": kind.telemetryValue, "opened_result": .flag(openedResult)]
        case .delegationStarted(let trigger):
            return ["trigger": trigger.telemetryValue]
        case .delegationFinished(let outcome):
            return ["outcome": outcome.telemetryValue]
        case .intelligenceUsed(let feature, let tier, let outcome):
            return [
                "feature": feature.telemetryValue,
                "tier": tier.telemetryValue,
                "outcome": outcome.telemetryValue,
            ]
        case .autoMergeRuleFired(let outcome):
            return ["outcome": outcome.telemetryValue]
        case .issuesInboxUsed(let action):
            return ["action": action.telemetryValue]
        case .fleetViewed(let scope):
            return ["scope": scope.telemetryValue]
        case .digestOpened(let source):
            return ["source": source.telemetryValue]
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
            .reviewSubmitted(kind: .approve, inlineComments: .oneToThree),
            .pullRequestMerged(method: .squash, source: .detail),
            .focusSessionCompleted(queueSize: .elevenPlus, completed: true),
            .bulkTriagePerformed(action: .approve, size: .fourToTen),
            .searchUsed(kind: .semantic, openedResult: true),
            .delegationStarted(trigger: .manual),
            .delegationFinished(outcome: .finished),
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

/// What a bulk-triage run did, mirroring `BulkTriageAction` one for one.
///
/// The spec listed two cases and the domain has three: "approve" and "approve and merge" are
/// different gestures with different risk, and folding them together would hide the one worth
/// watching.
enum TriageAction: String, TelemetryChoice {
    case approve, approveAndMerge = "approve_and_merge", merge
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

/// How a delegation ended.
///
/// `Choice` because `DelegationOutcome` is already the real thing — the struct a finished run
/// hands back. These are its three statuses, one for one.
///
/// The spec proposed `applied / discarded`, which describes a step Shepherd does not have: a run
/// ends with its work in a worktree, and there is no moment where the user accepts or rejects a
/// diff for this to observe. `cancelled` against `finished` answers the question the spec asked —
/// whether delegation is abandoned in practice — without claiming to have watched something else.
enum DelegationOutcomeChoice: String, TelemetryChoice {
    case finished, cancelled, failed
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

/// What an auto-merge rule did.
///
/// Only `merged` is ever recorded, and the event fires once per queued merge. `skipped` stays in
/// the vocabulary because a decision has two sides, but recording it is deliberately not done: the
/// policy reaches a decision for *every inbox row on every sweep*, so a skip event would be tens
/// of thousands a month per installation and would swamp the very number it sits beside.
enum AutoMergeOutcome: String, TelemetryChoice {
    case merged, skipped
}

enum IssuesAction: String, TelemetryChoice {
    case viewed, commented, labeled, assigned, closed
}

/// Which fleet page was opened.
///
/// The spec said `all / repo`, but ADR 0035 built no repository-scoped fleet view: the screen is
/// either the whole roster or one agent's page, and that page groups *by* repository rather than
/// being scoped to one. These are the two things a user can actually open, and the question worth
/// answering is whether anybody goes past the roster.
enum FleetScope: String, TelemetryChoice {
    case all, agent
}

enum DigestSource: String, TelemetryChoice {
    case notification, menuBar = "menu_bar", app
}
