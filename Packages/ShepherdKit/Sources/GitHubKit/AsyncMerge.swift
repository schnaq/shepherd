import Foundation

/// GitHub's answer to an asynchronous merge (ADR 0042): `PUT …/pulls/{n}/merge-async` and
/// `GET …/pulls/{n}/merge-async/{uuid}` report the same shape.
///
/// The asynchronous API exists for stacks: merging a stacked pull request merges every pull
/// request below it too, atomically, and GitHub does that work in the background. The answer says
/// how far it got at the moment it was given.
///
/// `details` comes in three documented shapes — the full one with a `uuid`, `{message}` alone, and
/// `{message, sha}` for a pull request that is merged already — so every field but ``status`` is
/// optional here.
public struct AsyncMergeResult: Sendable, Hashable {
    /// How far an asynchronous merge got.
    public enum Status: String, Sendable, Hashable, CaseIterable {
        /// Accepted and still running.
        case pending
        /// Merged, the pull requests below it in the stack included.
        case merged
        /// Added to the repository's merge queue.
        case enqueued
        /// GitHub gave up; ``AsyncMergeResult/message`` says why.
        case failed
    }

    /// How far the merge got.
    public var status: Status
    /// The id to poll the status by. Absent from the short answers.
    public var uuid: String?
    /// GitHub's sentence about the merge.
    public var message: String?
    /// The merge method GitHub is using.
    public var mergeMethod: String?
    /// The action GitHub is taking (`default`, `direct_merge`, `merge_queue`).
    public var mergeAction: String?
    /// The head the merge is pinned to.
    public var expectedHeadSha: String?
    /// The merge commit, on an answer for a pull request that is merged already.
    public var sha: String?

    /// Creates a result.
    public init(
        status: Status,
        uuid: String? = nil,
        message: String? = nil,
        mergeMethod: String? = nil,
        mergeAction: String? = nil,
        expectedHeadSha: String? = nil,
        sha: String? = nil
    ) {
        self.status = status
        self.uuid = uuid
        self.message = message
        self.mergeMethod = mergeMethod
        self.mergeAction = mergeAction
        self.expectedHeadSha = expectedHeadSha
        self.sha = sha
    }
}

/// The wire shape of ``AsyncMergeResult``.
struct RESTAsyncMergeDTO: Decodable {
    struct Details: Decodable {
        var message: String?
        var uuid: String?
        var mergeMethod: String?
        var mergeAction: String?
        var expectedHeadSha: String?
        var sha: String?
    }
    var status: String
    var details: Details?

    /// The model value. A status word this build does not know reads as `pending`: by the time
    /// the answer is read GitHub has accepted the merge, and failing to decode it would report a
    /// merge that is running as one that never happened. "Still running" is the reading that
    /// leaves the verdict to the next sweep, which is where it lands anyway.
    var model: AsyncMergeResult {
        AsyncMergeResult(
            status: AsyncMergeResult.Status(rawValue: status.lowercased()) ?? .pending,
            uuid: details?.uuid,
            message: details?.message,
            mergeMethod: details?.mergeMethod,
            mergeAction: details?.mergeAction,
            expectedHeadSha: details?.expectedHeadSha,
            sha: details?.sha
        )
    }
}

/// The body of `PUT /repos/{owner}/{repo}/pulls/{number}/merge-async`. A `nil` SHA is omitted
/// rather than sent as a null; `merge_action` is never sent, so GitHub takes its default — the
/// merge queue where the repository has one — which is what a Merge press means.
struct AsyncMergeBody: Encodable {
    var sha: String?
    var mergeMethod: String
}
