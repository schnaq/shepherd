import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

final class DetailParsingTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    /// Wires up every endpoint a detail fetch touches. The most specific URL fragments are
    /// registered first, because the mock matches in registration order.
    private func makeTransport() async throws -> MockTransport {
        let transport = MockTransport()
        let files = try Fixture.response("pull-files-page")
        let commits = try Fixture.response("pull-commits")
        let reviews = try Fixture.response("pull-reviews")
        let threads = try Fixture.response("review-threads")
        let checks = try Fixture.response("check-runs")
        let pull = try Fixture.response("pull-request")
        await transport.route("/pulls/128/files", files)
        await transport.route("/pulls/128/commits", commits)
        await transport.route("/pulls/128/reviews", reviews)
        await transport.route("ShepherdReviewThreads", threads)
        await transport.route("check-runs", checks)
        await transport.route("/pulls/128", pull)
        return transport
    }

    func testDetailFetchAssemblesEveryEndpoint() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)

        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        XCTAssertEqual(detail.id, "PR_kwDOAgentOne")
        XCTAssertEqual(detail.number, 128)
        XCTAssertEqual(detail.repo, repo)
        XCTAssertTrue(detail.bodyMarkdown.hasPrefix("Moves the Keychain wrapper"))
        XCTAssertEqual(detail.files.count, 4)
        XCTAssertEqual(detail.commits.count, 2)
        XCTAssertEqual(detail.threads.count, 2)
        XCTAssertEqual(detail.checks.count, 3)
        XCTAssertEqual(detail.timeline.count, 5)
    }

    func testTheDetailFetchReadsMergeStateStatusFromRESTsMergeableState() async throws {
        // REST's `mergeable_state` carries the same values as GraphQL's `mergeStateStatus`, so a
        // detail fetch does not wipe the `behind` the sweep stored (ADR 0041).
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)

        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        XCTAssertEqual(detail.summary.mergeStateStatus, .behind)
        XCTAssertEqual(detail.summary.mergeable, .mergeable, "the boolean still decides mergeable")
    }

    func testTheDetailFetchReadsTheStackFromTheRESTResource() async throws {
        // REST names the stack's trunk `base.ref` and its repository-scoped number `number`;
        // `id` is a database id Shepherd has no use for (ADR 0042).
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)

        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        XCTAssertEqual(
            detail.summary.stack,
            PullRequestStack(number: 7, size: 3, position: 2, baseRefName: "main")
        )
    }

    func testARESTStackMissingAFieldMapsToNoStack() throws {
        func pull(_ json: String) throws -> RESTPullRequestDTO {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(RESTPullRequestDTO.self, from: Data(json.utf8))
        }
        XCTAssertNil(ResponseMapping.stack(rest: try pull("{}").stack))
        XCTAssertNil(ResponseMapping.stack(rest: try pull(#"{"stack":null}"#).stack))
        XCTAssertNil(
            ResponseMapping.stack(rest: try pull(#"{"stack":{"size":3,"position":2,"number":7}}"#).stack),
            "no base branch"
        )
        XCTAssertNil(
            ResponseMapping.stack(
                rest: try pull(#"{"stack":{"base":{"ref":"main"},"size":3,"id":789,"number":7}}"#).stack
            ),
            "no position"
        )
        XCTAssertEqual(
            ResponseMapping.stack(
                rest: try pull(#"{"stack":{"base":{"ref":"main"},"size":3,"position":3,"number":7}}"#).stack
            ),
            PullRequestStack(number: 7, size: 3, position: 3, baseRefName: "main"),
            "the base sha and the stack's id are not needed"
        )
    }

    func testChangedFilesArePreservedIncludingRenamesAndBinaries() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        let files = try await client.changedFiles(repo: repo, number: 128)

        XCTAssertEqual(files.map(\.path), [
            "Sources/Auth/TokenStore.swift",
            "Sources/Auth/KeychainTokenStore.swift",
            "Resources/icon.png",
            "Tests/AuthTests/LegacyKeychainTests.swift",
        ])
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[0].additions, 120)
        XCTAssertEqual(files[0].deletions, 40)
        XCTAssertTrue(files[0].hasPatch)

        XCTAssertEqual(files[1].status, .renamed)
        XCTAssertEqual(files[1].previousPath, "Sources/Auth/Keychain.swift")

        XCTAssertEqual(files[2].status, .added)
        XCTAssertFalse(files[2].hasPatch, "binary files come back without a patch")

        XCTAssertEqual(files[3].status, .removed)
    }

    func testFilesRequestIsPaginated() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        _ = try await client.changedFiles(repo: repo, number: 128)

        let request = await transport.firstRequest(containing: "/pulls/128/files")
        let url = request?.url.absoluteString ?? ""
        XCTAssertTrue(url.contains("per_page=100"), url)
        XCTAssertTrue(url.contains("page=1"), url)
        // Four files is less than a full page, so no second request is made.
        let requests = await transport.requests
        let fileRequests = requests.filter { $0.url.absoluteString.contains("/files") }
        XCTAssertEqual(fileRequests.count, 1)
    }

    func testReviewThreadsCarryIDsAndResolutionState() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        let threads = try await client.reviewThreads(repo: repo, number: 128)

        XCTAssertEqual(threads.count, 2)
        let first = threads[0]
        XCTAssertEqual(first.id, "PRRT_kwDOThreadOne")
        XCTAssertEqual(first.path, "Sources/Auth/TokenStore.swift")
        XCTAssertEqual(first.line, 42)
        XCTAssertEqual(first.originalLine, 40)
        XCTAssertEqual(first.side, .right)
        XCTAssertFalse(first.isResolved)
        XCTAssertFalse(first.isOutdated)
        XCTAssertTrue(first.isAnchoredInCurrentDiff)
        XCTAssertEqual(first.comments.count, 2)
        XCTAssertEqual(first.comments[0].databaseID, 987_654_321)
        XCTAssertEqual(first.comments[0].author.kind, .human)
        XCTAssertEqual(first.comments[1].author.kind.agentIdentity?.id, "claude-code")

        let second = threads[1]
        XCTAssertTrue(second.isResolved)
        XCTAssertTrue(second.isOutdated)
        XCTAssertEqual(second.side, .left)
        // GraphQL nulls `line` precisely when the thread no longer maps onto the current diff.
        // Backfilling it from `originalLine` — which points into an older commit's diff —
        // would park the conversation on whatever code happens to be at line 12 today.
        XCTAssertNil(second.line, "a lost anchor stays lost")
        XCTAssertEqual(second.originalLine, 12, "kept for display only")
        XCTAssertFalse(second.isAnchoredInCurrentDiff)
    }

    func testCheckRunsAndRollup() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        let checks = try await client.checkRuns(repo: repo, ref: "3f1a9c0d")

        XCTAssertEqual(checks.count, 3)
        XCTAssertEqual(checks[0].status, .completed)
        XCTAssertEqual(checks[0].conclusion, .success)
        XCTAssertEqual(checks[0].summary, "142 tests, 0 failures")
        XCTAssertNotNil(checks[0].detailsURL)
        XCTAssertEqual(checks[1].conclusion, .failure)
        XCTAssertEqual(checks[2].status, .inProgress)
        XCTAssertNil(checks[2].conclusion)

        let rollup = CheckRollup(runs: checks)
        XCTAssertEqual(rollup.state, .failure)
        XCTAssertEqual(rollup.total, 3)
        XCTAssertEqual(rollup.successCount, 1)
        XCTAssertEqual(rollup.failureCount, 1)
        XCTAssertEqual(rollup.pendingCount, 1)
    }

    func testDetailDerivesReviewDecisionFromTheReviewListing() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        // octocat's latest review approves, but hubot still requests changes.
        XCTAssertEqual(detail.summary.reviewDecision, .changesRequested)
        XCTAssertEqual(detail.summary.checkRollup?.state, .failure)
    }

    func testCommitTrailersPromoteProvenance() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        XCTAssertTrue(
            detail.commitTrailers.contains("Co-Authored-By: Claude <noreply@anthropic.com>")
        )
        XCTAssertEqual(detail.summary.author.kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(detail.commits[0].messageHeadline,
                       "refactor: hide the Keychain behind a protocol")
    }

    func testTimelineIsOrderedOldestFirst() async throws {
        let transport = try await makeTransport()
        let client = GitHubClient.makeForTesting(transport: transport)
        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        let dates = detail.timeline.map(\.createdAt)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(detail.timeline.first?.kind, .commit)
        XCTAssertTrue(detail.timeline.contains(where: { $0.kind == .reviewChangesRequested }))
        XCTAssertTrue(detail.timeline.contains(where: { $0.kind == .reviewApproved }))
    }

    func testHeadRefOidProbeUsesGraphQL() async throws {
        let transport = MockTransport()
        let head = try Fixture.response("head-oid")
        await transport.route("ShepherdPullRequestHead", head)
        let client = GitHubClient.makeForTesting(transport: transport)

        let oid = try await client.headRefOid(repo: repo, number: 128)
        XCTAssertEqual(oid, "3f1a9c0d5b7e2a4c6d8f0b1a2c3e4d5f60718293")

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/graphql")
    }
}
