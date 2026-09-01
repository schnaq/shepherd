import Foundation

/// The condition an auto-delegation rule fires on (ADR 0016).
///
/// Deliberately two cases. Both are *transitions on a pull request the user owns* — the only
/// shape of trigger v1 allows, because it is the only one where "something just went wrong with
/// my work" is unambiguous and where a fix is the obvious next step.
public enum AutoDelegationTrigger: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// CI turned red: the previous sweep saw a non-failing rollup, this one sees a failing one.
    case checksFailed
    /// A reviewer asked for changes: the previous sweep saw another review decision.
    case changesRequested

    public var id: String { rawValue }

    /// How the condition is described *inside the agent's prompt*.
    ///
    /// Unlocalised on purpose: this string is part of the prompt handed to a CLI, not UI chrome.
    /// Everything the user reads is built in the app layer with `String(localized:)`.
    public var promptDescription: String {
        switch self {
        case .checksFailed: return "CI turned red"
        case .changesRequested: return "a reviewer requested changes"
        }
    }
}

/// The opt-in rule set: what may start a delegation on its own, and how often (ADR 0016).
///
/// Every field is off or small by default. `isEnabled` is the master switch, and with it false
/// nothing in this file ever produces a start — exactly as `webhooksEnabled` gates webhooks
/// (ADR 0012) and `settingsSyncEnabled` gates the bucket (ADR 0014).
public struct AutoDelegationRules: Sendable, Codable, Hashable {
    /// Whether rules may start delegations at all. Off on a fresh install.
    public var isEnabled: Bool
    /// Which conditions are armed.
    public var triggers: Set<AutoDelegationTrigger>
    /// The task text template, with `{…}` placeholders (see ``AutoDelegationPrompt``).
    public var promptTemplate: String
    /// How many automatic delegations may run at the same time.
    public var maxConcurrent: Int
    /// How many automatic delegations may start on one calendar day.
    public var maxPerDay: Int

    /// The conditions a fresh install arms once the master switch goes on.
    ///
    /// Red CI only. "Changes requested" is a human asking for a judgement call, so it is opt-in
    /// on top of an opt-in.
    public static let defaultTriggers: Set<AutoDelegationTrigger> = [.checksFailed]
    /// The default concurrency cap: one run at a time.
    public static let defaultMaxConcurrent = 1
    /// The default daily cap.
    public static let defaultMaxPerDay = 5

    /// The task text a fresh install starts from.
    ///
    /// Unlocalised, like ``AutoDelegationTrigger/promptDescription``: it is a prompt for an agent
    /// CLI. Shepherd's own preamble (worktree, never push, keep it small) is prepended by the
    /// delegation itself, so the template does not repeat it.
    public static let defaultPromptTemplate = """
        Fix the failing CI on pull request #{number} of {repo} — {reason}: {checks}.

        Reproduce the failure in this worktree, make the smallest change that makes it pass, and \
        stop when it does. If you cannot reproduce it, say what you tried in your final message \
        instead of guessing.
        """

    /// Creates a rule set.
    /// - Parameters:
    ///   - isEnabled: Whether rules may start delegations.
    ///   - triggers: The armed conditions.
    ///   - promptTemplate: The task template.
    ///   - maxConcurrent: The concurrency cap.
    ///   - maxPerDay: The daily cap.
    public init(
        isEnabled: Bool = false,
        triggers: Set<AutoDelegationTrigger> = AutoDelegationRules.defaultTriggers,
        promptTemplate: String = AutoDelegationRules.defaultPromptTemplate,
        maxConcurrent: Int = AutoDelegationRules.defaultMaxConcurrent,
        maxPerDay: Int = AutoDelegationRules.defaultMaxPerDay
    ) {
        self.isEnabled = isEnabled
        self.triggers = triggers
        self.promptTemplate = promptTemplate
        self.maxConcurrent = maxConcurrent
        self.maxPerDay = maxPerDay
    }

    /// The concurrency cap, never below one.
    public var concurrencyCap: Int { max(1, maxConcurrent) }
    /// The daily cap, never below one.
    public var dailyCap: Int { max(1, maxPerDay) }

