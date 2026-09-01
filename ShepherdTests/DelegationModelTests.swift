import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// A scripted agent run: yields a fixed list of events, then exits with a fixed code.
final class ScriptedAgentRunner: AgentRunning, @unchecked Sendable {
    /// The events to replay, in order.
    var events: [AgentStreamEvent]
    /// The exit code to report.
    var exitCode: Int32
    /// When set, ``run(prompt:in:)`` throws instead of starting.
    var spawnError: (any Error)?

    private let lock = NSLock()
    private var recordedPrompts: [String] = []
    private var recordedDirectories: [URL] = []

    /// Creates a scripted runner.
    init(
        events: [AgentStreamEvent] = [],
        exitCode: Int32 = 0,
        spawnError: (any Error)? = nil
    ) {
        self.events = events
        self.exitCode = exitCode
        self.spawnError = spawnError
    }

    /// The prompts the model asked for.
    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPrompts
    }

    /// The worktrees the model asked to run in.
    var directories: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDirectories
    }

    func run(prompt: String, in worktree: URL) throws -> AgentSession {
        if let spawnError { throw spawnError }
        lock.lock()
        recordedPrompts.append(prompt)
        recordedDirectories.append(worktree)
        lock.unlock()

        let (stream, continuation) = AsyncStream<AgentStreamEvent>.makeStream()
        for event in events { continuation.yield(event) }
        continuation.finish()
        let code = exitCode
        return AgentSession(
            events: stream,
            cancel: {},
            exitCode: { code },
            invocation: AgentInvocation(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: []
            )
        )
    }
}

/// A run that never ends on its own — it only finishes when it is cancelled.
final class HangingAgentRunner: AgentRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AgentStreamEvent>.Continuation?
    private var cancelled = false

    /// Whether the model asked for the run to stop.
    var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(prompt: String, in worktree: URL) throws -> AgentSession {
        let (stream, continuation) = AsyncStream<AgentStreamEvent>.makeStream()
        // One event so the model reaches `.running` before the test cancels it.
        continuation.yield(.systemInit(model: "test-model"))
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        return AgentSession(
            events: stream,
            cancel: { [weak self] in self?.stop() },
            exitCode: { 143 },
            invocation: AgentInvocation(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: []
            )
        )
    }

    private func stop() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

/// The delegation state machine, with the CLI and git both replaced by fakes.
@MainActor
final class DelegationModelTests: XCTestCase {
    private var root: URL!
    private var context: DelegationContext!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shepherd-delegation-tests-\(UUID().uuidString)", isDirectory: true)
        context = DelegationContext(
            prID: "PR_kwDO",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Fix the off-by-one",
            headRefName: "agent/fix",
            headRefOid: "0123456789abcdef",
            focusReasons: ["Sources/App.swift — security-sensitive path"]
        )
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    private func makeModel(
        runner: any AgentRunning,
        git: RecordingProcessRunner = RecordingProcessRunner(),
        worktree: Bool = true,
        readiness: DelegationModel.Readiness = .ready,
        onDidPush: (@MainActor () async -> Void)? = nil
    ) -> DelegationModel {
        let tree = worktree
            ? GitWorktree(
                checkout: URL(fileURLWithPath: "/Users/dev/code/review"),
                directory: GitWorktree.directory(repo: context.repo, number: context.number, root: root),
                managedRoot: root,
                git: URL(fileURLWithPath: "/usr/bin/git"),
                runner: git
            )
            : nil
        return DelegationModel(
            context: context,
            configuration: AgentCLIConfiguration(),
            readiness: readiness,
            runner: runner,
            worktree: tree,
            toasts: nil,
            onDidPush: onDidPush
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for the expected state", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func gitRunnerWithDiffStat() -> RecordingProcessRunner {
        RecordingProcessRunner { invocation in
            switch invocation.arguments.first {
            case "diff":
                return ProcessResult(
                    status: 0,
                    standardOutput: " Sources/App.swift | 4 ++--\n 1 file changed\n",
                    standardError: ""
                )
            case "status":
                return ProcessResult(
                    status: 0,
                    standardOutput: " M Sources/App.swift\n",
                    standardError: ""
                )
            default:
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            }
        }
    }

    // MARK: - Success

    func testASuccessfulRunEndsFinishedWithTheDiffStat() async throws {
        let git = gitRunnerWithDiffStat()
        let runner = ScriptedAgentRunner(
            events: [
                .systemInit(model: "claude-opus-4-6"),
                .assistantText("Looking at the failing test."),
                .toolUse(name: "Read"),
                .assistantText("Patched it."),
                .result(
                    AgentRunResult(
                        isError: false,
                        resultText: "Fixed the off-by-one.",
                        totalCostUSD: 0.0421,
                        durationMS: 18_234,
                        numTurns: 7,
                        sessionID: "6f2a",
                        subtype: "success"
                    )
                ),
            ]
        )
        let model = makeModel(runner: runner, git: git)
        XCTAssertEqual(model.state, .idle)

        model.start()
        await model.runTask?.value

        guard case .finished(let result, let diffStat) = model.state else {
            return XCTFail("expected a finished state, got \(model.state)")
        }
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.numTurns, 7)
        XCTAssertEqual(result.resultText, "Fixed the off-by-one.")
        XCTAssertTrue(diffStat.contains("1 file changed"))
        XCTAssertTrue(model.hasChanges)

        // The worktree was prepared before the agent ran, and inspected afterwards.
        XCTAssertEqual(
            git.arguments,
            [
                ["fetch", "origin", "agent/fix"],
                ["worktree", "add", "--detach", model.worktree?.directory.path ?? "", "0123456789abcdef"],
                ["diff", "--stat", "HEAD"],
                ["status", "--porcelain"],
            ]
        )

        // The agent ran inside the worktree, with Shepherd's preamble in front of the task.
        XCTAssertEqual(runner.directories.first, model.worktree?.directory)
        let prompt = try XCTUnwrap(runner.prompts.first)
        XCTAssertTrue(prompt.hasPrefix(DelegationPrompt.preamble(for: context)))
        XCTAssertTrue(prompt.contains("security-sensitive path"))

        // Assistant text and tool uses both reach the transcript.
        XCTAssertTrue(model.transcript.contains { $0.text == "Looking at the failing test." })
        XCTAssertTrue(model.transcript.contains { $0.kind == .tool && $0.text == "Read" })
    }

