import Foundation
import ShepherdCore

/// One page of a repository's closed pull requests (ADR 0027).
///
/// The shape ``GitHubClient/searchClosedPullRequests(repo:since:cursor:pageSize:)`` answers with,
/// and the reason the backfill's pager can live outside GitHubKit: everything the pager needs to
/// decide whether to ask for another page, and to tell the user how far along it is, is in this
/// value.
///
/// `totalCount` is GitHub's `issueCount` for the *whole* query rather than for this page, which is
/// what makes a progress line possible at all — and it is an estimate: the search index is
/// eventually consistent, so the number can move between pages. The progress line says "of about
/// 340" for that reason, and it is never used as a loop bound.
public struct ClosedPullRequestPage: Sendable, Equatable {
    /// The closed pull requests on this page, in the order GitHub returned them.
    public var pullRequests: [ClosedPullRequest]
    /// GitHub's estimate of how many the whole query matches.
    public var totalCount: Int
    /// Whether another page exists.
    public var hasNextPage: Bool
    /// The cursor to pass as `cursor` for the next page, when there is one.
    public var endCursor: String?

    /// Creates a page.
    /// - Parameters:
    ///   - pullRequests: The page's pull requests.
    ///   - totalCount: GitHub's estimate of the total.
    ///   - hasNextPage: Whether another page exists.
    ///   - endCursor: The next page's cursor.
    public init(
        pullRequests: [ClosedPullRequest],
        totalCount: Int,
        hasNextPage: Bool = false,
        endCursor: String? = nil
    ) {
        self.pullRequests = pullRequests
        self.totalCount = totalCount
        self.hasNextPage = hasNextPage
        self.endCursor = endCursor
    }
}