    /// Whether a condition is armed *and* the master switch is on.
    /// - Parameter trigger: The condition.
    public func isArmed(_ trigger: AutoDelegationTrigger) -> Bool {
        isEnabled && triggers.contains(trigger)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, triggers, promptTemplate, maxConcurrent, maxPerDay
    }

    /// Encodes the trigger set as a *sorted* array of raw values.
    ///
    /// A `Set` has no order, and the settings-sync document is encoded canonically (ADR 0014):
    /// two identical rule sets must produce identical bytes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(triggers.map(\.rawValue).sorted(), forKey: .triggers)
        try container.encode(promptTemplate, forKey: .promptTemplate)
        try container.encode(maxConcurrent, forKey: .maxConcurrent)
        try container.encode(maxPerDay, forKey: .maxPerDay)
    }

    /// Decodes tolerantly: a rule set written by an older build is missing keys that were added
    /// later, and a missing key falls back to the default rather than throwing the whole set away.
    ///
    /// An *absent* `triggers` key means "this build wrote no triggers" and falls back to the
    /// default; an explicitly empty array means the user unticked every box and is kept as is.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled))
            .flatMap { $0 } ?? false
        let rawTriggers = (try? container.decodeIfPresent([String].self, forKey: .triggers))
            .flatMap { $0 }
        triggers = rawTriggers
            .map { Set($0.compactMap(AutoDelegationTrigger.init(rawValue:))) }
            ?? Self.defaultTriggers
        promptTemplate = (try? container.decodeIfPresent(String.self, forKey: .promptTemplate))
            .flatMap { $0 } ?? Self.defaultPromptTemplate
        maxConcurrent = (try? container.decodeIfPresent(Int.self, forKey: .maxConcurrent))
            .flatMap { $0 } ?? Self.defaultMaxConcurrent
        maxPerDay = (try? container.decodeIfPresent(Int.self, forKey: .maxPerDay))
            .flatMap { $0 } ?? Self.defaultMaxPerDay
    }
}

/// What the sweep noticed, reduced to exactly what the policy needs.
///
/// ``isTransition`` is the load-bearing field. "CI is red" is a *state* and would fire on every
/// sweep, and on the first sweep after a fresh install it would fire for every red pull request
/// the account has. "CI turned red" is an *edge*, and only an edge may start a run (ADR 0016).
public struct AutoDelegationSignal: Sendable, Equatable {
    /// Which condition fired.
    public var trigger: AutoDelegationTrigger
    /// The pull request, as the sweep knows it.
    public var pullRequest: PullRequestSummary
    /// Whether Shepherd *saw the change happen*: the previous sweep had this pull request and it
    /// was not already in the triggering state.
    public var isTransition: Bool

    /// Creates a signal.
    /// - Parameters:
    ///   - trigger: Which condition fired.
    ///   - pullRequest: The pull request.
    ///   - isTransition: Whether the change was observed rather than found already true.
    public init(
        trigger: AutoDelegationTrigger,
        pullRequest: PullRequestSummary,
        isTransition: Bool
    ) {
        self.trigger = trigger
        self.pullRequest = pullRequest
        self.isTransition = isTransition
    }
}

/// Why a signal did not start a delegation.
///
/// Ordered like ``AutoDelegationPolicy``'s checks, and complete: every path out of the policy
/// that is not a start names one of these, so "why did nothing happen?" always has an answer.
public enum AutoDelegationSkipReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// Automatic delegation is switched off.
    case disabled
    /// This particular condition is not ticked.
    case triggerNotArmed
    /// The pull request is not the user's own work.
    case notOwnPullRequest
    /// The state was already like this when Shepherd first saw the pull request.
    case notATransition
    /// No agent CLI, or no local clone for this repository.
    case notConfigured
    /// A rule already fired for this pull request at this head commit.
    case alreadyHandled
    /// A delegation for this pull request is already running (ADR 0011's one-per-PR rule).
    case delegationRunning
    /// As many automatic delegations are running as the user allows.
    case concurrencyCapReached
    /// Today's budget is used up.
    case dailyCapReached

    /// Whether the reason is "a rule would have fired, but a cap stopped it".
    ///
    /// These are the only skips worth a notification: the user asked for automation and did not
    /// get it. Every other reason is a normal non-event that happens dozens of times an hour.
    public var isCap: Bool {
        switch self {
        case .concurrencyCapReached, .dailyCapReached:
            return true
        case .disabled, .triggerNotArmed, .notOwnPullRequest, .notATransition, .notConfigured,
             .alreadyHandled, .delegationRunning:
            return false
        }
    }
}

