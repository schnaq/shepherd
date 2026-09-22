import Foundation

/// Why an issue is being closed — GitHub's `state_reason` vocabulary as a closed enum (ADR 0032).
///
/// A real enum rather than ``OutboxAction/merge(method:expectedHeadOid:)``'s raw string, and the
/// asymmetry is deliberate: a merge method is one of three words GitHub may grow, while "completed
/// or not planned" is the *whole* of the choice the close button offers and the two halves read
/// differently in the UI. So the vocabulary is closed here, and a row written by a build that knew
/// a third reason simply fails to decode — which
/// ``ShepherdPersistence/DatabaseManager/claimReadyOutboxItems(now:limit:)`` already skips rather
/// than letting it poison the queue.
///
/// The raw values *are* the wire values: they go into `state_reason` verbatim.
public enum IssueCloseReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// The issue was addressed. GitHub's `completed`.
    case completed
    /// The issue will not be addressed. GitHub's `not_planned`.
    case notPlanned = "not_planned"
}

/// An outbound mutation waiting to be sent to GitHub.
///
/// Every write Shepherd performs — submitting a review, replying, resolving a thread,
/// merging — is written to the outbox first and executed by the sync engine (ADR 0006). That
/// is what makes writes survive a crash, a quit, or a train tunnel.
///
/// The five issue cases (ADR 0032's Sprint 4a amendment) are additive to this type and to nothing
/// else: `outbox.payload` stores the whole enum as an opaque blob, so a new case needs no
/// migration, and a row written before they existed still decodes because its discriminator is
/// still one of the cases below. Each of them carries `basedOnUpdatedAt` — the issue's
/// `updatedAt` at the moment the user pressed the button — which the drain re-reads and compares
/// before it sends anything, exactly as ``ReviewDraft/basedOnHeadOid`` is compared before a review
/// is submitted.
public enum OutboxAction: Sendable, Codable, Hashable {
    /// Submit a locally composed review.
    case submitReview(ReviewDraft)
    /// Reply to an existing review comment, addressed by its REST database id.
    case replyToComment(commentDatabaseID: Int, body: String)
    /// Resolve a review thread by its GraphQL node id.
    case resolveThread(threadID: String)
    /// Unresolve a review thread by its GraphQL node id.
    case unresolveThread(threadID: String)
    /// Merge the pull request, and optionally delete its head branch afterwards.
    ///
    /// The deletion is a *field of the merge* rather than a row of its own, because a merge and
    /// the tidying-up that follows it are one intent: two rows could be drained by two different
    /// Macs, or in two different sweeps, and a branch deleted by a machine whose merge row was
    /// still queued would be a deletion of something that had not been merged yet.
    /// - Parameters:
    ///   - method: `"merge"`, `"squash"` or `"rebase"`. A raw string so that `ShepherdCore`
    ///     stays free of GitHub-specific types.
    ///   - expectedHeadOid: The head SHA the user saw, sent as a merge precondition.
    ///   - deletesHeadBranch: Whether the head branch is to be deleted once the merge has landed.
    ///     Defaults to `false`, which is how every caller that predates branch deletion queues a
    ///     merge — the automatic rules (ADR 0018) and bulk triage (ADR 0015) among them.
    case merge(method: String, expectedHeadOid: String?, deletesHeadBranch: Bool = false)
    /// Take the pull request out of draft state.
    case markReadyForReview
    /// Post a comment on the pull request's conversation.
    ///
    /// The conversation, not a review: GitHub's own *Comment* button writes an issue comment,
    /// which is a different thing from a `COMMENT` review — a review carries a verdict field and
    /// shows up under Files changed, a comment is what one says about the pull request. Shepherd
    /// had the first and not the second.
    /// - Parameter body: The comment as Markdown source.
    case addPullRequestComment(body: String)
    /// Close the pull request, and say why in the same breath.
    ///
    /// One case rather than two rows, for ``merge(method:expectedHeadOid:deletesHeadBranch:)``'s
    /// reason: "comment and close" is one intent, and two rows could be drained by two different
    /// Macs or in two different sweeps — a pull request closed by the machine whose comment row
    /// was still queued would be a close with the explanation missing.
    /// - Parameter comment: What to post before closing, or `nil` to close without a word.
    case closePullRequest(comment: String?)
    /// Post a comment on the issue (ADR 0032).
    /// - Parameters:
    ///   - body: The comment as Markdown source.
    ///   - basedOnUpdatedAt: The issue's ``IssueRowSummary/updatedAt`` when this was queued.
    case addIssueComment(body: String, basedOnUpdatedAt: Date)
    /// Add one label to the issue, without touching the ones already on it.
    ///
    /// The *additive* endpoint, never the full-replace `PATCH`: two queued label writes must not
    /// be able to race each other into one lost update (ADR 0032).
    /// - Parameters:
    ///   - name: The label name, exactly as GitHub spells it.
    ///   - basedOnUpdatedAt: The issue's ``IssueRowSummary/updatedAt`` when this was queued.
    case addIssueLabel(name: String, basedOnUpdatedAt: Date)
    /// Add one assignee to the issue, without removing the ones already on it.
    /// - Parameters:
    ///   - login: The GitHub login to assign.
    ///   - basedOnUpdatedAt: The issue's ``IssueRowSummary/updatedAt`` when this was queued.
    case addIssueAssignee(login: String, basedOnUpdatedAt: Date)
    /// Close the issue with a reason.
    /// - Parameters:
    ///   - reason: Completed, or not planned.
    ///   - basedOnUpdatedAt: The issue's ``IssueRowSummary/updatedAt`` when this was queued.
    case closeIssue(reason: IssueCloseReason, basedOnUpdatedAt: Date)
    /// Reopen a closed issue.
    /// - Parameter basedOnUpdatedAt: The issue's ``IssueRowSummary/updatedAt`` when this was
    ///   queued.
    case reopenIssue(basedOnUpdatedAt: Date)

