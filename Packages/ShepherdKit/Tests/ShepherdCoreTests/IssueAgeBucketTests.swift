import Foundation
import XCTest
@testable import ShepherdCore

/// The issues rail's age facet (ADR 0032): a pure bucketing of `createdAt` against a moment the
/// caller states, so the rail, the store's filter and this test cannot disagree about what "this
/// week" means.
final class IssueAgeBucketTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    private func bucket(hoursAgo: Double) -> IssueAgeBucket {
        IssueAgeBucket.bucket(
            createdAt: now.addingTimeInterval(-hoursAgo * 3_600),
            now: now
        )
    }

    func testTheFourBoundariesAreElapsedSpans() {
        XCTAssertEqual(bucket(hoursAgo: 0), .today)
        XCTAssertEqual(bucket(hoursAgo: 23), .today)
        XCTAssertEqual(bucket(hoursAgo: 25), .thisWeek)
        XCTAssertEqual(bucket(hoursAgo: 24 * 6), .thisWeek)
        XCTAssertEqual(bucket(hoursAgo: 24 * 8), .thisMonth)
        XCTAssertEqual(bucket(hoursAgo: 24 * 29), .thisMonth)
        XCTAssertEqual(bucket(hoursAgo: 24 * 31), .older)
    }

    func testTheBoundariesThemselvesBelongToTheOlderBucket() {
        // Exactly one day old is no longer "today": the comparison is `<`, so a row cannot be in
        // two buckets and cannot be in none.
        XCTAssertEqual(bucket(hoursAgo: 24), .thisWeek)
        XCTAssertEqual(bucket(hoursAgo: 24 * 7), .thisMonth)
        XCTAssertEqual(bucket(hoursAgo: 24 * 30), .older)
    }

    func testAFutureTimestampLandsInTodayRatherThanNowhere() {
        // Clock skew between GitHub and this Mac is real and is measured in seconds.
        XCTAssertEqual(bucket(hoursAgo: -1), .today)
    }

    func testContainsAgreesWithTheClassifier() {
        let createdAt = now.addingTimeInterval(-3 * 24 * 3_600)
        XCTAssertTrue(IssueAgeBucket.thisWeek.contains(createdAt: createdAt, now: now))
        XCTAssertFalse(IssueAgeBucket.today.contains(createdAt: createdAt, now: now))
        for candidate in IssueAgeBucket.allCases {
            XCTAssertEqual(
                candidate.contains(createdAt: createdAt, now: now),
                candidate == .thisWeek
            )
        }
    }

    func testTheRailOrderIsNewestFirst() {
        XCTAssertEqual(
            IssueAgeBucket.allCases.sorted { $0.facetSortIndex < $1.facetSortIndex },
            [.today, .thisWeek, .thisMonth, .older]
        )
    }
}
