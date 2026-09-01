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

    /// Removes the worktree and prunes git's administrative record of it.
    ///
    /// Refuses any directory outside ``managedRoot`` — the path comes from settings the user
    /// can edit, and `git worktree remove --force` deletes files.
    func remove() async throws {
        try ensureManaged()
        try await run(
            ["worktree", "remove", "--force", directory.path],
            in: checkout,
            label: "worktree remove"
        )
        try await run(["worktree", "prune"], in: checkout, label: "worktree prune")
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
        return Snapshot(porcelain: result.trimmedOutput)
    }

    /// `git diff --stat HEAD` inside the worktree — what the reviewer reads before pushing.
    func diffStat() async throws -> String {
        try await run(["diff", "--stat", "HEAD"], in: directory, label: "diff").trimmedOutput
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
