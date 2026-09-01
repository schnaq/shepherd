import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
@testable import ShepherdSync

/// A scripted stand-in for ``GitHubKit/GitHubClient``.
///
/// Records what the engine asked for so the delta logic can be asserted on directly: the
/// point of the sweep is that it *does not* fetch details for pull requests that did not
/// change.
actor MockGitHub: PullRequestFetching {
    /// One entry per sweep, consumed in order. The last entry repeats.
    var searchResults: [[PullRequestSummary]] = []
    /// Details keyed by `owner/name#number`; missing keys are synthesised from the summary.
    var details: [String: PullRequestDetail] = [:]
    /// Head SHAs keyed by `owner/name#number`.
    var headOids: [String: String] = [:]
    /// One entry per notifications poll. The last entry repeats.
    var notificationPages: [NotificationsPage] = []

    var searchError: GitHubError?
    var detailError: GitHubError?
    var submitError: GitHubError?
    var mergeError: GitHubError?

    private(set) var searchCallCount = 0
    private(set) var detailRequests: [String] = []
    private(set) var submittedDrafts: [ReviewDraft] = []
    private(set) var resolvedThreads: [String] = []
    private(set) var unresolvedThreads: [String] = []
    private(set) var replies: [(commentID: Int, body: String)] = []
    private(set) var merges: [(number: Int, method: MergeMethod, sha: String?)] = []
    private(set) var readyForReview: [String] = []
    private(set) var headOidRequests: [String] = []
    private(set) var notificationCallCount = 0

    private var lastSummaries: [PullRequestSummary] = []

    /// A latch the scripted calls can be parked on, so a test can hold one call suspended and
    /// drive a second one into the engine while the first is still in flight.
    private var gateIsClosed = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    // MARK: - Gate

    /// Makes the next gated call suspend until ``openGate()``.
    func closeGate() {
        gateIsClosed = true
    }

    /// Releases everything parked on the gate and lets later calls through.
    func openGate() {
        gateIsClosed = false
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// How many calls are currently parked. Tests poll this instead of sleeping.
    var gateWaiterCount: Int { gateWaiters.count }

    private func passGate() async {
        guard gateIsClosed else { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    // MARK: - Scripting

    func setSearchResults(_ results: [[PullRequestSummary]]) {
        searchResults = results
    }

    func setHeadOid(_ oid: String, repo: RepoRef, number: Int) {
        headOids["\(repo.fullName)#\(number)"] = oid
    }

    func setNotificationPages(_ pages: [NotificationsPage]) {
        notificationPages = pages
    }

    func setSearchError(_ error: GitHubError?) {
        searchError = error
    }

    func setSubmitError(_ error: GitHubError?) {
        submitError = error
    }

    func setMergeError(_ error: GitHubError?) {
        mergeError = error
    }

    func setDetailError(_ error: GitHubError?) {
        detailError = error
    }

    // MARK: - PullRequestFetching

    func searchOpenPullRequests(queries: [InboxQuery]) async throws -> [PullRequestSummary] {
        searchCallCount += 1
        await passGate()
        if let searchError { throw searchError }
        if searchResults.isEmpty { return lastSummaries }
        let result = searchResults.count > 1 ? searchResults.removeFirst() : searchResults[0]
        lastSummaries = result
        return result
    }

    func pullRequestDetail(repo: RepoRef, number: Int) async throws -> PullRequestDetail {
        let key = "\(repo.fullName)#\(number)"
        detailRequests.append(key)
        if let detailError { throw detailError }
        if let detail = details[key] { return detail }
        guard let summary = lastSummaries.first(where: {
            $0.repo == repo && $0.number == number
        }) else {
            throw GitHubError.notFound(resource: key)
        }
        return PullRequestDetail(summary: summary, bodyMarkdown: "synthesised")
    }

    func headRefOid(repo: RepoRef, number: Int) async throws -> String {
        let key = "\(repo.fullName)#\(number)"
        headOidRequests.append(key)
        return headOids[key] ?? "unknown-head"
    }

    func notifications(
        since: Date?,
        lastModified: String?,
        participating: Bool
    ) async throws -> NotificationsPage {
        notificationCallCount += 1
        if notificationPages.isEmpty { return NotificationsPage(items: []) }
        if notificationPages.count > 1 { return notificationPages.removeFirst() }
        return notificationPages[0]
    }

    func submitReview(
        _ draft: ReviewDraft,
        repo: RepoRef,
        number: Int
    ) async throws -> SubmittedReview {
        await passGate()
        if let submitError { throw submitError }
        submittedDrafts.append(draft)
        return SubmittedReview(id: 1, nodeId: "PRR_1", state: "APPROVED", commitID: nil)
    }

    func replyToComment(repo: RepoRef, number: Int, commentID: Int, body: String) async throws {
        replies.append((commentID: commentID, body: body))
    }

    func resolveThread(id: String) async throws {
        resolvedThreads.append(id)
    }

    func unresolveThread(id: String) async throws {
        unresolvedThreads.append(id)
    }

    func mergePullRequest(
        repo: RepoRef,
        number: Int,
        method: MergeMethod,
        expectedHeadOid: String?,
        commitTitle: String?
    ) async throws -> String? {
        if let mergeError { throw mergeError }
        merges.append((number: number, method: method, sha: expectedHeadOid))
        return "merged-sha"
    }

    func markReadyForReview(pullRequestID: String) async throws {
        readyForReview.append(pullRequestID)
    }
}

/// Collects the engine's events so a test can assert on them after the fact.
actor EventCollector {
    private(set) var events: [SyncEvent] = []

    func append(_ event: SyncEvent) {
        events.append(event)
    }
}

/// A ``ShepherdCore/Sleeping`` that gives the loops a bounded number of iterations: after
/// `allowedSleeps` waits it throws `CancellationError`, which both loops treat as "stop".
actor BoundedSleeper: Sleeping {
    private var remaining: Int
    private(set) var recorded: [Duration] = []

    init(allowedSleeps: Int) {
        self.remaining = allowedSleeps
    }

    func sleep(for duration: Duration) async throws {
        // Capped so a fast-spinning loop cannot grow the array without bound.
        if recorded.count < 500 {
            recorded.append(duration)
        }
        remaining -= 1
        if remaining < 0 {
            throw CancellationError()
        }
        await Task.yield()
    }

    /// The recorded waits expressed in seconds.
    var recordedSeconds: [Double] {
        recorded.map(\.inSeconds)
    }
}

enum SyncFixtures {
    static let repo = RepoRef(owner: "schnaq", name: "review")

    static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_788_162_000 + offset)
    }

    static func agent() -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: "claude[bot]",
            displayName: nil,
            avatarURL: nil,
            kind: .agent(
                AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
            )
        )
    }

    static func summary(
        id: String,
        number: Int,
        updatedAt: TimeInterval = 0,
        headRefOid: String = "head-1",
        relations: Set<Relation> = [.reviewRequested],
        checkState: CheckRollup.State? = nil,
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "PR \(number)",
            author: agent(),
            updatedAt: date(updatedAt),
            createdAt: date(-3_600),
            isDraft: false,
            additions: 10,
            deletions: 2,
            changedFiles: 1,
            headRefName: "claude/branch-\(number)",
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkRollup: checkState.map { CheckRollup(state: $0, total: 1) },
            myRelation: relations,
            labels: [],
            mergeable: .mergeable
        )
    }

    static func notification(
        id: String,
        reason: NotificationReason,
        number: Int = 1,
        type: String = "PullRequest"
    ) -> NotificationItem {
        NotificationItem(
            id: id,
            reason: reason,
            isUnread: true,
            updatedAt: date(0),
            subjectTitle: "PR \(number)",
            subjectType: type,
            repo: repo,
            pullRequestNumber: type == "PullRequest" ? number : nil
        )
    }
}
