import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

final class SearchParsingTests: XCTestCase {
    func testSweepParsesTheDocumentedSearchShape() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(queries: [.reviewRequested])
        XCTAssertEqual(summaries.count, 2, "the plain Issue node must be dropped")

        guard let agentPR = summaries.first(where: { $0.id == "PR_kwDOAgentOne" }) else {
            return XCTFail("missing the agent pull request")
        }
        XCTAssertEqual(agentPR.repo, RepoRef(owner: "schnaq", name: "review"))
        XCTAssertEqual(agentPR.number, 128)
        XCTAssertEqual(agentPR.title, "Refactor the token store")
        XCTAssertEqual(agentPR.additions, 240)
        XCTAssertEqual(agentPR.deletions, 96)
        XCTAssertEqual(agentPR.changedFiles, 7)
        XCTAssertEqual(agentPR.headRefName, "claude/refactor-token-store")
        XCTAssertEqual(agentPR.baseRefName, "main")
        XCTAssertEqual(agentPR.reviewDecision, .reviewRequired)
        XCTAssertEqual(agentPR.mergeable, .mergeable)
        XCTAssertEqual(agentPR.labels, ["agent", "refactor"])
        XCTAssertFalse(agentPR.isDraft)
        XCTAssertEqual(agentPR.checkRollup?.state, .failure)
        XCTAssertEqual(agentPR.checkRollup?.total, 4)
        XCTAssertEqual(
            agentPR.updatedAt,
            Date(timeIntervalSince1970: 1_788_162_072),
            "2026-08-31T07:41:12Z"
        )
    }

    func testAuthorProvenanceIsResolvedDuringParsing() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(queries: [.involves])
        let agentPR = summaries.first { $0.id == "PR_kwDOAgentOne" }
        let humanPR = summaries.first { $0.id == "PR_kwDOHumanTwo" }

        XCTAssertEqual(agentPR?.author.kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(agentPR?.author.kind.provenanceLabel, "Claude Code")
        XCTAssertEqual(humanPR?.author.kind, .human)
        XCTAssertNotNil(agentPR?.author.avatarURL)
    }

    func testDraftAndMissingRollupAreHandled() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(queries: [.involves])
        let humanPR = summaries.first { $0.id == "PR_kwDOHumanTwo" }
        XCTAssertEqual(humanPR?.isDraft, true)
        XCTAssertNil(humanPR?.checkRollup)
        XCTAssertNil(humanPR?.reviewDecision)
        XCTAssertEqual(humanPR?.mergeable, .conflicting)
    }

    func testRelationsComeFromTheFacetQueryAndAreUnioned() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(
            queries: [.reviewRequested, .authored, .involves]
        )
        // The same fixture answers all three facets, so every row carries both relations.
        XCTAssertEqual(summaries.count, 2, "duplicates across facets must be merged")
        for summary in summaries {
            XCTAssertEqual(summary.myRelation, [.reviewRequested, .author])
        }
    }

    func testSweepSendsOneRequestPerFacetWithTheRightQueryString() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.searchOpenPullRequests(queries: [.reviewRequested, .authored])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.method == "POST" })
        XCTAssertTrue(
            requests.allSatisfy { $0.url.absoluteString == "https://api.github.com/graphql" }
        )

        let bodies = requests.map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        XCTAssertTrue(bodies[0].contains("review-requested:@me"))
        XCTAssertTrue(bodies[1].contains("author:@me"))
        XCTAssertTrue(bodies.allSatisfy { $0.contains("is:pr is:open archived:false") })
        XCTAssertTrue(bodies.allSatisfy { $0.contains("statusCheckRollup") })
        XCTAssertTrue(bodies.allSatisfy { $0.contains("reviewDecision") })
        XCTAssertTrue(bodies.allSatisfy { $0.contains("headRefOid") })
    }

    func testEveryRequestCarriesAuthorizationAndAPIVersionHeaders() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.searchOpenPullRequests(queries: [.involves])
        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.headers["Authorization"], "Bearer ghu_test-token")
        XCTAssertEqual(request?.headers["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertNotNil(request?.headers["User-Agent"])
    }

    func testSweepResultsAreSortedMostRecentlyUpdatedFirst() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(queries: [.involves])
        XCTAssertEqual(summaries.map(\.id), ["PR_kwDOAgentOne", "PR_kwDOHumanTwo"])
    }

    func testGraphQLErrorsBecomeTypedErrors() async throws {
        let transport = MockTransport()
        let stub_graphql_errors = try Fixture.response("graphql-errors")
        await transport.route("ShepherdInboxSweep", stub_graphql_errors)
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.searchOpenPullRequests(queries: [.involves])
            XCTFail("expected a GraphQL error")
        } catch let error as GitHubError {
            guard case .graphQL(let messages) = error else {
                return XCTFail("expected .graphQL, got \(error)")
            }
            XCTAssertEqual(messages.count, 1)
            XCTAssertTrue(messages[0].contains("Could not resolve"))
        }
    }
}
