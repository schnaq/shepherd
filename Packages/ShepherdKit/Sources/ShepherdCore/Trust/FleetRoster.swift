import Foundation

/// One agent's ledger in one repository: what closed there, and what is open there right now.
///
/// The unit the fleet's per-repository grid is drawn from, and the reason the aggregate above that
/// grid is allowed to exist at all: a rate over four repositories can hide a single bad one, so the
/// screen never shows an average without the rows it averages.
public struct FleetRepositoryRecord: Sendable, Hashable, Identifiable {
    /// The repository, spelled the way the freshest source spells it.
    public var repo: RepoRef
    /// What the agent's closed pull requests in this repository add up to.
    ///
    /// ``TrackRecord/compute(outcomes:subject:repo:since:)`` over this repository's bucket and
    /// nothing else. The fleet adds no arithmetic of its own, so the badge beside an inbox row and
    /// this grid cannot come to different conclusions about the same ninety days (ADR 0027).
    public var record: TrackRecord
    /// How many of the agent's pull requests in this repository are open in the inbox right now.
    public var openCount: Int
    /// How many of those are waiting on the signed-in user's review.
    public var openAwaitingReviewCount: Int
    /// When the most recently counted pull request closed, or `nil` when none did.
    public var lastClosedAt: Date?
    /// Whether the inbox no longer carries this repository at all.
    ///
    /// `true` when **no** open pull request in the inbox names this repository — not this agent's,
    /// not another agent's, not a person's — which means the sweep has stopped syncing it and what
    /// is left is history that outlived its inbox. ADR 0027 gives the outcome table no cascade
    /// precisely so those rows survive, and the page owes the reader a word about where they came
    /// from.
    ///
    /// Deliberately *not* the same question as ``openCount`` being zero. An agent that happens to
    /// have nothing open in a repository the user still reviews in is having a quiet week, and a
    /// footnote reading "history only" would be a wrong statement about a live repository.
    public var isHistoryOnly: Bool

    /// Creates a per-repository record.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - record: What the agent's closed pull requests there add up to.
    ///   - openCount: How many of the agent's pull requests there are open now.
    ///   - openAwaitingReviewCount: How many of those await the signed-in user's review.
    ///   - lastClosedAt: When the most recently counted pull request closed.
    ///   - isHistoryOnly: Whether the inbox carries no open pull request from this repository.
    public init(
        repo: RepoRef,
        record: TrackRecord,
        openCount: Int = 0,
        openAwaitingReviewCount: Int = 0,
        lastClosedAt: Date? = nil,
        isHistoryOnly: Bool = false
    ) {
        self.repo = repo
        self.record = record
        self.openCount = openCount
        self.openAwaitingReviewCount = openAwaitingReviewCount
        self.lastClosedAt = lastClosedAt
        self.isHistoryOnly = isHistoryOnly
    }

    /// Identified by the repository's full name, lower-cased.
    ///
    /// GitHub treats `Schnaq/Review` and `schnaq/review` as one repository and a fleet built from
    /// two sources will meet both spellings, so the identity a list is diffed by has to be the one
    /// that ignores the difference — ``RepoRef/isSameRepository(as:)``'s rule as a key.
    public var id: String { repo.fullName.lowercased() }
}

