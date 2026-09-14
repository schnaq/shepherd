import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app's side of the third outbox state (ADR 0006): the rows Settings → Sync lists, the words
/// it lists them with, and what its two buttons actually do to the queue.
/// `PullRequestQueueStatusTests` below covers the other half of the same subject — what the
/// pull-request panel says about the writes queued for the one pull request on screen.
///
/// The *counting* is covered on the Linux runner — `DraftAndOutboxTests` owns
/// `failedOutboxCount()`, `failedOutboxItems()` and `retryOutboxItem(id:)` — so what is left here
/// is what only the app layer can get wrong: naming a queued write after its database
/// discriminator, and a Retry button that leaves the row where it was.
///
/// Nothing here needs a `SignedInSession`, a Keychain or a token: the card reads the failed rows
/// off `DatabaseManager` and writes back through it, which is exactly what these tests do.
@MainActor
final class OutboxSurfacesTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let moment = Date(timeIntervalSince1970: 1_788_162_000)

    private func item(_ action: OutboxAction) -> OutboxItem {
        OutboxItem(prID: "PR_1", repo: repo, number: 182, action: action)
    }

    private var everyAction: [OutboxAction] {
        [
            .submitReview(ReviewDraft(prID: "PR_1", verdict: .approve, basedOnHeadOid: "abc123")),
            .replyToComment(commentDatabaseID: 7, body: "thanks"),
            .resolveThread(threadID: "PRRT_1"),
            .unresolveThread(threadID: "PRRT_1"),
            .merge(method: "squash", expectedHeadOid: "abc123"),
            .markReadyForReview,
            .addIssueComment(body: "on it", basedOnUpdatedAt: moment),
            .addIssueLabel(name: "needs-triage", basedOnUpdatedAt: moment),
            .addIssueAssignee(login: "octocat", basedOnUpdatedAt: moment),
            .closeIssue(reason: .completed, basedOnUpdatedAt: moment),
            .reopenIssue(basedOnUpdatedAt: moment),
            .addPullRequestComment(body: "one thought"),
            .closePullRequest(comment: "superseded"),
            .closePullRequest(comment: nil),
        ]
    }

    // MARK: - The words

    func testEveryQueuedWriteIsNamedInWordsRatherThanByItsDiscriminator() {
        for action in everyAction {
            let name = SyncSettingsTab.actionName(action)
            XCTAssertFalse(name.isEmpty, "\(action.kind) has no name")
            XCTAssertNotEqual(
                name,
                action.kind,
                "\(action.kind) is a database column, not something to show a user"
            )
        }
    }

    func testEveryActionIsToldApartFromTheOthers() {
        // A row says "octocat/review#182 · <this>", so two actions sharing a phrase would make
        // two different failures look like the same one. That holds for the two closes as well:
        // a close that carries a comment and one that does not are two different things to
        // re-send or discard, and the queue is where a user decides which.
        let names = everyAction.map { SyncSettingsTab.actionName($0) }
        XCTAssertEqual(Set(names).count, everyAction.count)
        XCTAssertEqual(
            SyncSettingsTab.actionName(.closePullRequest(comment: "superseded")),
            String(localized: "Comment and close"),
            "a close that carries a comment says so — it is two things that happened"
        )
        XCTAssertEqual(
            SyncSettingsTab.actionName(.closePullRequest(comment: nil)),
            String(localized: "Close a pull request")
        )
    }

    // MARK: - What the two buttons do

    func testRetryPutsARowTheDrainGaveUpOnBackIntoTheQueue() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item(.addIssueComment(body: "on it", basedOnUpdatedAt: moment))
        try await database.enqueue(queued)
        try await database.markOutboxItemFailed(
            id: queued.id,
            error: "422 Unprocessable Entity",
            now: moment,
            retriable: false
        )
        let listed = try await database.failedOutboxItems()
        XCTAssertEqual(listed.map(\.id), [queued.id])
        XCTAssertEqual(listed.first?.lastError, "422 Unprocessable Entity")

        try await database.retryOutboxItem(id: queued.id)

        let stillFailed = try await database.failedOutboxItems()
        let waiting = try await database.pendingOutboxCount()
        XCTAssertTrue(stillFailed.isEmpty, "the card's list empties as soon as it is retried")
        XCTAssertEqual(waiting, 1)
    }

    func testDiscardTakesTheRowOutOfTheQueueAltogether() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item(.merge(method: "squash", expectedHeadOid: "abc123"))
        try await database.enqueue(queued)
        try await database.markOutboxItemFailed(
            id: queued.id,
            error: "405 Method Not Allowed",
            now: moment,
            retriable: false
        )

        try await database.deleteOutboxItem(id: queued.id)

        let stored = try await database.allOutboxItems()
        let failed = try await database.failedOutboxCount()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(failed, 0)
    }

    func testTheCardListsOnlyTheRowsItCanActOn() async throws {
        // Pending rows need time and parked ones need the pull request they were queued against;
        // neither belongs under a Retry button in a settings window.
        let database = try DatabaseManager.inMemory()
        let doomed = item(.closeIssue(reason: .completed, basedOnUpdatedAt: moment))
        let parked = item(.submitReview(ReviewDraft(prID: "PR_1", verdict: .approve, basedOnHeadOid: "abc123")))
        let waiting = item(.resolveThread(threadID: "PRRT_1"))
        try await database.enqueue(doomed)
        try await database.enqueue(parked)
        try await database.enqueue(waiting)
        try await database.markOutboxItemFailed(
            id: doomed.id,
            error: "403 Forbidden",
            now: moment,
            retriable: false
        )
        try await database.markOutboxItemConflicted(id: parked.id, reason: "head moved")

        let listed = try await database.failedOutboxItems()
        let named = listed.map { SyncSettingsTab.actionName($0.action) }
        XCTAssertEqual(listed.map(\.id), [doomed.id])
        XCTAssertEqual(named, [SyncSettingsTab.actionName(doomed.action)])
    }
}

