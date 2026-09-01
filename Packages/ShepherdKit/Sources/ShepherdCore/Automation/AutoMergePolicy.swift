import Foundation

/// The rules a pull request has to satisfy before Shepherd merges it without being asked
/// (ADR 0018).
///
/// The shape is deliberately the same as ``AutoDelegationRules``: `isEnabled` is a master switch
/// that is off on a fresh install, and with it false nothing in this file can produce a merge —
/// exactly as `webhooksEnabled` gates webhooks (ADR 0012) and `settingsSyncEnabled` gates the
/// bucket (ADR 0014).
///
/// What is *not* a field here is as much of the decision as what is. "Authored by a recognised
/// agent", "every check green", "approved", "not a draft", "no conflicts" are conditions of the
/// feature rather than checkboxes: the founder's decision was one rule — *CI green + approved +
/// agent pull request* — and a switch that let the user drop "approved" would turn an
/// automation that only ever records a decision somebody already made into one that makes the
/// decision. The two optional narrowings below can only ever make the rule *stricter*.
public struct AutoMergeRules: Sendable, Codable, Hashable {
    /// Whether Shepherd may queue merges on its own at all. Off on a fresh install.
    public var isEnabled: Bool
    /// The repositories this may happen in, as `owner/name` patterns (`*` and `?` wildcards).
    ///
    /// **Empty means every repository the sweep brings in**, which is the honest default for a
    /// rule that is already narrow — and the reason the field exists at all is the opposite case:
    /// somebody who wants automatic merges in `schnaq/*` and nowhere near the shared monorepo.
    public var allowedRepositories: [String]
    /// Labels a pull request must *all* carry, or empty for "no label is required".
    ///
    /// The list is the escape hatch for a team that wants the agent — or a human — to opt a
    /// single pull request in, e.g. `automerge`. Compared case-insensitively, because a label a
    /// user typed as `Automerge` in Settings and GitHub renders as `automerge` is one label.
    public var requiredLabels: [String]

    /// Creates a rule set.
    /// - Parameters:
    ///   - isEnabled: Whether merges may be queued automatically.
    ///   - allowedRepositories: The `owner/name` patterns, or empty for all.
    ///   - requiredLabels: Labels that must all be present, or empty for none.
    public init(
        isEnabled: Bool = false,
        allowedRepositories: [String] = [],
        requiredLabels: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.allowedRepositories = allowedRepositories
        self.requiredLabels = requiredLabels
    }

    /// The allow-list entries that could actually match something.
    public var usableRepositories: [String] {
        AutoMergeRules.cleaned(allowedRepositories)
    }

    /// The required labels that could actually be matched.
    public var usableLabels: [String] {
        AutoMergeRules.cleaned(requiredLabels)
    }

    /// Whether a repository is inside the allow-list.
    ///
    /// Case-insensitive and glob-matched through ``GlobPattern``, like
    /// ``ReviewTemplate/matches(_:)``: both shapes the user reaches for — `schnaq/review` for one
    /// repository and `schnaq/*` for everything an owner has — work without a second syntax.
    /// - Parameter repo: The repository the pull request lives in.
    public func allows(_ repo: RepoRef) -> Bool {
        let patterns = usableRepositories
        guard !patterns.isEmpty else { return true }
        return patterns.contains { GlobPattern($0).matches(repo.fullName) }
    }

    /// The required labels a pull request does *not* carry, in the order the user listed them.
    ///
    /// Returned rather than a `Bool` so the UI can name the label that is missing instead of
    /// saying "a label is missing".
    /// - Parameter labels: The pull request's labels, as GitHub returned them.
    public func missingLabels(from labels: [String]) -> [String] {
        let present = Set(labels.map { $0.lowercased() })
        return usableLabels.filter { !present.contains($0.lowercased()) }
    }

    /// The required labels a pull request carries — the justification recorded in the audit log.
    /// - Parameter labels: The pull request's labels.
    public func matchedLabels(from labels: [String]) -> [String] {
        let present = Set(labels.map { $0.lowercased() })
        return usableLabels.filter { present.contains($0.lowercased()) }
    }

    /// Splits a comma-separated settings field into a list.
    ///
    /// The two list fields in Settings are text fields rather than editable tables on purpose:
    /// both lists are short, both are typed once, and a comma-separated line is something a user
    /// can read back at a glance. Newlines count as separators too, so a pasted list works.
    /// - Parameter text: What the user typed.
    /// - Returns: The entries, trimmed, in the order given, without blanks.
    public static func list(from text: String) -> [String] {
        let pieces = text.split(whereSeparator: { character in
            character == "," || character.isNewline
        })
        return cleaned(pieces.map { String($0) })
    }

