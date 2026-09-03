import Foundation

/// The envelope every GraphQL response comes in.
struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    var data: Payload?
    var errors: [GraphQLErrorDTO]?
}

/// One entry of a GraphQL `errors` array.
struct GraphQLErrorDTO: Decodable {
    var message: String?
    var type: String?
}

/// A GraphQL `pageInfo` fragment.
struct PageInfoDTO: Decodable {
    var hasNextPage: Bool?
    var endCursor: String?
}

/// A GitHub `Actor` (`User`, `Bot`, `Organization`, `Mannequin`, …).
struct GraphQLActorDTO: Decodable {
    var typename: String?
    var login: String?
    var avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
        case avatarUrl
    }

    /// `true` when GitHub says this account is a bot — authoritative for provenance
    /// (ADR 0008).
    var isBot: Bool { typename == "Bot" }
}

/// A repository fragment: `repository { name owner { login } }`.
struct GraphQLRepositoryDTO: Decodable {
    struct Owner: Decodable {
        var login: String?
    }
    var name: String?
    var owner: Owner?
}

// MARK: - Inbox sweep

/// The `search` connection returned by ``GraphQLDocuments/searchPullRequests``.
struct SearchPullRequestsData: Decodable {
    struct Search: Decodable {
        var issueCount: Int?
        var pageInfo: PageInfoDTO?
        var nodes: [SearchNodeDTO?]?
    }
    var search: Search?
}

/// One node of the search connection.
///
/// Every field is optional: a `search(type: ISSUE)` connection may legitimately contain plain
/// issues, which carry only `__typename`.
struct SearchNodeDTO: Decodable {
    struct LabelConnection: Decodable {
        struct Label: Decodable { var name: String? }
        var nodes: [Label?]?
    }

    struct CommitConnection: Decodable {
        struct Node: Decodable {
            struct Commit: Decodable {
                var oid: String?
                var statusCheckRollup: StatusCheckRollupDTO?
            }
            var commit: Commit?
        }
        var nodes: [Node?]?
    }

    struct StatusCheckRollupDTO: Decodable {
        struct Contexts: Decodable { var totalCount: Int? }
        var state: String?
        var contexts: Contexts?
    }

    var typename: String?
    var id: String?
    var number: Int?
    var title: String?
    var createdAt: String?
    var updatedAt: String?
    var isDraft: Bool?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var headRefName: String?
    var headRefOid: String?
    var baseRefName: String?
    var mergeable: String?
    var reviewDecision: String?
    var repository: GraphQLRepositoryDTO?
    var author: GraphQLActorDTO?
    var labels: LabelConnection?
    var commits: CommitConnection?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case id, number, title, createdAt, updatedAt, isDraft, additions, deletions
        case changedFiles, headRefName, headRefOid, baseRefName, mergeable, reviewDecision
        case repository, author, labels, commits
    }
}

// MARK: - Review threads

/// The payload of ``GraphQLDocuments/reviewThreads``.
struct ReviewThreadsData: Decodable {
    struct Repository: Decodable {
        struct PullRequest: Decodable {
            struct ThreadConnection: Decodable {
                var pageInfo: PageInfoDTO?
                var nodes: [ReviewThreadDTO?]?
            }
            var reviewThreads: ThreadConnection?
        }
        var pullRequest: PullRequest?
    }
    var repository: Repository?
}

/// One review thread node.
struct ReviewThreadDTO: Decodable {
    struct CommentConnection: Decodable {
        var nodes: [ReviewCommentDTO?]?
    }
    var id: String?
    var isResolved: Bool?
    var isOutdated: Bool?
    var path: String?
    var line: Int?
    var originalLine: Int?
    var diffSide: String?
    var comments: CommentConnection?
}

/// One comment inside a review thread.
struct ReviewCommentDTO: Decodable {
    var id: String?
    var databaseId: Int?
    var body: String?
    var createdAt: String?
    var author: GraphQLActorDTO?
}

// MARK: - Closing issues (ADR 0032, the pull-request side of the link)

