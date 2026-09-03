import Foundation
import ShepherdCore
import ShepherdPersistence

/// Which round of the pull request the review screen is showing (ADR 0028).
enum RoundView: String, CaseIterable, Identifiable, Sendable {
    /// Everything the pull request changes, the way the review screen has always opened.
    case all
    /// Only what changed since the head the reviewer last reviewed.
    case sinceReview

    var id: String { rawValue }

    /// The segmented-control label.
    var title: String {
        switch self {
        case .all: return String(localized: "All files")
        case .sinceReview: return String(localized: "Since your review")
        }
    }
}

/// Everything the review screen knows about the round the reviewer last reviewed.
///
/// Computed locally from the snapshot the outbox drain stored and the detail the app already
/// holds; no GitHub call is involved (ADR 0028).
struct SinceReviewRound: Sendable, Equatable {
    /// The diff the review was written against.
    var snapshot: ReviewSnapshot
    /// How many heads of this pull request have been reviewed on this Mac.
    var roundCount: Int
    /// The pull request's current head commit.
    var currentHeadOid: String
    /// The files and hunks that differ between the two heads.
    var interdiff: [InterdiffFile]
    /// The reviewer's own findings from that round, each with its state.
    var findings: [ReviewFinding]

    /// Whether the pull request has moved on since the review.
    var hasMoved: Bool { snapshot.isBehind(currentHeadOid) }

    /// Whether the screen has anything to show in ``RoundView/sinceReview``.
    ///
    /// A snapshot whose head is still the current one has nothing to compare, and a snapshot
    /// Shepherd could not read leaves an empty interdiff — in both cases the segmented control
    /// stays away rather than offering an empty tab.
    var isOffered: Bool { hasMoved && !interdiff.isEmpty }

    /// How many findings the new round left where they were.
    var unchangedFindingCount: Int {
        findings.filter { $0.state == .unchanged }.count
    }

    /// The interdiff files as the file list and the diff viewer want them.
    var changedFiles: [ChangedFile] {
        interdiff.map { $0.changedFile() }
    }
}

/// What the inbox row says about the rounds of one pull request.
struct ReviewRoundsSummary: Sendable, Equatable {
    /// How many heads have been reviewed.
    var roundCount: Int
    /// How many of the reviewer's findings the newest round left unchanged, or `nil` when the
    /// interdiff was not computed for this row — a row past the inbox cap, or one whose head has
    /// not moved since the reviewed one. `nil` is not `0`: the chip must never claim a count
    /// Shepherd did not work out.
    var unchangedFindingCount: Int?

    /// The row's chip text, or `nil` when there is nothing worth a chip.
    ///
    /// Two counters, each pluralised on its own through the catalog's plural variations and
    /// joined with a middle dot, because one key with two numbers cannot be pluralised for both.
    var chipText: String? {
        guard roundCount > 0 else { return nil }
        let rounds = String(localized: "\(roundCount) rounds")
        guard let unchangedFindingCount, unchangedFindingCount > 0 else { return rounds }
        return rounds + " · " + String(localized: "\(unchangedFindingCount) findings unchanged")
    }
}

/// Reads the baseline and computes the interdiff (ADR 0028).
///
/// Split from ``ReviewModel`` because the inbox needs the same numbers for its rows, and
/// because the computation itself is pure: everything below `load` and `rounds` is
/// ``ShepherdCore/Interdiff`` and ``ShepherdCore/ReviewFindings``, which are unit-tested on
/// Linux.
enum SinceReviewLoader {
    /// How many inbox rows one refresh is willing to compute an interdiff for.
    ///
    /// The chip is a nicety on a list that must stay instant, and the plan's volume is ten to
    /// forty pull requests a week; rows past the cap show their round count and no finding
    /// count until they are opened.
    static let inboxRowLimit = 20

    /// Computes the round from a snapshot and the current detail. Pure.
    /// - Parameters:
    ///   - snapshot: The stored baseline.
    ///   - roundCount: How many snapshots this pull request has.
    ///   - detail: The pull request as it is now.
    ///   - viewerLogin: The signed-in user's login.
    /// - Returns: The computed round.
    static func compute(
        snapshot: ReviewSnapshot,
        roundCount: Int,
        detail: PullRequestDetail,
        viewerLogin: String
    ) -> SinceReviewRound {
        let interdiff = snapshot.isBehind(detail.summary.headRefOid)
            ? Interdiff.compute(before: snapshot.files, after: detail.files)
            : []
        return SinceReviewRound(
            snapshot: snapshot,
            roundCount: roundCount,
            currentHeadOid: detail.summary.headRefOid,
            interdiff: interdiff,
            findings: ReviewFindings.compute(
                threads: detail.threads,
                interdiff: interdiff,
                viewerLogin: viewerLogin,
                reviewedAt: snapshot.reviewedAt
            )
        )
    }

    /// Reads the newest snapshot of a pull request and computes its round.
    /// - Parameters:
    ///   - database: The local source of truth.
    ///   - detail: The pull request as it is now.
    ///   - viewerLogin: The signed-in user's login.
    /// - Returns: The round, or `nil` when this pull request has never been reviewed here.
    static func load(
        database: DatabaseManager,
        detail: PullRequestDetail,
        viewerLogin: String
    ) async -> SinceReviewRound? {
        guard let snapshot = try? await database.latestReviewSnapshot(prID: detail.id) else {
            return nil
        }
        let roundCount = (try? await database.reviewSnapshotCount(prID: detail.id)) ?? 1
        return compute(
            snapshot: snapshot,
            roundCount: roundCount,
            detail: detail,
            viewerLogin: viewerLogin
        )
    }

    /// The round counts (and unchanged-finding counts) the inbox shows.
    ///
    /// One grouped query for the whole list, then at most ``inboxRowLimit`` interdiffs for the
    /// rows that actually moved on since their review. A row whose snapshot is still the current
    /// head gets its round count and nothing else — there is no interdiff to count findings in.
    /// - Parameters:
    ///   - database: The local source of truth.
    ///   - rows: The inbox rows, in display order.
    ///   - viewerLogin: The signed-in user's login.
    /// - Returns: One entry per row that has been reviewed at least once, keyed by node id.
    static func rounds(
        database: DatabaseManager,
        rows: [PullRequestSummary],
        viewerLogin: String
    ) async -> [String: ReviewRoundsSummary] {
        guard let counts = try? await database.reviewSnapshotCounts(prIDs: rows.map(\.id)),
              !counts.isEmpty
        else { return [:] }

        var result: [String: ReviewRoundsSummary] = [:]
        var computed = 0
        for row in rows {
            guard let count = counts[row.id], count > 0 else { continue }
            result[row.id] = ReviewRoundsSummary(roundCount: count, unchangedFindingCount: nil)
            guard computed < inboxRowLimit else { continue }
            guard let snapshot = try? await database.latestReviewSnapshot(prID: row.id),
                  snapshot.isBehind(row.headRefOid),
                  let detail = try? await database.fetchPullRequestDetail(id: row.id)
            else { continue }
            computed += 1
            let round = compute(
                snapshot: snapshot,
                roundCount: count,
                detail: detail,
                viewerLogin: viewerLogin
            )
            result[row.id] = ReviewRoundsSummary(
                roundCount: count,
                unchangedFindingCount: round.unchangedFindingCount
            )
        }
        return result
    }
}
