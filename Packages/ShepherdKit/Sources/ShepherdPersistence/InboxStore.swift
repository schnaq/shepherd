import Foundation
import GRDB
import ShepherdCore

/// Narrows what ``DatabaseManager/fetchInbox(filter:)`` returns.
///
/// The inbox is small enough (hundreds of rows, not millions) that composing this in Swift
/// after an ordered SQL fetch is both faster to read and impossible to get subtly wrong.
public struct InboxFilter: Sendable, Hashable {
    /// Only rows from this repository.
    public var repo: RepoRef?
    /// Only rows the user relates to in at least one of these ways.
    public var anyOfRelations: Set<Relation>
    /// Only rows authored by this agent (``AgentIdentity/id``).
    public var agentID: String?
    /// Only rows authored by a machine (`true`) or by a human (`false`).
    public var isMachineAuthored: Bool?
    /// Whether draft pull requests are included.
    public var includeDrafts: Bool
    /// Cap on the number of rows returned.
    public var limit: Int?

    /// Creates a filter. All fields default to "no restriction".
    public init(
        repo: RepoRef? = nil,
        anyOfRelations: Set<Relation> = [],
        agentID: String? = nil,
        isMachineAuthored: Bool? = nil,
        includeDrafts: Bool = true,
        limit: Int? = nil
    ) {
        self.repo = repo
        self.anyOfRelations = anyOfRelations
        self.agentID = agentID
        self.isMachineAuthored = isMachineAuthored
        self.includeDrafts = includeDrafts
        self.limit = limit
    }

    /// Whether a row passes the filter.
    func matches(_ summary: PullRequestSummary) -> Bool {
        if let repo, summary.repo != repo { return false }
        if !anyOfRelations.isEmpty, summary.myRelation.isDisjoint(with: anyOfRelations) {
            return false
        }
        if let agentID, summary.author.kind.agentIdentity?.id != agentID { return false }
        if let isMachineAuthored, summary.author.kind.isMachine != isMachineAuthored {
            return false
        }
        if !includeDrafts, summary.isDraft { return false }
        return true
    }
}

extension DatabaseManager {
    // MARK: - Inbox rows

    /// The rows a sweep may **not** prune, whatever the search returned.
    ///
    /// `review_drafts`, `draft_comments` and `outbox` have no foreign key onto
    /// `pull_requests`, so pruning a row the user still has unfinished work on leaves the
    /// draft alive with nothing to render it against — and the review screen has nothing to
    /// show. That happens routinely: the `involves:@me` facet is capped at five pages, and a
    /// pull request queued for approval offline disappears from the search the moment someone
    /// else merges it.
    ///
    /// Terminal outbox rows (`failed`, `succeeded`) do not hold a pull request open; a
    /// `conflicted` row does, because it is waiting for the user to decide.
    private static let pruneGuardSQL = """
        id NOT IN (SELECT prID FROM review_drafts)
        AND id NOT IN (
            SELECT prID FROM outbox WHERE state IN ('pending', 'sending', 'conflicted')
        )
        """