    /// Renders a list back into the field's text.
    /// - Parameter list: The entries.
    public static func text(from list: [String]) -> String {
        cleaned(list).joined(separator: ", ")
    }

    /// Trims every entry and drops the empty ones.
    private static func cleaned(_ entries: [String]) -> [String] {
        entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, allowedRepositories, requiredLabels
    }

    /// Decodes tolerantly, for the same reason ``AutoDelegationRules`` does: a rule set written by
    /// an older build is missing keys this one expects, and a missing key must cost that key
    /// rather than the whole rule set. An unreadable list falls back to empty — which for both of
    /// these lists means "do not narrow", so it can never *widen* the rule beyond the fixed
    /// conditions ``AutoMergePolicy`` enforces.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled))
            .flatMap { $0 } ?? false
        allowedRepositories = (try? container.decodeIfPresent(
            [String].self,
            forKey: .allowedRepositories
        )).flatMap { $0 } ?? []
        requiredLabels = (try? container.decodeIfPresent([String].self, forKey: .requiredLabels))
            .flatMap { $0 } ?? []
    }
}

/// Why a pull request was not merged automatically.
///
/// Ordered like ``AutoMergePolicy``'s checks, and complete: every path out of the policy that is
/// not a merge names one of these, so "why is this still sitting here?" always has an answer the
/// UI can show. That matters more here than it does for auto-delegation: a merge that silently
/// did not happen looks exactly like a feature that is broken.
public enum AutoMergeSkipReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// Automatic merging is switched off.
    case disabled
    /// A human (or an unrecognised bot) opened it — v1 never merges those.
    case notAgentAuthored
    /// The repository is not on the allow-list.
    case repositoryNotAllowed
    /// A required label is missing.
    case requiredLabelMissing
    /// The pull request is still a draft.
    case draft
    /// The head commit has no checks at all, so there is nothing green about it.
    case noChecks
    /// At least one check failed, or checks are still running.
    case checksNotGreen
    /// GitHub does not report an approving review decision.
    case notApproved
    /// GitHub reports conflicts, or has not finished computing mergeability.
    case notMergeable
    /// A merge was already queued for this pull request at this head commit.
    case alreadyQueued
    /// The outbox still holds an unsent write for this pull request.
    case writeInFlight
}

/// What the policy decided about one pull request.
public enum AutoMergeDecision: Sendable, Equatable {
    /// Queue a merge, with this head commit as the merge precondition.
    case merge(expectedHeadOid: String)
    /// Do nothing, for this reason.
    case skip(AutoMergeSkipReason)

    /// The head commit to merge against, when the decision was to merge.
    public var expectedHeadOid: String? {
        if case .merge(let oid) = self { return oid }
        return nil
    }

    /// The reason, when the decision was to skip.
    public var skipReason: AutoMergeSkipReason? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}

/// One line of the audit log: a merge Shepherd queued on its own, and what justified it.
///
/// Everything needed to render the line is copied in rather than looked up — the pull request is
/// merged moments later and the sweep prunes the row, so a log that resolved ids against the
/// inbox would go blank exactly when it is most needed.
public struct AutoMergeAuditEntry: Sendable, Codable, Hashable, Identifiable {
    /// The pull request's node id — the deduplication key's first half.
    public var prID: String
    /// `owner/name#number`, copied in so the line can name a pull request the inbox no longer has.
    public var slug: String
    /// The pull request title at the time.
    public var title: String
    /// The head commit the merge was queued against — the deduplication key's second half, and
    /// the `expectedHeadOid` the outbox row carries.
    public var headRefOid: String
    /// The merge method, as GitHub's raw value (`"merge"`, `"squash"`, `"rebase"`).
    public var mergeMethod: String
    /// The author's login, so the log says *which* agent's work was merged.
    public var authorLogin: String
    /// How many checks were green on that head commit.
    public var checkCount: Int
    /// The required labels the pull request carried, or empty when no label was required.
    public var matchedLabels: [String]
    /// When the merge was queued (not when it reached GitHub — the outbox reports that).
    public var queuedAt: Date

    /// Creates an entry.
    public init(
        prID: String,
        slug: String,
        title: String,
        headRefOid: String,
        mergeMethod: String,
        authorLogin: String,
        checkCount: Int,
        matchedLabels: [String] = [],
        queuedAt: Date
    ) {
        self.prID = prID
        self.slug = slug
        self.title = title
        self.headRefOid = headRefOid
        self.mergeMethod = mergeMethod
        self.authorLogin = authorLogin
        self.checkCount = checkCount
        self.matchedLabels = matchedLabels
        self.queuedAt = queuedAt
    }

