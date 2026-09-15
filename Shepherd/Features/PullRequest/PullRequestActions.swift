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
///
/// Every toast here is worded by what the drain *did* with the row rather than by what the user
/// asked for. The drain can park a write as a conflict or give up on it, and a screen that says
/// "Approved schnaq/review#182." either way is followed a second later by an alert saying the
/// review was never sent — so the outcome is read back off the queue and the sentence chosen
/// from it (``ShepherdCore/OutboxWriteOutcome``, ``enqueue(_:on:)``).
@MainActor
struct PullRequestActions {
    /// The active session.
    let session: SignedInSession
    /// Where failures are surfaced.
    let toasts: ToastCenter
    /// Which writes are already in flight.
    ///
    /// The funnel is where this belongs rather than in the buttons: a pull request is approved
    /// from the inbox panel, the composer bar, ⌘K and a keyboard shortcut, and only the funnel
    /// sees all four. Every write below marks its key for as long as it runs, so the button that
    /// started it can go quiet — and a second press of any of the four is refused here even if
    /// the surface that raised it never looked.
    let activity: ActionActivity
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
    /// Whether a *successful* enqueue puts a toast on screen. Failures always do.
    ///
    /// True for everything a human asked for — the toast is the confirmation of their keystroke.
    /// False for automatic merging (ADR 0018), which announces a whole pass in one notification
    /// and records every merge in its audit log: one toast per row would put a dozen banners on
    /// screen for a pass nobody was watching, which is the sibling of the argument
    /// ``PullRequestActions/queue(_:method:)`` makes about draining once for a batch.
    var announcesSuccess = true

    /// Creates the write helper.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - toasts: Where failures are surfaced.
    ///   - activity: Which writes are already in flight. No default: a helper built without it
    ///     would be a surface whose buttons stay clickable, which is the bug this closed.
    ///   - onDidQueueVerdict: Called after a verdict or a merge reaches the outbox.
    ///   - announcesSuccess: Whether a successful enqueue toasts. Failures always do.
    init(
        session: SignedInSession,
        toasts: ToastCenter,
        activity: ActionActivity,
        onDidQueueVerdict: (@MainActor (String) -> Void)? = nil,
        announcesSuccess: Bool = true
    ) {
        self.session = session
        self.toasts = toasts
        self.activity = activity
        self.onDidQueueVerdict = onDidQueueVerdict
        self.announcesSuccess = announcesSuccess
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
    /// - Returns: `false` when GitHub would have refused the verdict and nothing was written,
    ///   `true` in every case where the review reached the local database. Callers that hold the
    ///   text the user typed — ``ReviewModel/submit(verdict:actions:)`` and the sheet above it —
    ///   must keep it on `false`: a refusal happens *before* ``ReviewDraft`` is saved, so this is
    ///   the only signal that the summary is not on disk anywhere yet. A second call while the
    ///   first is still running is `false` for the same reason and by the same rule — nothing was
    ///   written, so the summary stays in the field.
    @discardableResult
    func submitReview(
        on summary: PullRequestSummary,
        verdict: ReviewVerdict,
        body: String = ""
    ) async -> Bool {
        await activity.run(summary.id, .review) {
            // The one place every verdict passes through, so it is the one place that has to know
            // what GitHub will refuse.
            if let blocker = Self.refusal(of: verdict, on: summary) {
                toasts.show(
                    Toast(message: Self.blockerMessage(blocker, slug: summary.slug), kind: .warning)
                )
                return false
            }
            do {
                let existing = try await session.database.fetchDraft(prID: summary.id)
                let draft = ReviewDraft.verdict(
                    verdict,
                    on: summary,
                    existing: existing,
                    body: body
                )
                try await session.database.saveDraft(draft)
                let outcome = try await enqueue(.submitReview(draft), on: summary)
                announce(outcome, of: .review(verdict), on: summary)
                onDidQueueVerdict?(summary.id)
            } catch {
                toasts.failure(error, context: String(localized: "Could not queue the review"))
            }
            // `true` even after a local write failure, and deliberately: whichever of the two
            // writes threw, ``ReviewDraft/verdict(_:on:existing:body:at:)`` was built from the
            // text and a saved draft is restored by ``ReviewModel``'s draft observation. Only the
            // refusal above returns before anything has been written at all.
            return true
        } ?? false
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
        await activity.run(summary.id, .reply) {
            do {
                let outcome = try await enqueue(
                    .replyToComment(commentDatabaseID: commentDatabaseID, body: body),
                    on: summary
                )
                announce(outcome, of: .reply, on: summary)
            } catch {
                toasts.failure(error, context: String(localized: "Could not queue the reply"))
            }
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
        // Keyed by the *thread*, not the pull request: a card can show a dozen conversations,
        // and resolving one of them is no reason for the other eleven buttons to report a write.
        await activity.run(threadID, .thread) {
            do {
                let outcome = try await enqueue(
                    resolved
                        ? .resolveThread(threadID: threadID)
                        : .unresolveThread(threadID: threadID),
                    on: summary
                )
                announce(outcome, of: .thread(resolved: resolved), on: summary)
            } catch {
                toasts.failure(error, context: String(localized: "Could not update the thread"))
            }
        }
    }

    // MARK: - Conversation

    /// Posts a comment on the pull request's conversation.
    ///
    /// The conversation and not a review: this is GitHub's *Comment* button, which writes an
    /// issue comment. A `COMMENT` review — ``submitReview(on:verdict:body:)`` with
    /// ``ShepherdCore/ReviewVerdict/comment`` — is the other thing, and says "I looked at the
    /// diff and have no verdict"; this one says something about the pull request.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - body: The comment as Markdown source.
    func comment(on summary: PullRequestSummary, body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let outcome = try await enqueue(.addPullRequestComment(body: trimmed), on: summary)
            announce(outcome, of: .comment, on: summary)
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the comment"))
        }
    }

    /// Closes the pull request, with or without a comment.
    ///
    /// One row for both halves rather than a comment row and a close row, because "comment and
    /// close" is one intent: two rows could be drained by two Macs or in two sweeps, and a pull
    /// request closed by the machine whose comment was still queued is a close with its reason
    /// missing. The drain closes first and comments second, which is what makes a retry after a
    /// half-failure safe.
    ///
    /// No verdict callback: closing is not a review, so a focus session does not advance on it.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - comment: What to say while closing, or `nil` to close without a word.
    func close(_ summary: PullRequestSummary, comment: String? = nil) async {
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            let outcome = try await enqueue(.closePullRequest(comment: body), on: summary)
            announce(outcome, of: .close(withComment: body != nil), on: summary)
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the close"))
        }
    }

