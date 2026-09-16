import XCTest
@testable import ShepherdCore

final class InboxIgnoreListTests: XCTestCase {
    private func row(
        id: String,
        relations: Set<Relation> = [],
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        Fixtures.summary(id: id, reviewDecision: reviewDecision, relations: relations)
    }

    func testAnIgnoredRowIsHidden() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))

        XCTAssertTrue(list.hides(row(id: "pr-1")))
        XCTAssertFalse(list.hides(row(id: "pr-2")))
    }

    func testAReviewRequestBringsAnIgnoredRowBack() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))

        // The whole point of the escape hatch: somebody asked for this review *after* it was
        // put away, so it is not stale any more and the list stops hiding it.
        let requested = row(id: "pr-1", relations: [.reviewRequested])
        XCTAssertFalse(list.hides(requested))
    }

    func testAnApprovedReviewRequestStaysHidden() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))

        // `needsMyReview` is the one definition of "waiting for you", and an approved review
        // request is not waiting for anything.
        let approved = row(id: "pr-1", relations: [.reviewRequested], reviewDecision: .approved)
        XCTAssertTrue(list.hides(approved))
    }

    func testShowingAnIgnoredRowRemovesIt() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))
        list.show(id: "pr-1")

        XCTAssertFalse(list.hides(row(id: "pr-1")))
        XCTAssertTrue(list.entries.isEmpty)
    }

    func testIgnoringTheSameRowTwiceKeepsOneEntry() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))
        list.ignore(row(id: "pr-1"), at: Fixtures.date(60))

        XCTAssertEqual(list.entries.count, 1)
        XCTAssertEqual(list.entries.first?.ignoredAt, Fixtures.date(60))
    }

    func testEntriesAreNewestFirst() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-old"), at: Fixtures.date(0))
        list.ignore(row(id: "pr-new"), at: Fixtures.date(60))

        XCTAssertEqual(list.entries.map(\.id), ["pr-new", "pr-old"])
    }

    func testAnEntryRemembersEnoughToRenderWithoutTheRow() throws {
        var list = InboxIgnoreList()
        list.ignore(
            Fixtures.summary(
                id: "pr-1",
                number: 831,
                repo: RepoRef(owner: "schnaq", name: "unlock"),
                title: "Rework the billing screen"
            ),
            at: Fixtures.date(0)
        )

        // The row itself is pruned from the database as soon as the sweep stops returning it,
        // so "Show again" in Settings has nothing but this entry to draw from.
        let entry = try XCTUnwrap(list.entries.first)
        XCTAssertEqual(entry.repo.fullName, "schnaq/unlock")
        XCTAssertEqual(entry.number, 831)
        XCTAssertEqual(entry.title, "Rework the billing screen")
    }

    func testFilterDropsHiddenRowsAndKeepsTheRest() {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))
        list.ignore(row(id: "pr-2"), at: Fixtures.date(0))

        let rows = [
            row(id: "pr-1"),
            row(id: "pr-2", relations: [.reviewRequested]),
            row(id: "pr-3"),
        ]
        XCTAssertEqual(list.filter(rows).map(\.id), ["pr-2", "pr-3"])
    }

    func testItSurvivesARoundTripThroughJSON() throws {
        var list = InboxIgnoreList()
        list.ignore(row(id: "pr-1"), at: Fixtures.date(0))

        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(InboxIgnoreList.self, from: data)
        XCTAssertEqual(decoded, list)
    }
}
