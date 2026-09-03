import Foundation

/// Where one stored outcome came from (ADR 0027).
public enum PullRequestOutcomeSource: String, Sendable, Codable, Hashable, CaseIterable {
    /// The sweep saw an open pull request disappear and read its final state once.
    case sync
    /// The one-time backfill of the last ninety days read it from the closed-pull-request search.
    case backfill
}

/// What became of one pull request, kept so an agent's track record can be counted (ADR 0027).
///
/// One row per pull request, keyed by its node id, written from two places and upserted by both:
/// a pull request the backfill imported and the sweep later saw close again ends up as one row,
/// not two. Nothing here is a judgement — every field is something GitHub said — and by ADR 0027's
/// rule no automation reads any of it.
public struct PullRequestOutcome: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id of the pull request — the primary key, as everywhere in Shepherd.
    public var prID: String
    /// The repository it belonged to.
    public var repo: RepoRef
    /// The display name of the agent that opened it, or `nil` for a human or a plain bot.
    ///
    /// The *name* rather than the registry id, because that is what the badge says and what the
    /// badge groups by: an agent the user renamed in their registry keeps one track record under
    /// the name they gave it.
    public var agentName: String?
    /// The author's login, kept beside ``agentName`` so a human's outcomes are still countable.
    public var authorLogin: String
    /// When the pull request was opened.
    public var openedAt: Date
    /// When it was closed — merged or not.
    public var closedAt: Date
    /// Whether it was merged.
    public var merged: Bool
    /// The node id of the pull request that reverted this one, when one was found.
    public var revertedByPRID: String?
    /// Whether the checks on the **first** commit of the branch were green.
    ///
    /// `nil` when nothing can be said: no checks on that commit, checks still running, or a
    /// pull request whose first commit Shepherd never saw. Three states rather than two on
    /// purpose — a `false` here is "the first push was red", and an unknown must not be counted
    /// as one.
    public var firstPushCIGreen: Bool?
    /// How many reviews requested changes before the pull request closed.
    public var reviewRounds: Int
    /// Added plus deleted lines.
    public var changedLines: Int
    /// Which of the two writers produced this row.
    public var source: PullRequestOutcomeSource

    /// Creates an outcome.
    public init(
        prID: String,
        repo: RepoRef,
        agentName: String? = nil,
        authorLogin: String,
        openedAt: Date,
        closedAt: Date,
        merged: Bool,
        revertedByPRID: String? = nil,
        firstPushCIGreen: Bool? = nil,
        reviewRounds: Int = 0,
        changedLines: Int = 0,
        source: PullRequestOutcomeSource
    ) {
        self.prID = prID
        self.repo = repo
        self.agentName = agentName
        self.authorLogin = authorLogin
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.merged = merged
        self.revertedByPRID = revertedByPRID
        self.firstPushCIGreen = firstPushCIGreen
        self.reviewRounds = reviewRounds
        self.changedLines = changedLines
        self.source = source
    }

    /// `PullRequestOutcome` is identified by its ``prID``.
    public var id: String { prID }

    /// Whether this outcome was reverted by another pull request.
    public var wasReverted: Bool { revertedByPRID != nil }
}

/// One closed pull request as GitHub handed it over, before it becomes a stored outcome.
///
/// The outcome table holds no title and no description — nothing needs them once the counting is
/// done — but revert detection does: `Revert "…"` is in a title and `This reverts commit …` is in
/// a body. So the read carries both alongside the outcome, ``RevertDetector`` links them, and only
/// the outcomes are written.
public struct ClosedPullRequest: Sendable, Codable, Hashable, Identifiable {
    /// The row that will be stored.
    public var outcome: PullRequestOutcome
    /// The pull request number, for the revert reference that names one.
    public var number: Int
    /// The title, as typed.
    public var title: String
    /// The description, as Markdown source.
    public var bodyMarkdown: String
    /// The merge commit's SHA, when GitHub reported one.
    public var mergeCommitOid: String?

    /// Creates a closed pull request.
    public init(
        outcome: PullRequestOutcome,
        number: Int,
        title: String,
        bodyMarkdown: String = "",
        mergeCommitOid: String? = nil
    ) {
        self.outcome = outcome
        self.number = number
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.mergeCommitOid = mergeCommitOid
    }

    /// Shares the identity of its ``outcome``.
    public var id: String { outcome.prID }
}
