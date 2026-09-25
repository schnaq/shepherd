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

    /// The prefix of the *closed* search, which is the only read in Shepherd that looks past the
    /// open inbox (ADR 0027).
    ///
    /// It is the open prefix with one word changed, and that is deliberate: the track-record
    /// backfill is the same `search(type: ISSUE)` machinery the sweep uses, on the same host,
    /// through the same client, so it inherits the paging, the retry, the rate-limit backoff and
    /// the conditional-request cache rather than growing a second read path.
    public static let closedPullRequestPrefix = "is:pr is:closed archived:false"

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
    ///
    /// It marks its hits like every other facet does. That looks redundant — "involved" is what
    /// the whole inbox used to mean — and it stopped being redundant the moment a row could
    /// arrive without the user being involved at all: a watched repository's pull request
    /// (``watching(_:)``) has no relation to them, and an empty relation set would be the only
    /// thing distinguishing it from a pull request they commented on three years ago.
    public static let involves = InboxQuery(
        rawQuery: "\(openPullRequestPrefix) involves:@me",
        impliedRelations: [.involved]
    )

    /// Every open pull request in one repository, whether or not the user has anything to do
    /// with it (ADR 0005's 2026-09-16 amendment).
    ///
    /// The five default facets are all `@me` searches, which is the right default — an inbox is
    /// what is waiting for *you*. It leaves no way to follow a repository you are responsible for
    /// but not named on, which is the normal shape of a small team's own repositories: work
    /// happens, nobody asks you, and you find out when it is merged.
    ///
    /// One search per repository rather than `org:` for the whole organisation, because the cost
    /// is then proportional to what the user asked for: a handful of repositories is a handful of
    /// searches on top of five, where an organisation-wide sweep on a busy org is five pages of
    /// pull requests nobody wanted in their inbox. The Settings card caps the list for the same
    /// reason.
    /// - Parameter repo: The repository to watch.
    /// - Returns: The facet query.
    public static func watching(_ repo: RepoRef) -> InboxQuery {
        InboxQuery(
            rawQuery: "\(openPullRequestPrefix) repo:\(repo.fullName)",
            impliedRelations: [.watched]
        )
    }

    /// The watched-repository facets for a whole list, in order.
    /// - Parameter repos: The repositories to watch.
    /// - Returns: One query per repository.
    public static func watching(_ repos: [RepoRef]) -> [InboxQuery] {
        repos.map { watching($0) }
    }

    /// The default sweep: four relation-bearing facets plus the catch-all.
    ///
    /// Five search calls per cycle sit at a few percent of the search budget even at a
    /// two-minute cadence (see `docs/research/research-github-stack.md`).
    public static let defaultSweep: [InboxQuery] = [
        .reviewRequested, .authored, .assigned, .mentioned, .involves,
    ]

    /// The closed-pull-request query for one repository since one date (ADR 0027).
    ///
    /// `closed:>YYYY-MM-DD` rather than a timestamp: GitHub's search index resolves the qualifier
    /// to whole days anyway, and a date is what the ninety-day window means to the person who
    /// pressed the button. The extra hours a `>` on the boundary day lets in are counted and then
    /// filtered out by ``ShepherdCore/TrackRecord/compute(outcomes:subject:repo:since:)``, whose
    /// `since` is exact.
    /// - Parameters:
    ///   - repo: The repository to read.
    ///   - since: The oldest close date to include.
    ///   - calendar: The calendar the date is formatted in. UTC by default, because GitHub's
    ///     search qualifier is interpreted in UTC unless an offset is given.
    /// - Returns: The search expression.
    public static func closedPullRequests(
        in repo: RepoRef,
        since: Date,
        calendar: Calendar = InboxQuery.utcCalendar
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: since)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let stamp = String(format: "%04d-%02d-%02d", year, month, day)
        return "\(closedPullRequestPrefix) repo:\(repo.fullName) closed:>\(stamp)"
    }

    /// The calendar the closed-search date is formatted in: Gregorian, UTC.
    ///
    /// Built here rather than taken from `Calendar.current` so the query a Mac in Berlin sends is
    /// byte-identical to the one a Mac in Auckland sends, which is also what makes the
    /// conditional-request cache key stable.
    public static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    /// Returns the query narrowed to a single organisation, for very large accounts.
    /// - Parameter organization: The organisation login.
    public func scoped(toOrganization organization: String) -> InboxQuery {
        InboxQuery(
            rawQuery: "\(rawQuery) org:\(organization)",
            impliedRelations: impliedRelations
        )
    }
}

