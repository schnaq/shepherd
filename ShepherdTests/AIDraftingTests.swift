import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// AI-drafted review summaries and inline comments (ADR 0007 amendment).
///
/// Four things are worth testing here and none of them needs a window, a network or a Mac with
/// Apple Intelligence switched on:
///
/// - **Context capping.** What a provider is handed must be bounded by the tier's budget, and
///   bounded the same way every time. The fixtures are deliberately far too long for the
///   on-device tier.
/// - **Prompt encoding.** The instruction that the text is a *suggestion* and the JSON contract
///   have to reach the wire, so they are asserted on the encoded request body of both cloud
///   providers rather than only on the string constants.
/// - **Degradation.** Cloud failure → on-device → a reason the user can read, with the same
///   ``IntelligenceOutcome`` semantics as the existing hint calls.
/// - **The field's own rules.** A draft never silently overwrites what the reviewer wrote, and the
///   "AI draft" caption disappears on their first edit.
final class AIDraftingTests: XCTestCase {
    // MARK: - Fixtures

    private func summary(number: Int = 42, title: String = "Retry the flaky upload") -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: number,
            title: title,
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
    ///
    /// Context lines only, so the left-hand and right-hand line numbers stay equal and an
    /// assertion about "line 100" is an assertion about one obvious row.
    private func longPatch(lines: Int = 200) -> String {
        var text = "@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 1...lines {
            text += " context line \(index) — code long enough for the budget to matter\n"
        }
        text += "+added tail line\n"
        return text
    }

    private func detail(
        path: String = "Sources/Upload.swift",
        patch: String?,
        body: String = "Retries the upload twice before giving up."
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(),
            bodyMarkdown: body,
            files: [
                ChangedFile(
                    path: path,
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: patch
                )
            ]
        )
    }

    private func lines(of excerpt: String) -> [String] {
        excerpt.components(separatedBy: "\n")
    }

    private func markedLines(of excerpt: String) -> [String] {
        lines(of: excerpt).filter { $0.hasPrefix(InlineCommentDraftBuilder.anchorMarker) }
    }

    // MARK: - Inline excerpt: the window around the anchor

    func testTheAnchoredLineIsMarkedAndOnlyItsNeighbourhoodIsSent() {
        let request = InlineCommentDraftBuilder.build(
            detail: detail(patch: longPatch()),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 100, side: .right),
            budget: .cloud
        )

        let marked = markedLines(of: request.excerpt)
        XCTAssertEqual(marked.count, 1, "exactly the commented line carries the marker")
        XCTAssertTrue(marked[0].contains("context line 100"))

        // `contextLines` on either side, and nothing beyond it: the point of the excerpt is that
        // the tier reads the lines the reviewer can see, not the whole file.
        XCTAssertTrue(request.excerpt.contains("context line 76"))
        XCTAssertTrue(request.excerpt.contains("context line 124"))
        XCTAssertFalse(request.excerpt.contains("context line 75"))
        XCTAssertFalse(request.excerpt.contains("context line 125"))
        XCTAssertTrue(request.excerptWasTruncated, "a window into a longer diff says so")
        XCTAssertTrue(request.hasExcerpt)
        XCTAssertEqual(request.path, "Sources/Upload.swift")
        XCTAssertEqual(request.repoFullName, "schnaq/review")
        XCTAssertEqual(request.number, 42)
    }

    func testALeftSideAnchorIsNumberedOnTheBaseSide() {
        var patch = "@@ -10,4 +10,4 @@\n"
        patch += " kept line\n"
        patch += "-removed line\n"
        patch += "+added line\n"
        patch += " trailing line\n"

        // The removed line is line 11 of the base side; the added line is line 11 of the head
        // side. Anchoring left must mark the removal and nothing else.
        let left = InlineCommentDraftBuilder.excerpt(
            patch: patch,
            anchor: InlineCommentAnchor(path: "f.swift", line: 11, side: .left),
            limit: 4_000
        )
        XCTAssertEqual(markedLines(of: left.text).count, 1)
        XCTAssertTrue(markedLines(of: left.text)[0].contains("removed line"))

        let right = InlineCommentDraftBuilder.excerpt(
            patch: patch,
            anchor: InlineCommentAnchor(path: "f.swift", line: 11, side: .right),
            limit: 4_000
        )
        XCTAssertEqual(markedLines(of: right.text).count, 1)
        XCTAssertTrue(markedLines(of: right.text)[0].contains("added line"))
        XCTAssertFalse(right.truncated, "a patch that fits whole is not a window")
    }

    func testAMultiLineSelectionMarksEveryLineItCovers() {
        let result = InlineCommentDraftBuilder.excerpt(
            patch: longPatch(lines: 40),
            anchor: InlineCommentAnchor(path: "f.swift", line: 12, side: .right, startLine: 10),
            limit: 40_000
        )
        XCTAssertEqual(markedLines(of: result.text).count, 3)
        for number in 10...12 {
            XCTAssertTrue(
                markedLines(of: result.text).contains { $0.contains("context line \(number)") }
            )
        }
    }

    // MARK: - Inline excerpt: the character cap

    func testTheExcerptIsCutToTheCharacterLimitAroundTheAnchor() {
        let limit = 300
        let result = InlineCommentDraftBuilder.excerpt(
            patch: longPatch(),
            anchor: InlineCommentAnchor(path: "f.swift", line: 100, side: .right),
            limit: limit
        )
        XCTAssertLessThanOrEqual(result.text.count, limit)
        XCTAssertTrue(result.truncated)
        // The anchored line survives the cut — it is the question being asked.
        XCTAssertTrue(result.text.contains("context line 100"))
    }

    func testEveryTierGetsAnExcerptInsideItsOwnBudget() {
        // A 500-line selection: the anchored block alone is far larger than the on-device tier's
        // whole context, which is exactly the case ADR 0007 says must not become a silent
        // overflow.
        let anchor = InlineCommentAnchor(
            path: "Sources/Upload.swift",
            line: 600,
            side: .right,
            startLine: 100
        )
        let fixture = detail(patch: longPatch(lines: 1_200))

        let onDevice = InlineCommentDraftBuilder.build(
            detail: fixture,
            anchor: anchor,
            budget: .onDevice
        )
        let cloud = InlineCommentDraftBuilder.build(
            detail: fixture,
            anchor: anchor,
            budget: .cloud
        )

        XCTAssertLessThanOrEqual(onDevice.approximateTokenCount, TokenBudget.onDevice.maxTokens)
        XCTAssertLessThanOrEqual(cloud.approximateTokenCount, TokenBudget.cloud.maxTokens)
        XCTAssertLessThan(
            onDevice.excerpt.count,
            cloud.excerpt.count,
            "the small tier must be handed less, not the same prompt and a bigger hope"
        )
        XCTAssertTrue(onDevice.excerptWasTruncated)
    }

    func testAFileWithoutAPatchYieldsNoExcerpt() {
        let request = InlineCommentDraftBuilder.build(
            detail: detail(patch: nil),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 3, side: .right),
            budget: .cloud
        )
        XCTAssertFalse(request.hasExcerpt)
        XCTAssertFalse(request.excerptWasTruncated)
        // The prompt says so out loud rather than presenting a file name as if it were context.
        XCTAssertTrue(
            IntelligencePrompt.body(for: request).contains("No diff excerpt is available")
        )
    }

    // MARK: - Summary request: the digest and the reviewer's own notes

    func testPendingCommentsAreCappedByCountLengthAndBudget() {
        let comments = (1...20).map { index in
            DraftComment(
                path: "Sources/File\(index).swift",
                line: index,
                body: String(repeating: "a", count: 1_000)
            )
        }

        let cloud = ReviewSummaryDraftRequest.notes(from: comments, budget: .cloud)
        let onDevice = ReviewSummaryDraftRequest.notes(from: comments, budget: .onDevice)

        XCTAssertEqual(cloud.count, ReviewSummaryDraftRequest.maximumNotes, "the count cap bites first")
        for note in cloud {
            XCTAssertLessThanOrEqual(
                note.body.count,
                ReviewSummaryDraftRequest.maximumNoteCharacters + 1,
                "each quoted comment is capped, plus the ellipsis"
            )
        }
        // The small tier's share of the budget bites before the count cap does, so it is handed
        // fewer notes from exactly the same draft.
        XCTAssertGreaterThan(onDevice.count, 0)
        XCTAssertLessThan(onDevice.count, cloud.count)
        XCTAssertEqual(cloud.first?.path, "Sources/File1.swift", "oldest first, unshuffled")
    }

    func testEmptyPendingCommentsAreNotQuotedAtAll() {
        let comments = [
            DraftComment(path: "a.swift", line: 1, body: "   \n "),
            DraftComment(path: "b.swift", line: 2, body: "This retry loop never terminates."),
        ]
        let notes = ReviewSummaryDraftRequest.notes(from: comments, budget: .cloud)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].path, "b.swift")
    }

    func testTheSummaryRequestStaysInsideTheSmallTiersBudgetWithNotesOnTop() {
        let fixture = detail(
            patch: longPatch(lines: 1_500),
            body: String(repeating: "Long description. ", count: 4_000)
        )
        let comments = (1...20).map {
            DraftComment(path: "f\($0).swift", line: $0, body: String(repeating: "b", count: 900))
        }

        for budget in [TokenBudget.onDevice, TokenBudget.cloud] {
            let request = ReviewSummaryDraftRequest.build(
                detail: fixture,
                pendingComments: comments,
                budget: budget
            )
            XCTAssertFalse(request.notes.isEmpty, "the reviewer's own findings are quoted")
            // Digest *and* notes together, which is what the tier actually receives — the whole
            // point of reserving room for the notes before building the digest.
            XCTAssertLessThanOrEqual(request.approximateTokenCount, budget.maxTokens)
            XCTAssertGreaterThan(
                request.approximateTokenCount,
                request.digest.approximateTokenCount,
                "the notes are part of the accounting, not free"
            )
        }

        let small = ReviewSummaryDraftRequest.build(
            detail: fixture,
            pendingComments: comments,
            budget: .onDevice
        )
        XCTAssertTrue(small.digest.wasTruncated, "a 1,500-line diff does not fit tier 2")
    }

    // MARK: - Prompts

    func testTheDraftInstructionsSayTheTextIsASuggestionAndForbidInvention() {
        for instructions in [
            IntelligencePrompt.draftSummaryInstructions,
            IntelligencePrompt.draftInlineCommentInstructions,
        ] {
            XCTAssertTrue(instructions.contains("suggestion"))
            XCTAssertTrue(instructions.lowercased().contains("no greeting"))
            XCTAssertTrue(instructions.lowercased().contains("guess"))
        }
        // The summary draft must not pick a verdict — that is the reviewer's click.
        XCTAssertTrue(IntelligencePrompt.draftSummaryInstructions.contains("do not approve"))
        XCTAssertTrue(IntelligencePrompt.draftJSONContract.contains("{\"draft\": string}"))
    }

    func testTheInlineBodyNamesTheFileTheSideAndTheMarker() {
        let request = InlineCommentDraftBuilder.build(
            detail: detail(patch: longPatch()),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 100, side: .right),
            budget: .cloud
        )
        let body = IntelligencePrompt.body(for: request)
        XCTAssertTrue(body.contains("schnaq/review"))
        XCTAssertTrue(body.contains("#42 — Retry the flaky upload"))
        XCTAssertTrue(body.contains("Sources/Upload.swift"))
        XCTAssertTrue(body.contains("head side, line 100"))
        XCTAssertTrue(body.contains(">>"), "the marker is explained, so it can be understood")
        XCTAssertTrue(body.contains("context line 100"))
    }

    func testTheSummaryBodyCarriesTheDigestAndTheReviewersOwnNotes() {
        let fixture = detail(patch: longPatch(lines: 20))
        let digest = PullRequestDigestBuilder.build(from: fixture, budget: .cloud)
        let request = ReviewSummaryDraftRequest(
            digest: digest,
            notes: [
                ReviewSummaryDraftRequest.Note(
                    path: "Sources/Upload.swift",
                    line: 12,
                    body: "This retry loop never terminates."
                )
            ]
        )
        let body = IntelligencePrompt.body(for: request)
        XCTAssertTrue(body.contains("Retry the flaky upload"))
        XCTAssertTrue(body.contains("Sources/Upload.swift:12 — This retry loop never terminates."))
        XCTAssertTrue(body.contains("do not repeat them word for word"))
    }

    // MARK: - Answer parsing

    func testAModelAnswerIsReadFromJSONAFenceOrPlainProse() throws {
        XCTAssertEqual(
            try IntelligenceJSON.draft(from: #"{"draft":"Check the retry bound."}"#),
            "Check the retry bound."
        )
        XCTAssertEqual(
            try IntelligenceJSON.draft(
                from: "```json\n{\"draft\": \"Check the retry bound.\"}\n```"
            ),
            "Check the retry bound."
        )
        XCTAssertEqual(
            try IntelligenceJSON.draft(
                from: "Sure! Here is a draft:\n{\"draft\": \"Check the retry bound.\"}"
            ),
            "Check the retry bound."
        )
        // A model that ignored the contract still wrote something usable.
        XCTAssertEqual(
            try IntelligenceJSON.draft(from: "  Check the retry bound.\n"),
            "Check the retry bound."
        )
    }

    func testAnEmptyAnswerIsAFailureRatherThanAnEmptyField() {
        for answer in ["", "   \n  ", #"{"draft":""}"#, #"{"draft":"   "}"#] {
            XCTAssertThrowsError(try IntelligenceJSON.draft(from: answer)) { error in
                XCTAssertEqual(error as? IntelligenceError, .malformedResponse)
            }
        }
    }

    // MARK: - Wire encoding, both cloud shapes

    func testTheOpenAICompatibleProviderSendsTheDraftPromptAsSystemThenUser() throws {
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.konduit.eu/v1",
            model: "test-model",
            apiKey: ""
        )
        let data = try provider.completionRequestBody(
            system: IntelligencePrompt.draftSummaryInstructions + "\n"
                + IntelligencePrompt.draftJSONContract,
            user: "the body"
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertNotNil(object["max_tokens"] as? Int, "the budget is sent, not left to the server")

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.contains("suggestion"))
        XCTAssertTrue(system.contains("{\"draft\": string}"))
        XCTAssertEqual(messages[1]["content"] as? String, "the body")
    }

    func testTheAnthropicProviderSendsTheDraftPromptInTheSystemField() throws {
        let provider = AnthropicProvider(apiKey: "not-a-real-key", model: "test-model")
        let data = try provider.completionRequestBody(
            system: IntelligencePrompt.draftInlineCommentInstructions + "\n"
                + IntelligencePrompt.draftJSONContract,
            user: "the body"
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let system = try XCTUnwrap(object["system"] as? String)
        XCTAssertTrue(system.contains("suggestion for a human reviewer"))
        XCTAssertTrue(system.contains("{\"draft\": string}"))
        XCTAssertNotNil(object["max_tokens"] as? Int)

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "the system prompt is not a message in this shape")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "the body")
    }

    // MARK: - Router degradation

    func testDraftingIsDisabledWhenIntelligenceIsOff() async {
        let router = IntelligenceRouter(configuration: .disabled, tiers: failingTiers())
        let outcome = await router.draftReviewSummary(for: detail(patch: longPatch(lines: 10)))
        XCTAssertEqual(outcome, .disabled)
        XCTAssertNil(outcome.output)
        XCTAssertNil(outcome.message)
        XCTAssertFalse(router.canDraft)
    }

    func testACloudFailureDegradesToTheOnDeviceTier() async {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in
                    StubProvider(kind: .anthropic, failure: .http(status: 503, message: "overloaded"))
                },
                onDevice: { StubProvider(kind: .onDevice, text: "on-device draft") },
                onDeviceUnavailabilityReason: { nil }
            )
        )
        let outcome = await router.draftReviewSummary(for: detail(patch: longPatch(lines: 10)))
        XCTAssertEqual(outcome.output?.kind, .onDevice)
        XCTAssertEqual(outcome.output?.value, "on-device draft")
    }

    func testBothTiersFailingReportsTheLastReason() async {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in
                    StubProvider(kind: .anthropic, failure: .http(status: 503, message: "overloaded"))
                },
                onDevice: {
                    StubProvider(kind: .onDevice, failure: .digestTooLarge(tokens: 9_000, limit: 6_000))
                },
                onDeviceUnavailabilityReason: { nil }
            )
        )
        let outcome = await router.draftReviewSummary(for: detail(patch: longPatch(lines: 10)))
        XCTAssertNil(outcome.output)
        XCTAssertEqual(
            outcome.message,
            IntelligenceError.digestTooLarge(tokens: 9_000, limit: 6_000).errorDescription
        )
    }

    func testNoTierAtAllIsReportedAsUnavailableWithTheOnDeviceReason() async {
        let reason = "Apple Intelligence is turned off in System Settings."
        let router = IntelligenceRouter(
            configuration: IntelligenceConfiguration(mode: .onDevice),
            tiers: IntelligenceTiers(
                cloud: { _ in nil },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { reason }
            )
        )
        let outcome = await router.draftInlineComment(
            for: detail(patch: longPatch(lines: 10)),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 5, side: .right)
        )
        XCTAssertEqual(outcome, .unavailable(reason))
        XCTAssertFalse(router.canDraft, "the button is not offered when nothing can answer")
    }

    func testACloudTierKeepsDraftingOfferedEvenWithoutAppleIntelligence() {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic) },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { "This Mac does not support Apple Intelligence." }
            )
        )
        XCTAssertTrue(router.canDraft)
    }

    func testAFileWithoutADiffIsRefusedBeforeAnyTierIsAsked() async {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: failingTiers()
        )
        let outcome = await router.draftInlineComment(
            for: detail(patch: nil),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 5, side: .right)
        )
        XCTAssertNil(outcome.output)
        XCTAssertTrue(outcome.message?.contains("no diff") == true, "the reason names the cause")
    }

    // MARK: - The field's own rules

    func testADraftFillsAnEmptyFieldAndIsLabelledUntilTheFirstEdit() {
        var state = AIDraftFieldState()
        XCTAssertFalse(state.isDrafting)
        state.begin()
        XCTAssertTrue(state.isDrafting)

        let written = state.finish(
            .value(IntelligenceOutput(kind: .onDevice, value: "  Check the retry bound.  ")),
            existingText: "   "
        )
        XCTAssertEqual(written, "Check the retry bound.", "trimmed, and written straight in")
        XCTAssertEqual(state.draftedKind, .onDevice)
        XCTAssertNil(state.pendingDraft)

        // The write itself is not an edit, or the label would never be seen.
        state.fieldChanged(to: "Check the retry bound.")
        XCTAssertEqual(state.draftedKind, .onDevice)

        // The reviewer's own keystroke makes it their text.
        state.fieldChanged(to: "Check the retry bound. Also the timeout.")
        XCTAssertNil(state.draftedKind)
        XCTAssertEqual(state.phase, .idle)
    }

    func testADraftNeverOverwritesTypedTextWithoutBeingAsked() {
        var state = AIDraftFieldState()
        state.begin()
        let written = state.finish(
            .value(IntelligenceOutput(kind: .anthropic, value: "Drafted text.")),
            existingText: "My own notes."
        )
        XCTAssertNil(written, "nothing is written while the question is open")
        XCTAssertEqual(state.pendingDraft?.text, "Drafted text.")
        XCTAssertEqual(state.pendingDraft?.kind, .anthropic)
        XCTAssertNil(state.draftedKind)

        var replacing = state
        XCTAssertEqual(replacing.replaceWithPendingDraft(), "Drafted text.")
        XCTAssertEqual(replacing.draftedKind, .anthropic)

        var appending = state
        XCTAssertEqual(
            appending.appendPendingDraft(to: "My own notes."),
            "My own notes.\n\nDrafted text."
        )
        XCTAssertEqual(appending.draftedKind, .anthropic)

        var discarding = state
        discarding.discardPendingDraft()
        XCTAssertEqual(discarding.phase, .idle)
        XCTAssertNil(discarding.pendingDraft)
        XCTAssertNil(discarding.replaceWithPendingDraft(), "nothing left to apply")
    }

    func testAppendingIntoAFieldThatBecameEmptyJustWritesTheDraft() {
        var state = AIDraftFieldState()
        state.begin()
        _ = state.finish(
            .value(IntelligenceOutput(kind: .openAICompatible, value: "Drafted text.")),
            existingText: "typed"
        )
        XCTAssertEqual(state.appendPendingDraft(to: "  "), "Drafted text.")
    }

    func testEveryFailureBecomesOneReadableLineAndLeavesTheFieldAlone() {
        var state = AIDraftFieldState()
        state.begin()
        XCTAssertNil(state.finish(.failed("the endpoint returned 401"), existingText: ""))
        XCTAssertEqual(state.failureMessage, "the endpoint returned 401")

        state.begin()
        XCTAssertNil(state.finish(.unavailable("Apple Intelligence is off"), existingText: ""))
        XCTAssertEqual(state.failureMessage, "Apple Intelligence is off")

        // An answer that is technically a success but carries nothing is a failure here.
        state.begin()
        XCTAssertNil(
            state.finish(
                .value(IntelligenceOutput(kind: .onDevice, value: "   ")),
                existingText: ""
            )
        )
        XCTAssertNotNil(state.failureMessage)

        // Settings switched off mid-request: say nothing at all rather than blame the model.
        state.begin()
        XCTAssertNil(state.finish(.disabled, existingText: ""))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.failureMessage)
    }

    // MARK: - Streaming: the wire (plan §0.2)

    func testBothCloudShapesAskForAStreamOnlyWhenStreaming() throws {
        let openAI = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "test-model",
            apiKey: "not-a-real-key"
        )
        let plain = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try openAI.completionRequestBody(system: "s", user: "u")
            ) as? [String: Any]
        )
        XCTAssertNil(plain["stream"], "the key is absent rather than false when not streaming")
        let streamed = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try openAI.completionRequestBody(system: "s", user: "u", streaming: true)
            ) as? [String: Any]
        )
        XCTAssertEqual(streamed["stream"] as? Bool, true)

        let anthropic = AnthropicProvider(apiKey: "not-a-real-key", model: "test-model")
        let anthropicStreamed = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try anthropic.completionRequestBody(
                    system: "s",
                    user: "u",
                    streaming: true
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(anthropicStreamed["stream"] as? Bool, true)
        XCTAssertNil(
            try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: try anthropic.completionRequestBody(system: "s", user: "u")
                ) as? [String: Any]
            )["stream"]
        )
    }

    func testTheStreamedDraftPromptAsksForTextRatherThanJSON() {
        // A partial JSON object is not text a reviewer can read, so the streamed calls swap the
        // envelope for the same instruction in words.
        XCTAssertTrue(IntelligencePrompt.draftPlainTextContract.contains("no JSON"))
        XCTAssertFalse(IntelligencePrompt.draftPlainTextContract.contains("{"))
    }

    func testTheTwoNewFailuresReadAsSentencesWithoutTouchingAModel() {
        XCTAssertEqual(
            IntelligenceError.guardrailDeclined.errorDescription,
            "Apple Intelligence declined this content."
        )
        XCTAssertNotEqual(IntelligenceError.guardrailDeclined, .contextExceeded)
        let context = IntelligenceError.contextExceeded.errorDescription ?? ""
        XCTAssertTrue(context.contains("context window"))
    }

    // MARK: - Streaming: the ladder

    func testAStreamIsLabelledWithItsTierAndYieldsCumulativeText() async throws {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic) },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                summaryStream: { _, _ in streamScript(["Check", "Check the retry bound."]) }
            )
        )
        let outcome = await router.streamReviewSummaryDraft(
            for: detail(patch: longPatch(lines: 10))
        )
        let stream = try XCTUnwrap(outcome.stream, "a tier answered")
        XCTAssertEqual(stream.kind, .anthropic, "the caption is known before the first token")
        XCTAssertNil(outcome.failure)
        let received = try await collect(stream.text)
        XCTAssertEqual(received, ["Check", "Check the retry bound."])
        XCTAssertEqual(received.last, "Check the retry bound.", "the last element is the draft")
    }

    func testACloudStreamThatFailsBeforeItsFirstTokenDegradesToTheOnDeviceTier() async throws {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic) },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                summaryStream: { provider, _ in
                    provider.kind == .anthropic
                        ? streamScript([], failure: .http(status: 503, message: "overloaded"))
                        : streamScript(["On-device draft."])
                }
            )
        )
        let outcome = await router.streamReviewSummaryDraft(
            for: detail(patch: longPatch(lines: 10))
        )
        let stream = try XCTUnwrap(outcome.stream)
        XCTAssertEqual(stream.kind, .onDevice)
        XCTAssertEqual(try await collect(stream.text), ["On-device draft."])
    }

    func testATierThatStreamsNothingCountsAsAFailureAndTheLadderMovesOn() async throws {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic) },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                summaryStream: { provider, _ in
                    provider.kind == .anthropic
                        ? streamScript([])
                        : streamScript(["On-device draft."])
                }
            )
        )
        let stream = try XCTUnwrap(
            await router.streamReviewSummaryDraft(
                for: detail(patch: longPatch(lines: 10))
            ).stream
        )
        XCTAssertEqual(stream.kind, .onDevice, "an empty answer is not an answer")
    }

    func testAStreamThatFailsAfterItsFirstTokenKeepsItsTierAndItsText() async throws {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic) },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                summaryStream: { _, _ in
                    streamScript(["half a draft"], failure: .malformedResponse)
                }
            )
        )
        let stream = try XCTUnwrap(
            await router.streamReviewSummaryDraft(
                for: detail(patch: longPatch(lines: 10))
            ).stream
        )
        // Committed: once the reviewer is watching text arrive, another tier's attempt at the
        // same draft may not replace it.
        XCTAssertEqual(stream.kind, .anthropic)
        var received: [String] = []
        do {
            for try await text in stream.text { received.append(text) }
            XCTFail("the stream must report the failure it ended with")
        } catch {
            XCTAssertEqual(error as? IntelligenceError, .malformedResponse)
        }
        XCTAssertEqual(received, ["half a draft"])
    }

    func testBothStreamingTiersFailingReportsTheLastReasonThroughTheSameOutcome() async {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic) },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                summaryStream: { provider, _ in
                    provider.kind == .anthropic
                        ? streamScript([], failure: .http(status: 503, message: "overloaded"))
                        : streamScript([], failure: .digestTooLarge(tokens: 9_000, limit: 6_000))
                }
            )
        )
        let outcome = await router.streamReviewSummaryDraft(
            for: detail(patch: longPatch(lines: 10))
        )
        XCTAssertNil(outcome.stream)
        XCTAssertEqual(
            outcome.failure,
            .failed(IntelligenceError.digestTooLarge(tokens: 9_000, limit: 6_000).errorDescription ?? "")
        )
    }

    func testStreamingIsDisabledWhenIntelligenceIsOff() async {
        let router = IntelligenceRouter(configuration: .disabled, tiers: failingTiers())
        let outcome = await router.streamReviewSummaryDraft(
            for: detail(patch: longPatch(lines: 10))
        )
        XCTAssertNil(outcome.stream)
        XCTAssertEqual(outcome.failure, .disabled)
    }

    func testNoStreamingTierAtAllIsReportedAsUnavailableWithTheOnDeviceReason() async {
        let reason = "Apple Intelligence is turned off in System Settings."
        let router = IntelligenceRouter(
            configuration: IntelligenceConfiguration(mode: .onDevice),
            tiers: IntelligenceTiers(
                cloud: { _ in nil },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { reason }
            )
        )
        let outcome = await router.streamInlineCommentDraft(
            for: detail(patch: longPatch(lines: 10)),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 5, side: .right)
        )
        XCTAssertEqual(outcome.failure, .unavailable(reason))
    }

    func testAFileWithoutADiffIsRefusedBeforeAnyStreamIsStarted() async {
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: failingTiers()
        )
        let outcome = await router.streamInlineCommentDraft(
            for: detail(patch: nil),
            anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 5, side: .right)
        )
        XCTAssertNil(outcome.stream)
        XCTAssertTrue(outcome.failure?.message?.contains("no diff") == true)
    }

    func testATierThatCannotStreamStillProducesOneCumulativeElement() async throws {
        // The protocol's default implementation: exactly what the non-streaming call returns,
        // wrapped as a stream, so "prefer streaming" never costs a tier its button.
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in StubProvider(kind: .anthropic, text: "one-shot draft") },
                onDevice: { StubProvider(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil }
            )
        )
        let stream = try XCTUnwrap(
            await router.streamInlineCommentDraft(
                for: detail(patch: longPatch(lines: 10)),
                anchor: InlineCommentAnchor(path: "Sources/Upload.swift", line: 5, side: .right)
            ).stream
        )
        XCTAssertEqual(try await collect(stream.text), ["one-shot draft"])
    }

    // MARK: - The field's own rules, streamed

    func testAStreamAsksBeforeItStartsWhenTheFieldHasTextAndNotOtherwise() {
        var empty = AIDraftFieldState()
        XCTAssertEqual(empty.prepareStream(existingText: "   "), .ready(base: ""))
        XCTAssertEqual(empty.phase, .drafting)

        var typed = AIDraftFieldState()
        XCTAssertEqual(typed.prepareStream(existingText: "My own notes."), .askFirst)
        XCTAssertTrue(typed.isConfirmingStream)
        XCTAssertNil(typed.streamingDraft, "nothing has been requested yet")

        // Discarding here means the request is never made at all — nothing generated, nothing
        // sent to a provider.
        var discarding = typed
        discarding.discardPendingDraft()
        XCTAssertEqual(discarding.phase, .idle)

        var replacing = typed
        XCTAssertEqual(
            replacing.resolve(.replace, existingText: "My own notes."),
            .startStream(base: "")
        )

        var appending = typed
        XCTAssertEqual(
            appending.resolve(.append, existingText: "My own notes."),
            .startStream(base: "My own notes.\n\n")
        )
    }

    func testTheGrowingDraftIsWrittenCumulativelyAndStaysLabelledUntilAKeystroke() {
        var state = AIDraftFieldState()
        _ = state.prepareStream(existingText: "")
        state.streamStarted(kind: .onDevice, base: "")
        XCTAssertTrue(state.isDrafting, "the button stays busy while text arrives")
        XCTAssertEqual(state.labelledKind, .onDevice, "the caption is up before the text is")

        XCTAssertEqual(state.streamed("Check"), "Check")
        XCTAssertNil(state.streamed("Check"), "an unchanged snapshot writes nothing")
        XCTAssertEqual(state.streamed("Check the retry"), "Check the retry")
        // Shepherd's own writes are not edits, or the caption would never be seen.
        state.fieldChanged(to: "Check the retry")
        XCTAssertEqual(state.labelledKind, .onDevice)

        XCTAssertEqual(state.streamed("Check the retry bound.  "), "Check the retry bound.  ")
        XCTAssertEqual(state.finishStream(), "Check the retry bound.", "trimmed once, at the end")
        XCTAssertEqual(state.draftedKind, .onDevice)
        XCTAssertFalse(state.isDrafting)

        state.fieldChanged(to: "Check the retry bound. Also the timeout.")
        XCTAssertNil(state.draftedKind, "their keystroke makes it their text")
        XCTAssertNil(state.labelledKind)
    }

    func testAnAppendedStreamGrowsUnderTheReviewersOwnParagraph() {
        var state = AIDraftFieldState()
        _ = state.prepareStream(existingText: "My own notes.")
        guard case .startStream(let base) = state.resolve(.append, existingText: "My own notes.")
        else { return XCTFail("appending must start the stream") }
        state.streamStarted(kind: .anthropic, base: base)
        XCTAssertEqual(state.streamed("Also"), "My own notes.\n\nAlso")
        XCTAssertEqual(state.finishStream(), "My own notes.\n\nAlso")
        XCTAssertEqual(state.draftedKind, .anthropic)
    }

    func testAKeystrokeDuringAStreamKeepsTheTypedTextAndDropsLaterSnapshots() {
        var state = AIDraftFieldState()
        _ = state.prepareStream(existingText: "")
        state.streamStarted(kind: .onDevice, base: "")
        XCTAssertEqual(state.streamed("Check the"), "Check the")

        // The reviewer types over it: the rule has no exception for an unfinished draft.
        state.fieldChanged(to: "My own sentence.")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.streamed("Check the retry bound."), "the stream lost the field")
        XCTAssertNil(state.finishStream())
        XCTAssertNil(state.labelledKind)
    }

    func testCancellingAStreamKeepsWhatArrivedAndKeepsItLabelled() {
        var state = AIDraftFieldState()
        _ = state.prepareStream(existingText: "")
        state.streamStarted(kind: .openAICompatible, base: "")
        _ = state.streamed("A partial draft that ")
        XCTAssertEqual(state.cancelStream(), "A partial draft that")
        XCTAssertEqual(state.draftedKind, .openAICompatible)

        // A stop before anything arrived leaves no trace: no caption, no error line.
        var nothing = AIDraftFieldState()
        _ = nothing.prepareStream(existingText: "")
        nothing.streamStarted(kind: .onDevice, base: "")
        XCTAssertNil(nothing.cancelStream())
        XCTAssertEqual(nothing.phase, .idle)
        XCTAssertNil(nothing.failureMessage)
    }

    func testStoppingBeforeTheFirstSnapshotLeavesTheFieldExactlyAsItWas() {
        // The stop button exists from the click, not from the first token: an on-device session
        // that is still warming up has to be stoppable, and stopping it is not a failure.
        var waiting = AIDraftFieldState()
        XCTAssertEqual(waiting.prepareStream(existingText: ""), .ready(base: ""))
        waiting.cancelDrafting()
        XCTAssertEqual(waiting.phase, .idle)
        XCTAssertNil(waiting.failureMessage, "the reviewer stopped it themselves")
        XCTAssertNil(waiting.labelledKind)

        // Once text is arriving, ending the stream is ``cancelStream``'s job and this one keeps
        // its hands off — the two are called together, and exactly one of them does anything.
        var streaming = AIDraftFieldState()
        _ = streaming.prepareStream(existingText: "")
        streaming.streamStarted(kind: .onDevice, base: "")
        _ = streaming.streamed("Half a draft")
        streaming.cancelDrafting()
        XCTAssertEqual(streaming.streamingDraft?.partial, "Half a draft")
    }

    func testAFailedStreamKeepsTextIfAnyArrivedAndOtherwiseSaysWhy() {
        var withText = AIDraftFieldState()
        _ = withText.prepareStream(existingText: "")
        withText.streamStarted(kind: .anthropic, base: "")
        _ = withText.streamed("Half a draft")
        XCTAssertEqual(withText.failStream("the endpoint dropped the connection"), "Half a draft")
        XCTAssertEqual(withText.draftedKind, .anthropic, "still labelled, because it is not theirs")
        XCTAssertNil(withText.failureMessage)

        var withNothing = AIDraftFieldState()
        _ = withNothing.prepareStream(existingText: "")
        withNothing.streamStarted(kind: .anthropic, base: "")
        XCTAssertNil(withNothing.failStream("the endpoint returned 401"))
        XCTAssertEqual(withNothing.failureMessage, "the endpoint returned 401")
    }

    func testAStreamThatEndedWithNothingIsAFailureLineRatherThanAnEmptyCaption() {
        var state = AIDraftFieldState()
        _ = state.prepareStream(existingText: "")
        state.streamStarted(kind: .onDevice, base: "")
        XCTAssertNil(state.finishStream())
        XCTAssertNotNil(state.failureMessage)
        XCTAssertNil(state.draftedKind)
    }

    func testResolvingAWaitingValueStillWritesItThroughTheSharedPath() {
        var state = AIDraftFieldState()
        state.begin()
        _ = state.finish(
            .value(IntelligenceOutput(kind: .anthropic, value: "Drafted text.")),
            existingText: "My own notes."
        )
        XCTAssertEqual(
            state.resolve(.append, existingText: "My own notes."),
            .write("My own notes.\n\nDrafted text.")
        )
        XCTAssertEqual(state.draftedKind, .anthropic)
        XCTAssertEqual(state.resolve(.replace, existingText: ""), .nothing, "nothing left to apply")
    }

    // MARK: - Stubs

    private var enabledConfiguration: IntelligenceConfiguration {
        IntelligenceConfiguration(
            mode: .onDeviceAndCloud,
            cloudKind: .anthropic,
            cloudAPIKey: "not-a-real-key"
        )
    }

    /// Tiers where nothing can answer, for the paths that must not reach a provider at all.
    private func failingTiers() -> IntelligenceTiers {
        IntelligenceTiers(
            cloud: { _ in StubProvider(kind: .anthropic, failure: .malformedResponse) },
            onDevice: { StubProvider(kind: .onDevice, failure: .malformedResponse) },
            onDeviceUnavailabilityReason: { nil }
        )
    }

    /// A tier that answers with a fixed draft, or fails with a fixed error.
    private struct StubProvider: IntelligenceProvider {
        let kind: IntelligenceKind
        var text: String = "drafted text"
        var failure: IntelligenceError?

        var isAvailable: Bool { get async { failure == nil } }

        func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
            if let failure { throw failure }
            return PRSummary(overview: text)
        }

        func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
            if let failure { throw failure }
            return []
        }

        func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String {
            if let failure { throw failure }
            return text
        }

        func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
            if let failure { throw failure }
            return text
        }
    }
}

/// A scripted provider stream: these elements, then a clean finish or this failure.
///
/// Cumulative text is the contract, so the scripts below are written the way a provider would
/// yield them — each element the whole draft so far.
/// - Parameters:
///   - chunks: The cumulative drafts to yield, in order.
///   - failure: The error to finish with, or `nil` for a clean end.
/// - Returns: The stream.
private func streamScript(
    _ chunks: [String],
    failure: IntelligenceError? = nil
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        if let failure {
            continuation.finish(throwing: failure)
        } else {
            continuation.finish()
        }
    }
}

extension AIDraftingTests {
    /// Drains a stream into the elements a field would have been written with.
    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var elements: [String] = []
        for try await element in stream { elements.append(element) }
        return elements
    }
}
