import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The focus review session's pure half: the frozen queue, every cursor transition, and what the
/// closing summary says.
///
/// All the product risk of the feature is in here. The bar and the screen around it own no state
/// — they read ``ReviewSession`` and call ``AppEnvironment`` — so there is nothing else to test
/// without a window.
final class ReviewSessionTests: XCTestCase {
    private func summary(
        id: String,
        number: Int = 1,
        relation: Set<Relation> = [.reviewRequested],
        decision: ReviewDecision? = nil,
        checks: CheckRollup.State? = nil,
        isDraft: Bool = false,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: number,
            title: "Title \(number)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: updatedAt,
            createdAt: Date(timeIntervalSince1970: 0),
            isDraft: isDraft,
            headRefName: "feature",
            headRefOid: "abc",
            baseRefName: "main",
            reviewDecision: decision,
            checkRollup: checks.map { CheckRollup(state: $0) },
            myRelation: relation
        )
    }

    /// `count` queue entries, `PR_1…PR_n`.
    private func items(_ count: Int) -> [ReviewSession.Item] {
        (1...count).map {
            ReviewSession.Item(id: "PR_\($0)", slug: "schnaq/review#\($0)", title: "Title \($0)")
        }
    }

    /// A session over `count` entries, starting at a fixed instant.
    private func session(_ count: Int) -> ReviewSession {
        guard let session = ReviewSession(
            items: items(count),
            startedAt: Date(timeIntervalSince1970: 1_000)
        ) else {
            preconditionFailure("a non-empty queue must produce a session")
        }
        return session
    }

    /// Every id of a session's queue — "nothing has vanished".
    private func allPresent(in session: ReviewSession) -> Set<String> {
        Set(session.items.map(\.id))
    }

    // MARK: - Building the queue

    func testAnEmptyQueueDoesNotProduceASession() {
        // The one guard that matters at the entry point: a session bar reading "0 of 0" would be
        // a dead end, so the caller says "nothing needs your review" instead.
        XCTAssertNil(ReviewSession(items: []))
        XCTAssertNil(ReviewSession.make(from: []))
    }

    func testAnInboxWhereNothingNeedsMeDoesNotProduceASession() {
        let rows = [
            summary(id: "mine", relation: [.author]),
            summary(id: "approved", relation: [.reviewRequested], decision: .approved),
            summary(id: "involved", relation: [.assigned]),
        ]
        XCTAssertNil(ReviewSession.make(from: rows))
    }

    func testTheQueueIsTheNeedsMyReviewRowsInThePriorityOrder() {
        let plain = summary(id: "plain", number: 1)
        let failing = summary(id: "failing", number: 2, checks: .failure)
        let changesRequested = summary(id: "changes", number: 3, decision: .changesRequested)
        let mine = summary(id: "mine", number: 4, relation: [.author])

        let session = ReviewSession.make(from: [plain, failing, changesRequested, mine])
        // The same ranking the inbox and the menu bar use, because it is the same function:
        // changes requested (+25) outranks red CI (+20) outranks a plain row. `mine` is not in
        // the queue at all — it does not need the user's review.
        XCTAssertEqual(session?.items.map(\.id), ["changes", "failing", "plain"])
        XCTAssertEqual(session?.total, 3)
        XCTAssertEqual(session?.position, 1)
    }

    func testTheQueueOrderDoesNotDependOnArrivalOrder() {
        let older = summary(id: "older", number: 1, updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = summary(id: "newer", number: 2, updatedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(
            ReviewSession.make(from: [older, newer])?.items.map(\.id),
            ["newer", "older"]
        )
        XCTAssertEqual(
            ReviewSession.make(from: [newer, older])?.items.map(\.id),
            ["newer", "older"]
        )
    }

    func testTheEntryKeepsTheSlugAndTitleItWasFrozenWith() {
        var row = summary(id: "PR_1", number: 7)
        row.title = "Fix the login redirect"
        let session = ReviewSession.make(from: [row])
        XCTAssertEqual(session?.current?.slug, "schnaq/review#7")
        XCTAssertEqual(session?.current?.title, "Fix the login redirect")
    }

    // MARK: - The queue is frozen

    func testANewlyArrivedPullRequestDoesNotJoinARunningSession() {
        var running = session(3)
        // A sweep lands and imports two more review requests. `present` grows; the queue must not.
        let present = allPresent(in: running).union(["PR_99", "PR_100"])
        _ = running.completeCurrent(present: present)
        XCTAssertEqual(running.total, 3)
        XCTAssertEqual(running.position, 2)
        XCTAssertEqual(running.items.map(\.id), ["PR_1", "PR_2", "PR_3"])
    }

    // MARK: - Moving through it

    func testCompletingCountsAsReviewedAndMovesOn() {
        var running = session(3)
        let advance = running.completeCurrent(present: allPresent(in: running))
        XCTAssertEqual(advance.next?.id, "PR_2")
        XCTAssertFalse(advance.isFinished)
        XCTAssertTrue(advance.vanished.isEmpty)
        XCTAssertNil(advance.vanishedMessage)
        XCTAssertEqual(running.reviewedCount, 1)
        XCTAssertEqual(running.skippedCount, 0)
        XCTAssertEqual(running.position, 2)
        XCTAssertEqual(running.remaining, 2)
    }

    func testSkippingDoesNotCountAsReviewed() {
        var running = session(3)
        let advance = running.skipCurrent(present: allPresent(in: running))
        XCTAssertEqual(advance.next?.id, "PR_2")
        XCTAssertEqual(running.reviewedCount, 0)
        XCTAssertEqual(running.skippedCount, 1)
    }

    func testSkippingTheLastEntryFinishesTheSession() {
        var running = session(2)
        let present = allPresent(in: running)
        _ = running.completeCurrent(present: present)
        let advance = running.skipCurrent(present: present)
        XCTAssertTrue(advance.isFinished)
        XCTAssertNil(advance.next)
        XCTAssertTrue(running.isFinished)
        XCTAssertNil(running.current)
        XCTAssertEqual(running.remaining, 0)
        // "2 of 2" rather than "3 of 2": the position is clamped, so a finished bar reads sanely.
        XCTAssertEqual(running.position, 2)
        XCTAssertEqual(running.progress, 1, accuracy: 0.0001)
    }

    func testCompletingTheLastEntryFinishesTheSession() {
        var running = session(1)
        let advance = running.completeCurrent(present: allPresent(in: running))
        XCTAssertTrue(advance.isFinished)
        XCTAssertEqual(running.reviewedCount, 1)
        XCTAssertTrue(running.isFinished)
    }

    func testMovingAFinishedSessionChangesNothing() {
        var running = session(1)
        let present = allPresent(in: running)
        _ = running.completeCurrent(present: present)
        let after = running

        let completed = running.completeCurrent(present: present)
        XCTAssertTrue(completed.isFinished)
        let skipped = running.skipCurrent(present: present)
        XCTAssertTrue(skipped.isFinished)
        // No counter creeps up after the queue ran out, so the closing summary cannot overcount.
        XCTAssertEqual(running, after)
    }

    func testProgressAndPositionWalkTheQueue() {
        var running = session(4)
        let present = allPresent(in: running)
        XCTAssertEqual(running.position, 1)
        XCTAssertEqual(running.progress, 0, accuracy: 0.0001)
        _ = running.completeCurrent(present: present)
        XCTAssertEqual(running.position, 2)
        XCTAssertEqual(running.progress, 0.25, accuracy: 0.0001)
        _ = running.completeCurrent(present: present)
        XCTAssertEqual(running.position, 3)
        XCTAssertEqual(running.progress, 0.5, accuracy: 0.0001)
    }

    // MARK: - Pull requests that leave the inbox

    func testAnEntryThatLeftTheInboxIsWalkedPastWhenItIsReached() {
        var running = session(4)
        // PR_2 and PR_3 were merged by someone else while the user was on PR_1.
        let present: Set<String> = ["PR_1", "PR_4"]
        let advance = running.completeCurrent(present: present)
        XCTAssertEqual(advance.next?.id, "PR_4")
        XCTAssertEqual(advance.vanished.map(\.id), ["PR_2", "PR_3"])
        XCTAssertEqual(running.vanishedCount, 2)
        // Counted apart from the ones the user skipped on purpose.
        XCTAssertEqual(running.skippedCount, 0)
        XCTAssertEqual(running.reviewedCount, 1)
        XCTAssertEqual(running.position, 4)
    }

    func testAVanishedTailFinishesTheSession() {
        var running = session(3)
        let advance = running.completeCurrent(present: ["PR_1"])
        XCTAssertTrue(advance.isFinished)
        XCTAssertEqual(advance.vanished.map(\.id), ["PR_2", "PR_3"])
        XCTAssertTrue(running.isFinished)
        XCTAssertEqual(running.vanishedCount, 2)
    }

    func testSettlingAtTheStartSkipsAFirstEntryThatIsAlreadyGone() {
        var running = session(3)
        let advance = running.settle(present: ["PR_3"])
        XCTAssertEqual(advance.next?.id, "PR_3")
        XCTAssertEqual(advance.vanished.map(\.id), ["PR_1", "PR_2"])
        XCTAssertEqual(running.vanishedCount, 2)
    }

    func testSettlingWithNothingMissingIsANoOp() {
        var running = session(3)
        let before = running
        let advance = running.settle(present: allPresent(in: running))
        XCTAssertEqual(advance.next?.id, "PR_1")
        XCTAssertTrue(advance.vanished.isEmpty)
        XCTAssertEqual(running, before)
    }

    func testTheVanishedNoticeNamesOnePullRequestAndCountsSeveral() {
        var one = session(3)
        let single = one.completeCurrent(present: ["PR_1", "PR_3"])
        XCTAssertEqual(
            single.vanishedMessage,
            "Skipped schnaq/review#2 — it is no longer in your inbox."
        )

        var many = session(4)
        let several = many.completeCurrent(present: ["PR_1", "PR_4"])
        XCTAssertEqual(
            several.vanishedMessage,
            "Skipped 2 pull requests that are no longer in your inbox."
        )
    }

    // MARK: - The closing summary

    func testTheSummaryOfAQueueThatRanOut() {
        var running = session(3)
        let present = allPresent(in: running)
        _ = running.completeCurrent(present: present)
        _ = running.completeCurrent(present: present)
        _ = running.skipCurrent(present: present)

        let summary = running.summary(at: Date(timeIntervalSince1970: 1_102))
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.reviewed, 2)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.vanished, 0)
        XCTAssertEqual(summary.remaining, 0)
        XCTAssertEqual(summary.duration, 102, accuracy: 0.0001)
        XCTAssertEqual(summary.message, "Session complete — 2 reviewed, 1 skipped · 1 m 42 s")
    }

    func testTheSummaryOfASessionEndedEarlySaysSoAndCountsWhatIsLeft() {
        var running = session(12)
        let present = allPresent(in: running)
        for _ in 0..<9 { _ = running.completeCurrent(present: present) }

        let summary = running.summary(at: Date(timeIntervalSince1970: 1_030))
        XCTAssertEqual(summary.remaining, 3)
        // Never "complete" while pull requests are still in the queue.
        XCTAssertFalse(summary.message.contains("complete"))
        XCTAssertEqual(summary.message, "Session ended — 9 reviewed, 3 left · 30 s")
    }

    func testAnUntouchedCategoryIsLeftOutOfTheMessage() {
        var running = session(1)
        _ = running.completeCurrent(present: allPresent(in: running))
        let message = running.summary(at: Date(timeIntervalSince1970: 1_005)).message
        XCTAssertEqual(message, "Session complete — 1 reviewed · 5 s")
        XCTAssertFalse(message.contains("skipped"))
        XCTAssertFalse(message.contains("gone"))
    }

    func testVanishedEntriesAreNamedSeparatelyInTheMessage() {
        var running = session(3)
        _ = running.completeCurrent(present: ["PR_1", "PR_3"])
        _ = running.skipCurrent(present: ["PR_1", "PR_3"])
        let summary = running.summary(at: Date(timeIntervalSince1970: 1_010))
        XCTAssertEqual(summary.vanished, 1)
        XCTAssertEqual(summary.message, "Session complete — 1 reviewed, 1 skipped, 1 gone · 10 s")
    }

    func testTheCompletionViewsHeadlineDrawsTheSameDistinctionTheSentenceDoes() {
        var ranOut = session(1)
        _ = ranOut.completeCurrent(present: allPresent(in: ranOut))
        XCTAssertEqual(ranOut.summary(at: Date(timeIntervalSince1970: 1_005)).title, "Session complete")

        var endedEarly = session(4)
        _ = endedEarly.completeCurrent(present: allPresent(in: endedEarly))
        let summary = endedEarly.summary(at: Date(timeIntervalSince1970: 1_005))
        XCTAssertEqual(summary.remaining, 3)
        XCTAssertEqual(
            summary.title,
            "Session ended",
            "never 'complete' while pull requests are still in the queue"
        )
    }

    func testASummaryTakenBeforeTheStartNeverReportsANegativeDuration() {
        let running = session(2)
        XCTAssertEqual(
            running.summary(at: Date(timeIntervalSince1970: 0)).duration,
            0,
            accuracy: 0.0001
        )
    }
}