    /// A short, stable discriminator, used as a database column and in logs.
    public var kind: String {
        switch self {
        case .submitReview: return "submitReview"
        case .replyToComment: return "replyToComment"
        case .resolveThread: return "resolveThread"
        case .unresolveThread: return "unresolveThread"
        case .merge: return "merge"
        case .markReadyForReview: return "markReadyForReview"
        case .addPullRequestComment: return "addPullRequestComment"
        case .closePullRequest: return "closePullRequest"
        case .addIssueComment: return "addIssueComment"
        case .addIssueLabel: return "addIssueLabel"
        case .addIssueAssignee: return "addIssueAssignee"
        case .closeIssue: return "closeIssue"
        case .reopenIssue: return "reopenIssue"
        }
    }

    /// The issue `updatedAt` this action was composed against, or `nil` when it is a
    /// pull-request action.
    ///
    /// The drain's staleness precondition reads exactly this: a non-`nil` answer means "probe the
    /// issue before sending", so the rule cannot be forgotten for a case added later — a new issue
    /// action that did not carry the date would have to say so here.
    public var basedOnIssueUpdatedAt: Date? {
        switch self {
        case .addIssueComment(_, let updatedAt),
             .addIssueLabel(_, let updatedAt),
             .addIssueAssignee(_, let updatedAt),
             .closeIssue(_, let updatedAt),
             .reopenIssue(let updatedAt):
            return updatedAt
        case .submitReview, .replyToComment, .resolveThread, .unresolveThread, .merge,
             .markReadyForReview, .addPullRequestComment, .closePullRequest:
            return nil
        }
    }

    /// Whether the action targets an issue rather than a pull request.
    ///
    /// Which is also what decides how ``OutboxItem``'s three target fields are to be read — see
    /// that type's own note.
    public var targetsIssue: Bool { basedOnIssueUpdatedAt != nil }

    // MARK: - Coding

    // The compiler would synthesise all of this, and did until the merge case grew a third
    // associated value. Synthesised decoding of an enum payload is *strict* — every associated
    // value is a required key — so a merge row queued by a build that predates
    // ``deletesHeadBranch`` would stop decoding the moment the field was added, and
    // ``ShepherdPersistence/DatabaseManager/claimReadyOutboxItems(now:limit:)`` skips a row whose
    // payload no longer decodes. A user who queued a merge on the train and updated Shepherd
    // before landing would find the merge quietly gone.
    //
    // So the coding is written out by hand, in exactly the shape the compiler produced — one
    // object whose single key names the case, holding the associated values under their labels
    // (or `_0` where there is no label) — with one difference: the new field is read
    // *tolerantly*, the way ``AutoDelegationRules`` reads a field an older document does not carry.
    // An absent key means the row was queued before branch deletion existed, and such a merge
    // must not start deleting a branch because the app was updated.

