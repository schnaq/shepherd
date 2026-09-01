import AppKit
import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// Every write Shepherd performs, funnelled through the persisted outbox.
///
/// ADR 0006 is explicit: outbound mutations are written to SQLite first and executed by the
/// sync engine, so an approval survives a crash, a quit or a tunnel. Nothing here calls
/// `GitHubClient` directly for a mutation that the outbox models.
@MainActor
struct PullRequestActions {
    /// The active session.
    let session: SignedInSession
    /// Where failures are surfaced.
    let toasts: ToastCenter
    /// Called with a pull request's node id the moment a *verdict* or a *merge* the user asked
    /// for has been written to the outbox — never for a reply, a thread toggle, or a viewed flag.
    ///
    /// This is the seam the focus review session advances on (``ReviewSession``), and it is
    /// deliberately here, beside the success toast, rather than in the drain: the session
    /// follows the *user's* action. Waiting for GitHub would stall the queue on a slow network,
    /// and a session driven by `mutationSent` would move again on every retry — including hours
    /// later, when the app has come back online and nobody is reviewing anything.
    ///
    /// `nil` for every caller that is not inside a session-capable screen, which is why adding
    /// it changed no existing call site.
    var onDidQueueVerdict: (@MainActor (String) -> Void)?

    /// Creates the write helper.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - toasts: Where failures are surfaced.
    ///   - onDidQueueVerdict: Called after a verdict or a merge reaches the outbox.
    init(
        session: SignedInSession,
        toasts: ToastCenter,
        onDidQueueVerdict: (@MainActor (String) -> Void)? = nil
    ) {
        self.session = session
        self.toasts = toasts
        self.onDidQueueVerdict = onDidQueueVerdict
    }

    // MARK: - Reviews

    /// Submits (or queues) a review for a pull request.
    ///
    /// An existing local draft is reused so a queued verdict never throws away inline comments
    /// the user already wrote.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - verdict: Approve, request changes, or comment.
    ///   - body: The review summary text.
    func submitReview(
        on summary: PullRequestSummary,
        verdict: ReviewVerdict,
        body: String = ""
    ) async {
        do {
            let existing = try await session.database.fetchDraft(prID: summary.id)
            let draft = ReviewDraft.verdict(
                verdict,
                on: summary,
                existing: existing,
                body: body
            )
            try await session.database.saveDraft(draft)
            try await enqueue(.submitReview(draft), on: summary)
            toasts.success(confirmation(for: verdict, summary: summary))
            onDidQueueVerdict?(summary.id)
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the review"))
        }
    }

    /// Replies to an existing review comment.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - commentDatabaseID: The REST database id of the comment being replied to.
    ///   - body: The reply text.
    func reply(
        on summary: PullRequestSummary,
        commentDatabaseID: Int,
        body: String
    ) async {
        do {
            try await enqueue(
                .replyToComment(commentDatabaseID: commentDatabaseID, body: body),
                on: summary
            )
            toasts.success(String(localized: "Reply queued."))
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the reply"))
        }
    }

    /// Resolves or unresolves a review thread.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - threadID: The thread's GraphQL node id.
    ///   - resolved: The state to move to.
    func setThread(
        on summary: PullRequestSummary,
        threadID: String,
        resolved: Bool
    ) async {
        do {
            try await enqueue(
                resolved ? .resolveThread(threadID: threadID) : .unresolveThread(threadID: threadID),
                on: summary
            )
            toasts.success(
                resolved
                    ? String(localized: "Thread resolved.")
                    : String(localized: "Thread reopened.")
            )
        } catch {
            toasts.failure(error, context: String(localized: "Could not update the thread"))
        }
    }

    // MARK: - Merge

    /// Merges a pull request.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - method: Merge, squash or rebase.
    func merge(_ summary: PullRequestSummary, method: MergeMethod) async {
        do {
            try await enqueue(
                .merge(method: method.rawValue, expectedHeadOid: summary.headRefOid),
                on: summary
            )
            toasts.success(String(localized: "Merge queued for \(summary.slug)."))
            onDidQueueVerdict?(summary.id)
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the merge"))
        }
    }

    // MARK: - Bulk triage (ADR 0015)

    /// What queueing a bulk-triage plan actually did, so the caller can say something true.
    struct BulkTriageOutcome: Sendable, Equatable {
        /// How many pull requests got at least one row into the outbox.
        var queuedPullRequests = 0
        /// How many outbox rows that amounted to (a merge behind an approval counts twice).
        var queuedWrites = 0
        /// How many selected pull requests the plan left out.
        var skipped = 0
        /// The pull requests whose rows could not be written locally, as `owner/repo#n`.
        var failed: [String] = []
    }

