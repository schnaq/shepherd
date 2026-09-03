import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// "Explain these lines" (plan §3.D): the request, the ladder and the popover.
///
/// Four things are worth testing and none of them needs a window, a network or a Mac with Apple
/// Intelligence switched on:
///
/// - **The context is the drafting context, unchanged.** An explanation must send exactly the
///   excerpt an inline-comment draft sends — same window, same character share, same "anchored
///   lines go last" rule — because that is what makes ADR 0007's privacy sentence cover both
///   surfaces with one clause. Asserted against the drafting builder itself rather than against
///   copied expectations, so the two cannot drift apart without a failure here.
/// - **The instruction carries the language.** A German reviewer reads German; the prompt says so
///   by name, in English, so a small model does not have to interpret a language tag.
/// - **The ladder is the drafting ladder.** Cloud rung first, stepping down to on-device on a
///   failure before the first element, and a defined refusal where a tier has not implemented the
///   method at all.
/// - **The popover is a state machine.** Stop keeps what arrived, Escape does not, a mid-answer
///   failure shows both halves — and "Turn into a comment" goes through ``AIDraftFieldState``, so
///   an explanation can no more overwrite a reviewer's half-typed comment than a draft can.
final class ExplainSelectionTests: XCTestCase {
    // MARK: - Fixtures

