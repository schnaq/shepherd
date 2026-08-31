import XCTest
@testable import ShepherdCore

final class InboxGrouperTests: XCTestCase {
    private let claude = Fixtures.agent("claude-code", "Claude Code")
    private let copilot = Fixtures.agent("github-copilot", "GitHub Copilot")

    private func sample() -> [PullRequestSummary] {
        [
            Fixtures.summary(
                id: "pr-human",
                number: 1,
                author: Fixtures.makeActor("octocat"),
                updatedAt: -300,
                reviewDecision: .reviewRequired
            ),
            Fixtures.summary(
                id: "pr-claude",
                number: 2,
                author: Fixtures.makeActor("claude[bot]", kind: claude),
                updatedAt: 0,
                reviewDecision: .approved
            ),
            Fixtures.summary(
                id: "pr-copilot",
                number: 3,
                repo: RepoRef(owner: "schnaq", name: "other"),
                author: Fixtures.makeActor("copilot[bot]", kind: copilot),
                updatedAt: -100,
                reviewDecision: .changesRequested
            ),
            Fixtures.summary(
                id: "pr-bot",
                number: 4,
                author: Fixtures.makeActor("some[bot]", kind: .bot),
                updatedAt: -200
            ),
        ]
    }

    // MARK: - Sorting

    func testSortsMostRecentlyUpdatedFirst() {
        let sorted = InboxGrouper.sorted(sample())
        XCTAssertEqual(sorted.map(\.id), ["pr-claude", "pr-copilot", "pr-bot", "pr-human"])
    }

    func testSortIsStableForIdenticalTimestamps() {
        let a = Fixtures.summary(id: "a", number: 7, updatedAt: 0)
        let b = Fixtures.summary(id: "b", number: 9, updatedAt: 0)
        let c = Fixtures.summary(
            id: "c",
            number: 1,
            repo: RepoRef(owner: "aaa", name: "zzz"),
            updatedAt: 0
        )
        XCTAssertEqual(
            InboxGrouper.sorted([a, b, c]).map(\.id),
            InboxGrouper.sorted([c, b, a]).map(\.id)
        )
        // Repository name breaks the tie first, then the higher number.
        XCTAssertEqual(InboxGrouper.sorted([a, b, c]).map(\.id), ["c", "b", "a"])
    }

    // MARK: - Provenance facet

    func testGroupsByProvenanceWithAgentsFirst() {
        let sections = InboxGrouper.group(sample(), by: .provenance)
        XCTAssertEqual(
            sections.map(\.title),
            ["Claude Code", "GitHub Copilot", "Bots", "People"]
        )
        XCTAssertEqual(sections.map(\.count), [1, 1, 1, 1])
        XCTAssertTrue(sections.allSatisfy { $0.facet == .provenance })
    }

    func testProvenanceSectionsAreSortedInternally() {
        let claudeOld = Fixtures.summary(
            id: "old",
            number: 10,
            author: Fixtures.makeActor("claude[bot]", kind: claude),
            updatedAt: -1_000
        )
        let claudeNew = Fixtures.summary(
            id: "new",
            number: 11,
            author: Fixtures.makeActor("claude[bot]", kind: claude),
            updatedAt: 0
        )
        let sections = InboxGrouper.group([claudeOld, claudeNew], by: .provenance)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.items.map(\.id), ["new", "old"])
    }

    // MARK: - Repository facet

    func testGroupsByRepositoryAlphabetically() {
        let sections = InboxGrouper.group(sample(), by: .repository)
        XCTAssertEqual(sections.map(\.title), ["schnaq/other", "schnaq/review"])
        XCTAssertEqual(sections.first?.count, 1)
        XCTAssertEqual(sections.last?.count, 3)
    }

    // MARK: - Review-state facet

    func testGroupsByReviewStateInBlockingOrder() {
        let sections = InboxGrouper.group(sample(), by: .reviewState)
        XCTAssertEqual(
            sections.map(\.title),
            ["Review required", "Changes requested", "Approved", "No review decision"]
        )
        XCTAssertEqual(sections.first?.items.map(\.id), ["pr-human"])
        XCTAssertEqual(sections.last?.items.map(\.id), ["pr-bot"])
    }

    func testEmptySectionsAreOmitted() {
        let only = [Fixtures.summary(id: "x", reviewDecision: .approved)]
        let sections = InboxGrouper.group(only, by: .reviewState)
        XCTAssertEqual(sections.map(\.title), ["Approved"])
    }

    func testGroupingAnEmptyInboxProducesNoSections() {
        for facet in InboxFacet.allCases {
            XCTAssertTrue(InboxGrouper.group([], by: facet).isEmpty)
        }
    }

    func testGroupingIsDeterministicAcrossRuns() {
        let first = InboxGrouper.group(sample(), by: .provenance).map(\.id)
        let second = InboxGrouper.group(Array(sample().reversed()), by: .provenance).map(\.id)
        XCTAssertEqual(first, second)
    }
}
