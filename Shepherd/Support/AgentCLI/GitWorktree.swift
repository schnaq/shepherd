import Foundation
import ShepherdCore

/// A Shepherd-managed `git worktree` for one pull request.
///
/// Delegation never runs an agent in the user's checkout: it fetches the pull request's head
/// commit and adds a **detached** worktree under Application Support, so whatever the agent
/// does cannot touch the branch the user is standing on (ADR 0011).
///
/// Every command goes through ``ProcessRunning``, which is what lets the unit tests assert the
/// exact argv of each git call without a repository on disk.
struct GitWorktree: Sendable {
    /// The state of the worktree after a run.
    struct Snapshot: Sendable, Equatable {
        /// The raw `git status --porcelain` output.
        var porcelain: String

        /// Whether the agent changed anything at all.
        var isDirty: Bool { !porcelain.isEmpty }

        /// The paths git reported, in the order it printed them.
        var changedPaths: [String] {
            porcelain
                .split(separator: "\n")
                .map { String($0.dropFirst(3)) }
                .filter { !$0.isEmpty }
        }
    }

    /// Why a git step failed.
    enum Failure: LocalizedError, Equatable {
        /// A git command exited non-zero.
        case commandFailed(command: String, status: Int32, message: String)
        /// A path outside the managed worktrees directory was passed to ``remove()``.
        case pathOutsideManagedDirectory(String)
        /// git could not say which branch `origin`'s HEAD points at.
        case noDefaultBranch
        /// A previous run left uncommitted work in the worktree this one wants.
        case worktreeHasUncommittedWork(String)
        /// Every candidate name for a repository task's branch was already taken.
        case noFreeTaskBranch

        var errorDescription: String? {
            switch self {
            case .commandFailed(let command, let status, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return String(localized: "`git \(command)` failed with status \(Int(status)).")
                }
                return String(localized: "`git \(command)` failed: \(detail)")
            case .pathOutsideManagedDirectory(let path):
                return String(
                    localized: "Refusing to delete \(path): it is not inside Shepherd's worktrees directory."
                )
            case .noDefaultBranch:
                return String(
                    localized: "git could not tell which branch this repository's `origin` points at. Run `git remote set-head origin --auto` in your clone and try again."
                )
            case .worktreeHasUncommittedWork(let path):
                return String(
                    localized: "A previous run left changes in \(path) that were never committed. Commit or discard them from that delegation's sheet, then assign the issue again."
                )
            case .noFreeTaskBranch:
                return String(
                    localized: "Every branch name Shepherd tried for this task is already taken. Start the task with different first words."
                )
            }
        }
    }

    /// The user's own clone of the repository.
    let checkout: URL
    /// The Shepherd-managed worktree directory.
    let directory: URL
    /// The directory every managed worktree must live inside.
    let managedRoot: URL
    /// The git binary.
    let git: URL
    /// The subprocess seam.
    let runner: any ProcessRunning

    /// git as shipped with the developer tools. Resolved through the `/usr/bin` shim so it
    /// works whether the user has the full Xcode or just the command line tools.
    static let defaultGitExecutable = URL(fileURLWithPath: "/usr/bin/git")

    /// Creates a worktree handle.
    /// - Parameters:
    ///   - checkout: The user's clone; git commands that need the repository run here.
    ///   - directory: Where the worktree lives.
    ///   - managedRoot: The directory ``remove()`` refuses to step outside of.
    ///   - git: The git binary.
    ///   - runner: The subprocess seam.
    init(
        checkout: URL,
        directory: URL,
        managedRoot: URL = AppConfig.worktreesDirectory,
        git: URL = GitWorktree.defaultGitExecutable,
        runner: any ProcessRunning = SystemProcessRunner.shared
    ) {
        self.checkout = checkout
        self.directory = directory
        self.managedRoot = managedRoot
        self.git = git
        self.runner = runner
    }

