import Foundation
import ShepherdCore
import ShepherdPersistence

/// One lane row in the inbox rail, with its count (ADR 0027).
struct TrustLaneFacet: Identifiable, Equatable, Sendable {
    /// The lane.
    var lane: TrustLane
    /// How many rows of the current smart view are in it.
    var count: Int

    /// Identified by the lane.
    var id: String { lane.rawValue }
}

/// What the inbox knows about lanes and track records right now (ADR 0027).
///
/// One value rather than two dictionaries on the model, so a refresh replaces both at the same
/// moment: a list showing last refresh's lanes with this refresh's badges would put a pull request
/// under "Short look" with a badge counted from a different window.
struct TrustLaneSnapshot: Equatable, Sendable {
    /// The lane of each row, keyed by node id.
    var lanes: [String: TrustLane] = [:]
    /// The track record behind each row's badge, keyed by node id.
    ///
    /// A row whose author has no closed pull requests in the window is **absent** rather than
    /// present with an empty record: no history means no badge at all, which is what a fresh
    /// install looks like before the backfill has run.
    var records: [String: TrackRecord] = [:]

    /// The empty snapshot — every row a full review, no badge anywhere.
    static let empty = TrustLaneSnapshot()

    /// The lane of one row, defaulting to the wide lane.
    ///
    /// The default matters: a row the snapshot has not been computed for yet is a *full review*,
    /// not a short look, because "short look" is the narrower claim (ADR 0027). So a list that is
    /// still loading shows everything under one header rather than promising a quick pass at
    /// something nobody has classified.
    /// - Parameter id: The pull request's node id.
    func lane(for id: String) -> TrustLane {
        lanes[id] ?? .fullReview
    }

    /// The track record of one row, or `nil` when there is nothing to show.
    /// - Parameter id: The pull request's node id.
    func record(for id: String) -> TrackRecord? {
        guard let record = records[id], !record.isEmpty else { return nil }
        return record
    }
}

/// Works out the lanes and the badges for the rows the inbox is showing (ADR 0027).
///
/// The database work and the pure computation are separate functions on purpose: the interesting
/// half — which rows land in which lane, and which authors get a badge — is
/// ``snapshot(rows:files:outcomes:configuration:since:extraSecurityHints:)``, a pure function over
/// values, tested without a database. ``load(database:rows:configuration:now:extraSecurityHints:)``
/// is two queries and a call into it.
enum TrustLaneLoader {
    /// Reads what the snapshot needs and computes it.
    ///
    /// Two queries for the whole list, never one per row: the cached diffs' *paths* (no patches —
    /// ``ShepherdPersistence/DatabaseManager/changedFilePaths(prIDs:)`` explains why) and the
    /// ninety-day window of outcomes. Both are small; the second is the same read the badges of
    /// every row share.
    /// - Parameters:
    ///   - database: The local source of truth.
    ///   - rows: The rows to classify.
    ///   - configuration: The lane thresholds.
    ///   - now: The moment the ninety-day window is measured back from.
    ///   - extraSecurityHints: The user's own sensitive-path substrings, from settings.
    /// - Returns: The snapshot, or ``TrustLaneSnapshot/empty`` when either read fails — a failed
    ///   read leaves every row a full review and no badges, which is the honest degraded state.
    static func load(
        database: DatabaseManager,
        rows: [PullRequestSummary],
        configuration: TrustLaneConfiguration,
        now: Date = Date(),
        extraSecurityHints: [String] = []
    ) async -> TrustLaneSnapshot {
        guard !rows.isEmpty else { return .empty }
        let since = TrackRecord.windowStart(from: now)
        let files = (try? await database.changedFilePaths(prIDs: rows.map(\.id))) ?? [:]
        let outcomes = (try? await database.pullRequestOutcomes(since: since)) ?? []
        return snapshot(
            rows: rows,
            files: files,
            outcomes: outcomes,
            configuration: configuration,
            since: since,
            extraSecurityHints: extraSecurityHints
        )
    }