    /// The single key of an encoded action: the case's own name.
    private enum CodingKeys: String, CodingKey {
        case submitReview, replyToComment, resolveThread, unresolveThread, merge
        case markReadyForReview
        case addIssueComment, addIssueLabel, addIssueAssignee, closeIssue, reopenIssue
        case addPullRequestComment, closePullRequest
    }

    /// The payload keys of ``submitReview(_:)`` — one unlabelled value, so `_0`.
    private enum SubmitReviewKeys: String, CodingKey {
        case _0
    }

    /// The payload keys of ``replyToComment(commentDatabaseID:body:)``.
    private enum ReplyToCommentKeys: String, CodingKey {
        case commentDatabaseID, body
    }

    /// The payload keys of the two thread actions, which carry the same one value.
    private enum ThreadKeys: String, CodingKey {
        case threadID
    }

    /// The payload keys of ``merge(method:expectedHeadOid:deletesHeadBranch:)``.
    private enum MergeKeys: String, CodingKey {
        case method, expectedHeadOid, deletesHeadBranch
    }

    /// The payload keys of ``addPullRequestComment(body:)``.
    private enum PullRequestCommentKeys: String, CodingKey {
        case body
    }

    /// The payload keys of ``closePullRequest(comment:)``.
    private enum ClosePullRequestKeys: String, CodingKey {
        case comment
    }

    /// The payload keys of ``addIssueComment(body:basedOnUpdatedAt:)``.
    private enum IssueCommentKeys: String, CodingKey {
        case body, basedOnUpdatedAt
    }

    /// The payload keys of ``addIssueLabel(name:basedOnUpdatedAt:)``.
    private enum IssueLabelKeys: String, CodingKey {
        case name, basedOnUpdatedAt
    }

    /// The payload keys of ``addIssueAssignee(login:basedOnUpdatedAt:)``.
    private enum IssueAssigneeKeys: String, CodingKey {
        case login, basedOnUpdatedAt
    }

    /// The payload keys of ``closeIssue(reason:basedOnUpdatedAt:)``.
    private enum CloseIssueKeys: String, CodingKey {
        case reason, basedOnUpdatedAt
    }

    /// The payload keys of ``reopenIssue(basedOnUpdatedAt:)``.
    private enum ReopenIssueKeys: String, CodingKey {
        case basedOnUpdatedAt
    }

