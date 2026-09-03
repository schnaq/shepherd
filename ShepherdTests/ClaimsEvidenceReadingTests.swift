import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// A recognised coding agent, so a fixture pull request's card opens expanded (ADR 0008's facet).
///
/// File scope rather than a static on the test case, so it can be a default argument below.
private let agentActorKind = ActorKind.agent(
    AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .commitTrailer)
)

/// The optional on-device pass over a description, as the claims card spends it (ADR 0026's
/// tier-2 amendment, plan §2.A).
///
/// The *decisions* about what a model claim is and what merging one means are covered by
/// `ClaimListTests` in ShepherdKit, which runs on the Linux runner. What is tested here is
/// everything a pure value cannot see, and every one of them is a rule the feature would be wrong
/// without:
///
/// - **It is additive.** A model claim becomes a row with its own evidence; the pattern rows keep
///   the verdicts they had.
/// - **It never repeats tier 1.** A model claim of a shape the patterns already found disappears.
/// - **A Mac without the model loses nothing.** No tag, no caption, no error line — the tier-1
///   card exactly as it always was.
/// - **It is attended, and it is spent once.** A collapsed card reads nothing; an open one reads
///   once per pull request, however often the view re-runs its task.
/// - **A pull request that goes away takes its pass with it.** The answer for a detail nobody is
///   looking at any more is never folded into the card that replaced it.
///
/// Every pass goes through the injected ``ClaimExtracting`` seam, so nothing here depends on
/// Apple's model being present or on its answers being stable.
@MainActor
final class ClaimsEvidenceReadingTests: XCTestCase {
    // MARK: - Doubles

    /// A deterministic stand-in for the on-device claim reader.
    ///
    /// It answers with a list the test wrote by hand and records the bodies it was handed, in
    /// order, which is how "once per pull request" and "not while collapsed" are asserted. It can
    /// also be *held* open, so a test can arrive at the moment a pass is in flight and change the
    /// pull request underneath it.
    private actor FakeExtractor: ClaimExtracting {
        private let list: ClaimList
        private let availabilityReason: String?
        private let failure: IntelligenceError?
        private let isHeld: Bool

        private(set) var bodies: [String] = []
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var hasStarted = false

        init(
            list: ClaimList = .empty,
            availabilityReason: String? = nil,
            failure: IntelligenceError? = nil,
            isHeld: Bool = false
        ) {
            self.list = list
            self.availabilityReason = availabilityReason
            self.failure = failure
            self.isHeld = isHeld
        }

        var callCount: Int { bodies.count }

        func availability() async -> ClaimExtractorAvailability {
            guard let availabilityReason else { return .available }
            return .unavailable(availabilityReason)
        }

        func extract(from body: String) async throws -> ClaimList {
            bodies.append(body)
            hasStarted = true
            started?.resume()
            started = nil
            if isHeld {
                await withCheckedContinuation { continuation in
                    release = continuation
                }
            }
            if let failure { throw failure }
            return list
        }

        /// Waits until a pass has actually entered ``extract(from:)``.
        func waitUntilStarted() async {
            if hasStarted { return }
            await withCheckedContinuation { continuation in started = continuation }
        }

        /// Lets a held pass finish.
        func releaseHold() {
            release?.resume()
            release = nil
        }
    }

    // MARK: - Fixtures