/// One facet query of the issues sweep (ADR 0032).
///
/// ``InboxQuery``'s twin, one word changed — `is:issue` in place of `is:pr` — for the reason
/// ADR 0027 gives for the closed-pull-request search: `search(query:, type: ISSUE)` already
/// returns both kinds of node, so a second facet type on the same connection inherits the
/// paging, the retry, the `Retry-After` backoff, the rate-limit snapshot and the request log
/// rather than growing a second read path. Like ``InboxQuery`` it also *tells us why* an issue is
/// in the inbox, which is where ``IssueRelation`` comes from.
public struct IssueQuery: Sendable, Hashable {
    /// The GitHub search expression, e.g. `"is:issue is:open assignee:@me"`.
    public var rawQuery: String
    /// What a hit on this query says about the user's relation to the issue.
    public var impliedRelations: Set<IssueRelation>

    /// Creates a facet query.
    /// - Parameters:
    ///   - rawQuery: The GitHub search expression.
    ///   - impliedRelations: Relations every hit of this query has.
    public init(rawQuery: String, impliedRelations: Set<IssueRelation> = []) {
        self.rawQuery = rawQuery
        self.impliedRelations = impliedRelations
    }

    /// The common prefix every issue facet shares.
    public static let openIssuePrefix = "is:issue is:open archived:false"

    /// Issues assigned to the user.
    public static let assigned = IssueQuery(
        rawQuery: "\(openIssuePrefix) assignee:@me",
        impliedRelations: [.assigned]
    )
    /// Issues the user opened.
    public static let authored = IssueQuery(
        rawQuery: "\(openIssuePrefix) author:@me",
        impliedRelations: [.authored]
    )
    /// Issues that mention the user.
    public static let mentioned = IssueQuery(
        rawQuery: "\(openIssuePrefix) mentions:@me",
        impliedRelations: [.mentioned]
    )

    /// The default sweep: exactly the three relation-bearing facets, in rail order.
    ///
    /// No `involves:@me` catch-all, unlike ``InboxQuery/defaultSweep``. The pull-request inbox
    /// has one because a review request can reach a user through a team without any of the four
    /// narrow facets matching; an issue reaches somebody by being assigned to them, opened by
    /// them or mentioning them, and a fourth search that returns the union of the three would
    /// cost a search call per cycle for rows the sweep already has.
    public static let defaultSweep: [IssueQuery] = [.assigned, .authored, .mentioned]