/// One agent's row in the fleet, and the whole of its page.
///
/// Everything here is a tally of things GitHub said, in the order the screen draws it. There is no
/// score, no grade and no position: ``FleetRoster/make(outcomes:openRows:since:)`` answers in one
/// fixed order and nothing downstream re-sorts it.
///
/// **There is no login on this type, and that is the point.** The fleet is a ledger of *agents*.
/// An agent's outcome still carries the login of whatever account opened the pull request — often
/// a person's, because a local session pushes with the maintainer's token — and a field for it
/// here would let the screen say "christian's pull request" on a page nobody wrote about them.
/// ADR 0027 already keeps the two apart in ``TrackRecordSubject``; the fleet keeps them apart by
/// having nowhere to put a login at all, on this type or on ``FleetRepositoryRecord``.
/// `PullRequestOutcome.authorLogin` is read nowhere in this file and discarded by the builder.
public struct FleetAgent: Sendable, Hashable, Identifiable {
    /// The name the agent is known by, which is also what the badge beside an inbox row says.
    ///
    /// From the live actor's ``AgentIdentity/displayName`` when the agent has anything open, and
    /// otherwise from the agent's most recently closed pull request — an agent the user renamed in
    /// their registry should be called what it is called now, and history is the only source left
    /// once nothing of its is open.
    public var displayName: String
    /// The registry identifier, or `nil` when only history knows this agent.
    ///
    /// The id travels on a live ``Actor`` and nowhere else: a stored outcome keeps the display
    /// name rather than the id (see ``PullRequestOutcome/agentName``), so an agent whose work has
    /// all closed can be named but not addressed.
    public var registryID: String?
    /// What the agent's closed pull requests add up to across every repository.
    ///
    /// The call `TrackRecord.compute(outcomes:subject:repo:since:)` was written for and nobody has
    /// ever made: `repo: nil`, documented there as "every repository".
    public var overall: TrackRecord
    /// The same counting again, one repository at a time, in the fleet's one order.
    ///
    /// Never empty when the agent is in the fleet at all, because an agent joins it by having
    /// either a counted outcome or an open pull request, and both name a repository.
    public var repositories: [FleetRepositoryRecord]
    /// How many of the agent's pull requests are open in the inbox right now, everywhere.
    public var openCount: Int
    /// How many of those are waiting on the signed-in user's review.
    ///
    /// Counted through ``PullRequestSummary/needsMyReview`` rather than by reading `myRelation` a
    /// second time. That property is the app's single definition of "needs my review" — the rail's
    /// smart view, the menu-bar count, the focus queue and the morning digest all ask it — and a
    /// fleet that also counted the review requests GitHub leaves standing after an approval would
    /// put a different number on this screen from the one in the corner of the same window.
    public var openAwaitingReviewCount: Int
    /// When the agent's most recently counted pull request closed, or `nil` when none did.
    public var lastClosedAt: Date?

    /// Creates an agent's row.
    /// - Parameters:
    ///   - displayName: The name the agent is known by.
    ///   - registryID: The registry identifier, when a live actor carried one.
    ///   - overall: The counting across every repository.
    ///   - repositories: The same counting per repository, in the fleet's order.
    ///   - openCount: How many of the agent's pull requests are open now.
    ///   - openAwaitingReviewCount: How many of those await the signed-in user's review.
    ///   - lastClosedAt: When the agent's most recently counted pull request closed.
    public init(
        displayName: String,
        registryID: String? = nil,
        overall: TrackRecord,
        repositories: [FleetRepositoryRecord] = [],
        openCount: Int = 0,
        openAwaitingReviewCount: Int = 0,
        lastClosedAt: Date? = nil
    ) {
        self.displayName = displayName
        self.registryID = registryID
        self.overall = overall
        self.repositories = repositories
        self.openCount = openCount
        self.openAwaitingReviewCount = openAwaitingReviewCount
        self.lastClosedAt = lastClosedAt
    }

    /// Identified by the display name, lower-cased.
    ///
    /// The name rather than the registry id, because the id is the half that can be missing: an
    /// agent with history and nothing open has no live actor to carry one. The lower-casing is the
    /// same join ``TrackRecordSubject/matches(_:)`` performs, so a row cannot change identity when
    /// a repository spells the agent's name differently.
    public var id: String { displayName.lowercased() }
}

/// Builds the fleet out of the two things Shepherd already stores.
///
/// The pure half of the screen, in ShepherdCore for the reason `TrustLaneLoader.snapshot` is pure:
/// the reading is the app's business — one `DatabaseManager.pullRequestOutcomes(since:)` and the
/// session's inbox rows, off the main actor — and the counting is arithmetic that must be the same
/// on the Linux runner as on a Mac. No new query, no new request, no new host (ADR 0027).
public enum FleetRoster {
    /// One agent's two halves while the roster is being assembled.
    private struct Bucket {
        /// The agent's counted outcomes, in whatever order they arrived.
        var outcomes: [PullRequestOutcome] = []
        /// The agent's open inbox rows, in whatever order they arrived.
        var rows: [PullRequestSummary] = []
    }

