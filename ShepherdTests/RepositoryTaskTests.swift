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

    func testTheIdentityIsTheRepositoryIgnoringCase() {
        XCTAssertEqual(
            DelegationContext.repository(RepoRef(owner: "Schnaq", name: "Review")).id,
            DelegationContext.repository(repo).id
        )
        XCTAssertEqual(DelegationContext.repository(repo).id, "repository:schnaq/review")
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

    func testAFreeSlugIsReadAfterAFetchFromLocalAndRemoteAgentBranches() async {
        let git = taskGit()
        let slug = await handle(git).freeTaskSlug(for: "Add dark mode\nwith a toggle", repo: repo)
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

    func testATakenSlugIsSuffixedWhetherTheBranchIsLocalOrOnOrigin() async {
        let local = taskGit(agentRefs: "refs/heads/agent/add-dark-mode\n")
        let fromLocal = await handle(local).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
            suffix: { "beef" }
        )
        XCTAssertEqual(fromLocal, "add-dark-mode-beef")

        let remote = taskGit(agentRefs: "refs/remotes/origin/agent/add-dark-mode\n")
        let fromRemote = await handle(remote).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
            suffix: { "beef" }
        )
        XCTAssertEqual(fromRemote, "add-dark-mode-beef")
    }

    func testALeftoverDirectoryAlsoTakesTheSlug() async throws {
        try FileManager.default.createDirectory(
            at: GitWorktree.directory(repo: repo, taskSlug: "add-dark-mode", root: root),
            withIntermediateDirectories: true
        )
        let slug = await handle(taskGit()).freeTaskSlug(
            for: "Add dark mode",
            repo: repo,
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

    func testAFinishedTaskIsShownAgainRatherThanReplaced() throws {
        let center = DelegationCenter()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shepherd.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let first = center.open(context: .repository(repo), settings: settings, toasts: ToastCenter())
        center.dismiss()
        center.present(first)
        XCTAssertTrue(center.presented === first)

        // A model the centre does not hold is not put on screen.
        center.dismiss()
        center.present(model(git: taskGit()))
        XCTAssertNil(center.presented)
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

    func testACheckoutIsFoundWhateverCaseTheRepositoryIsSpelledIn() throws {
        let settings = try settings()
        settings.setLocalCheckout(checkout, forRepoNamed: "Schnaq/Review")
        XCTAssertEqual(settings.localCheckoutURL(for: repo)?.path, checkout.path)

        // Linking again under the other spelling replaces the entry instead of adding a second.
        settings.setLocalCheckout(URL(fileURLWithPath: "/Volumes/new/review"), forRepoNamed: "schnaq/review")
        XCTAssertEqual(settings.localCheckouts, ["schnaq/review": "/Volumes/new/review"])
    }
}
