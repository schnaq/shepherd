import Foundation
import XCTest
@testable import ShepherdCore

/// The pure half of the thread digest: which comments reach the prompt, in which order, and what
/// the request says about the ones that did not (plan §3.G).
///
/// Runs on the Linux runner, which is the whole point of the split — no on-device model exists
/// there, and none of the rules below needs one. What the app-target `ThreadDigestTests` cover on
/// top of this is what a pure function cannot see: when a model run is actually spent, what
/// invalidates a cached digest, and the states the card shows.
///
/// The eviction order is the assertion that matters most. A digest answers "where does this
/// thread stand now", so dropping the *newest* comments would produce a confident summary of a
/// conversation that has since moved on — a wrong answer rather than a partial one.
final class ThreadDigestRequestTests: XCTestCase {
    // MARK: - Fixtures

    /// A comment whose body names its own index, so an assertion can point at one row.
    private func comment(
        _ index: Int,
        author: String = "octocat",
        body: String? = nil
    ) -> ThreadDigestRequest.Comment {
        ThreadDigestRequest.Comment(
            author: author,
            body: body ?? "comment number \(index) about the retry loop",
            createdAt: Fixtures.date(TimeInterval(index) * 60)
        )
    }

    private func comments(_ count: Int) -> [ThreadDigestRequest.Comment] {
        (1...count).map { comment($0) }
    }

    /// A budget so small that the share arithmetic lands on ``minimumTotalCharacters``.
    private var tinyBudget: TokenBudget { TokenBudget(maxTokens: 100) }

    // MARK: - Eviction order

    func testTheOldestCommentsAreGivenUpFirstAndTheNewestSurvives() {
        let request = ThreadDigestRequest.build(comments: comments(60), budget: tinyBudget)

        XCTAssertLessThan(request.coveredCount, 60, "sixty comments do not fit a 100-token budget")
        XCTAssertEqual(request.totalCount, 60)
        XCTAssertTrue(request.wasTruncated)

        // The kept window is a *suffix* of the thread: contiguous, ending at the newest comment.
        let covered = request.comments
        XCTAssertEqual(covered.last?.body, "comment number 60 about the retry loop")
        let expectedFirst = 60 - request.coveredCount + 1
        XCTAssertEqual(covered.first?.body, "comment number \(expectedFirst) about the retry loop")
        XCTAssertFalse(
            request.promptText.contains("comment number \(expectedFirst - 1) "),
            "the comment just outside the window is not in the prompt"
        )
    }

    func testTheCoveredCommentsStayInThreadOrder() {
        let request = ThreadDigestRequest.build(comments: comments(60), budget: tinyBudget)

        let dates = request.comments.map(\.createdAt)
        XCTAssertEqual(dates, dates.sorted(), "oldest first, newest last — never the reverse")

        // And the prompt numbers them in that order, so "who is waiting on whom" is answerable.
        let text = request.promptText
        guard let firstIndex = text.range(of: "[1] "), let secondIndex = text.range(of: "[2] ")
        else { return XCTFail("the prompt numbers its comments") }
        XCTAssertLessThan(firstIndex.lowerBound, secondIndex.lowerBound)
    }

    func testAWholeShortThreadIsCoveredWithNothingToSayAboutCoverage() {
        let request = ThreadDigestRequest.build(comments: comments(8), budget: .onDevice)

        XCTAssertEqual(request.coveredCount, 8)
        XCTAssertEqual(request.totalCount, 8)
        XCTAssertFalse(request.wasTruncated)
        XCTAssertFalse(
            request.promptText.contains("older ones are not"),
            "a complete digest does not apologise for coverage it has"
        )
    }

    // MARK: - Caps

    func testASingleEnormousCommentIsCappedRatherThanDroppedOrAllowedToFillTheBudget() {
        let log = String(repeating: "stack frame ", count: 4_000)
        let request = ThreadDigestRequest.build(
            comments: comments(5) + [comment(6, body: log)],
            budget: .onDevice
        )

        guard let newest = request.comments.last else { return XCTFail("the newest comment is kept") }
        XCTAssertEqual(
            newest.body.count,
            ThreadDigestRequest.maximumCommentCharacters + 1,
            "capped to the per-comment limit plus the ellipsis that says so"
        )
        XCTAssertTrue(newest.body.hasSuffix("…"))
        XCTAssertEqual(request.coveredCount, 6, "capping a comment does not evict its neighbours")
    }

    func testTheNewestCommentSurvivesEvenTheSmallestBudget() {
        // The property the constants are chosen for: `maximumCommentCharacters` is below
        // `minimumTotalCharacters`, so one comment always fits and the request is never empty
        // for a thread that has text in it.
        let request = ThreadDigestRequest.build(
            comments: [comment(1, body: String(repeating: "x", count: 10_000))],
            budget: TokenBudget(maxTokens: 1)
        )

        XCTAssertEqual(request.coveredCount, 1)
        XCTAssertFalse(request.isEmpty)
        XCTAssertLessThanOrEqual(
            ThreadDigestRequest.maximumCommentCharacters,
            ThreadDigestRequest.minimumTotalCharacters
        )
    }

    func testTheCharacterLimitIsAShareOfTheBudgetWithAFloor() {
        XCTAssertEqual(
            ThreadDigestRequest.charactersLimit(in: TokenBudget(maxTokens: 100)),
            ThreadDigestRequest.minimumTotalCharacters,
            "a tiny budget still gets the floor"
        )
        XCTAssertEqual(
            ThreadDigestRequest.charactersLimit(in: TokenBudget(maxTokens: 6_000)),
            12_000,
            "6,000 tokens × 4 characters × half"
        )
    }

