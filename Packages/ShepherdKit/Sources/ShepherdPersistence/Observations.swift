import Dispatch
import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    /// Streams the inbox, re-emitting whenever any row that the query reads changes.
    ///
    /// This is the mechanism behind "the UI always renders from the database" (ADR 0006): the
    /// sync engine writes, GRDB notices, the view updates. The first value is emitted as soon
    /// as the observation starts, so a view never has to fetch once and observe separately.
    /// - Parameter filter: What to include.
    /// - Returns: A stream that finishes when the caller stops iterating or the observation
    ///   fails.
    public func observeInbox(
        filter: InboxFilter = InboxFilter()
    ) -> AsyncStream<[PullRequestSummary]> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> [PullRequestSummary] in
            try DatabaseManager.loadInbox(db, filter: filter)
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.schnaq.shepherd.observation.inbox")
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Streams one pull request's review draft.
    ///
    /// Emits `nil` when the draft is deleted — which is what the composer needs in order to
    /// clear itself after a successful submit.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: A stream of the current draft.
    public func observeDraft(prID: String) -> AsyncStream<ReviewDraft?> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> ReviewDraft? in
            try DatabaseManager.loadDraft(db, prID: prID)
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.schnaq.shepherd.observation.draft")
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Streams one pull request's cached detail.
    ///
    /// ``observeDraft(prID:)``'s other half for the review screen: the draft is what the reviewer
    /// is writing, and this is what everybody else is doing to the pull request meanwhile. The
    /// sweep re-fetches a detail whenever `updatedAt` or the head commit moved and stores it
    /// through ``savePullRequestDetail(_:)``, so this is how an open review learns that CI turned
    /// green, that a colleague answered a thread, or that the branch was pushed to — none of
    /// which used to reach a screen that had already fetched once.
    ///
    /// Emits `nil` when the pull request is not, or no longer, cached: a sweep prunes what its
    /// search stopped returning and the detail rows cascade away with it, which is the local
    /// signal that the pull request left the inbox.
    ///
    /// The tracked region is the whole of `pull_requests` and its children — the primary key is a
    /// node id rather than a rowid, so GRDB cannot narrow it to one row — which means a sweep
    /// writing *any* pull request re-runs this query. That is one local read per sweep
    /// transaction while a review is open, and the caller compares the value it gets against the
    /// one it is showing rather than acting on the notification itself.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: A stream of the current detail.
    public func observePullRequestDetail(prID: String) -> AsyncStream<PullRequestDetail?> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> PullRequestDetail? in
            try DatabaseManager.loadPullRequestDetail(db, id: prID)
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.schnaq.shepherd.observation.detail")
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Streams how one pull request ended, once the sweep has read it (ADR 0027).
    ///
    /// A second observation rather than one more field on ``observePullRequestDetail(prID:)``,
    /// because the two facts land apart and in that order: the prune removes the inbox row first,
    /// and the outcome is read from GitHub *after* it, in the same sweep. A screen watching only
    /// the detail would therefore see the pull request vanish and never learn whether it was
    /// merged or abandoned.
    ///
    /// An outcome row is never deleted — the whole point of the table is that it outlives the
    /// pull request it describes — so a value here means "this is how it ended the last time it
    /// ended", not "it has ended". The caller pairs it with the detail's disappearance.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: A stream of the stored outcome, or `nil` while there is none.
    public func observePullRequestOutcome(prID: String) -> AsyncStream<PullRequestOutcome?> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> PullRequestOutcome? in
            try DatabaseManager.loadPullRequestOutcome(db, prID: prID)
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.schnaq.shepherd.observation.outcome")
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    /// Streams the number of mutations waiting in the outbox.
    /// - Returns: A stream of pending counts.
    public func observePendingOutboxCount() -> AsyncStream<Int> {
        observeOutboxCount(
            matching: "state IN ('pending', 'sending')",
            label: "com.schnaq.shepherd.observation.outbox"
        )
    }

    /// Streams the number of mutations parked as conflicted.
    ///
    /// A parked mutation never leaves that state on its own (ADR 0006), so this is the number
    /// that needs the user rather than time.
    /// - Returns: A stream of conflicted counts.
    public func observeConflictedOutboxCount() -> AsyncStream<Int> {
        observeOutboxCount(
            matching: "state = 'conflicted'",
            label: "com.schnaq.shepherd.observation.outbox.conflicted"
        )
    }

    /// Streams the number of mutations the drain gave up on.
    ///
    /// The third of the three standing counts, and like the conflicted one it never falls by
    /// itself: a failed row waits for the user to retry it or throw it away (Settings → Sync).
    /// - Returns: A stream of failed counts.
    public func observeFailedOutboxCount() -> AsyncStream<Int> {
        observeOutboxCount(
            matching: "state = 'failed'",
            label: "com.schnaq.shepherd.observation.outbox.failed"
        )
    }

    /// Streams every row the outbox is holding, oldest first.
    ///
    /// The three counts above answer "what is the account's queue doing?"; this answers "what is
    /// the queue holding for *this* pull request?", which needs the rows rather than a number.
    ///
    /// Observed rather than re-read on demand, and that is the one place the pull-request side
    /// differs from the issue side. A write against a pull request is queued from four different
    /// places — the list's bulk triage, the detail panel, the review composer and automatic
    /// merging — so there is no single call site that could re-read the queue after enqueuing and
    /// no honest place to put such a read. Every issue write goes through one model instead, which
    /// is why a cheap re-read after each one is enough there. The cost of the difference is one
    /// more `ValueObservation` on a table that holds tens of rows at most.
    /// - Returns: A stream that finishes when the caller stops iterating or the observation
    ///   fails.
    public func observeOutboxItems() -> AsyncStream<[OutboxItem]> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> [OutboxItem] in
            try DatabaseManager.loadOutboxItems(db)
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.schnaq.shepherd.observation.outbox.items")
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private func observeOutboxCount(matching predicate: String, label: String) -> AsyncStream<Int> {
        let writer = self.writer
        let observation = ValueObservation.tracking { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE \(predicate)") ?? 0
        }
        return AsyncStream { continuation in
            let queue = DispatchQueue(label: label)
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: queue),
                onError: { _ in continuation.finish() },
                onChange: { value in continuation.yield(value) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