    /// Returns the query narrowed to a single organisation, for very large accounts.
    /// - Parameter organization: The organisation login.
    public func scoped(toOrganization organization: String) -> IssueQuery {
        IssueQuery(
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
            mergeStateStatus
            reviewDecision
            repository { name owner { login } }
            author { __typename login avatarUrl }
            labels(first: 20) { nodes { name } }
            commits(last: 1) {
              nodes {
                commit {
                  oid
                  messageBody
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

    /// The issues sweep (ADR 0032): the same `search(type: ISSUE)` connection the inbox sweep
    /// pages, with `... on Issue` in place of `... on PullRequest`.
    ///
    /// `closedByPullRequestsReferences` is the "Development panel" equivalent on `Issue` — the
    /// field that answers *which pull requests will close this* — and it is selected **inside the
    /// sweep** rather than fetched per issue, for the reason `statusCheckRollup` sits inside the
    /// pull-request sweep's `commits` selection: it is one more nested selection on a connection
    /// that is being paged anyway. `includeClosedPrs: true` is deliberate: an issue whose fix was
    /// merged last week is exactly the row a reader wants to see the link on, and leaving it out
    /// would make the "has an agent pull request" facet forget every finished piece of work.
    ///
    /// Five is the cap because the row shows a count and the detail panel a short list; an issue
    /// with a sixth linked pull request is a conversation, not an inbox row.
    public static let searchIssues = """
    query ShepherdIssueSweep($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on Issue {
            id
            number
            title
            createdAt
            updatedAt
            closedAt
            closed
            stateReason
            repository { name owner { login } }
            author { __typename login avatarUrl }
            labels(first: 20) { nodes { name } }
            comments { totalCount }
            closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
              totalCount
              nodes {
                number
                title
                state
                repository { name owner { login } }
                author { __typename login avatarUrl }
              }
            }
          }
        }
      }
    }
    """

    /// One issue by repository and number — what a `shepherd://issue/…` link needs when the row
    /// is not in the local cache (ADR 0032, ADR 0013).
    ///
    /// The same `... on Issue` field set ``searchIssues`` selects, under
    /// `repository { issue(number:) }` instead of under the search connection, which is exactly
    /// how ``closedPullRequest`` relates to ``searchPullRequests``. It therefore decodes into the
    /// same DTO and goes through the same ``ResponseMapping/issueRowSummary(from:relations:detector:)``
    /// — a link cannot produce a row shaped differently from a swept one.
    ///
    /// It exists for the reason `openPullRequest`'s single fetch does: the sweep searches
    /// `assignee:`/`author:`/`mentions:@me`, so an issue somebody sends you in chat is routinely
    /// *not* in the inbox, and a sweep would be slow and still miss it. One GraphQL query on the
    /// host that is already on `CONTRIBUTING.md`'s list, made only when a link names an issue the
    /// cache does not have.
    public static let issueByNumber = """
    query ShepherdIssue($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          __typename
          id
          number
          title
          createdAt
          updatedAt
          closedAt
          closed
          stateReason
          repository { name owner { login } }
          author { __typename login avatarUrl }
          labels(first: 20) { nodes { name } }
          comments { totalCount }
          closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
            totalCount
            nodes {
              number
              title
              state
              repository { name owner { login } }
              author { __typename login avatarUrl }
            }
          }
        }
      }
    }
    """

    /// The same sweep, reading the links out of the issue's timeline instead — the documented
    /// fallback, and **not** what the client sends (ADR 0032).
    ///
    /// `Issue.closedByPullRequestsReferences` is part of GitHub's public schema and needs no
    /// preview header, so ``searchIssues`` is the primary read. This document and
    /// ``ResponseMapping/issueRowSummary(fromTimelineOf:relations:detector:)`` exist so that a
    /// schema regression is a one-line switch rather than a rewrite: `CROSS_REFERENCED_EVENT` and
    /// `CONNECTED_EVENT` have been on `IssueTimelineItems` for years, and between them they carry
    /// the same two facts the panel needs — a pull request that references the issue, and one
    /// that was linked to it by hand.
    ///
    /// It is more verbose and slightly less precise (a cross-reference is *any* mention, so
    /// `willCloseTarget` is what separates "will fix this" from "mentioned this"), which is why
    /// it is the fallback and not the default. Both shapes are fixture-tested, so whichever way
    /// the live schema goes there is already a regression test for it.
    public static let searchIssuesWithTimelineLinks = """
    query ShepherdIssueSweepTimeline($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on Issue {
            id
            number
            title
            createdAt
            updatedAt
            closedAt
            closed
            stateReason
            repository { name owner { login } }
            author { __typename login avatarUrl }
            labels(first: 20) { nodes { name } }
            comments { totalCount }
            timelineItems(
              itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT]
              first: 20
            ) {
              nodes {
                __typename
                ... on CrossReferencedEvent {
                  willCloseTarget
                  source {
                    __typename
                    ... on PullRequest {
                      number
                      title
                      state
                      repository { name owner { login } }
                      author { __typename login avatarUrl }
                    }
                  }
                }
                ... on ConnectedEvent {
                  subject {
                    __typename
                    ... on PullRequest {
                      number
                      title
                      state
                      repository { name owner { login } }
                      author { __typename login avatarUrl }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// The closed-pull-request read behind the track record (ADR 0027).
    ///
    /// One page of the same `search(type: ISSUE)` connection the inbox sweep uses, selecting the
    /// handful of extra fields a *closed* pull request has and the sweep therefore does not ask
    /// for: `closedAt`, `merged`, the merge commit, the number of change-requesting reviews, and
    /// the check rollup of the **first** commit rather than the last.
    ///
    /// `commits(first: 1)` is the one selection worth explaining. The sweep asks for
    /// `commits(last: 1)` because it wants the head; this asks for the first because
    /// "did the agent's first push go green" is the question, and it is a question about the
    /// commit the branch started on. `reviews(states: CHANGES_REQUESTED)` is selected for its
    /// `totalCount` only — the reviews themselves are nobody's business here.
    ///
    /// Everything needed for one stored outcome is in this single request: no detail fetch, no
    /// per-pull-request round trip, and no second host.
    public static let searchClosedPullRequests = """
    query ShepherdClosedPullRequests($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            id
            number
            title
            body
            createdAt
            closedAt
            merged
            mergeCommit { oid }
            additions
            deletions
            changedFiles
            headRefName
            repository { name owner { login } }
            author { __typename login avatarUrl }
            reviews(states: CHANGES_REQUESTED) { totalCount }
            commits(first: 1) {
              nodes {
                commit {
                  oid
                  statusCheckRollup {
                    state
                    contexts(first: 1) { totalCount }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// The same fields for **one** pull request, read by number.
    ///
    /// What the sweep uses when an open pull request disappears from the inbox: one request, one
    /// pull request, and the same shape the backfill's pages carry so both writers produce
    /// identical rows (ADR 0027).
    public static let closedPullRequest = """
    query ShepherdClosedPullRequest($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          id
          number
          title
          body
          createdAt
          closedAt
          merged
          mergeCommit { oid }
          additions
          deletions
          changedFiles
          headRefName
          repository { name owner { login } }
          author { __typename login avatarUrl }
          reviews(states: CHANGES_REQUESTED) { totalCount }
          commits(first: 1) {
            nodes {
              commit {
                oid
                statusCheckRollup {
                  state
                  contexts(first: 1) { totalCount }
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

    /// The issues one pull request will close — the other direction of ADR 0032's link.
    ///
    /// `closingIssuesReferences` is the pull-request side of the *Development panel*: the issues
    /// GitHub itself resolved out of the description's `closes #123` / `fixes #123` keywords. It
    /// is a long-stable, documented field that needs no preview header — unlike its issue-side
    /// counterpart, which is why that one keeps a fallback mapper and this one does not.
    ///
    /// Read **beside** ``reviewThreads`` on the same detail fetch rather than as a screen of its
    /// own, for the reason `closedByPullRequestsReferences` sits inside the issues sweep: the
    /// round trip is already being made, and the answer is four scalars per issue.
    ///
    /// Ten is the cap because the section lists every issue it gets and a description that names
    /// an eleventh is a release note, not a link. `totalCount` is selected so a future "and three
    /// more" line needs no second document; nothing reads it yet.
    public static let pullRequestClosingIssues = """
    query ShepherdPullRequestClosingIssues($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          closingIssuesReferences(first: 10) {
            totalCount
            nodes {
              number
              title
              state
              repository { name owner { login } }
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

    /// The cheapest possible staleness probe for an issue: its current `updatedAt` (ADR 0032's
    /// Sprint 4a amendment).
    ///
    /// ``pullRequestHead``'s shape with the other node in it, and deliberately so: an issue has
    /// no head commit, so the field a queued triage write has to be re-validated against is the
    /// timestamp every issue write moves. `closed` comes along because it costs nothing on a
    /// query that is being made anyway and it is what tells a reopen that has already happened
    /// from one that has not.
    ///
    /// Three fields, one node, no connection — the same reasoning that makes the head probe
    /// cheap enough to run before every review submission.
    public static let issueState = """
    query ShepherdIssueState($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) { id updatedAt closed }
      }
    }
    """

    /// The three facts a queued branch deletion is decided on (ADR 0005's 2026-09-05 amendment).
    ///
    /// ``pullRequestHead``'s shape and ``pullRequestHead``'s reason: it is read at the moment the
    /// drain is about to delete something, because a deletion cannot be undone and the cached
    /// inbox row was written by a sweep that may be two minutes old. `headRepository` is what
    /// tells a fork's branch from ours, and `defaultBranchRef` is the one branch a merge may
    /// never tidy away.
    ///
    /// Four fields on two nodes of a repository Shepherd is already talking to — no new host, and
    /// only asked at all when the merge row says the user ticked the box.
    public static let headBranchContext = """
    query ShepherdHeadBranchContext($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        pullRequest(number: $number) {
          headRefName
          headRepository { nameWithOwner }
        }
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
