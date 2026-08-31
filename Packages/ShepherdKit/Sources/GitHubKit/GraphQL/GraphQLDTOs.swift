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
