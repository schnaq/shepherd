import Foundation

/// One kind of line a morning digest can carry.
///
/// The declaration order *is* the reading order of the digest, and it is a priority order rather
/// than a chronological one: what somebody else is waiting for comes first — a review request,
/// then an issue somebody put your name on — then the work that is one click from done and the
/// work an agent finished, then the user's own blocked pull requests, and last the two sections
/// that are about Shepherd itself: writes it could not send — parked first, because those still
/// have a draft to re-apply, then the ones it gave up on entirely.
///
/// A closed vocabulary on purpose. The digest is assembled by walking ``allCases``, so a new kind
/// is one case plus one branch of an exhaustive switch, and it cannot be silently forgotten.
public enum DigestSectionKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Pull requests that asked for the user's review inside the digest's window.
    case newReviewRequests
    /// Issues assigned to the user that moved inside the digest's window (ADR 0032).
    case issuesAssignedToYou
    /// Green, agent-authored pull requests that only need an approval or a merge.
    case greenAgentPullRequests
    /// Issues an agent's pull request closed as completed (ADR 0032).
    case agentPullRequestsThatClosedAnIssue
    /// The user's own pull requests with red CI or a change request on them.
    case ownPullRequestsNeedingAttention
    /// Queued reviews the outbox parked because the pull request moved on (ADR 0006).
    case parkedReviews
    /// Queued writes the outbox gave up on, because retrying them cannot help (ADR 0006).
    ///
    /// The section that exists because nothing else reported it: a row in
    /// ``OutboxState/failed`` is neither waiting nor parked, it never leaves that state on its
    /// own, and a digest that is meant to say what happened overnight would otherwise stay silent
    /// about the one thing that is certainly not going to fix itself.
    case failedWrites

    /// Whether the section is about a *change* inside the digest's window rather than about
    /// standing state.
    ///
    /// Two of the seven are windowed, and the asymmetry is deliberate — see
    /// ``DigestReport/make(pullRequests:issues:parkedReviewCount:failedWriteCount:windowStart:now:maxItemsPerSection:)``.
    public var isWindowed: Bool {
        switch self {
        case .newReviewRequests, .issuesAssignedToYou:
            return true
        case .greenAgentPullRequests, .agentPullRequestsThatClosedAnIssue,
             .ownPullRequestsNeedingAttention, .parkedReviews, .failedWrites:
            return false
        }
    }

    /// Whether the section names issues rather than pull requests.
    ///
    /// Read by the presentation layer, which has one destination for each: a section of issues
    /// hands the inbox's content-kind picker over rather than applying a rail state that means
    /// nothing on that side.
    public var isAboutIssues: Bool {
        switch self {
        case .issuesAssignedToYou, .agentPullRequestsThatClosedAnIssue:
            return true
        case .newReviewRequests, .greenAgentPullRequests, .ownPullRequestsNeedingAttention,
             .parkedReviews, .failedWrites:
            return false
        }
    }
}

/// What one morning digest says, derived from the local database and from nothing else.
///
/// A pure value, and that is the whole point of the type: a digest is generated **unattended**, so
/// every judgement in it — what counts as new, what counts as ready, what counts as blocked, and
/// what is worth waking someone for — has to be a testable function rather than something
/// discovered once a day in a notification banner.
///
/// Two properties are load-bearing:
///
/// - **It is tier 1.** Every number here comes out of ``PullRequestSummary`` and
///   ``IssueRowSummary`` values the two sweeps already wrote to SQLite. There is no network call anywhere in this file and none anywhere in
///   the digest's path: the feature runs while nobody is watching, so a digest that phoned an
///   endpoint would be exactly the kind of unattended traffic CONTRIBUTING.md forbids.
/// - **An empty report is a real answer.** ``isEmpty`` is what stops the app from posting "good
///   morning, nothing happened" — no notification, no card. A quiet night should be silent.
///
/// The predicates are borrowed rather than re-stated: ``PullRequestSummary/needsMyReview`` is the
/// inbox rail's own definition, ``BulkTriagePlan/greenAgentPullRequests(in:)`` is the bulk-triage
/// preselect (ADR 0015), and ``AutoDelegationPolicy/isOwn(_:)`` is auto-delegation's "this is my
/// work" test (ADR 0016). A digest that disagreed with the inbox about what needs a review would be
/// worse than no digest.
public struct DigestReport: Sendable, Equatable {
    /// One pull request a digest section names by title.
    public struct Item: Sendable, Equatable, Identifiable {
        /// The pull request's node id, so a click can open it.
        public let prID: String
        /// `owner/name#number`.
        public let slug: String
        /// The pull request title.
        public let title: String

