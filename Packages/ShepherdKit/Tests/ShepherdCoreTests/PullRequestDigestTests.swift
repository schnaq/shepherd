import XCTest
@testable import ShepherdCore

final class PullRequestDigestTests: XCTestCase {
    private func patch(lines: Int, marker: String) -> String {
        (0..<lines).map { "+\(marker) line \($0)" }.joined(separator: "\n")
    }

    private func detail(files: [ChangedFile], body: String = "Body.") -> PullRequestDetail {
        let churn = files.reduce(0) { $0 + $1.churn }
        return PullRequestDetail(
            summary: Fixtures.summary(
                id: "pr-1",
                number: 42,
                title: "Rework the token store",
                author: Fixtures.makeActor(
                    "claude[bot]",
                    kind: Fixtures.agent("claude-code", "Claude Code")
                ),
                additions: churn,
                deletions: 0,
                changedFiles: files.count
            ),
            bodyMarkdown: body,
            commits: [],
            files: files,
            threads: [],
            timeline: [],
            checks: []
        )
    }

    func testDigestCarriesIdentityAndTotals() {
        let digest = PullRequestDigestBuilder.build(
            from: detail(files: [Fixtures.file("Sources/App/View.swift")]),
            budget: TokenBudget(maxTokens: 4_000)
        )
        XCTAssertEqual(digest.repoFullName, "schnaq/review")
        XCTAssertEqual(digest.number, 42)
        XCTAssertEqual(digest.title, "Rework the token store")
        XCTAssertEqual(digest.authorLogin, "claude[bot]")
        XCTAssertEqual(digest.authorProvenance, "Claude Code")
        XCTAssertEqual(digest.changedFileCount, 1)
    }

    func testFilesAreListedInReviewPriorityOrder() {
        let digest = PullRequestDigestBuilder.build(
            from: detail(files: [
                Fixtures.file("package-lock.json", patch: nil),
                Fixtures.file("docs/readme.md"),
                Fixtures.file("Sources/Auth/TokenStore.swift"),
            ]),
            budget: TokenBudget(maxTokens: 8_000)
        )
        XCTAssertEqual(digest.files.first?.path, "Sources/Auth/TokenStore.swift")
        XCTAssertEqual(digest.files.first?.bucket, .reviewFirst)
        XCTAssertEqual(digest.files.last?.path, "package-lock.json")
        XCTAssertEqual(digest.files.last?.category, .generated)
    }

    func testGeneratedFilesNeverContributeHunks() {
        let digest = PullRequestDigestBuilder.build(
            from: detail(files: [
                Fixtures.file("package-lock.json", patch: patch(lines: 50, marker: "lock")),
                Fixtures.file("Sources/App/View.swift", patch: patch(lines: 5, marker: "src")),
            ]),
            budget: TokenBudget(maxTokens: 8_000)
        )
        XCTAssertFalse(digest.topHunks.contains(where: { $0.path == "package-lock.json" }))
        XCTAssertTrue(digest.topHunks.contains(where: { $0.path == "Sources/App/View.swift" }))
    }

    func testDigestStaysInsideItsTokenBudget() {
        let files = (0..<40).map { index in
            Fixtures.file(
                "Sources/App/File\(index).swift",
                additions: 200,
                deletions: 50,
                patch: patch(lines: 400, marker: "content-\(index)")
            )
        }
        let budget = TokenBudget(maxTokens: 2_000)
        let digest = PullRequestDigestBuilder.build(from: detail(files: files), budget: budget)

        XCTAssertLessThanOrEqual(digest.approximateTokenCount, budget.maxTokens)
        XCTAssertTrue(digest.wasTruncated)
        XCTAssertFalse(digest.files.isEmpty)
    }

    func testLargerBudgetKeepsMoreContent() {
        let files = (0..<12).map { index in
            Fixtures.file(
                "Sources/App/File\(index).swift",
                patch: patch(lines: 120, marker: "content-\(index)")
            )
        }
        let small = PullRequestDigestBuilder.build(
            from: detail(files: files),
            budget: TokenBudget(maxTokens: 1_000)
        )
        let large = PullRequestDigestBuilder.build(
            from: detail(files: files),
            budget: TokenBudget(maxTokens: 20_000)
        )
        XCTAssertGreaterThan(large.topHunks.count, small.topHunks.count)
        XCTAssertGreaterThanOrEqual(large.files.count, small.files.count)
    }

