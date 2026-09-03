import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The composer half of streaming drafts (plan §3.B): what a reviewer can do to a stream while it
/// runs, and what the field looks like afterwards.
///
/// The rules here are the ones that make a streaming draft a *tool* rather than something
/// happening to the reviewer, and none of them is visual:
///
/// - **Stop keeps what arrived.** The stop button and Escape end the request, and every word that
///   already landed stays in the field with its caption. Deleting it would punish the reviewer for
///   changing their mind.
/// - **A keystroke wins.** Typing during a stream takes the field back *and* ends the request, so
///   the model is not still generating tokens into a field it no longer owns.
/// - **A stop is not a failure.** Nothing the reviewer did themselves puts a red line under the
///   field — not a stop before the first token, and not the request finishing empty after one.
/// - **The question still comes first.** With text already in the field, nothing is requested until
///   the reviewer answers replace-or-append; a stream cannot ask halfway through.
/// - **A failure mid-stream keeps the partial.** The tier's own reason is what the field would show
///   if nothing had arrived, and nothing at all if something had.
///
/// The two composers are SwiftUI views, so ``DraftedField`` below is the same sequence they run —
/// button, task, `AIDraftFieldState`, field — without a window. That makes the *cancellation*
/// paths testable as they actually happen: through a task somebody stops from outside while text
/// is arriving, rather than by calling the state's methods in the order the test already believes.
@MainActor
final class StreamingDraftUITests: XCTestCase {
    // MARK: - Stopping

    func testStoppingAStreamKeepsWhatArrivedAndKeepsItLabelled() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        let field = DraftedField()
        field.toggle { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }
        continuation.yield("Check the retry")
        await field.wait { field.text == "Check the retry" }

        XCTAssertEqual(field.text, "Check the retry")
        XCTAssertEqual(field.draft.streamingDraft?.kind, .onDevice, "the tier is known already")
        XCTAssertEqual(field.draft.labelledKind, .onDevice, "and the caption is up")

        // The stop button, which is also what Escape reaches.
        field.toggle { XCTFail("a second request must not be started"); return .disabled }

        XCTAssertEqual(field.text, "Check the retry", "what arrived stays")
        XCTAssertEqual(field.draft.draftedKind, .onDevice, "and stays labelled as a draft")
        XCTAssertFalse(field.draft.isDrafting, "the button is a sparkles button again")

        // A snapshot that was already in flight when the reviewer stopped.
        continuation.yield("Check the retry bound, it is off by one.")
        continuation.finish()
        await field.settle()

