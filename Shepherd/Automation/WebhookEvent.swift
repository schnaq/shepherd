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
    /// A rule queued a merge on its own (ADR 0018).
    ///
    /// The one event that fires on an *intent* rather than on a success, and the exception is
    /// deliberate: what is worth reporting here is that **Shepherd decided something unattended**,
    /// which is a fact the moment the row is written. The write's success is still reported, by
    /// ``pullRequestMerged``, once the drain has sent it — so an automatic merge produces two
    /// events, and a merge that was parked because the head moved produces only the first.
    case autoMergeQueued = "pr.auto_merge_queued"
    /// An issue Shepherd closed reached GitHub (ADR 0032's Sprint 4a amendment).
    ///
    /// Fired from the outbox drain's `mutationSent`, the same hook ``reviewSubmitted`` and
    /// ``pullRequestMerged`` use, and for the same reason: a close that is still waiting out a
    /// backoff has closed nothing. It is the one event whose envelope carries an `issue` object
    /// in place of `pullRequest` — see ``WebhookEvent/Subject``.
    case issueClosed = "issue.closed"
    /// An issue was handed to a local assistant (ADR 0032's 2026-09-04 amendment).
    ///
    /// Fired when the run is **actually running** in its worktree, which is neither the click
    /// nor the assignment comment reaching GitHub: a click can be followed by a missing
    /// checkout or a branch git refuses to create, and the comment is queued locally and may
    /// sit out a backoff. What is true at this one point is that something is working on the
    /// issue — see ``DelegationStart``. Like ``issueClosed`` its envelope carries an `issue`.
    case issueAssignedToAgent = "issue.assigned_to_agent"
    /// The "Send test event" button in Settings. Never emitted on its own.
    case test = "shepherd.test"

    var id: String { rawValue }

    /// Whether this event's envelope describes an issue rather than a pull request.
    ///
    /// The subject key is part of the wire contract, so this is the single place that decides
    /// it: a kind added later either says `true` here and carries an `issue`, or says `false`
    /// and carries a `pullRequest`. There is no third shape.
    var isAboutAnIssue: Bool {
        switch self {
        case .issueClosed, .issueAssignedToAgent:
            return true
        case .reviewSubmitted, .pullRequestMerged, .delegationFinished, .newReviewRequest,
             .autoMergeQueued, .test:
            return false
        }
    }

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
        case .autoMergeQueued: return String(localized: "An automatic merge was queued")
        case .issueClosed: return String(localized: "An issue was closed")
        case .issueAssignedToAgent: return String(localized: "An issue was handed to an agent")
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
            return String(localized: "Fires when a local agent run ends: finished, failed or cancelled — including runs an automatic rule started.")
        case .newReviewRequest:
            return String(localized: "Fires when a sweep finds a pull request waiting for your review.")
        case .autoMergeQueued:
            return String(localized: "Fires when an auto-merge rule queued a merge — at the moment Shepherd decided, not when GitHub confirmed. The merge itself still sends \"A pull request was merged\".")
        case .issueClosed:
            return String(localized: "Fires when GitHub confirmed the close, with the reason. The payload describes the issue, not a pull request.")
        case .issueAssignedToAgent:
            return String(localized: "Fires when an agent is actually running on an issue you assigned it — not when you pressed the button. The payload describes the issue, not a pull request.")
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

/// The `issue` object an issue-shaped event carries in place of ``WebhookPullRequest``.
///
/// A second type rather than three optional fields on the pull-request object, and the reason is
/// the same one ADR 0032 gives for `IssueRowSummary` beside `PullRequestSummary`: an issue has no
/// branch, no base branch, no head SHA, no draft flag and no diff counts, and a receiver that had
/// to guard every one of them would be reading a shape the producer never fills in.
///
/// Deliberately small — exactly what the plan's §5.3 names: where it is, what it is called, who
/// wrote it and with what provenance. No body, no labels, no comment count, no linked pull
/// requests. ADR 0012's rule is that the payload says *what happened* and the receiver follows
/// the `url` for the substance.
struct WebhookIssue: Encodable, Sendable, Equatable {
    /// The repository owner.
    var owner: String
    /// The repository name, without the owner.
    var repo: String
    /// The issue number.
    var number: Int
    /// The GraphQL node id — Shepherd's primary key, useful for de-duplication downstream.
    var nodeID: String
    /// The issue title.
    var title: String
    /// The issue on github.com.
    var url: URL
    /// The author's login.
    var author: String
    /// `"human"`, `"bot"` or `"agent"` (ADR 0008).
    var authorKind: String
    /// Whether the author is a recognised coding agent.
    var isAgentAuthored: Bool
    /// The registry id of the agent, e.g. `"example-agent"`; `null` for humans and plain bots.
    var agentID: String?