/// A delegation a rule wants started.
public struct AutoDelegationPlan: Sendable, Equatable {
    /// Which condition produced it.
    public var trigger: AutoDelegationTrigger
    /// The pull request to work on.
    public var pullRequest: PullRequestSummary
    /// The rendered task text — the *editable* half of the delegation prompt.
    public var task: String

    /// Creates a plan.
    /// - Parameters:
    ///   - trigger: Which condition produced it.
    ///   - pullRequest: The pull request.
    ///   - task: The rendered task text.
    public init(trigger: AutoDelegationTrigger, pullRequest: PullRequestSummary, task: String) {
        self.trigger = trigger
        self.pullRequest = pullRequest
        self.task = task
    }

    /// The `(pull request, head commit)` pair this plan is deduplicated on.
    public var fingerprint: AutoDelegationLedger.Fingerprint {
        AutoDelegationLedger.Fingerprint(
            prID: pullRequest.id,
            headRefOid: pullRequest.headRefOid,
            trigger: trigger
        )
    }
}

/// What the policy decided.
public enum AutoDelegationDecision: Sendable, Equatable {
    /// Start this delegation.
    case start(AutoDelegationPlan)
    /// Do nothing, for this reason.
    case skip(AutoDelegationSkipReason)

    /// The plan, when the decision was to start.
    public var plan: AutoDelegationPlan? {
        if case .start(let plan) = self { return plan }
        return nil
    }

    /// The reason, when the decision was to skip.
    public var skipReason: AutoDelegationSkipReason? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}

/// What automatic delegation has already done, persisted so a relaunch does not forget it.
///
/// Two jobs, both about *not doing something twice*:
///
/// - ``handled`` is the deduplication key set: one start per `(pull request, head commit)`, ever.
///   A rebuild of the same commit, a second red check, a reopened pull request or an app restart
///   therefore cannot start a second run for work the agent has already been sent.
/// - ``day`` plus ``startsToday`` is the daily budget, which resets when the calendar day
///   changes rather than 24 hours after the last start.
///
/// It is a plain value so the whole thing is testable without a store, and machine-local by
/// design: it records what *this* Mac did and never travels in the settings document (ADR 0014).
public struct AutoDelegationLedger: Sendable, Codable, Equatable {
    /// One `(pull request, head commit)` pair a rule already fired for.
    public struct Fingerprint: Sendable, Codable, Hashable {
        /// The pull request's node id.
        public var prID: String
        /// The head commit the rule fired at.
        public var headRefOid: String
        /// Which condition fired, for the audit trail.
        public var trigger: AutoDelegationTrigger

        /// Creates a fingerprint.
        /// - Parameters:
        ///   - prID: The pull request's node id.
        ///   - headRefOid: The head commit.
        ///   - trigger: Which condition fired.
        public init(prID: String, headRefOid: String, trigger: AutoDelegationTrigger) {
            self.prID = prID
            self.headRefOid = headRefOid
            self.trigger = trigger
        }

        /// Whether this fingerprint is about the same commit of the same pull request.
        ///
        /// Deliberately trigger-blind: once the agent has been sent to a commit, a *second*
        /// condition on that same commit is not new work.
        /// - Parameter other: The other fingerprint.
        public func addressesSameCommit(as other: Fingerprint) -> Bool {
            prID == other.prID && headRefOid == other.headRefOid
        }
    }