    private func summary(
        kind: ActorKind = agentActorKind,
        head: String = "abc123"
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Retry the flaky upload",
            author: ShepherdCore.Actor(login: "claude[bot]", kind: kind),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "claude/retry",
            headRefOid: head,
            baseRefName: "main",
            checkRollup: CheckRollup(state: .failure, total: 1, failureCount: 1)
        )
    }

    /// A pull request whose description claims tests were added, with no test file and red CI —
    /// one contradicted tier-1 line, which is what the additions are measured against.
    private func detail(
        kind: ActorKind = agentActorKind,
        body: String = "Tests added.",
        head: String = "abc123"
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(kind: kind, head: head),
            bodyMarkdown: body,
            files: [
                ChangedFile(
                    path: "Sources/Uploader/Upload.swift",
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: "@@ -1,2 +1,2 @@\n-old\n+new\n"
                )
            ]
        )
    }

    private func list(_ claims: ExtractedClaim...) -> ClaimList {
        ClaimList(claims: claims)
    }

    /// A loaded model with the seam injected, in the state the card is in when it is on screen.
    private func loaded(
        extractor: (any ClaimExtracting)?,
        kind: ActorKind = agentActorKind,
        body: String = "Tests added."
    ) -> ClaimsEvidenceModel {
        let model = ClaimsEvidenceModel()
        model.refresh(detail: detail(kind: kind, body: body), extractor: extractor)
        return model
    }

    // MARK: - Adding a claim

    func testAModelClaimBecomesARowMarkedAsReadByTheModel() async throws {
        let extractor = FakeExtractor(
            list: list(
                ExtractedClaim(
                    kind: .scopeLimited(module: "Sources/Uploader"),
                    quote: "Nothing outside the uploader is touched."
                )
            )
        )
        let model = loaded(extractor: extractor)
        XCTAssertEqual(model.state.lines.count, 1, "the patterns found one claim")
        XCTAssertFalse(model.state.hasModelClaims)

        await model.readWithModel(detail: detail())

        XCTAssertEqual(model.state.lines.count, 2)
        let added = try XCTUnwrap(model.state.lines.first { $0.claim.origin == .model })
        XCTAssertEqual(added.claim.kind, .scopeLimited(module: "Sources/Uploader"))
        XCTAssertEqual(added.claim.quote, "Nothing outside the uploader is touched.")
        XCTAssertTrue(model.state.hasModelClaims)
        XCTAssertTrue(model.state.showsReadingCaption)
        XCTAssertFalse(model.state.isReading)
        XCTAssertNil(model.state.modelUnavailableReason)
    }

    func testTheModelSeesTheDescriptionAndNothingElse() async throws {
        let extractor = FakeExtractor()
        let model = loaded(extractor: extractor, body: "Tests added. Only the uploader changed.")
        await model.readWithModel(detail: detail(body: "Tests added. Only the uploader changed."))
        let bodies = await extractor.bodies
        XCTAssertEqual(bodies, ["Tests added. Only the uploader changed."])
    }

    func testEvidenceIsComputedForAModelClaimTheSameWayAsForAPatternClaim() async throws {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .fixesIssue(number: 142), quote: "This closes #142."))
        )
        let model = loaded(extractor: extractor)
        let patternLineBefore = try XCTUnwrap(model.state.lines.first)

        await model.readWithModel(detail: detail())

        let added = try XCTUnwrap(model.state.lines.first { $0.claim.origin == .model })
        // The issue line is always "?" and always carries its facts (ADR 0026: the issue is not
        // fetched, and a "✓ because a reference exists" would be a claim Shepherd did not check).
        XCTAssertEqual(added.verdict.status, .unclear)
        XCTAssertFalse(added.verdict.facts.isEmpty)
        // And the tier-1 line is the same value it was, verdict included.
        XCTAssertEqual(model.state.lines.first, patternLineBefore)
    }

    func testAModelClaimCanBeTurnedIntoACommentLikeAnyOtherContradictedLine() async throws {
        // Nothing about the tag changes what a row *does*: the pass adds evidence-checked lines
        // and no new behaviour (ADR 0026 — nothing in the card acts).
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .testsAdded, quote: "The suite is green."))
        )
        let model = loaded(extractor: extractor, body: "Fixes #7.")
        await model.readWithModel(detail: detail(body: "Fixes #7."))

        let added = try XCTUnwrap(model.state.lines.first { $0.claim.origin == .model })
        XCTAssertEqual(added.verdict.status, .contradicted)
        XCTAssertEqual(
            model.state.turnIntoComment(added, existingSummary: ""),
            .write(ClaimsEvidenceCardState.commentText(for: added))
        )
    }

    // MARK: - Never repeating tier 1

    func testAClaimOfAShapeThePatternsAlreadyFoundIsDropped() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .testsAdded, quote: "A second sentence about tests."))
        )
        let model = loaded(extractor: extractor)
        let before = model.state.report

        await model.readWithModel(detail: detail())

        XCTAssertEqual(model.state.report, before)
        XCTAssertFalse(model.state.hasModelClaims)
        // Nothing was added, so there is nothing for the caption to be about either.
        XCTAssertFalse(model.state.showsReadingCaption)
    }

    func testAnEmptyAnswerLeavesTheCardExactlyAsItWas() async {
        let model = loaded(extractor: FakeExtractor(list: .empty))
        let before = model.state.report
        await model.readWithModel(detail: detail())
        XCTAssertEqual(model.state.report, before)
        XCTAssertFalse(model.state.showsReadingCaption)
    }

    // MARK: - The degraded states

    func testAMacWithoutTheModelGetsNoTagNoCaptionAndNoError() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .noBreakingChanges, quote: "Backwards compatible.")),
            availabilityReason: "Apple Intelligence is switched off."
        )
        let model = loaded(extractor: extractor)
        let before = model.state.report

        await model.readWithModel(detail: detail())

        XCTAssertEqual(model.state.report, before)
        XCTAssertFalse(model.state.hasModelClaims)
        XCTAssertFalse(model.state.showsReadingCaption)
        XCTAssertFalse(model.state.isReading)
        // The sentence exists for anything that later wants to explain the absence; the card
        // itself shows nothing.
        XCTAssertEqual(model.state.modelUnavailableReason, "Apple Intelligence is switched off.")
        let calls = await extractor.callCount
        XCTAssertEqual(calls, 0)
    }

    func testWithTheTiersOffNothingIsAskedAndNothingIsSaid() async {
        let model = loaded(extractor: nil)
        let before = model.state.report
        await model.readWithModel(detail: detail())
        XCTAssertEqual(model.state.report, before)
        XCTAssertNil(model.state.modelUnavailableReason)
        XCTAssertFalse(model.state.showsReadingCaption)
    }

    func testAFailedPassLeavesTheTierOneCardAndIsNotRetried() async {
        let extractor = FakeExtractor(failure: IntelligenceError.guardrailDeclined)
        let model = loaded(extractor: extractor)
        let before = model.state.report

        await model.readWithModel(detail: detail())
        XCTAssertEqual(model.state.report, before)
        XCTAssertFalse(model.state.isReading)
        XCTAssertFalse(model.state.showsReadingCaption)

        // A guardrail refusal would decline again on the same words (ADR 0007's no-retry rule).
        await model.readWithModel(detail: detail())
        let calls = await extractor.callCount
        XCTAssertEqual(calls, 1)
    }

    func testADescriptionThatClaimsNothingIsNeverRead() async {
        // No card to open, so there is no click to be attended by, and the pass is not the way
        // a card comes into existence — tier 1 decides that (ADR 0026).
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .testsAdded, quote: "The suite is green."))
        )
        let model = loaded(extractor: extractor, body: "typo fix")
        XCTAssertTrue(model.state.isHidden)

        await model.readWithModel(detail: detail(body: "typo fix"))

        let calls = await extractor.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.state.isHidden)
    }

    // MARK: - Attended, and spent once

    func testACollapsedCardReadsNothing() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .noBreakingChanges, quote: "Nothing breaks."))
        )
        // A person's pull request opens collapsed (ADR 0008's facet).
        let model = loaded(extractor: extractor, kind: .human)
        XCTAssertFalse(model.state.isExpanded)

        await model.readWithModel(detail: detail(kind: .human))

        let calls = await extractor.callCount
        XCTAssertEqual(calls, 0, "the expansion is the click that pays for the pass")

        model.state.toggleExpansion()
        await model.readWithModel(detail: detail(kind: .human))
        let afterOpening = await extractor.callCount
        XCTAssertEqual(afterOpening, 1)
    }

    func testThePassIsSpentOncePerPullRequestHoweverOftenItIsAskedFor() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .fixesIssue(number: 7), quote: "Closes #7."))
        )
        let model = loaded(extractor: extractor)

        await model.readWithModel(detail: detail())
        await model.readWithModel(detail: detail())
        // Collapsing and re-opening is not new data, so it is not a new pass.
        model.state.toggleExpansion()
        model.state.toggleExpansion()
        await model.readWithModel(detail: detail())

        let calls = await extractor.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.state.lines.filter { $0.claim.origin == .model }.count, 1)
    }

    func testNewDataForTheSamePullRequestEarnsANewPass() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .fixesIssue(number: 7), quote: "Closes #7."))
        )
        let model = loaded(extractor: extractor)
        await model.readWithModel(detail: detail())

        let moved = detail(head: "def456")
        model.refresh(detail: moved, extractor: extractor)
        await model.readWithModel(detail: moved)

        let calls = await extractor.callCount
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.state.hasModelClaims)
    }

    func testAPullRequestThatGoesAwayTakesItsPassWithIt() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .fixesIssue(number: 7), quote: "Closes #7.")),
            isHeld: true
        )
        let first = detail()
        let model = loaded(extractor: extractor)

        let pass = Task { await model.readWithModel(detail: first) }
        await extractor.waitUntilStarted()
        XCTAssertTrue(model.state.isReading)

        // The reviewer moved on, or a sweep replaced the row. The spinner goes with it.
        let second = detail(head: "def456")
        model.refresh(detail: second, extractor: extractor)
        XCTAssertFalse(model.state.isReading)

        await extractor.releaseHold()
        await pass.value

        // The answer belonged to a card nobody is looking at any more.
        XCTAssertFalse(model.state.hasModelClaims)
        XCTAssertFalse(model.state.isReading)
    }

    func testCancellingClearsTheSpinnerAndLeavesTheCard() async {
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .fixesIssue(number: 7), quote: "Closes #7.")),
            isHeld: true
        )
        let current = detail()
        let model = loaded(extractor: extractor)
        let before = model.state.report

        let pass = Task { await model.readWithModel(detail: current) }
        await extractor.waitUntilStarted()
        model.cancelReading()
        XCTAssertFalse(model.state.isReading)

        await extractor.releaseHold()
        await pass.value

        XCTAssertEqual(model.state.report, before)
    }

    func testCollapsingTheCardCancelsThePassThroughTheViewsOwnTask() async {
        // The card's `.task(id:)` is what stops a pass when the card collapses: the id goes to
        // `nil`, SwiftUI cancels the task, and that cancellation has to reach the pass itself.
        let extractor = FakeExtractor(
            list: list(ExtractedClaim(kind: .fixesIssue(number: 7), quote: "Closes #7.")),
            isHeld: true
        )
        let current = detail()
        let model = loaded(extractor: extractor)
        let before = model.state.report

        let viewTask = Task { await model.readWithModel(detail: current) }
        await extractor.waitUntilStarted()
        XCTAssertTrue(model.state.isReading)
        viewTask.cancel()
        await extractor.releaseHold()
        await viewTask.value

        XCTAssertFalse(model.state.isReading, "a spinner nobody is filling comes down")
        XCTAssertEqual(model.state.report, before, "nothing is folded into a card that was closed")
    }

    // MARK: - The merge, at this layer

    func testMergingKeepsThePatternLinesAndChecksOnlyTheNewOnes() throws {
        let current = detail()
        let report = ClaimsEvidenceReport.build(detail: current, summary: current.summary)
        let merged = ClaimsEvidenceModel.merging(
            ClaimList(claims: [
                ExtractedClaim(kind: .fixesIssue(number: 142), quote: "This closes #142."),
            ]),
            into: report,
            of: current
        )
        XCTAssertEqual(merged.lines.count, report.lines.count + 1)
        XCTAssertEqual(merged.lines.first, report.lines.first)
        let added = try XCTUnwrap(merged.lines.last)
        XCTAssertEqual(added.claim.origin, .model)
        XCTAssertFalse(added.verdict.facts.isEmpty)
    }
}
