import Foundation
import XCTest
@testable import ShepherdCore

/// The pure half of the feedback loop: the similarity floor, the thirty-day window, the
/// "two different pull requests" rule, the exemplar, and the two total orders (ADR 0029).
///
/// Runs on the Linux runner, which is the point of the split — no embedding model exists there, so
/// every vector here is one a test wrote by hand and every cosine is one a reader can check with a
/// pencil. `RecurringFindingTests` in the app target covers what a pure function cannot see: when
/// an embedding is spent, that a dismissal hides a card, and what the delegation sheet is handed.
final class RecurringFindingDetectorTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    /// A day, so a fixture reads as "eight days ago".
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - Vectors a reader can check

    /// The axis every cluster in this file points along, so a candidate's cosine is arithmetic.
    private let axis = SearchVector([1, 0, 0])
    /// Cosine 4/√17 ≈ 0.970 against ``axis``.
    private let near = SearchVector([4, 1, 0])
    /// Cosine 2/√5 ≈ 0.894.
    private let close = SearchVector([2, 1, 0])
    /// Cosine exactly 3/5 = 0.6 — the floor itself.
    private let atFloor = SearchVector([3, 4, 0])
    /// Cosine 1/√10 ≈ 0.316 — nowhere near it.
    private let far = SearchVector([1, 3, 0])

    // MARK: - Fixtures

    private typealias Candidate = (
        id: String,
        body: String,
        prID: String,
        number: Int,
        createdAt: Date,
        vector: SearchVector
    )

    private func candidate(
        _ id: String,
        _ body: String,
        pr: Int,
        daysAgo: Double,
        vector: SearchVector
    ) -> Candidate {
        (
            id: id,
            body: body,
            prID: "PR_\(pr)",
            number: pr,
            createdAt: now.addingTimeInterval(-daysAgo * day),
            vector: vector
        )
    }

    /// Three "add a test" comments on two pull requests, well inside the window.
    private var testsCluster: [Candidate] {
        [
            candidate("c1", "Please add a test for the error path here.", pr: 11, daysAgo: 20, vector: axis),
            candidate("c2", "Needs a test for the failure branch.", pr: 12, daysAgo: 10, vector: near),
            candidate("c3", "Add a test covering the error path, please.", pr: 12, daysAgo: 2, vector: close),
        ]
    }

    // MARK: - The cluster

    func testThreeSimilarCommentsOnTwoPullRequestsAreOneRecurringFinding() {
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: testsCluster,
            now: now
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.count, 3)
        XCTAssertEqual(findings.first?.repo, repo)
        XCTAssertEqual(findings.first?.distinctPullRequestCount, 2)
        // Oldest first, which is the order the card quotes them in.
        XCTAssertEqual(findings.first?.comments.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(findings.first?.comments.map(\.number), [11, 12, 12])
    }

    func testTheExemplarIsTheShortestComment() {
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: testsCluster,
            now: now
        )
        // Not the first one and not the newest: the shortest, because the reviewer's shortest
        // phrasing is the one closest to a rule.
        XCTAssertEqual(findings.first?.exemplar, "Needs a test for the failure branch.")
    }

    func testACommentThatIsNotAboutTheSameThingStaysOutOfTheCluster() {
        var comments = testsCluster
        comments.append(
            candidate("c4", "Nit: this name reads better as `retryCount`.", pr: 13, daysAgo: 1, vector: far)
        )
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        // One finding, and the naming nit is not in it — nor is it a finding of its own, being a
        // cluster of one.
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.comments.map(\.id), ["c1", "c2", "c3"])
    }

    func testTheFloorIsInclusive() {
        let comments = [
            candidate("c1", "Please add a test for the error path.", pr: 11, daysAgo: 5, vector: axis),
            candidate("c2", "A test for the error path, please.", pr: 12, daysAgo: 4, vector: atFloor),
            candidate("c3", "Test the error path.", pr: 13, daysAgo: 3, vector: near),
        ]
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        // Exactly 0.6 counts: the constant is documented as the cosine a comment "must reach",
        // and a floor that excluded its own value would make the number a lie.
        XCTAssertEqual(findings.first?.count, 3)
    }

    func testTheFloorIsAnArgumentSoACallerMayRaiseIt() {
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: testsCluster,
            now: now,
            similarity: 0.95
        )
        // At 0.95 only `near` still reaches the seed, which is two comments — under the count.
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - The window

    func testACommentOlderThanTheWindowDoesNotCount() {
        var comments = testsCluster
        comments[0] = candidate(
            "c1",
            "Please add a test for the error path here.",
            pr: 11,
            daysAgo: 31,
            vector: axis
        )
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        // Two comments inside thirty days is not three, and the card does not appear. The rule
        // this would have drafted describes a habit the agent may no longer have.
        XCTAssertTrue(findings.isEmpty)
    }

    func testTheWindowIsAnArgumentSoAWiderOneFindsTheOldComment() {
        var comments = testsCluster
        comments[0] = candidate(
            "c1",
            "Please add a test for the error path here.",
            pr: 11,
            daysAgo: 31,
            vector: axis
        )
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: comments,
            now: now,
            window: 60 * 24 * 60 * 60
        )
        XCTAssertEqual(findings.first?.count, 3)
    }

    func testTheWindowIsMeasuredFromTheCommentsOwnTimestamp() {
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: testsCluster,
            now: now.addingTimeInterval(40 * day)
        )
        // Forty days later the same three comments are all outside the window: the clock the
        // window is measured against is `now`, never "when the sweep read them".
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - The spread

    func testThreeCommentsOnOnePullRequestAreOneArgumentNotAPattern() {
        let comments = [
            candidate("c1", "Please add a test for the error path.", pr: 11, daysAgo: 5, vector: axis),
            candidate("c2", "Still no test for the error path.", pr: 11, daysAgo: 4, vector: near),
            candidate("c3", "A test for the error path, please.", pr: 11, daysAgo: 3, vector: close),
        ]
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        // The count is met and the finding is still refused: one long thread about one mistake is
        // not evidence about the repository.
        XCTAssertTrue(findings.isEmpty)
    }

    func testTheSpreadRuleIsAnArgumentSoACallerMayDropIt() {
        let comments = [
            candidate("c1", "Please add a test for the error path.", pr: 11, daysAgo: 5, vector: axis),
            candidate("c2", "Still no test for the error path.", pr: 11, daysAgo: 4, vector: near),
            candidate("c3", "A test for the error path, please.", pr: 11, daysAgo: 3, vector: close),
        ]
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: comments,
            now: now,
            minimumDistinctPullRequests: 1
        )
        XCTAssertEqual(findings.first?.count, 3)
    }

    // MARK: - Order and determinism

    func testTheLargestClusterComesFirst() {
        var comments = testsCluster
        // A second cluster along another axis: four comments, so it outranks the three.
        let other = SearchVector([0, 1, 0])
        comments += [
            candidate("d1", "Do not widen the public API for this.", pr: 21, daysAgo: 9, vector: other),
            candidate("d2", "This widens the public API again.", pr: 22, daysAgo: 8, vector: SearchVector([1, 4, 0])),
            candidate("d3", "Please keep the public API as it is.", pr: 23, daysAgo: 7, vector: SearchVector([1, 2, 0])),
            candidate("d4", "Again a wider public API.", pr: 24, daysAgo: 6, vector: SearchVector([0, 1, 0])),
        ]
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        XCTAssertEqual(findings.map(\.count), [4, 3])
        XCTAssertEqual(findings.first?.comments.map(\.id), ["d1", "d2", "d3", "d4"])
    }

    func testTheSameCommentsInAnyOrderProduceTheSameFindings() {
        let forwards = RecurringFindingDetector.detect(
            repo: repo,
            comments: testsCluster,
            now: now
        )
        let backwards = RecurringFindingDetector.detect(
            repo: repo,
            comments: Array(testsCluster.reversed()),
            now: now
        )
        // The whole promise of the seeding order: a sweep that read the rows in another order
        // must not reshuffle the card's quotes, which would read as new information.
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.first?.exemplar, backwards.first?.exemplar)
    }

    // MARK: - Nothing to say

    func testACommentTheModelCouldNotEmbedIsNotEvidenceOfAnything() {
        var comments = testsCluster
        comments.append(
            candidate("c4", "Please add a test for the error path.", pr: 14, daysAgo: 1, vector: SearchVector([]))
        )
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        // Dropped, not clustered on its text and not a cluster of one: an empty vector is "no
        // answer", never "unrelated".
        XCTAssertEqual(findings.first?.count, 3)
        XCTAssertEqual(findings.first?.comments.map(\.id), ["c1", "c2", "c3"])
    }

    func testAnEmptyBodyIsDropped() {
        var comments = testsCluster
        comments.append(candidate("c4", "   \n ", pr: 14, daysAgo: 1, vector: axis))
        let findings = RecurringFindingDetector.detect(repo: repo, comments: comments, now: now)
        XCTAssertEqual(findings.first?.count, 3)
    }

    func testTooFewCommentsCostNoClustering() {
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: Array(testsCluster.prefix(2)),
            now: now
        )
        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - The dismissal key

    func testTheDismissalKeyIsTheRepositoryAndTheExemplarAndNothingElse() {
        let findings = RecurringFindingDetector.detect(
            repo: repo,
            comments: testsCluster,
            now: now
        )
        guard let finding = findings.first else { return XCTFail("one finding was expected") }
        XCTAssertEqual(
            finding.dismissalKey,
            RecurringFindingDetector.dismissalKey(repo: repo, exemplar: finding.exemplar)
        )
        // A fourth comment joining the cluster must not resurrect a dismissed card, so the key
        // may not depend on the cluster's membership.
        var grown = testsCluster
        grown.append(
            candidate("c4", "Needs a test for the failure branch.", pr: 15, daysAgo: 1, vector: near)
        )
        let after = RecurringFindingDetector.detect(repo: repo, comments: grown, now: now)
        XCTAssertEqual(after.first?.count, 4)
        XCTAssertEqual(after.first?.dismissalKey, finding.dismissalKey)
    }

    func testTheKeyIgnoresTheRepositorysCasing() {
        XCTAssertEqual(
            RecurringFindingDetector.dismissalKey(repo: repo, exemplar: "Add a test."),
            RecurringFindingDetector.dismissalKey(
                repo: RepoRef(owner: "Schnaq", name: "Review"),
                exemplar: "Add a test."
            )
        )
    }

    func testADifferentFindingIsADifferentKey() {
        XCTAssertNotEqual(
            RecurringFindingDetector.dismissalKey(repo: repo, exemplar: "Add a test."),
            RecurringFindingDetector.dismissalKey(repo: repo, exemplar: "Do not widen the API.")
        )
    }
}
