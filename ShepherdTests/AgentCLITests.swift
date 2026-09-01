import Foundation
import XCTest

@testable import Shepherd

/// The agent-CLI engine: stream decoding, argv construction, template splitting.
///
/// The fixtures are realistic lines of `claude -p … --output-format stream-json --verbose`
/// output. Decoding must survive every one of them, including the ones Shepherd does not model.
final class AgentCLITests: XCTestCase {
    // MARK: - Fixtures

    private enum Fixture {
        static let systemInit = """
            {"type":"system","subtype":"init","cwd":"/tmp/wt","session_id":"6f2a-0001","tools":["Read","Edit","Bash","Glob","Grep"],"model":"claude-opus-4-6","permissionMode":"acceptEdits","apiKeySource":"none"}
            """

        static let assistantText = """
            {"type":"assistant","message":{"id":"msg_01","role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"Reading the failing test first."}],"stop_reason":null},"session_id":"6f2a-0001"}
            """

        static let assistantToolUse = """
            {"type":"assistant","message":{"id":"msg_02","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Read","input":{"file_path":"Sources/App.swift"}}]},"session_id":"6f2a-0001"}
            """

        static let assistantMixed = """
            {"type":"assistant","message":{"id":"msg_03","role":"assistant","content":[{"type":"text","text":"Patching the off-by-one."},{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"a.swift"}},{"type":"thinking","thinking":"hidden"}]},"session_id":"6f2a-0001"}
            """

        static let resultSuccess = """
            {"type":"result","subtype":"success","is_error":false,"result":"Fixed the off-by-one in PatchReconstructor.","duration_ms":18234,"duration_api_ms":16101,"num_turns":7,"total_cost_usd":0.0421,"session_id":"6f2a-0001","usage":{"input_tokens":18234,"output_tokens":912}}
            """

        static let resultError = """
            {"type":"result","subtype":"error_max_turns","is_error":true,"result":null,"duration_ms":92311,"num_turns":25,"total_cost_usd":0.5133,"session_id":"6f2a-0001"}
            """