    /// The directory name for a pull request: `owner-repo-pr123`.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    static func directoryName(repo: RepoRef, number: Int) -> String {
        "\(sanitize(repo.owner))-\(sanitize(repo.name))-pr\(number)"
    }

    /// The managed directory for a pull request.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    ///   - root: The managed worktrees directory.
    static func directory(
        repo: RepoRef,
        number: Int,
        root: URL = AppConfig.worktreesDirectory
    ) -> URL {
        root.appendingPathComponent(directoryName(repo: repo, number: number), isDirectory: true)
    }

    /// The directory name for an issue: `owner-repo-issue128`.
    ///
    /// A vocabulary of its own rather than reusing the pull-request name, because the numbers
    /// come from two different sequences: issue 128 and pull request 128 exist in the same
    /// repository and would otherwise be handed the same directory — and the second run would
    /// delete the first one's work on its way in (ADR 0032's 2026-09-04 amendment).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    static func directoryName(repo: RepoRef, issueNumber number: Int) -> String {
        "\(sanitize(repo.owner))-\(sanitize(repo.name))-issue\(number)"
    }

    /// The managed directory for an issue.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - root: The managed worktrees directory.
    static func directory(
        repo: RepoRef,
        issueNumber number: Int,
        root: URL = AppConfig.worktreesDirectory
    ) -> URL {
        root.appendingPathComponent(
            directoryName(repo: repo, issueNumber: number),
            isDirectory: true
        )
    }

    /// The branch a delegation started from an issue works on.
    ///
    /// **Shepherd** names it, deterministically, rather than asking the assistant to invent one:
    /// a name the app can predict is a name it can show in the sheet, put in the preamble and
    /// find again when the same issue is handed over twice (ADR 0032's 2026-09-04 amendment).
    /// - Parameter number: The issue number.
    static func branchName(issueNumber number: Int) -> String { "agent/issue-\(number)" }

    /// The directory name for a free-text task on a repository: `owner-repo-task-add-dark-mode`.
    ///
    /// The third vocabulary beside `-pr` and `-issue`, for the second one's reason: a task has no
    /// number, so its directory is named after the same slug as its branch, and the two are
    /// uniqued together (ADR 0011's 2026-09-23 amendment).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - slug: The task's slug, from ``ShepherdCore/RepositoryTaskBranch``.
    static func directoryName(repo: RepoRef, taskSlug slug: String) -> String {
        "\(sanitize(repo.owner))-\(sanitize(repo.name))-task-\(sanitize(slug))"
    }

    /// The managed directory for a free-text task on a repository.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - slug: The task's slug.
    ///   - root: The managed worktrees directory.
    static func directory(
        repo: RepoRef,
        taskSlug slug: String,
        root: URL = AppConfig.worktreesDirectory
    ) -> URL {
        root.appendingPathComponent(directoryName(repo: repo, taskSlug: slug), isDirectory: true)
    }

    /// The same clone, git and runner, pointed at another worktree directory.
    ///
    /// A repository task only learns its directory when it starts — the name comes from the task
    /// text, which is typed in the sheet the handle was built for — so the handle is re-aimed
    /// rather than rebuilt from settings.
    /// - Parameter directory: The new worktree directory.
    func relocated(to directory: URL) -> GitWorktree {
        GitWorktree(
            checkout: checkout,
            directory: directory,
            managedRoot: managedRoot,
            git: git,
            runner: runner
        )
    }

    /// The agent branch names git already knows for this clone, as slugs: `agent/<slug>` locally
    /// and on `origin` as of a fresh fetch.
    ///
    /// The first half of choosing a free slug, and the only half that waits. It is split from
    /// ``freeTaskSlug(for:repo:taken:suffix:)`` so the caller can do the second half — pick the
    /// name *and* record it as taken — with no suspension point in between: two tasks started back
    /// to back on one repository both wait here, and if the pick happened after the wait inside
    /// this method, both would see the same repository and choose the same name. ``DelegationModel``
    /// makes the pick on the main actor straight after this returns (ADR 0011's 2026-09-23
    /// amendment).
    ///
    /// One `for-each-ref` answers for local and remote branches, after a fetch so that "on
    /// `origin`" means now rather than whenever the clone last fetched — a branch pushed from
    /// another Mac this morning counts. The fetch is best-effort (an offline Mac still gets a name,
    /// checked against what it knows), and the one ``addForNewWork(branch:)`` makes straight after
    /// is then a cheap no-op.
    func takenTaskSlugs() async -> Set<String> {
        _ = try? await run(["fetch", "origin"], in: checkout, label: "fetch")
        let result = try? await runner.run(
            executable: git,
            arguments: [
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads/agent/",
                "refs/remotes/origin/agent/",
            ],
            currentDirectory: checkout
        )
        var taken = Set<String>()
        for line in (result?.standardOutput ?? "").split(whereSeparator: \.isNewline) {
            for prefix in ["refs/heads/agent/", "refs/remotes/origin/agent/"] where line.hasPrefix(prefix) {
                taken.insert(String(line.dropFirst(prefix.count)))
            }
        }
        return taken
    }

    /// Picks a free slug for a new task on a repository — synchronously, for the reason
    /// ``takenTaskSlugs()`` gives.
    ///
    /// "Free" means four things at once, because a collision on any of them is a different
    /// failure: no local branch `agent/<slug>` (``addForNewWork(branch:)`` would *resume* it and
    /// land this task on another one's commits), no `origin/agent/<slug>` (a push from the button
    /// would collide), no managed directory of that name (which ``addForNewWork(branch:)`` would
    /// refuse or clear), and no other task on the repository that has claimed the name but not
    /// created anything yet. The first two and the last arrive in `taken`; the directory is
    /// checked here.
    /// - Parameters:
    ///   - task: The task text, whose first line becomes the slug.
    ///   - repo: The repository, for the directory name.
    ///   - taken: Slugs already spoken for — git's, and the other tasks'.
    ///   - suffix: A fresh short suffix per call, for when the slug is taken.
    /// - Returns: A free slug, or `nil` when five suffixed candidates were all taken.
    func freeTaskSlug(
        for task: String,
        repo: RepoRef,
        taken: Set<String>,
        suffix: () -> String = { RepositoryTaskBranch.randomSuffix() }
    ) -> String? {
        let root = managedRoot
        return RepositoryTaskBranch.unique(
            RepositoryTaskBranch.slug(from: task),
            isTaken: { slug in
                taken.contains(slug) || FileManager.default.fileExists(
                    atPath: GitWorktree.directory(repo: repo, taskSlug: slug, root: root).path
                )
            },
            suffix: suffix
        )
    }

    /// Replaces anything that would create a nested path or an odd file name.
    private static func sanitize(_ component: String) -> String {
        String(component.map { $0 == "/" || $0 == ":" || $0 == "." ? "-" : $0 })
    }

    // MARK: - Lifecycle

    /// Fetches the pull request's branch and adds a detached worktree at its head commit.
    ///
    /// Detached on purpose: the agent must not be able to move a branch, and the reviewer
    /// decides later whether anything gets pushed.
    /// - Parameters:
    ///   - branch: The head branch name, fetched from `origin`.
    ///   - headOid: The commit to check out.
    func prepare(branch: String, headOid: String) async throws {
        try await run(["fetch", "origin", branch], in: checkout, label: "fetch")
        if FileManager.default.fileExists(atPath: directory.path) {
            // A worktree left behind by a previous run (or a crash) is cleaned up rather than
            // failing the whole delegation. Failure here is not fatal: `worktree add` will say
            // so far more clearly.
            try? await remove()
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await run(
            ["worktree", "add", "--detach", directory.path, headOid],
            in: checkout,
            label: "worktree add"
        )
    }

    /// Adds a worktree for work that does not exist yet, on its own branch.
    ///
    /// The counterpart to ``prepare(branch:headOid:)``, and the difference is the whole point of
    /// having two entry points. Addressing an existing pull request means standing on that pull
    /// request's commit with no branch to move, so that one checks out a detached head. Working
    /// on an issue means there is nothing to stand on yet: the worktree starts at the tip of the
    /// repository's default branch, on a branch Shepherd named, and a commit made there belongs
    /// to something (ADR 0032's 2026-09-04 amendment).
    ///
    /// Which branch is the default is asked of **git** rather than of GitHub: `origin/HEAD` is a
    /// pointer every clone has, `git remote set-head --auto` refreshes it with the user's own
    /// credentials, and that keeps this a local operation on a Mac that already has the
    /// repository — no request, and nothing added to the host list in CONTRIBUTING.md.
    ///
    /// Handing the same issue over twice **resumes** the branch rather than resetting it: the
    /// first run's commits are the user's work, and a second worktree that quietly threw them
    /// away would be the worst possible reading of "assign this again".
    /// - Parameter branch: The branch to create, from ``branchName(issueNumber:)``.
    /// - Returns: The ref the branch was started from, e.g. `origin/main`, for the transcript.
    @discardableResult
    func addForNewWork(branch: String) async throws -> String {
        try await run(["fetch", "origin"], in: checkout, label: "fetch")
        // Best-effort: a clone made before the default branch was renamed still points at the
        // old name, and this is the cheap way to notice. A failure here is not fatal — the
        // pointer may already be right, and ``defaultBranchRef()`` is what actually decides.
        _ = try? await run(
            ["remote", "set-head", "origin", "--auto"],
            in: checkout,
            label: "remote set-head"
        )
        let base = try await defaultBranchRef()
        if FileManager.default.fileExists(atPath: directory.path) {
            // A worktree is already there: a previous run's, or a crash's. Committed work is
            // safe either way — it is on the branch, and the branch is what this worktree is
            // re-checked-out from below. **Uncommitted** work is not, and removing a worktree
            // is `--force`, so the one case that must not be silently swallowed is a dirty
            // one: it is refused with a message naming the directory instead. A clean leftover
            // is cleared out, exactly as ``prepare(branch:headOid:)`` clears one.
            let leftover = try? await status()
            if leftover?.isDirty == true {
                throw Failure.worktreeHasUncommittedWork(directory.path)
            }
            try? await remove()
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if await hasLocalBranch(branch) {
            try await run(
                ["worktree", "add", directory.path, branch],
                in: checkout,
                label: "worktree add"
            )
        } else {
            try await run(
                ["worktree", "add", "-b", branch, directory.path, base],
                in: checkout,
                label: "worktree add"
            )
        }
        return base
    }

    /// What `origin`'s HEAD points at, e.g. `origin/main`.
    private func defaultBranchRef() async throws -> String {
        let result = try? await run(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            in: checkout,
            label: "symbolic-ref"
        )
        let ref = result?.trimmedOutput ?? ""
        // A clone whose `origin/HEAD` was never set answers with a failure or with nothing, and
        // guessing `main` here would put the branch on top of whatever that name happens to be
        // in a repository that calls its default something else. The error names the one command
        // that fixes it instead.
        guard !ref.isEmpty else { throw Failure.noDefaultBranch }
        return ref
    }

    /// Whether the local repository already has this branch.
    ///
    /// Asked before creating one, rather than creating one and reading the failure: `git
    /// worktree add -b` fails for more reasons than "the branch exists", and a retry that
    /// swallowed the first error would report the wrong one.
    private func hasLocalBranch(_ branch: String) async -> Bool {
        let result = try? await runner.run(
            executable: git,
            arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            currentDirectory: checkout
        )
        return result?.isSuccess ?? false
    }

    /// Removes the worktree and prunes git's administrative record of it.
    ///
    /// Refuses any directory outside ``managedRoot`` — the path comes from settings the user
    /// can edit, and `git worktree remove --force` deletes files.
    ///
    /// A directory that is not there is not an error. `git worktree remove` fails on one ("is not
    /// a working tree"), and a *Discard* that fails because there is nothing to discard leaves
    /// the sheet with no way out — a run whose `worktree add` failed half-way, or a directory the
    /// user deleted in Finder. The remove is skipped and the prune still runs, which is what
    /// clears git's record of a worktree whose directory has gone.
    func remove() async throws {
        try ensureManaged()
        if FileManager.default.fileExists(atPath: directory.path) {
            try await run(
                ["worktree", "remove", "--force", directory.path],
                in: checkout,
                label: "worktree remove"
            )
        }
        try await run(["worktree", "prune"], in: checkout, label: "worktree prune")
    }

    /// Deletes a local branch that exists and holds no work of its own; keeps any other.
    ///
    /// For a repository task discarded after its directory went missing: the branch is then the
    /// leftover of a worktree that never really existed, and leaving it would take its name for
    /// good. "Holds no work" is `git rev-list --count <base>..<branch>` answering `0` — a branch
    /// with a commit on it is somebody's work, and Shepherd does not throw work away, so it stays.
    /// Without a base there is no way to tell, and the branch stays too.
    /// - Parameters:
    ///   - branch: The branch, e.g. `agent/add-dark-mode`.
    ///   - base: The ref the branch was started from, when known.
    /// - Returns: Whether the branch was deleted.
    @discardableResult
    func deleteLocalBranchIfUnused(_ branch: String, since base: String?) async throws -> Bool {
        guard await hasLocalBranch(branch), let base else { return false }
        let count = try await run(
            ["rev-list", "--count", "\(base)..refs/heads/\(branch)"],
            in: checkout,
            label: "rev-list"
        )
        guard count.trimmedOutput == "0" else { return false }
        try await run(["branch", "-D", branch], in: checkout, label: "branch -D")
        return true
    }

    /// Throws unless ``directory`` is a proper descendant of ``managedRoot``.
    func ensureManaged() throws {
        let root = managedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let target = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let boundary = root.hasSuffix("/") ? root : root + "/"
        guard target != root, target.hasPrefix(boundary), !target.contains("/../") else {
            throw Failure.pathOutsideManagedDirectory(directory.path)
        }
    }

    // MARK: - Inspection

    /// `git status --porcelain` inside the worktree.
    func status() async throws -> Snapshot {
        let result = try await run(["status", "--porcelain"], in: directory, label: "status")
        // Trim only line breaks: porcelain lines carry meaning in their first two columns,
        // and an unstaged entry (" M path") starts with a space that must survive.
        return Snapshot(
            porcelain: result.standardOutput.trimmingCharacters(in: .newlines)
        )
    }

    /// `git diff --stat HEAD` inside the worktree — what the reviewer reads before pushing.
    func diffStat() async throws -> String {
        try await run(["diff", "--stat", "HEAD"], in: directory, label: "diff").trimmedOutput
    }

    /// `git diff --stat` from where new work started to the working tree — committed and
    /// uncommitted changes together.
    ///
    /// For a run that may commit (an issue, a repository task): ``diffStat()`` compares against
    /// `HEAD`, so a run that committed everything would read as one that changed nothing. The
    /// comparison point is the merge base of `base` and `HEAD` rather than `base` itself, because
    /// the run may have fetched and moved `origin/main` since, and a diff against the moved ref
    /// would show upstream's new commits as if the agent had reverted them.
    /// - Parameter base: The ref the branch was started from, e.g. `origin/main`.
    ///
    /// A merge base git cannot find — a shallow clone, a rewritten default branch, a starting ref
    /// that no longer exists — falls back to ``diffStat()`` rather than failing: an empty stat
    /// would read as "changed nothing" and disable the push button for work that is there.
    func diffStat(since base: String) async throws -> String {
        let mergeBase = (try? await run(
            ["merge-base", base, "HEAD"],
            in: directory,
            label: "merge-base"
        ))?.trimmedOutput ?? ""
        guard !mergeBase.isEmpty else { return try await diffStat() }
        return try await run(["diff", "--stat", mergeBase], in: directory, label: "diff").trimmedOutput
    }

    // MARK: - Publishing

    /// Stages and commits everything the agent changed.
    /// - Parameter message: The commit message.
    func commitAll(message: String) async throws {
        try await run(["add", "-A"], in: directory, label: "add")
        try await run(["commit", "-m", message], in: directory, label: "commit")
    }

    /// Pushes the worktree's HEAD to the pull request's branch.
    ///
    /// This uses **the user's own git credentials** — their credential helper, their SSH agent.
    /// Shepherd's GitHub token is for the API and is never handed to git (ADR 0011).
    /// - Parameter branch: The pull request's head branch.
    func push(toBranch branch: String) async throws {
        try await run(["push", "origin", "HEAD:\(branch)"], in: directory, label: "push")
    }

    // MARK: - Plumbing

    @discardableResult
    private func run(
        _ arguments: [String],
        in directory: URL,
        label: String
    ) async throws -> ProcessResult {
        let result = try await runner.run(
            executable: git,
            arguments: arguments,
            currentDirectory: directory
        )
        guard result.isSuccess else {
            let message = result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            throw Failure.commandFailed(
                command: label,
                status: result.status,
                message: String(message.prefix(400))
            )
        }
        return result
    }
}