    func testAGenerousBudgetCoversMoreOfTheSameThreadThanASmallOne() {
        let thread = comments(60)
        let small = ThreadDigestRequest.build(comments: thread, budget: tinyBudget)
        let large = ThreadDigestRequest.build(comments: thread, budget: .cloud)

        XCTAssertGreaterThan(large.coveredCount, small.coveredCount)
        XCTAssertEqual(large.coveredCount, 60, "the cloud-sized budget has room for all of it")
    }

    // MARK: - Counts

    func testAnEmptyThreadProducesAnEmptyRequestAndSaysSoRatherThanCrashing() {
        let request = ThreadDigestRequest.build(comments: [], budget: .onDevice)

        XCTAssertTrue(request.isEmpty)
        XCTAssertEqual(request.coveredCount, 0)
        XCTAssertEqual(request.totalCount, 0)
        XCTAssertFalse(request.wasTruncated, "nothing covered out of nothing is not a truncation")
        XCTAssertTrue(request.promptText.contains("0 comments in total"))
        XCTAssertTrue(request.promptText.contains("None of the comments"))
        XCTAssertGreaterThan(request.approximateTokenCount, 0)
    }

    func testAWhitespaceOnlyCommentIsNotSummarisedButStillCountsAsPartOfTheThread() {
        let request = ThreadDigestRequest.build(
            comments: [comment(1), comment(2, body: "   \n\t "), comment(3)],
            budget: .onDevice
        )

        XCTAssertEqual(request.coveredCount, 2, "there is nothing in a blank body to summarise")
        XCTAssertEqual(request.totalCount, 3, "the reviewer still counts three comments")
        XCTAssertTrue(request.wasTruncated)
        XCTAssertFalse(request.comments.contains { $0.body.isEmpty })
    }

    func testABodyIsTrimmedBeforeItReachesThePrompt() {
        let request = ThreadDigestRequest.build(
            comments: [comment(1, body: "\n\n  needs a test first.  \n")],
            budget: .onDevice
        )

        XCTAssertEqual(request.comments.first?.body, "needs a test first.")
    }

    // MARK: - The prompt

    func testTheCoverageNoteNamesBothCountsSoTheModelKnowsWhatItCannotSee() {
        let request = ThreadDigestRequest.build(comments: comments(60), budget: tinyBudget)
        let text = request.promptText

        XCTAssertTrue(text.contains("60 comments in total"))
        XCTAssertTrue(text.contains("Only the last \(request.coveredCount) comments"))
        XCTAssertTrue(text.contains("\(60 - request.coveredCount) older ones are not"))
        XCTAssertTrue(text.contains("do not describe how the thread began"))
    }

    func testAResolvedThreadSaysSoAndAnUnresolvedOneDoesNot() {
        let resolved = ThreadDigestRequest.build(
            comments: comments(6),
            isResolved: true,
            budget: .onDevice
        )
        let open = ThreadDigestRequest.build(comments: comments(6), budget: .onDevice)

        XCTAssertTrue(resolved.promptText.contains("marked resolved"))
        XCTAssertFalse(open.promptText.contains("marked resolved"))
    }

    func testTheAuthorAndTheTimestampTravelWithEveryComment() {
        let request = ThreadDigestRequest.build(
            comments: [comment(1, author: "renovate[bot]")],
            budget: .onDevice
        )

        XCTAssertTrue(request.promptText.contains("renovate[bot]"))
        XCTAssertTrue(
            request.promptText.contains("UTC"),
            "the stamp is a fixed-offset one, so the prompt is the same on every machine"
        )
    }

    func testTheStampIsFixedWidthAndInUTC() {
        // The assertion is on the *shape*, which is what makes the prompt reproducible, and on
        // the offset, which is what makes it identical on the Linux runner and on a Mac in
        // Berlin.
        let stamp = ThreadDigestRequest.stamp(for: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(stamp, "1970-01-01 00:00 UTC")
    }

    // MARK: - The fetched-comment bridge

    func testAFetchedCommentBecomesTheDigestsViewOfIt() {
        let fetched = ReviewComment(
            id: "RC_1",
            author: ShepherdCore.Actor(
                login: "octocat",
                displayName: "Octo Cat",
                avatarURL: nil,
                kind: .human
            ),
            bodyMarkdown: "Should this be behind a flag?",
            createdAt: Fixtures.date(0)
        )

        let mapped = ThreadDigestRequest.Comment(fetched)

        XCTAssertEqual(mapped.author, "Octo Cat", "the display name, as the thread shows it")
        XCTAssertEqual(mapped.body, "Should this be behind a flag?")
        XCTAssertEqual(mapped.createdAt, Fixtures.date(0))
    }

    // MARK: - The result pair

    func testAResultCarriesItsOwnCoverageSoACardCannotForgetIt() {
        let partial = ThreadDigestResult(
            digest: ThreadDigest(state: .blocked, summary: "Waiting on the author."),
            coveredCount: 8,
            totalCount: 23
        )
        let whole = ThreadDigestResult(
            digest: ThreadDigest(state: .agreed, summary: "Agreed to add a test."),
            coveredCount: 7,
            totalCount: 7
        )

        XCTAssertTrue(partial.wasTruncated)
        XCTAssertFalse(whole.wasTruncated)
        XCTAssertTrue(whole.digest.openQuestions.isEmpty, "no questions is the default")
    }

    // MARK: - The threshold

    func testTheOfferThresholdIsSixCommentsAndLivesWithTheBudgeting() {
        // Asserted rather than restated in the view: the button's condition and the request's
        // idea of "long enough to summarise" have to be the same number.
        XCTAssertEqual(ThreadDigestRequest.minimumCommentCount, 6)
    }
}
