import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// "Add a local repository…" and "Start an agent on this repository…" (ADR 0011's 2026-09-23
/// amendment): what git is asked, what the run is told, and what is refused.
@MainActor
final class RepositoryTaskTests: XCTestCase {
    private var root: URL!
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let checkout = URL(fileURLWithPath: "/Users/dev/code/review")

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shepherd-repository-task-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    /// Answers every read a repository task makes: no agent branches yet, `origin/main` as the
    /// default branch, a merge base, and a diff stat.
    private func taskGit(
        agentRefs: String = "",
        diffStat: String = "",
        porcelain: String = ""
    ) -> RecordingProcessRunner {
        RecordingProcessRunner { invocation in
            switch invocation.arguments.first {
            case "for-each-ref":
                return ProcessResult(status: 0, standardOutput: agentRefs, standardError: "")
            case "symbolic-ref":
                return ProcessResult(status: 0, standardOutput: "origin/main\n", standardError: "")
            case "rev-parse":
                return ProcessResult(status: 1, standardOutput: "", standardError: "")
            case "merge-base":
                return ProcessResult(status: 0, standardOutput: "abc123\n", standardError: "")
            case "diff":
                return ProcessResult(status: 0, standardOutput: diffStat, standardError: "")
            case "status":
                return ProcessResult(status: 0, standardOutput: porcelain, standardError: "")
            default:
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            }
        }
    }

    private func handle(_ git: RecordingProcessRunner) -> GitWorktree {
        GitWorktree(
            checkout: checkout,
            directory: root,
            managedRoot: root,
            git: URL(fileURLWithPath: "/usr/bin/git"),
            runner: git
        )
    }

    private func model(
        git: RecordingProcessRunner,
        agent: ScriptedAgentRunner = ScriptedAgentRunner(
            events: [.result(AgentRunResult(isError: false, subtype: "success"))]
        )
    ) -> DelegationModel {
        DelegationModel(
            context: .repository(repo),
            configuration: AgentCLIConfiguration(),
            readiness: .ready,
            runner: agent,
            worktree: handle(git)
        )
    }

    // MARK: - The context

    func testARepositoryContextHasNoNumberNoCommitAndNoBranchYet() {
        let context = DelegationContext.repository(repo)
        XCTAssertEqual(context.origin, .repository)
        XCTAssertTrue(context.isRepositoryTask)
        XCTAssertTrue(context.isNewWork)
        XCTAssertFalse(context.isIssue)
        XCTAssertEqual(context.headRefName, "", "the branch is named after the task, at start")
        XCTAssertEqual(context.headRefOid, "")
        XCTAssertEqual(context.slug, "schnaq/review", "no `#0` for something that has no number")
        XCTAssertEqual(DelegationPrompt.defaultTask(for: context), "")
    }

    func testEveryTaskIsItsOwnTargetUnderTheRepositorysPrefix() {
        let first = DelegationContext.repository(repo)
        let second = DelegationContext.repository(RepoRef(owner: "Schnaq", name: "Review"))
        XCTAssertNotEqual(first.id, second.id, "two tasks on one repository are two targets")
        XCTAssertTrue(first.id.hasPrefix("repository:schnaq/review#"))
        XCTAssertTrue(second.id.hasPrefix("repository:schnaq/review#"), "the prefix ignores case")

        // A caller rebuilding a sheet keeps its identity.
        let task = UUID()
        XCTAssertEqual(
            DelegationContext.repository(repo, task: task).id,
            DelegationContext.repository(repo, task: task).id
        )
    }

    func testTheRepositoryPreambleNamesTheRepositoryAndTheBranchAndAllowsPublishing() {
        var context = DelegationContext.repository(repo)
        context.headRefName = "agent/add-dark-mode"
        let preamble = DelegationPrompt.preamble(for: context)
        XCTAssertTrue(preamble.contains("schnaq/review"))
        XCTAssertTrue(preamble.contains("agent/add-dark-mode"))
        XCTAssertTrue(preamble.lowercased().contains("open a pull request"))
        XCTAssertFalse(preamble.contains("Do not push"))
        XCTAssertFalse(preamble.contains("issue #"), "there is no issue behind a repository task")

        let full = DelegationPrompt.full(for: context, task: "Add dark mode")
        XCTAssertTrue(full.hasSuffix("Task from the reviewer:\nAdd dark mode"))
    }

    // MARK: - Worktree naming

    func testATaskDirectoryIsNamedAfterItsSlug() {
        let directory = GitWorktree.directory(repo: repo, taskSlug: "add-dark-mode", root: root)
        XCTAssertEqual(directory.lastPathComponent, "schnaq-review-task-add-dark-mode")
        XCTAssertEqual(directory.deletingLastPathComponent().path, root.path)
    }

    func testTheCentreAimsARepositoryTaskAtTheManagedRootUntilItStarts() {
        XCTAssertEqual(
            DelegationCenter.worktreeDirectory(for: .repository(repo), root: root),
            root
        )
        XCTAssertThrowsError(
            try handle(RecordingProcessRunner()).ensureManaged(),
            "the root is the one directory `remove()` refuses, so a stray Discard deletes nothing"
        )
    }

