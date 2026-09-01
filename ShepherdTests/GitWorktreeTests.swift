import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// Records every subprocess it is asked to run and answers from a scripted handler.
///
/// Delegation shells out to git; these tests assert the **exact argv** of every call rather
/// than running git for real, which keeps them hermetic and fast.
final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    /// One recorded call.
    struct Invocation: Equatable {
        /// The binary.
        var executable: String
        /// argv without argv[0].
        var arguments: [String]
        /// The working directory's path.
        var currentDirectory: String?
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let handler: @Sendable (Invocation) -> ProcessResult

    /// Creates a runner.
    /// - Parameter handler: Decides what each call returns. Defaults to a silent success.
    init(handler: @escaping @Sendable (Invocation) -> ProcessResult = { _ in
        ProcessResult(status: 0, standardOutput: "", standardError: "")
    }) {
        self.handler = handler
    }

    /// Everything that was run, in order.
    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    /// argv of every call, for compact assertions.
    var arguments: [[String]] { invocations.map(\.arguments) }

    // Synchronous on purpose: `lock`/`unlock` are unavailable from async contexts.
    private func record(_ invocation: Invocation) {
        lock.withLock { recorded.append(invocation) }
    }

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) async throws -> ProcessResult {
        let invocation = Invocation(
            executable: executable.path,
            arguments: arguments,
            currentDirectory: currentDirectory?.path
        )
        record(invocation)
        return handler(invocation)
    }
}

/// The git command sequences behind a delegation.
final class GitWorktreeTests: XCTestCase {
    private var root: URL!
    private var checkout: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shepherd-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        checkout = URL(fileURLWithPath: "/Users/dev/code/review")
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func worktree(runner: RecordingProcessRunner) -> GitWorktree {
        GitWorktree(
            checkout: checkout,
            directory: GitWorktree.directory(
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 42,
                root: root
            ),
            managedRoot: root,
            git: URL(fileURLWithPath: "/usr/bin/git"),
            runner: runner
        )
    }

    func testTheWorktreeDirectoryIsNamedAfterThePullRequest() {
        let directory = GitWorktree.directory(
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            root: root
        )
        XCTAssertEqual(directory.lastPathComponent, "schnaq-review-pr42")
        XCTAssertEqual(directory.deletingLastPathComponent().path, root.path)
    }

    func testPreparingFetchesThenAddsADetachedWorktree() async throws {
        let runner = RecordingProcessRunner()
        let tree = worktree(runner: runner)
        try await tree.prepare(branch: "agent/fix-thing", headOid: "deadbeef")

        XCTAssertEqual(
            runner.arguments,
            [
                ["fetch", "origin", "agent/fix-thing"],
                ["worktree", "add", "--detach", tree.directory.path, "deadbeef"],
            ]
        )
        // Both run in the user's clone, not in the worktree, which does not exist yet.
        XCTAssertEqual(runner.invocations.map(\.currentDirectory), [checkout.path, checkout.path])
        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/git")
    }

    func testPreparingSurfacesAFailedFetch() async {
        let runner = RecordingProcessRunner { invocation in
            invocation.arguments.first == "fetch"
                ? ProcessResult(status: 128, standardOutput: "", standardError: "no such remote")
                : ProcessResult(status: 0, standardOutput: "", standardError: "")
        }
        do {
            try await worktree(runner: runner).prepare(branch: "b", headOid: "o")
            XCTFail("expected the fetch failure to propagate")
        } catch {
            XCTAssertEqual(
                error as? GitWorktree.Failure,
                .commandFailed(command: "fetch", status: 128, message: "no such remote")
            )
        }
        XCTAssertEqual(runner.arguments.count, 1, "nothing runs after a failed fetch")
    }

    func testStatusAndDiffStatRunInsideTheWorktree() async throws {
        let runner = RecordingProcessRunner { invocation in
            switch invocation.arguments.first {
            case "status":
                return ProcessResult(
                    status: 0,
                    standardOutput: " M Sources/App.swift\n?? Sources/New.swift\n",
                    standardError: ""
                )
            case "diff":
                return ProcessResult(
                    status: 0,
                    standardOutput: " Sources/App.swift | 4 ++--\n 1 file changed\n",
                    standardError: ""
                )
            default:
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            }
        }
        let tree = worktree(runner: runner)

        let snapshot = try await tree.status()
        XCTAssertTrue(snapshot.isDirty)
        XCTAssertEqual(snapshot.changedPaths, ["Sources/App.swift", "Sources/New.swift"])

        let stat = try await tree.diffStat()
        XCTAssertTrue(stat.hasPrefix("Sources/App.swift | 4 ++--"))

        XCTAssertEqual(
            runner.arguments,
            [["status", "--porcelain"], ["diff", "--stat", "HEAD"]]
        )
        XCTAssertEqual(
            runner.invocations.map(\.currentDirectory),
            [tree.directory.path, tree.directory.path]
        )
    }

    func testCommitAllStagesEverythingThenCommits() async throws {
        let runner = RecordingProcessRunner()
        try await worktree(runner: runner).commitAll(message: "Address review feedback on #42")
        XCTAssertEqual(
            runner.arguments,
            [["add", "-A"], ["commit", "-m", "Address review feedback on #42"]]
        )
    }

    func testPushGoesToThePullRequestBranchFromDetachedHEAD() async throws {
        let runner = RecordingProcessRunner()
        try await worktree(runner: runner).push(toBranch: "agent/fix-thing")
        XCTAssertEqual(runner.arguments, [["push", "origin", "HEAD:agent/fix-thing"]])
    }

    func testRemoveForcesThenPrunes() async throws {
        let runner = RecordingProcessRunner()
        let tree = worktree(runner: runner)
        try await tree.remove()
        XCTAssertEqual(
            runner.arguments,
            [
                ["worktree", "remove", "--force", tree.directory.path],
                ["worktree", "prune"],
            ]
        )
    }

    func testRemoveRefusesAnyPathOutsideTheManagedDirectory() async {
        let runner = RecordingProcessRunner()
        let escaped = GitWorktree(
            checkout: checkout,
            directory: URL(fileURLWithPath: "/Users/dev/code/review"),
            managedRoot: root,
            git: URL(fileURLWithPath: "/usr/bin/git"),
            runner: runner
        )
        do {
            try await escaped.remove()
            XCTFail("expected the removal to be refused")
        } catch {
            XCTAssertEqual(
                error as? GitWorktree.Failure,
                .pathOutsideManagedDirectory("/Users/dev/code/review")
            )
        }
        XCTAssertTrue(runner.invocations.isEmpty, "nothing may run before the check")
    }

    func testRemoveRefusesTheManagedRootItself() async {
        let runner = RecordingProcessRunner()
        let tree = GitWorktree(
            checkout: checkout,
            directory: root,
            managedRoot: root,
            git: URL(fileURLWithPath: "/usr/bin/git"),
            runner: runner
        )
        do {
            try await tree.remove()
            XCTFail("expected the removal to be refused")
        } catch {
            XCTAssertTrue(runner.invocations.isEmpty)
        }
    }

    func testRemoveRefusesATraversalOutOfTheManagedDirectory() async {
        let runner = RecordingProcessRunner()
        let tree = GitWorktree(
            checkout: checkout,
            directory: root.appendingPathComponent("../../etc", isDirectory: true),
            managedRoot: root,
            git: URL(fileURLWithPath: "/usr/bin/git"),
            runner: runner
        )
        do {
            try await tree.remove()
            XCTFail("expected the removal to be refused")
        } catch {
            XCTAssertTrue(runner.invocations.isEmpty)
        }
    }
}
