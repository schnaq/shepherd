import Dispatch
import Foundation
import GRDB
import ShepherdCore

/// Narrows what ``DatabaseManager/fetchIssues(filter:)`` returns.
///
/// ``InboxFilter``'s twin: the issues inbox is small enough — hundreds of rows, not millions —
/// that composing the predicate in Swift after one ordered SQL fetch is both easier to read and
/// impossible to get subtly wrong. The two issue-only axes are the ones the rail adds
/// (``hasLinkedAgentPullRequest`` and ``ageBucket``); everything else is the pull-request
/// filter's shape.
public struct IssueFilter: Sendable, Hashable {
    /// Only issues from this repository.
    public var repo: RepoRef?
    /// Only issues the user relates to in at least one of these ways.
    public var anyOfRelations: Set<IssueRelation>
    /// Only issues opened by this agent (``AgentIdentity/id``).
    public var agentID: String?
    /// Only issues opened by a machine (`true`) or by a human (`false`).
    public var isMachineAuthored: Bool?
    /// Only issues that have (`true`) or have not (`false`) a machine-authored linked pull
    /// request — the rail's own facet, reading
    /// ``ShepherdCore/IssueRowSummary/hasAgentPullRequest``.
    public var hasLinkedAgentPullRequest: Bool?
    /// Only issues opened inside this age bucket.
    public var ageBucket: IssueAgeBucket?
    /// The moment ``ageBucket`` is measured against.
    ///
    /// Part of the filter rather than read from the clock inside it, because the filter is also
    /// the key of a ``ValueObservation``: a predicate that consulted `Date()` would make two
    /// otherwise identical observations unequal and would re-bucket rows underneath a view
    /// without any write having happened.
    public var now: Date
    /// Whether closed issues are included. `false` — the default — is the inbox.
    public var includeClosed: Bool
    /// Cap on the number of rows returned.
    public var limit: Int?

    /// Creates a filter. All fields default to "no restriction", except ``includeClosed``, which
    /// defaults to the inbox's own answer.
    public init(
        repo: RepoRef? = nil,
        anyOfRelations: Set<IssueRelation> = [],
        agentID: String? = nil,
        isMachineAuthored: Bool? = nil,
        hasLinkedAgentPullRequest: Bool? = nil,
        ageBucket: IssueAgeBucket? = nil,
        now: Date = Date(),
        includeClosed: Bool = false,
        limit: Int? = nil
    ) {
        self.repo = repo
        self.anyOfRelations = anyOfRelations
        self.agentID = agentID
        self.isMachineAuthored = isMachineAuthored
        self.hasLinkedAgentPullRequest = hasLinkedAgentPullRequest
        self.ageBucket = ageBucket
        self.now = now
        self.includeClosed = includeClosed
        self.limit = limit
    }

    /// Whether a row passes the filter.
    func matches(_ summary: IssueRowSummary) -> Bool {
        if let repo, summary.repo != repo { return false }
        if !anyOfRelations.isEmpty, summary.myRelation.isDisjoint(with: anyOfRelations) {
            return false
        }
        if let agentID, summary.author.kind.agentIdentity?.id != agentID { return false }
        if let isMachineAuthored, summary.author.kind.isMachine != isMachineAuthored {
            return false
        }
        if let hasLinkedAgentPullRequest,
           summary.hasAgentPullRequest != hasLinkedAgentPullRequest {
            return false
        }
        if let ageBucket, !ageBucket.contains(createdAt: summary.createdAt, now: now) {
            return false
        }
        if !includeClosed, summary.state == .closed { return false }
        return true
    }
}

extension DatabaseManager {
    // MARK: - Issue rows

    /// The issues a sweep may **not** prune, whatever the search returned.
    ///
    /// The pull-request guard's `outbox` half, and only that half: `outbox` has no foreign key
    /// onto anything, so pruning a row the user has a queued mutation for would leave the write
    /// with nothing to apply itself to and nothing to render. There is no `review_drafts`
    /// equivalent for an issue — an issue has no review to draft — so the other half of
    /// ``pruneGuardSQL`` has no twin here.
    ///
    /// Terminal outbox rows (`failed`, `succeeded`) do not hold an issue open; a `conflicted` row
    /// does, because it is waiting for the user to decide. The column is `prID` because that is
    /// what the outbox table calls the node id it targets — it has held one kind of node until
    /// now, and an issue-targeting action stores the issue's node id in the same column rather
    /// than adding a second one that would always be `NULL` for one of the two.
    static let issuePruneGuardSQL = """
        id NOT IN (
            SELECT prID FROM outbox WHERE state IN ('pending', 'sending', 'conflicted')
        )
        """

