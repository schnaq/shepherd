import Foundation
import GitHubKit
import ShepherdCore

/// Which outbound event this is (ADR 0012, schema in `docs/WEBHOOKS.md`).
///
/// The raw values are the wire contract — they appear verbatim in the `event` field and users
/// switch on them in n8n — so they are renamed only by bumping the envelope version.
enum WebhookEventKind: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    /// A review actually reached GitHub (approve / request changes / comment).
    case reviewSubmitted = "review.submitted"
    /// A merge actually reached GitHub.
    case pullRequestMerged = "pr.merged"
    /// A local-agent delegation reached a terminal state (ADR 0011).
    case delegationFinished = "delegation.finished"
    /// The sweep discovered a pull request that is waiting for the user's review.
    case newReviewRequest = "inbox.new_review_request"
    /// The "Send test event" button in Settings. Never emitted on its own.
    case test = "shepherd.test"

    var id: String { rawValue }

    /// The kinds the user can subscribe to in Settings.
    ///
    /// ``test`` is deliberately not among them: it is user-initiated, so it is delivered
    /// whenever webhooks are configured at all rather than being something to tick.
    static var userSelectable: [WebhookEventKind] {
        allCases.filter { $0 != .test }
    }

    /// The checkbox label.
    var title: String {
        switch self {
        case .reviewSubmitted: return String(localized: "A review was submitted")
        case .pullRequestMerged: return String(localized: "A pull request was merged")
        case .delegationFinished: return String(localized: "A delegation finished")
        case .newReviewRequest: return String(localized: "A new review was requested from me")
        case .test: return String(localized: "Test event")
        }
    }

    /// A one-line explanation shown under the checkbox.
    var explanation: String {
        switch self {
        case .reviewSubmitted:
            return String(localized: "Fires when the outbox has actually sent the review, not when you press the key.")
        case .pullRequestMerged:
            return String(localized: "Fires when GitHub confirmed the merge, with the method used.")
        case .delegationFinished:
            return String(localized: "Fires when a local agent run ends: finished, failed or cancelled.")
        case .newReviewRequest:
            return String(localized: "Fires when a sweep finds a pull request waiting for your review.")
        case .test:
            return String(localized: "Sent only when you press the button below.")
        }
    }
}

/// The `pullRequest` object every payload carries.
///
/// Every key is always present so a consumer can index into the object without guarding, and
/// the two genuinely absent-able fields (`agentId`, and the details' optionals) are encoded as
/// explicit `null` rather than omitted — the same choice ``AgentCLIConfiguration`` makes, for
/// the same reason: a missing key and a null key must not be the same thing.
struct WebhookPullRequest: Encodable, Sendable, Equatable {
    /// The identity every event can name, even when the local cache no longer has the row.
    struct Identity: Sendable, Hashable {
        /// The pull request's GraphQL node id.
        var prID: String
        /// The repository.
        var repo: RepoRef
        /// The pull request number.
        var number: Int
    }

    /// The repository owner.
    var owner: String
    /// The repository name, without the owner.
    var repo: String
    /// The pull request number.
    var number: Int
    /// The GraphQL node id — Shepherd's primary key, useful for de-duplication downstream.
    var nodeID: String
    /// The pull request title.
    var title: String
    /// The pull request on github.com.
    var url: URL
    /// The author's login.
    var author: String
    /// `"human"`, `"bot"` or `"agent"` (ADR 0008).
    var authorKind: String
    /// Whether the author is a recognised coding agent — the facet the whole product turns on.
    var isAgentAuthored: Bool
    /// The registry id of the agent, e.g. `"claude-code"`; `null` for humans and plain bots.
    var agentID: String?
    /// The head branch name.
    var branch: String
    /// The base branch name.
    var baseBranch: String
    /// The head commit SHA.
    var headSha: String
    /// Whether the pull request is a draft.
    var isDraft: Bool
    /// Added lines.
    var additions: Int
    /// Deleted lines.
    var deletions: Int
    /// Number of changed files.
    var changedFiles: Int
    /// Label names, in GitHub's order.
    var labels: [String]

