import Foundation

/// Why GitHub would refuse a review verdict or a merge on this pull request right now.
///
/// Three predicates the app used to re-derive at every button. That is how a merge on a draft
/// reached the outbox: the review header disabled its Merge button on conflicts only, so a draft
/// went through the funnel, sat in the queue, and came back as a failed write reading
/// "Pull Request is still a draft" — a refusal Shepherd knew about before it wrote the row.
///
/// Naming the refusals here makes the write funnel and every surface that mirrors it read the
/// *same* rule, and it is where ``BulkTriagePlan`` already partitioned on: the bulk dialog has
/// skipped drafts, conflicts and your own pull request since ADR 0015, and it now skips them by
/// asking these two properties rather than by repeating their conditions.
public enum ReviewActionBlocker: Equatable, Sendable {
    /// GitHub refuses the merge with "Pull Request is still a draft" until it is marked ready.
    case draft
    /// The head branch conflicts with its base, so there is nothing to merge yet.
    case conflicting
    /// GitHub answers 422 to an approval or a change request on your own pull request.
    case ownPullRequest
}

public extension PullRequestSummary {
    /// Why an approve or a request-changes would be refused, or `nil` when neither would be.
    ///
    /// A plain `COMMENT` review is *always* allowed, including on your own pull request, which is
    /// why this is the verdict's blocker rather than the review's: the composer degrades to a
    /// comment instead of going dark.
    var verdictBlocker: ReviewActionBlocker? {
        myRelation.contains(.author) ? .ownPullRequest : nil
    }

    /// Why a merge would be refused, or `nil` when nothing here would refuse it.
    ///
    /// Draft is checked before conflicts so the sentence a user reads never depends on
    /// evaluation order — the same fixed order ``BulkTriagePlan`` reports a skip in.
    /// ``Mergeable/unknown`` is deliberately not a blocker: GitHub has merely not finished
    /// computing mergeability, and refusing on it would grey out every pull request in the
    /// seconds after a push. The merge sheet warns about it instead.
    var mergeBlocker: ReviewActionBlocker? {
        if isDraft { return .draft }
        if mergeable == .conflicting { return .conflicting }
        return nil
    }
}
