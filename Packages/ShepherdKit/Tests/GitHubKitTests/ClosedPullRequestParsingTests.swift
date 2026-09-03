import Foundation
import ShepherdCore
import XCTest

@testable import GitHubKit

/// The closed-pull-request reads behind the track record (ADR 0027).
final class ClosedPullRequestParsingTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    // MARK: - The query

    func testTheClosedQueryIsTheOpenPrefixWithOneWordChanged() {
        XCTAssertEqual(InboxQuery.closedPullRequestPrefix, "is:pr is:closed archived:false")
        XCTAssertEqual(
            InboxQuery.closedPullRequests(
                in: repo,
                since: Date(timeIntervalSince1970: 1_780_000_000)
            ),
            "is:pr is:closed archived:false repo:schnaq/review closed:>2026-05-28"
        )
    }

    func testTheQueryDateIsFormattedInUTCWhereverTheMacIs() {
        // Just before midnight UTC: a Mac in a positive offset would otherwise send tomorrow's
        // date, and the conditional-request cache key would differ per timezone.
        let moment = Date(timeIntervalSince1970: 1_780_012_799)
        XCTAssertTrue(
            InboxQuery.closedPullRequests(in: repo, since: moment).hasSuffix("closed:>2026-05-28"),
            "the qualifier is UTC, not the Mac's calendar"
        )
    }

    // MARK: - One page

    func testAPageParsesEveryFieldAnOutcomeStores() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequests",
            try Fixture.response("closed-search-page-1")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let page = try await client.searchClosedPullRequests(
            repo: repo,
            since: Date(timeIntervalSince1970: 1_780_000_000)
        )

        XCTAssertEqual(page.totalCount, 3)
        XCTAssertTrue(page.hasNextPage)
        XCTAssertEqual(page.endCursor, "Y3Vyc29yOjI=")
        XCTAssertEqual(
            page.pullRequests.map(\.id),
            ["PR_kwDOClosedMerged", "PR_kwDOClosedRevert", "PR_kwDOClosedUnmerged"],
            "the plain Issue node and the still-open pull request are both dropped"
        )

        guard let merged = page.pullRequests.first else { return XCTFail("no rows") }
        XCTAssertEqual(merged.outcome.repo, repo)
        XCTAssertEqual(merged.number, 128)
        XCTAssertEqual(merged.title, "Refactor the token store")
        XCTAssertEqual(merged.mergeCommitOid, "4f3a9c1d2b8e7f6a5c4b3a2918273645abcdef01")
        XCTAssertTrue(merged.outcome.merged)
        XCTAssertEqual(merged.outcome.agentName, "Claude Code")
        XCTAssertEqual(merged.outcome.authorLogin, "claude[bot]")
        XCTAssertEqual(merged.outcome.changedLines, 336, "240 added plus 96 deleted")
        XCTAssertEqual(merged.outcome.reviewRounds, 2, "the change-requesting reviews")
        XCTAssertEqual(merged.outcome.source, .backfill)
        XCTAssertEqual(
            merged.outcome.closedAt,
            Date(timeIntervalSince1970: 1_787_398_200),
            "2026-08-22T11:30:00Z"
        )
        XCTAssertEqual(
            merged.outcome.openedAt,
            Date(timeIntervalSince1970: 1_787_216_400),
            "2026-08-20T09:00:00Z"
        )
    }

    func testTheFirstPushRollupBecomesThreeStatesAndNotTwo() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequests",
            try Fixture.response("closed-search-page-1")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let page = try await client.searchClosedPullRequests(repo: repo, since: Date(timeIntervalSince1970: 0))
        let byID = Dictionary(uniqueKeysWithValues: page.pullRequests.map { ($0.id, $0) })

        XCTAssertEqual(
            byID["PR_kwDOClosedMerged"]?.outcome.firstPushCIGreen,
            false,
            "the first commit's rollup was FAILURE"
        )
        XCTAssertEqual(byID["PR_kwDOClosedRevert"]?.outcome.firstPushCIGreen, true)
        XCTAssertNil(
            byID["PR_kwDOClosedUnmerged"]?.outcome.firstPushCIGreen,
            "no rollup at all says nothing about the first push"
        )
    }

    func testAPendingFirstPushIsUnknownRatherThanRed() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequests",
            try Fixture.response("closed-search-page-2")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let page = try await client.searchClosedPullRequests(repo: repo, since: Date(timeIntervalSince1970: 0))
        XCTAssertNil(page.pullRequests.first?.outcome.firstPushCIGreen)
        XCTAssertFalse(page.hasNextPage)
        XCTAssertNil(page.endCursor)
    }

    func testThePageIsAskedForWithItsCursorAndCachedByIt() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequests",
            try Fixture.response("closed-search-page-2", headers: ["ETag": "\"page-2\""])
        )
        let cache = InMemoryConditionalCache()
        let client = GitHubClient.makeForTesting(transport: transport, cache: cache)

        _ = try await client.searchClosedPullRequests(
            repo: repo,
            since: Date(timeIntervalSince1970: 1_780_000_000),
            cursor: "Y3Vyc29yOjI="
        )

        guard let request = await transport.onlyRequest() else { return }
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("Y3Vyc29yOjI="), "the cursor travels as the `after` variable")
        XCTAssertTrue(body.contains("is:pr is:closed archived:false"))

        // A GraphQL read cannot be keyed on its URL — one endpoint, every document — so the
        // client names the key itself, and the entry is stored because GitHub sent a validator.
        let key = "graphql:closedPullRequests:"
            + InboxQuery.closedPullRequests(
                in: repo,
                since: Date(timeIntervalSince1970: 1_780_000_000)
            )
            + ":100:Y3Vyc29yOjI="
        let stored = await cache.entry(for: key)
        XCTAssertEqual(stored?.etag, "\"page-2\"")
    }

    // MARK: - One pull request

    func testTheSingleReadParsesTheSameShapeAndIsMarkedAsSync() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequest(",
            try Fixture.response("closed-pull-request")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let closed = try await client.closedPullRequest(repo: repo, number: 128)

        XCTAssertEqual(closed?.outcome.prID, "PR_kwDOClosedMerged")
        XCTAssertEqual(closed?.outcome.source, .sync, "the sweep's own read is the sync source")
        XCTAssertEqual(closed?.outcome.merged, true)
        XCTAssertEqual(closed?.number, 128)
        XCTAssertTrue(
            closed?.bodyMarkdown.contains("Keychain wrapper") ?? false,
            "the body is carried because revert detection reads it"
        )
    }

    func testTheSingleReadIsOneRequestAndNotADetailFetch() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequest(",
            try Fixture.response("closed-pull-request")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.closedPullRequest(repo: repo, number: 128)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "no files, commits, reviews, threads or check runs")
    }

    func testAStillOpenPullRequestIsNilRatherThanAFabricatedOutcome() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequest(",
            Fixture.response(
                json: """
                    {"data":{"repository":{"pullRequest":{
                      "__typename":"PullRequest","id":"PR_1","number":9,"title":"open",
                      "body":"","createdAt":"2026-08-25T08:00:00Z","closedAt":null,
                      "merged":false,"mergeCommit":null,"additions":1,"deletions":1,
                      "changedFiles":1,"headRefName":"claude/open",
                      "repository":{"name":"review","owner":{"login":"schnaq"}},
                      "author":{"__typename":"Bot","login":"claude[bot]","avatarUrl":null},
                      "reviews":{"totalCount":0},"commits":{"nodes":[]}
                    }}}}
                    """
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let awaited1 = try await client.closedPullRequest(repo: repo, number: 9)
        XCTAssertNil(awaited1)
    }

    func testAPullRequestGitHubNoLongerHasIsNotFound() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdClosedPullRequest(",
            Fixture.response(json: #"{"data":{"repository":{"pullRequest":null}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.closedPullRequest(repo: repo, number: 404)
            XCTFail("expected a notFound")
        } catch let error as GitHubError {
            guard case .notFound(let resource) = error else {
                return XCTFail("expected notFound, got \(error)")
            }
            XCTAssertEqual(resource, "schnaq/review#404")
        }
    }
}
