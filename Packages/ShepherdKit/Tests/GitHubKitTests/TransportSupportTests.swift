import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

// `URLRequest` lives in a separate module on Linux, and `RedirectPolicyTests` below asserts on
// the two of them the redirect delegate is handed.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class GitHubTimestampTests: XCTestCase {
    func testParsesTheShapeGitHubActuallySends() {
        XCTAssertEqual(
            GitHubTimestamp.parse("2026-08-31T07:41:12Z"),
            Date(timeIntervalSince1970: 1_788_162_072)
        )
        XCTAssertEqual(
            GitHubTimestamp.parse("1970-01-01T00:00:00Z"),
            Date(timeIntervalSince1970: 0)
        )
    }

    func testParsesFractionalSecondsAndOffsets() {
        let fractional = GitHubTimestamp.parse("2026-08-31T07:41:12.250Z")
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, 1_788_162_072.25, accuracy: 0.001)

        XCTAssertEqual(
            GitHubTimestamp.parse("2026-08-31T09:41:12+02:00"),
            Date(timeIntervalSince1970: 1_788_162_072)
        )
        XCTAssertEqual(
            GitHubTimestamp.parse("2026-08-31T05:41:12-02:00"),
            Date(timeIntervalSince1970: 1_788_162_072)
        )
    }

    func testRejectsNonsense() {
        XCTAssertNil(GitHubTimestamp.parse(""))
        XCTAssertNil(GitHubTimestamp.parse("yesterday"))
        XCTAssertNil(GitHubTimestamp.parse("2026-13-31T07:41:12Z"))
        XCTAssertNil(GitHubTimestamp.parse("2026-08-31"))
    }

    func testFormatsBackToTheSameString() {
        let stamps = [
            "1970-01-01T00:00:00Z",
            "2000-02-29T12:00:00Z",
            "2026-08-31T07:41:12Z",
            "2100-12-31T23:59:59Z",
        ]
        for stamp in stamps {
            guard let date = GitHubTimestamp.parse(stamp) else {
                return XCTFail("failed to parse \(stamp)")
            }
            XCTAssertEqual(GitHubTimestamp.string(from: date), stamp)
        }
    }

    func testCivilDateArithmeticRoundTrips() {
        for day in stride(from: -20_000, through: 40_000, by: 137) {
            let civil = GitHubTimestamp.civilFromDays(day)
            XCTAssertEqual(
                GitHubTimestamp.daysFromCivil(
                    year: civil.year,
                    month: civil.month,
                    day: civil.day
                ),
                day
            )
        }
    }
}

final class AsyncSemaphoreTests: XCTestCase {
    func testPermitsAreHandedOutAndReturned() async {
        let semaphore = AsyncSemaphore(value: 2)
        await semaphore.wait()
        await semaphore.wait()
        var available = await semaphore.availablePermits
        XCTAssertEqual(available, 0)

        await semaphore.signal()
        available = await semaphore.availablePermits
        XCTAssertEqual(available, 1)
    }

    func testValuesBelowOneAreClamped() async {
        let semaphore = AsyncSemaphore(value: 0)
        let available = await semaphore.availablePermits
        XCTAssertEqual(available, 1)
    }

    func testConcurrentHoldersNeverExceedTheLimit() async {
        let semaphore = AsyncSemaphore(value: 3)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await semaphore.wait()
                    await counter.enter()
                    await Task.yield()
                    await counter.leave()
                    await semaphore.signal()
                }
            }
            await group.waitForAll()
        }

        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 0)
    }
}

/// Tracks how many tasks are inside the critical section at once.
actor ConcurrencyCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

final class RateLimitTests: XCTestCase {
    func testParsesAllHeaders() {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "X-RateLimit-Limit": "5000",
                "X-RateLimit-Remaining": "4999",
                "X-RateLimit-Used": "1",
                "X-RateLimit-Reset": "1788165600",
                "X-RateLimit-Resource": "core",
            ]
        )
        let snapshot = RateLimitSnapshot.parse(from: response)
        XCTAssertEqual(snapshot?.limit, 5_000)
        XCTAssertEqual(snapshot?.remaining, 4_999)
        XCTAssertEqual(snapshot?.used, 1)
        XCTAssertEqual(snapshot?.resource, "core")
        XCTAssertEqual(snapshot?.resetAt, Date(timeIntervalSince1970: 1_788_165_600))
        XCTAssertEqual(snapshot?.isExhausted, false)
    }

    func testResponsesWithoutHeadersProduceNoSnapshot() {
        XCTAssertNil(RateLimitSnapshot.parse(from: HTTPResponse(statusCode: 200)))
    }

    func testRetryAfterWins() {
        let response = HTTPResponse(
            statusCode: 403,
            headers: ["Retry-After": "12", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "0"]
        )
        XCTAssertEqual(
            RateLimitPolicy.retryDelay(for: response, now: Date(timeIntervalSince1970: 0)),
            12
        )
    }

    func testResetIsUsedWhenTheBudgetIsExhausted() {
        let response = HTTPResponse(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "600"]
        )
        XCTAssertEqual(
            RateLimitPolicy.retryDelay(for: response, now: Date(timeIntervalSince1970: 0)),
            600
        )
    }

    func testNoHintMeansNoDelay() {
        let response = HTTPResponse(statusCode: 403, headers: ["x-ratelimit-remaining": "10"])
        XCTAssertNil(RateLimitPolicy.retryDelay(for: response, now: Date()))
        XCTAssertFalse(RateLimitPolicy.isRateLimit(response))
    }

    func testSecondaryLimitIsDetectedFromTheBody() {
        let response = HTTPResponse(
            statusCode: 403,
            headers: [:],
            body: Data("{\"message\":\"You have exceeded a secondary rate limit\"}".utf8)
        )
        XCTAssertTrue(RateLimitPolicy.isRateLimit(response))
    }
}

