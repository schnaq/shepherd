import Foundation

/// What the pull request says, beside what Shepherd found — one line per claim (ADR 0026).
///
/// The whole of the card's content as a value: pure, cheap, and derived from nothing but a
/// ``PullRequestDetail`` Shepherd has already fetched. Three properties of the shape are the
/// decision rather than the implementation:
///
/// - **One line per claim, and no aggregate.** There is no score, no count of ✓ against ✗ and no
///   "overall" field, because any of those would be the verdict this card refuses to give
///   (ADR 0007's rule, applied to a tier-1 feature).
/// - **An empty report is a real answer.** A pull request whose description claims nothing gets no
///   card at all rather than an empty one saying "no claims found" — the reviewer did not ask a
///   question, so there is nothing to answer.
/// - **The order is total and stable.** ``ClaimExtractor`` orders the claims; this type preserves
///   that order, so re-opening a pull request cannot reshuffle the card.
public struct ClaimsEvidenceReport: Sendable, Hashable {
    /// One row of the card: a claim and what the diff and CI say about it.
    public struct Line: Sendable, Hashable, Identifiable {
        /// What the description said.
        public var claim: Claim
        /// What Shepherd found.
        public var verdict: EvidenceVerdict

        /// Creates a line.
        /// - Parameters:
        ///   - claim: The claim.
        ///   - verdict: Its evidence.
        public init(claim: Claim, verdict: EvidenceVerdict) {
            self.claim = claim
            self.verdict = verdict
        }

        /// A line is identified by its claim.
        public var id: String { claim.id }
    }

    /// The lines, in ``ClaimExtractor``'s order.
    public var lines: [Line]

    /// Creates a report.
    /// - Parameter lines: The lines, already ordered.
    public init(lines: [Line]) {
        self.lines = lines
    }

    /// The report with nothing in it — a description that claimed nothing.
    public static let empty = ClaimsEvidenceReport(lines: [])

    /// Whether there is anything to show. An empty report means: draw no card.
    public var isEmpty: Bool { lines.isEmpty }

    /// The lines whose evidence contradicts the claim.
    ///
    /// The only grouping this type offers, and it exists because those are the lines the card
    /// offers "Turn into a comment" on — not because ✗ lines are more true than ? lines.
    public var contradictedLines: [Line] {
        lines.filter { $0.verdict.status == .contradicted }
    }

    /// Builds the report for one pull request.
    ///
    /// The summary is passed in beside the detail rather than read from `detail.summary` because
    /// the review screen holds the newest inbox row: a detail fetched a minute ago can carry a
    /// stale check rollup, and "CI is green" is the one fact on this card that goes out of date on
    /// its own. The given row wins, and every check below sees it.
    /// - Parameters:
    ///   - detail: The pull request's description, files, checks and commits.
    ///   - summary: The pull request's current inbox row.
    /// - Returns: The report, empty when the description claims nothing.
    public static func build(
        detail: PullRequestDetail,
        summary: PullRequestSummary
    ) -> ClaimsEvidenceReport {
        let claims = ClaimExtractor.extract(from: detail.bodyMarkdown)
        guard !claims.isEmpty else { return .empty }
        var current = detail
        current.summary = summary
        return ClaimsEvidenceReport(
            lines: claims.map { claim in
                Line(claim: claim, verdict: EvidenceChecker.check(claim, in: current))
            }
        )
    }
}
