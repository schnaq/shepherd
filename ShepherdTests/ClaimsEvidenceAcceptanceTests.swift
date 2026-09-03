import Foundation
import GitHubKit
import ShepherdCore
import XCTest

@testable import Shepherd

/// The claims card's one network read: the issue a `fixes #N` claim points at (ADR 0026's
/// amendment).
///
/// Everything asserted here is a rule about *when the read happens and what the card says when it
/// does not*, and none of it needs a token, a network or a window — the read goes through the
/// injected ``IssueFetching`` seam and the embeddings through ``EmbeddingProviding``, the same
/// two seams ⌘K search and the saved-reply suggester are tested through:
///
/// - a collapsed card, a description with no issue reference, and a signed-out window all cost
///   **zero** reads;
/// - one open of the card is one read, and a second open is none;
/// - a 404 leaves the "acceptance criteria not checked" fact in place and adds why;
/// - a reference that turns out to be a pull request produces no bullets;
/// - moving to another pull request cancels the read in flight, and its answer never lands on
///   the new card.
@MainActor
final class ClaimsEvidenceAcceptanceTests: XCTestCase {
    // MARK: - Seams

    /// A scripted issue read. Records every call, so "fetched once" is an assertion rather than a
    /// hope, and can be told to hang until a test releases it.
    private actor FakeIssues: IssueFetching {
        private let table: [Int: IssueSummary]
        private let error: (any Error)?
        private let holds: Bool
        private(set) var requested: [Int] = []

        init(table: [Int: IssueSummary] = [:], error: (any Error)? = nil, holds: Bool = false) {
            self.table = table
            self.error = error
            self.holds = holds
        }

        var callCount: Int { requested.count }

        func issue(repo: RepoRef, number: Int) async throws -> IssueSummary {
            requested.append(number)
            if holds {
                // Long enough that the test's cancellation always wins, and cooperative so the
                // suite does not actually wait for it.
                try? await Task.sleep(for: .seconds(30))
                try Task.checkCancellation()
            }
            if let error { throw error }
            guard let issue = table[number] else {
                throw GitHubError.notFound(resource: "#\(number)")
            }
            return issue
        }
    }

    /// An embedder that answers for nothing, which is the shape of a Mac without the model: the
    /// matcher then runs its keyword pass alone.
    private actor SilentEmbedder: EmbeddingProviding {
        nonisolated let modelIdentifier = "fake-acceptance-1"
        private(set) var availabilityAsks = 0

        func availability() async -> EmbeddingAvailability {
            availabilityAsks += 1
            return .unavailable("no model in this test")
        }

        func vector(for text: String) async -> SearchVector? { nil }
    }

    /// Anything that is not a ``GitHubKit/GitHubError``: the model has no sentence for it beyond
    /// "the issue could not be read".
    private struct NotAGitHubError: Error {}

    // MARK: - Fixtures

