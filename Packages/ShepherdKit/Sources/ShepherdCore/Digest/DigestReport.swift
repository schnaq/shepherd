import Foundation

/// One kind of line a morning digest can carry.
///
/// The declaration order *is* the reading order of the digest, and it is a priority order rather
/// than a chronological one: what somebody else is waiting for comes first, then the work that is
/// one click from done, then the user's own blocked pull requests, and last the one section that is
/// about Shepherd itself — reviews it could not send.
///
/// A closed vocabulary on purpose. The digest is assembled by walking ``allCases``, so a new kind
/// is one case plus one branch of an exhaustive switch, and it cannot be silently forgotten.
public enum DigestSectionKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Pull requests that asked for the user's review inside the digest's window.
    case newReviewRequests
    /// Green, agent-authored pull requests that only need an approval or a merge.
    case greenAgentPullRequests
    /// The user's own pull requests with red CI or a change request on them.
    case ownPullRequestsNeedingAttention
    /// Queued reviews the outbox parked because the pull request moved on (ADR 0006).
    case parkedReviews

    /// Whether the section is about a *change* inside the digest's window rather than about
    /// standing state.
    ///
    /// Only one section is windowed, and the asymmetry is deliberate — see
    /// ``DigestReport/make(pullRequests:parkedReviewCount:windowStart:now:maxItemsPerSection:)``.
    public var isWindowed: Bool {
        switch self {
        case .newReviewRequests:
            return true
        case .greenAgentPullRequests, .ownPullRequestsNeedingAttention, .parkedReviews:
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
/// - **It is tier 1.** Every number here comes out of ``PullRequestSummary`` values the sweep
///   already wrote to SQLite. There is no network call anywhere in this file and none anywhere in
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

        /// `Item` is identified by its pull request.
        public var id: String { prID }
    }

    /// One line of the digest: a kind, how many, and the first few by name.
    public struct Section: Sendable, Equatable, Identifiable {
        /// Which kind of line this is.
        public let kind: DigestSectionKind
        /// How many pull requests (or parked reviews) the line counts.
        public let count: Int
        /// The first few, in the digest's order. Empty for ``DigestSectionKind/parkedReviews``,
        /// which counts outbox rows rather than pull requests.
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
        /// Zero for a section that names nothing at all — ``DigestSectionKind/parkedReviews`` is a
        /// bare count, and "3 parked reviews, and 3 more" would count the same rows twice.
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
    /// - Parameters:
    ///   - pullRequests: Every row the local inbox holds. Not filtered by the rail's facets: a
    ///     digest is about the account, not about whichever filter was left selected last night.
    ///   - parkedReviewCount: How many outbox rows are parked as conflicted (ADR 0006).
    ///   - windowStart: The start of the span, from ``DigestSchedule/window(now:lastDeliveredAt:calendar:)``.
    ///   - now: The clock.
    ///   - maxItemsPerSection: How many pull requests a section names.
    /// - Returns: The report. ``isEmpty`` when there is nothing to say.
    public static func make(
        pullRequests: [PullRequestSummary],
        parkedReviewCount: Int,
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
            case .greenAgentPullRequests:
                append(
                    &sections,
                    kind,
                    rows: BulkTriagePlan.greenAgentPullRequests(in: pullRequests),
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
}