/// The payload of ``GraphQLDocuments/pullRequestClosingIssues``.
///
/// Shaped exactly like ``ReviewThreadsData``, because it is the same nesting on the same node:
/// the document is read beside that one on the same detail fetch.
struct PullRequestClosingIssuesData: Decodable {
    struct Repository: Decodable {
        struct PullRequest: Decodable {
            struct IssueConnection: Decodable {
                var totalCount: Int?
                var nodes: [ClosingIssueNodeDTO?]?
            }
            var closingIssuesReferences: IssueConnection?
        }
        var pullRequest: PullRequest?
    }
    var repository: Repository?
}

/// One issue as `closingIssuesReferences` carries it.
///
/// Four optional fields for ``LinkedPullRequestNodeDTO``'s reason — a response is trusted for
/// what it contains and not for what it ought to contain — and no author: this is the mirror of
/// the issue-side link, and a provenance chip is a question about a pull request.
struct ClosingIssueNodeDTO: Decodable {
    var number: Int?
    var title: String?
    var state: String?
    var repository: GraphQLRepositoryDTO?
}

// MARK: - Head probe and mutations

/// The payload of ``GraphQLDocuments/pullRequestHead``.
struct PullRequestHeadData: Decodable {
    struct Repository: Decodable {
        struct PullRequest: Decodable {
            var id: String?
            var headRefOid: String?
            var updatedAt: String?
        }
        var pullRequest: PullRequest?
    }
    var repository: Repository?
}

/// The payload of ``GraphQLDocuments/issueState`` (ADR 0032).
struct IssueStateData: Decodable {
    struct Repository: Decodable {
        struct Issue: Decodable {
            var id: String?
            var updatedAt: String?
            var closed: Bool?
        }
        var issue: Issue?
    }
    var repository: Repository?
}

/// The payload of the resolve/unresolve mutations.
struct ResolveThreadData: Decodable {
    struct Payload: Decodable {
        struct Thread: Decodable {
            var id: String?
            var isResolved: Bool?
        }
        var thread: Thread?
    }
    var resolveReviewThread: Payload?
    var unresolveReviewThread: Payload?
}

/// The payload of the ready-for-review mutation.
struct MarkReadyData: Decodable {
    struct Payload: Decodable {
        struct PullRequest: Decodable {
            var id: String?
            var isDraft: Bool?
        }
        var pullRequest: PullRequest?
    }
    var markPullRequestReadyForReview: Payload?
}

// MARK: - Closed pull requests (ADR 0027)

/// The `search` connection returned by ``GraphQLDocuments/searchClosedPullRequests``.
struct SearchClosedPullRequestsData: Decodable {
    struct Search: Decodable {
        var issueCount: Int?
        var pageInfo: PageInfoDTO?
        var nodes: [ClosedPullRequestNodeDTO?]?
    }
    var search: Search?
}

/// The payload of ``GraphQLDocuments/closedPullRequest``.
struct ClosedPullRequestData: Decodable {
    struct Repository: Decodable {
        var pullRequest: ClosedPullRequestNodeDTO?
    }
    var repository: Repository?
}

/// One closed pull request as the track-record read selects it.
///
/// Every field is optional for ``SearchNodeDTO``'s reason: a `search(type: ISSUE)` connection may
/// contain plain issues, which carry only `__typename`. `closedAt` being `nil` is therefore not a
/// malformed row — it is a pull request that is not closed — and the mapper drops it rather than
/// inventing a close date.
struct ClosedPullRequestNodeDTO: Decodable {
    struct MergeCommit: Decodable {
        var oid: String?
    }

    struct ReviewConnection: Decodable {
        var totalCount: Int?
    }

    struct CommitConnection: Decodable {
        struct Node: Decodable {
            struct Commit: Decodable {
                var oid: String?
                var statusCheckRollup: SearchNodeDTO.StatusCheckRollupDTO?
            }
            var commit: Commit?
        }
        var nodes: [Node?]?
    }