        XCTAssertEqual(field.text, "Check the retry", "a snapshot after the stop is dropped")
        XCTAssertNil(field.draft.failureMessage, "a stop the reviewer asked for is not a failure")
    }

    func testStoppingBeforeTheFirstTokenLeavesNoTraceAtAll() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        let field = DraftedField()
        field.toggle { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }
        await field.wait { field.draft.streamingDraft != nil }
        XCTAssertTrue(field.draft.isDrafting, "the spinner is up, nothing has arrived")

        field.stop()

        XCTAssertEqual(field.text, "", "nothing was written, so nothing is kept")
        XCTAssertEqual(field.draft.phase, .idle)
        XCTAssertNil(field.draft.failureMessage)
        XCTAssertNil(field.draft.labelledKind, "no caption over an empty field")

        continuation.finish()
        await field.settle()
        XCTAssertNil(field.draft.failureMessage, "an empty answer nobody waited for says nothing")
    }

    func testStoppingWhileTheLadderIsStillChoosingATierReportsNothing() async {
        // The window between the click and the tier: the router is still trying the cloud rung,
        // and the reviewer has already changed their mind. Whatever the ladder ends up saying is
        // an answer to a question that no longer exists.
        let (gate, opener) = AsyncStream<Void>.makeStream(of: Void.self)
        let field = DraftedField()
        field.toggle {
            for await _ in gate { break }
            return .failed("the endpoint returned 401")
        }
        XCTAssertTrue(field.draft.isDrafting, "the request is out, no tier has answered")

        field.stop()
        XCTAssertEqual(field.draft.phase, .idle)

        opener.yield(())
        opener.finish()
        await field.settle()

        XCTAssertNil(field.draft.failureMessage, "the reviewer stopped it; there is nothing to say")
        XCTAssertEqual(field.text, "")
    }

    func testClosingTheSheetEndsTheRequestWithoutFilingItAsAFinishedDraft() async {
        // Cancelling the task is all a closing sheet does — the field is gone, so nobody touches
        // it. The loop still has to recognise the stop: `AsyncThrowingStream` ends a cancelled
        // iteration *without* throwing, so a loop that only trusted `CancellationError` would
        // file this as a stream that ran to completion and produced nothing, which is a failure
        // line.
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        let field = DraftedField()
        field.toggle { .stream(IntelligenceStream(kind: .anthropic, text: stream)) }
        await field.wait { field.draft.streamingDraft != nil }
        XCTAssertNotNil(field.draft.streamingDraft)

        field.close()
        continuation.finish()
        await field.settle()

        XCTAssertNil(field.draft.failureMessage, "a stopped request is not an empty answer")
        XCTAssertEqual(field.draft.phase, .idle)
    }

    // MARK: - Typing

    func testTypingDuringAStreamKeepsTheKeystrokeAndEndsTheRequest() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        let field = DraftedField()
        field.toggle { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }
        continuation.yield("Check the")
        await field.wait { field.text == "Check the" }
        XCTAssertEqual(field.text, "Check the")

        field.type("My own sentence.")

        XCTAssertEqual(field.text, "My own sentence.")
        XCTAssertNil(field.draft.labelledKind, "their keystroke makes it their text")
        XCTAssertFalse(field.draft.isDrafting, "the stop happened without a click")

        continuation.yield("Check the retry bound.")
        continuation.finish()
        await field.settle()

        XCTAssertEqual(field.text, "My own sentence.", "later snapshots are refused")
        XCTAssertNil(field.draft.failureMessage)
    }

    // MARK: - The question, still in front of the request

    func testNothingIsRequestedUntilTheReplaceOrAppendQuestionIsAnswered() async {
        let field = DraftedField(text: "My own notes.")
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        field.toggle { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }

        XCTAssertTrue(field.draft.isConfirmingStream, "the question comes before the first token")
        XCTAssertFalse(field.draft.isDrafting, "and before the request, so nothing is in flight")
        XCTAssertEqual(field.writes, [], "the field has not been written to at all")

        field.resolve(.append) { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }
        continuation.yield("Also the timeout.")
        continuation.finish()
        await field.settle()

        XCTAssertEqual(field.text, "My own notes.\n\nAlso the timeout.")
        XCTAssertEqual(field.draft.draftedKind, .onDevice)
    }

    // MARK: - A scripted stream through the router

    func testAScriptedStreamGrowsInTheFieldAndEndsLabelledWithItsTier() async {
        let pullRequest = detail(patch: patch())
        let ladder = router(script: scripted(["Check", "Check the retry bound."]))
        let field = DraftedField()

        field.toggle { await ladder.streamReviewSummaryDraft(for: pullRequest) }
        await field.settle()

        XCTAssertEqual(field.writes.first, "Check", "the field grows from the first word")
        XCTAssertEqual(field.text, "Check the retry bound.")
        XCTAssertEqual(field.draft.draftedKind, .anthropic, "the tier that answered, not a guess")
        XCTAssertNil(field.draft.failureMessage)
    }

    func testAFailureMidStreamKeepsThePartialAndSaysNothingUnderIt() async {
        let pullRequest = detail(patch: patch())
        let ladder = router(script: scripted(["Half a draft"], failure: .malformedResponse))
        let field = DraftedField()

        field.toggle { await ladder.streamReviewSummaryDraft(for: pullRequest) }
        await field.settle()

        XCTAssertEqual(field.text, "Half a draft", "the words the reviewer watched arrive stay")
        XCTAssertEqual(
            field.draft.draftedKind,
            .anthropic,
            "still labelled, because it is not theirs"
        )
        XCTAssertNil(
            field.draft.failureMessage,
            "a red line under text that is visibly there would be the confusing half"
        )
    }

    func testAFailureBeforeTheFirstTokenIsTheOneLineTheFieldShows() async {
        let pullRequest = detail(patch: patch())
        // Both rungs fail before yielding, so the ladder runs out and the field says why.
        let ladder = router(script: scripted([], failure: .http(status: 401, message: "bad key")))
        let field = DraftedField()

        field.toggle { await ladder.streamReviewSummaryDraft(for: pullRequest) }
        await field.settle()

        XCTAssertEqual(field.text, "", "nothing arrived, so nothing is kept")
        XCTAssertNotNil(field.draft.failureMessage)
        XCTAssertNil(field.draft.labelledKind)
    }

    // MARK: - The tier line

    func testTheDraftingLineNamesTheTierAndTheOnDeviceOneNamesNobody() {
        // Structural rather than word-for-word: `String(localized:)` resolves against the
        // runner's own language (see `LocalizationTests`), so what is pinned here is that the
        // line the reviewer reads while text arrives says *where the text is coming from* — a
        // cloud tier by the same badge the caption uses, and the on-device tier by nothing at
        // all, because there is no third party to name.
        let onDevice = AIDraftStatusView.draftingLine(.onDevice)
        XCTAssertFalse(onDevice.contains(IntelligenceKind.anthropic.badge))
        XCTAssertFalse(onDevice.contains(IntelligenceKind.openAICompatible.badge))
        XCTAssertTrue(
            AIDraftStatusView.draftingLine(.anthropic)
                .contains(IntelligenceKind.anthropic.badge)
        )
        XCTAssertTrue(
            AIDraftStatusView.draftingLine(.openAICompatible)
                .contains(IntelligenceKind.openAICompatible.badge)
        )
        XCTAssertNotEqual(onDevice, AIDraftStatusView.draftingLine(.anthropic))
    }

    // MARK: - Fixtures

    /// A router whose every tier streams the same script, cloud rung first.
    private func router(
        script: @escaping @Sendable () -> AsyncThrowingStream<String, Error>
    ) -> IntelligenceRouter {
        IntelligenceRouter(
            configuration: IntelligenceConfiguration(
                mode: .onDeviceAndCloud,
                cloudKind: .anthropic,
                cloudAPIKey: "not-a-real-key"
            ),
            tiers: IntelligenceTiers(
                cloud: { _ in StubTier(kind: .anthropic) },
                onDevice: { StubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                summaryStream: { _, _ in script() }
            )
        )
    }

    /// A patch long enough to be digested, short enough to read.
    private func patch(lines: Int = 10) -> String {
        var text = "@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 1...lines {
            text += " context line \(index) — code long enough for the budget to matter\n"
        }
        return text + "+added tail line\n"
    }

    private func detail(patch: String) -> PullRequestDetail {
        PullRequestDetail(
            summary: PullRequestSummary(
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
            ),
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

    /// A scripted provider stream: these cumulative drafts, then a clean finish or this failure.
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

/// What a provider's outcome is asked for — the router call, or a stream a test drives by hand.
private typealias StreamProducer = @Sendable () async -> IntelligenceStreamOutcome

/// One text field with an AI-draft button, as the two composers wire it up.
///
/// Deliberately the same sequence as ``SubmitReviewSheet`` and ``InlineCommentComposer``: those are
/// views, and the thing worth testing is not their layout but what happens to the field when a
/// stream is stopped from outside while it runs. Every write into the field is recorded, so a test
/// can assert that the draft *grew* rather than only where it ended up.
@MainActor
private final class DraftedField {
    /// The field's contents.
    private(set) var text: String
    /// The field's drafting state.
    private(set) var draft = AIDraftFieldState()
    /// Every value written into the field, in order.
    private(set) var writes: [String] = []
    /// The running stream's task, cancelled by a stop, an Escape, a keystroke or a closing sheet.
    private var task: Task<Void, Never>?
    /// The last task started, kept after a stop cleared ``task`` so ``settle()`` can still wait
    /// for it — a stopped task is exactly the one whose *remaining* behaviour is worth asserting.
    private var lastTask: Task<Void, Never>?

    init(text: String = "") {
        self.text = text
    }

    /// The sparkles button, and ⇧⌘D: start a draft, or stop the one that is running.
    func toggle(_ outcome: @escaping StreamProducer) {
        guard !draft.isDrafting else { return stop() }
        switch draft.prepareStream(existingText: text) {
        case .askFirst:
            break
        case .ready(let base):
            start(base: base, outcome: outcome)
        }
    }

    /// The reviewer's answer to the replace-or-append question.
    func resolve(_ choice: AIDraftFieldState.Choice, _ outcome: @escaping StreamProducer) {
        switch draft.resolve(choice, existingText: text) {
        case .write(let written):
            write(written)
        case .startStream(let base):
            start(base: base, outcome: outcome)
        case .nothing:
            break
        }
    }

    /// The stop button, or Escape.
    func stop() {
        task?.cancel()
        task = nil
        draft.cancelDrafting()
        write(draft.cancelStream())
    }

    /// The reviewer typing into the field.
    func type(_ typed: String) {
        write(typed)
        let wasStreaming = draft.streamingDraft != nil
        draft.fieldChanged(to: typed)
        if wasStreaming, draft.streamingDraft == nil {
            task?.cancel()
            task = nil
        }
    }

    /// The sheet closing: the request ends, the field is not touched.
    func close() {
        task?.cancel()
        task = nil
    }

    /// Waits for the last task started to finish, so an assertion is about a settled field.
    func settle() async {
        guard let lastTask else { return }
        await lastTask.value
    }

    /// Waits until the field satisfies `condition`, or gives up and lets the assertion say so.
    ///
    /// A stream is consumed by a task, and a test that wants to stop it *mid-stream* has to know
    /// that the snapshot it yielded has landed. The condition is the following assertion's own
    /// precondition, so waiting on it is not a guess about timing: either the field reaches the
    /// state the test is about, or the assertion after this fails and says which state it is in.
    /// - Parameter condition: What the test is waiting for.
    func wait(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func start(base: String, outcome: @escaping StreamProducer) {
        let started = Task { await self.run(base: base, outcome: outcome) }
        task = started
        lastTask = started
    }

    private func run(base: String, outcome: StreamProducer) async {
        let answered = await outcome()
        guard !Task.isCancelled else { return }
        guard let stream = answered.stream else {
            write(draft.finish(answered.failure ?? .disabled, existingText: text))
            return
        }
        draft.streamStarted(kind: stream.kind, base: base)
        do {
            for try await partial in stream.text {
                write(draft.streamed(partial))
            }
            if Task.isCancelled {
                write(draft.cancelStream())
            } else {
                write(draft.finishStream())
            }
        } catch is CancellationError {
            write(draft.cancelStream())
        } catch {
            write(draft.failStream(AIDraftFailure.describe(error)))
        }
    }

    private func write(_ written: String?) {
        guard let written else { return }
        text = written
        writes.append(written)
    }
}

/// A tier that answers nothing on its own: every test here scripts the stream instead.
///
/// The four non-streaming methods exist because the protocol has them; a streaming test never
/// reaches one, and a test that did would rather see this fixture's failure than a plausible draft.
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
