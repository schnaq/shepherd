import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The rail keeps its places when the smart view changes (2026-09-22): entries and order come
/// from the whole inbox, counts from the view, and watched repositories have a fixed block.
final class RailStabilityTests: XCTestCase {
    private let shepherd = RepoRef(owner: "schnaq", name: "shepherd")
    private let site = RepoRef(owner: "schnaq", name: "site")
    private let other = RepoRef(owner: "acme", name: "api")

    private func row(_ id: String, repo: RepoRef) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: 1,
            title: "T",
            author: ShepherdCore.Actor(login: "alice", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 1,
            deletions: 1,
            changedFiles: 1,
            headRefName: "b",
            headRefOid: "h",
            baseRefName: "main"
        )
    }

    // MARK: - stabilised

    func testEntriesAndOrderComeFromTheWholeAndCountsFromTheView() {
        let all = [("a", 5), ("b", 3), ("c", 1)]
        let view = [("c", 1), ("a", 2)]
        let result = InboxModel.stabilised(all, counts: view, key: \.0, zero: { ($0.0, 0) })
        XCTAssertEqual(result.map(\.0), ["a", "b", "c"], "the order is the whole inbox's")
        XCTAssertEqual(result.map(\.1), [2, 0, 1], "a missing entry reads zero instead of leaving")
    }

    func testRepositoriesKeepTheirPlacesAcrossViews() {
        let rows = [
            row("1", repo: shepherd), row("2", repo: shepherd), row("3", repo: shepherd),
            row("4", repo: site), row("5", repo: other),
        ]
        let whole = InboxModel.repositoryFacets(in: rows)
        let narrow = InboxModel.repositoryFacets(in: [rows[3], rows[4], rows[4]])
        let shown = InboxModel.stabilised(whole, counts: narrow, key: \.repo, zero: { (repo: $0.repo, count: 0) })
        XCTAssertEqual(shown.map(\.repo), whole.map(\.repo))
        XCTAssertEqual(shown.first?.repo, shepherd)
        XCTAssertEqual(shown.first?.count, 0)
    }

    // MARK: - The watched block

    func testWatchedRepositoriesAreListedByNameWithTheViewsCounts() {
        let watched = [site, RepoRef(owner: "Schnaq", name: "Shepherd"), other]
        let facets: [(repo: RepoRef, count: Int)] = [(repo: shepherd, count: 4)]

        let block = InboxSidebar.watchedFacets(watched, facets: facets)

        XCTAssertEqual(block.map(\.repo.fullName), ["acme/api", "schnaq/shepherd", "schnaq/site"])
        XCTAssertEqual(block.map(\.count), [0, 4, 0], "zero when the view holds nothing from it")
        XCTAssertEqual(block[1].repo, shepherd, "the inbox's own spelling, so the filter matches its rows")
    }

    func testAnEmptyWatchListHasNoBlock() {
        XCTAssertTrue(InboxSidebar.watchedFacets([], facets: [(repo: shepherd, count: 1)]).isEmpty)
    }
}