        /// Creates an item.
        /// - Parameters:
        ///   - prID: The pull request's node id.
        ///   - slug: `owner/name#number`.
        ///   - title: The pull request title.
        public init(prID: String, slug: String, title: String) {
            self.prID = prID
            self.slug = slug
            self.title = title
        }

        /// The item as one row of the digest, built from an inbox row.
        /// - Parameter pullRequest: The row to name.
        public init(_ pullRequest: PullRequestSummary) {
            self.init(
                prID: pullRequest.id,
                slug: pullRequest.slug,
                title: pullRequest.title
            )
        }

        /// The item as one row of the digest, built from an issue row (ADR 0032).
        ///
        /// ``prID`` carries the **issue's** node id here. The field is reused generically, the
        /// way ``OutboxItem``'s three target fields are and for the same reason: renaming it
        /// would touch every existing digest call site for no behavioural change, and the two
        /// kinds are already told apart by ``DigestSectionKind/isAboutIssues``.
        /// - Parameter issue: The issue row to name.
        public init(_ issue: IssueRowSummary) {
            self.init(prID: issue.id, slug: issue.slug, title: issue.title)
        }

        /// `Item` is identified by its target.
        public var id: String { prID }
    }

    /// One line of the digest: a kind, how many, and the first few by name.
    public struct Section: Sendable, Equatable, Identifiable {
        /// Which kind of line this is.
        public let kind: DigestSectionKind
        /// How many pull requests, issues or outbox rows the line counts.
        public let count: Int
        /// The first few, in the digest's order. Empty for the two outbox lines
        /// (``DigestSectionKind/parkedReviews``, ``DigestSectionKind/failedWrites``), which count
        /// outbox rows rather than pull requests.
        public let items: [Item]

        /// Creates a section.
        /// - Parameters:
        ///   - kind: Which kind of line this is.
        ///   - count: How many the line counts.
        ///   - items: The first few by name.
        public init(kind: DigestSectionKind, count: Int, items: [Item]) {
            self.kind = kind
            self.count = count
            self.items = items
        }

        /// `Section` is identified by its kind: a report never carries two of the same.
        public var id: String { kind.rawValue }

        /// How many the section counts beyond the ones it names.
        ///
        /// Zero for a section that names nothing at all — the two outbox lines are bare counts,
        /// and "3 parked reviews, and 3 more" would count the same rows twice.
        public var overflow: Int {
            guard !items.isEmpty else { return 0 }
            return max(0, count - items.count)
        }
    }

    /// How many pull requests a section names before it starts counting the rest.
    ///
    /// Three, because the digest is a *glance*: a notification body and a card of a few lines. The
    /// inbox is where a list belongs, and every section's "Show" leads there.
    public static let maxItemsPerSection = 3

    /// The start of the span this digest reports on — the previous digest, or a first-run window.
    public let windowStart: Date
    /// When the digest was built, which is also the end of its span.
    public let generatedAt: Date
    /// The lines, in ``DigestSectionKind`` order. A section with nothing in it is never produced.
    public let sections: [Section]

    /// Creates a report.
    /// - Parameters:
    ///   - windowStart: The start of the reported span.
    ///   - generatedAt: When the digest was built.
    ///   - sections: The lines, in ``DigestSectionKind`` order.
    public init(windowStart: Date, generatedAt: Date, sections: [Section]) {
        self.windowStart = windowStart
        self.generatedAt = generatedAt
        self.sections = sections
    }

    /// Whether there is nothing at all to report — no notification, no card.
    public var isEmpty: Bool { sections.isEmpty }

    /// One section by kind, or `nil` when the report has nothing of that kind.
    /// - Parameter kind: The kind to look for.
    public func section(_ kind: DigestSectionKind) -> Section? {
        sections.first { $0.kind == kind }
    }

    /// Everything the digest counts, across all sections.
    public var totalCount: Int { sections.reduce(0) { $0 + $1.count } }

    // MARK: - Building