    // MARK: - Merge

    /// Merges a pull request.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - method: Merge, squash or rebase.
    ///   - deletesHeadBranch: Whether to delete the head branch once the merge has landed
    ///     (ADR 0005's 2026-09-05 amendment). Defaults to `false`, which is what the automatic
    ///     rules get: ADR 0018 lets a rule *record* a decision a human made, and a deletion
    ///     nobody ticked would be a wider decision than the approval it stands on.
    func merge(
        _ summary: PullRequestSummary,
        method: MergeMethod,
        deletesHeadBranch: Bool = false
    ) async {
        await activity.run(summary.id, .merge) {
            // Same refusal, before the row is written rather than after the drain has been told
            // "Pull Request is still a draft" — the outbox was carrying exactly that failure.
            if let blocker = summary.mergeBlocker {
                toasts.show(
                    Toast(message: Self.blockerMessage(blocker, slug: summary.slug), kind: .warning)
                )
                return
            }
            do {
                let outcome = try await enqueue(
                    .merge(
                        method: method.rawValue,
                        expectedHeadOid: summary.headRefOid,
                        deletesHeadBranch: deletesHeadBranch
                    ),
                    on: summary
                )
                announce(outcome, of: .merge, on: summary)
                onDidQueueVerdict?(summary.id)
            } catch {
                toasts.failure(error, context: String(localized: "Could not queue the merge"))
            }
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
    /// - Returns: What was queued, for the summary toast. An empty outcome when a run was
    ///   already in flight: nothing was written, so there is nothing to report.
    @discardableResult
    func queue(_ plan: BulkTriagePlan, method: MergeMethod) async -> BulkTriageOutcome {
        // Keyed `"bulk"` rather than per pull request, because that is what a second click would
        // duplicate: the plan is one gesture over *n* rows, and two runs of it are 2n rows.
        await activity.run("bulk", .bulk) {
            var outcome = BulkTriageOutcome(skipped: plan.skipped.count)
            guard plan.isActionable else {
                toasts.info(
                    String(localized: "Nothing to queue — every selected pull request was skipped.")
                )
                return outcome
            }

            let writes = plan.writes(
                mergeMethod: method.rawValue,
                existingDrafts: await existingDrafts(for: plan)
            )
            do {
                // Every draft and every row in one transaction, each draft still written before
                // the row that carries it. A local write failure is a broken database rather than
                // one unlucky pull request, so the batch is all or nothing: better a run the user
                // can retry whole than an approval queued without the merge meant to follow it.
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
        } ?? BulkTriageOutcome()
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
        await activity.run(summary.id, .readyForReview) {
            do {
                let outcome = try await enqueue(.markReadyForReview, on: summary)
                announce(outcome, of: .readyForReview, on: summary)
            } catch {
                toasts.failure(
                    error,
                    context: String(localized: "Could not update the pull request")
                )
            }
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
        // Keyed on the pull request rather than on the path: one file is selected at a time, so
        // the toggle and the `v` shortcut are the same button and cannot mean two files at once.
        await activity.run(summary.id, .viewed) {
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
    }

    // MARK: - What the user asked for

    /// Which write a toast is about, in the terms the user pressed a button in.
    ///
    /// A small enum of its own rather than the ``ShepherdCore/OutboxAction`` the row carries: the
    /// sentence is about what the *person* asked for, and two actions the outbox barely tells
    /// apart — resolving a thread and reopening one — are two different pieces of news.
    enum WriteKind: Sendable, Hashable {
        /// A review verdict.
        case review(ReviewVerdict)
        /// A reply to an existing review comment.
        case reply
        /// A review thread resolved (`true`) or reopened (`false`).
        case thread(resolved: Bool)
        /// A merge.
        case merge
        /// Taking the pull request out of draft state.
        case readyForReview
        /// A comment on the pull request's conversation.
        case comment
        /// Closing the pull request, with or without a comment.
        case close(withComment: Bool)
    }

    /// Why this verdict would be refused on this pull request, or `nil` when it would not.
    ///
    /// A plain comment is exempt from everything: `COMMENT` on your own pull request is accepted,
    /// and only `APPROVE` and `REQUEST_CHANGES` come back as a 422. Pure and `static` so the one
    /// rule the funnel turns on can be asserted without a ``SignedInSession``.
    /// - Parameters:
    ///   - verdict: What the user asked for.
    ///   - summary: The pull request it targets.
    /// - Returns: The blocker, or `nil` when the verdict may be written.
    static func refusal(
        of verdict: ReviewVerdict,
        on summary: PullRequestSummary
    ) -> ReviewActionBlocker? {
        guard verdict != .comment else { return nil }
        return summary.verdictBlocker
    }

    /// What to tell a user whose click GitHub would have refused.
    ///
    /// `static` and pure for the reason the outcome wording below is: the sentence is the whole
    /// of what this path produces, and the app's tests cannot build a ``SignedInSession``. Each
    /// surface that greys a button out uses it as the button's tooltip, so the explanation the
    /// user hovers and the toast they would have got are the same sentence.
    /// - Parameters:
    ///   - blocker: What GitHub would refuse.
    ///   - slug: The pull request, as `owner/repo#123`.
    /// - Returns: One sentence naming the pull request and the way out of it.
    static func blockerMessage(_ blocker: ReviewActionBlocker, slug: String) -> String {
        switch blocker {
        case .draft:
            return String(
                localized: "\(slug) is still a draft — GitHub refuses the merge until it is marked ready for review."
            )
        case .conflicting:
            return String(localized: "\(slug) has conflicts with its base branch. Resolve them first.")
        case .ownPullRequest:
            return String(
                localized: "GitHub does not accept an approve or request changes on your own pull request (\(slug))."
            )
        }
    }

    /// A button's tooltip: why GitHub would refuse it, or what it usually says.
    ///
    /// Four surfaces greyed a button out and each wrote the same two lines — "is there a blocker,
    /// then ``blockerMessage(_:slug:)``, otherwise the shortcut" — around the inbox panel's
    /// buttons, the review composer's verdicts, the submit sheet and the review header's Merge.
    /// One function, because the rule is one rule: a dark button whose reason lives only in a
    /// toast the user never triggers explains nothing, and a tooltip that falls back to its
    /// shortcut is what makes hovering worth doing on a button that *is* live.
    /// - Parameters:
    ///   - blocker: What GitHub would refuse, or `nil` when it would refuse nothing.
    ///   - summary: The pull request the button acts on, for the slug the sentence names.
    ///   - otherwise: The tooltip for a button that is live.
    /// - Returns: The tooltip text.
    static func help(
        for blocker: ReviewActionBlocker?,
        on summary: PullRequestSummary,
        otherwise: String
    ) -> String {
        guard let blocker else { return otherwise }
        return blockerMessage(blocker, slug: summary.slug)
    }

    /// The toast an outcome deserves, or `nil` when that outcome is announced elsewhere.
    ///
    /// `static` and pure so the wording can be asserted on its own. The app's tests cannot build
    /// a ``SignedInSession`` — it wants the Keychain and the real database file — and the wording
    /// is the whole point of this path, so it is written where a test can reach it.
    /// - Parameters:
    ///   - outcome: What the drain did with the row.
    ///   - write: What the user asked for.
    ///   - slug: The pull request, as `owner/repo#123`.
    /// - Returns: The toast to show, or `nil` when nothing is to be said here.
    static func announcement(
        for outcome: OutboxWriteOutcome,
        of write: WriteKind,
        slug: String
    ) -> Toast? {
        switch outcome {
        case .sent:
            guard let message = sentMessage(write, slug: slug) else { return nil }
            return Toast(message: message, kind: .success)
        case .queued:
            return Toast(message: queuedMessage(write, slug: slug), kind: .success)
        case .parked:
            // A warning rather than a failure, because nothing is lost: the draft is still on
            // disk, and the alert this sentence points at is where it is re-applied or discarded
            // (``DraftConflictQueue``, ADR 0006). The reason the row carries is not shown — it
            // names two commit SHAs, and "the pull request changed" is the part a person acts on.
            return Toast(message: parkedMessage(write, slug: slug), kind: .warning, duration: 8)
        case .failed(let reason):
            let sentence = failedMessage(write, slug: slug)
            // The shape ``ToastCenter/failure(_:context:)`` builds, for its reason: what GitHub
            // or the drain said is one untranslated sentence from somewhere else, so it is
            // appended after the translated one rather than interpolated into it.
            return Toast(
                message: reason.map { "\(sentence): \($0)" } ?? sentence,
                kind: .failure,
                duration: 8
            )
        }
    }

    /// What to say about a write that actually reached GitHub.
    private static func sentMessage(_ write: WriteKind, slug: String) -> String? {
        switch write {
        case .review(.approve):
            return String(localized: "Approved \(slug).")
        case .review(.requestChanges):
            return String(localized: "Requested changes on \(slug).")
        case .review(.comment):
            return String(localized: "Commented on \(slug).")
        case .reply:
            return String(localized: "Reply sent.")
        case .thread(let resolved):
            return resolved
                ? String(localized: "Thread resolved.")
                : String(localized: "Thread reopened.")
        case .merge:
            // Said once, from the other end: a merge that lands is announced by
            // `AppEnvironment.handle(_:)` off ``ShepherdSync/SyncEvent/mutationSent(_:)``, which
            // is also the only thing that can announce a merge a *later* drain sent. Saying it
            // here as well would put two toasts on screen for one merge.
            return nil
        case .readyForReview:
            return String(localized: "Marked ready for review.")
        case .comment:
            return String(localized: "Comment posted on \(slug).")
        case .close(let withComment):
            return withComment
                ? String(localized: "Commented and closed \(slug).")
                : String(localized: "Closed \(slug).")
        }
    }

    /// What to say about a write that is on disk but has not landed yet.
    ///
    /// Not a failure and not a lie: an offline approval, a backoff or a drain that is still
    /// running is the ordinary local-first promise (ADR 0006), and the queue keeps it.
    private static func queuedMessage(_ write: WriteKind, slug: String) -> String {
        switch write {
        case .review(.approve):
            return String(localized: "Approval queued for \(slug).")
        case .review(.requestChanges):
            return String(localized: "Change request queued for \(slug).")
        case .review(.comment):
            return String(localized: "Review comment queued for \(slug).")
        case .reply:
            return String(localized: "Reply queued.")
        case .thread:
            // One sentence for both directions: which way the toggle went is on screen behind
            // the toast, and "queued" is the whole of what this adds to it.
            return String(localized: "Thread update queued.")
        case .merge:
            return String(localized: "Merge queued for \(slug).")
        case .readyForReview:
            return String(localized: "Ready for review queued.")
        case .comment:
            return String(localized: "Comment queued for \(slug).")
        case .close:
            // One sentence for both, and it names the close rather than the comment: the close
            // is the part that changes what the pull request *is*, and the comment goes with it
            // in the same row either way.
            return String(localized: "Close queued for \(slug).")
        }
    }

    /// What to say about a write the drain parked because the pull request moved on.
    private static func parkedMessage(_ write: WriteKind, slug: String) -> String {
        switch write {
        case .review:
            return String(
                localized: "Review held back — \(slug) changed since you started. See the alert."
            )
        case .merge:
            return String(
                localized: "Merge held back — \(slug) changed since you started. See the alert."
            )
        case .comment, .close:
            // Nothing parks these two either: neither is pinned to the head commit, and a
            // comment says what it says however the pull request has moved since.
            return String(localized: "Not sent — \(slug) changed since you started.")
        case .reply, .thread, .readyForReview:
            // Nothing parks these three today — only a review draft and a merge are checked
            // against the head commit — but the outcome is read off the queue rather than
            // guessed, so the sentence exists for the day the drain learns to park one of them.
            // It points at no alert, because only a parked *review* raises one (ADR 0006).
            return String(localized: "Not sent — \(slug) changed since you started.")
        }
    }

    /// What to say about a write the drain gave up on. No full stop: a reason is appended.
    private static func failedMessage(_ write: WriteKind, slug: String) -> String {
        switch write {
        case .review:
            return String(localized: "Could not send the review for \(slug)")
        case .reply:
            return String(localized: "Could not send the reply to \(slug)")
        case .thread:
            return String(localized: "Could not update the thread on \(slug)")
        case .merge:
            return String(localized: "Could not merge \(slug)")
        case .readyForReview:
            return String(localized: "Could not mark \(slug) ready for review")
        case .comment:
            return String(localized: "Could not comment on \(slug)")
        case .close:
            return String(localized: "Could not close \(slug)")
        }
    }

    // MARK: - Plumbing

    /// Shows the toast the outcome deserves.
    ///
    /// ``announcesSuccess`` gates the two outcomes that are merely the queue doing its job —
    /// sent and still queued — and never the two that need somebody: a pass nobody watched
    /// (ADR 0018) still has to say when its write was parked or refused, which is exactly what
    /// that property has always claimed.
    /// - Parameters:
    ///   - outcome: What the drain did with the row.
    ///   - write: What the user asked for.
    ///   - summary: The pull request it targeted.
    private func announce(
        _ outcome: OutboxWriteOutcome,
        of write: WriteKind,
        on summary: PullRequestSummary
    ) {
        switch outcome {
        case .sent, .queued:
            guard announcesSuccess else { return }
        case .parked, .failed:
            break
        }
        guard let toast = Self.announcement(for: outcome, of: write, slug: summary.slug) else {
            return
        }
        toasts.show(toast)
    }

    /// Writes one row, drains, and reads back what became of *that* row.
    ///
    /// The read is the whole mechanism. ``ShepherdSync/SyncEngine/drainOutbox()`` returns nothing
    /// and needs to return nothing: the queue already records every outcome ADR 0006 defines — a
    /// sent row is deleted, a parked one is ``ShepherdCore/OutboxState/conflicted`` with its
    /// reason, a refused one is ``ShepherdCore/OutboxState/failed`` with GitHub's — so the row
    /// this call just wrote is looked up by its own id afterwards. Reading the store rather than
    /// plumbing an outcome out of the engine also answers correctly when a *concurrent* drain was
    /// the one that sent the row, which a return value could not.
    /// - Parameters:
    ///   - action: The mutation.
    ///   - summary: The pull request it targets.
    /// - Returns: What became of the row.
    /// - Throws: When the local write fails — the one failure that is not an outcome, because
    ///   nothing was queued at all.
    private func enqueue(
        _ action: OutboxAction,
        on summary: PullRequestSummary
    ) async throws -> OutboxWriteOutcome {
        let item = OutboxItem(
            prID: summary.id,
            repo: summary.repo,
            number: summary.number,
            action: action
        )
        try await session.database.enqueue(item)
        await session.drainOutbox()
        do {
            let row = try await session.database.outboxItem(id: item.id)
            return OutboxWriteOutcome(row: row)
        } catch {
            // The row was written and only the read back failed, so "still queued" is both the
            // honest answer and the one that promises least.
            return .queued
        }
    }
}