final class HTTPResponseTests: XCTestCase {
    func testHeaderLookupIsCaseInsensitive() {
        let response = HTTPResponse(statusCode: 200, headers: ["ETag": "W/\"x\""])
        XCTAssertEqual(response.header("etag"), "W/\"x\"")
        XCTAssertEqual(response.header("ETAG"), "W/\"x\"")
        XCTAssertNil(response.header("missing"))
        XCTAssertTrue(response.isSuccess)
        XCTAssertFalse(HTTPResponse(statusCode: 404).isSuccess)
    }
}

final class InboxQueryTests: XCTestCase {
    func testDefaultSweepCoversTheFacetsFromADR0005() {
        let queries = InboxQuery.defaultSweep
        XCTAssertEqual(queries.count, 5)
        XCTAssertTrue(queries.allSatisfy { $0.rawQuery.hasPrefix("is:pr is:open archived:false") })

        XCTAssertEqual(
            Set(queries.flatMap(\.impliedRelations)),
            [.reviewRequested, .author, .assigned, .mentioned, .involved]
        )
    }

    func testTheCatchAllFacetSaysSoRatherThanSayingNothing() {
        // Every facet marks its hits, the catch-all included. Without this an `involves:@me` row
        // and a watched-repository row are both "no relation at all", and the rail cannot tell a
        // pull request the user once commented on from one they have never touched.
        XCTAssertEqual(InboxQuery.involves.impliedRelations, [.involved])
    }

    func testAWatchedRepositoryIsSweptWholeAndMarkedAsWatched() {
        let query = InboxQuery.watching(RepoRef(owner: "schnaq", name: "unlock"))
        XCTAssertEqual(query.rawQuery, "is:pr is:open archived:false repo:schnaq/unlock")
        XCTAssertEqual(query.impliedRelations, [.watched])
    }

    func testScopingToAnOrganisationKeepsRelations() {
        let scoped = InboxQuery.reviewRequested.scoped(toOrganization: "schnaq")
        XCTAssertTrue(scoped.rawQuery.hasSuffix("org:schnaq"))
        XCTAssertEqual(scoped.impliedRelations, [.reviewRequested])
    }

    func testWatchingManyRepositoriesIsOneQueryEach() {
        let repos = [
            RepoRef(owner: "schnaq", name: "unlock"),
            RepoRef(owner: "schnaq", name: "review"),
        ]
        let queries = InboxQuery.watching(repos)
        XCTAssertEqual(
            queries.map(\.rawQuery),
            [
                "is:pr is:open archived:false repo:schnaq/unlock",
                "is:pr is:open archived:false repo:schnaq/review",
            ]
        )
    }
}

/// The one rule about where a credential may travel (ADR 0024).
///
/// `URLSession` follows redirects itself and copies the original request's headers onto the hop,
/// so on the job-log read — a `302` from `api.github.com` to a signed blob on
/// `*.githubusercontent.com` — it would hand a bearer token to a host that never needed one. The
/// decision is a pure function precisely so that it can be asserted here, on the Linux runner,
/// with no session and no socket; ``RedirectStrippingDelegate/followedRequest(original:proposed:)``
/// is the same decision applied to the two `URLRequest`s the delegate is handed.
final class RedirectPolicyTests: XCTestCase {
    private let api = URL(string: "https://api.github.com/repos/schnaq/review/actions/jobs/9/logs")!
    private let blob = URL(
        string: "https://objects.githubusercontent.com/github-production-actions-log/1?sig=abc"
    )!

    private func request(_ url: URL, headers: [String: String]? = nil) -> HTTPRequest {
        HTTPRequest(
            method: "GET",
            url: url,
            headers: headers ?? [
                "Authorization": "Bearer ghu_test-token",
                "Accept": "application/vnd.github+json",
                "User-Agent": "Shepherd/1.0",
                "X-GitHub-Api-Version": "2022-11-28",
            ]
        )
    }