    /// Builds the digest for a moment, a window and the rows the local database holds.
    ///
    /// The **window applies to one section only**, and that is the interesting decision in this
    /// function. "A review was requested" is an event, so it belongs to the span since the last
    /// digest; "an agent's pull request is green and nobody merged it" and "my pull request is red"
    /// are *states*, and a state that survived the night is exactly what a morning brief is for. A
    /// windowed version of those two would go quiet on the second morning precisely because nothing
    /// had been done about them.
    ///
    /// The windowed section is selected on ``PullRequestSummary/updatedAt`` rather than
    /// `createdAt`: GitHub bumps `updatedAt` when a review is requested, so `createdAt` would miss
    /// the most common overnight shape of all — somebody adding you as a reviewer to a pull request
    /// that is a week old. The price is that a pull request which only got a comment overnight also
    /// appears; it is still one that needs your review and still moved, so the line remains true.
    /// The two issue sections (ADR 0032) split the same way, and the second one is the more
    /// interesting half. "An issue was assigned to you" is an event and is windowed on
    /// `updatedAt`, exactly as the review requests are — GitHub moves `updatedAt` when somebody
    /// assigns you, so `createdAt` would miss the common shape of an old issue handed over this
    /// morning. "An agent's pull request closed one of these as completed" is a **state**, and is
    /// therefore not windowed at all: a digest that dropped it on the second morning would go
    /// quiet precisely because nothing had been done about it. It cannot repeat itself for long
    /// either, and that is a property of the data rather than a cap: the issues sweep captures the
    /// close onto the row and keeps it only for its retention window, then prunes it (ADR 0032's
    /// 2026-09-03 amendment). That capture is also what puts a closed row in front of this section
    /// at all — a sweep that searches `is:open` and prunes on sight leaves nothing to read.
    /// - Parameters:
    ///   - pullRequests: Every row the local inbox holds. Not filtered by the rail's facets: a
    ///     digest is about the account, not about whichever filter was left selected last night.
    ///   - issues: Every issue row the local database holds, closed ones included (ADR 0032).
    ///     Defaults to none, which is how a caller that predates the issues inbox builds a
    ///     report — and what it gets is the report it always got.
    ///   - parkedReviewCount: How many outbox rows are parked as conflicted (ADR 0006).
    ///   - failedWriteCount: How many outbox rows the drain gave up on (ADR 0006). Defaults to
    ///     none, which is how a caller that predates the line builds the report it always built.
    ///   - windowStart: The start of the span, from ``DigestSchedule/window(now:lastDeliveredAt:calendar:)``.
    ///   - now: The clock.
    ///   - maxItemsPerSection: How many rows a section names.
    /// - Returns: The report. ``isEmpty`` when there is nothing to say.
    public static func make(
        pullRequests: [PullRequestSummary],
        issues: [IssueRowSummary] = [],
        parkedReviewCount: Int,
        failedWriteCount: Int = 0,
        windowStart: Date,
        now: Date = Date(),
        maxItemsPerSection: Int = DigestReport.maxItemsPerSection
    ) -> DigestReport {
        var sections: [Section] = []
        for kind in DigestSectionKind.allCases {
            switch kind {
            case .newReviewRequests:
                append(
                    &sections,
                    kind,
                    rows: pullRequests.filter {
                        $0.needsMyReview && $0.updatedAt >= windowStart
                    },
                    limit: maxItemsPerSection
                )
            case .issuesAssignedToYou:
                append(
                    &sections,
                    kind,
                    issues: issues.filter {
                        $0.myRelation.contains(.assigned) && $0.updatedAt >= windowStart
                    },
                    limit: maxItemsPerSection
                )
            case .greenAgentPullRequests:
                append(
                    &sections,
                    kind,
                    rows: BulkTriagePlan.greenAgentPullRequests(in: pullRequests),
                    limit: maxItemsPerSection
                )
            case .agentPullRequestsThatClosedAnIssue:
                append(
                    &sections,
                    kind,
                    issues: issues.filter(wasClosedByAnAgent),
                    limit: maxItemsPerSection
                )
            case .ownPullRequestsNeedingAttention:
                append(
                    &sections,
                    kind,
                    rows: pullRequests.filter(needsMyAttention),
                    limit: maxItemsPerSection
                )
            case .parkedReviews:
                // No items: this counts parked *outbox rows*, and the digest deliberately does not
                // reach into the outbox to name them — the count is the actionable part, and
                // Settings → Sync is where they are dealt with.
                guard parkedReviewCount > 0 else { continue }
                sections.append(Section(kind: kind, count: parkedReviewCount, items: []))
            case .failedWrites:
                // Also a bare count, and for the same reason — but a stronger one: a failed row
                // may be an *issue* write, so naming it would mean reaching into the outbox for a
                // kind of target this report does not otherwise carry. Settings → Sync names them.
                guard failedWriteCount > 0 else { continue }
                sections.append(Section(kind: kind, count: failedWriteCount, items: []))
            }
        }
        return DigestReport(windowStart: windowStart, generatedAt: now, sections: sections)
    }