    /// How many fingerprints are kept. Beyond this the oldest are forgotten — a pull request
    /// whose head commit is 200 automatic starts old is not coming back.
    public static let maxFingerprints = 200

    /// The calendar day ``startsToday`` counts, as `yyyy-MM-dd`; empty on a fresh install.
    public var day: String
    /// How many automatic delegations started on ``day``.
    public var startsToday: Int
    /// The pairs already handled, oldest first.
    public var handled: [Fingerprint]

    /// Creates a ledger.
    /// - Parameters:
    ///   - day: The day the counter belongs to.
    ///   - startsToday: How many starts that day has seen.
    ///   - handled: The pairs already handled, oldest first.
    public init(day: String = "", startsToday: Int = 0, handled: [Fingerprint] = []) {
        self.day = day
        self.startsToday = startsToday
        self.handled = handled
    }

    private enum CodingKeys: String, CodingKey {
        case day, startsToday, handled
    }

    /// Decodes tolerantly, for the same reason ``AutoDelegationRules`` does: a ledger written by
    /// another build must never be thrown away wholesale, because losing it means re-triggering.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? container.decodeIfPresent(String.self, forKey: .day)).flatMap { $0 } ?? ""
        startsToday = (try? container.decodeIfPresent(Int.self, forKey: .startsToday))
            .flatMap { $0 } ?? 0
        handled = (try? container.decodeIfPresent([Fingerprint].self, forKey: .handled))
            .flatMap { $0 } ?? []
    }

    /// The `yyyy-MM-dd` stamp of a date in a time zone.
    ///
    /// Built from date components and plain string padding rather than from a `DateFormatter` or
    /// `String(format:)`: no locale can turn this into a Japanese calendar or a two-digit year, no
    /// `CVarArg` width surprise can differ between macOS and Linux, and the result is stable
    /// across launches and machines.
    /// - Parameters:
    ///   - date: The moment to stamp.
    ///   - timeZone: The time zone that decides where the day boundary is.
    public static func dayStamp(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = padded(parts.year ?? 0, to: 4)
        let month = padded(parts.month ?? 0, to: 2)
        let day = padded(parts.day ?? 0, to: 2)
        return "\(year)-\(month)-\(day)"
    }

    /// Left-pads a non-negative number with zeros.
    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(max(0, value))
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// Whether a rule already fired for this pull request at this head commit.
    /// - Parameter fingerprint: The pair to look for.
    public func hasHandled(_ fingerprint: Fingerprint) -> Bool {
        handled.contains { $0.addressesSameCommit(as: fingerprint) }
    }

    /// How many automatic delegations started on the calendar day of `date`.
    ///
    /// Zero for any day other than ``day``: the counter belongs to one day and is not carried
    /// over, which is what makes the cap "five a day" rather than "five ever".
    /// - Parameters:
    ///   - date: The moment whose day is asked about.
    ///   - timeZone: The time zone that decides where the day boundary is.
    public func starts(onDayOf date: Date, timeZone: TimeZone) -> Int {
        Self.dayStamp(for: date, timeZone: timeZone) == day ? startsToday : 0
    }

    /// The ledger as it looks after a start was allowed.
    ///
    /// Pure, so the store is a thin wrapper around it and the counting rules are unit-tested
    /// without `UserDefaults`.
    /// - Parameters:
    ///   - fingerprint: What was started.
    ///   - date: When.
    ///   - timeZone: The time zone that decides where the day boundary is.
    /// - Returns: The updated ledger.
    public func recording(
        _ fingerprint: Fingerprint,
        at date: Date,
        timeZone: TimeZone
    ) -> AutoDelegationLedger {
        let stamp = Self.dayStamp(for: date, timeZone: timeZone)
        var updated = self
        updated.day = stamp
        updated.startsToday = (stamp == day ? startsToday : 0) + 1
        // Re-recording the same commit must not grow the list: the dedup check already refuses
        // it, and a duplicate here would waste one of the kept slots.
        updated.handled.removeAll { $0.addressesSameCommit(as: fingerprint) }
        updated.handled.append(fingerprint)
        if updated.handled.count > Self.maxFingerprints {
            updated.handled.removeFirst(updated.handled.count - Self.maxFingerprints)
        }
        return updated
    }
}

