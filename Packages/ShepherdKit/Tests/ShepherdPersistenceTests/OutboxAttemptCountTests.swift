import Foundation
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// The outbox's replay check (ADR 0044) reads `attemptCount > 1` on a claimed row as "an earlier
/// attempt may have reached GitHub". That reading rests on three rules of this store, pinned
/// here so a later tidy-up of `resetInFlightOutboxItems` or `releaseOutboxItems` cannot quietly
/// turn a lost-response retry back into a blind second post.
final class OutboxAttemptCountTests: XCTestCase {
    func testAnInFlightRowKeepsItsAttemptAcrossARelaunchAndAReleaseGivesItBack() async throws {
        let store = try DatabaseManager.inMemory()
        let item = OutboxItem(
            prID: "PR_1",
            repo: RepoRef(owner: "o", name: "r"),
            number: 1,
            action: .resolveThread(threadID: "T")
        )
        try await store.enqueue(item)

        _ = try await store.claimReadyOutboxItems(now: Date(), limit: 5)
        try await store.resetInFlightOutboxItems()
        let second = try await store.claimReadyOutboxItems(now: Date(), limit: 5)
        XCTAssertEqual(second.first?.attemptCount, 2, "a relaunch must not forget an attempt that may have landed")

        try await store.releaseOutboxItems(ids: [item.id])
        let released = try await store.outboxItem(id: item.id)
        XCTAssertEqual(released?.attemptCount, 1, "a row that never left gives its attempt back")

        _ = try await store.claimReadyOutboxItems(now: Date(), limit: 5)
        try await store.markOutboxItemFailed(id: item.id, error: "timeout", now: Date(), retriable: true)
        let failed = try await store.outboxItem(id: item.id)
        XCTAssertEqual(failed?.attemptCount, 2, "a failed send keeps the attempt it was claimed with")
    }
}
