import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    // MARK: - Writing

    /// Writes outcomes, replacing any row for the same pull request.
    ///
    /// One transaction for the batch, for ``saveTriageVerdicts(_:)``'s reason: the backfill walks
    /// a repository a page at a time and each row is tiny, so a transaction per pull request would
    /// mean one `fsync` per closed pull request for work nobody is watching.
    ///
    /// Unlike every other derived table, nothing is skipped here: there is no foreign key to
    /// refuse a row, because the pull request an outcome describes has by definition left the
    /// inbox (ADR 0027). Replacing rather than merging is what makes running the backfill twice a
    /// no-op — and what lets the sweep's own reading of a pull request's final state overwrite the
    /// backfill's.
    ///
    /// A row's existing `revertedByPRID` is **kept** when the incoming value is `nil`, because the
    /// link is discovered separately and later (``applyRevertLinks(_:)``): a second backfill that
    /// re-imported the pull request must not un-revert it.
    /// - Parameter closed: The closed pull requests to store.
    /// - Returns: How many rows were written.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    @discardableResult
    public func savePullRequestOutcomes(
        _ closed: [ClosedPullRequest]
    ) async throws -> Int {
        guard !closed.isEmpty else { return 0 }
        let records = closed.map { PullRequestOutcomeRecord(closed: $0) }
        return try await writer.write { db in
            for stored in records {
                var record = stored
                if record.revertedByPRID == nil {
                    let existing: String? = try String.fetchOne(
                        db,
                        sql: """
                            SELECT revertedByPRID FROM pull_request_outcomes WHERE prID = ?
                            """,
                        arguments: [record.prID]
                    )
                    record.revertedByPRID = existing
                }
                try record.save(db)
            }
            return records.count
        }
    }

    /// Records that some pull requests were reverted.
    ///
    /// A separate write from ``savePullRequestOutcomes(_:)`` because the link is discovered
    /// *after* both halves are stored: the reverting pull request is normally read in a later
    /// page — or a later sweep — than the one it undoes. A link whose target is not on disk, or
    /// whose target was never merged, is silently ignored: the honest reading of the first is
    /// "the pull request this reverts closed before the ninety-day window", and of the second
    /// "the text names something that was never merged, so there is nothing to undo".
    /// - Parameter links: The reverting pull request's node id, keyed by the node id of the pull
    ///   request it reverts, as ``ShepherdCore/RevertDetector/links(candidates:known:)`` returns.
    /// - Returns: How many rows were updated.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    @discardableResult
    public func applyRevertLinks(_ links: [String: String]) async throws -> Int {
        guard !links.isEmpty else { return 0 }
        // Sorted so a batch is applied in one order on every Mac and in every test run; the
        // updates are independent, but a deterministic order is free.
        let pairs = links.sorted { $0.key < $1.key }
        return try await writer.write { db in
            var updated = 0
            for (targetID, revertingID) in pairs {
                let exists = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM pull_request_outcomes WHERE prID = ? AND merged = 1
                        )
                        """,
                    arguments: [targetID]
                ) ?? false
                guard exists else { continue }
                try db.execute(
                    sql: "UPDATE pull_request_outcomes SET revertedByPRID = ? WHERE prID = ?",
                    arguments: [revertingID, targetID]
                )
                updated += 1
            }
            return updated
        }
    }

    // MARK: - Reading

    /// Every outcome that closed since one moment.
    ///
    /// The whole window in one query, on purpose, and for ``triageVerdicts()``'s reason: these
    /// are small rows about pull requests that closed in the last ninety days — a few hundred for
    /// a busy solo maintainer — and the inbox needs *all* of them to put a badge on every row it
    /// shows. A query per (agent, repository) pair would be one round trip per rail row for
    /// numbers that are then counted in Swift anyway.
    ///
    /// The counting itself is the pure
    /// ``ShepherdCore/TrackRecord/compute(outcomes:subject:repo:since:)``, because "23 merged,
    /// 2 reverted, 78 %" is a number a user reads off a badge and acts on.
    /// - Parameter since: The oldest `closedAt` to read; inclusive.
    /// - Returns: The outcomes, most recently closed first.
    /// - Throws: A `DatabaseError` when the read fails.
    public func pullRequestOutcomes(since: Date) async throws -> [PullRequestOutcome] {
        let cutoff = since.timeIntervalSince1970
        return try await writer.read { db in
            try PullRequestOutcomeRecord
                .fetchAll(
                    db,
                    sql: """
                        SELECT * FROM pull_request_outcomes
                        WHERE closedAt >= ?
                        ORDER BY closedAt DESC
                        """,
                    arguments: [cutoff]
                )
                .map(\.outcome)
        }
    }

    /// One author's outcomes in one repository.
    ///
    /// The index's query — `(repoFullName, agentName, closedAt)` — kept for the callers that ask
    /// about a single badge: the popover, and anything that wants one agent's numbers without
    /// reading the window. `agentName: nil` means "a human or a plain bot", which is a `NULL`
    /// rather than a missing filter, so the two spellings of "no agent" cannot be confused.
    /// - Parameters:
    ///   - repo: The repository to count in.
    ///   - agentName: The agent's display name, or `nil` for rows that carry no agent.
    ///   - since: The oldest `closedAt` to read; inclusive.
    /// - Returns: The outcomes, most recently closed first.
    /// - Throws: A `DatabaseError` when the read fails.
    public func pullRequestOutcomes(
        repo: RepoRef,
        agentName: String?,
        since: Date
    ) async throws -> [PullRequestOutcome] {
        let cutoff = since.timeIntervalSince1970
        let fullName = repo.fullName
        return try await writer.read { db in
            let records: [PullRequestOutcomeRecord]
            if let agentName {
                records = try PullRequestOutcomeRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM pull_request_outcomes
                        WHERE repoFullName = ? COLLATE NOCASE
                          AND agentName = ? COLLATE NOCASE
                          AND closedAt >= ?
                        ORDER BY closedAt DESC
                        """,
                    arguments: [fullName, agentName, cutoff]
                )
            } else {
                records = try PullRequestOutcomeRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM pull_request_outcomes
                        WHERE repoFullName = ? COLLATE NOCASE
                          AND agentName IS NULL
                          AND closedAt >= ?
                        ORDER BY closedAt DESC
                        """,
                    arguments: [fullName, cutoff]
                )
            }
            return records.map(\.outcome)
        }
    }

    /// The merged pull requests of one repository a revert could be pointing at.
    ///
    /// What ``ShepherdCore/RevertDetector/links(candidates:known:)`` takes as its `known`
    /// argument: only merged rows, because only a merged pull request can be reverted, and only
    /// the columns a title, a number or a merge commit can be matched against.
    /// - Parameters:
    ///   - repo: The repository to read.
    ///   - since: The oldest `closedAt` to read; inclusive.
    /// - Returns: The stored merged pull requests, oldest first.
    /// - Throws: A `DatabaseError` when the read fails.
    public func mergedClosedPullRequests(
        repo: RepoRef,
        since: Date
    ) async throws -> [ClosedPullRequest] {
        let cutoff = since.timeIntervalSince1970
        let fullName = repo.fullName
        return try await writer.read { db in
            try PullRequestOutcomeRecord
                .fetchAll(
                    db,
                    sql: """
                        SELECT * FROM pull_request_outcomes
                        WHERE merged = 1
                          AND repoFullName = ? COLLATE NOCASE
                          AND closedAt >= ?
                        ORDER BY closedAt ASC
                        """,
                    arguments: [fullName, cutoff]
                )
                .map(\.closedPullRequest)
        }
    }

    /// How many outcomes are stored, for the Settings line that says whether there is a history.
    /// - Returns: The row count.
    /// - Throws: A `DatabaseError` when the read fails.
    public func pullRequestOutcomeCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request_outcomes") ?? 0
        }
    }

    /// Whether one pull request already has a stored outcome.
    ///
    /// The sweep's gate: a pull request that left the inbox is read once, and a row already on
    /// disk — from the backfill, or from a previous sweep that saw the same disappearance — means
    /// there is nothing to fetch (ADR 0027).
    /// - Parameter prID: The pull request's node id.
    /// - Returns: `true` when a row exists.
    /// - Throws: A `DatabaseError` when the read fails.
    public func hasPullRequestOutcome(prID: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM pull_request_outcomes WHERE prID = ?)",
                arguments: [prID]
            ) ?? false
        }
    }

    /// The single-outcome query, shared by ``observePullRequestOutcome(prID:)``.
    ///
    /// The row-shaped sibling of ``hasPullRequestOutcome(prID:)``, and it exists for one reader:
    /// an open review screen, which needs to know not only *that* the pull request under it left
    /// the inbox but *how* — a merge and an abandonment are two different sentences to put in
    /// front of somebody who was halfway through reviewing it.
    /// - Parameters:
    ///   - db: The database connection to read from.
    ///   - prID: The pull request's node id.
    /// - Returns: The stored outcome, or `nil` when the pull request has none.
    static func loadPullRequestOutcome(
        _ db: Database,
        prID: String
    ) throws -> PullRequestOutcome? {
        try PullRequestOutcomeRecord.fetchOne(
            db,
            sql: "SELECT * FROM pull_request_outcomes WHERE prID = ?",
            arguments: [prID]
        )?.outcome
    }

    // MARK: - Deleting

    /// Deletes one repository's outcomes.
    ///
    /// There is no cascade to do this — the whole point of the table is that it outlives the pull
    /// requests it describes — so forgetting a repository's history is an explicit delete.
    /// - Parameter repo: The repository whose history goes.
    /// - Throws: A `DatabaseError` when the write fails.
    public func deletePullRequestOutcomes(repo: RepoRef) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM pull_request_outcomes WHERE repoFullName = ? COLLATE NOCASE",
                arguments: [repo.fullName]
            )
        }
    }

    /// Deletes every stored outcome.
    ///
    /// "Clear history" in Settings → Automation: the badges disappear, the lanes do not move, and
    /// the next backfill can fetch it all again. Device-local state, like the search index and the
    /// auto-merge ledger, so nothing about this reaches another Mac (ADR 0014).
    /// - Throws: A `DatabaseError` when the write fails.
    public func deleteAllPullRequestOutcomes() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM pull_request_outcomes")
        }
    }
}

// MARK: - The lane's diff input

extension DatabaseManager {
    /// The changed files of some pull requests, **without** their patches.
    ///
    /// What the trust lane needs and all it needs: ``ShepherdCore/TrustSensitivePaths`` reads
    /// paths and statuses, never a diff, and a pull request's patches are the largest thing in
    /// the database — one inbox's worth would be megabytes read on every refresh to answer a
    /// question about file names. So `patch` is left in SQLite and the returned
    /// ``ShepherdCore/ChangedFile`` values carry `nil` for it, which ``ChangedFile/hasPatch``
    /// already reports honestly.
    ///
    /// A pull request nobody has opened yet is **absent** from the result rather than present
    /// with an empty list, and the difference is load-bearing: "this pull request changes nothing
    /// sensitive" and "Shepherd has not fetched this diff" are different facts, and the lane
    /// treats the second one as a full review (ADR 0027).
    /// - Parameter prIDs: The pull requests to read.
    /// - Returns: The files, keyed by node id, in the order the detail fetch stored them.
    /// - Throws: A `DatabaseError` when the read fails.
    public func changedFilePaths(prIDs: [String]) async throws -> [String: [ChangedFile]] {
        let ids = Array(Set(prIDs))
        guard !ids.isEmpty else { return [:] }
        return try await writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT prID, path, previousPath, status, additions, deletions
                    FROM changed_files
                    WHERE prID IN (\(placeholders))
                    ORDER BY prID ASC, sortIndex ASC
                    """,
                arguments: StatementArguments(ids)
            )
            var result: [String: [ChangedFile]] = [:]
            for row in rows {
                let prID: String = row["prID"]
                let path: String = row["path"]
                let previousPath: String? = row["previousPath"]
                let status: String = row["status"]
                let additions: Int = row["additions"] ?? 0
                let deletions: Int = row["deletions"] ?? 0
                result[prID, default: []].append(
                    ChangedFile(
                        path: path,
                        previousPath: previousPath,
                        status: FileChangeStatus(rawValue: status) ?? .modified,
                        additions: additions,
                        deletions: deletions,
                        patch: nil,
                        isViewed: false
                    )
                )
            }
            return result
        }
    }
}
