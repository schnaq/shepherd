import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app's side of the third outbox state (ADR 0006): the rows Settings → Sync lists, the words
/// it lists them with, and what its two buttons actually do to the queue.
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

    func testTheElevenActionsAreToldApartFromEachOther() {
        // A row says "octocat/review#182 · <this>", so two actions sharing a phrase would make
        // two different failures look like the same one.
        let names = everyAction.map { SyncSettingsTab.actionName($0) }
        XCTAssertEqual(Set(names).count, everyAction.count)
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
