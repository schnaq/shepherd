import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The selected row stays where it was clicked (2026-09-25).
///
/// Selecting a pull request refreshes its detail, the refresh lands in the database with a newer
/// `updatedAt`, and the sort used to carry the row the reader had just clicked up to the top of
/// the list. ``InboxSelectionAnchor`` holds it in its section and at its position while it stays
/// selected; these tests drive it the way `InboxModel` does — capture from the list on screen,
/// then apply to each newly sorted list — because the model itself cannot be built in a test.
@MainActor
final class InboxSelectionAnchorTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "shepherd")

    // MARK: - Helpers

    private func row(_ id: String) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: 1,
            title: id,
            author: ShepherdCore.Actor(login: "alice", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            headRefName: "b",
            headRefOid: "h",
            baseRefName: "main"
        )
    }

    private func section(_ id: String, _ ids: [String]) -> InboxSection {
        InboxSection(id: id, title: id, kind: .humans, facet: .provenance, items: ids.map(row))
    }

    private func context(
        sortOrder: InboxSortOrder = .recentlyUpdated,
        repoFilter: RepoRef? = nil
    ) -> InboxSelectionAnchor.Context {
        InboxSelectionAnchor.Context(
            rail: InboxModel.RailState(
                smartView: .involved,
                provenanceFilter: nil,
                repoFilter: repoFilter,
                riskFilter: nil,
                laneFilter: nil,
                selectedID: nil
            ),
            groupBy: .provenance,
            sortOrder: sortOrder
        )
    }

    private func ids(_ sections: [InboxSection]) -> [[String]] {
        sections.map { $0.items.map(\.id) }
    }

    // MARK: - Holding the row

    func testTheSelectedRowKeepsItsPlaceWhenARefreshSortsItToTheTop() throws {
        let shown = [section("humans", ["a", "b", "c", "d"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "c", in: shown, context: context()))

        // The detail refresh made "c" the most recently updated row.
        let resorted = [section("humans", ["c", "a", "b", "d"])]
        XCTAssertEqual(ids(anchor.apply(to: resorted, context: context())), [["a", "b", "c", "d"]])
    }

    func testOtherRowsStillReorderAroundTheSelectedOne() throws {
        let shown = [section("humans", ["a", "b", "c", "d"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "b", in: shown, context: context()))

        let resorted = [section("humans", ["d", "b", "a", "c"])]
        XCTAssertEqual(ids(anchor.apply(to: resorted, context: context())), [["d", "b", "a", "c"]])
        let moved = [section("humans", ["b", "d", "c", "a"])]
        XCTAssertEqual(
            ids(anchor.apply(to: moved, context: context())),
            [["d", "b", "c", "a"]],
            "the selected row stays second; the others take the sort's order around it"
        )
    }

    func testTheSelectedRowStaysInItsSectionWhenItsGroupChanges() throws {
        let shown = [section("agents", ["a", "b"]), section("humans", ["c", "d"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "c", in: shown, context: context()))

        // Its review state changed and the grouping now puts it with the others.
        let regrouped = [section("agents", ["c", "a", "b"]), section("humans", ["d"])]
        XCTAssertEqual(ids(anchor.apply(to: regrouped, context: context())), [["a", "b"], ["c", "d"]])
    }

    func testASectionTheMoveLeavesEmptyIsDropped() throws {
        let shown = [section("agents", ["a"]), section("humans", ["c", "d"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "c", in: shown, context: context()))

        let regrouped = [section("agents", ["a"]), section("humans", ["d"]), section("bots", ["c"])]
        let result = anchor.apply(to: regrouped, context: context())
        XCTAssertEqual(result.map(\.id), ["agents", "humans"])
        XCTAssertEqual(ids(result), [["a"], ["c", "d"]])
    }

    func testAPositionPastTheEndOfAShrunkSectionLandsLast() throws {
        let shown = [section("humans", ["a", "b", "c", "d"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "d", in: shown, context: context()))

        let shrunk = [section("humans", ["d", "a"])]
        XCTAssertEqual(ids(anchor.apply(to: shrunk, context: context())), [["a", "d"]])
    }

    // MARK: - Letting it go

    func testTheAnchorIsReleasedByAChangeOfSort() throws {
        let shown = [section("humans", ["a", "b", "c"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "c", in: shown, context: context()))

        let resorted = [section("humans", ["c", "b", "a"])]
        XCTAssertEqual(
            ids(anchor.apply(to: resorted, context: context(sortOrder: .oldestFirst))),
            [["c", "b", "a"]],
            "a sort the reader chose is shown as sorted"
        )
    }

    func testTheAnchorIsReleasedByAChangeOfFilter() throws {
        let shown = [section("humans", ["a", "b", "c"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "c", in: shown, context: context()))

        let filtered = [section("humans", ["c", "a"])]
        XCTAssertEqual(ids(anchor.apply(to: filtered, context: context(repoFilter: repo))), [["c", "a"]])
    }

    func testARowThatLeftTheListIsNotConjuredBack() throws {
        let shown = [section("humans", ["a", "b", "c"])]
        let anchor = try XCTUnwrap(InboxSelectionAnchor.capture(id: "b", in: shown, context: context()))

        let merged = [section("humans", ["c", "a"])]
        XCTAssertEqual(ids(anchor.apply(to: merged, context: context())), [["c", "a"]])
    }

    func testANewSelectionIsAnchoredWhereItIsShownNotWhereTheSortWouldPutIt() throws {
        // "b" is held second by its anchor although the sort now puts it first.
        let sorted = [section("humans", ["b", "a", "c", "d"])]
        let first = try XCTUnwrap(InboxSelectionAnchor.capture(
            id: "b",
            in: [section("humans", ["a", "b", "c", "d"])],
            context: context()
        ))
        let shown = first.apply(to: sorted, context: context())
        XCTAssertEqual(ids(shown), [["a", "b", "c", "d"]])

        // The reader clicks "c", third on screen; the anchor moves with the selection.
        let second = try XCTUnwrap(InboxSelectionAnchor.capture(id: "c", in: shown, context: context()))
        XCTAssertEqual(second.index, 2)
        XCTAssertEqual(ids(second.apply(to: sorted, context: context())), [["b", "a", "c", "d"]])
    }

    func testNothingIsAnchoredForARowThatIsNotInTheList() {
        XCTAssertNil(InboxSelectionAnchor.capture(id: "z", in: [section("humans", ["a"])], context: context()))
    }
}
