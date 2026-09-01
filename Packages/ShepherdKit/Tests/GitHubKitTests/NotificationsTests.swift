import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

final class NotificationsTests: XCTestCase {
    func testParsesThreadsAndResolvesPullRequestNumbers() async throws {
        let transport = MockTransport()
        let response = try Fixture.response(
            "notifications",
            headers: [
                "X-Poll-Interval": "60",
                "Last-Modified": "Mon, 31 Aug 2026 07:41:12 GMT",
            ]
        )
        await transport.route("/notifications", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let page = try await client.notifications()
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.pollInterval, 60)
        XCTAssertEqual(page.lastModified, "Mon, 31 Aug 2026 07:41:12 GMT")
        XCTAssertFalse(page.notModified)

        let first = page.items[0]
        XCTAssertEqual(first.id, "12345678")
        XCTAssertEqual(first.reason, .reviewRequested)
        XCTAssertTrue(first.isUnread)
        XCTAssertTrue(first.isPullRequest)
        XCTAssertEqual(first.repo, RepoRef(owner: "schnaq", name: "review"))
        XCTAssertEqual(first.pullRequestNumber, 128)
        XCTAssertEqual(first.subjectTitle, "Refactor the token store")

        let issue = page.items[1]
        XCTAssertEqual(issue.reason, .subscribed)
        XCTAssertFalse(issue.isPullRequest)
        XCTAssertNil(issue.pullRequestNumber, "issues do not carry a pull request number")

        XCTAssertEqual(page.items[2].reason, .ciActivity)
        XCTAssertEqual(page.items[2].pullRequestNumber, 129)
    }

    func testSinceAndParticipatingBecomeQueryItems() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("notifications")
        await transport.route("/notifications", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.notifications(
            since: Date(timeIntervalSince1970: 1_788_162_072),
            participating: true
        )
        let request = await transport.onlyRequest()
        let url = request?.url.absoluteString ?? ""
        XCTAssertTrue(url.contains("participating=true"), url)
        XCTAssertTrue(url.contains("since=2026-08-31T07:41:12Z"), url)
    }

    func testIfModifiedSinceIsSentWhenTheCallerHasOne() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("notifications")
        await transport.route("/notifications", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.notifications(lastModified: "Mon, 31 Aug 2026 07:00:00 GMT")
        let request = await transport.onlyRequest()
        XCTAssertEqual(
            request?.headers["If-Modified-Since"],
            "Mon, 31 Aug 2026 07:00:00 GMT"
        )
    }

    func testNotModifiedWithoutACachedBodyIsAFreePoll() async throws {
        let transport = MockTransport()
        await transport.route(
            "/notifications",
            Fixture.empty(status: 304, headers: ["X-Poll-Interval": "90"])
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let page = try await client.notifications(lastModified: "Mon, 31 Aug 2026 07:00:00 GMT")
        XCTAssertTrue(page.notModified)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.pollInterval, 90)
        XCTAssertEqual(page.lastModified, "Mon, 31 Aug 2026 07:00:00 GMT")
    }

    func testETagsAreStoredAndReplayed() async throws {
        let transport = MockTransport()
        let first = try Fixture.response(
            "notifications",
            headers: ["ETag": "W/\"abc123\"", "Last-Modified": "Mon, 31 Aug 2026 07:41:12 GMT"]
        )
        await transport.route("/notifications", first)
        await transport.route(
            "/notifications",
            Fixture.empty(status: 304, headers: ["X-Poll-Interval": "60"])
        )

        let cache = InMemoryConditionalCache()
        let client = GitHubClient.makeForTesting(transport: transport, cache: cache)

        let firstPage = try await client.notifications()
        XCTAssertEqual(firstPage.items.count, 3)

        let cachedCount = await cache.count
        XCTAssertEqual(cachedCount, 1, "the response validators are cached")

        // The second poll is a free 304. The cached body is *not* replayed as fresh items:
        // the sync loop treats every returned item as new, so handing back last poll's page
        // would force a full sweep on every single poll.
        let secondPage = try await client.notifications()
        XCTAssertTrue(secondPage.notModified)
        XCTAssertTrue(secondPage.items.isEmpty, "a 304 means nothing changed, not 'these again'")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].headers["If-None-Match"], "W/\"abc123\"")
    }

    func testTheNotificationsCacheKeyIgnoresTheVolatileSinceParameter() async throws {
        let transport = MockTransport()
        await transport.route(
            "/notifications",
            try Fixture.response("notifications", headers: ["ETag": "W/\"abc123\""])
        )
        await transport.route("/notifications", Fixture.empty(status: 304))

        let cache = InMemoryConditionalCache()
        let client = GitHubClient.makeForTesting(transport: transport, cache: cache)

        _ = try await client.notifications(since: Date(timeIntervalSince1970: 1_788_162_000))
        // A later poll rewrites `since`, so the URL differs. Keying on the full URL would mint
        // a second permanent row holding the whole payload — one per poll, forever — and the
        // stored ETag could never be replayed.
        _ = try await client.notifications(since: Date(timeIntervalSince1970: 1_788_165_600))

        let cachedCount = await cache.count
        XCTAssertEqual(cachedCount, 1, "one row per endpoint, not one per poll")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[1].headers["If-None-Match"],
            "W/\"abc123\"",
            "the validator is replayed even though `since` moved"
        )
    }

    func testPerCommitCheckRunsAreNotCached() async throws {
        let transport = MockTransport()
        await transport.route(
            "/check-runs",
            try Fixture.response("check-runs", headers: ["ETag": "W/\"checks\""])
        )
        let cache = InMemoryConditionalCache()
        let client = GitHubClient.makeForTesting(transport: transport, cache: cache)

        _ = try await client.checkRuns(
            repo: RepoRef(owner: "schnaq", name: "review"),
            ref: "abc123"
        )

        // Keyed by an immutable SHA: every push would leave one more permanently unreachable
        // row behind, holding a full response body.
        let cachedCount = await cache.count
        XCTAssertEqual(cachedCount, 0)
    }

    func testCacheKeyNormalisation() throws {
        let notifications = try XCTUnwrap(
            URL(string: "https://api.github.com/notifications?participating=true&since=2026-08-31T07:41:12Z")
        )
        XCTAssertEqual(
            GitHubClient.cacheKey(for: notifications),
            "https://api.github.com/notifications"
        )

        let checks = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/schnaq/review/commits/abc/check-runs?page=1")
        )
        XCTAssertNil(GitHubClient.cacheKey(for: checks))

        let pull = try XCTUnwrap(URL(string: "https://api.github.com/repos/schnaq/review/pulls/128"))
        XCTAssertEqual(
            GitHubClient.cacheKey(for: pull),
            "https://api.github.com/repos/schnaq/review/pulls/128"
        )
    }

    func testNotificationReasonMapping() {
        XCTAssertEqual(NotificationReason.fromAPI("review_requested"), .reviewRequested)
        XCTAssertEqual(NotificationReason.fromAPI("team_mention"), .mention)
        XCTAssertEqual(NotificationReason.fromAPI("state_change"), .stateChange)
        XCTAssertEqual(NotificationReason.fromAPI("ci_activity"), .ciActivity)
        XCTAssertEqual(NotificationReason.fromAPI("something_new"), .other)
    }
}
