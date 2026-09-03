import Foundation
import ShepherdCore
import ShepherdPersistence
import ShepherdSync

/// What one of Shepherd's own events amounts to on the wire.
///
/// Producing this is the only interesting decision in the whole feature — *which* internal
/// event counts as which outbound event, and which ones count as nothing — so it is a value,
/// built by a pure function, and the tests assert on it directly.
struct WebhookPlan: Sendable, Equatable {
    /// Which outbound event to send.
    var kind: WebhookEventKind
    /// The event-specific payload.
    var details: WebhookEventDetails
    /// How to name (or look up) the target.
    ///
    /// Named for the pull request it usually is; an issue-shaped event reuses the same three
    /// fields for the issue's node id, repository and number, exactly as
    /// ``ShepherdCore/OutboxItem`` reuses its own (ADR 0032).
    var identity: WebhookPullRequest.Identity
    /// The pull request, when the internal event already carried it. When `nil`, the
    /// coordinator reads it out of the local database before sending.
    var summary: PullRequestSummary?
    /// The issue, when the internal event already carried it. Only ever set for a plan whose
    /// ``WebhookEventKind/isAboutAnIssue`` is `true`; `nil` there means the coordinator reads the
    /// row out of the local database before sending, and falls back to the identity when the
    /// sweep has already pruned it.
    var issue: WebhookIssue?
    /// When the thing happened.
    var occurredAt: Date
}

/// Turns Shepherd's internal events into outbound webhook deliveries (ADR 0012).
///
/// The mapping is deliberately narrow. Only events that mean **something definitely happened**
/// are mapped:
///
/// - `review.submitted` and `pr.merged` come from ``ShepherdSync/SyncEvent/mutationSent(_:)``,
///   i.e. from the outbox drain — not from the key press that queued the review. A queued
///   approval that is still waiting out a backoff has not approved anything yet.
/// - `pr.merged` therefore fires only for merges *Shepherd* performed.
///   ``ShepherdSync/SyncEvent/prMerged(_:)`` is not mapped even though the name matches: a
///   sweep of *open* pull requests cannot tell a merge from a close, and an automation that
///   reacts to "merged" must not be handed a pull request somebody abandoned.
/// - `delegation.finished` comes from ``DelegationModel``'s terminal state, once per run, and
///   says whether a rule started it (`details.automatic`, additive under `"v": 1` — ADR 0016).
/// - `inbox.new_review_request` comes from the sweep's own once-per-pull-request discovery.
/// - `pr.auto_merge_queued` is the single, deliberate exception (ADR 0018): it reports that
///   Shepherd *decided* to merge something unattended, which is a fact at the enqueue. The merge
///   reaching GitHub is still reported separately, by `pr.merged` from the drain.
/// - `issue.closed` comes from `mutationSent` too (ADR 0032's Sprint 4a amendment), which is why
///   it is the *close* that is an event and not the comment, the label, the assignee or the
///   reopen queued beside it: those four are sent by the same drain and are deliberately mapped
///   to nothing, because v1 promised no event for them and adding one later is additive.
///
/// Everything else — thread replies, resolves, "ready for review", CI failures, sync
/// failures, generic updates — is not an event this version promises, and mapping it later is
/// an additive change.
@MainActor
final class WebhookCoordinator {
    private let dispatcher: WebhookDispatcher
    private let settings: AppSettings
    private let secretStore: KeychainSecretStore

    /// Creates a coordinator.
    /// - Parameters:
    ///   - dispatcher: The delivery mechanism.
    ///   - settings: Where the non-secret configuration lives.
    ///   - secretStore: Where the shared secret lives (Keychain only).
    init(
        dispatcher: WebhookDispatcher,
        settings: AppSettings,
        secretStore: KeychainSecretStore
    ) {
        self.dispatcher = dispatcher
        self.settings = settings
        self.secretStore = secretStore
    }

    /// The configuration as it stands right now.
    ///
    /// Assembled per delivery rather than cached, so turning the toggle off takes effect on the
    /// very next event and the secret is only ever held for the length of one POST.
    var configuration: WebhookConfiguration {
        var configuration = gateConfiguration
        configuration.secret = storedSecret()
        return configuration
    }

    /// Everything the delivery gate looks at, and nothing that costs anything to read.
    ///
    /// Split out from ``configuration`` because ``WebhookConfiguration/wantsEvent(_:)`` never
    /// consults the secret: the decision is identical either way, and taking it from these three
    /// `UserDefaults`-backed values keeps the Keychain out of the path of every event Shepherd
    /// does *not* deliver.
    private var gateConfiguration: WebhookConfiguration {
        WebhookConfiguration(
            isEnabled: settings.webhooksEnabled,
            urlText: settings.webhookURL,
            events: settings.webhookEvents
        )
    }

