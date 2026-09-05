import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence
import ShepherdSync

/// Owns the one-time track-record backfill and the stored history's lifecycle (ADR 0027).
///
/// Created inert, like the search index and the triage coordinator beside it: it reads nothing,
/// asks GitHub nothing and holds nothing until somebody presses *Load track record* in
/// Settings → Automation. With the button never pressed, the whole feature is the two thresholds
/// and whatever the sweep has captured on its own.
///
/// It owns the *run*, not the numbers. The badges are computed by ``TrustLaneLoader`` from the
/// table, in the inbox, on every refresh — so a coordinator that held a copy of them could only
/// ever be a second answer to the same question.
@MainActor
@Observable
final class TrackRecordCoordinator {
    /// Whether a backfill is running.
    private(set) var isRunning = false
    /// The progress line, or `nil` when nothing is running.
    private(set) var progress: TrackRecordBackfillProgress?
    /// What the last finished run did, so Settings can say something true afterwards.
    private(set) var lastResult: TrackRecordBackfillResult?
    /// How many outcomes are on disk, refreshed after every run and after a clear.
    private(set) var storedOutcomeCount = 0
    /// Whether ``storedOutcomeCount`` has ever been read from the database.
    ///
    /// The count alone cannot say this: it starts at `0`, and `0` is also the answer that means
    /// "nothing is stored", which the inbox's one-time offer reads as *make the offer*. The first
    /// body evaluation happens before the screen's `.task` has run, so an account with a history
    /// would flash the notice for one frame and then lose it. This is the flag that makes "not
    /// counted yet" a third answer rather than a wrong one.
    private(set) var hasReadStoredCount = false
    /// Bumped whenever the stored history is replaced, so the inbox knows to recount.
    ///
    /// A counter rather than a `Bool` or a notification: the inbox's `onChange` fires on a *new*
    /// value, and two backfills in a row have to be two changes.
    private(set) var historyVersion = 0

    private var runTask: Task<Void, Never>?

    /// Creates the coordinator.
    init() {}

    /// Starts a backfill over the repositories the inbox knows.
    ///
    /// Four properties the settings card promises:
    ///
    /// - **`.utility` priority.** A history nobody is waiting for must not compete with the sweep
    ///   or with the diff the user is reading; the task is created at the priority the
    ///   search-index pass uses for the same reason.
    /// - **Cancellable.** ``cancel()`` cancels this task, the pager stops between pages, and
    ///   everything read so far is already on disk — the table is an upsert, so a second run
    ///   continues rather than duplicating.
    /// - **One run at a time.** A second press while one is running is ignored rather than
    ///   queued: two pagers over the same repositories would spend twice the requests to write
    ///   the same rows.
    /// - **Nothing is thrown at the caller.** A repository that fails becomes a line in
    ///   ``lastResult``; the run keeps going.
    /// - Parameters:
    ///   - repos: The repositories to read, deduplicated and ordered by the caller.
    ///   - reader: The GitHub side, normally the session's client.
    ///   - store: The database side, normally the session's database.
    func start(
        repos: [RepoRef],
        reader: any ClosedPullRequestReading,
        store: any OutcomeRecording
    ) {
        guard !isRunning, !repos.isEmpty else { return }
        isRunning = true
        progress = nil
        lastResult = nil
        let backfill = TrackRecordBackfill(reader: reader, store: store)
        runTask = Task(priority: .utility) { [self] in
            let result = await backfill.run(repos: repos) { update in
                // The pager reports from its own actor; the line the user reads is `@MainActor`
                // state, so every update hops. A detached hop rather than an `await` on a method,
                // because the pager's callback is synchronous by design — it must not be able to
                // make the paging wait for a view.
                Task { @MainActor in
                    self.progress = update
                }
            }
            self.finish(with: result)
        }
    }

    /// Cancels a running backfill. A no-op when nothing is running.
    func cancel() {
        runTask?.cancel()
    }

    /// Deletes every stored outcome.
    ///
    /// The badges disappear on the inbox's next recount and the lanes do not move, because a lane
    /// never read the history in the first place (ADR 0027).
    /// - Parameter database: The database to empty.
    func clearHistory(database: DatabaseManager) {
        Task { [self] in
            try? await database.deleteAllPullRequestOutcomes()
            self.lastResult = nil
            self.progress = nil
            await self.refreshStoredCount(database: database)
            self.historyVersion += 1
        }
    }

    /// Re-reads how many outcomes are stored.
    /// - Parameter database: The database to count in.
    func refreshStoredCount(database: DatabaseManager) async {
        storedOutcomeCount = (try? await database.pullRequestOutcomeCount()) ?? 0
        // Set even when the count could not be read: a database that refuses to answer is not a
        // reason to offer a backfill, and the next refresh will ask again.
        hasReadStoredCount = true
    }

    /// Forgets everything on sign-out, exactly as the other coordinators do.
    ///
    /// The rows themselves go with `eraseAllData()`, which empties every table including
    /// `pull_request_outcomes` — this drops the *run* state, which names the leaving account's
    /// repositories.
    func reset() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        progress = nil
        lastResult = nil
        storedOutcomeCount = 0
        // The count that was read belonged to the account that just left, so the next one has to
        // be read again before anything may be concluded from it.
        hasReadStoredCount = false
        historyVersion += 1
    }

    private func finish(with result: TrackRecordBackfillResult) {
        isRunning = false
        progress = nil
        lastResult = result
        runTask = nil
        historyVersion += 1
    }
}