    private enum CodingKeys: String, CodingKey {
        case owner, repo, number
        case nodeID = "nodeId"
        case title, url, author, authorKind, isAgentAuthored
        case agentID = "agentId"
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
        // `encode` rather than `encodeIfPresent`: an unknown agent is an explicit null, exactly
        // as it is on the pull-request object.
        try container.encode(agentID, forKey: .agentID)
    }

    /// Describes an issue Shepherd still has the row for.
    /// - Parameter summary: The cached issue row.
    init(summary: IssueRowSummary) {
        self.owner = summary.repo.owner
        self.repo = summary.repo.name
        self.number = summary.number
        self.nodeID = summary.id
        self.title = summary.title
        self.url = AppConfig.issueURL(
            owner: summary.repo.owner,
            name: summary.repo.name,
            number: summary.number
        )
        self.author = summary.author.login
        self.authorKind = WebhookPullRequest.wireAuthorKind(summary.author.kind)
        self.isAgentAuthored = summary.author.kind.agentIdentity != nil
        self.agentID = summary.author.kind.agentIdentity?.id
    }

    /// Describes an issue the local cache can no longer supply in full.
    ///
    /// A real case rather than a defensive one, and a more likely one here than on the
    /// pull-request side: closing an issue is exactly what makes the next sweep prune its row,
    /// so a slow POST can perfectly well outlive it. The shape does not change — every key is
    /// still there, with the cached-only fields empty.
    /// - Parameter identity: What the event itself carried.
    init(identity: WebhookPullRequest.Identity) {
        self.owner = identity.repo.owner
        self.repo = identity.repo.name
        self.number = identity.number
        self.nodeID = identity.prID
        self.title = ""
        self.url = AppConfig.issueURL(
            owner: identity.repo.owner,
            name: identity.repo.name,
            number: identity.number
        )
        self.author = ""
        self.authorKind = "unknown"
        self.isAgentAuthored = false
        self.agentID = nil
    }
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
    ///
    /// `automatic` was added with the auto-delegation rules (ADR 0016). It is additive under
    /// `"v": 1`: a receiver that never looks at it keeps working, and one that does can tell a
    /// run the user started from one a rule started.
    case delegation(
        status: String,
        agent: String,
        durationSeconds: Int,
        changedFileCount: Int,
        message: String?,
        automatic: Bool
    )
    /// ``WebhookEventKind/newReviewRequest``.
    case newReviewRequest(relations: [String], reviewDecision: String?, checks: String?)
    /// ``WebhookEventKind/autoMergeQueued`` (ADR 0018).
    ///
    /// The three facts that justified the decision, and nothing else: which method the row asks
    /// for, how many checks were green, and which required labels the pull request carried (empty
    /// when the rule required none). The head commit the merge is pinned to is already in the
    /// envelope's `pullRequest.headSha`.
    case autoMergeQueued(mergeMethod: String, checkCount: Int, matchedLabels: [String])
    /// ``WebhookEventKind/issueClosed`` (ADR 0032).
    ///
    /// One key: GitHub's own `state_reason` word, `"completed"` or `"not_planned"`. Deliberately
    /// raw and unmapped — a receiver that routes on "was this actually fixed" wants the word
    /// GitHub records, not a vocabulary Shepherd invented.
    case issueClosed(reason: String)
    /// ``WebhookEventKind/issueAssignedToAgent`` (ADR 0032).
    ///
    /// Two keys: which assistant is on it, and which task template the brief was rendered from —
    /// the template's *name*, never its text. A template may quote the issue, and an envelope
    /// that promises to say what happened rather than what was written must not carry a brief
    /// (ADR 0012).
    case issueAssignment(agent: String, template: String)
    /// ``WebhookEventKind/test``.
    case test(note: String)