    /// Encodes the action as `{"<case>": {<associated values>}}`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .submitReview(let draft):
            var nested = container.nestedContainer(
                keyedBy: SubmitReviewKeys.self,
                forKey: .submitReview
            )
            try nested.encode(draft, forKey: ._0)
        case .replyToComment(let commentDatabaseID, let body):
            var nested = container.nestedContainer(
                keyedBy: ReplyToCommentKeys.self,
                forKey: .replyToComment
            )
            try nested.encode(commentDatabaseID, forKey: .commentDatabaseID)
            try nested.encode(body, forKey: .body)
        case .resolveThread(let threadID):
            var nested = container.nestedContainer(
                keyedBy: ThreadKeys.self,
                forKey: .resolveThread
            )
            try nested.encode(threadID, forKey: .threadID)
        case .unresolveThread(let threadID):
            var nested = container.nestedContainer(
                keyedBy: ThreadKeys.self,
                forKey: .unresolveThread
            )
            try nested.encode(threadID, forKey: .threadID)
        case .merge(let method, let expectedHeadOid, let deletesHeadBranch):
            var nested = container.nestedContainer(keyedBy: MergeKeys.self, forKey: .merge)
            try nested.encode(method, forKey: .method)
            try nested.encodeIfPresent(expectedHeadOid, forKey: .expectedHeadOid)
            try nested.encode(deletesHeadBranch, forKey: .deletesHeadBranch)
        case .markReadyForReview:
            // The case has no associated values, so its payload is the empty object the
            // compiler's own synthesis writes.
            try container.encode([String: String](), forKey: .markReadyForReview)
        case .addPullRequestComment(let body):
            var nested = container.nestedContainer(
                keyedBy: PullRequestCommentKeys.self,
                forKey: .addPullRequestComment
            )
            try nested.encode(body, forKey: .body)
        case .closePullRequest(let comment):
            var nested = container.nestedContainer(
                keyedBy: ClosePullRequestKeys.self,
                forKey: .closePullRequest
            )
            // `encodeIfPresent`, so a close with nothing to say writes no key at all rather than
            // a null — and reads back as `nil` through the same door an older row would.
            try nested.encodeIfPresent(comment, forKey: .comment)
        case .addIssueComment(let body, let basedOnUpdatedAt):
            var nested = container.nestedContainer(
                keyedBy: IssueCommentKeys.self,
                forKey: .addIssueComment
            )
            try nested.encode(body, forKey: .body)
            try nested.encode(basedOnUpdatedAt, forKey: .basedOnUpdatedAt)
        case .addIssueLabel(let name, let basedOnUpdatedAt):
            var nested = container.nestedContainer(
                keyedBy: IssueLabelKeys.self,
                forKey: .addIssueLabel
            )
            try nested.encode(name, forKey: .name)
            try nested.encode(basedOnUpdatedAt, forKey: .basedOnUpdatedAt)
        case .addIssueAssignee(let login, let basedOnUpdatedAt):
            var nested = container.nestedContainer(
                keyedBy: IssueAssigneeKeys.self,
                forKey: .addIssueAssignee
            )
            try nested.encode(login, forKey: .login)
            try nested.encode(basedOnUpdatedAt, forKey: .basedOnUpdatedAt)
        case .closeIssue(let reason, let basedOnUpdatedAt):
            var nested = container.nestedContainer(
                keyedBy: CloseIssueKeys.self,
                forKey: .closeIssue
            )
            try nested.encode(reason, forKey: .reason)
            try nested.encode(basedOnUpdatedAt, forKey: .basedOnUpdatedAt)
        case .reopenIssue(let basedOnUpdatedAt):
            var nested = container.nestedContainer(
                keyedBy: ReopenIssueKeys.self,
                forKey: .reopenIssue
            )
            try nested.encode(basedOnUpdatedAt, forKey: .basedOnUpdatedAt)
        }
    }

    /// Decodes an action written by this build or by any build before it.
    /// - Parameter decoder: The decoder holding one stored `outbox.payload`.
    /// - Throws: A ``Swift/DecodingError`` when the object does not name exactly one known
    ///   action, or when a value the action has always carried is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "An outbox payload names exactly one action."
                )
            )
        }
        switch key {
        case .submitReview:
            let nested = try container.nestedContainer(
                keyedBy: SubmitReviewKeys.self,
                forKey: .submitReview
            )
            let draft = try nested.decode(ReviewDraft.self, forKey: ._0)
            self = .submitReview(draft)
        case .replyToComment:
            let nested = try container.nestedContainer(
                keyedBy: ReplyToCommentKeys.self,
                forKey: .replyToComment
            )
            let commentDatabaseID = try nested.decode(Int.self, forKey: .commentDatabaseID)
            let body = try nested.decode(String.self, forKey: .body)
            self = .replyToComment(commentDatabaseID: commentDatabaseID, body: body)
        case .resolveThread:
            let nested = try container.nestedContainer(
                keyedBy: ThreadKeys.self,
                forKey: .resolveThread
            )
            let threadID = try nested.decode(String.self, forKey: .threadID)
            self = .resolveThread(threadID: threadID)
        case .unresolveThread:
            let nested = try container.nestedContainer(
                keyedBy: ThreadKeys.self,
                forKey: .unresolveThread
            )
            let threadID = try nested.decode(String.self, forKey: .threadID)
            self = .unresolveThread(threadID: threadID)
        case .merge:
            let nested = try container.nestedContainer(keyedBy: MergeKeys.self, forKey: .merge)
            let method = try nested.decode(String.self, forKey: .method)
            let expectedHeadOid = try nested.decodeIfPresent(
                String.self,
                forKey: .expectedHeadOid
            )
            // The tolerant read this whole hand-written coding exists for: a row queued before
            // the field existed carries no key, and "the user did not ask for a deletion" is the
            // only honest reading of that.
            let deletesHeadBranch = (try? nested.decodeIfPresent(
                Bool.self,
                forKey: .deletesHeadBranch
            )).flatMap { $0 } ?? false
            self = .merge(
                method: method,
                expectedHeadOid: expectedHeadOid,
                deletesHeadBranch: deletesHeadBranch
            )
        case .markReadyForReview:
            self = .markReadyForReview
        case .addPullRequestComment:
            let nested = try container.nestedContainer(
                keyedBy: PullRequestCommentKeys.self,
                forKey: .addPullRequestComment
            )
            let body = try nested.decode(String.self, forKey: .body)
            self = .addPullRequestComment(body: body)
        case .closePullRequest:
            let nested = try container.nestedContainer(
                keyedBy: ClosePullRequestKeys.self,
                forKey: .closePullRequest
            )
            let comment = try nested.decodeIfPresent(String.self, forKey: .comment)
            self = .closePullRequest(comment: comment)
        case .addIssueComment:
            let nested = try container.nestedContainer(
                keyedBy: IssueCommentKeys.self,
                forKey: .addIssueComment
            )
            let body = try nested.decode(String.self, forKey: .body)
            let updatedAt = try nested.decode(Date.self, forKey: .basedOnUpdatedAt)
            self = .addIssueComment(body: body, basedOnUpdatedAt: updatedAt)
        case .addIssueLabel:
            let nested = try container.nestedContainer(
                keyedBy: IssueLabelKeys.self,
                forKey: .addIssueLabel
            )
            let name = try nested.decode(String.self, forKey: .name)
            let updatedAt = try nested.decode(Date.self, forKey: .basedOnUpdatedAt)
            self = .addIssueLabel(name: name, basedOnUpdatedAt: updatedAt)
        case .addIssueAssignee:
            let nested = try container.nestedContainer(
                keyedBy: IssueAssigneeKeys.self,
                forKey: .addIssueAssignee
            )
            let login = try nested.decode(String.self, forKey: .login)
            let updatedAt = try nested.decode(Date.self, forKey: .basedOnUpdatedAt)
            self = .addIssueAssignee(login: login, basedOnUpdatedAt: updatedAt)
        case .closeIssue:
            let nested = try container.nestedContainer(
                keyedBy: CloseIssueKeys.self,
                forKey: .closeIssue
            )
            let reason = try nested.decode(IssueCloseReason.self, forKey: .reason)
            let updatedAt = try nested.decode(Date.self, forKey: .basedOnUpdatedAt)
            self = .closeIssue(reason: reason, basedOnUpdatedAt: updatedAt)
        case .reopenIssue:
            let nested = try container.nestedContainer(
                keyedBy: ReopenIssueKeys.self,
                forKey: .reopenIssue
            )
            let updatedAt = try nested.decode(Date.self, forKey: .basedOnUpdatedAt)
            self = .reopenIssue(basedOnUpdatedAt: updatedAt)
        }
    }
}

