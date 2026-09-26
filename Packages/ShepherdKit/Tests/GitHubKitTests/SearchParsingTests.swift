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
        XCTAssertEqual(agentPR.mergeStateStatus, .behind)
        XCTAssertEqual(
            agentPR.stack,
            PullRequestStack(number: 7, size: 3, position: 2, baseRefName: "main")
        )
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
        XCTAssertEqual(humanPR?.mergeStateStatus, .dirty)
        XCTAssertNil(humanPR?.stack, "a pull request outside a stack has null for both fields")
    }

    func testRelationsComeFromTheFacetQueryAndAreUnioned() async throws {
        let transport = MockTransport()
        let stub_search_response = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", stub_search_response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(
            queries: [.reviewRequested, .authored, .involves]
        )
        // The same fixture answers all three facets, so every row carries all three relations.
        XCTAssertEqual(summaries.count, 2, "duplicates across facets must be merged")
        for summary in summaries {
            XCTAssertEqual(summary.myRelation, [.reviewRequested, .author, .involved])
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

    func testTheSweepReadsTheHeadCommitsTrailersSoAnAgentIsKnownFromTheStart() async throws {
        // A Claude Code pull request on an ordinary branch, opened under a human account: only the
        // commit's `Co-Authored-By` trailer says who wrote it. Found only by the detail fetch, the
        // row used to sit under "People" until then and jump into "Claude Code" the moment the
        // detail loaded.
        let json = """
        {"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
          {"__typename":"PullRequest","id":"PR_trailer","number":7,"title":"Tidy the sync loop",
           "createdAt":"2026-09-20T09:00:00Z","updatedAt":"2026-09-25T09:00:00Z","isDraft":false,
           "headRefName":"tidy-sync","headRefOid":"abc","baseRefName":"main",
           "repository":{"name":"shepherd","owner":{"login":"schnaq"}},
           "author":{"__typename":"User","login":"n2o","avatarUrl":null},
           "labels":{"nodes":[]},
           "commits":{"nodes":[{"commit":{"oid":"abc",
             "messageBody":"Keeps the loop alive.\\n\\nCo-Authored-By: Claude <noreply@anthropic.com>",
             "statusCheckRollup":null}}]}}
        ]}}}
        """
        let transport = MockTransport()
        await transport.route("ShepherdInboxSweep", Fixture.response(json: json))
        let client = GitHubClient.makeForTesting(transport: transport)

        let summaries = try await client.searchOpenPullRequests(queries: [.involves])

        XCTAssertEqual(summaries.first?.author.kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(summaries.first?.author.login, "n2o")
        XCTAssertTrue(GraphQLDocuments.searchPullRequests.contains("messageBody"))
    }

    func testTheSweepAsksForMergeStateStatusNextToMergeable() {
        // The merge series (ADR 0041) reads `BEHIND` from every sweep; without the field in the
        // query nothing would ever bring a branch up to date.
        XCTAssertTrue(GraphQLDocuments.searchPullRequests.contains("mergeStateStatus"))
    }

    func testMergeStateStatusMapsEveryGitHubSpellingAndDropsUnknownValues() {
        let graphQL: [String: MergeStateStatus] = [
            "BEHIND": .behind, "BLOCKED": .blocked, "CLEAN": .clean, "DIRTY": .dirty,
            "DRAFT": .draft, "HAS_HOOKS": .hasHooks, "UNSTABLE": .unstable, "UNKNOWN": .unknown,
        ]
        for (raw, expected) in graphQL {
            XCTAssertEqual(ResponseMapping.mergeStateStatus(raw), expected, raw)
            // REST's `mergeable_state` spells the same values in lower case.
            XCTAssertEqual(ResponseMapping.mergeStateStatus(raw.lowercased()), expected, raw)
        }
        XCTAssertEqual(Set(graphQL.values), Set(MergeStateStatus.allCases))
        XCTAssertNil(ResponseMapping.mergeStateStatus(nil))
        XCTAssertNil(
            ResponseMapping.mergeStateStatus("QUEUED_SOMEWHERE"),
            "a value GitHub adds later reads as absent, never as a state the series acts on"
        )
    }

    func testTheSweepAsksForTheStackAndThePullRequestsPlaceInIt() {
        // ADR 0042: the row's "Stack 2/3" chip and the drain's choice of the asynchronous merge
        // both read what the sweep stored; without the selection every row reads as unstacked.
        let query = GraphQLDocuments.searchPullRequests
        XCTAssertTrue(query.contains("stack { number size baseRefName }"))
        XCTAssertTrue(query.contains("stackEntry { position }"))
    }

    func testAStackIsOnlyMappedWhenTheStackAndTheEntryAreBothComplete() throws {
        func node(_ json: String) throws -> SearchNodeDTO {
            try JSONDecoder().decode(SearchNodeDTO.self, from: Data(json.utf8))
        }
        let complete = try node(
            #"{"stack":{"number":4,"size":2,"baseRefName":"trunk"},"stackEntry":{"position":1}}"#
        )
        XCTAssertEqual(
            ResponseMapping.stack(complete.stack, entry: complete.stackEntry),
            PullRequestStack(number: 4, size: 2, position: 1, baseRefName: "trunk")
        )

        let unstacked = try node(#"{"stack":null,"stackEntry":null}"#)
        XCTAssertNil(ResponseMapping.stack(unstacked.stack, entry: unstacked.stackEntry))
        let absent = try node("{}")
        XCTAssertNil(ResponseMapping.stack(absent.stack, entry: absent.stackEntry))

        // Half a stack is not a place in one: without a position the chip could not say 2/3,
        // and the stack's number without a size could not say how many merge along.
        let noEntry = try node(#"{"stack":{"number":4,"size":2,"baseRefName":"trunk"},"stackEntry":null}"#)
        XCTAssertNil(ResponseMapping.stack(noEntry.stack, entry: noEntry.stackEntry))
        let noStack = try node(#"{"stack":null,"stackEntry":{"position":1}}"#)
        XCTAssertNil(ResponseMapping.stack(noStack.stack, entry: noStack.stackEntry))
        let noSize = try node(#"{"stack":{"number":4,"baseRefName":"trunk"},"stackEntry":{"position":1}}"#)
        XCTAssertNil(ResponseMapping.stack(noSize.stack, entry: noSize.stackEntry))
    }
}