    private enum CodingKeys: String, CodingKey {
        case owner, repo, number
        case nodeID = "nodeId"
        case title, url, author, authorKind, isAgentAuthored
        case agentID = "agentId"
        case branch, baseBranch, headSha, isDraft, additions, deletions, changedFiles, labels
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(repo, forKey: .repo)
        try container.encode(number, forKey: .number)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(author, forKey: .author)
        try container.encode(authorKind, forKey: .authorKind)
        try container.encode(isAgentAuthored, forKey: .isAgentAuthored)
        // `encode` rather than `encodeIfPresent`: an unknown agent is an explicit null.
        try container.encode(agentID, forKey: .agentID)
        try container.encode(branch, forKey: .branch)
        try container.encode(baseBranch, forKey: .baseBranch)
        try container.encode(headSha, forKey: .headSha)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encode(additions, forKey: .additions)
        try container.encode(deletions, forKey: .deletions)
        try container.encode(changedFiles, forKey: .changedFiles)
        try container.encode(labels, forKey: .labels)
    }

    /// Describes a pull request Shepherd has in full.
    /// - Parameter summary: The inbox row.
    init(summary: PullRequestSummary) {
        self.owner = summary.repo.owner
        self.repo = summary.repo.name
        self.number = summary.number
        self.nodeID = summary.id
        self.title = summary.title
        self.url = AppConfig.pullRequestURL(
            owner: summary.repo.owner,
            name: summary.repo.name,
            number: summary.number
        )
        self.author = summary.author.login
        self.authorKind = WebhookPullRequest.wireAuthorKind(summary.author.kind)
        self.isAgentAuthored = summary.author.kind.agentIdentity != nil
        self.agentID = summary.author.kind.agentIdentity?.id
        self.branch = summary.headRefName
        self.baseBranch = summary.baseRefName
        self.headSha = summary.headRefOid
        self.isDraft = summary.isDraft
        self.additions = summary.additions
        self.deletions = summary.deletions
        self.changedFiles = summary.changedFiles
        self.labels = summary.labels
    }

    /// Describes a pull request the local cache can no longer supply in full.
    ///
    /// This is a real case rather than a defensive one: a merge that succeeds just after a
    /// sweep pruned the row leaves nothing to read. The envelope keeps its shape — every key is
    /// still there — with the cached-only fields empty, so a receiver never has to handle two
    /// shapes for one event.
    /// - Parameter identity: What the event itself carried.
    init(identity: Identity) {
        self.owner = identity.repo.owner
        self.repo = identity.repo.name
        self.number = identity.number
        self.nodeID = identity.prID
        self.title = ""
        self.url = AppConfig.pullRequestURL(
            owner: identity.repo.owner,
            name: identity.repo.name,
            number: identity.number
        )
        self.author = ""
        self.authorKind = "unknown"
        self.isAgentAuthored = false
        self.agentID = nil
        self.branch = ""
        self.baseBranch = ""
        self.headSha = ""
        self.isDraft = false
        self.additions = 0
        self.deletions = 0
        self.changedFiles = 0
        self.labels = []
    }

    /// The wire value for an author's provenance.
    static func wireAuthorKind(_ kind: ActorKind) -> String {
        switch kind {
        case .human: return "human"
        case .bot: return "bot"
        case .agent: return "agent"
        }
    }

    /// The obviously-fictional pull request the test event describes.
    static let sample = WebhookPullRequest(
        identity: Identity(
            prID: "PR_shepherd_test",
            repo: RepoRef(owner: "octocat", name: "hello-world"),
            number: 1
        )
    )
}

/// The per-event `details` object.
///
/// Deliberately small. No review text, no comment bodies, no diff content and no agent output
/// ever leaves the Mac through a webhook — the payload describes *what happened*, and the
/// receiver follows the `url` when it wants the substance (`docs/WEBHOOKS.md`).
enum WebhookEventDetails: Encodable, Sendable, Equatable {
    /// ``WebhookEventKind/reviewSubmitted``.
    case reviewSubmitted(verdict: String, inlineCommentCount: Int)
    /// ``WebhookEventKind/pullRequestMerged``.
    case merged(method: String)
    /// ``WebhookEventKind/delegationFinished``.
    case delegation(
        status: String,
        agent: String,
        durationSeconds: Int,
        changedFileCount: Int,
        message: String?
    )
    /// ``WebhookEventKind/newReviewRequest``.
    case newReviewRequest(relations: [String], reviewDecision: String?, checks: String?)
    /// ``WebhookEventKind/test``.
    case test(note: String)