/// Where an outbox row is in its lifecycle.
public enum OutboxState: String, Sendable, Codable, Hashable, CaseIterable {
    /// Waiting to be sent, or waiting out a backoff.
    case pending
    /// Claimed by a drain and currently in flight.
    ///
    /// The claim is what makes the drain safe to call from several places at once: a row is
    /// moved out of ``pending`` inside the same write transaction that selects it, so a second
    /// drain overlapping the first can never pick the same row up and send it twice. Rows left
    /// in this state by a crash are reset to ``pending`` when the database is next opened.
    case sending
    /// Given up on: it failed in a way retrying cannot fix.
    case failed
    /// Not sent because the pull request moved on underneath it; needs the user to decide.
    case conflicted
    /// Sent successfully.
    case succeeded
}

/// One row of the outbox.
///
/// ``prID``, ``repo`` and ``number`` name **the target**, whichever kind of node that is. They
/// keep their pull-request names because renaming them would touch every existing call site for
/// no behavioural change, and because the prune guard already asks the generic question — "is
/// something queued against this id" (ADR 0032). ``OutboxAction/targetsIssue`` is how a reader
/// tells the two apart, and every issue call site says so in a comment where it fills the fields
/// in.
public struct OutboxItem: Sendable, Codable, Hashable, Identifiable {
    /// The row's local identity.
    public let id: UUID
    /// The node id of the target — the pull request's, or the issue's for an issue action
    /// (ADR 0032).
    public var prID: String
    /// The repository the target lives in.
    public var repo: RepoRef
    /// The target's number within its repository. GitHub draws issues and pull requests from one
    /// number sequence, so this means the same thing either way.
    public var number: Int
    /// What to do.
    public var action: OutboxAction
    /// When the row was enqueued.
    public var createdAt: Date
    /// How many times sending has been attempted.
    public var attemptCount: Int
    /// The earliest moment the next attempt may be made.
    public var nextAttemptAt: Date
    /// The last error message, in English, for the log — and for the UI only when
    /// ``lastErrorCode`` has nothing the app can read.
    public var lastError: String?
    /// The same error as a stable machine-readable string, when it had one.
    ///
    /// Opaque to this package: the sync engine writes a GitHub error's `storageCode` here, and
    /// the app decodes it back and says it in the user's language (ADR 0022, 2026-09-22
    /// amendment). `ShepherdCore` cannot hold the typed error itself — `GitHubKit` depends on it,
    /// not the other way round — and cannot call `String(localized:)` either, which is why the
    /// English sentence beside it can never be translated after the fact.
    public var lastErrorCode: String?
    /// The row's lifecycle state.
    public var state: OutboxState

