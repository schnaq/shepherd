import Foundation

/// The part of a pull request's stack that the inbox holds, bottom to top (ADR 0042).
///
/// One value feeds three places — the detail panel's and the review screen's stack list and the
/// merge sheet's "also merges" line — so the rules for which rows belong to a stack and how many
/// are missing are written once, and tested without a view. A stack is not a grouping in the
/// inbox; this only answers "what else is in it" for the one pull request on screen.
public struct PullRequestStackOverview: Sendable, Equatable {
    /// The shown pull request's place in its stack, as its own row reports it.
    public let stack: PullRequestStack
    /// The shown pull request's node id, so a list can mark it.
    public let currentID: String
    /// Every row of the same repository and stack number the inbox holds, the shown pull request
    /// included, in position order (bottom first). One row per position: two claiming the same
    /// one (a sweep caught mid-restack) keep the first in inbox order.
    public let members: [PullRequestSummary]

    /// Creates an overview.
    public init(stack: PullRequestStack, currentID: String, members: [PullRequestSummary]) {
        self.stack = stack
        self.currentID = currentID
        self.members = members
    }

    /// How many of the stack's pull requests the inbox does not hold — somebody else's, or
    /// filtered out by the sweep. Never negative, even when the rows disagree about the size.
    public var missingCount: Int { max(0, stack.size - members.count) }

    /// The pull requests below the shown one that the inbox holds, bottom first — what merges
    /// along with it.
    public var below: [PullRequestSummary] {
        members.filter { ($0.stack?.position ?? 0) < stack.position }
    }

    /// How many pull requests are below the shown one, whether the inbox holds them or not.
    public var belowCount: Int { max(0, stack.position - 1) }

    /// Whether the inbox holds every pull request below the shown one, so a sentence can name
    /// them all. Naming only some would understate what a merge takes along.
    public var knowsEveryPullRequestBelow: Bool { below.count == belowCount }

    /// The overview for a pull request, or `nil` when it is in no stack.
    /// - Parameters:
    ///   - pullRequest: The pull request on screen.
    ///   - rows: **Every** inbox row, not the filtered list on screen: a search filter must not
    ///     make the rest of a stack read as missing.
    public static func make(
        for pullRequest: PullRequestSummary,
        in rows: [PullRequestSummary]
    ) -> PullRequestStackOverview? {
        guard let stack = pullRequest.stack else { return nil }
        var byPosition: [Int: PullRequestSummary] = [stack.position: pullRequest]
        for row in rows where row.id != pullRequest.id {
            guard let other = row.stack, other.number == stack.number, row.repo == pullRequest.repo else {
                continue
            }
            if byPosition[other.position] == nil { byPosition[other.position] = row }
        }
        return PullRequestStackOverview(
            stack: stack,
            currentID: pullRequest.id,
            members: byPosition.keys.sorted().compactMap { byPosition[$0] }
        )
    }
}