/// What the pull-request detail panel says about the outbox rows targeting one pull request
/// (ADR 0006's 2026-09-04 amendment): the three counts `InboxDetailPanel.queueStatus(_:)` draws,
/// and the observation they follow.
///
/// The counting is asserted through `InboxModel`'s static form rather than through an instance,
/// for the reason the suite above gives for needing no session either: `InboxModel` is built from
/// a `SignedInSession`, which wants the Keychain and the real database file, so standing one up
/// here would test the wiring of a test rather than the panel. The instance methods the panel
/// calls are one-line applications of these four functions to whatever the observation last handed
/// over, and the last test drives that observation for real.
///
/// Deliberately not `@MainActor`, unlike its neighbour: nothing here touches main-actor state, and
/// the `AsyncStream` iterator in the last test stays in one isolation domain that way.
final class PullRequestQueueStatusTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let moment = Date(timeIntervalSince1970: 1_788_162_000)

    /// A row carrying only what the queue line reads: its node id, which is an outbox row's
    /// `prID`, and the number the queue stores beside it.
    private func pullRequest(id: String, number: Int) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Pull request \(number)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: moment,
            createdAt: moment,
            headRefName: "feature",
            headRefOid: "abc123",
            baseRefName: "main"
        )
    }

    private func write(
        _ action: OutboxAction,
        on row: PullRequestSummary,
        state: OutboxState = .pending
    ) -> OutboxItem {
        OutboxItem(
            prID: row.id,
            repo: repo,
            number: row.number,
            action: action,
            createdAt: moment,
            state: state
        )
    }

    func testAQueuedWriteIsCountedForItsOwnPullRequestAndNotForAnother() {
        let mine = pullRequest(id: "PR_1", number: 182)
        let other = pullRequest(id: "PR_2", number: 183)
        let draft = ReviewDraft(prID: mine.id, verdict: .approve, basedOnHeadOid: "abc123")
        let items = [
            write(.submitReview(draft), on: mine),
            write(.resolveThread(threadID: "PRRT_1"), on: mine, state: .sending),
        ]

        XCTAssertEqual(
            InboxModel.queuedWriteCount(items, for: mine),
            2,
            "a row already in flight has still not landed"
        )
        XCTAssertEqual(InboxModel.queuedWrites(items, for: mine).count, 2)
        XCTAssertEqual(
            InboxModel.queuedWriteCount(items, for: other),
            0,
            "the queue is read per target, so a neighbour's write is not this pull request's news"
        )
        XCTAssertTrue(InboxModel.queuedWrites(items, for: other).isEmpty)
    }

    func testAParkedWriteIsCountedAsParkedRatherThanAsWaiting() {
        // A parked row never leaves that state on its own, so counting it as waiting would
        // promise a send that is never coming.
        let mine = pullRequest(id: "PR_1", number: 182)
        let other = pullRequest(id: "PR_2", number: 183)
        let items = [
            write(
                .merge(method: "squash", expectedHeadOid: "abc123"),
                on: mine,
                state: .conflicted
            ),
            write(.resolveThread(threadID: "PRRT_9"), on: other),
        ]

        XCTAssertEqual(InboxModel.parkedWriteCount(items, for: mine), 1)
        XCTAssertEqual(InboxModel.queuedWriteCount(items, for: mine), 0)
        XCTAssertEqual(InboxModel.failedWriteCount(items, for: mine), 0)
        XCTAssertEqual(InboxModel.parkedWriteCount(items, for: other), 0)
        XCTAssertEqual(InboxModel.queuedWriteCount(items, for: other), 1)
    }

    func testAWriteTheDrainGaveUpOnIsCountedAsFailedAndAsNeitherOfTheOtherTwo() {
        // The state that was on nobody's screen for a pull request: a 4xx from GitHub ends here,
        // and the row never moves again by itself.
        let mine = pullRequest(id: "PR_1", number: 182)
        let items = [
            write(.markReadyForReview, on: mine, state: .failed),
            write(.replyToComment(commentDatabaseID: 7, body: "thanks"), on: mine),
        ]

        XCTAssertEqual(InboxModel.failedWriteCount(items, for: mine), 1)
        XCTAssertEqual(
            InboxModel.parkedWriteCount(items, for: mine),
            0,
            "a failed row is not parked"
        )
        XCTAssertEqual(
            InboxModel.queuedWriteCount(items, for: mine),
            1,
            "and it is not waiting: the row still waiting is the other one"
        )
    }

    func testTheCountsFollowTheOutboxObservation() async throws {
        // The panel's line is fed by `observeOutboxItems()` rather than by a re-read, because a
        // pull-request write is queued from four different places. So the chain that matters is
        // "write to the outbox, the observation speaks, the counts change".
        let database = try DatabaseManager.inMemory()
        let mine = pullRequest(id: "PR_1", number: 182)
        var iterator = database.observeOutboxItems().makeAsyncIterator()
        let empty = await iterator.next()
        XCTAssertEqual(empty?.count, 0, "the observation speaks once as soon as it starts")
        XCTAssertEqual(InboxModel.queuedWriteCount(empty ?? [], for: mine), 0)

        let queued = write(.merge(method: "squash", expectedHeadOid: "abc123"), on: mine)
        try await database.enqueue(queued)
        let afterEnqueue = await iterator.next()
        XCTAssertEqual(InboxModel.queuedWriteCount(afterEnqueue ?? [], for: mine), 1)
        XCTAssertEqual(InboxModel.failedWriteCount(afterEnqueue ?? [], for: mine), 0)

        try await database.markOutboxItemFailed(
            id: queued.id,
            error: "405 Method Not Allowed",
            now: moment,
            retriable: false
        )
        let afterFailure = await iterator.next()
        XCTAssertEqual(
            InboxModel.failedWriteCount(afterFailure ?? [], for: mine),
            1,
            "the drain giving up is what the panel has to be able to say"
        )
        XCTAssertEqual(InboxModel.queuedWriteCount(afterFailure ?? [], for: mine), 0)
        XCTAssertEqual(InboxModel.parkedWriteCount(afterFailure ?? [], for: mine), 0)
    }
}