    /// Creates an outbox row.
    public init(
        id: UUID = UUID(),
        prID: String,
        repo: RepoRef,
        number: Int,
        action: OutboxAction,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        nextAttemptAt: Date = Date(timeIntervalSince1970: 0),
        lastError: String? = nil,
        lastErrorCode: String? = nil,
        state: OutboxState = .pending
    ) {
        self.id = id
        self.prID = prID
        self.repo = repo
        self.number = number
        self.action = action
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.lastErrorCode = lastErrorCode
        self.state = state
    }
}

/// What became of one outbox row, read back after a drain.
///
/// The outbox already records this and has done since ADR 0006: a row that reached GitHub is
/// deleted, a row the drain parked is ``OutboxState/conflicted`` with its reason in
/// ``OutboxItem/lastError``, and a row the drain gave up on is ``OutboxState/failed`` with the
/// same. So this is a *reading* of the queue rather than a second record of it — the drain
/// returns nothing and needs to return nothing, and a caller that wants to know what happened to
/// the row it just wrote looks that row up afterwards.
///
/// It exists because "I queued it" and "it happened" are different sentences and a user who is
/// told the second one when only the first is true has been lied to: a parked review is followed
/// by an alert saying it was never sent.
public enum OutboxWriteOutcome: Sendable, Hashable {
    /// The row left the queue, which it only does by being sent.
    case sent
    /// Still queued — offline, waiting out a backoff, or in flight in a drain that has not come
    /// back yet. This is the ordinary local-first promise rather than a problem: the row is on
    /// disk and the engine keeps trying until it lands.
    case queued
    /// Parked because the target moved on underneath the write. It is never retried on its own,
    /// so only the user can move it from here.
    case parked(reason: String?)
    /// Given up on, because retrying cannot fix what went wrong.
    case failed(reason: String?)

    /// Reads the outcome off the row as the drain left it.
    ///
    /// **Correct only for an id no other caller can already know.** A missing row reads as
    /// ``sent`` because the drain deletes a row it sent — but so does *Discard* in
    /// Settings → Sync (`DatabaseManager.deleteOutboxItem(id:)`, ADR 0006's 2026-09-03
    /// amendment), and from here the two are indistinguishable. What makes the reading safe is
    /// the caller rather than the row: `PullRequestActions.enqueue` reads back only an id it has
    /// just minted and has handed to nobody, so nothing can have discarded that row in between.
    /// An id that came from somewhere a user could have reached — a list, a screen that has been
    /// open for a while — needs the row's own state instead.
    /// - Parameter row: The row as the outbox holds it now, or `nil` when it is no longer there.
    public init(row: OutboxItem?) {
        guard let row else {
            self = .sent
            return
        }
        switch row.state {
        case .pending, .sending:
            self = .queued
        case .conflicted:
            self = .parked(reason: row.lastError)
        case .failed:
            self = .failed(reason: row.lastError)
        case .succeeded:
            // No row is ever stored in this state — a sent row is deleted outright by the
            // store's `markOutboxItemSucceeded(id:)`, which is the `nil` above — but the case
            // exists in the model, and answering anything but "sent" for it would be wrong.
            self = .sent
        }
    }
}

/// The retry schedule for failed outbox rows.
///
/// Exponential with a ceiling: a GitHub outage must not turn into a request storm, and a
/// user who comes back after lunch must not wait an hour for their queued approval.
public enum OutboxBackoff {
    /// The delay before attempt number `attempt` (1-based).
    /// - Parameters:
    ///   - attempt: How many attempts have already failed.
    ///   - base: The delay after the first failure, in seconds. Defaults to 5.
    ///   - maximum: The ceiling, in seconds. Defaults to 15 minutes.
    /// - Returns: The delay in seconds.
    public static func delay(
        forAttempt attempt: Int,
        base: TimeInterval = 5,
        maximum: TimeInterval = 900
    ) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // Cap the exponent before it can overflow a Double for absurd attempt counts.
        let exponent = min(attempt - 1, 16)
        let delay = base * pow(2, Double(exponent))
        return min(maximum, delay)
    }
}