/// Everything outside the signal that the decision depends on.
public struct AutoDelegationContext: Sendable, Equatable {
    /// The user's rules.
    public var rules: AutoDelegationRules
    /// Whether a delegation for this repository could actually run right now: the agent CLI was
    /// found and a local clone is configured (ADR 0011). Without it a start would produce a
    /// sheet stuck on "no checkout" while burning a dedup slot and a day of budget.
    public var isConfigured: Bool
    /// Whether a delegation for this pull request is already in flight.
    public var hasRunningDelegation: Bool
    /// How many automatic delegations are running right now.
    public var runningAutomaticCount: Int
    /// What automatic delegation has already done.
    public var ledger: AutoDelegationLedger
    /// The clock.
    public var now: Date
    /// The time zone that decides where the day boundary is.
    public var timeZone: TimeZone

    /// Creates a context.
    public init(
        rules: AutoDelegationRules,
        isConfigured: Bool,
        hasRunningDelegation: Bool,
        runningAutomaticCount: Int,
        ledger: AutoDelegationLedger,
        now: Date,
        timeZone: TimeZone = .current
    ) {
        self.rules = rules
        self.isConfigured = isConfigured
        self.hasRunningDelegation = hasRunningDelegation
        self.runningAutomaticCount = runningAutomaticCount
        self.ledger = ledger
        self.now = now
        self.timeZone = timeZone
    }
}

/// Renders the task text an automatic delegation runs with.
///
/// The template is the user's, the substitutions are Shepherd's, and neither carries a single
/// line of code or review text: the agent gets the *situation*, and reads the repository itself.
public enum AutoDelegationPrompt {
    /// `{number}` — the pull request number.
    public static let numberPlaceholder = "{number}"
    /// `{repo}` — `owner/name`.
    public static let repoPlaceholder = "{repo}"
    /// `{title}` — the pull request title.
    public static let titlePlaceholder = "{title}"
    /// `{branch}` — the head branch name.
    public static let branchPlaceholder = "{branch}"
    /// `{sha}` — the first twelve characters of the head commit.
    public static let shaPlaceholder = "{sha}"
    /// `{checks}` — a one-line summary of the CI rollup.
    public static let checksPlaceholder = "{checks}"
    /// `{reason}` — which condition fired.
    public static let reasonPlaceholder = "{reason}"

    /// Every placeholder, in the order the Settings help text lists them.
    public static let placeholders = [
        numberPlaceholder, repoPlaceholder, titlePlaceholder, branchPlaceholder,
        shaPlaceholder, checksPlaceholder, reasonPlaceholder,
    ]

    /// A one-line description of the head commit's CI state.
    ///
    /// Unlocalised: it is interpolated into the agent's prompt.
    /// - Parameter pullRequest: The pull request.
    public static func checksSummary(for pullRequest: PullRequestSummary) -> String {
        guard let rollup = pullRequest.checkRollup else {
            return "no checks are reported for the head commit"
        }
        switch rollup.state {
        case .failure:
            guard rollup.failureCount > 0, rollup.total > 0 else {
                return "the rolled-up CI state is failing"
            }
            return "\(rollup.failureCount) of \(rollup.total) checks are failing"
        case .pending:
            return "checks are still running"
        case .success:
            return "all checks are green"
        case .none:
            return "no checks are reported for the head commit"
        }
    }