    /// Queues a whole bulk-triage plan through the ordinary outbox.
    ///
    /// There is no bulk endpoint and Shepherd invents none: a plan becomes *n* ordinary outbox
    /// rows, which is what gives every one of them the retry, offline and staleness behaviour a
    /// single approval has (ADR 0006, ADR 0015). The drain runs once at the end rather than per
    /// row, and so does the *write*: the whole batch is one transaction
    /// (``ShepherdPersistence/DatabaseManager/saveBulkTriage(writes:)``), so twenty approvals
    /// cost one commit and one drain instead of forty and twenty. Webhooks need nothing here —
    /// they hang off `mutationSent`, after each row really reached GitHub (ADR 0012).
    /// - Parameters:
    ///   - plan: The confirmed plan.
    ///   - method: The merge method for whatever the plan merges.
    /// - Returns: What was queued, for the summary toast.
    @discardableResult
    func queue(_ plan: BulkTriagePlan, method: MergeMethod) async -> BulkTriageOutcome {
        var outcome = BulkTriageOutcome(skipped: plan.skipped.count)
        guard plan.isActionable else {
            toasts.info(String(localized: "Nothing to queue — every selected pull request was skipped."))
            return outcome
        }

        let writes = plan.writes(
            mergeMethod: method.rawValue,
            existingDrafts: await existingDrafts(for: plan)
        )
        do {
            // Every draft and every row in one transaction, each draft still written before the
            // row that carries it. A local write failure is a broken database rather than one
            // unlucky pull request, so the batch is all or nothing: better a run the user can
            // retry whole than an approval queued without the merge that was meant to follow it.
            try await session.database.saveBulkTriage(writes: writes)
            outcome.queuedWrites = writes.count
            outcome.queuedPullRequests = Set(writes.map(\.item.prID)).count
        } catch {
            // Reported in the plan's order, not a set's, so the message is reproducible.
            outcome.failed = plan.eligible.map(\.pullRequest.slug)
        }

        await session.drainOutbox()
        report(outcome, action: plan.action)
        return outcome
    }

    /// The drafts already on disk for the plan's eligible pull requests.
    ///
    /// Read up front, and in one query, so a bulk approval reuses inline comments the user wrote
    /// earlier instead of replacing the draft that holds them.
    ///
    /// A read failure yields no drafts rather than an error: the plan is still queueable, it
    /// simply cannot reuse anything, which is what would have happened for an absent draft too.
    private func existingDrafts(for plan: BulkTriagePlan) async -> [String: ReviewDraft] {
        let ids = plan.eligible.map(\.id)
        return (try? await session.database.fetchDrafts(prIDs: ids)) ?? [:]
    }

    private func report(_ outcome: BulkTriageOutcome, action: BulkTriageAction) {
        if outcome.queuedPullRequests > 0 {
            let count = outcome.queuedPullRequests
            let suffix = outcome.skipped > 0
                ? String(localized: " · \(outcome.skipped) skipped")
                : ""
            switch action {
            case .approve:
                toasts.success(String(localized: "Queued \(count) approvals\(suffix)."))
            case .approveAndMerge:
                toasts.success(String(localized: "Queued \(count) approvals and merges\(suffix)."))
            case .merge:
                toasts.success(String(localized: "Queued \(count) merges\(suffix)."))
            }
        }
        guard !outcome.failed.isEmpty else { return }
        toasts.show(
            Toast(
                message: String(
                    localized: "Could not queue \(outcome.failed.count) of them: \(outcome.failed.joined(separator: ", "))"
                ),
                kind: .failure,
                duration: 8
            )
        )
    }

    /// Takes a pull request out of draft state.
    /// - Parameter summary: The pull request.
    func markReadyForReview(_ summary: PullRequestSummary) async {
        do {
            try await enqueue(.markReadyForReview, on: summary)
            toasts.success(String(localized: "Marked ready for review."))
        } catch {
            toasts.failure(error, context: String(localized: "Could not update the pull request"))
        }
    }

    // MARK: - Local conveniences

    /// Opens the pull request on github.com.
    /// - Parameter summary: The pull request.
    func openOnGitHub(_ summary: PullRequestSummary) {
        NSWorkspace.shared.open(
            AppConfig.pullRequestURL(
                owner: summary.repo.owner,
                name: summary.repo.name,
                number: summary.number
            )
        )
    }

    /// Copies the head branch name to the pasteboard.
    /// - Parameter summary: The pull request.
    func copyBranch(_ summary: PullRequestSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.headRefName, forType: .string)
        toasts.info(String(localized: "Copied \(summary.headRefName)"))
    }

    /// Marks a file viewed (or not) for the current head commit.
    /// - Parameters:
    ///   - path: The file path.
    ///   - summary: The pull request.
    ///   - isViewed: The new state.
    func setFileViewed(path: String, on summary: PullRequestSummary, isViewed: Bool) async {
        do {
            try await session.database.setFileViewed(
                prID: summary.id,
                path: path,
                headRefOid: summary.headRefOid,
                isViewed: isViewed
            )
        } catch {
            toasts.failure(error, context: String(localized: "Could not save the viewed state"))
        }
    }

    // MARK: - Plumbing

    private func enqueue(_ action: OutboxAction, on summary: PullRequestSummary) async throws {
        try await session.database.enqueue(
            OutboxItem(
                prID: summary.id,
                repo: summary.repo,
                number: summary.number,
                action: action
            )
        )
        await session.drainOutbox()
    }

    private func confirmation(
        for verdict: ReviewVerdict,
        summary: PullRequestSummary
    ) -> String {
        switch verdict {
        case .approve: return String(localized: "Approved \(summary.slug).")
        case .requestChanges: return String(localized: "Requested changes on \(summary.slug).")
        case .comment: return String(localized: "Review comment queued for \(summary.slug).")
        }
    }
}