    /// Classifies the rows and counts the badges.
    ///
    /// Two things are worth knowing about it, and both are ADR 0027's rules made mechanical:
    ///
    /// - **A row whose diff is not cached is a full review.** `files` is missing the pull request
    ///   entirely until somebody opens it or a sweep fetches it, and Shepherd cannot claim "no
    ///   sensitive path" about a diff it has never seen. So the sensitive-path flag is `true` for
    ///   such a row, which is what ``ShepherdCore/TrustLaneInput/sensitivePaths`` means.
    /// - **The record is counted per (author, repository) pair, once.** Ten pull requests from one
    ///   agent in one repository share one computation and one badge; the cache is what keeps a
    ///   forty-row inbox from counting the same ninety days forty times.
    /// - Parameters:
    ///   - rows: The rows to classify.
    ///   - files: The cached changed files, keyed by node id. A missing key means "no diff yet".
    ///   - outcomes: The stored outcomes of the window.
    ///   - configuration: The lane thresholds.
    ///   - since: The oldest `closedAt` the badges count.
    ///   - extraSecurityHints: The user's own sensitive-path substrings.
    /// - Returns: The snapshot.
    static func snapshot(
        rows: [PullRequestSummary],
        files: [String: [ChangedFile]],
        outcomes: [PullRequestOutcome],
        configuration: TrustLaneConfiguration,
        since: Date,
        extraSecurityHints: [String] = []
    ) -> TrustLaneSnapshot {
        var snapshot = TrustLaneSnapshot()
        var cache: [String: TrackRecord] = [:]
        for row in rows {
            let sensitive: Bool
            if let rowFiles = files[row.id] {
                sensitive = TrustSensitivePaths.contains(
                    files: rowFiles,
                    extraHints: extraSecurityHints
                )
            } else {
                sensitive = true
            }
            snapshot.lanes[row.id] = TrustLane.classify(
                summary: row,
                sensitivePaths: sensitive,
                configuration: configuration
            )

            let subject = TrackRecordSubject(actor: row.author)
            let cacheKey = "\(row.repo.fullName.lowercased())\u{1}\(subjectKey(subject))"
            let record: TrackRecord
            if let cached = cache[cacheKey] {
                record = cached
            } else {
                record = TrackRecord.compute(
                    outcomes: outcomes,
                    subject: subject,
                    repo: row.repo,
                    since: since
                )
                cache[cacheKey] = record
            }
            guard !record.isEmpty else { continue }
            snapshot.records[row.id] = record
        }
        return snapshot
    }

    /// Counts the lanes of some rows, in display order, omitting empty lanes.
    ///
    /// Empty lanes are omitted for the RISK facet's reason: a rail row that filters to nothing is
    /// a dead control. So an inbox with nothing green and small shows one lane header, not two —
    /// and an inbox where *everything* is a short look shows one too.
    /// - Parameters:
    ///   - rows: The rows to count.
    ///   - snapshot: The snapshot to read the lanes from.
    /// - Returns: The facets, short lane first.
    static func facets(
        rows: [PullRequestSummary],
        snapshot: TrustLaneSnapshot
    ) -> [TrustLaneFacet] {
        var counts: [TrustLane: Int] = [:]
        for row in rows {
            counts[snapshot.lane(for: row.id), default: 0] += 1
        }
        return TrustLane.allCases
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { lane in
                guard let count = counts[lane], count > 0 else { return nil }
                return TrustLaneFacet(lane: lane, count: count)
            }
    }

    /// A stable dictionary key for a subject.
    private static func subjectKey(_ subject: TrackRecordSubject) -> String {
        switch subject {
        case .agent(let name): return "agent:\(name.lowercased())"
        case .author(let login): return "author:\(login.lowercased())"
        }
    }
}
