import Foundation
import XCTest

@testable import ShepherdCore

/// When a pull request whose classification failed may be asked about again.
///
/// The failure memory exists because the unattended pass runs on every inbox write: without it a
/// pull request the model refused was asked about again every couple of minutes, for as long as
/// it stayed in the inbox, and refused every time.
final class TriageFailureTests: XCTestCase {
    private let failedAt = Date(timeIntervalSince1970: 1_788_162_000)

    private func failure(_ kind: TriageFailure.Kind) -> TriageFailure {
        TriageFailure(
            documentHash: "hash-1",
            modelIdentifier: "tagger-1",
            kind: kind,
            failedAt: failedAt
        )
    }

    func testARefusedDocumentIsNeverAskedAboutAgain() {
        let refused = failure(.content)

        XCTAssertFalse(
            refused.allowsRetry(
                documentHash: "hash-1",
                modelIdentifier: "tagger-1",
                now: failedAt.addingTimeInterval(86_400)
            ),
            "the same text trips the same guardrail however long one waits"
        )
    }

    func testAChangedDocumentIsAskedAboutAgain() {
        XCTAssertTrue(
            failure(.content).allowsRetry(
                documentHash: "hash-2",
                modelIdentifier: "tagger-1",
                now: failedAt
            )
        )
        XCTAssertTrue(
            failure(.transient).allowsRetry(
                documentHash: "hash-2",
                modelIdentifier: "tagger-1",
                now: failedAt
            )
        )
    }

    func testAnotherModelIsAskedAboutTheSameDocumentAgain() {
        XCTAssertTrue(
            failure(.content).allowsRetry(
                documentHash: "hash-1",
                modelIdentifier: "tagger-2",
                now: failedAt
            )
        )
    }

    func testATransientFailureWaitsOutItsBackoffAndThenRetries() {
        let transient = failure(.transient)
        let backoff = TriageFailure.transientBackoff

        XCTAssertFalse(
            transient.allowsRetry(
                documentHash: "hash-1",
                modelIdentifier: "tagger-1",
                now: failedAt.addingTimeInterval(backoff - 1)
            )
        )
        XCTAssertTrue(
            transient.allowsRetry(
                documentHash: "hash-1",
                modelIdentifier: "tagger-1",
                now: failedAt.addingTimeInterval(backoff)
            )
        )
    }

    func testTheBackoffIsMinutesRatherThanASweep() {
        // A sweep lands every two minutes; a backoff shorter than that would retry on every one.
        XCTAssertGreaterThanOrEqual(TriageFailure.transientBackoff, 5 * 60)
    }
}