    func testBodyIsTruncatedRatherThanDropped() {
        let body = String(repeating: "This body is long. ", count: 500)
        let digest = PullRequestDigestBuilder.build(
            from: detail(files: [Fixtures.file("Sources/App/View.swift")], body: body),
            budget: TokenBudget(maxTokens: 500)
        )
        XCTAssertFalse(digest.bodyExcerpt.isEmpty)
        XCTAssertLessThan(digest.bodyExcerpt.count, body.count)
        XCTAssertTrue(digest.wasTruncated)
    }

    func testDigestIsDeterministic() {
        let input = detail(files: [
            Fixtures.file("Sources/Auth/TokenStore.swift", patch: patch(lines: 30, marker: "a")),
            Fixtures.file("Sources/App/View.swift", patch: patch(lines: 30, marker: "b")),
        ])
        let budget = TokenBudget(maxTokens: 3_000)
        XCTAssertEqual(
            PullRequestDigestBuilder.build(from: input, budget: budget),
            PullRequestDigestBuilder.build(from: input, budget: budget)
        )
    }

    func testTokenApproximationUsesFourCharactersPerToken() {
        let budget = TokenBudget(maxTokens: 10)
        XCTAssertEqual(budget.maxCharacters, 40)
        XCTAssertEqual(budget.approximateTokens(of: "abcd"), 1)
        XCTAssertEqual(budget.approximateTokens(of: "abcde"), 2)
        XCTAssertEqual(budget.approximateTokens(of: ""), 0)
    }

    func testOnDeviceBudgetFitsTheDocumentedCeiling() {
        // ADR 0007: the on-device model has an 8K context; the digest must leave room for
        // the prompt scaffolding and the response.
        XCTAssertLessThanOrEqual(TokenBudget.onDevice.maxTokens, 6_000)
    }

    // MARK: - Measured budgets (plan §0.1)

    func testAMeasurementWinsOverTheEstimate() {
        let budget = TokenBudget(maxTokens: 100)
        // Eight characters: the estimate says two tokens, the "tokenizer" says five, and the
        // whole point of the hook is that the tokenizer is the one that will read the prompt.
        XCTAssertEqual(budget.measured("abcdefgh") { _ in 5 }, 5)
        XCTAssertEqual(budget.measured("abcdefgh"), 2, "no closure at all is the estimate")
    }

    func testDecliningToMeasureFallsBackToTheEstimate() {
        let budget = TokenBudget(maxTokens: 100)
        XCTAssertEqual(budget.measured("abcdefgh") { _ in nil }, 2)
    }

    func testANegativeMeasurementIsClamped() {
        // A platform that answers with nonsense must not produce a negative token count that
        // would make every oversized prompt look like it fits.
        XCTAssertEqual(TokenBudget(maxTokens: 10).measured("abcd") { _ in -3 }, 0)
    }

    func testFitsUsesTheSameMeasurementAsMeasured() {
        let budget = TokenBudget(maxTokens: 4)
        XCTAssertTrue(budget.fits("abcdefghijklmnop") { _ in 4 })
        XCTAssertFalse(budget.fits("abcdefghijklmnop") { _ in 5 })
        XCTAssertTrue(budget.fits("abcdefghijklmnop"), "16 characters ÷ 4 is exactly the budget")
        XCTAssertFalse(budget.fits("abcdefghijklmnopq"))
    }

    func testAReportedContextWindowReplacesTheGuessAndKeepsRoomToAnswer() {
        let budget = TokenBudget.onDevice.limited(toContextSize: 8_192, reservedForResponse: 512)
        XCTAssertEqual(budget.maxTokens, 7_680)
        XCTAssertEqual(
            budget.charactersPerToken,
            TokenBudget.onDevice.charactersPerToken,
            "the fallback estimate is unchanged by a measurement being available"
        )
        XCTAssertGreaterThan(
            budget.maxTokens,
            TokenBudget.onDevice.maxTokens,
            "the ~25 % slack the estimate forces is what the measurement buys back"
        )
    }

    func testAContextWindowSmallerThanTheReservationIsZeroRatherThanNegative() {
        let budget = TokenBudget.onDevice.limited(toContextSize: 100, reservedForResponse: 512)
        XCTAssertEqual(budget.maxTokens, 0)
    }
}