    /// The shared secret, or an empty string when there is none or the Keychain refuses.
    ///
    /// An unreadable Keychain means an unsigned delivery rather than no delivery: the receiver
    /// decides whether it accepts one, and dropping the event outright would lose it silently.
    private func storedSecret() -> String {
        ((try? secretStore.secret(for: KeychainSecretStore.Key.webhookSecret)) ?? nil) ?? ""
    }

    /// Handles a sync event.
    /// - Parameters:
    ///   - event: The event the sync engine emitted.
    ///   - database: The local cache, used to fill in the pull request the event only named.
    func handle(_ event: SyncEvent, database: DatabaseManager?) {
        guard let plan = WebhookCoordinator.plan(for: event) else { return }
        dispatch(plan, database: database)
    }

    /// Handles a merge an auto-merge rule just queued (ADR 0018).
    /// - Parameters:
    ///   - queued: What was queued, with the audit line that justified it.
    ///   - database: Unused for this event — the plan already carries the pull request — and taken
    ///     only so every `handle` on this type reads the same way.
    func handle(_ queued: AutoMergeQueuedWrite, database: DatabaseManager?) {
        dispatch(WebhookCoordinator.plan(for: queued), database: database)
    }

    /// Handles a finished delegation (ADR 0011).
    /// - Parameters:
    ///   - outcome: How the run ended.
    ///   - database: The local cache, used to describe the pull request.
    func handle(_ outcome: DelegationOutcome, database: DatabaseManager?) {
        dispatch(WebhookCoordinator.plan(for: outcome), database: database)
    }

    /// Sends the test event and reports the result.
    /// - Parameter secret: When given, signs with this instead of the stored one, so a freshly
    ///   pasted secret can be tested before it is written to the Keychain.
    /// - Throws: ``WebhookError`` when nothing arrived.
    func sendTestEvent(secret: String? = nil) async throws {
        var configuration = self.configuration
        if let secret { configuration.secret = secret }
        try await dispatcher.deliverTestEvent(configuration: configuration)
    }

    // MARK: - Dispatch

    private func dispatch(_ plan: WebhookPlan, database: DatabaseManager?) {
        // The gate comes first, and reads only `UserDefaults`: with the feature off — or with
        // this event unsubscribed — an event costs a `Bool`, a URL parse and a set lookup. No
        // Keychain round trip, no task, no database read.
        var configuration = gateConfiguration
        guard configuration.wantsEvent(plan.kind) else { return }
        // Only an event that is definitely going out is worth the cross-process Keychain read,
        // and the secret is held no longer than the POST that uses it.
        configuration.secret = storedSecret()
        // Detached on purpose. The caller is the sync engine's event loop or a delegation
        // sheet, and neither may end up waiting on a stranger's HTTP server. `configuration` is
        // captured by value so the task carries the settings as they were when the event
        // happened, rather than reading them again after the fact.
        Task { [dispatcher, configuration] in
            let subject: WebhookEvent.Subject
            if plan.kind.isAboutAnIssue {
                var issue = plan.issue
                if issue == nil, let database,
                   let row = try? await database.fetchIssueSummary(id: plan.identity.prID) {
                    issue = WebhookIssue(summary: row)
                }
                // Closing an issue is exactly what makes the next sweep prune its row, so the
                // fallback here is a normal path rather than a defensive one.
                subject = .issue(issue ?? WebhookIssue(identity: plan.identity))
            } else {
                var summary = plan.summary
                if summary == nil, let database {
                    summary = try? await database.fetchPullRequestSummary(id: plan.identity.prID)
                }
                subject = .pullRequest(
                    summary.map(WebhookPullRequest.init(summary:))
                        ?? WebhookPullRequest(identity: plan.identity)
                )
            }
            await dispatcher.deliver(
                WebhookEvent(
                    event: plan.kind,
                    subject: subject,
                    details: plan.details,
                    occurredAt: plan.occurredAt
                ),
                configuration: configuration
            )
        }
    }

    // MARK: - Mapping