    var typename: String?
    var id: String?
    var number: Int?
    var title: String?
    var body: String?
    var createdAt: String?
    var closedAt: String?
    var merged: Bool?
    var mergeCommit: MergeCommit?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var headRefName: String?
    var repository: GraphQLRepositoryDTO?
    var author: GraphQLActorDTO?
    var reviews: ReviewConnection?
    var commits: CommitConnection?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case id, number, title, body, createdAt, closedAt, merged, mergeCommit
        case additions, deletions, changedFiles, headRefName
        case repository, author, reviews, commits
    }
}

// MARK: - Issues sweep (ADR 0032)

/// The `search` connection returned by ``GraphQLDocuments/searchIssues`` and by its
/// timeline-shaped fallback.
struct SearchIssuesData: Decodable {
    struct Search: Decodable {
        var issueCount: Int?
        var pageInfo: PageInfoDTO?
        var nodes: [IssueSearchNodeDTO?]?
    }
    var search: Search?
}

/// The payload of ``GraphQLDocuments/issueByNumber``.
///
/// The search connection's node type, reused: the document selects the same fields, so a row a
/// deep link fetched cannot be shaped differently from one the sweep returned.
struct IssueByNumberData: Decodable {
    struct Repository: Decodable {
        var issue: IssueSearchNodeDTO?
    }
    var repository: Repository?
}

/// One pull request as an issue's links carry it.
///
/// The three shapes that can produce it — `closedByPullRequestsReferences.nodes`,
/// `CrossReferencedEvent.source` and `ConnectedEvent.subject` — select the same five fields, so
/// they decode into the same DTO and there is one mapping rather than three.
struct LinkedPullRequestNodeDTO: Decodable {
    var typename: String?
    var number: Int?
    var title: String?
    var state: String?
    var repository: GraphQLRepositoryDTO?
    var author: GraphQLActorDTO?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case number, title, state, repository, author
    }
}

/// One node of the issues search connection.
///
/// Every field is optional for ``SearchNodeDTO``'s reason: a `search(type: ISSUE)` connection may
/// legitimately contain pull requests, which carry only `__typename` here — the mirror image of
/// the pull-request sweep, which sees plain issues.
///
/// Both link shapes are decoded on the same type. Only one of them is ever populated, because
/// only one of the two documents is ever sent; carrying both is what lets the primary mapper and
/// the fallback mapper share every other field instead of duplicating fourteen of them.
struct IssueSearchNodeDTO: Decodable {
    struct LabelConnection: Decodable {
        struct Label: Decodable { var name: String? }
        var nodes: [Label?]?
    }

    struct CommentConnection: Decodable {
        var totalCount: Int?
    }

    /// `closedByPullRequestsReferences` — the primary shape.
    struct LinkedPullRequestConnection: Decodable {
        var totalCount: Int?
        var nodes: [LinkedPullRequestNodeDTO?]?
    }

    /// `timelineItems(itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT])` — the fallback shape.
    struct TimelineItemConnection: Decodable {
        struct Node: Decodable {
            var typename: String?
            /// `CrossReferencedEvent.willCloseTarget`: whether the reference actually closes this
            /// issue rather than merely mentioning it.
            var willCloseTarget: Bool?
            /// `CrossReferencedEvent.source`.
            var source: LinkedPullRequestNodeDTO?
            /// `ConnectedEvent.subject`.
            var subject: LinkedPullRequestNodeDTO?

            private enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case willCloseTarget, source, subject
            }
        }
        var nodes: [Node?]?
    }

    var typename: String?
    var id: String?
    var number: Int?
    var title: String?
    var createdAt: String?
    var updatedAt: String?
    var closedAt: String?
    var closed: Bool?
    var stateReason: String?
    var repository: GraphQLRepositoryDTO?
    var author: GraphQLActorDTO?
    var labels: LabelConnection?
    var comments: CommentConnection?
    var closedByPullRequestsReferences: LinkedPullRequestConnection?
    var timelineItems: TimelineItemConnection?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case id, number, title, createdAt, updatedAt, closedAt, closed, stateReason
        case repository, author, labels, comments
        case closedByPullRequestsReferences, timelineItems
    }
}
