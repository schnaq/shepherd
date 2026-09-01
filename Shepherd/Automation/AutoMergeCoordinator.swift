import Foundation
import GitHubKit
import Observation
import ShepherdCore

/// One merge automatic merging queued, with the audit line that justifies it.
///
/// The coordinator's output rather than a mere side effect, because two other things need it: the
/// `pr.auto_merge_queued` webhook (ADR 0012's additive rule) and the tests, which assert on the
/// value instead of on a database.
struct AutoMergeQueuedWrite: Sendable, Equatable {
    /// The pull request, as the sweep knows it.
    var pullRequest: PullRequestSummary
    /// The audit-log line that was recorded before the write.
    var entry: AutoMergeAuditEntry
}

/// How a queued merge reaches the outbox.
///
/// A seam rather than a dependency, the same shape as ``WebhookPosting`` and
/// ``DigestCoordinator``'s input source: in the app it is ``PullRequestActions/merge(_:method:)`` —
/// literally the function the merge sheet's button calls — and in the tests it is a closure that
/// records what it was asked to write. There is deliberately no way for this file to reach
/// GitHub, or even the database, on its own (ADR 0006: one write path).
typealias AutoMergeWriting = @MainActor (PullRequestSummary, MergeMethod) async -> Void

/// Queues merges for pull requests that satisfy every one of the user's rules (ADR 0018).
///
/// The sibling of ``AutoDelegationCoordinator``, and the division of labour is the same: the
/// *decision* is a pure function in `ShepherdCore` (``ShepherdCore/AutoMergePolicy``), and this
/// type supplies the inputs, reserves the slot in the persistent ledger, performs the write
/// through the seam above and tells the user. It holds no judgement of its own.
///
/// Two things about *when* it runs are worth stating, because they are the reason this is not
/// driven by ``ShepherdSync/SyncEvent`` the way auto-delegation is:
///
/// - The trigger is **the inbox rows after a sweep**, not an event. Auto-delegation fires on an
///   edge the engine reports (`checksFailedOnOwnPR`), and there is no equivalent edge here:
///   GitHub does not bump a pull request's `updatedAt` when a check run finishes, so
///   `SyncEvent.prUpdated` is not emitted for the one transition this feature is entirely about —
///   the last check turning green. The rows the sweep wrote to SQLite are the honest source, and
///   they are the same rows the menu bar, the focus session and the morning digest read.
/// - A pass is therefore allowed to be **repeated and idempotent** rather than exact. Every sweep
///   re-considers every row; the ledger's `(prID, headRefOid)` key and the outbox check are what
///   make that safe, and with the feature off a pass costs one `Bool` read.
@MainActor
@Observable
final class AutoMergeCoordinator {
    private let settings: AppSettings
    private let store: AutoMergeStore
    private let now: @MainActor () -> Date
    private let notify: @MainActor (NotificationPayload) -> Void

    /// What the last pass decided, keyed by pull-request node id.
    ///
    /// Kept so the UI can answer "why was *this* one not merged?" without re-running the policy,
    /// and so a test can assert on the reason rather than on the absence of a write. Empty while
    /// the feature is off — the pass returns before deciding anything, and "it is switched off"
    /// is an answer the settings card already gives.
    private(set) var lastDecisions: [String: AutoMergeDecision] = [:]

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: Where the rules and the remembered merge method live.
    ///   - store: The persistent ledger, which is also the audit log.
    ///   - now: The clock. Injectable so an audit line's timestamp is assertable.
    ///   - notify: Where the notice goes. A closure rather than the ``NotificationManager``
    ///     itself, so the logic can be tested without a notification centre.
    init(
        settings: AppSettings,
        store: AutoMergeStore,
        now: @escaping @MainActor () -> Date = { Date() },
        notify: @escaping @MainActor (NotificationPayload) -> Void = { _ in }
    ) {
        self.settings = settings
        self.store = store
        self.now = now
        self.notify = notify
    }

    // MARK: - Status, for Settings

    /// The audit-log lines the settings card shows, newest first.
    var auditEntries: [AutoMergeAuditEntry] { store.displayedEntries }

    /// How many automatic merges are on record on this Mac.
    var auditEntryCount: Int { store.entryCount }