    /// Fills the placeholders of a template.
    /// - Parameters:
    ///   - template: The user's template.
    ///   - signal: What the sweep noticed.
    /// - Returns: The task text, trimmed.
    public static func render(template: String, signal: AutoDelegationSignal) -> String {
        let pullRequest = signal.pullRequest
        let substitutions: [(String, String)] = [
            (numberPlaceholder, String(pullRequest.number)),
            (repoPlaceholder, pullRequest.repo.fullName),
            (titlePlaceholder, pullRequest.title),
            (branchPlaceholder, pullRequest.headRefName),
            (shaPlaceholder, String(pullRequest.headRefOid.prefix(12))),
            (checksPlaceholder, checksSummary(for: pullRequest)),
            (reasonPlaceholder, signal.trigger.promptDescription),
        ]
        var text = template
        for (placeholder, value) in substitutions {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied template would produce a delegation with no task at all, which the sheet
        // refuses to start; fall back to the default rather than starting nothing.
        guard !trimmed.isEmpty else {
            return render(
                template: AutoDelegationRules.defaultPromptTemplate,
                signal: signal
            )
        }
        return trimmed
    }
}

/// Decides whether a sweep signal starts a delegation (ADR 0016).
///
/// The whole product risk of this feature is "did Shepherd run an agent I did not ask it to
/// run", so the answer is a pure function over values: rules, the pull request, what has already
/// happened, and the clock. No sweep, no CLI, no database, no `Process`. The app layer supplies
/// the inputs, performs the start and persists the ledger — it makes no decisions of its own.
public enum AutoDelegationPolicy {
    /// Whether a pull request counts as the user's own work.
    ///
    /// Two ways to qualify, and both need an *own-facet* relation rather than mere visibility
    /// (ADR 0005 fills ``ShepherdCore/Relation`` from the facet query that found the row):
    ///
    /// - the signed-in user opened it (`author:@me`), or
    /// - a recognised coding agent opened it (ADR 0008 provenance) **and** it is assigned to the
    ///   user (`assignee:@me`) — the agent-on-my-behalf case, which is the normal shape of a
    ///   delegated task coming back.
    ///
    /// `mentioned` and the `involves:@me` catch-all deliberately do not qualify: being copied in
    /// on somebody else's pull request must never start an agent on it.
    /// - Parameter pullRequest: The pull request.
    public static func isOwn(_ pullRequest: PullRequestSummary) -> Bool {
        if pullRequest.myRelation.contains(.author) { return true }
        return pullRequest.author.kind.agentIdentity != nil
            && pullRequest.myRelation.contains(.assigned)
    }

    /// Decides what to do about one signal.
    ///
    /// The checks run in a fixed order, so the reason a skip reports never depends on evaluation
    /// order: switched off → condition not armed → not mine → not a transition → not configured
    /// → already handled → already delegating → concurrency cap → daily cap.
    /// - Parameters:
    ///   - signal: What the sweep noticed.
    ///   - context: Rules, current state, ledger and clock.
    /// - Returns: The decision.
    public static func decide(
        _ signal: AutoDelegationSignal,
        context: AutoDelegationContext
    ) -> AutoDelegationDecision {
        guard context.rules.isEnabled else { return .skip(.disabled) }
        guard context.rules.triggers.contains(signal.trigger) else {
            return .skip(.triggerNotArmed)
        }
        guard isOwn(signal.pullRequest) else { return .skip(.notOwnPullRequest) }
        // The edge, not the state. See `AutoDelegationSignal.isTransition`.
        guard signal.isTransition else { return .skip(.notATransition) }
        guard context.isConfigured else { return .skip(.notConfigured) }

        let plan = AutoDelegationPlan(
            trigger: signal.trigger,
            pullRequest: signal.pullRequest,
            task: AutoDelegationPrompt.render(
                template: context.rules.promptTemplate,
                signal: signal
            )
        )

        guard !context.ledger.hasHandled(plan.fingerprint) else { return .skip(.alreadyHandled) }
        // ADR 0011's one-delegation-per-pull-request rule is the DelegationCenter's, and an
        // automatic start is the last thing that may bend it.
        guard !context.hasRunningDelegation else { return .skip(.delegationRunning) }
        guard context.runningAutomaticCount < context.rules.concurrencyCap else {
            return .skip(.concurrencyCapReached)
        }
        guard context.ledger.starts(onDayOf: context.now, timeZone: context.timeZone)
            < context.rules.dailyCap
        else {
            return .skip(.dailyCapReached)
        }
        return .start(plan)
    }
}
