import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The tool loop, in all three providers and in the router (plan §0.3, §3.F).
///
/// What is worth testing here is *control flow*, and none of it needs a network, a key or a Mac
/// with Apple Intelligence switched on:
///
/// - **The reads themselves.** ``LocalToolExecutor`` answers three tools from one snapshot, cuts
///   every answer to the tier's budget, and turns a call the model got wrong into a refusal the
///   model can read rather than into an error that ends the turn.
/// - **Both cloud loop shapes.** `tool_use`/`tool_result` and `tool_calls`/`role: "tool"` are
///   transcript protocols: appending the wrong thing makes the *next* request fail, on the user's
///   machine, with their key. So the recorded answers are driven through the real providers and
///   the requests they produce are asserted.
/// - **The two hard stops.** The hop cap, and an endpoint that cannot call tools at all.
/// - **The ladder.** On-device first, the cloud rung only after a budget failure *and* only with
///   consent — which is the inverse of every other call in ``IntelligenceRouter`` and therefore
///   the thing most likely to be "fixed" by mistake.
final class IntelligenceToolLoopTests: XCTestCase {
    // MARK: - Fixtures

    private static let path = "Sources/Upload.swift"
    private static let binaryPath = "Resources/icon.png"

    private func summary(number: Int = 42) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: number,
            title: "Retry the flaky upload",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 2,
            headRefName: "feature",
            headRefOid: "abc123",
            baseRefName: "main"
        )
    }

    /// A patch of 40 numbered context lines, so a window around one of them is obvious.
    private func patch(lines: Int = 40) -> String {
        var text = "@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 1...lines {
            text += " context line \(index)\n"
        }
        return text
    }

    private func checks() -> [CheckRun] {
        [
            CheckRun(
                id: "1",
                name: "App build (macOS)",
                status: .completed,
                conclusion: .failure,
                summary: "Compilation failed: 1 error"
            ),
            CheckRun(id: "2", name: "ShepherdKit tests (Linux)", status: .completed, conclusion: .success),
            CheckRun(id: "3", name: "Localization", status: .completed, conclusion: .timedOut),
            CheckRun(id: "4", name: "Docs", status: .inProgress),
        ]
    }

    private func detail(checks givenChecks: [CheckRun]? = nil) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(),
            bodyMarkdown: "Retries the upload twice before giving up.",
            files: [
                ChangedFile(
                    path: Self.path,
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: patch()
                ),
                ChangedFile(path: Self.binaryPath, status: .added, patch: nil),
            ],
            checks: givenChecks ?? checks()
        )
    }

    private func executor(budget: TokenBudget = .onDevice) -> LocalToolExecutor {
        LocalToolExecutor(detail: detail(), budget: budget)
    }

    private func request(budget: TokenBudget = .onDevice) -> CIDiagnosisRequest {
        CIDiagnosisRequest.build(detail: detail(), summary: summary(), budget: budget)
    }

    // MARK: - LocalToolExecutor: the reads

    func testFailingChecksListsTheRedOnesAndCountsThemForTheTrace() async throws {
        let result = try await executor().execute(
            IntelligenceToolCall(id: "c1", tool: .failingChecks)
        )

        XCTAssertEqual(result.callID, "c1")
        XCTAssertTrue(result.content.contains("App build (macOS)"))
        XCTAssertTrue(result.content.contains("Compilation failed: 1 error"))
        // A timed-out check is red to a reviewer, so it is red here: the rollup counts it, and a
        // tool that disagreed with the rollup would answer a question nobody asked.
        XCTAssertTrue(result.content.contains("Localization"))
        // Green and still-running checks are not the question.
        XCTAssertFalse(result.content.contains("ShepherdKit tests (Linux)"))
        XCTAssertFalse(result.content.contains("Docs"))
        XCTAssertTrue(result.summaryLine.contains("2"), "two failing checks")
        XCTAssertFalse(result.wasTruncated)
    }

    func testACheckSummaryIsCappedAndFlattenedSoOneTalkativeCheckCannotReshapeThePrompt() async throws {
        let noisy = CheckRun(
            id: "9",
            name: "Noisy",
            status: .completed,
            conclusion: .failure,
            summary: "line one\nline two\n" + String(repeating: "x", count: 4_000)
        )
        let result = try await LocalToolExecutor(
            detail: detail(checks: [noisy]),
            budget: .onDevice
        ).execute(IntelligenceToolCall(id: "c1", tool: .failingChecks))

        XCTAssertFalse(
            result.content.contains("line one\nline two"),
            "a check's own newlines never reach the prompt"
        )
        XCTAssertLessThan(
            result.content.count,
            LocalToolExecutor.maximumCheckSummaryCharacters + 200
        )
    }

    func testAPullRequestWithNothingRedSaysSoRatherThanListingNothing() async throws {
        let green = [
            CheckRun(id: "2", name: "Tests", status: .completed, conclusion: .success),
        ]
        let result = try await LocalToolExecutor(detail: detail(checks: green), budget: .onDevice)
            .execute(IntelligenceToolCall(id: "c1", tool: .failingChecks))

        XCTAssertTrue(result.content.contains("No check"))
        XCTAssertTrue(result.summaryLine.contains("0"))
    }

    func testFileDiffAnswersAWindowAroundTheLineTheModelNamed() async throws {
        let result = try await executor().execute(
            IntelligenceToolCall(
                id: "c2",
                tool: .fileDiff,
                arguments: ["path": .string(Self.path), "line": .integer(20)]
            )
        )

        XCTAssertTrue(result.content.contains(Self.path))
        XCTAssertTrue(result.content.contains("context line 20"))
        XCTAssertFalse(result.summaryLine.isEmpty)
    }

    func testFileDiffSaysSoWhenGitHubSentNoPatchInsteadOfAnsweringNothing() async throws {
        let result = try await executor().execute(
            IntelligenceToolCall(
                id: "c3",
                tool: .fileDiff,
                arguments: ["path": .string(Self.binaryPath)]
            )
        )

        XCTAssertTrue(result.content.contains("no diff"))
        XCTAssertTrue(result.content.contains(Self.binaryPath))
        XCTAssertFalse(result.wasTruncated)
    }

    func testTheDiffWindowStaysInsideTheTierBudgetAndNeverCutsTheNamedLine() async throws {
        let long = ChangedFile(
            path: Self.path,
            status: .modified,
            patch: patch(lines: 4_000)
        )
        func window(_ budget: TokenBudget) async throws -> String {
            try await LocalToolExecutor(
                detail: PullRequestDetail(summary: summary(), files: [long], checks: checks()),
                budget: budget
            ).execute(
                IntelligenceToolCall(
                    id: "c4",
                    tool: .fileDiff,
                    arguments: ["path": .string(Self.path), "line": .integer(2_000)]
                )
            ).content
        }

        let onDevice = try await window(.onDevice)
        let cloud = try await window(.cloud)
        XCTAssertLessThanOrEqual(
            onDevice.count,
            Int(Double(TokenBudget.onDevice.maxCharacters) * LocalToolExecutor.diffShare) + 200
        )
        XCTAssertTrue(onDevice.contains("context line 2000"), "the named line is never cut")
        XCTAssertTrue(cloud.contains("context line 2000"))
    }

    func testJobLogTailAnswersThatThereIsNoLogYetRatherThanFailing() async throws {
        let result = try await executor().execute(
            IntelligenceToolCall(
                id: "c5",
                tool: .jobLogTail,
                arguments: ["checkName": .string("App build (macOS)")]
            )
        )

        XCTAssertTrue(result.content.contains("No log is available"))
        XCTAssertTrue(result.content.contains("summary"), "it says what to do instead")
        XCTAssertFalse(result.wasTruncated)
        XCTAssertFalse(result.summaryLine.isEmpty)
    }

    func testJobLogTailCorrectsACheckNameTheModelInvented() async throws {
        let result = try await executor().execute(
            IntelligenceToolCall(
                id: "c6",
                tool: .jobLogTail,
                arguments: ["checkName": .string("Build (Windows)")]
            )
        )

        XCTAssertTrue(result.content.contains("no failing check"))
        XCTAssertTrue(result.content.contains("failingChecks"), "it names the way out")
    }

    // MARK: - LocalToolExecutor: refusals are results, never errors

    func testAPathThePullRequestDoesNotContainIsRefusedRatherThanRead() async throws {
        let result = try await executor().execute(
            IntelligenceToolCall(
                id: "c7",
                tool: .fileDiff,
                arguments: ["path": .string("/etc/passwd")]
            )
        )

        // The guardrail the plan names: no free text a model wrote reaches a read. It comes back
        // as a *result*, so the model can correct itself inside the hop cap.
        XCTAssertTrue(result.content.contains("not one of the files"))
        XCTAssertTrue(result.content.contains("/etc/passwd"))
        // This one refusal is spelled out for the reviewer too, because seeing it is seeing the
        // guardrail work.
        XCTAssertTrue(result.summaryLine.contains("/etc/passwd"))
    }

    func testAnUnknownToolAMissingArgumentAndAnInventedArgumentAreAllRefusals() async throws {
        let local = executor()

        let unknown = try await local.execute(
            IntelligenceToolCall(id: "c8", toolName: "runTests")
        )
        XCTAssertTrue(unknown.content.contains("no tool called"))
        XCTAssertTrue(unknown.content.contains("failingChecks"))

        let missing = try await local.execute(
            IntelligenceToolCall(id: "c9", tool: .jobLogTail)
        )
        XCTAssertTrue(missing.content.contains("checkName"))

        let invented = try await local.execute(
            IntelligenceToolCall(
                id: "c10",
                tool: .fileDiff,
                arguments: ["path": .string(Self.path), "sha": .string("deadbeef")]
            )
        )
        XCTAssertTrue(invented.content.contains("sha"))

        let wrongType = try await local.execute(
            IntelligenceToolCall(
                id: "c11",
                tool: .fileDiff,
                arguments: ["path": .string(Self.path), "line": .string("twelve")]
            )
        )
        XCTAssertTrue(wrongType.content.contains("integer"))

        // Every one of them answered, and every one of them kept its call id so the provider can
        // pair it with the call the model made.
        XCTAssertEqual(
            [unknown.callID, missing.callID, invented.callID, wrongType.callID],
            ["c8", "c9", "c10", "c11"]
        )
    }

    // MARK: - The request

    func testTheRequestNamesTheRedChecksAndTheOnlyPathsThatMayBeRead() {
        let built = request()

        XCTAssertEqual(built.slug, "schnaq/review#42")
        XCTAssertEqual(built.failingChecks.map(\.name), ["App build (macOS)", "Localization"])
        XCTAssertEqual(built.failingChecks.first?.conclusion, "failure")
        XCTAssertEqual(built.changedFilePaths, [Self.path, Self.binaryPath])
        XCTAssertTrue(built.registry.changedFilePaths.contains(Self.path))
        XCTAssertGreaterThan(built.approximateTokenCount, 0)

        let body = IntelligencePrompt.body(for: built)
        XCTAssertTrue(body.contains("schnaq/review"))
        XCTAssertTrue(body.contains("App build (macOS)"))
        XCTAssertTrue(body.contains(Self.path))
        XCTAssertTrue(body.contains("Only these paths can be read"))
    }

    // MARK: - Anthropic: the tool_use loop

    func testTheAnthropicLoopOffersTheToolsRunsTheCallAndAnswersTheResult() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"""
                    {"stop_reason": "tool_use", "content": [
                      {"type": "text", "text": "Let me look at the checks."},
                      {"type": "tool_use", "id": "call_1", "name": "failingChecks", "input": {}}
                    ]}
                    """#
            ),
            ScriptedTransport.Answer(body: Self.anthropicFinalAnswer),
        ])
        let provider = AnthropicProvider(
            apiKey: "not-a-real-key",
            model: "test-model",
            transport: transport
        )

        let run = try await provider.diagnoseFailingChecks(request(), tools: executor())

        XCTAssertEqual(run.value.hypothesis, "The retry count is off by one.")
        XCTAssertEqual(run.value.confidence, .high)
        XCTAssertEqual(run.value.line, 12)
        XCTAssertEqual(run.hopCount, 1)
        XCTAssertEqual(run.trace.orderedSteps.first?.toolName, .failingChecks)
        XCTAssertEqual(run.trace.orderedSteps.first?.argumentsDisplay, "")

        let requests = await transport.bodies
        XCTAssertEqual(requests.count, 2)
        // The schemas have to reach the wire, in the envelope this API takes.
        XCTAssertTrue(requests[0].contains(#""input_schema""#))
        XCTAssertTrue(requests[0].contains(#""jobLogTail""#))
        // The assistant's own content is echoed verbatim, then the results answer it by id.
        XCTAssertTrue(requests[1].contains(#""Let me look at the checks.""#))
        XCTAssertTrue(requests[1].contains(#""tool_use_id":"call_1""#))
        XCTAssertTrue(requests[1].contains(#""type":"tool_result""#))
        XCTAssertTrue(requests[1].contains("App build (macOS)"), "the tool's answer travels")
    }

    func testAnthropicPassesTheModelsArgumentsThroughToTheToolAndIntoTheTrace() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"""
                    {"stop_reason": "tool_use", "content": [
                      {"type": "tool_use", "id": "call_2", "name": "fileDiff",
                       "input": {"path": "Sources/Upload.swift", "line": 20}}
                    ]}
                    """#
            ),
            ScriptedTransport.Answer(body: Self.anthropicFinalAnswer),
        ])
        let provider = AnthropicProvider(
            apiKey: "k",
            model: "test-model",
            transport: transport
        )

        let run = try await provider.diagnoseFailingChecks(request(), tools: executor())

        XCTAssertEqual(run.trace.orderedSteps.first?.toolName, .fileDiff)
        XCTAssertEqual(
            run.trace.orderedSteps.first?.argumentsDisplay,
            "line: 20, path: Sources/Upload.swift"
        )
        let requests = await transport.bodies
        XCTAssertTrue(requests[1].contains("context line 20"))
    }

    func testAnthropicStopsAtTheHopCapRatherThanLoopingForever() async throws {
        // Seven rounds, each asking for one more read. The seventh is the one too many.
        let answer = ScriptedTransport.Answer(
            body: #"""
                {"stop_reason": "tool_use", "content": [
                  {"type": "tool_use", "id": "call_n", "name": "failingChecks", "input": {}}
                ]}
                """#
        )
        let transport = ScriptedTransport(Array(repeating: answer, count: 7))
        let provider = AnthropicProvider(apiKey: "k", model: "m", transport: transport)

        await assertThrows(.toolLoopExceeded) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
        let requests = await transport.bodies
        XCTAssertEqual(
            requests.count,
            IntelligenceToolLoop.maximumHops + 1,
            "six reads happened, and the request that asked for a seventh is where it stopped"
        )
    }

    func testAnthropicCountsACallItCannotValidateAgainstTheHopCapAllTheSame() async throws {
        // A model that keeps naming a tool nobody declared. Every call is *refused* rather than
        // run, so the typed trace stays empty — and a cap measured against the trace would let
        // this turn go round for as long as the endpoint kept answering.
        let answer = ScriptedTransport.Answer(
            body: #"""
                {"stop_reason": "tool_use", "content": [
                  {"type": "tool_use", "id": "call_n", "name": "runTests", "input": {}}
                ]}
                """#
        )
        let transport = ScriptedTransport(Array(repeating: answer, count: 7))
        let provider = AnthropicProvider(apiKey: "k", model: "m", transport: transport)

        await assertThrows(.toolLoopExceeded) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
        // The script holds exactly seven answers, so a loop that had *not* stopped would have
        // failed on an exhausted transport instead — the count is the assertion.
        let requests = await transport.bodies
        XCTAssertEqual(
            requests.count,
            IntelligenceToolLoop.maximumHops + 1,
            "six refused reads happened, and the request that asked for a seventh is the stop"
        )
    }

    func testAnthropicMapsA400AboutToolsToAnEndpointThatCannotDoThis() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"{"error": {"message": "tools: unsupported parameter"}}"#,
                status: 400
            ),
        ])
        let provider = AnthropicProvider(apiKey: "k", model: "m", transport: transport)

        await assertThrows(.toolsUnsupported) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
    }

    func testAnthropicKeepsEveryOtherFailureAsItself() async throws {
        // A wrong key is a wrong key whatever the request carried, and telling the user their
        // endpoint "cannot call tools" would send them to change the wrong setting.
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"{"error": {"message": "invalid x-api-key"}}"#,
                status: 401
            ),
        ])
        let provider = AnthropicProvider(apiKey: "k", model: "m", transport: transport)

        await assertThrows(.http(status: 401, message: "invalid x-api-key")) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
        XCTAssertEqual(
            AnthropicProvider.toolFailure(status: 400, message: "rate limited"),
            .http(status: 400, message: "rate limited")
        )
        XCTAssertEqual(
            AnthropicProvider.toolFailure(status: 400, message: "function calling is not supported"),
            .toolsUnsupported
        )
    }

    func testAnthropicRefusesAnAnswerThatCarriesNoDiagnosis() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "I had a look."}]}"#
            ),
        ])
        let provider = AnthropicProvider(apiKey: "k", model: "m", transport: transport)

        await assertThrows(.malformedResponse) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
    }

    // MARK: - OpenAI-compatible: the tool_calls loop

    func testTheOpenAILoopAppendsTheAssistantCallAndOneToolMessagePerCall() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"""
                    {"choices": [{"finish_reason": "tool_calls", "message": {
                      "role": "assistant", "content": null, "tool_calls": [
                        {"id": "call_a", "type": "function", "function": {
                          "name": "fileDiff",
                          "arguments": "{\"path\": \"Sources/Upload.swift\", \"line\": 20}"}}
                      ]}}]}
                    """#
            ),
            ScriptedTransport.Answer(body: Self.openAIFinalAnswer),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "test-model",
            apiKey: "k",
            transport: transport
        )

        let run = try await provider.diagnoseFailingChecks(request(), tools: executor())

        XCTAssertEqual(run.value.hypothesis, "The retry count is off by one.")
        XCTAssertEqual(run.hopCount, 1)
        XCTAssertEqual(
            run.trace.orderedSteps.first?.argumentsDisplay,
            "line: 20, path: Sources/Upload.swift"
        )

        let requests = await transport.bodies
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].contains(#""type":"function""#))
        XCTAssertTrue(requests[0].contains(#""fileDiff""#))
        XCTAssertTrue(requests[1].contains(#""tool_calls""#), "the assistant message is echoed")
        XCTAssertTrue(requests[1].contains(#""tool_call_id":"call_a""#))
        XCTAssertTrue(requests[1].contains(#""role":"tool""#))
        XCTAssertTrue(requests[1].contains("context line 20"))
    }

    func testAnArgumentsStringThatDoesNotParseBecomesARefusalRatherThanAFailedTurn() async throws {
        XCTAssertTrue(OpenAICompatibleProvider.arguments(in: "not json at all").isEmpty)
        XCTAssertTrue(OpenAICompatibleProvider.arguments(in: "").isEmpty)
        XCTAssertEqual(
            OpenAICompatibleProvider.arguments(in: #"{"path": "a", "line": 3}"#),
            ["path": .string("a"), "line": .integer(3)]
        )

        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"""
                    {"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
                      {"id": "call_b", "type": "function",
                       "function": {"name": "fileDiff", "arguments": "{oops"}}
                    ]}}]}
                    """#
            ),
            ScriptedTransport.Answer(body: Self.openAIFinalAnswer),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "",
            transport: transport
        )

        let run = try await provider.diagnoseFailingChecks(request(), tools: executor())
        XCTAssertEqual(run.hopCount, 1, "the hop happened, and it was a refusal")
        let requests = await transport.bodies
        XCTAssertTrue(requests[1].contains("needs the argument"))
    }

    func testTheOpenAILoopStopsAtTheHopCap() async throws {
        let answer = ScriptedTransport.Answer(
            body: #"""
                {"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
                  {"id": "call_n", "type": "function",
                   "function": {"name": "failingChecks", "arguments": "{}"}}
                ]}}]}
                """#
        )
        let transport = ScriptedTransport(Array(repeating: answer, count: 7))
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "",
            transport: transport
        )

        await assertThrows(.toolLoopExceeded) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
    }

    func testTheOpenAILoopCountsACallItCannotValidateAgainstTheHopCapAllTheSame() async throws {
        // The same non-converging model in the other wire shape: an invented tool name, refused
        // every time, recorded never, and stopped by the cap regardless.
        let answer = ScriptedTransport.Answer(
            body: #"""
                {"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
                  {"id": "call_n", "type": "function",
                   "function": {"name": "runTests", "arguments": "{}"}}
                ]}}]}
                """#
        )
        let transport = ScriptedTransport(Array(repeating: answer, count: 7))
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "",
            transport: transport
        )

        await assertThrows(.toolLoopExceeded) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
        let requests = await transport.bodies
        XCTAssertEqual(requests.count, IntelligenceToolLoop.maximumHops + 1)
    }

    func testAnEndpointThatRejectsToolsIsReportedAsSuchRatherThanAsA400() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.Answer(
                body: #"{"error": {"message": "this model does not support tools"}}"#,
                status: 400
            ),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "http://localhost:11434/v1",
            model: "a-local-model",
            apiKey: "",
            transport: transport
        )

        await assertThrows(.toolsUnsupported) {
            _ = try await provider.diagnoseFailingChecks(self.request(), tools: self.executor())
        }
        XCTAssertEqual(
            OpenAICompatibleProvider.toolFailure(status: 404, message: "no such model"),
            .http(status: 404, message: "no such model")
        )
    }

    // MARK: - A tier that does not implement tools at all

    func testATierWithoutToolSupportSaysSoInsteadOfAnsweringWithoutHavingRead() async throws {
        // The default implementation on `IntelligenceProvider`. The failure mode it prevents is
        // the quiet one: an unread guess looks exactly like a read one on the card.
        await assertThrows(.toolsUnsupported) {
            _ = try await StubDiagnosisProvider(kind: .openAICompatible)
                .diagnoseFailingChecks(self.request(), tools: self.executor())
        }
    }

    // MARK: - The on-device hop cap

    func testTheRecorderReservesAHopAtomicallySoTwoCallsCannotBothPassTheSameCheck() async {
        // Two tools for one turn is something the framework may do, and it is the case a
        // read-then-write cap cannot survive: both calls read the same count, both pass.
        let recorder = ToolTraceRecorder()
        async let first = recorder.reserveHop()
        async let second = recorder.reserveHop()
        let firstGranted = await first
        let secondGranted = await second
        XCTAssertTrue(firstGranted, "the cap has room for both of these")
        XCTAssertTrue(secondGranted)

        // Twice the cap, all at once: exactly the cap is granted, whatever the interleaving.
        let crowded = ToolTraceRecorder()
        let granted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<(IntelligenceToolLoop.maximumHops * 2) {
                group.addTask { await crowded.reserveHop() }
            }
            var count = 0
            for await didReserve in group {
                if didReserve { count += 1 }
            }
            return count
        }
        XCTAssertEqual(granted, IntelligenceToolLoop.maximumHops)
    }

    func testTheOnDeviceBridgeStopsTheTurnOnceTheCapIsSpent() async {
        let recorder = ToolTraceRecorder()
        let local = executor()

        for hop in 1...IntelligenceToolLoop.maximumHops {
            let content = try? await OnDeviceToolBridge.run(
                IntelligenceToolCall(id: "hop-\(hop)", tool: .failingChecks),
                tool: .failingChecks,
                executor: local,
                recorder: recorder
            )
            XCTAssertNotNil(content, "hop \(hop) is inside the cap")
        }

        await assertThrows(.toolLoopExceeded) {
            _ = try await OnDeviceToolBridge.run(
                IntelligenceToolCall(id: "one-too-many", tool: .failingChecks),
                tool: .failingChecks,
                executor: local,
                recorder: recorder
            )
        }
        let count = await recorder.count
        XCTAssertEqual(count, IntelligenceToolLoop.maximumHops)
    }

    func testConcurrentOnDeviceToolCallsCannotRecordMoreHopsThanTheCapAllows() async {
        let recorder = ToolTraceRecorder()
        let local = executor()

        // The cap plus two, started together. Whichever ones win, the trace the reviewer is
        // shown may not hold more hops than the cap says one diagnosis is allowed.
        await withTaskGroup(of: Void.self) { group in
            for hop in 0..<(IntelligenceToolLoop.maximumHops + 2) {
                group.addTask {
                    _ = try? await OnDeviceToolBridge.run(
                        IntelligenceToolCall(id: "hop-\(hop)", tool: .failingChecks),
                        tool: .failingChecks,
                        executor: local,
                        recorder: recorder
                    )
                }
            }
        }

        let count = await recorder.count
        XCTAssertEqual(count, IntelligenceToolLoop.maximumHops)
    }

    // MARK: - The router's ladder

    func testTheLadderAsksTheOnDeviceTierFirstAndKeepsItsTrace() async throws {
        let log = DiagnoseLog()
        let router = IntelligenceRouter(
            configuration: .init(mode: .onDeviceAndCloud),
            tiers: tiers(log: log, cloud: StubDiagnosisProvider(kind: .anthropic))
        )

        let outcome = await router.diagnoseFailingChecks(for: detail(), summary: summary())

        XCTAssertEqual(outcome.output?.kind, .onDevice)
        XCTAssertEqual(outcome.output?.value.value.hypothesis, "scripted")
        XCTAssertEqual(outcome.output?.value.hopCount, 1)
        let asked = await log.kinds
        XCTAssertEqual(asked, [.onDevice], "the cloud tier was never asked")
    }

    func testABudgetFailureWithoutConsentStaysAFailureRatherThanReachingForTheCloud() async throws {
        let log = DiagnoseLog()
        let router = IntelligenceRouter(
            configuration: .init(mode: .onDeviceAndCloud),
            tiers: tiers(
                log: log,
                cloud: StubDiagnosisProvider(kind: .anthropic),
                failures: [.onDevice: .contextExceeded]
            )
        )

        // `preferCloud` defaults to `false`, which is the whole point: no caller can send a pull
        // request's contents to a configured endpoint by leaving an argument out.
        let outcome = await router.diagnoseFailingChecks(for: detail(), summary: summary())

        let asked = await log.kinds
        XCTAssertNil(outcome.output)
        XCTAssertEqual(asked, [.onDevice])
        XCTAssertNotNil(outcome.message)
    }

    func testABudgetFailureWithConsentStepsUpToTheCloudTier() async throws {
        let log = DiagnoseLog()
        let router = IntelligenceRouter(
            configuration: .init(mode: .onDeviceAndCloud),
            tiers: tiers(
                log: log,
                cloud: StubDiagnosisProvider(kind: .anthropic),
                failures: [.onDevice: .digestTooLarge(tokens: 9_000, limit: 6_000)]
            )
        )

        let outcome = await router.diagnoseFailingChecks(
            for: detail(),
            summary: summary(),
            preferCloud: true
        )

        let asked = await log.kinds
        XCTAssertEqual(outcome.output?.kind, .anthropic)
        XCTAssertEqual(asked, [.onDevice, .anthropic])
    }

    func testEveryOtherOnDeviceFailureIsReportedRatherThanRetriedInTheCloud() async throws {
        // A guardrail refusal is not a size problem, and a cloud provider is not a retry.
        let log = DiagnoseLog()
        let router = IntelligenceRouter(
            configuration: .init(mode: .onDeviceAndCloud),
            tiers: tiers(
                log: log,
                cloud: StubDiagnosisProvider(kind: .anthropic),
                failures: [.onDevice: .guardrailDeclined]
            )
        )

        let outcome = await router.diagnoseFailingChecks(
            for: detail(),
            summary: summary(),
            preferCloud: true
        )

        let asked = await log.kinds
        XCTAssertNil(outcome.output)
        XCTAssertEqual(asked, [.onDevice])
        XCTAssertEqual(
            outcome.message,
            IntelligenceError.guardrailDeclined.errorDescription
        )
    }

    func testAnUnavailableOnDeviceModelIsNotAReasonToUseTheCloudOne() async throws {
        let log = DiagnoseLog()
        var stubTiers = tiers(log: log, cloud: StubDiagnosisProvider(kind: .anthropic))
        stubTiers.onDeviceUnavailabilityReason = { "Apple Intelligence is turned off." }
        let router = IntelligenceRouter(
            configuration: .init(mode: .onDeviceAndCloud),
            tiers: stubTiers
        )

        let outcome = await router.diagnoseFailingChecks(
            for: detail(),
            summary: summary(),
            preferCloud: true
        )

        let asked = await log.kinds
        XCTAssertEqual(outcome.message, "Apple Intelligence is turned off.")
        XCTAssertTrue(asked.isEmpty)
    }

    func testAPullRequestWithNothingRedIsAnsweredWithoutAskingAnyTier() async throws {
        let log = DiagnoseLog()
        let router = IntelligenceRouter(
            configuration: .init(mode: .onDevice),
            tiers: tiers(log: log, cloud: nil)
        )
        let green = [CheckRun(id: "1", name: "Tests", status: .completed, conclusion: .success)]

        let outcome = await router.diagnoseFailingChecks(
            for: detail(checks: green),
            summary: summary()
        )

        let asked = await log.kinds
        XCTAssertNil(outcome.output)
        XCTAssertNotNil(outcome.message)
        XCTAssertTrue(asked.isEmpty)
    }

    func testIntelligenceOffMeansNoCardAtAll() async throws {
        let router = IntelligenceRouter(configuration: .disabled, tiers: tiers(log: DiagnoseLog()))
        let outcome = await router.diagnoseFailingChecks(for: detail(), summary: summary())

        guard case .disabled = outcome else {
            XCTFail("expected .disabled, got \(outcome)")
            return
        }
    }

    func testOnlyTheTwoBudgetFailuresCountAsBudgetFailures() {
        XCTAssertTrue(IntelligenceRouter.isBudgetFailure(IntelligenceError.contextExceeded))
        XCTAssertTrue(
            IntelligenceRouter.isBudgetFailure(
                IntelligenceError.digestTooLarge(tokens: 9_000, limit: 6_000)
            )
        )
        XCTAssertFalse(IntelligenceRouter.isBudgetFailure(IntelligenceError.guardrailDeclined))
        XCTAssertFalse(IntelligenceRouter.isBudgetFailure(IntelligenceError.toolsUnsupported))
        XCTAssertFalse(IntelligenceRouter.isBudgetFailure(IntelligenceError.malformedResponse))
        XCTAssertFalse(IntelligenceRouter.isBudgetFailure(URLError(.notConnectedToInternet)))
    }

    // MARK: - Parsing the final answer

    func testTheDiagnosisIsParsedOutOfWhateverProseTheModelWrappedItIn() throws {
        let diagnosis = try IntelligenceJSON.diagnosis(
            from: """
                Here is what I found:
                {"failingTest": "", "file": "  ", "line": "88",
                 "hypothesis": "The catalog row is missing."}
                """
        )

        XCTAssertNil(diagnosis.failingTest, "an empty field means unknown, not empty")
        XCTAssertNil(diagnosis.file)
        XCTAssertEqual(diagnosis.line, 88, "a quoted number is still a number")
        XCTAssertEqual(diagnosis.confidence, .low, "an absent confidence has not earned more")
    }

    func testAnAnswerWithNoHypothesisIsNoDiagnosis() {
        for text in ["", "I could not work it out.", #"{"confidence": "high"}"#] {
            XCTAssertThrowsError(try IntelligenceJSON.diagnosis(from: text), text)
        }
    }

    // MARK: - Helpers

    private static let anthropicFinalAnswer = #"""
        {"stop_reason": "end_turn", "content": [{"type": "text", "text":
          "{\"failingTest\": \"testRetries\", \"file\": \"Sources/Upload.swift\", \"line\": 12, \"hypothesis\": \"The retry count is off by one.\", \"confidence\": \"high\"}"}]}
        """#

    private static let openAIFinalAnswer = #"""
        {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content":
          "{\"failingTest\": \"testRetries\", \"file\": \"Sources/Upload.swift\", \"line\": 12, \"hypothesis\": \"The retry count is off by one.\", \"confidence\": \"high\"}"}}]}
        """#

    /// Tiers whose diagnosis is scripted per tier.
    /// - Parameters:
    ///   - log: Records which tiers were asked, in order.
    ///   - cloud: The cloud tier, or `nil` for a configuration without one.
    ///   - failures: What each tier throws instead of answering.
    /// - Returns: The tiers.
    private func tiers(
        log: DiagnoseLog,
        cloud: StubDiagnosisProvider? = nil,
        failures: [IntelligenceKind: IntelligenceError] = [:]
    ) -> IntelligenceTiers {
        IntelligenceTiers(
            cloud: { _ in cloud },
            onDevice: { StubDiagnosisProvider(kind: .onDevice) },
            onDeviceUnavailabilityReason: { nil },
            diagnose: { provider, _, _ in
                await log.record(provider.kind)
                if let failure = failures[provider.kind] { throw failure }
                var trace = IntelligenceTrace()
                trace.append(tool: .failingChecks, summaryLine: "1 check failing", duration: 0)
                return IntelligenceToolRun(
                    value: CIDiagnosis(hypothesis: "scripted", confidence: .medium),
                    trace: trace
                )
            }
        )
    }

    /// Asserts that an operation throws one specific ``IntelligenceError``.
    private func assertThrows(
        _ expected: IntelligenceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? IntelligenceError, expected, file: file, line: line)
        }
    }
}

// MARK: - Doubles

/// A transport that answers from a script instead of from a network.
///
/// An `actor` because the provider under test calls it from its own task and the recorded request
/// bodies are read back from the test's: the whole point is to assert what the *second* request
/// contained, which means the recording has to be safe to share.
private actor ScriptedTransport: IntelligenceTransport {
    /// One recorded answer.
    struct Answer: Sendable {
        /// The response body.
        var body: String
        /// The HTTP status. Defaults to `200`.
        var status: Int = 200
    }

    /// Asked for one more answer than the script has.
    struct Exhausted: Error {}

    private var answers: [Answer]
    /// Every request body sent, as text, oldest first.
    private(set) var bodies: [String] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (data: Data, status: Int) {
        bodies.append(String(decoding: body, as: UTF8.self))
        guard !answers.isEmpty else { throw Exhausted() }
        let answer = answers.removeFirst()
        return (Data(answer.body.utf8), answer.status)
    }
}

/// Which tiers a router asked, in order.
private actor DiagnoseLog {
    private(set) var kinds: [IntelligenceKind] = []

    func record(_ kind: IntelligenceKind) {
        kinds.append(kind)
    }
}

/// A provider that answers nothing, so the *default* tool-calling implementation is what runs.
private struct StubDiagnosisProvider: IntelligenceProvider {
    let kind: IntelligenceKind

    var isAvailable: Bool { get async { true } }

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        PRSummary(overview: "stub")
    }

    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
        []
    }

    func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String {
        "stub"
    }

    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
        "stub"
    }
}
