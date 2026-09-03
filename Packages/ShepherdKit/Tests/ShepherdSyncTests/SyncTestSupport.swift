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

    /// Scripts the detail one pull request comes back with, instead of the synthesised one.
    func setDetail(_ detail: PullRequestDetail, repo: RepoRef, number: Int) {
        details["\(repo.fullName)#\(number)"] = detail
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

/// A counting stand-in for the interdiff's baseline store (ADR 0028).
///
/// The real store is `DatabaseManager`, which the drain tests already use as their `store`;
/// this one is here so a test can assert *what the drain asked for* — the pull request, the
/// head, and how often — without reading SQLite back.
actor FakeReviewSnapshotWriter: ReviewSnapshotWriting {
    /// Every capture the engine asked for, in order.
    private(set) var captures: [(prID: String, head: String, reviewedAt: Date)] = []
    /// The heads that already have a baseline.
    private var existing: Set<String> = []
    /// What ``captureReviewSnapshot(prID:reviewedHeadOid:reviewedAt:)`` reports back.
    private var result = true

    init(existing: [(prID: String, head: String)] = [], result: Bool = true) {
        for entry in existing { self.existing.insert("\(entry.prID):\(entry.head)") }
        self.result = result
    }

    func hasReviewSnapshot(prID: String, reviewedHeadOid: String) async throws -> Bool {
        existing.contains("\(prID):\(reviewedHeadOid)")
    }

    func captureReviewSnapshot(
        prID: String,
        reviewedHeadOid: String,
        reviewedAt: Date
    ) async throws -> Bool {
        captures.append((prID: prID, head: reviewedHeadOid, reviewedAt: reviewedAt))
        existing.insert("\(prID):\(reviewedHeadOid)")
        return result
    }
}

/// A recording stand-in for the track record's two ports (ADR 0027).
///
/// One double for both halves rather than two, because every test that cares asserts on the
/// *pair*: what the engine read, and what it then stored. It also keeps the interesting
/// scripting in one place — how many pages a repository has, and which pull request the read
/// refuses.
actor FakeOutcomeStore: OutcomeRecording, ClosedPullRequestReading {
    /// The rows on disk, keyed by node id.
    private(set) var stored: [String: ClosedPullRequest] = [:]
    /// Every `closedPullRequest(repo:number:)` the engine made, in order.
    private(set) var singleReads: [String] = []
    /// Every `searchClosedPullRequests` the pager made, as `repo|cursor`.
    private(set) var pageReads: [String] = []
    /// The links that were applied, merged.
    private(set) var links: [String: String] = [:]

    /// What the single read answers with, keyed by `owner/name#number`. A missing key answers
    /// `nil`, which is the "it is still open" case.
    private var singleResults: [String: ClosedPullRequest] = [:]
    /// The pages one repository answers with, in order, keyed by `owner/name`.
    private var pages: [String: [ClosedPullRequestPage]] = [:]
    private var readError: GitHubError?

    init() {}

    // MARK: - Scripting

    func setSingleResult(_ closed: ClosedPullRequest?, repo: RepoRef, number: Int) {
        let key = "\(repo.fullName)#\(number)"
        if let closed {
            singleResults[key] = closed
        } else {
            singleResults.removeValue(forKey: key)
        }
    }

    func setPages(_ pages: [ClosedPullRequestPage], repo: RepoRef) {
        self.pages[repo.fullName] = pages
    }

    func setReadError(_ error: GitHubError?) {
        readError = error
    }

    // MARK: - OutcomeRecording

    func hasPullRequestOutcome(prID: String) async throws -> Bool {
        stored[prID] != nil
    }

    func savePullRequestOutcomes(_ closed: [ClosedPullRequest]) async throws -> Int {
        for entry in closed {
            stored[entry.outcome.prID] = entry
        }
        return closed.count
    }

    func mergedClosedPullRequests(
        repo: RepoRef,
        since: Date
    ) async throws -> [ClosedPullRequest] {
        stored.values
            .filter {
                $0.outcome.merged
                    && $0.outcome.repo.isSameRepository(as: repo)
                    && $0.outcome.closedAt >= since
            }
            .sorted { $0.outcome.closedAt < $1.outcome.closedAt }
    }

    func applyRevertLinks(_ links: [String: String]) async throws -> Int {
        var applied = 0
        for (target, reverting) in links where stored[target]?.outcome.merged == true {
            self.links[target] = reverting
            stored[target]?.outcome.revertedByPRID = reverting
            applied += 1
        }
        return applied
    }

    // MARK: - ClosedPullRequestReading

    func closedPullRequest(repo: RepoRef, number: Int) async throws -> ClosedPullRequest? {
        singleReads.append("\(repo.fullName)#\(number)")
        if let readError { throw readError }
        return singleResults["\(repo.fullName)#\(number)"]
    }

    func searchClosedPullRequests(
        repo: RepoRef,
        since: Date,
        cursor: String?,
        pageSize: Int
    ) async throws -> ClosedPullRequestPage {
        pageReads.append("\(repo.fullName)|\(cursor ?? "-")")
        if let readError { throw readError }
        var remaining = pages[repo.fullName] ?? []
        guard !remaining.isEmpty else {
            return ClosedPullRequestPage(pullRequests: [], totalCount: 0)
        }
        let page = remaining.removeFirst()
        pages[repo.fullName] = remaining
        return page
    }
}

extension SyncFixtures {
    /// One closed pull request, for the track record's tests.
    static func closed(
        prID: String,
        number: Int,
        repo: RepoRef = SyncFixtures.repo,
        title: String = "feat: something",
        body: String = "",
        merged: Bool = true,
        mergeCommitOid: String? = nil,
        closedAt: TimeInterval = 0
    ) -> ClosedPullRequest {
        ClosedPullRequest(
            outcome: PullRequestOutcome(
                prID: prID,
                repo: repo,
                agentName: "Claude Code",
                authorLogin: "claude[bot]",
                openedAt: SyncFixtures.date(closedAt - 3_600),
                closedAt: SyncFixtures.date(closedAt),
                merged: merged,
                firstPushCIGreen: true,
                reviewRounds: 1,
                changedLines: 42,
                source: .backfill
            ),
            number: number,
            title: title,
            bodyMarkdown: body,
            mergeCommitOid: mergeCommitOid
        )
    }
}

/// A scripted stand-in for the issues half of ``GitHubKit/GitHubClient`` (ADR 0032).
///
/// Its own double rather than more scripting on ``MockGitHub``, mirroring the port split: the
/// issues sweep hangs off ``IssueFetching``, so only the tests that care about it have to satisfy
/// anything. It records the facet strings it was asked for, because "the same connection with one
/// word changed" is a claim worth asserting from the engine's side too.
actor MockIssueGitHub: IssueFetching {
    /// One entry per sweep, consumed in order. The last entry repeats.
    private var results: [[IssueRowSummary]] = []
    private var error: GitHubError?
    private var last: [IssueRowSummary] = []

    /// How many sweeps the engine ran.
    private(set) var callCount = 0
    /// The raw query strings of every sweep, in order.
    private(set) var requestedQueries: [[String]] = []

    init() {}

    func setResults(_ results: [[IssueRowSummary]]) {
        self.results = results
    }

    func setError(_ error: GitHubError?) {
        self.error = error
    }

    func searchOpenIssues(queries: [IssueQuery]) async throws -> [IssueRowSummary] {
        callCount += 1
        requestedQueries.append(queries.map(\.rawQuery))
        if let error { throw error }
        if results.isEmpty { return last }
        let result = results.count > 1 ? results.removeFirst() : results[0]
        last = result
        return result
    }
}

/// A scripted stand-in for the issue-write half of ``GitHubKit/GitHubClient`` (ADR 0032's
/// Sprint 4a amendment).
///
/// Its own double rather than more scripting on ``MockGitHub`` or on ``MockIssueGitHub``,
/// mirroring the port split a third time: only a test that queues an issue write has to satisfy
/// ``IssueWriting``. It records the probe separately from the writes, because "nothing was sent"
/// and "nothing was even asked" are the two different failures the precondition can have.
actor MockIssueWriter: IssueWriting {
    /// One comment the drain posted.
    struct Comment: Equatable {
        var repo: RepoRef
        var number: Int
        var body: String
    }

    /// One state change the drain sent.
    struct StateChange: Equatable {
        var repo: RepoRef
        var number: Int
        var state: String
        var stateReason: String?
    }

    private var state: IssueState?
    private var probeError: GitHubError?

    /// `owner/name#number` for every probe, in order.
    private(set) var probes: [String] = []
    private(set) var comments: [Comment] = []
    private(set) var labels: [[String]] = []
    private(set) var assignees: [[String]] = []
    private(set) var stateChanges: [StateChange] = []

    init() {}

    /// Scripts what the probe answers with.
    func setState(updatedAt: Date, isClosed: Bool = false) {
        state = IssueState(id: "I_1", updatedAt: updatedAt, isClosed: isClosed)
    }

    /// Scripts a probe that cannot be made at all — the offline case.
    func setProbeError(_ error: GitHubError?) {
        probeError = error
    }

    func issueState(repo: RepoRef, number: Int) async throws -> IssueState {
        probes.append("\(repo.fullName)#\(number)")
        if let probeError { throw probeError }
        guard let state else {
            throw GitHubError.notFound(resource: "\(repo.fullName)#\(number)")
        }
        return state
    }

    func addIssueComment(repo: RepoRef, number: Int, body: String) async throws {
        comments.append(Comment(repo: repo, number: number, body: body))
    }

    func addIssueLabels(repo: RepoRef, number: Int, labels newLabels: [String]) async throws {
        labels.append(newLabels)
    }

    func addIssueAssignees(repo: RepoRef, number: Int, logins: [String]) async throws {
        assignees.append(logins)
    }

    func setIssueState(
        repo: RepoRef,
        number: Int,
        state newState: String,
        stateReason: String?
    ) async throws {
        stateChanges.append(
            StateChange(repo: repo, number: number, state: newState, stateReason: stateReason)
        )
    }

    /// Whether the drain sent anything at all.
    var sentAnything: Bool {
        !comments.isEmpty || !labels.isEmpty || !assignees.isEmpty || !stateChanges.isEmpty
    }
}

extension SyncFixtures {
    /// A machine that opens pull requests, for the "has an agent pull request" facet.
    static func machine() -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: "dependabot[bot]",
            displayName: nil,
            avatarURL: nil,
            kind: .agent(
                AgentIdentity(id: "dependabot", displayName: "Dependabot", matchedBy: .login)
            )
        )
    }

    /// One issue row, for the issues sweep's tests.
    /// - Parameters:
    ///   - id: The node id.
    ///   - number: The issue number.
    ///   - updatedAt: When it was last updated, as an offset from the fixture epoch.
    ///   - relations: How the user relates to it.
    ///   - links: The pull requests that will close it.
    static func issue(
        id: String,
        number: Int,
        updatedAt: TimeInterval = 0,
        relations: Set<IssueRelation> = [.assigned],
        links: [LinkedPullRequestReference] = []
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Issue \(number)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: date(-3_600),
            updatedAt: date(updatedAt),
            state: .open,
            labels: ["bug"],
            myRelation: relations,
            commentCount: 1,
            linkedPullRequests: links
        )
    }

    /// One linked pull request, machine-authored by default so the facet has something to read.
    static func link(
        number: Int,
        author: ShepherdCore.Actor = SyncFixtures.machine()
    ) -> LinkedPullRequestReference {
        LinkedPullRequestReference(
            repo: repo,
            number: number,
            title: "fix: issue \(number)",
            state: "OPEN",
            author: author
        )
    }
}
