import Foundation

/// A GitHub account as REST returns it (`user`, `owner`, `author`).
struct RESTUserDTO: Decodable {
    var login: String?
    var avatarUrl: String?
    var type: String?
    var name: String?

    /// `true` when GitHub says this account is a bot — authoritative for provenance
    /// (ADR 0008).
    var isBot: Bool { type?.lowercased() == "bot" }
}

/// A repository as REST returns it.
struct RESTRepositoryDTO: Decodable {
    var name: String?
    var fullName: String?
    var owner: RESTUserDTO?
}

/// `GET /repos/{owner}/{repo}/pulls/{number}`.
struct RESTPullRequestDTO: Decodable {
    struct Ref: Decodable {
        var ref: String?
        var sha: String?
        var repo: RESTRepositoryDTO?
    }
    struct Label: Decodable {
        var name: String?
    }

    var nodeId: String?
    var number: Int?
    var title: String?
    var body: String?
    var state: String?
    var draft: Bool?
    var merged: Bool?
    var mergeable: Bool?
    var mergeableState: String?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var createdAt: String?
    var updatedAt: String?
    var user: RESTUserDTO?
    var head: Ref?
    var base: Ref?
    var labels: [Label]?
    var htmlUrl: String?
}

/// One entry of `GET /repos/{owner}/{repo}/pulls/{number}/files`.
struct RESTFileDTO: Decodable {
    var filename: String?
    var previousFilename: String?
    var status: String?
    var additions: Int?
    var deletions: Int?
    var changes: Int?
    var patch: String?
    var sha: String?
}

/// One entry of `GET /repos/{owner}/{repo}/pulls/{number}/commits`.
struct RESTCommitDTO: Decodable {
    struct Commit: Decodable {
        struct Signature: Decodable {
            var name: String?
            var email: String?
            var date: String?
        }
        var message: String?
        var author: Signature?
        var committer: Signature?
    }
    var sha: String?
    var commit: Commit?
    var author: RESTUserDTO?
}

/// One entry of `GET /repos/{owner}/{repo}/pulls/{number}/reviews`.
struct RESTReviewDTO: Decodable {
    var id: Int?
    var nodeId: String?
    var user: RESTUserDTO?
    var body: String?
    var state: String?
    var submittedAt: String?
    var commitId: String?
}

/// `GET /repos/{owner}/{repo}/issues/{number}`.
///
/// The endpoint serves pull requests as well as issues, and the only thing that tells them apart
/// is the presence of the `pull_request` object — GitHub's own documented marker. Everything here
/// is optional because a body Shepherd cannot read is a `nil` field rather than a thrown error:
/// an issue with no description is ordinary.
struct RESTIssueDTO: Decodable {
    /// Present only when the resource is actually a pull request.
    struct PullRequestMarker: Decodable {
        var htmlUrl: String?
    }

    var number: Int?
    var title: String?
    var body: String?
    var state: String?
    var htmlUrl: String?
    var pullRequest: PullRequestMarker?
}

/// `GET /repos/{owner}/{repo}/commits/{ref}/check-runs`.
struct RESTCheckRunsDTO: Decodable {
    struct Run: Decodable {
        struct Output: Decodable {
            var title: String?
            var summary: String?
        }
        var id: Int?
        var nodeId: String?
        var name: String?
        var status: String?
        var conclusion: String?
        var detailsUrl: String?
        var startedAt: String?
        var completedAt: String?
        var output: Output?
    }
    var totalCount: Int?
    var checkRuns: [Run]?
}

/// One entry of `GET /notifications`.
struct RESTNotificationDTO: Decodable {
    struct Subject: Decodable {
        var title: String?
        var url: String?
        var latestCommentUrl: String?
        var type: String?
    }
    var id: String?
    var unread: Bool?
    var reason: String?
    var updatedAt: String?
    var lastReadAt: String?
    var subject: Subject?
    var repository: RESTRepositoryDTO?
}

/// The error body GitHub returns for `4xx` responses.
struct RESTErrorDTO: Decodable {
    struct FieldError: Decodable {
        var resource: String?
        var field: String?
        var code: String?
        var message: String?
    }
    var message: String?
    var errors: [FieldError]?
    var documentationUrl: String?

    /// A single human-readable line combining the top-level message and any field errors.
    var combinedMessage: String {
        var parts: [String] = []
        if let message, !message.isEmpty { parts.append(message) }
        for error in errors ?? [] {
            let field = [error.resource, error.field].compactMap { $0 }.joined(separator: ".")
            let detail = error.message ?? error.code ?? "invalid"
            parts.append(field.isEmpty ? detail : "\(field): \(detail)")
        }
        return parts.isEmpty ? "Unknown error" : parts.joined(separator: " — ")
    }
}

/// The response of `PUT /repos/{owner}/{repo}/pulls/{number}/merge`.
struct RESTMergeResultDTO: Decodable {
    var sha: String?
    var merged: Bool?
    var message: String?
}

/// The response of `POST /repos/{owner}/{repo}/pulls/{number}/reviews`.
public struct SubmittedReview: Sendable, Hashable {
    /// The REST id of the created review.
    public var id: Int
    /// The GraphQL node id of the created review, when GitHub returned one.
    public var nodeId: String?
    /// The review state: `"PENDING"`, `"APPROVED"`, `"CHANGES_REQUESTED"` or `"COMMENTED"`.
    public var state: String
    /// The commit the review was attached to.
    public var commitID: String?

    /// Creates a submitted-review receipt.
    public init(id: Int, nodeId: String? = nil, state: String, commitID: String? = nil) {
        self.id = id
        self.nodeId = nodeId
        self.state = state
        self.commitID = commitID
    }

    /// Whether the review was left pending on GitHub rather than submitted.
    public var isPending: Bool { state.uppercased() == "PENDING" }
}
