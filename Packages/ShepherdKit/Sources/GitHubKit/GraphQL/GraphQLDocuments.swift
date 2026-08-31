import Foundation
import ShepherdCore

/// One facet query of the inbox sweep.
///
/// ADR 0005: the inbox is filled by a handful of GraphQL `search` calls per cycle rather than
/// by listing pull requests per repository. Each facet also *tells us why* a pull request is
/// in the inbox, which is where ``Relation`` comes from — no extra round trip needed.
public struct InboxQuery: Sendable, Hashable {
    /// The GitHub search expression, e.g. `"is:pr is:open review-requested:@me"`.
    public var rawQuery: String
    /// What a hit on this query says about the user's relation to the pull request.
    public var impliedRelations: Set<Relation>

    /// Creates a facet query.
    /// - Parameters:
    ///   - rawQuery: The GitHub search expression.
    ///   - impliedRelations: Relations every hit of this query has.
    public init(rawQuery: String, impliedRelations: Set<Relation> = []) {
        self.rawQuery = rawQuery
        self.impliedRelations = impliedRelations
    }

    /// The common prefix every inbox facet shares.
    public static let openPullRequestPrefix = "is:pr is:open archived:false"

    /// Pull requests whose review was explicitly requested from the user.
    public static let reviewRequested = InboxQuery(
        rawQuery: "\(openPullRequestPrefix) review-requested:@me",
        impliedRelations: [.reviewRequested]
    )
    /// Pull requests the user opened.
    public static let authored = InboxQuery(
        rawQuery: "\(openPullRequestPrefix) author:@me",
        impliedRelations: [.author]
    )
    /// Pull requests assigned to the user.
    public static let assigned = InboxQuery(
        rawQuery: "\(openPullRequestPrefix) assignee:@me",
        impliedRelations: [.assigned]
    )
    /// Pull requests that mention the user.
    public static let mentioned = InboxQuery(
        rawQuery: "\(openPullRequestPrefix) mentions:@me",
        impliedRelations: [.mentioned]
    )
    /// The catch-all facet: anything the user is involved in.
    public static let involves = InboxQuery(
        rawQuery: "\(openPullRequestPrefix) involves:@me",
        impliedRelations: []
    )

    /// The default sweep: four relation-bearing facets plus the catch-all.
    ///
    /// Five search calls per cycle sit at a few percent of the search budget even at a
    /// two-minute cadence (see `docs/research/research-github-stack.md`).
    public static let defaultSweep: [InboxQuery] = [
        .reviewRequested, .authored, .assigned, .mentioned, .involves,
    ]

    /// Returns the query narrowed to a single organisation, for very large accounts.
    /// - Parameter organization: The organisation login.
    public func scoped(toOrganization organization: String) -> InboxQuery {
        InboxQuery(
            rawQuery: "\(rawQuery) org:\(organization)",
            impliedRelations: impliedRelations
        )
    }
}

/// The GraphQL documents Shepherd sends.
///
/// They are plain strings on purpose: no code generation, no schema download, nothing that
/// has to be regenerated in CI. Every field selected here maps onto a field of a
/// `ShepherdCore` model — if you add one, add it to the model and the mapper too.
public enum GraphQLDocuments {
    /// The inbox sweep (ADR 0005). Selects exactly the list-view fields, including the cheap
    /// `statusCheckRollup.state` scalar that REST search cannot provide.
    public static let searchPullRequests = """
    query ShepherdInboxSweep($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            id
            number
            title
            createdAt
            updatedAt
            isDraft
            additions
            deletions
            changedFiles
            headRefName
            headRefOid
            baseRefName
            mergeable
            reviewDecision
            repository { name owner { login } }
            author { __typename login avatarUrl }
            labels(first: 20) { nodes { name } }
            commits(last: 1) {
              nodes {
                commit {
                  oid
                  statusCheckRollup {
                    state
                    contexts(first: 100) { totalCount }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// Review threads with their node ids — the only way to get the ids that
    /// `resolveReviewThread` needs (ADR 0005).
    public static let reviewThreads = """
    query ShepherdReviewThreads(
      $owner: String!, $name: String!, $number: Int!, $first: Int!, $after: String
    ) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              originalLine
              diffSide
              comments(first: 100) {
                nodes {
                  id
                  databaseId
                  body
                  createdAt
                  author { __typename login avatarUrl }
                }
              }
            }
          }
        }
      }
    }
    """

    /// The cheapest possible staleness probe: the current head SHA of one pull request.
    /// Used before submitting a review draft (ADR 0006's conflict rule).
    public static let pullRequestHead = """
    query ShepherdPullRequestHead($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { id headRefOid updatedAt }
      }
    }
    """

    /// Resolve a review thread. GraphQL-only — REST has no equivalent.
    public static let resolveReviewThread = """
    mutation ShepherdResolveThread($threadId: ID!) {
      resolveReviewThread(input: { threadId: $threadId }) {
        thread { id isResolved }
      }
    }
    """

    /// Unresolve a review thread. GraphQL-only.
    public static let unresolveReviewThread = """
    mutation ShepherdUnresolveThread($threadId: ID!) {
      unresolveReviewThread(input: { threadId: $threadId }) {
        thread { id isResolved }
      }
    }
    """

    /// Take a pull request out of draft state. GraphQL-only.
    public static let markPullRequestReadyForReview = """
    mutation ShepherdMarkReady($pullRequestId: ID!) {
      markPullRequestReadyForReview(input: { pullRequestId: $pullRequestId }) {
        pullRequest { id isDraft }
      }
    }
    """
}
