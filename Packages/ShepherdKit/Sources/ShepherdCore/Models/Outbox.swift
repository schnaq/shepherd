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
    /// Merge the pull request.
    /// - Parameters:
    ///   - method: `"merge"`, `"squash"` or `"rebase"`. A raw string so that `ShepherdCore`
    ///     stays free of GitHub-specific types.
    ///   - expectedHeadOid: The head SHA the user saw, sent as a merge precondition.
    case merge(method: String, expectedHeadOid: String?)
    /// Take the pull request out of draft state.
    case markReadyForReview
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
             .markReadyForReview:
            return nil
        }
    }

    /// Whether the action targets an issue rather than a pull request.
    ///
    /// Which is also what decides how ``OutboxItem``'s three target fields are to be read — see
    /// that type's own note.
    public var targetsIssue: Bool { basedOnIssueUpdatedAt != nil }
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
    /// The last error message, for the UI and the log.
    public var lastError: String?
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
