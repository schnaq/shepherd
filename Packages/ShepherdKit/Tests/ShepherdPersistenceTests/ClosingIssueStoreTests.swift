import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// The store side of ADR 0032's linking sprint: `pull_request_closing_issues` in both
/// directions, the `(repo, number)` lookup the issue side's links resolve through, and the narrow
/// read of the issue side's list.
final class ClosingIssueStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }

    private func reference(
        number: Int,
        repo: RepoRef = PersistenceFixtures.repo,
        title: String = "Uploads fail silently",
        state: IssueSummary.State = .open
    ) -> LinkedIssueReference {
        LinkedIssueReference(repo: repo, number: number, title: title, state: state)
    }

    // MARK: - Round trip

    func testTheClosingIssuesRoundTripWithTheDetail() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.closingIssues = [
            reference(number: 142),
            reference(
                number: 7,
                repo: PersistenceFixtures.otherRepo,
                title: "Token refresh logs the user out",
                state: .closed
            ),
        ]
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        // GitHub's own order is kept, which is what `sortIndex` is for.
        XCTAssertEqual(loaded?.closingIssues.map(\.number), [142, 7])
        XCTAssertEqual(
            loaded?.closingIssues.map(\.repo.fullName),
            ["schnaq/review", "schnaq/shepherd-web"]
        )
        XCTAssertEqual(loaded?.closingIssues.map(\.state), [.open, .closed])
        XCTAssertEqual(loaded?.closingIssues.first?.title, "Uploads fail silently")
        // And the whole record still compares equal, so nothing else moved.
        XCTAssertEqual(loaded, detail)
    }

    func testASecondDetailFetchReplacesTheClosingIssuesRatherThanAccumulatingThem() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.closingIssues = [reference(number: 142), reference(number: 7)]
        try await database.savePullRequestDetail(detail)

        // The description was edited: one keyword removed, one issue closed since.
        detail.closingIssues = [reference(number: 7, title: "Still open", state: .closed)]
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(loaded?.closingIssues.map(\.number), [7])
        XCTAssertEqual(loaded?.closingIssues.map(\.state), [.closed])
    }

    func testADetailWithNoClosingIssuesEmptiesTheTable() async throws {
        // The opposite treatment from the check runs, and deliberately: the detail fetch selects
        // `closingIssuesReferences` on every pass, so an empty answer is a fact about the pull
        // request rather than a gap in this fetch (ADR 0032).
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.closingIssues = [reference(number: 142)]
        try await database.savePullRequestDetail(detail)

        detail.closingIssues = []
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertTrue(loaded?.closingIssues.isEmpty == true)
    }

    func testTheLinksAreReplacedEvenWhenTheFetchFoundNoChecks() async throws {
        // `savePullRequestDetail` returns early when a fetch carried no check runs, so a
        // repository on a classic CI status keeps the rollup the sweep computed. The closing
        // issues are written *above* that return, and this is the test that keeps them there.
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.checks = []
        detail.closingIssues = [reference(number: 142)]
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(loaded?.closingIssues.map(\.number), [142])
    }

    func testAnUnknownStoredStateReadsAsUnknown() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.closingIssues = [reference(number: 142)]
        try await database.savePullRequestDetail(detail)

        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE pull_request_closing_issues SET issueState = ? WHERE issueNumber = ?",
                arguments: ["something-new", 142]
            )
        }

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(loaded?.closingIssues.map(\.state), [.unknown])
    }

    // MARK: - The cascade

    func testTheClosingIssuesLeaveWithTheirPullRequest() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.closingIssues = [reference(number: 142)]
        try await database.savePullRequestDetail(detail)
        let before = try await closingIssueRowCount(database)
        XCTAssertEqual(before, 1)

        // The pull request was merged, so the next sweep prunes it — and the rows about it go
        // with it, exactly as `changed_files` does.
        try await database.savePullRequestSummaries([])

        let pruned = try await database.fetchPullRequestSummary(id: detail.id)
        XCTAssertNil(pruned)
        let after = try await closingIssueRowCount(database)
        XCTAssertEqual(after, 0)
    }

    func testErasingEverythingEmptiesTheClosingIssueTable() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.closingIssues = [reference(number: 142)]
        try await database.savePullRequestDetail(detail)

        try await database.eraseAllData()

        let remaining = try await closingIssueRowCount(database)
        XCTAssertEqual(remaining, 0)
    }

    private func closingIssueRowCount(_ database: DatabaseManager) async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request_closing_issues") ?? -1
        }
    }

    // MARK: - The issue side's lookups

    func testAPullRequestIsFoundByRepositoryAndNumber() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 128),
            PersistenceFixtures.summary(
                id: "PR_2",
                number: 128,
                repo: PersistenceFixtures.otherRepo
            ),
        ])

        let found = try await database.fetchPullRequestSummary(
            repo: PersistenceFixtures.repo,
            number: 128
        )
        XCTAssertEqual(found?.id, "PR_1")

        let other = try await database.fetchPullRequestSummary(
            repo: PersistenceFixtures.otherRepo,
            number: 128
        )
        XCTAssertEqual(other?.id, "PR_2")
        XCTAssertEqual(other?.checkRollup?.state, .failure)
        XCTAssertEqual(other?.reviewDecision, .changesRequested)
    }

    func testAPullRequestThatIsNotCachedIsNilRatherThanAnError() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])

        let missing = try await database.fetchPullRequestSummary(
            repo: PersistenceFixtures.repo,
            number: 9_999
        )
        XCTAssertNil(missing, "a linked pull request may be somebody else's")
    }

    func testTheLinkedPullRequestsOfAnIssueCanBeReadOnTheirOwn() async throws {
        let database = try makeDatabase()
        let summary = IssueFixtures.summary(
            links: [
                IssueFixtures.link(number: 128, author: IssueFixtures.machineActor()),
                IssueFixtures.link(number: 131, title: "test: cover the timeout"),
            ]
        )
        try await database.saveIssueSummaries([summary])

        let links = try await database.fetchLinkedPullRequests(issueID: summary.id)
        XCTAssertEqual(links.map(\.number), [128, 131])
        XCTAssertEqual(links[0].author.kind.isMachine, true)

        // A detail-shaped write knows nothing about the links and must not take them away
        // (Sprint 1's rule on `saveIssueDetail`), which is exactly what makes this read useful
        // after one.
        try await database.saveIssueDetail(
            IssueDetail(
                summary: IssueFixtures.summary(relations: [], links: []),
                bodyMarkdown: "Steps to reproduce."
            )
        )
        let afterDetail = try await database.fetchLinkedPullRequests(issueID: summary.id)
        XCTAssertEqual(afterDetail.map(\.number), [128, 131])
    }

    func testAnIssueNothingIsStoredAboutHasNoLinks() async throws {
        let database = try makeDatabase()
        let links = try await database.fetchLinkedPullRequests(issueID: "I_nothing")
        XCTAssertTrue(links.isEmpty)
    }
}