    /// Whether a pull request is the user's own work and is blocked on them.
    ///
    /// Red CI or a change request, on something ``AutoDelegationPolicy/isOwn(_:)`` recognises as
    /// theirs (ADR 0016) — so a pull request the user is merely mentioned on can never turn up in
    /// this line. Drafts are excluded: red CI on work still marked as a draft is not news, and a
    /// digest that said so every morning would train the user to ignore the line that matters.
    /// - Parameter pullRequest: The row to test.
    /// - Returns: `true` when the row belongs in
    ///   ``DigestSectionKind/ownPullRequestsNeedingAttention``.
    public static func needsMyAttention(_ pullRequest: PullRequestSummary) -> Bool {
        guard !pullRequest.isDraft else { return false }
        guard AutoDelegationPolicy.isOwn(pullRequest) else { return false }
        if pullRequest.checkRollup?.state == .failure { return true }
        return pullRequest.reviewDecision == .changesRequested
    }

    /// Whether an agent's pull request closed this issue as completed (ADR 0032).
    ///
    /// Three conditions and no fourth. `stateReason` is GitHub's own raw word, compared
    /// case-insensitively and never branched on beyond this one equality — the type keeps it raw
    /// precisely so a vocabulary GitHub grows costs nothing. `completed` rather than any closed
    /// state, because "not planned" is a decision somebody took *instead* of the work, and
    /// reporting it as an agent's success would be a lie.
    ///
    /// The agent half is ``IssueRowSummary/hasAgentPullRequest``, which reads the linked pull
    /// requests' own provenance — so this line, the rail's facet and the chip beside the link
    /// cannot disagree, and it can only ever understate: the sweep sees at most five links.
    /// - Parameter issue: The issue row to test.
    /// - Returns: `true` when the row belongs in
    ///   ``DigestSectionKind/agentPullRequestsThatClosedAnIssue``.
    public static func wasClosedByAnAgent(_ issue: IssueRowSummary) -> Bool {
        guard issue.state == .closed else { return false }
        guard let reason = issue.stateReason,
              reason.caseInsensitiveCompare("completed") == .orderedSame
        else { return false }
        return issue.hasAgentPullRequest
    }

    /// Appends a section for a set of rows, or nothing at all when the set is empty.
    ///
    /// The order inside a section is ``InboxGrouper/sorted(_:)`` — the inbox's own recency order,
    /// tie-broken on repository and number — so the three pull requests a line names are stable
    /// between two digests built from the same data.
    private static func append(
        _ sections: inout [Section],
        _ kind: DigestSectionKind,
        rows: [PullRequestSummary],
        limit: Int
    ) {
        guard !rows.isEmpty else { return }
        let ordered = InboxGrouper.sorted(rows)
        sections.append(
            Section(
                kind: kind,
                count: ordered.count,
                items: ordered.prefix(max(0, limit)).map { Item($0) }
            )
        )
    }

    /// The same, for a set of issue rows (ADR 0032).
    ///
    /// The order is the issues section's own — most recently updated first, tie-broken on
    /// repository and number — rather than ``InboxGrouper/sorted(_:)``, which takes pull
    /// requests. It is spelled out here because it has to be *total*: two digests built from the
    /// same data must name the same three issues in the same order, and `updatedAt` alone is not
    /// enough for that when a sweep writes several rows in one second.
    private static func append(
        _ sections: inout [Section],
        _ kind: DigestSectionKind,
        issues: [IssueRowSummary],
        limit: Int
    ) {
        guard !issues.isEmpty else { return }
        let ordered = issues.sorted { left, right in
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            if left.repo.fullName != right.repo.fullName {
                return left.repo.fullName < right.repo.fullName
            }
            return left.number < right.number
        }
        sections.append(
            Section(
                kind: kind,
                count: ordered.count,
                items: ordered.prefix(max(0, limit)).map { Item($0) }
            )
        )
    }
}
