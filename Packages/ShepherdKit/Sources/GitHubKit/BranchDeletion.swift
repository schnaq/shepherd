import Foundation
import ShepherdCore

/// The three facts that decide whether a merged pull request's head branch may be deleted
/// (ADR 0005's 2026-09-05 amendment).
///
/// It exists because none of them is anywhere else. A merge row in the outbox names a repository
/// and a number and nothing more, ``ShepherdCore/PullRequestSummary`` carries the branch *name*
/// but says nothing about which repository the branch lives in, and no part of Shepherd has ever
/// needed to know a repository's default branch. The drain therefore reads all three at the
/// moment it is about to delete something, from one small query, rather than deciding from a
/// cached row that may be minutes old — a deletion is not undoable and is worth one request.
///
/// Every field is optional on purpose: a `nil` is "GitHub did not tell us", and the drain treats
/// an unanswerable guard as a refusal rather than as permission.
public struct HeadBranchContext: Sendable, Hashable {
    /// The head branch's name, exactly as git spells it — slashes and all.
    public var headRefName: String?
    /// `owner/name` of the repository the head branch lives in, or `nil` when GitHub no longer
    /// has it (a fork that was deleted along with the merge).
    public var headRepositoryFullName: String?
    /// The base repository's default branch, which is the one branch a merge may never delete.
    public var defaultBranchName: String?

    /// Creates a context.
    /// - Parameters:
    ///   - headRefName: The head branch's name.
    ///   - headRepositoryFullName: `owner/name` of the repository holding the head branch.
    ///   - defaultBranchName: The base repository's default branch.
    public init(
        headRefName: String? = nil,
        headRepositoryFullName: String? = nil,
        defaultBranchName: String? = nil
    ) {
        self.headRefName = headRefName
        self.headRepositoryFullName = headRepositoryFullName
        self.defaultBranchName = defaultBranchName
    }

    /// The branch to delete in `repo`, or `nil` when it must not be deleted.
    ///
    /// A pure function so the two guards can be read — and tested — without a network at all,
    /// exactly as ``IssueState/isStale(against:)`` is. Both are refusals rather than errors:
    ///
    /// - **A fork's branch is not ours.** The head branch of a cross-repository pull request
    ///   lives in somebody else's repository, and `DELETE` on the *base* repository's refs would
    ///   either miss or, worse, hit a branch of the same name that belongs to somebody's work in
    ///   progress.
    /// - **The default branch is never a leftover.** A pull request from `main` into a release
    ///   branch is an ordinary thing to open, and merging it must not delete the repository's
    ///   trunk.
    /// - Parameter repo: The repository the merge was made in — the *base* repository.
    /// - Returns: The head branch's name when both guards pass and GitHub answered all three
    ///   questions, `nil` otherwise.
    public func deletableBranch(in repo: RepoRef) -> String? {
        guard let headRefName, !headRefName.isEmpty else { return nil }
        guard let headRepositoryFullName,
              headRepositoryFullName.caseInsensitiveCompare(repo.fullName) == .orderedSame
        else { return nil }
        // Branch names are case-sensitive in git, so this comparison is too — unlike the
        // repository one above, which compares two of GitHub's own case-insensitive slugs.
        guard let defaultBranchName, headRefName != defaultBranchName else { return nil }
        return headRefName
    }
}
