import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The menu-bar quick inbox's pure half: which rows it shows, where it cuts the list off, and how
/// the badge is written.
///
/// Everything the menu-bar feature actually decides is in here. The views around it read
/// ``SignedInSession/inboxRows`` and call ``AppEnvironment`` — there is no third source of truth
/// and no logic of their own to test.
final class MenuBarQuickInboxTests: XCTestCase {
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

    /// `count` rows that all need the user's review, each with its own number and timestamp so
    /// the order is fully determined.
    private func waitingRows(_ count: Int) -> [PullRequestSummary] {
        (1...count).map { index in
            summary(
                id: "PR_\(index)",
                number: index,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            )
        }
    }

    // MARK: - What counts as waiting

    func testOnlyTheRowsThatNeedMyReviewAreCountedAndShown() {
        let rows = [
            summary(id: "waiting"),
            summary(id: "mine", relation: [.author]),
            // Review requested but already approved: the rail drops it, so the menu bar must too.
            summary(id: "approved", relation: [.reviewRequested], decision: .approved),
            summary(id: "involved", relation: [.assigned]),
        ]
        XCTAssertEqual(MenuBarQuickInbox.count(in: rows), 1)
        XCTAssertEqual(MenuBarQuickInbox.make(from: rows).rows.map(\.id), ["waiting"])
    }

    func testTheCountAndTheListNeverDisagree() {
        // The badge is counted without sorting; the two paths must still answer the same
        // question, which is the whole reason the filter lives inside the type.
        let rows = waitingRows(3) + [summary(id: "mine", relation: [.author])]
        let quickInbox = MenuBarQuickInbox.make(from: rows)
        XCTAssertEqual(quickInbox.total, MenuBarQuickInbox.count(in: rows))
        XCTAssertEqual(quickInbox.rows.count, 3)
        XCTAssertEqual(quickInbox.overflow, 0)
    }

    func testAnEmptyInbox() {
        let quickInbox = MenuBarQuickInbox.make(from: [])
        XCTAssertTrue(quickInbox.isEmpty)
        XCTAssertTrue(quickInbox.rows.isEmpty)
        XCTAssertEqual(quickInbox.overflow, 0)
        XCTAssertNil(MenuBarQuickInbox.badgeText(count: quickInbox.total))
    }

    func testAnInboxWhereNothingNeedsMeIsEmptyEvenThoughRowsExist() {
        let quickInbox = MenuBarQuickInbox.make(from: [summary(id: "mine", relation: [.author])])
        XCTAssertTrue(quickInbox.isEmpty)
        XCTAssertEqual(quickInbox.total, 0)
    }

    // MARK: - Truncation and "n more…"

    func testTheListIsCutToEightRowsAndTheRestIsCounted() {
        let quickInbox = MenuBarQuickInbox.make(from: waitingRows(20))
        XCTAssertEqual(quickInbox.rows.count, MenuBarQuickInbox.rowLimit)
        XCTAssertEqual(quickInbox.rows.count, 8)
        XCTAssertEqual(quickInbox.total, 20)
        XCTAssertEqual(quickInbox.overflow, 12)
    }

    func testExactlyTheLimitShowsEverythingAndCountsNothingMore() {
        let quickInbox = MenuBarQuickInbox.make(from: waitingRows(MenuBarQuickInbox.rowLimit))
        XCTAssertEqual(quickInbox.rows.count, MenuBarQuickInbox.rowLimit)
        XCTAssertEqual(quickInbox.overflow, 0)
    }

    func testOneRowOverTheLimitCountsExactlyOneMore() {
        let quickInbox = MenuBarQuickInbox.make(from: waitingRows(MenuBarQuickInbox.rowLimit + 1))
        XCTAssertEqual(quickInbox.overflow, 1)
    }

    func testALimitOfZeroOrLessShowsNoRowsButStillCountsThem() {
        for limit in [0, -3] {
            let quickInbox = MenuBarQuickInbox.make(from: waitingRows(4), limit: limit)
            XCTAssertTrue(quickInbox.rows.isEmpty)
            XCTAssertEqual(quickInbox.total, 4)
            XCTAssertEqual(quickInbox.overflow, 4)
            XCTAssertFalse(quickInbox.isEmpty)
        }
    }

    // MARK: - Order

    func testTheEightRowsAreTheMostUrgentOnesInTheInboxOrder() {
        let plain = summary(id: "plain", number: 1)
        let failing = summary(id: "failing", number: 2, checks: .failure)
        let changesRequested = summary(id: "changes", number: 3, decision: .changesRequested)
        let quickInbox = MenuBarQuickInbox.make(
            from: [plain, failing, changesRequested],
            limit: 2
        )
        // The same ranking the inbox's priority sort applies, because it is literally the same
        // function: changes requested (+25) outranks red CI (+20) outranks a plain row.
        XCTAssertEqual(quickInbox.rows.map(\.id), ["changes", "failing"])
        XCTAssertEqual(quickInbox.overflow, 1)
    }

    func testRowsOfEqualUrgencyAreOrderedNewestFirstAndDeterministically() {
        let older = summary(
            id: "older",
            number: 1,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = summary(
            id: "newer",
            number: 2,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(
            MenuBarQuickInbox.make(from: [older, newer]).rows.map(\.id),
            ["newer", "older"]
        )
        // Same input in the other order, same result: nothing here depends on arrival order.
        XCTAssertEqual(
            MenuBarQuickInbox.make(from: [newer, older]).rows.map(\.id),
            ["newer", "older"]
        )
    }

    // MARK: - Badge

    func testTheBadgeIsEmptyAtZeroAndCapsAtNinetyNinePlus() {
        XCTAssertNil(MenuBarQuickInbox.badgeText(count: 0))
        XCTAssertNil(MenuBarQuickInbox.badgeText(count: -1))
        XCTAssertEqual(MenuBarQuickInbox.badgeText(count: 1), "1")
        XCTAssertEqual(MenuBarQuickInbox.badgeText(count: 12), "12")
        XCTAssertEqual(MenuBarQuickInbox.badgeText(count: 99), "99")
        XCTAssertEqual(MenuBarQuickInbox.badgeText(count: 100), "99+")
        XCTAssertEqual(MenuBarQuickInbox.badgeText(count: 4_312), "99+")
    }

    func testTheBadgeCountsEveryWaitingPullRequestNotOnlyTheVisibleOnes() {
        let quickInbox = MenuBarQuickInbox.make(from: waitingRows(30))
        XCTAssertEqual(MenuBarQuickInbox.badgeText(count: quickInbox.total), "30")
    }
}