    /// The fleet: one entry per agent, with its repositories, in the one order the screen shows.
    ///
    /// Two membership rules, and they are the whole of "this screen is about agents, never people".
    /// An outcome joins when it has an ``PullRequestOutcome/agentName``; an open row joins when its
    /// author is an ``ActorKind/agent(_:)``. A human's pull request is not filtered out late for
    /// tidiness — it never enters, and there is nowhere in ``FleetAgent`` for a login to surface if
    /// it did.
    ///
    /// The two sources are joined on the display name, case-insensitively, which is exactly the
    /// comparison ``TrackRecordSubject/matches(_:)`` makes: the badge beside an inbox row and the
    /// row on this screen have to be about the same agent.
    ///
    /// **There is no ordering parameter, and there will not be one.** The answer comes back sorted
    /// by open pull requests descending, then by the most recent close descending, then by name —
    /// none of which is a rate. A sort picker, a sortable column or a `by:` argument here would let
    /// somebody order agents by how often their first push is green, and a list of agents ordered
    /// by a rate is a leaderboard whatever the surrounding words say. The order is a fixed property
    /// of the function so that making one is a change to this file rather than a call site.
    ///
    /// Pure and total: an empty input is an empty fleet, and every optional stays `nil` rather than
    /// becoming a substituted zero. The `since` filter is applied here as well as by the store's
    /// query — the query is an optimisation, this is the rule, and a function that only counted
    /// correctly for a caller that had already filtered would be a rule nothing could test.
    ///
    /// - Parameters:
    ///   - outcomes: The stored outcomes to count over, in any order. Rows that closed before
    ///     `since`, and rows with no agent name, are ignored.
    ///   - openRows: The inbox as it stands, in any order. Rows whose author is not a recognised
    ///     agent count for nothing except the question of which repositories are still synced.
    ///   - since: The oldest `closedAt` to count; the app passes ninety days ago (ADR 0027).
    /// - Returns: The agents, in the fleet's one order, each with its repositories in that same
    ///   order.
    public static func make(
        outcomes: [PullRequestOutcome],
        openRows: [PullRequestSummary],
        since: Date
    ) -> [FleetAgent] {
        let counted = outcomes.filter { $0.closedAt >= since && $0.agentName != nil }

        // Bucket once by agent. The key is the lower-cased display name on both sides, which is
        // the join `TrackRecordSubject.matches(_:)` makes between a stored outcome and a live row.
        var buckets: [String: Bucket] = [:]
        for outcome in counted {
            guard let name = outcome.agentName else { continue }
            buckets[name.lowercased(), default: Bucket()].outcomes.append(outcome)
        }
        for row in openRows {
            guard let identity = row.author.kind.agentIdentity else { continue }
            buckets[identity.displayName.lowercased(), default: Bucket()].rows.append(row)
        }

        // "History only" is a statement about the inbox, not about one agent, so it is asked of
        // every open row there is — a repository the user still reviews in is being synced even
        // when the only pull requests open in it are people's.
        let syncedRepositories = Set(openRows.map { $0.repo.fullName.lowercased() })

        var agents: [FleetAgent] = []
        agents.reserveCapacity(buckets.count)
        for bucket in buckets.values {
            let identities = bucket.rows.compactMap { $0.author.kind.agentIdentity }
            // Within one bucket these names differ at most in case; `min` is here to make the
            // choice between two spellings independent of the order the rows arrived in.
            let liveName = identities.map(\.displayName).min()
            guard let displayName = liveName
                ?? mostRecentlyClosed(bucket.outcomes)?.agentName
            else { continue }

            // Then by repository, on the same case-insensitive key, so an outcome written when the
            // repository was spelled `Schnaq/Review` lands in the row headed `schnaq/review`.
            var outcomesByRepo: [String: [PullRequestOutcome]] = [:]
            for outcome in bucket.outcomes {
                outcomesByRepo[outcome.repo.fullName.lowercased(), default: []].append(outcome)
            }
            var rowsByRepo: [String: [PullRequestSummary]] = [:]
            for row in bucket.rows {
                rowsByRepo[row.repo.fullName.lowercased(), default: []].append(row)
            }

            var repositories: [FleetRepositoryRecord] = []
            for key in Set(outcomesByRepo.keys).union(rowsByRepo.keys) {
                let repoOutcomes = outcomesByRepo[key] ?? []
                let repoRows = rowsByRepo[key] ?? []
                guard let repo = repoRows.map(\.repo).min(by: { $0.fullName < $1.fullName })
                    ?? mostRecentlyClosed(repoOutcomes)?.repo
                else { continue }
                repositories.append(
                    FleetRepositoryRecord(
                        repo: repo,
                        // A repository that only has something open counts over an empty bucket
                        // and gets the empty record, whose rates are `nil`. That is the whole
                        // trick: nothing has to special-case it, and no rate is ever invented
                        // from an empty denominator (ADR 0027).
                        record: TrackRecord.compute(
                            outcomes: repoOutcomes,
                            subject: .agent(name: displayName),
                            repo: repo,
                            since: since
                        ),
                        openCount: repoRows.count,
                        openAwaitingReviewCount: repoRows.filter(\.needsMyReview).count,
                        lastClosedAt: repoOutcomes.map(\.closedAt).max(),
                        isHistoryOnly: !syncedRepositories.contains(key)
                    )
                )
            }
            repositories.sort { left, right in
                isOrderedBefore(
                    (openCount: left.openCount, lastClosedAt: left.lastClosedAt, key: left.id),
                    (openCount: right.openCount, lastClosedAt: right.lastClosedAt, key: right.id)
                )
            }

            agents.append(
                FleetAgent(
                    displayName: displayName,
                    registryID: identities.map(\.id).min(),
                    overall: TrackRecord.compute(
                        outcomes: bucket.outcomes,
                        subject: .agent(name: displayName),
                        repo: nil,
                        since: since
                    ),
                    repositories: repositories,
                    openCount: bucket.rows.count,
                    openAwaitingReviewCount: bucket.rows.filter(\.needsMyReview).count,
                    lastClosedAt: bucket.outcomes.map(\.closedAt).max()
                )
            )
        }

        agents.sort { left, right in
            isOrderedBefore(
                (openCount: left.openCount, lastClosedAt: left.lastClosedAt, key: left.id),
                (openCount: right.openCount, lastClosedAt: right.lastClosedAt, key: right.id)
            )
        }
        return agents
    }