    func testAFreeSlugIsReadAfterAFetchFromLocalAndRemoteAgentBranches() async throws {
        let git = taskGit()
        let taken = try await handle(git).takenTaskSlugs()
        XCTAssertEqual(taken, [])
        let slug = handle(git).freeTaskSlug(for: "Add dark mode\nwith a toggle", repo: repo, taken: taken)
        XCTAssertEqual(slug, "add-dark-mode")
        XCTAssertEqual(
            git.arguments,
            [
                ["fetch", "origin"],
                [
                    "for-each-ref", "--format=%(refname)",
                    "refs/heads/agent/", "refs/remotes/origin/agent/",
                ],
            ]
        )
        XCTAssertEqual(Set(git.invocations.compactMap(\.currentDirectory)), [checkout.path])
    }

    func testATakenSlugIsSuffixedWhetherTheBranchIsLocalOrOnOrigin() async throws {
        let local = taskGit(agentRefs: "refs/heads/agent/add-dark-mode\n")
        let fromLocal = handle(local).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
            taken: try await handle(local).takenTaskSlugs(),
            suffix: { "beef" }
        )
        XCTAssertEqual(fromLocal, "add-dark-mode-beef")

        let remote = taskGit(agentRefs: "refs/remotes/origin/agent/add-dark-mode\n")
        let fromRemote = handle(remote).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
            taken: try await handle(remote).takenTaskSlugs(),
            suffix: { "beef" }
        )
        XCTAssertEqual(fromRemote, "add-dark-mode-beef")
    }

    func testALeftoverDirectoryAlsoTakesTheSlug() async throws {
        try FileManager.default.createDirectory(
            at: GitWorktree.directory(repo: repo, taskSlug: "add-dark-mode", root: root),
            withIntermediateDirectories: true
        )
        let slug = handle(taskGit()).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
            taken: [],
            suffix: { "beef" }
        )
        XCTAssertEqual(slug, "add-dark-mode-beef")
    }

    func testASlugAnotherTaskClaimedIsTakenToo() {
        // Claimed by a task that is still fetching: no branch, no directory, only the claim.
        let slug = handle(taskGit()).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
            taken: ["add-dark-mode"],
            suffix: { "beef" }
        )
        XCTAssertEqual(slug, "add-dark-mode-beef")
    }

    func testTheDiffForNewWorkIsTakenFromTheMergeBase() async throws {
        let git = taskGit(diffStat: " a.swift | 2 +-\n 1 file changed\n")
        let stat = try await handle(git).diffStat(since: "origin/main")
        XCTAssertEqual(stat, "a.swift | 2 +-\n 1 file changed")
        XCTAssertEqual(
            git.arguments,
            [["merge-base", "origin/main", "HEAD"], ["diff", "--stat", "abc123"]]
        )
    }

    func testAMergeBaseGitCannotFindFallsBackToTheHeadDiff() async throws {
        // A shallow clone, a rewritten default branch, a starting ref that is gone: git exits
        // non-zero, and the card must still show what is in the worktree rather than nothing.
        let git = RecordingProcessRunner { invocation in
            switch invocation.arguments.first {
            case "merge-base":
                return ProcessResult(status: 1, standardOutput: "", standardError: "fatal: no merge base")
            case "diff":
                return ProcessResult(status: 0, standardOutput: " a.swift | 2 +-\n", standardError: "")
            default:
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            }
        }
        let stat = try await handle(git).diffStat(since: "origin/main")
        XCTAssertEqual(stat, "a.swift | 2 +-")
        XCTAssertEqual(
            git.arguments,
            [["merge-base", "origin/main", "HEAD"], ["diff", "--stat", "HEAD"]]
        )
    }

    func testAnIssueRunThatCommittedItsWorkCanStillBePushed() async throws {
        let row = IssueRowSummary(
            id: "I_128",
            repo: repo,
            number: 128,
            title: "Sync stalls on a renamed branch",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_788_100_000),
            labels: ["bug"]
        )
        let git = taskGit(diffStat: " a.swift | 2 +-\n", porcelain: "")
        let model = DelegationModel(
            context: .issue(row),
            configuration: AgentCLIConfiguration(),
            readiness: .ready,
            runner: ScriptedAgentRunner(
                events: [.result(AgentRunResult(isError: false, subtype: "success"))]
            ),
            worktree: GitWorktree(
                checkout: checkout,
                directory: GitWorktree.directory(repo: repo, issueNumber: 128, root: root),
                managedRoot: root,
                git: URL(fileURLWithPath: "/usr/bin/git"),
                runner: git
            )
        )
        model.start()
        await model.runTask?.value

        XCTAssertEqual(model.worktreeStatus?.isDirty, false, "the run committed everything")
        XCTAssertTrue(model.hasChanges, "committed work is still something to push")
        XCTAssertTrue(git.arguments.contains(["merge-base", "origin/main", "HEAD"]))
    }

    // MARK: - A run

    func testARunNamesItsBranchAfterTheTaskAndStartsItFromTheDefaultBranch() async throws {
        let git = taskGit(diffStat: " a.swift | 2 +-\n")
        let agent = ScriptedAgentRunner(
            events: [.result(AgentRunResult(isError: false, subtype: "success"))]
        )
        let model = model(git: git, agent: agent)
        XCTAssertEqual(model.branchName, "")
        XCTAssertFalse(model.isWorktreeDirectoryKnown)
        XCTAssertFalse(model.canStart, "an empty task starts nothing")

        model.task = "Add dark mode"
        model.start()
        await model.runTask?.value

        let directory = GitWorktree.directory(repo: repo, taskSlug: "add-dark-mode", root: root)
        XCTAssertEqual(model.branchName, "agent/add-dark-mode")
        XCTAssertEqual(model.worktree?.directory, directory)
        XCTAssertTrue(model.isWorktreeDirectoryKnown)
        XCTAssertTrue(
            git.arguments.contains(
                ["worktree", "add", "-b", "agent/add-dark-mode", directory.path, "origin/main"]
            )
        )
        XCTAssertFalse(git.arguments.contains { $0.contains("--detach") })
        XCTAssertFalse(git.arguments.contains { $0.first == "push" }, "Shepherd pushes nothing")
        XCTAssertEqual(
            git.arguments.filter { $0 == ["fetch", "origin"] }.count,
            1,
            "the slug's fetch is the task's only one"
        )

        // The agent ran in the new directory and was told the branch it is on.
        XCTAssertEqual(agent.directories, [directory])
        let prompt = try XCTUnwrap(agent.prompts.first)
        XCTAssertTrue(prompt.contains("agent/add-dark-mode"))
        XCTAssertTrue(prompt.contains("schnaq/review"))
        XCTAssertTrue(prompt.hasSuffix("Add dark mode"))
    }

    func testCommittedWorkCountsAsSomethingToPush() async {
        // A clean worktree with a non-empty diff from the merge base: the run committed its work.
        let model = model(git: taskGit(diffStat: " a.swift | 2 +-\n", porcelain: ""))
        model.task = "Add dark mode"
        model.start()
        await model.runTask?.value
        XCTAssertEqual(model.worktreeStatus?.isDirty, false)
        XCTAssertTrue(model.hasChanges)
    }

    func testRunAgainContinuesInTheSameWorktree() async throws {
        let git = taskGit()
        let model = model(git: git)
        model.task = "Add dark mode"
        model.start()
        await model.runTask?.value
        // git would have created it; the recording runner does not.
        let directory = try XCTUnwrap(model.worktree?.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let addsBefore = git.arguments.filter { $0.prefix(2) == ["worktree", "add"] }.count

        model.task = "Now also add a settings toggle"
        model.start()
        await model.runTask?.value

        XCTAssertEqual(model.branchName, "agent/add-dark-mode", "the branch stays the first run's")
        XCTAssertEqual(
            git.arguments.filter { $0.prefix(2) == ["worktree", "add"] }.count,
            addsBefore,
            "no second worktree"
        )
        XCTAssertTrue(model.transcript.contains { $0.text.contains("Continuing on agent/add-dark-mode") })
    }

    func testTheCommitMessageIsTheTasksFirstLine() {
        let model = model(git: taskGit())
        model.task = "\n  Add dark mode  \nMore detail"
        XCTAssertEqual(model.commitMessage, "Add dark mode")
        model.task = String(repeating: "x", count: 100)
        XCTAssertEqual(model.commitMessage.count, 72)
    }

    func testARuleNeverStartsARepositoryTask() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shepherd.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.setLocalCheckout(checkout, forRepoNamed: repo.fullName)
        // A CLI that exists, so the refusal below is the origin guard and not a missing tool.
        settings.agentCLI.executablePath = "/bin/echo"
        let center = DelegationCenter()
        let started = center.startAutomatically(
            context: .repository(repo),
            task: "Add dark mode",
            settings: settings,
            toasts: ToastCenter()
        )
        XCTAssertNil(started)
        XCTAssertTrue(center.models.isEmpty)

        // The same repository, opened by hand, would be ready to run.
        let manual = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        XCTAssertEqual(manual.readiness, .ready)
    }

    func testATaskThatNeverRanIsNotListedAndMakesWayForTheNext() throws {
        let center = DelegationCenter()
        let settings = try readySettings()
        let untouched = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        // Opened but never started: there is no worktree to go back to.
        XCTAssertTrue(center.repositoryTasks(for: repo).isEmpty)

        // The next "Start an agent…" is a new task, and the sheet nobody ran does not linger.
        let next = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        XCTAssertNotEqual(next.id, untouched.id)
        XCTAssertNil(center.models[untouched.id])
        XCTAssertTrue(center.presented === next)
    }

    func testPresentOnlyShowsAModelTheCentreHolds() async throws {
        // A task that ran: one that never did is forgotten when its sheet closes.
        let center = center(git: taskGit(), agents: [finishing])
        let first = center.open(context: .repository(repo), settings: try readySettings(), toasts: ToastCenter())
        first.task = "Add dark mode"
        first.start()
        await first.runTask?.value
        center.dismiss()
        center.present(first)
        XCTAssertTrue(center.presented === first)

        // A model the centre does not hold is not put on screen.
        center.dismiss()
        center.present(model(git: taskGit()))
        XCTAssertNil(center.presented)
    }

    // MARK: - Several tasks in one repository

    /// Settings with a linked clone and a CLI that exists, so a centre's models are ready.
    private func readySettings() throws -> AppSettings {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shepherd.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.setLocalCheckout(checkout, forRepoNamed: repo.fullName)
        settings.agentCLI.executablePath = "/bin/echo"
        return settings
    }

    /// A centre whose git is recorded and whose agents are the given runners, in the order the
    /// models are made (the last one repeats).
    private func center(git: RecordingProcessRunner, agents: [any AgentRunning]) -> DelegationCenter {
        var remaining = agents
        return DelegationCenter(
            gitRunner: git,
            worktreesRoot: root,
            makeAgentRunner: { _ in remaining.count > 1 ? remaining.removeFirst() : remaining[0] }
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

    private var finishing: ScriptedAgentRunner {
        ScriptedAgentRunner(events: [.result(AgentRunResult(isError: false, subtype: "success"))])
    }

    func testTwoTasksInOneRepositoryGetTheirOwnIdentityBranchWorktreeAndModel() async throws {
        let git = taskGit()
        let center = center(git: git, agents: [finishing])
        let settings = try readySettings()

        let first = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        first.task = "Add dark mode"
        first.start()
        // A second "Start an agent…" while the first runs starts a second task, not a reveal.
        let second = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        XCTAssertFalse(first === second)
        XCTAssertTrue(center.presented === second)
        second.task = "Fix the flaky login test"
        second.start()
        await first.runTask?.value
        await second.runTask?.value

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.branchName, "agent/add-dark-mode")
        XCTAssertEqual(second.branchName, "agent/fix-the-flaky-login-test")
        XCTAssertEqual(
            first.worktree?.directory,
            GitWorktree.directory(repo: repo, taskSlug: "add-dark-mode", root: root)
        )
        XCTAssertEqual(
            second.worktree?.directory,
            GitWorktree.directory(repo: repo, taskSlug: "fix-the-flaky-login-test", root: root)
        )
        XCTAssertEqual(git.arguments.filter { $0.prefix(2) == ["worktree", "add"] }.count, 2)
        XCTAssertEqual(center.repositoryTasks(for: repo).map(\.id), [first.id, second.id])
        XCTAssertFalse(git.arguments.contains { $0.first == "push" }, "Shepherd pushes nothing")
    }

    func testTheSameFirstLineStartedBackToBackGetsTwoBranches() async throws {
        let git = taskGit()
        let center = center(git: git, agents: [finishing])
        let settings = try readySettings()

        let first = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        first.task = "Add dark mode"
        let second = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        second.task = "Add dark mode\nbut for the settings window"
        // Both started before either has picked a name, created a branch or a directory.
        first.start()
        second.start()
        await first.runTask?.value
        await second.runTask?.value

        let branches = [first.branchName, second.branchName]
        XCTAssertEqual(Set(branches).count, 2, "\(branches)")
        XCTAssertTrue(branches.contains("agent/add-dark-mode"))
        XCTAssertTrue(branches.contains { $0.hasPrefix("agent/add-dark-mode-") })
        XCTAssertNotEqual(first.worktree?.directory, second.worktree?.directory)
    }

    func testDiscardingOneTaskLeavesTheOtherRunningAndListed() async throws {
        let git = taskGit()
        let hanging = HangingAgentRunner()
        let center = center(git: git, agents: [finishing, hanging])
        let settings = try readySettings()

        let first = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        first.task = "Add dark mode"
        first.start()
        await first.runTask?.value
        let second = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        second.task = "Fix the flaky login test"
        second.start()
        await waitUntil { second.state == .running }
        XCTAssertEqual(second.phase, .running)

        let firstDirectory = try XCTUnwrap(first.worktree?.directory)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        first.discardWorktree()
        await first.actionTask?.value

        XCTAssertEqual(first.phase, .idle)
        XCTAssertTrue(second.isBusy, "the other task keeps running")
        XCTAssertEqual(center.repositoryTasks(for: repo).map(\.id), [second.id])
        let removed = git.arguments.filter { $0.prefix(2) == ["worktree", "remove"] }
        XCTAssertEqual(removed, [["worktree", "remove", "--force", firstDirectory.path]])
        XCTAssertEqual(
            center.claimedTaskSlugs(in: repo, excluding: "nobody"),
            ["fix-the-flaky-login-test"],
            "the discarded task gave up its name, the running one keeps its own"
        )

        second.cancel()
        await second.runTask?.value
        XCTAssertEqual(center.repositoryTasks(for: repo).map(\.phase), [.cancelled])
    }

    func testTheRailAndThePaletteListBothTasksAndReopeningPicksTheOneNamed() async throws {
        let center = center(git: taskGit(), agents: [finishing])
        let settings = try readySettings()
        let first = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        first.task = "Add dark mode"
        first.start()
        await first.runTask?.value
        let second = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        second.task = "Fix the flaky login test"
        second.start()
        await second.runTask?.value

        // Another repository's task is listed in ⌘K but not under this rail row.
        let other = RepoRef(owner: "schnaq", name: "other")
        settings.setLocalCheckout(checkout, forRepoNamed: other.fullName)
        let elsewhere = center.open(context: .repository(other), settings: settings, toasts: ToastCenter())
        elsewhere.task = "Bump the version"
        elsewhere.start()
        await elsewhere.runTask?.value

        let rail = center.repositoryTasks(for: RepoRef(owner: "Schnaq", name: "Review"))
        XCTAssertEqual(rail.map(\.taskMenuTitle), [
            "Add dark mode — finished",
            "Fix the flaky login test — finished",
        ])
        XCTAssertEqual(center.repositoryTasks.map(\.id), [elsewhere.id, first.id, second.id])
        XCTAssertEqual(
            first.taskPaletteTitle,
            "Show agent task on schnaq/review: Add dark mode — finished"
        )

        // Reopening a finished task shows that run, not a fresh sheet.
        center.dismiss()
        center.present(rail[0])
        XCTAssertTrue(center.presented === first)
        center.present(rail[1])
        XCTAssertTrue(center.presented === second)
        XCTAssertEqual(center.models.count, 3, "reopening creates nothing")
    }

    func testAFailedRunIsListedAsFailed() async throws {
        let failing = ScriptedAgentRunner(events: [.result(AgentRunResult(isError: true, subtype: "error_max_turns"))])
        let center = center(git: taskGit(), agents: [failing])
        let model = center.open(context: .repository(repo), settings: try readySettings(), toasts: ToastCenter())
        model.task = "Add dark mode"
        model.start()
        await model.runTask?.value
        XCTAssertEqual(center.repositoryTasks(for: repo).map(\.phase), [.failed])
    }

    // MARK: - When git refuses, and when the directory is gone

    /// A switch a git handler reads, so one test can make `worktree add` fail and then succeed.
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var isOn: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
        }
    }

    /// ``taskGit()``, except that `worktree add` fails while `refusing` is on.
    private func refusingGit(_ refusing: Switch) -> RecordingProcessRunner {
        RecordingProcessRunner { invocation in
            if invocation.arguments.prefix(2) == ["worktree", "add"], refusing.isOn {
                return ProcessResult(
                    status: 128,
                    standardOutput: "",
                    standardError: "fatal: could not create leading directories"
                )
            }
            switch invocation.arguments.first {
            case "for-each-ref":
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            case "symbolic-ref":
                return ProcessResult(status: 0, standardOutput: "origin/main\n", standardError: "")
            case "rev-parse":
                return ProcessResult(status: 1, standardOutput: "", standardError: "")
            case "merge-base":
                return ProcessResult(status: 0, standardOutput: "abc123\n", standardError: "")
            default:
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            }
        }
    }

    func testAWorktreeGitRefusesReleasesTheClaimAndFailsWithGitsError() async throws {
        let refusing = Switch(true)
        let center = center(git: refusingGit(refusing), agents: [finishing])
        let settings = try readySettings()

        let failed = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        failed.task = "Add dark mode"
        failed.start()
        await failed.runTask?.value

        // (b) Failed, with git's own words.
        guard case .failed(let message) = failed.state else {
            return XCTFail("expected a failed state, got \(failed.state)")
        }
        XCTAssertTrue(message.contains("could not create leading directories"), message)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertTrue(failed.transcript.contains { $0.text.contains("The name is free again") })

        // (a) The claim is released: no branch, no directory, nothing held against the others.
        XCTAssertNil(failed.taskSlug)
        XCTAssertEqual(failed.branchName, "")
        XCTAssertFalse(failed.isWorktreeDirectoryKnown)
        XCTAssertEqual(center.claimedTaskSlugs(in: repo, excluding: "nobody"), [])
        // Still listed, as failed, so its sheet — error, Try again, Dismiss — can be reopened.
        XCTAssertEqual(center.repositoryTasks(for: repo).map(\.id), [failed.id])

        // The same first line is free for the next task, unsuffixed.
        refusing.isOn = false
        let next = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        XCTAssertNotNil(center.models[failed.id], "a failed task is not pruned like an unrun one")
        next.task = "Add dark mode"
        next.start()
        await next.runTask?.value
        XCTAssertEqual(next.branchName, "agent/add-dark-mode")
    }

    func testAFailedTaskCanBeRetriedOrDismissed() async throws {
        let refusing = Switch(true)
        let center = center(git: refusingGit(refusing), agents: [finishing])
        let settings = try readySettings()

        let retried = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        retried.task = "Add dark mode"
        retried.start()
        await retried.runTask?.value
        XCTAssertEqual(retried.phase, .failed)
        XCTAssertTrue(retried.canStart, "Try again is enabled")

        // Retry: git works now, and the task picks its name afresh.
        refusing.isOn = false
        retried.start()
        await retried.runTask?.value
        XCTAssertEqual(retried.phase, .finished)
        XCTAssertEqual(retried.branchName, "agent/add-dark-mode")
        XCTAssertFalse(center.canDismissTask(retried), "one with a worktree is discarded, not dismissed")

        // Dismiss: a failed task with nothing on disk leaves the lists and closes its sheet.
        refusing.isOn = true
        let dismissed = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        dismissed.task = "Fix the flaky login test"
        dismissed.start()
        await dismissed.runTask?.value
        XCTAssertEqual(dismissed.phase, .failed)
        XCTAssertTrue(center.presented === dismissed)
        XCTAssertTrue(center.canDismissTask(dismissed))
        center.dismissTask(dismissed)
        XCTAssertNil(center.models[dismissed.id])
        XCTAssertNil(center.presented)
        XCTAssertEqual(center.repositoryTasks(for: repo).map(\.id), [retried.id])
    }

    /// A git whose branch `agent/add-dark-mode` exists and has `commits` of its own.
    private func gitWithBranch(commits: Int?) -> RecordingProcessRunner {
        RecordingProcessRunner { invocation in
            switch invocation.arguments.first {
            case "symbolic-ref":
                return ProcessResult(status: 0, standardOutput: "origin/main\n", standardError: "")
            case "rev-parse":
                // `nil` commits: the branch does not exist.
                return ProcessResult(status: commits == nil ? 1 : 0, standardOutput: "", standardError: "")
            case "rev-list":
                return ProcessResult(status: 0, standardOutput: "\(commits ?? 0)\n", standardError: "")
            case "merge-base":
                return ProcessResult(status: 0, standardOutput: "abc123\n", standardError: "")
            default:
                return ProcessResult(status: 0, standardOutput: "", standardError: "")
            }
        }
    }

    private func discardWithTheDirectoryGone(commits: Int?) async -> (DelegationModel, RecordingProcessRunner) {
        let git = gitWithBranch(commits: commits)
        let model = model(git: git)
        model.task = "Add dark mode"
        model.start()
        await model.runTask?.value
        // The recording runner creates no directory: the worktree is "gone", as after a
        // half-finished `worktree add` or a delete in Finder.
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.worktree?.directory.path ?? "/"))
        model.discardWorktree()
        await model.actionTask?.value
        return (model, git)
    }

    func testDiscardSucceedsWhenTheDirectoryIsGoneAndDeletesTheUnusedBranch() async {
        let (model, git) = await discardWithTheDirectoryGone(commits: 0)
        XCTAssertEqual(model.state, .idle, "the discard went through")
        XCTAssertNil(model.taskSlug)
        let afterRun = git.arguments.drop { $0.prefix(2) != ["worktree", "prune"] }
        XCTAssertFalse(git.arguments.contains { $0.prefix(2) == ["worktree", "remove"] }, "nothing to remove")
        XCTAssertEqual(
            Array(afterRun),
            [
                ["worktree", "prune"],
                ["rev-parse", "--verify", "--quiet", "refs/heads/agent/add-dark-mode"],
                ["rev-list", "--count", "origin/main..refs/heads/agent/add-dark-mode"],
                ["branch", "-D", "agent/add-dark-mode"],
            ]
        )
    }

    func testDiscardWithTheDirectoryGoneKeepsABranchWithCommitsOrNoBranchAtAll() async {
        let (withWork, workGit) = await discardWithTheDirectoryGone(commits: 2)
        XCTAssertEqual(withWork.state, .idle)
        XCTAssertTrue(workGit.arguments.contains(["worktree", "prune"]))
        XCTAssertFalse(workGit.arguments.contains { $0.first == "branch" }, "committed work is kept")

        let (noBranch, noBranchGit) = await discardWithTheDirectoryGone(commits: nil)
        XCTAssertEqual(noBranch.state, .idle)
        XCTAssertTrue(noBranchGit.arguments.contains(["worktree", "prune"]))
        XCTAssertFalse(noBranchGit.arguments.contains { $0.first == "rev-list" || $0.first == "branch" })
    }

    // MARK: - Stopping a task while its worktree is prepared

    /// A git that holds one kind of call until the test lets it go, and records the rest.
    private final class GatedGit: ProcessRunning, @unchecked Sendable {
        let recorder: RecordingProcessRunner
        private let gated: [String]
        private let gatedResult: ProcessResult
        private let lock = NSLock()
        private var reached = false
        private let (gate, opener) = AsyncStream<Void>.makeStream()

        /// - Parameters:
        ///   - gated: The argv prefix to hold, e.g. `["fetch", "origin"]`.
        ///   - result: What the held call answers once it is let go.
        init(holding gated: [String], answering result: ProcessResult) {
            self.gated = gated
            self.gatedResult = result
            recorder = RecordingProcessRunner { invocation in
                switch invocation.arguments.first {
                case "symbolic-ref":
                    return ProcessResult(status: 0, standardOutput: "origin/main\n", standardError: "")
                case "rev-parse":
                    return ProcessResult(status: 1, standardOutput: "", standardError: "")
                default:
                    return ProcessResult(status: 0, standardOutput: "", standardError: "")
                }
            }
        }

        /// Whether the held call has been made.
        var hasReachedGate: Bool { lock.withLock { reached } }

        /// Lets the held call answer.
        func open() { opener.finish() }

        func run(executable: URL, arguments: [String], currentDirectory: URL?) async throws -> ProcessResult {
            let result = try await recorder.run(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory
            )
            guard Array(arguments.prefix(gated.count)) == gated else { return result }
            lock.withLock { reached = true }
            for await _ in gate {}
            return gatedResult
        }
    }

    private func model(gatedGit git: GatedGit, agent: ScriptedAgentRunner) -> DelegationModel {
        DelegationModel(
            context: .repository(repo),
            configuration: AgentCLIConfiguration(),
            readiness: .ready,
            runner: agent,
            worktree: GitWorktree(
                checkout: checkout,
                directory: root,
                managedRoot: root,
                git: URL(fileURLWithPath: "/usr/bin/git"),
                runner: git
            )
        )
    }

    private let succeeded = ProcessResult(status: 0, standardOutput: "", standardError: "")

    func testStoppingWhileTheSlugIsFetchedClaimsAndCreatesNothing() async throws {
        let git = GatedGit(holding: ["fetch", "origin"], answering: succeeded)
        let agent = finishing
        let model = model(gatedGit: git, agent: agent)
        model.task = "Add dark mode"
        model.start()
        await waitUntil { git.hasReachedGate }

        model.cancel()
        git.open()
        await model.runTask?.value

        XCTAssertEqual(model.state, .cancelled)
        XCTAssertNil(model.taskSlug, "nothing was claimed")
        XCTAssertFalse(git.recorder.arguments.contains { $0.prefix(2) == ["worktree", "add"] })
        XCTAssertTrue(agent.prompts.isEmpty, "the agent never started")
    }

    func testStoppingWhileTheWorktreeIsCreatedKeepsItAndSaysSo() async throws {
        let git = GatedGit(holding: ["worktree", "add"], answering: succeeded)
        let agent = finishing
        let model = model(gatedGit: git, agent: agent)
        model.task = "Add dark mode"
        model.start()
        await waitUntil { git.hasReachedGate }

        model.cancel()
        git.open()
        await model.runTask?.value

        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.taskSlug, "add-dark-mode", "the worktree exists, and its claim with it")
        XCTAssertTrue(model.isWorktreeDirectoryKnown, "so it can be revealed or discarded")
        XCTAssertTrue(model.transcript.contains { $0.text.contains("Stopped after the worktree was created") })
        XCTAssertTrue(agent.prompts.isEmpty, "the agent never started")
    }

    func testAGitFailureAfterStoppingDoesNotTurnTheRunIntoAFailure() async throws {
        let git = GatedGit(
            holding: ["worktree", "add"],
            answering: ProcessResult(status: 128, standardOutput: "", standardError: "fatal: interrupted")
        )
        let model = model(gatedGit: git, agent: finishing)
        model.task = "Add dark mode"
        model.start()
        await waitUntil { git.hasReachedGate }

        model.cancel()
        git.open()
        await model.runTask?.value

        XCTAssertEqual(model.state, .cancelled, "stopped stays stopped")
        XCTAssertNil(model.taskSlug, "git created nothing, so nothing is claimed")
        XCTAssertFalse(model.transcript.contains { $0.text.contains("interrupted") })
        XCTAssertFalse(model.transcript.contains { $0.text.contains("The name is free again") })
    }

    func testASheetOpenedAndClosedWithoutRunningLeavesNothingBehind() throws {
        let center = DelegationCenter()
        let settings = try readySettings()
        let model = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        XCTAssertNotNil(center.models[model.id])
        center.dismiss()
        XCTAssertNil(center.models[model.id])
        XCTAssertTrue(center.models.isEmpty)
    }

    // MARK: - Probing a folder

    func testAFolderOutsideAWorkTreeIsNotARepository() async throws {
        let git = RecordingProcessRunner { _ in
            ProcessResult(status: 128, standardOutput: "", standardError: "fatal: not a git repository")
        }
        let finding = try await LocalRepositoryProbe(runner: git).inspect(URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(finding, .notAGitRepository)
        XCTAssertEqual(git.arguments, [["rev-parse", "--show-toplevel"]])
    }

    func testTheOriginIsReadAtTheTopLevelNotTheFolderThatWasPicked() async throws {
        let git = RecordingProcessRunner { invocation in
            switch invocation.arguments.first {
            case "rev-parse":
                return ProcessResult(status: 0, standardOutput: "/Users/dev/code/review\n", standardError: "")
            default:
                return ProcessResult(
                    status: 0,
                    standardOutput: "git@github.com:schnaq/review.git\n",
                    standardError: ""
                )
            }
        }
        let finding = try await LocalRepositoryProbe(runner: git)
            .inspect(URL(fileURLWithPath: "/Users/dev/code/review/Sources"))
        XCTAssertEqual(
            finding,
            .repository(root: URL(fileURLWithPath: "/Users/dev/code/review", isDirectory: true), remote: .github(repo))
        )
        XCTAssertEqual(git.invocations.last?.arguments, ["remote", "get-url", "origin"])
        XCTAssertEqual(git.invocations.last?.currentDirectory, "/Users/dev/code/review")
    }

    func testACloneWithoutAnOriginIsAFindingNotAFailure() async throws {
        let git = RecordingProcessRunner { invocation in
            invocation.arguments.first == "rev-parse"
                ? ProcessResult(status: 0, standardOutput: "/Users/dev/code/review\n", standardError: "")
                : ProcessResult(status: 2, standardOutput: "", standardError: "error: No such remote 'origin'")
        }
        let finding = try await LocalRepositoryProbe(runner: git).inspect(checkout)
        guard case .repository(_, let remote) = finding else { return XCTFail("\(finding)") }
        XCTAssertEqual(remote, .none)
    }

    func testAnEnterpriseOriginIsNamedAsSuch() async throws {
        let git = RecordingProcessRunner { invocation in
            invocation.arguments.first == "rev-parse"
                ? ProcessResult(status: 0, standardOutput: "/Users/dev/code/app\n", standardError: "")
                : ProcessResult(status: 0, standardOutput: "https://github.acme.com/team/app.git\n", standardError: "")
        }
        let finding = try await LocalRepositoryProbe(runner: git).inspect(checkout)
        guard case .repository(_, let remote) = finding else { return XCTFail("\(finding)") }
        XCTAssertEqual(remote, .enterpriseHost("github.acme.com"))
    }

    // MARK: - Linking and watching in one step

    private func settings() throws -> AppSettings {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shepherd.tests.\(UUID().uuidString)"))
        return AppSettings(defaults: defaults)
    }

    func testAddingLinksAndWatchesAndIsIdempotent() throws {
        let settings = try settings()
        XCTAssertNil(settings.addLocalRepository(repo, folder: checkout, link: true, watch: true))
        XCTAssertEqual(settings.localCheckoutURL(for: repo)?.path, checkout.path)
        XCTAssertEqual(settings.watchedRepositories, [repo])
        XCTAssertTrue(settings.localRepositoryLink(repo, folder: checkout).isComplete)

        // The second time changes nothing and reports nothing wrong.
        XCTAssertNil(settings.addLocalRepository(repo, folder: checkout, link: true, watch: true))
        XCTAssertEqual(settings.watchedRepositories.count, 1)
        XCTAssertEqual(settings.localCheckouts.count, 1)
    }

    func testEitherHalfCanBeLeftOut() throws {
        let settings = try settings()
        XCTAssertNil(settings.addLocalRepository(repo, folder: checkout, link: false, watch: true))
        XCTAssertNil(settings.localCheckoutURL(for: repo))
        XCTAssertEqual(settings.watchedRepositories, [repo])

        let other = try self.settings()
        XCTAssertNil(other.addLocalRepository(repo, folder: checkout, link: true, watch: false))
        XCTAssertNotNil(other.localCheckoutURL(for: repo))
        XCTAssertTrue(other.watchedRepositories.isEmpty)
    }

    func testAFullWatchListIsReportedButTheCheckoutIsStillLinked() throws {
        let settings = try settings()
        settings.watchedRepositories = (0..<AppSettings.maximumWatchedRepositories)
            .map { RepoRef(owner: "o", name: "r\($0)") }
        let message = settings.addLocalRepository(repo, folder: checkout, link: true, watch: true)
        XCTAssertNotNil(message)
        XCTAssertNotNil(settings.localCheckoutURL(for: repo))
    }

    func testLinkedRepositoriesAreTheValidNonEmptyCheckoutsByName() throws {
        let settings = try settings()
        settings.localCheckouts = [
            "schnaq/zeta": "/code/zeta",
            "schnaq/alpha": "/code/alpha",
            "not a repository": "/code/x",
            "schnaq/empty": "  ",
        ]
        XCTAssertEqual(
            settings.linkedRepositories.map(\.fullName),
            ["schnaq/alpha", "schnaq/zeta"]
        )
    }

    func testAWholesaleAssignmentWithCaseVariantsKeepsOneEntryPerRepository() throws {
        // What `SettingsSyncApplier` does with a downloaded document.
        let settings = try settings()
        settings.localCheckouts = ["schnaq/review": "/b", "Schnaq/Review": "/a"]
        XCTAssertEqual(settings.localCheckouts, ["Schnaq/Review": "/a"])
        XCTAssertEqual(settings.localCheckoutURL(for: repo)?.path, "/a")

        let names = settings.linkedRepositories.map { $0.fullName.lowercased() }
        XCTAssertEqual(names, ["schnaq/review"], "one palette command, so one identity")
    }

    func testCaseVariantsInAnOldDefaultsFileAreCollapsedOnLoad() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(["schnaq/review": "/b", "Schnaq/Review": "/a"], forKey: "delegation.localCheckouts")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.localCheckouts, ["Schnaq/Review": "/a"])
        XCTAssertEqual(settings.linkedRepositories.count, 1)
    }

    func testAnUnreadableOriginIsShownWithoutItsCredentials() async throws {
        let git = RecordingProcessRunner { invocation in
            invocation.arguments.first == "rev-parse"
                ? ProcessResult(status: 0, standardOutput: "/Users/dev/code/app\n", standardError: "")
                : ProcessResult(
                    status: 0,
                    standardOutput: "https://me:ghp_secret@github.com/not a/repo?x=1\n",
                    standardError: ""
                )
        }
        let finding = try await LocalRepositoryProbe(runner: git).inspect(checkout)
        guard case .repository(_, .unreadable(let shown)) = finding else { return XCTFail("\(finding)") }
        XCTAssertEqual(shown, "https://github.com/not a/repo")
        XCTAssertFalse(shown.contains("ghp_secret"))
    }

    func testACheckoutIsFoundWhateverCaseTheRepositoryIsSpelledIn() throws {
        let settings = try settings()
        settings.setLocalCheckout(checkout, forRepoNamed: "Schnaq/Review")
        XCTAssertEqual(settings.localCheckoutURL(for: repo)?.path, checkout.path)

        // Linking again under the other spelling replaces the entry instead of adding a second.
        settings.setLocalCheckout(URL(fileURLWithPath: "/Volumes/new/review"), forRepoNamed: "schnaq/review")
        XCTAssertEqual(settings.localCheckouts, ["schnaq/review": "/Volumes/new/review"])
    }
}
