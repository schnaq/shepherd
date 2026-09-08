import Foundation

/// What a bulk-triage run is supposed to do to every pull request the user selected.
public enum BulkTriageAction: String, Sendable, Codable, Hashable, CaseIterable {
    /// Record an approving review, nothing else.
    case approve
    /// Record an approving review and queue the merge behind it.
    case approveAndMerge
    /// Merge pull requests that already carry an approval.
    case merge

    /// Whether the action records a review.
    public var includesApproval: Bool {
        switch self {
        case .approve, .approveAndMerge: return true
        case .merge: return false
        }
    }

    /// Whether the action merges.
    public var includesMerge: Bool {
        switch self {
        case .approveAndMerge, .merge: return true
        case .approve: return false
        }
    }
}

/// One write a plan will enqueue for one pull request.
///
/// The order matters and is the order of this array: an approval that a branch-protection rule
/// requires has to reach GitHub before the merge that depends on it.
public enum BulkTriageStep: String, Sendable, Codable, Hashable, CaseIterable {
    /// Submit an approving review with no summary body.
    case approve
    /// Merge the pull request.
    case merge
}

/// Why a pull request the user selected is left out of the run.
///
/// A skipped pull request is *shown* as skipped with its reason rather than silently dropped
/// (ADR 0015): the user selected it, so they are owed an explanation.
public enum BulkTriageSkipReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// The pull request is still a draft.
    case draft
    /// GitHub reports conflicts with the base branch.
    case conflicting
    /// At least one check on the head commit failed.
    case checksFailing
    /// Checks are still running, so "green" is not known yet.
    case checksRunning
    /// A reviewer asked for changes.
    case changesRequested
    /// GitHub refuses an approval on a pull request you opened yourself.
    case ownPullRequest
    /// Already approved, so an approve-only run has nothing to write.
    case alreadyApproved
    /// Not approved, so a merge-only run has no business merging it.
    case notApproved
}

/// Something worth saying about a pull request that *is* going ahead.
public enum BulkTriageCaveat: String, Sendable, Codable, Hashable, CaseIterable {
    /// The head commit has no checks at all, so there is no green to rely on.
    case noChecksConfigured
    /// GitHub has not finished computing mergeability; the merge may still be refused.
    case mergeabilityUnknown
    /// A local draft carries inline comments anchored to an older commit, so the approval queued
    /// for this pull request will be parked as a conflict instead of sent.
    case staleDraftComments
}

/// One outbox write a plan amounts to, plus the draft that has to be on disk beside it.
///
/// Keeping the two together is what lets the app enqueue a bulk run through exactly the same
/// path as a single approval: the draft is saved so it survives a crash, and the row carries a
/// copy of it so the drain has everything it needs (ADR 0006).
public struct BulkTriageWrite: Sendable, Equatable {
    /// The row to enqueue.
    public let item: OutboxItem
    /// The draft to persist first — non-`nil` exactly when ``item`` submits a review.
    public let draft: ReviewDraft?

    /// Creates a write.
    /// - Parameters:
    ///   - item: The outbox row.
    ///   - draft: The draft to save alongside it, if any.
    public init(item: OutboxItem, draft: ReviewDraft? = nil) {
        self.item = item
        self.draft = draft
    }
}

/// The partition a bulk-triage action produces over a set of selected pull requests.
///
/// A pure value, deliberately: the whole product risk of bulk triage sits in "which pull
/// requests does this actually touch", so that question is answered by a testable function
/// rather than by a view (ADR 0015). Nothing here talks to GitHub or to the database — it turns
/// inbox rows into a list of intended writes, and the app enqueues them through the existing
/// outbox.
public struct BulkTriagePlan: Sendable, Equatable {
    /// One selected pull request and what the run will do with it.
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The selected pull request, as the inbox knows it.
        public let pullRequest: PullRequestSummary
        /// The writes to enqueue, in send order. Empty for a skipped entry.
        public let steps: [BulkTriageStep]
        /// Why this entry is skipped, or `nil` when it goes ahead.
        public let skipReason: BulkTriageSkipReason?
        /// Notes for an entry that goes ahead anyway.
        public let caveats: [BulkTriageCaveat]

        /// How far apart two consecutive writes are timestamped.
        ///
        /// The drain sends rows in `createdAt` order, so the approval must carry a strictly
        /// earlier timestamp than the merge queued behind it. One millisecond is invisible to
        /// the user and unambiguous to `ORDER BY`.
        fileprivate static let stepSpacing: TimeInterval = 0.001

        /// Creates an entry.
        /// - Parameters:
        ///   - pullRequest: The selected pull request.
        ///   - steps: The writes to enqueue.
        ///   - skipReason: Why it is skipped, if it is.
        ///   - caveats: Notes about an entry that goes ahead.
        public init(
            pullRequest: PullRequestSummary,
            steps: [BulkTriageStep],
            skipReason: BulkTriageSkipReason? = nil,
            caveats: [BulkTriageCaveat] = []
        ) {
            self.pullRequest = pullRequest
            self.steps = steps
            self.skipReason = skipReason
            self.caveats = caveats
        }