        static let unknownType = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"…"}]},"session_id":"6f2a-0001"}
            """

        static let malformed = "Loading plugins… (not JSON)"
    }

    // MARK: - Stream decoding

    func testSystemInitCarriesTheModel() {
        XCTAssertEqual(
            AgentStreamEvent.events(in: Fixture.systemInit),
            [.systemInit(model: "claude-opus-4-6")]
        )
    }

    func testAssistantTextBecomesOneEvent() {
        XCTAssertEqual(
            AgentStreamEvent.events(in: Fixture.assistantText),
            [.assistantText("Reading the failing test first.")]
        )
    }

    func testToolUseCarriesTheToolName() {
        XCTAssertEqual(
            AgentStreamEvent.events(in: Fixture.assistantToolUse),
            [.toolUse(name: "Read")]
        )
    }

    func testOneMessageCanCarrySeveralBlocks() {
        // The unknown `thinking` block is skipped rather than failing the line.
        XCTAssertEqual(
            AgentStreamEvent.events(in: Fixture.assistantMixed),
            [.assistantText("Patching the off-by-one."), .toolUse(name: "Edit")]
        )
    }

    func testSuccessResult() throws {
        let events = AgentStreamEvent.events(in: Fixture.resultSuccess)
        guard case .result(let result) = try XCTUnwrap(events.first) else {
            return XCTFail("expected a result event")
        }
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.resultText, "Fixed the off-by-one in PatchReconstructor.")
        XCTAssertEqual(result.totalCostUSD ?? 0, 0.0421, accuracy: 0.000_001)
        XCTAssertEqual(result.durationMS, 18_234)
        XCTAssertEqual(result.numTurns, 7)
        XCTAssertEqual(result.sessionID, "6f2a-0001")
        XCTAssertEqual(result.subtype, "success")
    }

    func testErrorResultKeepsItsSubtypeAndCost() throws {
        let events = AgentStreamEvent.events(in: Fixture.resultError)
        guard case .result(let result) = try XCTUnwrap(events.first) else {
            return XCTFail("expected a result event")
        }
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.resultText)
        XCTAssertEqual(result.numTurns, 25)
        XCTAssertEqual(result.subtype, "error_max_turns")
    }

    func testAnUnknownEventTypeIsNotFatal() {
        XCTAssertEqual(AgentStreamEvent.events(in: Fixture.unknownType), [.unknown])
    }

    func testAMalformedLineIsSkippedEntirely() {
        XCTAssertTrue(AgentStreamEvent.events(in: Fixture.malformed).isEmpty)
        XCTAssertTrue(AgentStreamEvent.events(in: "").isEmpty)
        XCTAssertTrue(AgentStreamEvent.events(in: "   \n").isEmpty)
    }

    func testAnsiEscapesAreStrippedBeforeDecoding() {
        let coloured = "\u{1B}[32m" + Fixture.assistantText + "\u{1B}[0m"
        XCTAssertEqual(
            AgentStreamEvent.events(in: coloured),
            [.assistantText("Reading the failing test first.")]
        )
    }

    func testDecodingATruncatedResultStillYieldsAResult() throws {
        // Fields Shepherd cannot find are `nil`, not a decode failure.
        let line = #"{"type":"result","subtype":"success"}"#
        guard case .result(let result) = try XCTUnwrap(AgentStreamEvent.events(in: line).first)
        else { return XCTFail("expected a result event") }
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.totalCostUSD)
        XCTAssertNil(result.numTurns)
    }

    // MARK: - argv for the Claude Code kind

    private let worktree = URL(fileURLWithPath: "/tmp/shepherd/wt")
    private let binary = URL(fileURLWithPath: "/opt/homebrew/bin/claude")

    func testClaudeArgvWithTheDefaultGuardrails() throws {
        let invocation = try AgentCLIConfiguration().invocation(
            prompt: "Fix the test",
            worktree: worktree,
            executable: binary
        )
        XCTAssertEqual(invocation.executable, binary)
        XCTAssertEqual(
            invocation.arguments,
            [
                "-p", "Fix the test",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "acceptEdits",
                "--allowedTools", "Read,Edit,Bash(git *),Glob,Grep",
                "--max-turns", "25",
                "--max-budget-usd", "5",
            ]
        )
    }

    func testAnUncappedBudgetOmitsTheFlagEntirely() throws {
        var configuration = AgentCLIConfiguration()
        configuration.maxBudgetUSD = nil
        let invocation = try configuration.invocation(
            prompt: "p",
            worktree: worktree,
            executable: binary
        )
        XCTAssertFalse(invocation.arguments.contains("--max-budget-usd"))
    }

    func testFractionalBudgetsAndCustomToolsArePassedThrough() throws {
        var configuration = AgentCLIConfiguration()
        configuration.maxBudgetUSD = 2.5
        configuration.allowedTools = "Read,Grep"
        configuration.permissionMode = .plan
        configuration.maxTurns = 3
        configuration.extraArguments = ["--add-dir", "/tmp/extra"]
        let invocation = try configuration.invocation(
            prompt: "p",
            worktree: worktree,
            executable: binary
        )
        XCTAssertEqual(
            invocation.arguments,
            [
                "-p", "p",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "plan",
                "--allowedTools", "Read,Grep",
                "--max-turns", "3",
                "--max-budget-usd", "2.50",
                "--add-dir", "/tmp/extra",
            ]
        )
    }

    func testAPromptWithShellMetacharactersStaysOneArgument() throws {
        let nasty = "fix `rm -rf /`; echo \"$(whoami)\" && exit\nsecond line"
        let invocation = try AgentCLIConfiguration().invocation(
            prompt: nasty,
            worktree: worktree,
            executable: binary
        )
        XCTAssertEqual(invocation.arguments[0], "-p")
        XCTAssertEqual(invocation.arguments[1], nasty)
        XCTAssertEqual(invocation.arguments.filter { $0 == nasty }.count, 1)
    }

    func testAMissingExecutableIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(
            try AgentCLIConfiguration().invocation(
                prompt: "p",
                worktree: worktree,
                executable: nil
            )
        ) { error in
            XCTAssertEqual(error as? AgentCLIConfiguration.Failure, .executableNotFound)
        }
    }

    // MARK: - argv for a custom template

    func testCustomTemplateExpansion() throws {
        let configuration = AgentCLIConfiguration(
            kind: .custom(commandTemplate: "/usr/local/bin/agent run --cwd {worktree} --task {prompt} -q")
        )
        let invocation = try configuration.invocation(
            prompt: "do the thing",
            worktree: worktree,
            executable: nil
        )
        XCTAssertEqual(invocation.executable.path, "/usr/local/bin/agent")
        XCTAssertEqual(
            invocation.arguments,
            ["run", "--cwd", "/tmp/shepherd/wt", "--task", "do the thing", "-q"]
        )
    }

    func testAPlaceholderGluedToAFlagStaysOneArgument() throws {
        let configuration = AgentCLIConfiguration(
            kind: .custom(commandTemplate: "agent --task={prompt} --dir={worktree}")
        )
        let invocation = try configuration.invocation(
            prompt: "a b c",
            worktree: worktree,
            executable: nil
        )
        XCTAssertEqual(invocation.arguments, ["--task=a b c", "--dir=/tmp/shepherd/wt"])
    }

    func testATemplateWithoutAPromptPlaceholderIsRefused() {
        let configuration = AgentCLIConfiguration(
            kind: .custom(commandTemplate: "agent run --cwd {worktree}")
        )
        XCTAssertThrowsError(
            try configuration.invocation(prompt: "p", worktree: worktree, executable: nil)
        ) { error in
            XCTAssertEqual(
                error as? AgentCLIConfiguration.Failure,
                .templateMissingPromptPlaceholder
            )
        }
    }

    // MARK: - Shell-words splitting

    func testSplittingOnWhitespace() throws {
        XCTAssertEqual(try ShellWords.split("a b   c"), ["a", "b", "c"])
        XCTAssertEqual(try ShellWords.split("  "), [])
    }

    func testQuotesKeepSpacesTogether() throws {
        XCTAssertEqual(
            try ShellWords.split("agent --msg \"hello world\" 'and more'"),
            ["agent", "--msg", "hello world", "and more"]
        )
    }

    func testEscapesInsideAndOutsideQuotes() throws {
        XCTAssertEqual(try ShellWords.split(#"a\ b"#), ["a b"])
        XCTAssertEqual(try ShellWords.split(#""say \"hi\"""#), [#"say "hi""#])
        // Inside double quotes only " \ $ ` are escapable, so a Windows-ish path survives.
        XCTAssertEqual(try ShellWords.split(#""C:\path\to""#), [#"C:\path\to"#])
        XCTAssertEqual(try ShellWords.split("'it\\'"), ["it\\"])
    }

    func testAnEmptyQuotedArgumentIsStillAnArgument() throws {
        XCTAssertEqual(try ShellWords.split("agent \"\" x"), ["agent", "", "x"])
    }

    func testUnterminatedQuotesAndEscapesAreErrors() {
        XCTAssertThrowsError(try ShellWords.split("agent \"oops"))
        XCTAssertThrowsError(try ShellWords.split("agent 'oops"))
        XCTAssertThrowsError(try ShellWords.split(#"agent \"#))
    }

    // MARK: - Configuration round-tripping

    func testConfigurationSurvivesAJSONRoundTrip() throws {
        var configuration = AgentCLIConfiguration(
            kind: .custom(commandTemplate: "agent {prompt}"),
            executablePath: "/x/y",
            extraArguments: ["--flag"],
            permissionMode: .dontAsk,
            allowedTools: "Read",
            maxTurns: 9,
            maxBudgetUSD: nil
        )
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(AgentCLIConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)

        // A configuration written before a field existed keeps the defaults for it.
        let partial = Data(#"{"maxTurns":4}"#.utf8)
        configuration = try JSONDecoder().decode(AgentCLIConfiguration.self, from: partial)
        XCTAssertEqual(configuration.maxTurns, 4)
        XCTAssertEqual(configuration.permissionMode, .acceptEdits)
        XCTAssertEqual(configuration.allowedTools, AgentCLIConfiguration.defaultAllowedTools)
        XCTAssertEqual(configuration.maxBudgetUSD, AgentCLIConfiguration.defaultMaxBudgetUSD)
    }

    // MARK: - Prompt

    func testThePreambleIsAlwaysInFrontOfTheUsersText() {
        let context = DelegationContext(
            prID: "PR_1",
            repo: .init(owner: "schnaq", name: "review"),
            number: 42,
            title: "Fix the thing",
            headRefName: "agent/fix",
            headRefOid: "0123456789abcdef"
        )
        let prompt = DelegationPrompt.full(for: context, task: "my instructions")
        XCTAssertTrue(prompt.hasPrefix(DelegationPrompt.preamble(for: context)))
        XCTAssertTrue(prompt.contains("my instructions"))
        XCTAssertTrue(prompt.contains("#42"))
        XCTAssertTrue(prompt.contains("schnaq/review"))
        XCTAssertTrue(prompt.contains("agent/fix"))
        XCTAssertTrue(prompt.lowercased().contains("do not push"))
    }
}
