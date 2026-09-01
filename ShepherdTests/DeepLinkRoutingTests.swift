import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app-side half of the `shepherd://` scheme (ADR 0013): resolving a pull-request link
/// against the local cache, and mapping an inbox filter onto rail state.
///
/// The URL grammar itself is tested in `ShepherdCoreTests/DeepLinkTests.swift`, where it runs
/// headlessly on both CI runners.
final class DeepLinkRoutingTests: XCTestCase {
    // MARK: - Resolving a pull request against the cache

    func testFindsCachedPullRequestByRepoAndNumber() {
        let rows = [
            summary(id: "pr-1", repo: RepoRef(owner: "schnaq", name: "review"), number: 41),
            summary(id: "pr-2", repo: RepoRef(owner: "schnaq", name: "review"), number: 42),
            summary(id: "pr-3", repo: RepoRef(owner: "other", name: "review"), number: 42),
        ]
        XCTAssertEqual(
            AppEnvironment.pullRequestID(
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 42,
                in: rows
            ),
            "pr-2"
        )
    }

    func testRepositoryMatchIgnoresCase() {
        // A link carries whatever casing was typed; the cache holds what GitHub returned.
        let rows = [summary(id: "pr-1", repo: RepoRef(owner: "schnaq", name: "review"), number: 7)]
        XCTAssertEqual(
            AppEnvironment.pullRequestID(
                repo: RepoRef(owner: "Schnaq", name: "Review"),
                number: 7,
                in: rows
            ),
            "pr-1"
        )
    }

    func testMissingPullRequestIsNotFound() {
        let rows = [summary(id: "pr-1", repo: RepoRef(owner: "schnaq", name: "review"), number: 7)]
        XCTAssertNil(
            AppEnvironment.pullRequestID(
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 8,
                in: rows
            )
        )
        XCTAssertNil(
            AppEnvironment.pullRequestID(
                repo: RepoRef(owner: "schnaq", name: "shepherd"),
                number: 7,
                in: rows
            )
        )
        XCTAssertNil(
            AppEnvironment.pullRequestID(
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 7,
                in: []
            )
        )
    }

    // MARK: - Inbox filters

    func testViewFiltersReplaceTheWholeRailSelection() {
        XCTAssertEqual(
            InboxRailSelection(.needsMyReview),
            InboxRailSelection(smartView: .needsMyReview)
        )
        XCTAssertEqual(
            InboxRailSelection(.myPullRequests),
            InboxRailSelection(smartView: .myPullRequests)
        )
        XCTAssertEqual(InboxRailSelection(.involved), InboxRailSelection(smartView: .involved))
        XCTAssertEqual(
            InboxRailSelection(.approvedByMe),
            InboxRailSelection(smartView: .approvedByMe)
        )
    }

    func testFacetFiltersWidenTheSmartViewToInvolved() {
        XCTAssertEqual(
            InboxRailSelection(.bots),
            InboxRailSelection(smartView: .involved, provenanceFilter: .bots)
        )
        XCTAssertEqual(
            InboxRailSelection(.humans),
            InboxRailSelection(smartView: .involved, provenanceFilter: .humans)
        )
        XCTAssertEqual(
            InboxRailSelection(.agent(id: "claude-code")),
            InboxRailSelection(
                smartView: .involved,
                provenanceFilter: .agent(id: "claude-code")
            )
        )
        XCTAssertEqual(
            InboxRailSelection(.repository(RepoRef(owner: "schnaq", name: "review"))),
            InboxRailSelection(
                smartView: .involved,
                repoFilter: RepoRef(owner: "schnaq", name: "review")
            )
        )
    }

    func testFilterTokensFromLinksReachRailState() throws {
        // The end-to-end shape a script produces: a URL in, rail state out.
        let url = try XCTUnwrap(URL(string: "shepherd://inbox?filter=agent:Claude-Code"))
        guard case .inbox(let filter) = try XCTUnwrap(DeepLink.parse(url)),
              let filter
        else { return XCTFail("expected an inbox link with a filter") }
        XCTAssertEqual(
            InboxRailSelection(filter),
            InboxRailSelection(smartView: .involved, provenanceFilter: .agent(id: "claude-code"))
        )
    }

    // MARK: - Fixtures

    private func summary(id: String, repo: RepoRef, number: Int) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Title",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            isDraft: false,
            headRefName: "feature",
            headRefOid: "abc",
            baseRefName: "main"
        )
    }
}