    private enum CodingKeys: String, CodingKey {
        case verdict, inlineCommentCount
        case mergeMethod
        case status, agent, durationSeconds, changedFileCount, message, automatic
        case relations, reviewDecision, checks
        case checkCount, matchedLabels
        case reason
        case template
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
        case .delegation(let status, let agent, let seconds, let files, let message, let automatic):
            try container.encode(status, forKey: .status)
            try container.encode(agent, forKey: .agent)
            try container.encode(seconds, forKey: .durationSeconds)
            try container.encode(files, forKey: .changedFileCount)
            try container.encode(message, forKey: .message)
            try container.encode(automatic, forKey: .automatic)
        case .newReviewRequest(let relations, let reviewDecision, let checks):
            try container.encode(relations, forKey: .relations)
            try container.encode(reviewDecision, forKey: .reviewDecision)
            try container.encode(checks, forKey: .checks)
        case .autoMergeQueued(let method, let checkCount, let matchedLabels):
            try container.encode(method, forKey: .mergeMethod)
            try container.encode(checkCount, forKey: .checkCount)
            try container.encode(matchedLabels, forKey: .matchedLabels)
        case .issueClosed(let reason):
            try container.encode(reason, forKey: .reason)
        case .issueAssignment(let agent, let template):
            try container.encode(agent, forKey: .agent)
            try container.encode(template, forKey: .template)
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

    /// What one envelope is *about*: a pull request, or — since ADR 0032's Sprint 4a amendment —
    /// an issue.
    ///
    /// The two encode under different top-level keys, and that is the whole of the schema change:
    /// no event that existed before this amendment gained, lost or renamed a key, so it is
    /// additive under `"v": 1` in the strictest sense. A receiver switching on `event` already
    /// knows which shape it is getting, and ``WebhookEventKind/isAboutAnIssue`` is the single
    /// place that decides.
    enum Subject: Sendable, Equatable {
        /// The envelope carries a `pullRequest` object.
        case pullRequest(WebhookPullRequest)
        /// The envelope carries an `issue` object.
        case issue(WebhookIssue)
    }

    /// Which event this is.
    var event: WebhookEventKind
    /// A per-event id, stable across the delivery's retries — the idempotency key a receiver
    /// de-duplicates on.
    var deliveryID: UUID
    /// When the thing happened (not when the POST is attempted).
    var occurredAt: Date
    /// What the event is about.
    var subject: Subject
    /// The event-specific payload.
    var details: WebhookEventDetails

    private enum CodingKeys: String, CodingKey {
        case v, event, id, occurredAt, source, pullRequest, issue, details
    }

    /// Creates an envelope about a pull request.
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
        self.init(
            event: event,
            subject: .pullRequest(pullRequest),
            details: details,
            occurredAt: occurredAt,
            deliveryID: deliveryID
        )
    }

    /// Creates an envelope about an issue (ADR 0032).
    /// - Parameters:
    ///   - event: Which event this is.
    ///   - issue: The issue it is about.
    ///   - details: The event-specific payload.
    ///   - occurredAt: When it happened.
    ///   - deliveryID: The idempotency key; defaults to a fresh one.
    init(
        event: WebhookEventKind,
        issue: WebhookIssue,
        details: WebhookEventDetails,
        occurredAt: Date = Date(),
        deliveryID: UUID = UUID()
    ) {
        self.init(
            event: event,
            subject: .issue(issue),
            details: details,
            occurredAt: occurredAt,
            deliveryID: deliveryID
        )
    }

    /// The designated initialiser.
    /// - Parameters:
    ///   - event: Which event this is.
    ///   - subject: What it is about.
    ///   - details: The event-specific payload.
    ///   - occurredAt: When it happened.
    ///   - deliveryID: The idempotency key.
    init(
        event: WebhookEventKind,
        subject: Subject,
        details: WebhookEventDetails,
        occurredAt: Date = Date(),
        deliveryID: UUID = UUID()
    ) {
        self.event = event
        self.subject = subject
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
        // One key or the other, never both and never an empty one: an event is about exactly one
        // thing, and a `"pullRequest": null` beside an `issue` would be a shape every receiver
        // then has to guard.
        switch subject {
        case .pullRequest(let pullRequest):
            try container.encode(pullRequest, forKey: .pullRequest)
        case .issue(let issue):
            try container.encode(issue, forKey: .issue)
        }
        try container.encode(details, forKey: .details)
    }

    /// The exact bytes to POST — and to sign.
    ///
    /// ``CanonicalJSON`` is what makes the two the same bytes: the signature is computed over
    /// this output, so the encoding has to be a pure function of the value.
    /// - Returns: The encoded envelope.
    /// - Throws: Whatever `JSONEncoder` throws; the dispatcher maps it to
    ///   ``WebhookError/malformedPayload``.
    func canonicalJSON() throws -> Data {
        try CanonicalJSON.encoder().encode(self)
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