    private func summary(number: Int = 42, headRefOid: String = "abc123") -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_\(number)",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: number,
            title: "Retry the flaky upload",
            author: ShepherdCore.Actor(login: "claude[bot]", kind: .bot),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "claude/retry",
            headRefOid: headRefOid,
            baseRefName: "main",
            checkRollup: CheckRollup(state: .success, total: 1, successCount: 1)
        )
    }

    private func detail(
        number: Int = 42,
        headRefOid: String = "abc123",
        body: String = "Fixes #142. Retries a dropped connection and records the partial write."
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(number: number, headRefOid: headRefOid),
            bodyMarkdown: body,
            files: [
                ChangedFile(
                    path: "Sources/Uploader/RetryPolicy.swift",
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: "@@ -1,2 +1,2 @@\n-old\n+new\n"
                )
            ]
        )
    }

    private func issue(
        number: Int = 142,
        body: String,
        isPullRequest: Bool = false
    ) -> IssueSummary {
        IssueSummary(
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: number,
            title: "Uploads fail silently",
            bodyMarkdown: body,
            state: .open,
            isPullRequest: isPullRequest,
            url: URL(string: "https://github.com/schnaq/review/issues/\(number)")
        )
    }

    private static let checklist = """
    ## Acceptance criteria

    - [ ] the upload retries a dropped connection
    - [ ] the partial write is recorded
    """

    /// A model with both seams injected and the card already open — the state the read happens in.
    private func openedModel(
        issues: FakeIssues,
        detail: PullRequestDetail? = nil
    ) -> ClaimsEvidenceModel {
        let model = ClaimsEvidenceModel(issues: issues, embedder: SilentEmbedder())
        model.refresh(detail: detail ?? self.detail())
        model.state.toggleExpansion()
        return model
    }

    private func issueLine(_ model: ClaimsEvidenceModel) -> ClaimsEvidenceReport.Line? {
        model.state.lines.first { line in
            if case .fixesIssue = line.claim.kind { return true }
            return false
        }
    }

    // MARK: - When nothing is read

    func testACollapsedCardReadsNothing() async {
        let issues = FakeIssues(table: [142: issue(body: Self.checklist)])
        let model = ClaimsEvidenceModel(issues: issues, embedder: SilentEmbedder())
        model.refresh(detail: detail())
        XCTAssertFalse(model.state.isExpanded, "a bot that is not a recognised agent is a person")

        await model.loadAcceptanceCriteria()

        let calls = await issues.callCount
        XCTAssertEqual(calls, 0)
    }

    func testADescriptionWithNoIssueReferenceReadsNothing() async {
        let issues = FakeIssues(table: [142: issue(body: Self.checklist)])
        let model = openedModel(issues: issues, detail: detail(body: "Tests added."))
        XCTAssertTrue(model.referencedIssueNumbers.isEmpty)

        await model.loadAcceptanceCriteria()

        let calls = await issues.callCount
        XCTAssertEqual(calls, 0)
    }

    func testASignedOutWindowLeavesTheLineAsItWas() async {
        // No fetcher anywhere: the model was built without one and the view hands over `nil`.
        let model = ClaimsEvidenceModel(issues: nil, embedder: SilentEmbedder())
        model.refresh(detail: detail())
        model.state.toggleExpansion()

        await model.loadAcceptanceCriteria(using: nil)

        let line = issueLine(model)
        XCTAssertEqual(line?.verdict.status, .unclear)
        XCTAssertEqual(
            line?.verdict.facts.last?.englishSentence,
            "Acceptance criteria not checked — the issue is not fetched."
        )
    }

    // MARK: - The read

    func testTheIssueIsReadOnceAndTheBulletsBecomeFacts() async {
        let issues = FakeIssues(table: [142: issue(body: Self.checklist)])
        let model = openedModel(issues: issues)

        await model.loadAcceptanceCriteria()

        let line = issueLine(model)
        XCTAssertEqual(line?.verdict.status, .ok, "both bullets are mentioned")
        XCTAssertEqual(line?.verdict.facts.filter { $0.mark == .mentioned }.count, 2)
        XCTAssertEqual(line?.verdict.facts.filter { $0.mark == .notMentioned }.count, 0)

        // A second open of the same card — a redraw, a tab change, the `task(id:)` firing again —
        // costs nothing: the issue and its matches are held in memory for this screen.
        await model.loadAcceptanceCriteria()
        let calls = await issues.callCount
        let requested = await issues.requested
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requested, [142])
    }

    func testAnUnmentionedBulletIsNeverAContradiction() async {
        let issues = FakeIssues(table: [
            142: issue(body: """
            - [ ] the upload retries a dropped connection
            - [ ] the crash reporter learns about the failure
            """)
        ])
        let model = openedModel(issues: issues)

        await model.loadAcceptanceCriteria()

        let line = issueLine(model)
        XCTAssertEqual(line?.verdict.status, .unclear)
        XCTAssertNotEqual(line?.verdict.status, .contradicted)
        XCTAssertEqual(line?.verdict.facts.filter { $0.mark == .notMentioned }.count, 1)
        // A ? line offers no "Turn into a comment" button, so nothing about a bullet can be
        // drafted into the review summary.
        XCTAssertTrue(model.state.report.contradictedLines.isEmpty)
    }

    func testTheEmbedderIsAskedOnceAndItsAbsenceIsNotAnError() async {
        let embedder = SilentEmbedder()
        let issues = FakeIssues(table: [142: issue(body: Self.checklist)])
        let model = ClaimsEvidenceModel(issues: issues, embedder: embedder)
        model.refresh(detail: detail())
        model.state.toggleExpansion()

        await model.loadAcceptanceCriteria()

        let asks = await embedder.availabilityAsks
        XCTAssertEqual(asks, 1)
        // The keyword pass answered on its own, which is the whole behaviour without the model.
        XCTAssertEqual(issueLine(model)?.verdict.status, .ok)
    }

    // MARK: - When the read fails

    func testA404KeepsTheNotCheckedFactAndAddsWhy() async {
        let issues = FakeIssues(error: GitHubError.notFound(resource: "schnaq/review#142 issue"))
        let model = openedModel(issues: issues)

        await model.loadAcceptanceCriteria()

        let facts = issueLine(model)?.verdict.facts ?? []
        XCTAssertEqual(issueLine(model)?.verdict.status, .unclear)
        XCTAssertEqual(facts.count, 3)
        XCTAssertEqual(
            facts[1].englishSentence,
            "Acceptance criteria not checked — the issue is not fetched."
        )
        XCTAssertEqual(facts[2].englishSentence, IssueLookupFailure.notFound.sentence)

        // A failure is remembered, so the card does not re-ask on every redraw.
        await model.loadAcceptanceCriteria()
        let calls = await issues.callCount
        XCTAssertEqual(calls, 1)
    }

    func testEveryFailureShapeGetsItsOwnSentence() {
        XCTAssertEqual(
            ClaimsEvidenceModel.failure(for: GitHubError.notFound(resource: "x")),
            .notFound
        )
        XCTAssertEqual(
            ClaimsEvidenceModel.failure(for: GitHubError.forbidden(message: "x")),
            .noPermission
        )
        XCTAssertEqual(ClaimsEvidenceModel.failure(for: GitHubError.unauthorized), .noPermission)
        XCTAssertEqual(
            ClaimsEvidenceModel.failure(for: GitHubError.transport(message: "offline")),
            .offline
        )
        // A rate limit is not "could not be reached": GitHub answered.
        XCTAssertEqual(
            ClaimsEvidenceModel.failure(for: GitHubError.rateLimited(retryAfter: 60, resetAt: nil)),
            .failed
        )
        XCTAssertEqual(ClaimsEvidenceModel.failure(for: NotAGitHubError()), .failed)
    }

    // MARK: - A reference that is not an issue

    func testAPullRequestReferenceProducesNoBullets() async {
        let issues = FakeIssues(table: [
            142: issue(body: "- [ ] a task list in a pull request", isPullRequest: true)
        ])
        let model = openedModel(issues: issues)

        await model.loadAcceptanceCriteria()

        let facts = issueLine(model)?.verdict.facts ?? []
        XCTAssertEqual(issueLine(model)?.verdict.status, .unclear)
        XCTAssertTrue(facts.allSatisfy { $0.mark == nil })
        XCTAssertTrue(
            facts.contains { $0.englishSentence.contains("is a pull request rather than an issue") },
            facts.map(\.englishSentence).joined(separator: " | ")
        )
    }

    func testAnIssueWithNoChecklistSaysSo() async {
        let issues = FakeIssues(table: [142: issue(body: "Uploads fail silently. Please fix.")])
        let model = openedModel(issues: issues)

        await model.loadAcceptanceCriteria()

        let facts = issueLine(model)?.verdict.facts ?? []
        XCTAssertTrue(
            facts.contains { $0.englishSentence.contains("holds no checklist or list") },
            facts.map(\.englishSentence).joined(separator: " | ")
        )
    }

    // MARK: - Cancellation

    func testMovingToAnotherPullRequestCancelsTheReadInFlight() async {
        let issues = FakeIssues(table: [142: issue(body: Self.checklist)], holds: true)
        let model = openedModel(issues: issues)

        let load = Task { await model.loadAcceptanceCriteria() }
        // Wait until the read has actually started, so what follows cancels something rather
        // than racing it: the fake records the number before it suspends.
        while await issues.callCount == 0 {
            await Task.yield()
        }
        model.refresh(detail: detail(number: 43))
        await load.value

        // The answer belonged to #42's card and has nowhere to land: the new card's issue line is
        // the un-fetched one, and nothing about the old pull request is held.
        let line = issueLine(model)
        XCTAssertEqual(line?.verdict.status, .unclear)
        XCTAssertEqual(line?.verdict.facts.count, 2)
        XCTAssertTrue((line?.verdict.facts ?? []).allSatisfy { $0.mark == nil })
    }

    func testANewHeadRecomputesTheMatchesWithoutASecondRead() async {
        let issues = FakeIssues(table: [142: issue(body: Self.checklist)])
        let model = openedModel(issues: issues)
        await model.loadAcceptanceCriteria()
        XCTAssertEqual(issueLine(model)?.verdict.status, .ok)

        // The agent pushed a fix round that dropped the second half of the description. The issue
        // is still the issue — one read — but what the pull request says about itself changed, so
        // the matches have to be recomputed.
        model.refresh(detail: detail(
            headRefOid: "def456",
            body: "Fixes #142. Retries a dropped connection."
        ))
        await model.loadAcceptanceCriteria()

        let calls = await issues.callCount
        XCTAssertEqual(calls, 1, "the issue body is cached for this screen")
        XCTAssertEqual(issueLine(model)?.verdict.status, .unclear)
        XCTAssertEqual(
            issueLine(model)?.verdict.facts.filter { $0.mark == .notMentioned }.count,
            1
        )
    }
}