    /// The outbound event a sync event amounts to, if any.
    /// - Parameters:
    ///   - event: The sync event.
    ///   - now: The clock, for events whose timestamp is "when Shepherd noticed".
    /// - Returns: The plan, or `nil` when this event is not one webhooks promise.
    nonisolated static func plan(for event: SyncEvent, now: Date = Date()) -> WebhookPlan? {
        switch event {
        case .newReviewRequest(let summary):
            return WebhookPlan(
                kind: .newReviewRequest,
                details: .newReviewRequest(
                    // Sorted because `myRelation` is a `Set`: an unordered source must not
                    // produce a payload that differs between two identical events.
                    relations: summary.myRelation.map(\.rawValue).sorted(),
                    reviewDecision: summary.reviewDecision?.rawValue,
                    checks: summary.checkRollup?.state.rawValue
                ),
                identity: WebhookPullRequest.Identity(
                    prID: summary.id,
                    repo: summary.repo,
                    number: summary.number
                ),
                summary: summary,
                occurredAt: now
            )

        case .mutationSent(let sent):
            let identity = WebhookPullRequest.Identity(
                prID: sent.prID,
                repo: sent.repo,
                number: sent.number
            )
            switch sent.kind {
            case .reviewSubmitted(let verdict, let inlineCommentCount):
                return WebhookPlan(
                    kind: .reviewSubmitted,
                    details: .reviewSubmitted(
                        verdict: WebhookEventDetails.verdict(verdict),
                        inlineCommentCount: inlineCommentCount
                    ),
                    identity: identity,
                    summary: nil,
                    occurredAt: sent.sentAt
                )
            case .merged(let method):
                return WebhookPlan(
                    kind: .pullRequestMerged,
                    details: .merged(method: method),
                    identity: identity,
                    summary: nil,
                    occurredAt: sent.sentAt
                )
            case .issueClosed(let reason):
                return WebhookPlan(
                    kind: .issueClosed,
                    details: .issueClosed(reason: reason),
                    // The identity's three fields name the *issue* here.
                    identity: identity,
                    summary: nil,
                    // Looked up rather than carried: the drain announces a node id, and the row
                    // is still in the database at this moment more often than not.
                    issue: nil,
                    occurredAt: sent.sentAt
                )
            case .replyPosted, .threadResolved, .threadUnresolved, .markedReadyForReview,
                 .issueCommentAdded, .issueLabelAdded, .issueAssigneeAdded, .issueReopened:
                // Sent, and deliberately not events this version promises. A comment, a label,
                // an assignee and a reopen are the issue-side twins of the four pull-request
                // writes above them, and mapping any of them later is an additive change.
                return nil
            }

        case .prMerged, .prUpdated, .checksFailedOnOwnPR, .changesRequestedOnOwnPR,
             .draftConflict, .syncFailed:
            return nil
        }
    }

    /// The outbound event a queued automatic merge amounts to (ADR 0018).
    ///
    /// The one mapping in this file that does *not* come from a success. It is built from the
    /// audit line rather than from a sync event, because the fact being reported — Shepherd
    /// decided to merge something on its own — happens at the enqueue and has no later moment
    /// that could report it as honestly. `pr.merged` still fires from `mutationSent` when the
    /// drain sends the row, so a receiver sees the decision and the outcome as two events.
    /// - Parameter queued: What the coordinator queued.
    nonisolated static func plan(for queued: AutoMergeQueuedWrite) -> WebhookPlan {
        let summary = queued.pullRequest
        return WebhookPlan(
            kind: .autoMergeQueued,
            details: .autoMergeQueued(
                mergeMethod: queued.entry.mergeMethod,
                checkCount: queued.entry.checkCount,
                matchedLabels: queued.entry.matchedLabels
            ),
            identity: WebhookPullRequest.Identity(
                prID: summary.id,
                repo: summary.repo,
                number: summary.number
            ),
            // Carried rather than looked up: the merge is about to leave the inbox, and the row
            // may well be gone by the time the POST is attempted.
            summary: summary,
            occurredAt: queued.entry.queuedAt
        )
    }

    /// The outbound event a finished delegation amounts to.
    /// - Parameter outcome: How the run ended.
    nonisolated static func plan(for outcome: DelegationOutcome) -> WebhookPlan {
        WebhookPlan(
            kind: .delegationFinished,
            details: .delegation(
                status: outcome.status.rawValue,
                agent: outcome.agent,
                durationSeconds: outcome.durationSeconds,
                changedFileCount: outcome.changedFileCount,
                message: outcome.message,
                automatic: outcome.wasAutomatic
            ),
            identity: WebhookPullRequest.Identity(
                prID: outcome.prID,
                repo: outcome.repo,
                number: outcome.number
            ),
            summary: nil,
            occurredAt: outcome.at
        )
    }
}
