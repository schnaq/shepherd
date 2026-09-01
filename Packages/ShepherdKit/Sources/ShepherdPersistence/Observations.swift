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
