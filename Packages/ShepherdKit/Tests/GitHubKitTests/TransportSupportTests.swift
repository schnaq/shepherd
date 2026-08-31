import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

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

        let byRelation = queries.filter { !$0.impliedRelations.isEmpty }
        XCTAssertEqual(
            Set(byRelation.flatMap(\.impliedRelations)),
            [.reviewRequested, .author, .assigned, .mentioned]
        )
    }

    func testScopingToAnOrganisationKeepsRelations() {
        let scoped = InboxQuery.reviewRequested.scoped(toOrganization: "schnaq")
        XCTAssertTrue(scoped.rawQuery.hasSuffix("org:schnaq"))
        XCTAssertEqual(scoped.impliedRelations, [.reviewRequested])
    }
}