    /// Stores the result of one issues sweep.
    ///
    /// Rows are upserted, keeping the detail columns (the body and its fetch stamp) of any issue
    /// that was already fetched in detail. When `pruneMissing` is `true` — the normal case for a
    /// full sweep — issues that are no longer in the result set are deleted, which is how closed
    /// issues leave the inbox.
    ///
    /// Saving a row also **replaces its `issue_linked_pull_requests` rows** and re-derives the
    /// two denormalised columns from the list, so the facet's column and the detail panel's list
    /// cannot come to different conclusions. The sweep is the authority on the links: it selects
    /// them on every pass, so an empty list means "this issue has none" and not "this write knows
    /// nothing about them" — the opposite of the rule ``saveIssueDetail(_:)`` follows.
    /// - Parameters:
    ///   - summaries: The rows the sweep returned.
    ///   - pruneMissing: Whether to delete rows absent from `summaries`.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    public func saveIssueSummaries(
        _ summaries: [IssueRowSummary],
        pruneMissing: Bool = true
    ) async throws {
        try await writer.write { db in
            for summary in summaries {
                try RepoRecord(summary.repo).save(db)
                let existing = try IssueRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM issues WHERE id = ?",
                    arguments: [summary.id]
                )
                var record = IssueRecord(summary: summary, existing: existing)
                if summary.myRelation.isEmpty, let existing {
                    // A detail fetch cannot know the user's relation; keep what the sweep saw.
                    record.relations = existing.relations
                }
                try record.save(db)
                try DatabaseManager.replaceLinkedPullRequests(
                    db,
                    issueID: summary.id,
                    references: summary.linkedPullRequests
                )
            }

            guard pruneMissing else { return }
            let keep = summaries.map(\.id)
            if keep.isEmpty {
                try db.execute(
                    sql: "DELETE FROM issues WHERE \(DatabaseManager.issuePruneGuardSQL)"
                )
            } else {
                let placeholders = Array(repeating: "?", count: keep.count)
                    .joined(separator: ",")
                try db.execute(
                    sql: """
                        DELETE FROM issues
                        WHERE id NOT IN (\(placeholders))
                        AND \(DatabaseManager.issuePruneGuardSQL)
                        """,
                    arguments: StatementArguments(keep)
                )
            }
            try DatabaseManager.pruneOrphanedRepos(db)
        }
    }

    /// Reads the issues inbox, most-recently-updated first.
    /// - Parameter filter: What to include.
    /// - Returns: The rows, each with the linked pull requests stored beside it.
    public func fetchIssues(filter: IssueFilter = IssueFilter()) async throws -> [IssueRowSummary] {
        try await writer.read { db in
            try DatabaseManager.loadIssues(db, filter: filter)
        }
    }

    /// Reads one issue row.
    /// - Parameter id: The issue's GraphQL node id.
    /// - Returns: The row, or `nil` when the issue is not cached.
    public func fetchIssueSummary(id: String) async throws -> IssueRowSummary? {
        try await writer.read { db in
            guard let record = try IssueRecord.fetchOne(
                db,
                sql: "SELECT * FROM issues WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            let links = try DatabaseManager.linkedPullRequests(db, issueID: id)
            return record.summary(linkedPullRequests: links)
        }
    }

    /// The issues query, shared by ``fetchIssues(filter:)`` and ``observeIssues(filter:)``.
    ///
    /// Two queries rather than a join, for ``searchIndexSources(prIDs:)``'s reason: a join would
    /// repeat every issue row — `bodyMarkdown` included — once per linked pull request.
    static func loadIssues(_ db: Database, filter: IssueFilter) throws -> [IssueRowSummary] {
        let records = try IssueRecord.fetchAll(
            db,
            sql: "SELECT * FROM issues ORDER BY updatedAt DESC, repoFullName ASC, number DESC"
        )
        guard !records.isEmpty else { return [] }
        let linkRecords = try IssueLinkedPullRequestRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM issue_linked_pull_requests
                ORDER BY issueID ASC, sortIndex ASC
                """
        )
        var grouped: [String: [LinkedPullRequestReference]] = [:]
        for record in linkRecords {
            grouped[record.issueID, default: []].append(record.reference)
        }
        var results = records
            .map { $0.summary(linkedPullRequests: grouped[$0.id] ?? []) }
            .filter(filter.matches)
        if let limit = filter.limit, results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    /// The rows of `issue_linked_pull_requests` for one issue, in sort order.
    static func linkedPullRequests(
        _ db: Database,
        issueID: String
    ) throws -> [LinkedPullRequestReference] {
        try IssueLinkedPullRequestRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM issue_linked_pull_requests
                WHERE issueID = ? ORDER BY sortIndex ASC
                """,
            arguments: [issueID]
        ).map(\.reference)
    }

    /// Replaces one issue's linked pull requests and the two columns derived from them.
    ///
    /// Delete-then-insert rather than an upsert, for ``savePullRequestDetail(_:)``'s reason: the
    /// primary key is the pull request's repository and number, so an upsert would leave behind
    /// every link the issue used to have. GitHub's own order is kept as `sortIndex`, because it
    /// is stable across fetches while an order derived from anything else would reshuffle the
    /// panel on every sweep.
    static func replaceLinkedPullRequests(
        _ db: Database,
        issueID: String,
        references: [LinkedPullRequestReference]
    ) throws {
        try db.execute(
            sql: "DELETE FROM issue_linked_pull_requests WHERE issueID = ?",
            arguments: [issueID]
        )
        for (index, reference) in references.enumerated() {
            try IssueLinkedPullRequestRecord(
                issueID: issueID,
                reference: reference,
                sortIndex: index
            ).save(db)
        }
        // Both derived values are computed here, from the list that was just written, so the
        // facet's column cannot disagree with the panel's rows.
        let hasAgent = references.contains { $0.author.kind.isMachine }
        try db.execute(
            sql: """
                UPDATE issues
                SET linkedPullRequestCount = ?, hasAgentLinkedPullRequest = ?
                WHERE id = ?
                """,
            arguments: [references.count, hasAgent, issueID]
        )
    }

    /// Deletes repository rows nothing points at any more.
    ///
    /// Shared by both sweeps, and it has to be: `repos` is the parent of `pull_requests` *and* of
    /// `issues`, both with `ON DELETE CASCADE`, so a prune that only looked at one of the two
    /// would delete a repository the user has issues but no open pull requests in — and take
    /// every one of those issues with it.
    static func pruneOrphanedRepos(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM repos
            WHERE fullName NOT IN (SELECT DISTINCT repoFullName FROM pull_requests)
            AND fullName NOT IN (SELECT DISTINCT repoFullName FROM issues)
            """)
    }

    // MARK: - Detail

    /// Stores an issue's body, keeping the row it belongs to up to date.
    ///
    /// The links are treated the other way round from ``saveIssueSummaries(_:pruneMissing:)``: an
    /// empty list here means "this fetch learned nothing about them" and the stored rows are left
    /// alone — the same treatment the check columns get in ``savePullRequestDetail(_:)``, and for
    /// the same reason. The sweep selects the links on every pass and is the authority on them;
    /// a detail read is about the body.
    /// - Parameter detail: The detail record to store.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    public func saveIssueDetail(_ detail: IssueDetail) async throws {
        let fetchedAt = Date().timeIntervalSince1970
        try await writer.write { db in
            try RepoRecord(detail.repo).save(db)
            let existing = try IssueRecord.fetchOne(
                db,
                sql: "SELECT * FROM issues WHERE id = ?",
                arguments: [detail.id]
            )
            var record = IssueRecord(summary: detail.summary, existing: existing)
            if detail.summary.myRelation.isEmpty, let existing {
                record.relations = existing.relations
            }
            if detail.summary.linkedPullRequests.isEmpty, let existing {
                record.linkedPullRequestCount = existing.linkedPullRequestCount
                record.hasAgentLinkedPullRequest = existing.hasAgentLinkedPullRequest
            }
            record.bodyMarkdown = detail.bodyMarkdown
            record.detailFetchedAt = fetchedAt
            try record.save(db)

            guard !detail.summary.linkedPullRequests.isEmpty else { return }
            try DatabaseManager.replaceLinkedPullRequests(
                db,
                issueID: detail.id,
                references: detail.summary.linkedPullRequests
            )
        }
    }

    /// Reads an issue's detail record back.
    /// - Parameter id: The issue's GraphQL node id.
    /// - Returns: The detail record, or `nil` when the issue is not cached.
    public func fetchIssueDetail(id: String) async throws -> IssueDetail? {
        try await writer.read { db in
            guard let record = try IssueRecord.fetchOne(
                db,
                sql: "SELECT * FROM issues WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            let links = try DatabaseManager.linkedPullRequests(db, issueID: id)
            return IssueDetail(
                summary: record.summary(linkedPullRequests: links),
                bodyMarkdown: record.bodyMarkdown ?? ""
            )
        }
    }

    // MARK: - Observation

    /// Streams the issues inbox, re-emitting whenever any row the query reads changes.
    ///
    /// ``observeInbox(filter:)``'s twin, and the mechanism behind "the UI always renders from the
    /// database" (ADR 0006) for the issues section: the sweep writes, GRDB notices, the view
    /// updates. The first value is emitted as soon as the observation starts, so a view never has
    /// to fetch once and observe separately.
    /// - Parameter filter: What to include.
    /// - Returns: A stream that finishes when the caller stops iterating or the observation
    ///   fails.
    public func observeIssues(
        filter: IssueFilter = IssueFilter()
    ) -> AsyncStream<[IssueRowSummary]> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> [IssueRowSummary] in
            try DatabaseManager.loadIssues(db, filter: filter)
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.schnaq.shepherd.observation.issues")
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