    /// The fleet's one order, used for the agents and for the repositories inside one.
    ///
    /// Open pull requests first, because the screen's job is "what is on my plate from this agent",
    /// then the most recent close, then the name. Not one of the three is a rate: a list of agents
    /// ordered by how often their first push is green would be a ranking however carefully the
    /// surrounding words avoided the word.
    ///
    /// The third key is an identity — a lower-cased name — and identities are unique within one
    /// answer, so the order is **total**: two runs over the same rows in a different input order
    /// produce the same list, which is what lets a `List` diff it without rows jumping about.
    /// - Parameters:
    ///   - left: The open count, last close and identity of one entry.
    ///   - right: The same three of the other.
    /// - Returns: Whether `left` is shown before `right`.
    private static func isOrderedBefore(
        _ left: (openCount: Int, lastClosedAt: Date?, key: String),
        _ right: (openCount: Int, lastClosedAt: Date?, key: String)
    ) -> Bool {
        if left.openCount != right.openCount { return left.openCount > right.openCount }
        // Never closed sorts last rather than first: `nil` here means "nothing has come back from
        // this agent yet", which is the least recent thing that can be true of it.
        let leftClosed = left.lastClosedAt ?? .distantPast
        let rightClosed = right.lastClosedAt ?? .distantPast
        if leftClosed != rightClosed { return leftClosed > rightClosed }
        return left.key < right.key
    }

    /// The outcome that closed last — where a name and a repository's spelling are taken from.
    ///
    /// The roster and ``FleetNotices`` both have to name an agent and a repository the same way
    /// every time they are asked, over inputs whose order is the database's business. The most
    /// recently closed outcome is the one answer that also *means* something — the spelling the
    /// agent most recently went by — and `prID` breaks the tie so that two pull requests closing in
    /// the same second cannot make the answer depend on the order the rows arrived in.
    ///
    /// Internal because no screen needs it: what it exists for is that the two detectors cannot
    /// disagree about what an agent is called.
    /// - Parameter outcomes: The outcomes to choose from, in any order.
    /// - Returns: The one that closed last, or `nil` when there are none.
    static func mostRecentlyClosed(_ outcomes: [PullRequestOutcome]) -> PullRequestOutcome? {
        outcomes.max { left, right in
            if left.closedAt != right.closedAt { return left.closedAt < right.closedAt }
            return left.prID > right.prID
        }
    }
}