    func testADifferentHostDoesNotGetTheToken() {
        let followed = RedirectPolicy.request(for: request(api), redirectingTo: blob)

        XCTAssertNil(followed.headers["Authorization"], "the whole point")
        XCTAssertEqual(followed.url, blob)
        // The headers that say *what* is wanted rather than *who* is asking still travel: the
        // blob ignores them, and dropping them would make a followed redirect a different
        // request from the one that was sent.
        XCTAssertEqual(followed.headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(followed.headers["User-Agent"], "Shepherd/1.0")
        XCTAssertEqual(followed.headers["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertEqual(followed.method, "GET")
    }

    func testAnApiKeyIsACredentialToo() {
        // Anthropic's spelling, and the app sends the user's own key straight to the endpoint
        // they configured. An endpoint that answers with a redirect must not be able to forward
        // that key to a host the user never named.
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let elsewhere = URL(string: "https://gateway.example.test/v1/messages")!
        let sent = request(
            endpoint,
            headers: [
                "x-api-key": "sk-ant-test",
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            ]
        )

        let followed = RedirectPolicy.request(for: sent, redirectingTo: elsewhere)

        XCTAssertNil(followed.headers["x-api-key"], "the key stays on the host it was sent to")
        // What the request *is* still travels, exactly as it does for a GitHub hop.
        XCTAssertEqual(followed.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(followed.headers["content-type"], "application/json")

        let sameHost = URL(string: "https://api.anthropic.com/v1/messages?beta=1")!
        XCTAssertEqual(
            RedirectPolicy.request(for: sent, redirectingTo: sameHost).headers["x-api-key"],
            "sk-ant-test"
        )
    }

    func testACredentialIsSomethingItsHolderCanActWith() {
        // The list is a rule, not a habit: a webhook signature authenticates one message rather
        // than its sender, so it is deliberately not on it.
        XCTAssertEqual(RedirectPolicy.credentialHeaders, ["Authorization", "x-api-key"])
    }

    func testTheSameHostKeepsIt() {
        let elsewhere = URL(string: "https://api.github.com/repositories/1/pulls/42")!

        let followed = RedirectPolicy.request(for: request(api), redirectingTo: elsewhere)

        XCTAssertEqual(followed.headers["Authorization"], "Bearer ghu_test-token")
        XCTAssertEqual(followed.url, elsewhere)
    }

    func testTheHostComparisonIgnoresCaseAndTheHeaderNameDoesToo() {
        let sameHostShouting = URL(string: "https://API.GitHub.COM/rate_limit")!
        XCTAssertEqual(
            RedirectPolicy.request(for: request(api), redirectingTo: sameHostShouting)
                .headers["Authorization"],
            "Bearer ghu_test-token",
            "DNS does not care about case, so neither may this"
        )

        // HTTP header names are case-insensitive and `HTTPRequest` keeps whatever the caller
        // wrote, so a lowercased one must be dropped just the same.
        let lowercased = request(api, headers: ["authorization": "Bearer ghu_test-token"])
        XCTAssertTrue(
            RedirectPolicy.request(for: lowercased, redirectingTo: blob).headers.isEmpty
        )
    }

    func testAHostThatCannotBeEstablishedIsTreatedAsADifferentOne() {
        let hostless = URL(string: "file:///tmp/log.txt")!

        let followed = RedirectPolicy.request(for: request(api), redirectingTo: hostless)

        XCTAssertNil(followed.headers["Authorization"], "\"we could not tell\" is not a yes")
        XCTAssertFalse(RedirectPolicy.isSameHost(api, hostless))
        XCTAssertFalse(RedirectPolicy.isSameHost(hostless, hostless), "not even to itself")
    }

    func testTheDelegateStripsTheHeaderOffTheRequestURLSessionProposed() {
        var original = URLRequest(url: api)
        original.setValue("Bearer ghu_test-token", forHTTPHeaderField: "Authorization")
        original.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // What `URLSession` builds for the hop: the original's headers, plus its own.
        var proposed = URLRequest(url: blob)
        proposed.setValue("Bearer ghu_test-token", forHTTPHeaderField: "Authorization")
        proposed.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        proposed.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let followed = RedirectStrippingDelegate.followedRequest(
            original: original,
            proposed: proposed
        )

        XCTAssertNil(followed.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(followed.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(
            followed.value(forHTTPHeaderField: "Accept-Encoding"),
            "gzip",
            "what the session added for itself is not ours to drop"
        )
        XCTAssertEqual(followed.url, blob)
    }

    func testTheDelegateLeavesASameHostRedirectAlone() {
        var original = URLRequest(url: api)
        original.setValue("Bearer ghu_test-token", forHTTPHeaderField: "Authorization")
        let elsewhere = URL(string: "https://api.github.com/rate_limit")!
        var proposed = URLRequest(url: elsewhere)
        proposed.setValue("Bearer ghu_test-token", forHTTPHeaderField: "Authorization")

        let followed = RedirectStrippingDelegate.followedRequest(
            original: original,
            proposed: proposed
        )

        XCTAssertEqual(followed.value(forHTTPHeaderField: "Authorization"), "Bearer ghu_test-token")
        XCTAssertEqual(followed.url, elsewhere)
    }
}