        /// `Entry` is identified by its pull request.
        public var id: String { pullRequest.id }

        /// Whether this entry contributes any write.
        public var isEligible: Bool { skipReason == nil && !steps.isEmpty }

        /// The writes this entry amounts to, in send order.
        /// - Parameters:
        ///   - mergeMethod: The merge method as GitHub's raw value (`"merge"`, `"squash"`,
        ///     `"rebase"`).
        ///   - existingDraft: The draft already on disk for this pull request, so a queued
        ///     approval never throws away inline comments the user wrote earlier. A draft with
        ///     no comments is re-anchored to this pull request's head; one with comments keeps
        ///     its anchor and is flagged by ``BulkTriageCaveat/staleDraftComments``.
        ///   - now: The timestamp of the first write.
        /// - Returns: The writes, or an empty array for a skipped entry.
        public func writes(
            mergeMethod: String,
            existingDraft: ReviewDraft? = nil,
            now: Date = Date()
        ) -> [BulkTriageWrite] {
            var result: [BulkTriageWrite] = []
            for (offset, step) in steps.enumerated() {
                let createdAt = now.addingTimeInterval(Double(offset) * Entry.stepSpacing)
                switch step {
                case .approve:
                    let draft = ReviewDraft.verdict(
                        .approve,
                        on: pullRequest,
                        existing: existingDraft,
                        at: createdAt
                    )
                    result.append(
                        BulkTriageWrite(
                            item: item(action: .submitReview(draft), createdAt: createdAt),
                            draft: draft
                        )
                    )
                case .merge:
                    result.append(
                        BulkTriageWrite(
                            item: item(
                                // `deletesHeadBranch` stays at its default of `false`: the bulk
                                // dialog has no such box, and forty branches deleted behind one
                                // confirmation is not something to infer from a tick that meant
                                // "merge these" (ADR 0005's 2026-09-05 amendment).
                                action: .merge(
                                    method: mergeMethod,
                                    // The head the user saw, so the drain's merge preflight can
                                    // refuse a pull request that moved on (ADR 0006).
                                    expectedHeadOid: pullRequest.headRefOid
                                ),
                                createdAt: createdAt
                            )
                        )
                    )
                }
            }
            return result
        }