    private func summary() -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Retry the flaky upload",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "feature",
            headRefOid: "abc123",
            baseRefName: "main"
        )
    }

    /// A patch of `lines` context lines numbered 1…n, plus one added line at the end.
    private func longPatch(lines: Int = 200) -> String {
        var text = "@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 1...lines {
            text += " context line \(index) — code long enough for the budget to matter\n"
        }
        return text + "+added tail line\n"
    }

    private func detail(patch: String?) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(),
            bodyMarkdown: "Retries the upload twice before giving up.",
            files: [
                ChangedFile(
                    path: "Sources/Upload.swift",
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: patch
                )
            ]
        )
    }

    private func anchor(line: Int = 100, startLine: Int? = nil) -> InlineCommentAnchor {
        InlineCommentAnchor(
            path: "Sources/Upload.swift",
            line: line,
            side: .right,
            startLine: startLine
        )
    }

    private func markedLines(of excerpt: String) -> [String] {
        excerpt
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix(InlineCommentDraftBuilder.anchorMarker) }
    }

    // MARK: - The request reuses the drafting window

    func testTheExcerptIsExactlyTheOneAnInlineDraftWouldSend() {
        let fixture = detail(patch: longPatch())
        let selection = anchor()

        for budget in [TokenBudget.cloud, TokenBudget.onDevice] {
            let drafted = InlineCommentDraftBuilder.build(
                detail: fixture,
                anchor: selection,
                budget: budget
            )
            let explained = ExplainSelectionRequest.build(
                detail: fixture,
                anchor: selection,
                budget: budget,
                languageName: "German"
            )
            // The whole request, not only its text: the truncation flag, the budget and the
            // header fields are what the prompt is built from, and a difference in any of them
            // would be a second thing to describe in `CONTRIBUTING.md`.
            XCTAssertEqual(explained.selection, drafted)
            XCTAssertEqual(explained.approximateTokenCount, drafted.approximateTokenCount)
            XCTAssertLessThanOrEqual(
                explained.approximateTokenCount,
                budget.maxTokens,
                "an explanation is inside the tier's budget for the same reason a draft is"
            )
        }
    }

    func testTheWindowIsTheAnchoredLinesPlusTheirNeighbourhood() {
        let request = ExplainSelectionRequest.build(
            detail: detail(patch: longPatch()),
            anchor: anchor(line: 100),
            budget: .cloud,
            languageName: "German"
        )

        let marked = markedLines(of: request.selection.excerpt)
        XCTAssertEqual(marked.count, 1, "exactly the selected line carries the marker")
        XCTAssertTrue(marked[0].contains("context line 100"))
        XCTAssertTrue(request.selection.excerpt.contains("context line 76"))
        XCTAssertFalse(request.selection.excerpt.contains("context line 75"))
        XCTAssertTrue(request.selection.excerptWasTruncated)
        XCTAssertTrue(request.hasExcerpt)
        XCTAssertEqual(request.path, "Sources/Upload.swift")
        XCTAssertEqual(request.anchor.line, 100)
    }

    func testAMultiLineSelectionMarksEveryLineItCovers() {
        let request = ExplainSelectionRequest.build(
            detail: detail(patch: longPatch(lines: 40)),
            anchor: anchor(line: 12, startLine: 10),
            budget: .cloud,
            languageName: "German"
        )
        let marked = markedLines(of: request.selection.excerpt)
        XCTAssertEqual(marked.count, 3, "the selection is three lines, so three are marked")
        XCTAssertTrue(marked[0].contains("context line 10"))
        XCTAssertTrue(marked[2].contains("context line 12"))
    }

    func testEveryTierGetsAnExcerptInsideItsOwnBudget() {
        // A 500-line selection, as in `AIDraftingTests`: the anchored block alone is larger than
        // the on-device tier's whole context, which is precisely the case ADR 0007 says must be a
        // bounded prompt rather than a silent overflow — and an explanation must inherit that,
        // not re-earn it.
        let selection = InlineCommentAnchor(
            path: "Sources/Upload.swift",
            line: 600,
            side: .right,
            startLine: 100
        )
        let fixture = detail(patch: longPatch(lines: 1_200))
        let onDevice = ExplainSelectionRequest.build(
            detail: fixture,
            anchor: selection,
            budget: .onDevice,
            languageName: "German"
        )
        let cloud = ExplainSelectionRequest.build(
            detail: fixture,
            anchor: selection,
            budget: .cloud,
            languageName: "German"
        )

        XCTAssertLessThanOrEqual(onDevice.approximateTokenCount, TokenBudget.onDevice.maxTokens)
        XCTAssertLessThanOrEqual(cloud.approximateTokenCount, TokenBudget.cloud.maxTokens)
        XCTAssertLessThan(
            onDevice.selection.excerpt.count,
            cloud.selection.excerpt.count,
            "the small tier is handed less, not the same prompt and a bigger hope"
        )
        XCTAssertTrue(onDevice.selection.excerptWasTruncated)
        // The lines the reviewer pointed at are the last thing given up, so they are still there.
        XCTAssertTrue(onDevice.selection.excerpt.contains("context line 100"))
        XCTAssertFalse(markedLines(of: onDevice.selection.excerpt).isEmpty)
    }

    func testAFileWithoutAPatchYieldsNoExcerptToExplain() {
        let request = ExplainSelectionRequest.build(
            detail: detail(patch: nil),
            anchor: anchor(line: 3),
            budget: .cloud,
            languageName: "German"
        )
        XCTAssertFalse(request.hasExcerpt)
    }

    // MARK: - The instruction and the prompt

    func testTheInstructionNamesTheLanguageTheAnswerMustBeIn() {
        let german = ExplainSelectionRequest.currentLanguageName(of: Locale(identifier: "de_DE"))
        let english = ExplainSelectionRequest.currentLanguageName(of: Locale(identifier: "en_US"))
        XCTAssertFalse(german.isEmpty)
        XCTAssertNotEqual(german, english, "two locales must not resolve to one language name")

        let request = ExplainSelectionRequest.build(
            detail: detail(patch: longPatch(lines: 20)),
            anchor: anchor(line: 10),
            budget: .cloud,
            languageName: german
        )
        XCTAssertTrue(
            request.instructions.contains(german),
            "the reviewer's language is named in the instruction, not guessed by the model"
        )
        XCTAssertTrue(
            request.instructions.contains(IntelligencePrompt.explainSelectionInstructions),
            "and the shared contract is still all of the rest of it"
        )
    }

    func testTheInstructionAsksForAnExplanationRatherThanAReview() {
        // Structural, not word-for-word: what must be true is that the prompt that produces a
        // *review comment* and the prompt that produces an *explanation* are not the same text,
        // because the two live one keystroke apart on the same composer.
        XCTAssertNotEqual(
            IntelligencePrompt.explainSelectionInstructions,
            IntelligencePrompt.draftInlineCommentInstructions
        )
        XCTAssertFalse(IntelligencePrompt.explainSelectionInstructions.isEmpty)
    }

    func testTheBodyIsTheDraftingBodyWithTheSelectionNamedAsASelection() {
        let fixture = detail(patch: longPatch())
        let selection = anchor(line: 100)
        let request = ExplainSelectionRequest.build(
            detail: fixture,
            anchor: selection,
            budget: .cloud,
            languageName: "German"
        )
        let body = IntelligencePrompt.body(for: request)
        XCTAssertTrue(body.contains("schnaq/review"))
        XCTAssertTrue(body.contains("#42 — Retry the flaky upload"))
        XCTAssertTrue(body.contains("Sources/Upload.swift"))
        XCTAssertTrue(body.contains("head side, line 100"))
        XCTAssertTrue(body.contains(">>"), "the marker is explained, so it can be understood")
        XCTAssertTrue(body.contains("context line 100"))
        XCTAssertFalse(
            body.contains("Commented line"),
            "a prompt that says 'commented on' nudges the model into writing a comment"
        )

        // And the drafting prompt is byte-for-byte what it always was: the two labels are the
        // only difference between the two bodies, and the default arguments reproduce the old one.
        let drafted = InlineCommentDraftBuilder.build(
            detail: fixture,
            anchor: selection,
            budget: .cloud
        )
        XCTAssertTrue(IntelligencePrompt.body(for: drafted).contains("Commented line: head side"))
    }

    // MARK: - The ladder

    func testAScriptedExplanationComesBackLabelledWithTheTierThatWroteIt() async throws {
        let ladder = router(script: scripted(["Das", "Das ist eine Wiederholung."]))
        let outcome = await ladder.streamExplanation(
            for: detail(patch: longPatch(lines: 20)),
            anchor: anchor(line: 10),
            languageName: "German"
        )

        let stream = try XCTUnwrap(outcome.stream, "a scripted tier answered, so there is a stream")
        XCTAssertEqual(stream.kind, .anthropic, "the cloud rung is tried first, as for drafts")
        // The elements are cumulative, never deltas: the last one is the whole explanation.
        var received: [String] = []
        for try await partial in stream.text {
            received.append(partial)
        }
        XCTAssertEqual(received.first, "Das", "the popover fills from the first word")
        XCTAssertEqual(received.last, "Das ist eine Wiederholung.")
    }

    func testACloudTierThatFailsBeforeTheFirstElementStepsDownToOnDevice() async {
        // The whole point of the ladder: tier 2 is what this feature is designed for, so a cloud
        // rung that never produced a character must not cost the reviewer the answer.
        let ladder = IntelligenceRouter(
            configuration: configuration(),
            tiers: IntelligenceTiers(
                cloud: { _ in StubTier(kind: .anthropic) },
                onDevice: { StubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                explanationStream: { provider, _ in
                    guard provider.kind == .onDevice else {
                        return IntelligenceStreaming.failing(
                            IntelligenceError.http(status: 401, message: "bad key")
                        )
                    }
                    return AsyncThrowingStream { continuation in
                        continuation.yield("Auf dem Gerät erklärt.")
                        continuation.finish()
                    }
                }
            )
        )

        let outcome = await ladder.streamExplanation(
            for: detail(patch: longPatch(lines: 20)),
            anchor: anchor(line: 10),
            languageName: "German"
        )
        XCTAssertEqual(outcome.stream?.kind, .onDevice)
    }

    func testATierThatHasNotImplementedExplainingRefusesRatherThanImprovises() async {
        // `StubTier` implements the four required methods and nothing else, so both rungs fall
        // through to the protocol's default. That default must be a refusal: an explanation the
        // reviewer cannot tell apart from a real one is the failure this feature must not have.
        let ladder = IntelligenceRouter(
            configuration: configuration(),
            tiers: IntelligenceTiers(
                cloud: { _ in StubTier(kind: .anthropic) },
                onDevice: { StubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil }
            )
        )
        let outcome = await ladder.streamExplanation(
            for: detail(patch: longPatch(lines: 20)),
            anchor: anchor(line: 10),
            languageName: "German"
        )
        XCTAssertNil(outcome.stream)
        XCTAssertNotNil(outcome.failure?.message)
    }

    func testAFileWithoutADiffIsRefusedBeforeAnyTierIsAsked() async {
        let ladder = router(script: scripted(["never asked"]))
        let outcome = await ladder.streamExplanation(
            for: detail(patch: nil),
            anchor: anchor(line: 3),
            languageName: "German"
        )
        XCTAssertNil(outcome.stream)
        guard case .some(.unavailable) = outcome.failure else {
            return XCTFail("no patch is 'nothing to explain', not a tier failure")
        }
    }

    func testIntelligenceOffProducesNoRequestAtAll() async {
        let ladder = IntelligenceRouter(configuration: .disabled)
        let outcome = await ladder.streamExplanation(
            for: detail(patch: longPatch(lines: 20)),
            anchor: anchor(line: 10),
            languageName: "German"
        )
        guard case .some(.disabled) = outcome.failure else {
            return XCTFail("with intelligence off there is nothing to say and nothing to send")
        }
    }

    // MARK: - The popover's state machine

    func testStoppingKeepsWhatArrivedAndKeepsItAttributed() {
        var state = ExplainSelectionState()
        state.begin()
        state.started(kind: .onDevice)
        state.streamed("Diese Zeilen ")
        state.streamed("Diese Zeilen wiederholen den Upload.")
        XCTAssertTrue(state.isStreaming)
        XCTAssertNil(state.explanation, "an unfinished answer is not one to turn into a comment")

        state.stop()

        XCTAssertEqual(state.explanation, "Diese Zeilen wiederholen den Upload.")
        XCTAssertEqual(state.kind, .onDevice, "still the tier's words, so still its name")
        XCTAssertFalse(state.isExplaining)
        XCTAssertNil(state.failureMessage, "a stop the reviewer asked for is not a failure")
    }

    func testStoppingBeforeTheFirstSentenceLeavesNoTrace() {
        var state = ExplainSelectionState()
        state.begin()
        XCTAssertTrue(state.isExplaining)

        state.stop()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.explanation)
        XCTAssertNil(state.failureMessage)
        XCTAssertEqual(state.text, "")
    }

    func testEscapeThrowsTheAnswerAwayRatherThanKeepingIt() {
        var state = ExplainSelectionState()
        state.begin()
        state.started(kind: .anthropic)
        state.streamed("Halb erklärt")

        // Escape, and the Close button: the popover was dismissed, so the question was withdrawn.
        state.reset()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.text, "")
        XCTAssertNil(state.explanation)
        XCTAssertNil(state.kind)
    }

    func testAFinishedStreamIsTrimmedAndAnEmptyOneIsAFailure() {
        var state = ExplainSelectionState()
        state.begin()
        state.started(kind: .onDevice)
        state.streamed("  Fertig erklärt.\n\n")
        state.finish()
        XCTAssertEqual(state.explanation, "Fertig erklärt.")

        var empty = ExplainSelectionState()
        empty.begin()
        empty.started(kind: .onDevice)
        empty.finish()
        XCTAssertNil(empty.explanation)
        XCTAssertNotNil(
            empty.failureMessage,
            "a popover that stopped spinning and shows nothing looks like a bug"
        )
    }

    func testAFailureMidAnswerShowsBothTheSentencesAndTheReason() {
        var state = ExplainSelectionState()
        state.begin()
        state.started(kind: .anthropic)
        state.streamed("Die Wiederholung")
        state.fail("the endpoint returned 429: slow down")

        XCTAssertEqual(state.text, "Die Wiederholung")
        XCTAssertEqual(state.explanation, "Die Wiederholung", "a partial answer is still usable")
        XCTAssertEqual(state.failureMessage, "the endpoint returned 429: slow down")
        XCTAssertEqual(state.kind, .anthropic)
    }

    func testAFailureBeforeAnySentenceIsTheOnlyThingShown() {
        var state = ExplainSelectionState()
        state.begin()
        state.fail("Apple Intelligence declined this content.")

        XCTAssertEqual(state.text, "")
        XCTAssertNil(state.explanation)
        XCTAssertEqual(state.failureMessage, "Apple Intelligence declined this content.")
    }

    func testASnapshotThatRepeatsItselfChangesNothing() {
        var state = ExplainSelectionState()
        state.begin()
        state.started(kind: .onDevice)
        state.streamed("Gleich")
        let before = state
        state.streamed("Gleich")
        XCTAssertEqual(state, before, "every element the popover sees is a redraw")
    }

    // MARK: - Turning it into a comment

    func testAnExplanationLandsInAnEmptyCommentFieldLabelledAsADraft() {
        // The composer's own sequence: the explanation is handed to `AIDraftFieldState` as the
        // outcome it would have produced for a draft, so it obeys the drafting rules rather than
        // a second copy of them.
        var field = AIDraftFieldState()
        let written = field.finish(
            .value(IntelligenceOutput(kind: .onDevice, value: "Diese Zeilen wiederholen.")),
            existingText: ""
        )
        XCTAssertEqual(written, "Diese Zeilen wiederholen.")
        XCTAssertEqual(field.draftedKind, .onDevice, "captioned, because it is not their text")
        XCTAssertEqual(field.labelledKind, .onDevice)

        // …and the caption goes on the reviewer's first keystroke, exactly as for a draft.
        field.fieldChanged(to: "Diese Zeilen wiederholen. Und?")
        XCTAssertNil(field.labelledKind)
    }

    func testAnExplanationNeverSilentlyOverwritesAHalfTypedComment() {
        var field = AIDraftFieldState()
        let typed = "Ich glaube, das ist off by one."
        let written = field.finish(
            .value(IntelligenceOutput(kind: .anthropic, value: "Diese Zeilen wiederholen.")),
            existingText: typed
        )

        XCTAssertNil(written, "nothing is written until the reviewer answers")
        XCTAssertEqual(field.pendingDraft?.text, "Diese Zeilen wiederholen.")
        XCTAssertEqual(field.pendingDraft?.kind, .anthropic)

        // Append puts it after their paragraph, with the blank line the field's Markdown needs.
        guard case .write(let appended) = field.resolve(.append, existingText: typed) else {
            return XCTFail("append writes the two together")
        }
        XCTAssertEqual(appended, typed + "\n\nDiese Zeilen wiederholen.")
        XCTAssertEqual(field.draftedKind, .anthropic)
    }

    func testDiscardingTheQuestionLeavesTheCommentExactlyAsItWas() {
        var field = AIDraftFieldState()
        _ = field.finish(
            .value(IntelligenceOutput(kind: .onDevice, value: "Diese Zeilen wiederholen.")),
            existingText: "Meine eigene Notiz."
        )
        field.discardPendingDraft()
        XCTAssertEqual(field.phase, .idle)
        XCTAssertNil(field.pendingDraft)
        XCTAssertNil(field.labelledKind)
    }

    // MARK: - The tier caption

    func testTheTierLinesNameACloudProviderAndNameNobodyOnDevice() {
        // Structural rather than word-for-word, like `StreamingDraftUITests`: `String(localized:)`
        // resolves against the runner's language. What is pinned is that the caption says *where
        // the explanation came from* — a cloud tier by its badge, the on-device tier by nothing,
        // because there is no third party to name.
        let onDevice = ExplainSelectionPopover.tierLine(.onDevice)
        XCTAssertFalse(onDevice.contains(IntelligenceKind.anthropic.badge))
        XCTAssertFalse(onDevice.contains(IntelligenceKind.openAICompatible.badge))
        XCTAssertTrue(
            ExplainSelectionPopover.tierLine(.anthropic)
                .contains(IntelligenceKind.anthropic.badge)
        )
        XCTAssertTrue(
            ExplainSelectionPopover.tierLine(.openAICompatible)
                .contains(IntelligenceKind.openAICompatible.badge)
        )
        XCTAssertNotEqual(onDevice, ExplainSelectionPopover.tierLine(.anthropic))

        let explaining = ExplainSelectionPopover.explainingLine(.onDevice)
        XCTAssertFalse(explaining.contains(IntelligenceKind.anthropic.badge))
        XCTAssertNotEqual(
            explaining,
            onDevice,
            "'still arriving' and 'finished' are different facts about the same tier"
        )
    }

    // MARK: - Router fixtures

    private func configuration() -> IntelligenceConfiguration {
        IntelligenceConfiguration(
            mode: .onDeviceAndCloud,
            cloudKind: .anthropic,
            cloudAPIKey: "not-a-real-key"
        )
    }

    /// A router whose every tier explains with the same script, cloud rung first.
    private func router(
        script: @escaping @Sendable () -> AsyncThrowingStream<String, Error>
    ) -> IntelligenceRouter {
        IntelligenceRouter(
            configuration: configuration(),
            tiers: IntelligenceTiers(
                cloud: { _ in StubTier(kind: .anthropic) },
                onDevice: { StubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                explanationStream: { _, _ in script() }
            )
        )
    }

    /// A scripted provider stream: these cumulative answers, then a clean finish or this failure.
    ///
    /// Rebuilt per call rather than shared, because the ladder consumes one stream per rung and an
    /// already-iterated stream would make the second rung look empty.
    private func scripted(
        _ chunks: [String],
        failure: IntelligenceError? = nil
    ) -> @Sendable () -> AsyncThrowingStream<String, Error> {
        {
            AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

/// A tier that answers nothing on its own: every test here scripts the stream instead.
///
/// It implements the four required methods and **not** `streamExplanation(_:)`, which is
/// deliberate: that is what makes the protocol's default reachable from a test.
private struct StubTier: IntelligenceProvider {
    let kind: IntelligenceKind

    var isAvailable: Bool { get async { true } }

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        throw IntelligenceError.malformedResponse
    }

    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
        throw IntelligenceError.malformedResponse
    }

    func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String {
        throw IntelligenceError.malformedResponse
    }

    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
        throw IntelligenceError.malformedResponse
    }
}