    func testStartingASecondRunWhileOneIsRunningDoesNothing() async throws {
        let runner = HangingAgentRunner()
        let model = makeModel(runner: runner)
        model.start()
        await waitUntil { model.state == .running }

        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canStart)
        let transcriptCount = model.transcript.count
        model.start()
        XCTAssertEqual(model.transcript.count, transcriptCount, "the second start was ignored")

        model.cancel()
        await model.runTask?.value
    }

    // MARK: - Failure

    func testAnErrorResultStillFinishesButIsMarkedAsAnError() async throws {
        let runner = ScriptedAgentRunner(
            events: [
                .result(
                    AgentRunResult(
                        isError: true,
                        resultText: nil,
                        totalCostUSD: 0.51,
                        numTurns: 25,
                        subtype: "error_max_turns"
                    )
                )
            ],
            exitCode: 1
        )
        let model = makeModel(runner: runner, git: gitRunnerWithDiffStat())
        model.start()
        await model.runTask?.value

        guard case .finished(let result, _) = model.state else {
            return XCTFail("expected a finished state, got \(model.state)")
        }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.subtype, "error_max_turns")
    }

    func testARunWithoutAResultEventFallsBackToTheExitCode() async throws {
        let model = makeModel(
            runner: ScriptedAgentRunner(events: [.assistantText("done")], exitCode: 2)
        )
        model.start()
        await model.runTask?.value

        guard case .finished(let result, _) = model.state else {
            return XCTFail("expected a finished state, got \(model.state)")
        }
        XCTAssertTrue(result.isError, "a non-zero exit is an error even without a result event")
    }

    func testAFailingWorktreeStopsTheDelegationBeforeTheAgentRuns() async throws {
        let git = RecordingProcessRunner { _ in
            ProcessResult(status: 128, standardOutput: "", standardError: "fatal: no remote")
        }
        let runner = ScriptedAgentRunner()
        let model = makeModel(runner: runner, git: git)
        model.start()
        await model.runTask?.value

        guard case .failed(let message) = model.state else {
            return XCTFail("expected a failed state, got \(model.state)")
        }
        XCTAssertTrue(message.contains("no remote"))
        XCTAssertTrue(runner.prompts.isEmpty, "the agent must not run without a worktree")
    }

    func testACLIThatCannotBeSpawnedFails() async throws {
        let model = makeModel(
            runner: ScriptedAgentRunner(
                spawnError: AgentCLIConfiguration.Failure.executableNotFound
            )
        )
        model.start()
        await model.runTask?.value

        guard case .failed = model.state else {
            return XCTFail("expected a failed state, got \(model.state)")
        }
    }

    func testANotReadyDelegationRefusesToStart() async throws {
        let runner = ScriptedAgentRunner()
        let model = makeModel(
            runner: runner,
            worktree: false,
            readiness: .missingCheckout(repo: "schnaq/review")
        )
        XCTAssertFalse(model.canStart)
        model.start()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(runner.prompts.isEmpty)
    }

    // MARK: - Cancel

    func testCancellingARunningDelegationEndsCancelled() async throws {
        let runner = HangingAgentRunner()
        let model = makeModel(runner: runner)
        model.start()
        await waitUntil { model.state == .running }

        model.cancel()
        await model.runTask?.value

        XCTAssertTrue(runner.didCancel)
        XCTAssertEqual(model.state, .cancelled)
    }

    // MARK: - Publishing

    func testCommitAndPushRunsTheExpectedGitCommandsAndRefreshes() async throws {
        let git = gitRunnerWithDiffStat()
        let refreshed = expectation(description: "the pull request is re-synced after a push")
        let model = makeModel(
            runner: ScriptedAgentRunner(
                events: [.result(AgentRunResult(isError: false, subtype: "success"))]
            ),
            git: git,
            onDidPush: { refreshed.fulfill() }
        )
        model.start()
        await model.runTask?.value

        model.commitAndPush()
        await model.actionTask?.value

        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertTrue(model.hasPushed)
        XCTAssertEqual(
            Array(git.arguments.suffix(4)),
            [
                ["add", "-A"],
                ["commit", "-m", "Address review feedback on #42"],
                ["push", "origin", "HEAD:agent/fix"],
                ["status", "--porcelain"],
            ]
        )
    }

    func testDiscardingRemovesTheWorktreeAndResetsTheSheet() async throws {
        let git = gitRunnerWithDiffStat()
        let model = makeModel(
            runner: ScriptedAgentRunner(
                events: [.result(AgentRunResult(isError: false, subtype: "success"))]
            ),
            git: git
        )
        model.start()
        await model.runTask?.value

        model.discardWorktree()
        await model.actionTask?.value

        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertEqual(
            Array(git.arguments.suffix(2)),
            [
                ["worktree", "remove", "--force", model.worktree?.directory.path ?? ""],
                ["worktree", "prune"],
            ]
        )
    }

    // MARK: - Context and prompts

    func testAReviewFindingPromptCarriesThePathLineAndComments() {
        let summary = PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 7,
            title: "Add the thing",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            isDraft: false,
            headRefName: "feature",
            headRefOid: "abc123",
            baseRefName: "main"
        )
        let thread = ReviewThread(
            id: "T_1",
            path: "Sources/App.swift",
            line: 42,
            comments: [
                ReviewComment(
                    id: "C_1",
                    author: ShepherdCore.Actor(login: "reviewer", kind: .human),
                    bodyMarkdown: "This leaks the file handle when the guard fires.",
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            ]
        )
        let context = DelegationContext.reviewFinding(summary, thread: thread)
        XCTAssertEqual(context.origin, .reviewFinding(path: "Sources/App.swift", line: 42))

        let task = DelegationPrompt.defaultTask(for: context)
        XCTAssertTrue(task.contains("Sources/App.swift"))
        XCTAssertTrue(task.contains("42"))
        XCTAssertTrue(task.contains("leaks the file handle"))
    }

    // MARK: - Centre

    func testTheCentreKeepsOneDelegationPerPullRequest() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shepherd.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let center = DelegationCenter()
        let toasts = ToastCenter()

        let first = center.open(context: context, settings: settings, toasts: toasts)
        let second = center.open(context: context, settings: settings, toasts: toasts)
        XCTAssertEqual(center.models.count, 1)
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotNil(center.presented)
        XCTAssertFalse(center.isRunning(prID: context.prID))

        // Without a configured checkout the sheet refuses and says which setting is missing.
        XCTAssertEqual(second.readiness, .missingCheckout(repo: "schnaq/review"))
        XCTAssertNil(second.worktree)

        center.dismiss()
        XCTAssertNil(center.presented)
    }
}