        private func item(action: OutboxAction, createdAt: Date) -> OutboxItem {
            OutboxItem(
                prID: pullRequest.id,
                repo: pullRequest.repo,
                number: pullRequest.number,
                action: action,
                createdAt: createdAt
            )
        }
    }

    /// The action the plan was built for.
    public let action: BulkTriageAction
    /// Every selected pull request, in the order the caller passed them (the display order).
    public let entries: [Entry]

    /// Creates a plan.
    /// - Parameters:
    ///   - action: The action.
    ///   - entries: The partitioned entries.
    public init(action: BulkTriageAction, entries: [Entry]) {
        self.action = action
        self.entries = entries
    }

    /// Partitions a selection into what the action will do and what it will not.
    /// - Parameters:
    ///   - action: What the user asked for.
    ///   - pullRequests: The selected rows, in display order.
    ///   - existingDrafts: Drafts already on disk, keyed by pull-request id. Only used for the
    ///     ``BulkTriageCaveat/staleDraftComments`` note, so passing none simply omits it.
    /// - Returns: The plan.
    public static func make(
        action: BulkTriageAction,
        pullRequests: [PullRequestSummary],
        existingDrafts: [String: ReviewDraft] = [:]
    ) -> BulkTriagePlan {
        BulkTriagePlan(
            action: action,
            entries: pullRequests.map {
                entry(for: $0, action: action, existingDraft: existingDrafts[$0.id])
            }
        )
    }

    /// The entries that will be queued.
    public var eligible: [Entry] { entries.filter(\.isEligible) }

    /// The entries that will not be, with their reasons.
    public var skipped: [Entry] { entries.filter { !$0.isEligible } }

    /// Whether there is anything to confirm.
    public var isActionable: Bool { !eligible.isEmpty }

    /// Every write this plan amounts to, in the order they must reach GitHub.
    /// - Parameters:
    ///   - mergeMethod: The merge method as GitHub's raw value.
    ///   - existingDrafts: Drafts already on disk, keyed by pull-request id.
    ///   - now: The timestamp of the first write.
    /// - Returns: The writes for every eligible entry, concatenated in entry order.
    public func writes(
        mergeMethod: String,
        existingDrafts: [String: ReviewDraft] = [:],
        now: Date = Date()
    ) -> [BulkTriageWrite] {
        var result: [BulkTriageWrite] = []
        for entry in eligible {
            result.append(
                contentsOf: entry.writes(
                    mergeMethod: mergeMethod,
                    existingDraft: existingDrafts[entry.id],
                    now: now.addingTimeInterval(Double(result.count) * Entry.stepSpacing)
                )
            )
        }
        return result
    }

    // MARK: - Preselection

    /// Whether a pull request is "green" in the sense the preselect uses: checks passed, no
    /// conflicts, nobody asking for changes, not a draft.
    ///
    /// Deliberately stricter than ``make(action:pullRequests:)``: a pull request with *no*
    /// checks configured is not green (there is nothing to be green about) and is therefore not
    /// preselected, but the plan will still act on it if the user picks it by hand — with a
    /// ``BulkTriageCaveat/noChecksConfigured`` note. Convenience is conservative; an explicit
    /// choice is never overruled.
    /// - Parameter pullRequest: The row to test.
    /// - Returns: `true` when the row is green.
    public static func isGreen(_ pullRequest: PullRequestSummary) -> Bool {
        guard !pullRequest.isDraft else { return false }
        guard pullRequest.checkRollup?.state == .success else { return false }
        guard pullRequest.mergeable == .mergeable else { return false }
        return pullRequest.reviewDecision != .changesRequested
    }

    /// The green, agent-authored pull requests of a list, in the order given.
    ///
    /// This is the "select all green agent PRs in this view" convenience: bulk triage exists for
    /// the agent-PR flood (ADR 0008, ADR 0015), and a human's pull request is never swept into a
    /// bulk action by a single click.
    /// - Parameter pullRequests: The rows currently on screen.
    /// - Returns: The subset to preselect.
    public static func greenAgentPullRequests(
        in pullRequests: [PullRequestSummary]
    ) -> [PullRequestSummary] {
        pullRequests.filter { isGreen($0) && $0.author.kind.agentIdentity != nil }
    }

    // MARK: - Partitioning

    private static func entry(
        for pullRequest: PullRequestSummary,
        action: BulkTriageAction,
        existingDraft: ReviewDraft? = nil
    ) -> Entry {
        var steps: [BulkTriageStep] = []
        // An approval GitHub already reports is not worth a second write; "approve & merge"
        // therefore degrades to a merge instead of skipping the pull request.
        if action.includesApproval, pullRequest.reviewDecision != .approved {
            steps.append(.approve)
        }
        if action.includesMerge {
            steps.append(.merge)
        }

        if let reason = skipReason(for: pullRequest, action: action, steps: steps) {
            return Entry(pullRequest: pullRequest, steps: [], skipReason: reason)
        }
        return Entry(
            pullRequest: pullRequest,
            steps: steps,
            caveats: caveats(for: pullRequest, steps: steps, existingDraft: existingDraft)
        )
    }

    /// The first precondition the pull request fails, in a fixed order so the reason a user is
    /// shown never depends on evaluation order.
    private static func skipReason(
        for pullRequest: PullRequestSummary,
        action: BulkTriageAction,
        steps: [BulkTriageStep]
    ) -> BulkTriageSkipReason? {
        if pullRequest.mergeBlocker == .draft { return .draft }
        if pullRequest.mergeBlocker == .conflicting { return .conflicting }
        if pullRequest.checkRollup?.state == .failure { return .checksFailing }
        if pullRequest.checkRollup?.state == .pending { return .checksRunning }
        if pullRequest.reviewDecision == .changesRequested { return .changesRequested }
        // GitHub answers 422 to an approval of your own pull request. Merging your own is fine,
        // which is why this is tied to the step rather than to the action.
        if steps.contains(.approve), pullRequest.verdictBlocker == .ownPullRequest {
            return .ownPullRequest
        }
        if action == .merge, pullRequest.reviewDecision != .approved { return .notApproved }
        // Approve-only on something already approved: nothing left to write.
        if action == .approve, steps.isEmpty { return .alreadyApproved }
        return nil
    }

    private static func caveats(
        for pullRequest: PullRequestSummary,
        steps: [BulkTriageStep],
        existingDraft: ReviewDraft?
    ) -> [BulkTriageCaveat] {
        var result: [BulkTriageCaveat] = []
        let rollup = pullRequest.checkRollup
        if rollup == nil || rollup?.state == CheckRollup.State.none {
            result.append(.noChecksConfigured)
        }
        if steps.contains(.merge), pullRequest.mergeable != .mergeable {
            result.append(.mergeabilityUnknown)
        }
        // A comment-free draft is re-anchored to the current head when the verdict is recorded
        // (``ReviewDraft/verdict(_:on:existing:body:at:)``), so only a draft with comments can
        // still go out stale — and then the drain parks it. Saying so here is the difference
        // between the user knowing before the confirm and finding out from an alert afterwards.
        if steps.contains(.approve),
           let existingDraft,
           !existingDraft.comments.isEmpty,
           existingDraft.isStale(against: pullRequest.headRefOid) {
            result.append(.staleDraftComments)
        }
        return result
    }
}
