import Foundation
import ShepherdCore

/// Asks git what a folder the user picked is: a clone, and of which GitHub repository.
///
/// The first half of "Add a local repository…". Two reads and nothing else, both run *in* the
/// chosen folder through the same ``ProcessRunning`` seam and the same `/usr/bin/git` delegation
/// uses — no shell, no network, and nothing written:
///
/// 1. `git rev-parse --show-toplevel` — fails outside a work tree (a plain folder, a bare
///    repository), and otherwise names the clone's root, which is what gets linked. People pick a
///    subfolder often enough (`src/`, the folder the editor had open) that linking the pick
///    as-is would build every later worktree from the wrong place.
/// 2. `git remote get-url origin` — which repository the clone is of. A clone with no `origin`
///    exits non-zero, and that is a finding rather than a failure: the sheet then asks for the
///    name instead of guessing one.
///
/// What the URL *means* is ``ShepherdCore/GitRemote``'s decision, not this type's.
struct LocalRepositoryProbe: Sendable {
    /// What git said about the folder.
    enum Finding: Sendable, Equatable {
        /// Not inside a git work tree at all.
        case notAGitRepository
        /// A work tree, rooted at `root`, whose `origin` reads as `remote`.
        case repository(root: URL, remote: Remote)
    }

    /// What `origin` turned out to be.
    enum Remote: Sendable, Equatable {
        /// A repository on github.com.
        case github(RepoRef)
        /// A GitHub Enterprise host, which Shepherd does not talk to.
        case enterpriseHost(String)
        /// A host that is not GitHub.
        case otherHost(String)
        /// A URL Shepherd could not read a repository out of, redacted by
        /// ``ShepherdCore/GitRemote/redacted(_:)`` so it is safe to show.
        case unreadable(String)
        /// The clone has no `origin` remote.
        case none
    }

    /// The git binary.
    let git: URL
    /// The subprocess seam.
    let runner: any ProcessRunning

    /// Creates a probe.
    /// - Parameters:
    ///   - git: The git binary, `/usr/bin/git` by default — the one delegation uses.
    ///   - runner: The subprocess seam.
    init(
        git: URL = GitWorktree.defaultGitExecutable,
        runner: any ProcessRunning = SystemProcessRunner.shared
    ) {
        self.git = git
        self.runner = runner
    }

    /// Inspects a folder.
    /// - Parameter folder: What the user picked.
    /// - Returns: What it is.
    /// - Throws: Only when git itself could not be run — a Mac without the command line tools.
    func inspect(_ folder: URL) async throws -> Finding {
        let top = try await runner.run(
            executable: git,
            arguments: ["rev-parse", "--show-toplevel"],
            currentDirectory: folder
        )
        let rootPath = top.trimmedOutput
        guard top.isSuccess, !rootPath.isEmpty else { return .notAGitRepository }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        let origin = try await runner.run(
            executable: git,
            arguments: ["remote", "get-url", "origin"],
            currentDirectory: root
        )
        let url = origin.trimmedOutput
        guard origin.isSuccess, !url.isEmpty else {
            return .repository(root: root, remote: .none)
        }
        switch GitRemote.read(url) {
        case .github(let repo):
            return .repository(root: root, remote: .github(repo))
        case .enterpriseHost(let host):
            return .repository(root: root, remote: .enterpriseHost(host))
        case .otherHost(let host):
            return .repository(root: root, remote: .otherHost(host))
        case .unreadable:
            // Quoted back to the user by the sheet, so never with a credential in it.
            return .repository(root: root, remote: .unreadable(GitRemote.redacted(url)))
        }
    }
}