    /// Stores the result of one inbox sweep.
    ///
    /// Rows are upserted, keeping the detail columns (body, commits, timeline) of any pull
    /// request that was already fetched in detail. When `pruneMissing` is `true` — the normal
    /// case for a full sweep — pull requests that are no longer in the result set are deleted,
    /// which is how merged and closed pull requests leave the inbox.
    /// - Parameters:
    ///   - summaries: The rows the sweep returned.
    ///   - pruneMissing: Whether to delete rows absent from `summaries`.
    public func savePullRequestSummaries(
        _ summaries: [PullRequestSummary],
        pruneMissing: Bool = true
    ) async throws {
        try await writer.write { db in
            for summary in summaries {
                try RepoRecord(summary.repo).save(db)
                let existing = try PullRequestRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM pull_requests WHERE id = ?",
                    arguments: [summary.id]
                )
                var record = PullRequestRecord(summary: summary, existing: existing)
                if summary.myRelation.isEmpty, let existing {
                    // A detail fetch cannot know the user's relation; keep what the sweep saw.
                    record.relations = existing.relations
                }
                if let existing {
                    record.keepTrailerAgent(from: existing)
                }
                try record.save(db)
            }

            guard pruneMissing else { return }
            let keep = summaries.map(\.id)
            if keep.isEmpty {
                try db.execute(sql: "DELETE FROM pull_requests WHERE \(DatabaseManager.pruneGuardSQL)")
            } else {
                let placeholders = Array(repeating: "?", count: keep.count)
                    .joined(separator: ",")
                try db.execute(
                    sql: """
                        DELETE FROM pull_requests
                        WHERE id NOT IN (\(placeholders)) AND \(DatabaseManager.pruneGuardSQL)
                        """,
                    arguments: StatementArguments(keep)
                )
            }
            // Shared with the issues sweep, and it has to be: `repos` is the parent of both
            // tables with `ON DELETE CASCADE`, so a prune that only looked at `pull_requests`
            // would delete a repository the user has issues but no open pull requests in — and
            // take every one of those issues with it (ADR 0032).
            try DatabaseManager.pruneOrphanedRepos(db)
        }
    }

    /// Reads the inbox, most-recently-updated first.
    /// - Parameter filter: What to include.
    public func fetchInbox(filter: InboxFilter = InboxFilter()) async throws -> [PullRequestSummary] {
        try await writer.read { db in
            try DatabaseManager.loadInbox(db, filter: filter)
        }
    }

    /// Reads one inbox row.
    /// - Parameter id: The pull request's GraphQL node id.
    public func fetchPullRequestSummary(id: String) async throws -> PullRequestSummary? {
        try await writer.read { db in
            try PullRequestRecord.fetchOne(
                db,
                sql: "SELECT * FROM pull_requests WHERE id = ?",
                arguments: [id]
            )?.summary
        }
    }

    /// Whether the stored pull request is part of a GitHub stack — the drain's
    /// `StackMembershipLookup`, which picks the asynchronous merge for a stacked one (ADR 0042).
    ///
    /// Read off the same record as ``fetchPullRequestSummary(id:)``, so "stacked" means exactly
    /// what a row's chip shows: all four stack columns hold a value. A pull request the inbox does
    /// not hold reads as unstacked, which is how every merge worked before stacks.
    /// - Parameter id: The pull request's GraphQL node id.
    public func isInStack(prID id: String) async throws -> Bool {
        try await fetchPullRequestSummary(id: id)?.stack != nil
    }

    /// Reads one inbox row by repository and number.
    ///
    /// The node id is the primary key everywhere in Shepherd, so this is the *only* lookup that
    /// does not have one — and it exists because a link is written the way GitHub writes it:
    /// `owner/name#number`, never a node id (ADR 0032). It is what resolves the issue side's
    /// links against the local inbox, and `idx_pull_requests_repo_number` is exactly this query's
    /// unique index, so it is a lookup rather than a scan.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number within it.
    /// - Returns: The row, or `nil` when this pull request is not cached — which is an ordinary
    ///   answer and not a failure: the linked pull request may be somebody else's.
    public func fetchPullRequestSummary(
        repo: RepoRef,
        number: Int
    ) async throws -> PullRequestSummary? {
        try await writer.read { db in
            try PullRequestRecord.fetchOne(
                db,
                // `COLLATE NOCASE`, as the outcome store compares this column: a reference that
                // arrived through another GraphQL field may spell the owner differently from the
                // sweep that stored the row, and GitHub treats the two as one repository.
                sql: "SELECT * FROM pull_requests WHERE repoFullName = ? COLLATE NOCASE AND number = ?",
                arguments: [repo.fullName, number]
            )?.summary
        }
    }

    /// The inbox query, shared by ``fetchInbox(filter:)`` and ``observeInbox(filter:)``.
    static func loadInbox(_ db: Database, filter: InboxFilter) throws -> [PullRequestSummary] {
        let records = try PullRequestRecord.fetchAll(
            db,
            sql: "SELECT * FROM pull_requests ORDER BY updatedAt DESC, repoFullName ASC, number DESC"
        )
        var results = records.map(\.summary).filter(filter.matches)
        if let limit = filter.limit, results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    // MARK: - Detail

    /// Stores a full detail fetch, replacing the pull request's files, threads, checks and the
    /// issues it closes.
    /// - Parameter detail: The detail record to store.
    public func savePullRequestDetail(_ detail: PullRequestDetail) async throws {
        let fetchedAt = Date().timeIntervalSince1970
        try await writer.write { db in
            try RepoRecord(detail.repo).save(db)
            let existing = try PullRequestRecord.fetchOne(
                db,
                sql: "SELECT * FROM pull_requests WHERE id = ?",
                arguments: [detail.id]
            )
            var record = PullRequestRecord(summary: detail.summary, existing: existing)
            if detail.summary.myRelation.isEmpty, let existing {
                record.relations = existing.relations
            }
            if detail.checks.isEmpty, let existing {
                // A detail fetch derives its rollup from `/commits/{sha}/check-runs`, which
                // knows nothing about classic commit statuses. Repositories on Jenkins or
                // Buildkite therefore report *no* check runs, and writing that through would
                // null the rollup the GraphQL sweep computed from `statusCheckRollup` — the
                // badge would appear after a sweep and vanish a second later. Same treatment
                // as the body/commits/timeline columns: absent means "unknown", not "empty".
                record.checkState = existing.checkState
                record.checkTotal = existing.checkTotal
                record.checkSuccess = existing.checkSuccess
                record.checkFailure = existing.checkFailure
                record.checkPending = existing.checkPending
            }
            if detail.summary.mergeStateStatus == nil, let existing {
                // REST's `mergeable_state` normally carries the same state the sweep read from
                // `mergeStateStatus`; when a detail fetch lacks it, absent means "unknown", so the
                // sweep's `behind` survives for the merge series (ADR 0041).
                record.mergeStateStatus = existing.mergeStateStatus
            }
            if detail.summary.stack == nil, let existing {
                // REST documents `stack` as present "when a pull request belongs to a stack",
                // without saying whether an API version or preview gates it, so its absence is
                // read as "unknown". Clearing it wrongly would send a stacked merge to the
                // synchronous endpoint GitHub refuses; keeping it wrongly lasts until the next
                // sweep, which writes GraphQL's `null` through (ADR 0042).
                record.keepStack(from: existing)
            }
            record.bodyMarkdown = detail.bodyMarkdown
            record.commitsJSON = ColumnCoding.encodeJSON(detail.commits)
            record.timelineJSON = ColumnCoding.encodeJSON(detail.timeline)
            record.detailFetchedAt = fetchedAt
            try record.save(db)

            try db.execute(
                sql: "DELETE FROM changed_files WHERE prID = ?",
                arguments: [detail.id]
            )
            for (index, file) in detail.files.enumerated() {
                try ChangedFileRecord(prID: detail.id, file: file, sortIndex: index).save(db)
            }

            // Replaced on every detail write, exactly as `changed_files` is, and for the same
            // reason: this fetch selects `closingIssuesReferences` unconditionally, so it is the
            // authority on the list and an empty answer means "this pull request closes nothing"
            // (ADR 0032). It sits here, above the checks' early return, so a repository with no
            // check runs still gets its links replaced.
            try db.execute(
                sql: "DELETE FROM pull_request_closing_issues WHERE prID = ?",
                arguments: [detail.id]
            )
            for (index, issue) in detail.closingIssues.enumerated() {
                try PullRequestClosingIssueRecord(
                    prID: detail.id,
                    reference: issue,
                    sortIndex: index
                ).save(db)
            }

            // Comments cascade with their thread.
            try db.execute(
                sql: "DELETE FROM review_threads WHERE prID = ?",
                arguments: [detail.id]
            )
            for (threadIndex, thread) in detail.threads.enumerated() {
                try ReviewThreadRecord(
                    prID: detail.id,
                    thread: thread,
                    sortIndex: threadIndex
                ).save(db)
                for (commentIndex, comment) in thread.comments.enumerated() {
                    try ReviewCommentRecord(
                        threadID: thread.id,
                        comment: comment,
                        sortIndex: commentIndex
                    ).save(db)
                }
            }

            // Same reasoning as the check columns above: an empty listing means "this fetch
            // learned nothing about the checks", so the stored rows are left alone.
            guard !detail.checks.isEmpty else { return }
            try db.execute(sql: "DELETE FROM check_runs WHERE prID = ?", arguments: [detail.id])
            for (index, run) in detail.checks.enumerated() {
                try CheckRunRecord(prID: detail.id, run: run, sortIndex: index).save(db)
            }
        }
    }

    /// Reads a full detail record back, including local viewed-file state.
    /// - Parameter id: The pull request's GraphQL node id.
    /// - Returns: The detail record, or `nil` when the pull request is not cached.
    public func fetchPullRequestDetail(id: String) async throws -> PullRequestDetail? {
        try await writer.read { db in
            try DatabaseManager.loadPullRequestDetail(db, id: id)
        }
    }

    /// The detail query, shared by ``fetchPullRequestDetail(id:)`` and
    /// ``observePullRequestDetail(prID:)``.
    static func loadPullRequestDetail(_ db: Database, id: String) throws -> PullRequestDetail? {
        guard let record = try PullRequestRecord.fetchOne(
            db,
            sql: "SELECT * FROM pull_requests WHERE id = ?",
            arguments: [id]
        ) else { return nil }

        let viewedPaths = try Set(
            String.fetchAll(
                db,
                sql: "SELECT path FROM viewed_files WHERE prID = ? AND headRefOid = ?",
                arguments: [id, record.headRefOid]
            )
        )

        let fileRecords = try ChangedFileRecord.fetchAll(
            db,
            sql: "SELECT * FROM changed_files WHERE prID = ? ORDER BY sortIndex ASC",
            arguments: [id]
        )
        let files: [ChangedFile] = fileRecords.map { fileRecord in
            var file = fileRecord.changedFile
            file.isViewed = viewedPaths.contains(file.path)
            return file
        }

        let threadRecords = try ReviewThreadRecord.fetchAll(
            db,
            sql: "SELECT * FROM review_threads WHERE prID = ? ORDER BY sortIndex ASC",
            arguments: [id]
        )
        var threads: [ReviewThread] = []
        threads.reserveCapacity(threadRecords.count)
        for threadRecord in threadRecords {
            let commentRecords = try ReviewCommentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM review_comments
                    WHERE threadID = ? ORDER BY sortIndex ASC
                    """,
                arguments: [threadRecord.id]
            )
            threads.append(
                threadRecord.reviewThread(comments: commentRecords.map(\.reviewComment))
            )
        }

        let checkRecords = try CheckRunRecord.fetchAll(
            db,
            sql: "SELECT * FROM check_runs WHERE prID = ? ORDER BY sortIndex ASC",
            arguments: [id]
        )

        let closingIssueRecords = try PullRequestClosingIssueRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM pull_request_closing_issues
                WHERE prID = ? ORDER BY sortIndex ASC
                """,
            arguments: [id]
        )

        return PullRequestDetail(
            summary: record.summary,
            bodyMarkdown: record.bodyMarkdown ?? "",
            commits: record.commits,
            files: files,
            threads: threads,
            timeline: record.timeline,
            checks: checkRecords.map(\.checkRun),
            closingIssues: closingIssueRecords.map(\.reference)
        )
    }

    // MARK: - Viewed files

    /// Marks a file as viewed (or not) for a given head commit.
    ///
    /// Viewed state is scoped to the head SHA so that new commits reset it, which is what
    /// GitHub's own "viewed" checkbox does.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - path: The file path.
    ///   - headRefOid: The head commit the file was reviewed at.
    ///   - isViewed: Whether the file is now viewed.
    public func setFileViewed(
        prID: String,
        path: String,
        headRefOid: String,
        isViewed: Bool
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            if isViewed {
                try ViewedFileRecord(
                    prID: prID,
                    path: path,
                    headRefOid: headRefOid,
                    viewedAt: now
                ).save(db)
            } else {
                try db.execute(
                    sql: "DELETE FROM viewed_files WHERE prID = ? AND path = ?",
                    arguments: [prID, path]
                )
            }
        }
    }

    /// The set of paths marked viewed for a pull request at a given head commit.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - headRefOid: The head commit.
    public func viewedFiles(prID: String, headRefOid: String) async throws -> Set<String> {
        try await writer.read { db in
            try Set(
                String.fetchAll(
                    db,
                    sql: "SELECT path FROM viewed_files WHERE prID = ? AND headRefOid = ?",
                    arguments: [prID, headRefOid]
                )
            )
        }
    }

    // MARK: - The reviewer's own review comments

    /// Reads the review comments the signed-in user wrote, oldest first (ADR 0029).
    ///
    /// The one read the feedback loop needs, and it is deliberately narrow in three ways:
    ///
    /// - **The viewer's own comments only.** `authorLogin` is matched case-insensitively, because
    ///   GitHub treats a login that way and a casing difference between the account record and a
    ///   stored comment would silently return nothing. Nobody else's comment is returned at all,
    ///   so the feature *cannot* cluster a colleague's words even by accident (ADR 0020's
    ///   reasoning).
    /// - **Posted comments only.** A row with a `pendingLocalID` is a comment the reviewer has
    ///   written into a pending review and not sent yet; it is not something they have said, and
    ///   counting it would also double-count it the moment it is posted under its real node id.
    /// - **A time floor the caller states.** The window belongs to
    ///   ``ShepherdCore/RecurringFindingDetector``, not to SQL, but pushing the floor into the
    ///   query is what keeps a first sweep after a long absence from embedding a year of review.
    ///
    /// - Parameters:
    ///   - login: The signed-in user's login.
    ///   - since: The earliest `createdAt` to return.
    /// - Returns: The comments, oldest first, with the pull request each belongs to.
    public func viewerReviewComments(
        login: String,
        since: Date
    ) async throws -> [ViewerReviewComment] {
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let floor = since.timeIntervalSince1970
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id AS id, c.bodyMarkdown AS body, c.createdAt AS createdAt,
                           p.id AS prID, p.number AS number, p.repoFullName AS repoFullName
                    FROM review_comments c
                    JOIN review_threads t ON t.id = c.threadID
                    JOIN pull_requests p ON p.id = t.prID
                    WHERE c.authorLogin = ? COLLATE NOCASE
                      AND c.pendingLocalID IS NULL
                      AND c.createdAt >= ?
                    ORDER BY c.createdAt ASC, c.id ASC
                    """,
                arguments: [trimmed, floor]
            )
            return rows.compactMap { row -> ViewerReviewComment? in
                guard let id: String = row["id"],
                      let prID: String = row["prID"],
                      let fullName: String = row["repoFullName"],
                      let number: Int = row["number"],
                      let body: String = row["body"],
                      let createdAt: Double = row["createdAt"]
                else { return nil }
                return ViewerReviewComment(
                    id: id,
                    // The same tolerant parse ``PullRequestRecord/summary`` uses, so a stored
                    // `repoFullName` without a slash degrades to a readable reference instead of
                    // dropping the row.
                    repo: RepoRef.parse(fullName: fullName)
                        ?? RepoRef(owner: fullName, name: fullName),
                    prID: prID,
                    number: number,
                    body: body,
                    createdAt: Date(timeIntervalSince1970: createdAt)
                )
            }
        }
    }

    // MARK: - Sync state

    /// Reads a scalar sync-state value.
    /// - Parameter key: The state key, e.g. `"notifications.lastModified"`.
    public func syncState(forKey key: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM sync_state WHERE key = ?",
                arguments: [key]
            )
        }
    }

    /// Writes a scalar sync-state value.
    /// - Parameters:
    ///   - value: The value, or `nil` to clear it.
    ///   - key: The state key.
    public func setSyncState(_ value: String?, forKey key: String) async throws {
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            try SyncStateRecord(key: key, value: value, updatedAt: now).save(db)
        }
    }

    // MARK: - Agent registry overrides

    /// Reads the user's agent-registry extensions.
    public func agentRegistryOverrides() async throws -> [AgentRegistryEntry] {
        try await writer.read { db in
            try AgentOverrideRecord.fetchAll(
                db,
                sql: "SELECT * FROM agent_registry_overrides WHERE isEnabled = 1 ORDER BY id ASC"
            ).map(\.registryEntry)
        }
    }

    /// Adds or replaces one agent-registry extension.
    /// - Parameter entry: The entry to store.
    public func saveAgentRegistryOverride(_ entry: AgentRegistryEntry) async throws {
        try await writer.write { db in
            try AgentOverrideRecord(entry: entry).save(db)
        }
    }

    /// Removes an agent-registry extension.
    /// - Parameter id: The entry's id.
    public func deleteAgentRegistryOverride(id: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM agent_registry_overrides WHERE id = ?",
                arguments: [id]
            )
        }
    }
}