    /// `AutoMergeAuditEntry` is identified by the pair it deduplicates on, so the identity is
    /// stable across launches and a list can be rendered without an index.
    public var id: String { "\(prID)@\(headRefOid)" }

    /// The first twelve characters of the head commit — what a human recognises a commit by.
    public var shortHead: String { String(headRefOid.prefix(12)) }

    private enum CodingKeys: String, CodingKey {
        case prID, slug, title, headRefOid, mergeMethod, authorLogin, checkCount
        case matchedLabels, queuedAt
    }

    /// Decodes tolerantly, like every other persisted value in this folder: a log line written by
    /// another build must not cost the whole log, because losing the log means losing the
    /// deduplication with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prID = (try? container.decodeIfPresent(String.self, forKey: .prID)).flatMap { $0 } ?? ""
        slug = (try? container.decodeIfPresent(String.self, forKey: .slug)).flatMap { $0 } ?? ""
        title = (try? container.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        headRefOid = (try? container.decodeIfPresent(String.self, forKey: .headRefOid))
            .flatMap { $0 } ?? ""
        mergeMethod = (try? container.decodeIfPresent(String.self, forKey: .mergeMethod))
            .flatMap { $0 } ?? ""
        authorLogin = (try? container.decodeIfPresent(String.self, forKey: .authorLogin))
            .flatMap { $0 } ?? ""
        checkCount = (try? container.decodeIfPresent(Int.self, forKey: .checkCount))
            .flatMap { $0 } ?? 0
        matchedLabels = (try? container.decodeIfPresent([String].self, forKey: .matchedLabels))
            .flatMap { $0 } ?? []
        queuedAt = (try? container.decodeIfPresent(Date.self, forKey: .queuedAt))
            .flatMap { $0 } ?? Date(timeIntervalSince1970: 0)
    }
}

/// What automatic merging has already done on this Mac.
///
/// The ledger **is** the audit log, and that is the one structural decision in this type: one
/// list, so what Shepherd remembers and what it shows the user cannot disagree. A separate
/// dedup set plus a separate log would be two things to keep in step, and the moment they
/// disagreed the user would be told about a merge that could still be queued a second time.
///
/// The key is `(prID, headRefOid)`: at most one queued merge per pull request per head commit,
/// ever. A new push is a new head and therefore new work — which is the same rule
/// ``AutoDelegationLedger`` uses, and for the same reason. It is machine-local by design and
/// never travels in the settings document (ADR 0014): the *rules* are a preference, "this Mac
/// already queued that" is one machine's automation state.
public struct AutoMergeLedger: Sendable, Codable, Equatable {
    /// How many entries are kept. Beyond this the oldest are forgotten: a pull request whose head
    /// commit is a hundred automatic merges old has been merged, closed, or pushed to since.
    public static let maxEntries = 100

    /// The merges queued so far, oldest first.
    public var entries: [AutoMergeAuditEntry]

    /// Creates a ledger.
    /// - Parameter entries: The entries, oldest first.
    public init(entries: [AutoMergeAuditEntry] = []) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Decodes tolerantly — see ``AutoMergeAuditEntry/init(from:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? container.decodeIfPresent([AutoMergeAuditEntry].self, forKey: .entries))
            .flatMap { $0 } ?? []
    }

    /// Whether a merge was already queued for this pull request at this head commit.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - headRefOid: The head commit.
    public func hasQueued(prID: String, headRefOid: String) -> Bool {
        entries.contains { $0.prID == prID && $0.headRefOid == headRefOid }
    }

    /// The ledger as it looks after a merge was queued.
    ///
    /// Pure, so the store is a thin wrapper around it and the trimming rules are unit-tested
    /// without `UserDefaults`.
    /// - Parameter entry: What was queued.
    /// - Returns: The updated ledger.
    public func recording(_ entry: AutoMergeAuditEntry) -> AutoMergeLedger {
        var updated = self
        // Re-recording the same pair must not grow the list: the dedup check already refuses it,
        // and a duplicate here would waste one of the kept slots *and* show the same merge twice.
        updated.entries.removeAll { $0.id == entry.id }
        updated.entries.append(entry)
        if updated.entries.count > Self.maxEntries {
            updated.entries.removeFirst(updated.entries.count - Self.maxEntries)
        }
        return updated
    }

    /// The most recent entries, newest first — what the Automation settings tab lists.
    /// - Parameter limit: How many to return.
    public func recent(limit: Int) -> [AutoMergeAuditEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.suffix(limit).reversed())
    }
}