    private enum CodingKeys: String, CodingKey {
        case verdict, inlineCommentCount
        case mergeMethod
        case status, agent, durationSeconds, changedFileCount, message
        case relations, reviewDecision, checks
        case note
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reviewSubmitted(let verdict, let inlineCommentCount):
            try container.encode(verdict, forKey: .verdict)
            try container.encode(inlineCommentCount, forKey: .inlineCommentCount)
        case .merged(let method):
            try container.encode(method, forKey: .mergeMethod)
        case .delegation(let status, let agent, let seconds, let files, let message):
            try container.encode(status, forKey: .status)
            try container.encode(agent, forKey: .agent)
            try container.encode(seconds, forKey: .durationSeconds)
            try container.encode(files, forKey: .changedFileCount)
            try container.encode(message, forKey: .message)
        case .newReviewRequest(let relations, let reviewDecision, let checks):
            try container.encode(relations, forKey: .relations)
            try container.encode(reviewDecision, forKey: .reviewDecision)
            try container.encode(checks, forKey: .checks)
        case .test(let note):
            try container.encode(note, forKey: .note)
        }
    }

    /// The wire value of a review verdict.
    ///
    /// Snake case rather than ``ShepherdCore/ReviewVerdict``'s `requestChanges`, because that
    /// is what the documented schema promises and the domain enum is free to be renamed.
    static func verdict(_ verdict: ReviewVerdict?) -> String {
        switch verdict {
        case .some(.approve): return "approve"
        case .some(.requestChanges): return "request_changes"
        case .some(.comment): return "comment"
        case .none: return "pending"
        }
    }
}

/// One versioned envelope, ready to be POSTed to the URL the user configured.
struct WebhookEvent: Encodable, Sendable, Equatable {
    /// The envelope version. A change that a receiver cannot ignore bumps this.
    static let schemaVersion = 1
    /// The `source` field, so a receiver fed by several producers can tell them apart.
    static let source = "shepherd"

    /// Which event this is.
    var event: WebhookEventKind
    /// A per-event id, stable across the delivery's retries — the idempotency key a receiver
    /// de-duplicates on.
    var deliveryID: UUID
    /// When the thing happened (not when the POST is attempted).
    var occurredAt: Date
    /// The pull request the event is about.
    var pullRequest: WebhookPullRequest
    /// The event-specific payload.
    var details: WebhookEventDetails

    private enum CodingKeys: String, CodingKey {
        case v, event, id, occurredAt, source, pullRequest, details
    }

    /// Creates an envelope.
    /// - Parameters:
    ///   - event: Which event this is.
    ///   - pullRequest: The pull request it is about.
    ///   - details: The event-specific payload.
    ///   - occurredAt: When it happened.
    ///   - deliveryID: The idempotency key; defaults to a fresh one.
    init(
        event: WebhookEventKind,
        pullRequest: WebhookPullRequest,
        details: WebhookEventDetails,
        occurredAt: Date = Date(),
        deliveryID: UUID = UUID()
    ) {
        self.event = event
        self.pullRequest = pullRequest
        self.details = details
        self.occurredAt = occurredAt
        self.deliveryID = deliveryID
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .v)
        try container.encode(event.rawValue, forKey: .event)
        try container.encode(deliveryID.uuidString.lowercased(), forKey: .id)
        // Formatted by hand rather than through a `dateEncodingStrategy`: the same UTC,
        // second-precision ISO-8601 the GitHub client already speaks, and it cannot be
        // changed out from under the schema by an encoder setting.
        try container.encode(GitHubTimestamp.string(from: occurredAt), forKey: .occurredAt)
        try container.encode(Self.source, forKey: .source)
        try container.encode(pullRequest, forKey: .pullRequest)
        try container.encode(details, forKey: .details)
    }

    /// The one encoder webhook bodies are produced with.
    ///
    /// `sortedKeys` makes the bytes a pure function of the value, which is what lets the tests
    /// pin the schema and the signature be computed over exactly what is sent. JSON objects are
    /// unordered, so no receiver may depend on the alphabetical order it happens to see.
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The exact bytes to POST — and to sign.
    /// - Returns: The encoded envelope.
    /// - Throws: Whatever `JSONEncoder` throws; the dispatcher maps it to
    ///   ``WebhookError/malformedPayload``.
    func canonicalJSON() throws -> Data {
        try WebhookEvent.canonicalEncoder().encode(self)
    }

    /// The envelope the "Send test event" button delivers.
    /// - Parameter occurredAt: The timestamp to stamp it with.
    static func testEvent(occurredAt: Date = Date()) -> WebhookEvent {
        WebhookEvent(
            event: .test,
            pullRequest: .sample,
            details: .test(
                note: "Test event from Shepherd. The pull request in this payload is fictional."
            ),
            occurredAt: occurredAt
        )
    }
}