    // MARK: - Deciding

    /// Considers every row of the inbox and queues the merges the rules allow.
    ///
    /// Ordering inside the pass is the caller's row order, which is the inbox's, so a batch of
    /// outbox rows is timestamped in the order the user would have gone through them.
    /// - Parameters:
    ///   - rows: Every inbox row the local database holds (``SignedInSession/inboxRows``).
    ///   - existingOutbox: The node ids of pull requests the outbox still holds a write for.
    ///   - write: How a merge reaches the outbox.
    /// - Returns: What was queued, in row order. Empty when nothing was.
    @discardableResult
    func run(
        rows: [PullRequestSummary],
        existingOutbox: Set<String>,
        write: AutoMergeWriting
    ) async -> [AutoMergeQueuedWrite] {
        let rules = settings.autoMerge
        // Cheapest possible answer for the overwhelmingly common case: with the feature off a
        // sweep costs one Bool read and nothing else — no ledger, no policy, no outbox read.
        guard rules.isEnabled else { return [] }

        // The method every merge dialog in the app opens on, deliberately shared rather than
        // duplicated for the automatic path (``AppSettings/autoMergeMethod``).
        let method = settings.autoMergeMethod
        let moment = now()
        var decisions: [String: AutoMergeDecision] = [:]
        var queued: [AutoMergeQueuedWrite] = []

        for row in rows {
            let decision = AutoMergePolicy.decide(
                pullRequest: row,
                rules: rules,
                ledger: store.ledger,
                // The pull requests this pass has already queued a merge for are in the outbox
                // now, but the set was read before the pass started; adding them keeps the
                // policy's own "one write in flight" rule true within a single pass too.
                existingOutbox: existingOutbox.union(queued.map(\.pullRequest.id))
            )
            decisions[row.id] = decision
            guard decision.expectedHeadOid != nil else { continue }

            let entry = auditEntry(for: row, rules: rules, method: method, at: moment)
            // Recorded before the write, and before the next row is considered: the ledger is
            // what stops the *next* sweep queueing this merge again — and, because the record
            // happens on this side of the `await` below, a second pass that starts while this one
            // is writing sees it too. Two sweeps landing a second apart cannot double-merge.
            store.record(entry)
            await write(row, method)
            queued.append(AutoMergeQueuedWrite(pullRequest: row, entry: entry))
        }

        lastDecisions = decisions
        announce(queued)
        return queued
    }

    /// Why a pull request was not merged automatically, according to the last pass.
    ///
    /// `nil` when the last pass queued its merge, or when no pass has considered it yet.
    /// - Parameter prID: The pull request's node id.
    func skipReason(forPullRequestID prID: String) -> AutoMergeSkipReason? {
        lastDecisions[prID]?.skipReason
    }

    /// Forgets the ledger. Called from "Sign out & erase local data".
    func reset() {
        store.reset()
        lastDecisions = [:]
    }

    // MARK: - Building

    private func auditEntry(
        for row: PullRequestSummary,
        rules: AutoMergeRules,
        method: MergeMethod,
        at moment: Date
    ) -> AutoMergeAuditEntry {
        AutoMergeAuditEntry(
            prID: row.id,
            slug: row.slug,
            title: row.title,
            headRefOid: row.headRefOid,
            mergeMethod: method.rawValue,
            authorLogin: row.author.login,
            checkCount: row.checkRollup?.total ?? 0,
            matchedLabels: rules.matchedLabels(from: row.labels),
            queuedAt: moment
        )
    }

    /// Posts one notice for the whole pass.
    ///
    /// One rather than one per merge, unlike the audit log: a Monday-morning pass can queue a
    /// dozen merges, and a dozen banners would be the automation being more disruptive than the
    /// twelve clicks it replaced. Like an automatic delegation's notice (ADR 0016) it is **not**
    /// gated by a notification preference — something the app did unattended must always be
    /// visible, and the way to switch it off is to switch the rule off.
    private func announce(_ queued: [AutoMergeQueuedWrite]) {
        guard let payload = NotificationManager.payload(
            forAutoMerged: queued.map(\.entry)
        ) else { return }
        notify(payload)
    }
}