/// Decides whether Shepherd merges a pull request on its own (ADR 0018).
///
/// The sibling of ``AutoDelegationPolicy`` and split the same way: the whole product risk sits in
/// "did Shepherd merge something I would not have merged", so the answer is a pure function over
/// values — the pull request as the sweep knows it, the rules, what has already been queued — and
/// the app layer only supplies the inputs and performs the write through the ordinary outbox.
/// Nothing here talks to GitHub, to the database or to the outbox.
public enum AutoMergePolicy {
    /// Whether the checks on a head commit count as green.
    ///
    /// Stricter than "the rollup is not failing", and stricter than ``BulkTriagePlan/make`` on
    /// purpose: a pull request with **no** checks configured is *not* green, because there is
    /// nothing to be green about. Bulk triage may act on such a pull request when the user picks
    /// it by hand and carries a visible note; nobody is picking anything by hand here, so the
    /// same shape has to be a refusal. This is exactly
    /// ``BulkTriagePlan/greenAgentPullRequests(in:)``'s standard — the preselect a human still
    /// has to confirm — which is the least the unattended path may demand.
    /// - Parameter pullRequest: The pull request.
    public static func hasGreenChecks(_ pullRequest: PullRequestSummary) -> Bool {
        guard let rollup = pullRequest.checkRollup else { return false }
        return rollup.state == .success && rollup.total > 0
    }

    /// Whether a recognised coding agent opened the pull request (ADR 0008 provenance).
    ///
    /// Always required in v1. The feature exists for the agent-PR flood (ADR 0015's premise), and
    /// a colleague's pull request being merged by somebody else's Mac on a rule they cannot see
    /// is not a feature anybody asked for.
    /// - Parameter pullRequest: The pull request.
    public static func isAgentAuthored(_ pullRequest: PullRequestSummary) -> Bool {
        pullRequest.author.kind.agentIdentity != nil
    }

    /// Decides what to do about one pull request.
    ///
    /// The checks run in a fixed order, so the reason a skip reports never depends on evaluation
    /// order: switched off → not an agent's pull request → repository not allowed → a required
    /// label is missing → draft → no checks → checks not green → not approved → not mergeable →
    /// already queued for this head → a write for this pull request is still in flight.
    ///
    /// The last two are what stop the same merge going out twice. The ledger covers restarts and
    /// every later sweep of the same commit; the outbox covers the seconds between queueing and
    /// draining, and the much longer window in which a merge sits parked as conflicted waiting
    /// for the user (ADR 0006) — queueing a second one behind it would be the one way this
    /// feature could produce a pile of writes nobody asked for.
    /// - Parameters:
    ///   - pullRequest: The inbox row, as the last sweep wrote it.
    ///   - rules: The user's rules.
    ///   - ledger: What has already been queued on this Mac.
    ///   - existingOutbox: The node ids of pull requests the outbox still holds a write for —
    ///     pending, in flight or parked. Passed in as a set rather than read here, because this
    ///     function may not touch the database.
    /// - Returns: The decision.
    public static func decide(
        pullRequest: PullRequestSummary,
        rules: AutoMergeRules,
        ledger: AutoMergeLedger,
        existingOutbox: Set<String>
    ) -> AutoMergeDecision {
        guard rules.isEnabled else { return .skip(.disabled) }
        guard isAgentAuthored(pullRequest) else { return .skip(.notAgentAuthored) }
        guard rules.allows(pullRequest.repo) else { return .skip(.repositoryNotAllowed) }
        guard rules.missingLabels(from: pullRequest.labels).isEmpty else {
            return .skip(.requiredLabelMissing)
        }
        guard !pullRequest.isDraft else { return .skip(.draft) }
        guard let rollup = pullRequest.checkRollup, rollup.total > 0 else {
            return .skip(.noChecks)
        }
        guard rollup.state == .success else { return .skip(.checksNotGreen) }
        guard pullRequest.reviewDecision == .approved else { return .skip(.notApproved) }
        // Unknown mergeability is a refusal, not a note: the bulk-triage dialog can afford to
        // show "mergeability unknown" and let the user confirm, and there is nobody here to.
        guard pullRequest.mergeable == .mergeable else { return .skip(.notMergeable) }
        guard !ledger.hasQueued(
            prID: pullRequest.id,
            headRefOid: pullRequest.headRefOid
        ) else { return .skip(.alreadyQueued) }
        guard !existingOutbox.contains(pullRequest.id) else { return .skip(.writeInFlight) }
        // The head the *decision* was made on, which is the head the drain re-validates against:
        // a push between this moment and the drain parks the merge instead of merging a commit
        // nothing here ever looked at (ADR 0006).
        return .merge(expectedHeadOid: pullRequest.headRefOid)
    }
}
