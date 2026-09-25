import Foundation

/// Why a ticked pull request is left out of a merge series (ADR 0041).
///
/// Only what could never turn into a merge by waiting. Running checks are deliberately *not* a
/// reason: waiting for them is the point of a series. The raw values that
/// ``BulkTriageSkipReason`` also has are spelled the same, so the app can share their strings.
public enum MergeSeriesExclusionReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// A merge for it is already in the outbox or armed.
    case mergeOnItsWay
    /// The pull request is still a draft.
    case draft
    /// GitHub reports conflicts with the base branch.
    case conflicting
    /// At least one check on the head commit failed.
    case checksFailing
    /// A reviewer asked for changes.
    case changesRequested
    /// The signed-in user opened it. A series merges what the reviewer judged in others' work;
    /// their own pull request is not swept into one by a tick.
    case ownPullRequest
}

/// The merge series a set of ticked pull requests amounts to, before the user presses Start.
///
/// A pure value, like ``BulkTriagePlan``: "which pull requests, in which order" is the whole
/// product risk of the sheet, so it is answered by a testable function rather than by a view.
public struct MergeSeriesPlan: Sendable, Equatable {
    /// A ticked pull request that is left out, with the reason.
    public struct Exclusion: Sendable, Equatable, Identifiable {
        /// The pull request.
        public let pullRequest: PullRequestSummary
        /// Why it is left out.
        public let reason: MergeSeriesExclusionReason

        /// Creates an exclusion.
        public init(pullRequest: PullRequestSummary, reason: MergeSeriesExclusionReason) {
            self.pullRequest = pullRequest
            self.reason = reason
        }

        /// Identified by its pull request.
        public var id: String { pullRequest.id }
    }

    /// The part of the plan for one repository — one series, if the user starts it.
    public struct Group: Sendable, Equatable, Identifiable {
        /// The repository.
        public let repository: RepoRef
        /// The pull requests that can go into the series, in the default merge order.
        public let candidates: [PullRequestSummary]
        /// The ones left out, in the order they were ticked.
        public let excluded: [Exclusion]

        /// Creates a group.
        public init(repository: RepoRef, candidates: [PullRequestSummary], excluded: [Exclusion]) {
            self.repository = repository
            self.candidates = candidates
            self.excluded = excluded
        }

        /// Identified by its repository.
        public var id: String { repository.fullName }

        /// Whether there is anything to start.
        public var isActionable: Bool { !candidates.isEmpty }
    }

    /// One group per repository, in the order each repository first appears among the ticks.
    public let groups: [Group]

    /// Creates a plan.
    public init(groups: [Group]) {
        self.groups = groups
    }

    /// Whether any repository has something to start.
    public var isActionable: Bool { groups.contains(where: \.isActionable) }

    /// Groups ticked pull requests by repository, leaves out what can never merge, and sorts
    /// the rest into the default order.
    /// - Parameters:
    ///   - pullRequests: The ticked rows, in display order.
    ///   - mergesOnTheirWay: Node ids with a merge already queued or armed
    ///     (`hasMergeOnItsWay`).
    /// - Returns: The plan.
    public static func make(
        pullRequests: [PullRequestSummary],
        mergesOnTheirWay: Set<String> = []
    ) -> MergeSeriesPlan {
        var order: [RepoRef] = []
        var byRepository: [RepoRef: [PullRequestSummary]] = [:]
        for pullRequest in pullRequests {
            if byRepository[pullRequest.repo] == nil { order.append(pullRequest.repo) }
            byRepository[pullRequest.repo, default: []].append(pullRequest)
        }
        return MergeSeriesPlan(groups: order.map { repository in
            var candidates: [PullRequestSummary] = []
            var excluded: [Exclusion] = []
            var seen: Set<String> = []
            for pullRequest in byRepository[repository] ?? [] where seen.insert(pullRequest.id).inserted {
                if let reason = exclusionReason(for: pullRequest, mergesOnTheirWay: mergesOnTheirWay) {
                    excluded.append(Exclusion(pullRequest: pullRequest, reason: reason))
                } else {
                    candidates.append(pullRequest)
                }
            }
            return Group(
                repository: repository,
                candidates: stacksBottomFirst(candidates.sorted(by: isMergedEarlier)),
                excluded: excluded
            )
        })
    }

    /// Puts the members of each stack into position order, bottom first, without moving anything
    /// else (ADR 0042).
    ///
    /// A stack's upper pull request can only merge after the ones below it (merging it first
    /// would take them along, unreviewed by the series), so position outranks size — but only
    /// among members of one stack. Folding that into ``isMergedEarlier(_:_:)`` would not be an
    /// order at all: "same stack → position, otherwise size" is not transitive (bottom < top by
    /// position, top < X < bottom by size), and a sort with such a comparator is undefined. So
    /// the size order is computed first, and each stack's members are then written back into the
    /// slots they landed in, in position order. An unrelated pull request keeps its slot, even
    /// between two members of a stack.
    /// - Parameter sorted: The candidates in the default order, all of one repository.
    /// - Returns: The same pull requests, each stack reordered within its own slots.
    static func stacksBottomFirst(_ sorted: [PullRequestSummary]) -> [PullRequestSummary] {
        var slotsByStack: [Int: [Int]] = [:]
        for (index, pullRequest) in sorted.enumerated() {
            if let stack = pullRequest.stack { slotsByStack[stack.number, default: []].append(index) }
        }
        var result = sorted
        for slots in slotsByStack.values where slots.count > 1 {
            let members = slots.map { sorted[$0] }.sorted { lhs, rhs in
                let left = lhs.stack?.position ?? 0
                let right = rhs.stack?.position ?? 0
                // Two members claiming one position (a sweep caught mid-restack) keep their size
                // order, so the result is still total.
                return left != right ? left < right : isMergedEarlier(lhs, rhs)
            }
            for (slot, member) in zip(slots, members) { result[slot] = member }
        }
        return result
    }

    /// The default merge order: fewest changed lines first, because a small pull request causes
    /// the fewest conflicts for the ones after it; then the oldest; then the lowest number, so
    /// the order is total.
    public static func isMergedEarlier(_ lhs: PullRequestSummary, _ rhs: PullRequestSummary) -> Bool {
        if lhs.churn != rhs.churn { return lhs.churn < rhs.churn }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.number < rhs.number
    }

    /// The first reason that applies, in a fixed order. A merge already on its way goes first,
    /// because it is the one fact that makes every other reason moot; the rest follow
    /// ``BulkTriagePlan``'s order.
    private static func exclusionReason(
        for pullRequest: PullRequestSummary,
        mergesOnTheirWay: Set<String>
    ) -> MergeSeriesExclusionReason? {
        if mergesOnTheirWay.contains(pullRequest.id) { return .mergeOnItsWay }
        if pullRequest.mergeBlocker == .draft { return .draft }
        if pullRequest.mergeBlocker == .conflicting { return .conflicting }
        if pullRequest.checkRollup?.state == .failure { return .checksFailing }
        if pullRequest.reviewDecision == .changesRequested { return .changesRequested }
        if pullRequest.verdictBlocker == .ownPullRequest { return .ownPullRequest }
        return nil
    }
}
