import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

/// The issues sweep's parsing (ADR 0032): one recorded response per facet, the merge across
/// facets, and the timeline-shaped fallback.
///
/// The fallback has a fixture of its own precisely because it is *not* wired: whichever way the
/// live schema goes, the shape Shepherd is not currently sending still has a regression test, so
/// switching to it is a one-line change rather than a rewrite.
final class ResponseMappingIssueTests: XCTestCase {
    /// Routes the three facet fixtures by the query string in the request body — all three
    /// requests carry the same document, so the URL cannot tell them apart.
    private func makeClient(transport: MockTransport) async throws -> GitHubClient {
        let stub_assigned = try Fixture.response("issue-search-assigned")
        let stub_authored = try Fixture.response("issue-search-authored")
        let stub_mentioned = try Fixture.response("issue-search-mentioned")
        await transport.route("assignee:@me", stub_assigned)
        await transport.route("author:@me", stub_authored)
        await transport.route("mentions:@me", stub_mentioned)
        return GitHubClient.makeForTesting(transport: transport)
    }

    func testTheSweepParsesTheDocumentedIssueShape() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport: transport)

        let issues = try await client.searchOpenIssues(queries: [.assigned])
        XCTAssertEqual(issues.count, 2, "the plain PullRequest node must be dropped")

        guard let issue = issues.first(where: { $0.id == "I_kwDOIssueOne" }) else {
            return XCTFail("missing the assigned issue")
        }
        XCTAssertEqual(issue.repo, RepoRef(owner: "schnaq", name: "review"))
        XCTAssertEqual(issue.number, 42)
        XCTAssertEqual(issue.slug, "schnaq/review#42")
        XCTAssertEqual(issue.title, "Login times out after the token refresh")
        XCTAssertEqual(issue.state, .open)
        XCTAssertNil(issue.stateReason)
        XCTAssertNil(issue.closedAt)
        XCTAssertEqual(issue.labels, ["bug", "auth"])
        XCTAssertEqual(issue.commentCount, 4)
        XCTAssertEqual(issue.myRelation, [.assigned])
        XCTAssertEqual(issue.author.login, "octocat")
        XCTAssertEqual(issue.author.kind, .human)
        XCTAssertEqual(
            issue.createdAt,
            Date(timeIntervalSince1970: 1_787_220_000),
            "2026-08-20T10:00:00Z"
        )
        XCTAssertEqual(
            issue.updatedAt,
            Date(timeIntervalSince1970: 1_788_163_200),
            "2026-08-31T08:00:00Z"
        )
    }

    func testAClosedIssueCarriesItsCloseDateAndRawReason() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport: transport)

        let issues = try await client.searchOpenIssues(queries: [.assigned])
        guard let closed = issues.first(where: { $0.id == "I_kwDOIssueTwo" }) else {
            return XCTFail("missing the closed issue")
        }
        XCTAssertEqual(closed.state, .closed)
        // Raw and tolerant: shown, never branched on.
        XCTAssertEqual(closed.stateReason, "COMPLETED")
        XCTAssertEqual(closed.closedAt, Date(timeIntervalSince1970: 1_788_004_800))
        XCTAssertEqual(closed.labels, [])
        XCTAssertEqual(closed.commentCount, 0)
        XCTAssertTrue(closed.linkedPullRequests.isEmpty)
        XCTAssertFalse(closed.hasAgentPullRequest)
    }

    func testLinkedPullRequestsCarryTheirRepositoryStateAndProvenance() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport: transport)

        let issues = try await client.searchOpenIssues(queries: [.assigned])
        guard let issue = issues.first(where: { $0.id == "I_kwDOIssueOne" }) else {
            return XCTFail("missing the assigned issue")
        }
        XCTAssertEqual(issue.linkedPullRequests.map(\.number), [128, 131])
        XCTAssertEqual(issue.linkedPullRequests.map(\.state), ["OPEN", "MERGED"])
        XCTAssertEqual(issue.linkedPullRequests[0].id, "schnaq/review#128")
        XCTAssertEqual(issue.linkedPullRequests[0].repo.fullName, "schnaq/review")
        XCTAssertEqual(issue.linkedPullRequests[0].author.kind.agentIdentity?.id, "dependabot")
        XCTAssertEqual(issue.linkedPullRequests[1].author.kind, .human)
        // The facet's whole input, derived from the links rather than stored beside them.
        XCTAssertTrue(issue.hasAgentPullRequest)
    }

    func testFacetsAreMergedByIDUnioningRelationsAndLinks() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport: transport)

        let issues = try await client.searchOpenIssues()
        XCTAssertEqual(
            issues.map(\.id),
            ["I_kwDOIssueOne", "I_kwDOIssueThree", "I_kwDOIssueTwo"],
            "most recently updated first, then repository, then the higher number"
        )

        guard let issue = issues.first(where: { $0.id == "I_kwDOIssueOne" }) else {
            return XCTFail("missing the merged issue")
        }
        XCTAssertEqual(issue.myRelation, [.assigned, .authored])
        // The freshest copy of the mutable fields wins — the authored facet's copy is a day older
        // and carries a different title and comment count.
        XCTAssertEqual(issue.title, "Login times out after the token refresh")
        XCTAssertEqual(issue.commentCount, 4)
        XCTAssertEqual(issue.labels, ["bug", "auth"])
        // …but the links are unioned, because `first: 5` caps each answer separately.
        XCTAssertEqual(issue.linkedPullRequests.map(\.number), [128, 131, 140])
    }

    func testTheSweepSendsOneRequestPerFacetAgainstTheIssueDocument() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport: transport)

        _ = try await client.searchOpenIssues()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.method == "POST" })
        XCTAssertTrue(
            requests.allSatisfy { $0.url.absoluteString == "https://api.github.com/graphql" },
            "the issues sweep adds no host"
        )

        let bodies = requests.map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        XCTAssertTrue(bodies[0].contains("assignee:@me"))
        XCTAssertTrue(bodies[1].contains("author:@me"))
        XCTAssertTrue(bodies[2].contains("mentions:@me"))
        XCTAssertTrue(bodies.allSatisfy { $0.contains("is:issue is:open archived:false") })
        XCTAssertTrue(bodies.allSatisfy { $0.contains("ShepherdIssueSweep") })
        XCTAssertTrue(bodies.allSatisfy { $0.contains("closedByPullRequestsReferences") })
        XCTAssertTrue(bodies.allSatisfy { $0.contains("includeClosedPrs: true") })
        XCTAssertTrue(
            bodies.allSatisfy { !$0.contains("timelineItems") },
            "the fallback shape is not what the client sends"
        )
    }

    func testGraphQLErrorsBecomeTypedErrors() async throws {
        let transport = MockTransport()
        let stub_graphql_errors = try Fixture.response("graphql-errors")
        await transport.route("ShepherdIssueSweep", stub_graphql_errors)
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.searchOpenIssues(queries: [.assigned])
            XCTFail("expected a GraphQL error")
        } catch let error as GitHubError {
            guard case .graphQL(let messages) = error else {
                return XCTFail("expected .graphQL, got \(error)")
            }
            XCTAssertFalse(messages.isEmpty)
        }
    }

    // MARK: - The fallback shape

    /// Decodes the timeline fixture the way the client would, without sending it.
    private func timelineNode() throws -> IssueSearchNodeDTO {
        let data = try Fixture.data("issue-search-timeline")
        let envelope: GraphQLEnvelope<SearchIssuesData> = try RESTJSON.decodeGraphQL(data)
        guard let node = envelope.data?.search?.nodes?.compactMap({ $0 }).first else {
            throw Fixture.LoadError.missing("issue-search-timeline node")
        }
        return node
    }

    func testTheFallbackMapperReadsTheLinksOutOfTheTimeline() throws {
        let node = try timelineNode()
        guard let issue = ResponseMapping.issueRowSummary(
            fromTimelineOf: node,
            relations: [.assigned],
            detector: TestRegistry.detector
        ) else {
            return XCTFail("the fallback shape must map to a row")
        }

        // Everything but the links is the same mapping, so the row is complete either way.
        XCTAssertEqual(issue.id, "I_kwDOIssueOne")
        XCTAssertEqual(issue.number, 42)
        XCTAssertEqual(issue.labels, ["bug", "auth"])
        XCTAssertEqual(issue.commentCount, 4)
        XCTAssertEqual(issue.myRelation, [.assigned])

        // A `ConnectedEvent` is always a link; a `CrossReferencedEvent` only when it says it
        // closes the target; a duplicate is one link; and a cross-reference from another *issue*
        // is not a pull request at all.
        XCTAssertEqual(issue.linkedPullRequests.map(\.number), [128, 131])
        XCTAssertTrue(issue.hasAgentPullRequest)
    }

    func testTheFallbackDocumentSelectsBothTimelineItemTypes() {
        let document = GraphQLDocuments.searchIssuesWithTimelineLinks
        XCTAssertTrue(document.contains("CROSS_REFERENCED_EVENT"))
        XCTAssertTrue(document.contains("CONNECTED_EVENT"))
        XCTAssertTrue(document.contains("willCloseTarget"))
        XCTAssertFalse(
            document.contains("closedByPullRequestsReferences"),
            "the fallback exists because that field may be unavailable"
        )
    }

    func testThePrimaryMapperIgnoresATimelineItSelectedNothingFor() throws {
        // The two mappers read two different fields, so handing the timeline fixture to the
        // primary one yields a row with no links rather than a wrong one.
        let node = try timelineNode()
        let issue = ResponseMapping.issueRowSummary(
            from: node,
            relations: [.assigned],
            detector: TestRegistry.detector
        )
        XCTAssertEqual(issue?.id, "I_kwDOIssueOne")
        XCTAssertEqual(issue?.linkedPullRequests.count, 0)
    }
}
