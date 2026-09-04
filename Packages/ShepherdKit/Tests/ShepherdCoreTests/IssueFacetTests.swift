import Foundation
import XCTest
@testable import ShepherdCore

/// The issues rail's own facets (ADR 0032): pure counting, so the numbers the sidebar prints are
/// pinned on the Linux runner rather than discovered in a window.
final class IssueFacetTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    private func issue(
        _ number: Int,
        repo: RepoRef? = nil,
        labels: [String] = [],
        daysAgo: Double = 0,
        state: IssueSummary.State = .open,
        linkedPullRequests: [LinkedPullRequestReference] = []
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: "I_\(number)",
            repo: repo ?? self.repo,
            number: number,
            title: "Issue \(number)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: now.addingTimeInterval(-daysAgo * 24 * 3_600),
            updatedAt: now,
            state: state,
            labels: labels,
            linkedPullRequests: linkedPullRequests
        )
    }

    private func link(
        _ number: Int,
        kind: ActorKind
    ) -> LinkedPullRequestReference {
        LinkedPullRequestReference(
            repo: repo,
            number: number,
            title: "Fix \(number)",
            state: "OPEN",
            author: ShepherdCore.Actor(login: "author-\(number)", kind: kind)
        )
    }

    /// A recognised agent, spelled neutrally: the facet's question is "did somebody hand this to
    /// a machine", and which machine is ``AgentDetectorTests``' business.
    private var agentKind: ActorKind {
        .agent(
            AgentIdentity(
                id: "example-agent",
                displayName: "Example Agent",
                matchedBy: .login
            )
        )
    }

    // MARK: - Labels

    func testLabelFacetsAreSortedByCountThenName() {
        let rows = [
            issue(1, labels: ["bug", "ui"]),
            issue(2, labels: ["bug"]),
            issue(3, labels: ["bug", "docs"]),
            issue(4, labels: ["ui"]),
        ]
        let facets = IssueFacets.labelFacets(rows)
        XCTAssertEqual(facets.facets.map(\.name), ["bug", "ui", "docs"])
        XCTAssertEqual(facets.facets.map(\.count), [3, 2, 1])
        XCTAssertEqual(facets.hiddenCount, 0)
    }

    func testLabelTiesBreakCaseInsensitivelyOnTheName() {
        let rows = [issue(1, labels: ["Zebra"]), issue(2, labels: ["apple"])]
        XCTAssertEqual(IssueFacets.labelFacets(rows).facets.map(\.name), ["apple", "Zebra"])
    }

    func testALabelNobodyCarriesIsAbsentRatherThanZero() {
        XCTAssertTrue(IssueFacets.labelFacets([issue(1)]).isEmpty)
        XCTAssertTrue(IssueFacets.labelFacets([]).isEmpty)
    }

    func testTheLabelFacetIsCappedAndSaysHowManyItLeftOut() {
        // Ten distinct labels, one issue each, so the order is the name order and the cap is the
        // only thing under test.
        let rows = (1...10).map { issue($0, labels: ["label-\($0)"]) }
        let facets = IssueFacets.labelFacets(rows, limit: 3)
        XCTAssertEqual(facets.facets.count, 3)
        XCTAssertEqual(facets.hiddenCount, 7)
        XCTAssertEqual(IssueFacets.labelFacets(rows).facets.count, IssueFacets.labelFacetLimit)
        XCTAssertEqual(
            IssueFacets.labelFacets(rows).hiddenCount,
            10 - IssueFacets.labelFacetLimit
        )
    }

    func testALabelRepeatedOnOneIssueCountsOnce() {
        XCTAssertEqual(
            IssueFacets.labelFacets([issue(1, labels: ["bug", "bug"])]).facets,
            [IssueLabelFacet(name: "bug", count: 1)]
        )
    }

    // MARK: - Age

    func testAgeFacetsUseTheSharedBucketingAndOmitEmptyBuckets() {
        let rows = [
            issue(1, daysAgo: 0),
            issue(2, daysAgo: 3),
            issue(3, daysAgo: 4),
            issue(4, daysAgo: 60),
        ]
        let facets = IssueFacets.ageFacets(rows, now: now)
        XCTAssertEqual(facets.map(\.bucket), [.today, .thisWeek, .older])
        XCTAssertEqual(facets.map(\.count), [1, 2, 1])
    }

    func testAgeFacetsAreEmptyForAnEmptySection() {
        XCTAssertTrue(IssueFacets.ageFacets([], now: now).isEmpty)
    }

    // MARK: - Agent pull requests

    func testAgentPullRequestFacetCountsBothHalvesWithHasNoneFirst() {
        let rows = [
            issue(1, linkedPullRequests: [link(10, kind: agentKind)]),
            issue(2, linkedPullRequests: [link(11, kind: .human)]),
            issue(3),
        ]
        let facets = IssueFacets.agentPullRequestFacets(rows)
        XCTAssertEqual(facets.map(\.filter), [.hasNone, .hasAgentPullRequest])
        XCTAssertEqual(facets.map(\.count), [2, 1])
    }

    func testABotLinkedPullRequestCountsAsAMachine() {
        // `hasAgentPullRequest` reads `ActorKind.isMachine`, not `agentIdentity`: an
        // unrecognised bot is still not a person.
        let rows = [issue(1, linkedPullRequests: [link(10, kind: .bot)])]
        XCTAssertEqual(
            IssueFacets.agentPullRequestFacets(rows),
            [IssueAgentPullRequestFacet(filter: .hasAgentPullRequest, count: 1)]
        )
    }

    func testAOneSidedFacetReturnsOneRowSoTheRailCanDrawNothing() {
        // The rail's gate is `facets.count > 1`: one populated half would filter to everything
        // or to nothing.
        XCTAssertEqual(IssueFacets.agentPullRequestFacets([issue(1)]).count, 1)
        XCTAssertTrue(IssueFacets.agentPullRequestFacets([]).isEmpty)
    }

    func testTheFilterHalvesAgreeWithTheRowPropertyAndTheStore() {
        let withAgent = issue(1, linkedPullRequests: [link(10, kind: agentKind)])
        let without = issue(2)
        XCTAssertTrue(IssueAgentPullRequestFilter.hasAgentPullRequest.matches(withAgent))
        XCTAssertFalse(IssueAgentPullRequestFilter.hasAgentPullRequest.matches(without))
        XCTAssertTrue(IssueAgentPullRequestFilter.hasNone.matches(without))
        XCTAssertFalse(IssueAgentPullRequestFilter.hasNone.matches(withAgent))
        XCTAssertTrue(IssueAgentPullRequestFilter.hasAgentPullRequest.storeValue)
        XCTAssertFalse(IssueAgentPullRequestFilter.hasNone.storeValue)
    }

    // MARK: - State

    func testStateFacetCountsBothHalvesWithOpenFirst() {
        let rows = [
            issue(1),
            issue(2, state: .closed),
            issue(3),
        ]
        let facets = IssueFacets.stateFacets(rows)
        XCTAssertEqual(facets.map(\.filter), [.open, .closed])
        XCTAssertEqual(facets.map(\.count), [2, 1])
    }

    func testAStateNobodyIsInIsAbsentRatherThanZero() {
        XCTAssertEqual(
            IssueFacets.stateFacets([issue(1)]),
            [IssueStateFacet(filter: .open, count: 1)]
        )
        XCTAssertEqual(
            IssueFacets.stateFacets([issue(1, state: .closed)]),
            [IssueStateFacet(filter: .closed, count: 1)]
        )
        XCTAssertTrue(IssueFacets.stateFacets([]).isEmpty)
    }

    func testAStateShepherdDoesNotModelCountsAsOpen() {
        // The half is "not closed" rather than "open", which is exactly where the store's
        // `includeClosed` has always drawn the line — so a word this build does not know keeps
        // the row on screen instead of hiding it from both halves.
        let unknown = issue(1, state: .unknown)
        XCTAssertTrue(IssueStateFilter.open.matches(unknown))
        XCTAssertFalse(IssueStateFilter.closed.matches(unknown))
        XCTAssertEqual(
            IssueFacets.stateFacets([unknown]),
            [IssueStateFacet(filter: .open, count: 1)]
        )
    }

    func testTheStateHalvesAgreeWithTheRowsTheyCount() {
        let openRow = issue(1)
        let closedRow = issue(2, state: .closed)
        XCTAssertTrue(IssueStateFilter.open.matches(openRow))
        XCTAssertFalse(IssueStateFilter.open.matches(closedRow))
        XCTAssertTrue(IssueStateFilter.closed.matches(closedRow))
        XCTAssertFalse(IssueStateFilter.closed.matches(openRow))
        XCTAssertLessThan(
            IssueStateFilter.open.facetSortIndex,
            IssueStateFilter.closed.facetSortIndex
        )
    }
}
