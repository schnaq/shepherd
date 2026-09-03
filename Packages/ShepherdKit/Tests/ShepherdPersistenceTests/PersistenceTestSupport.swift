import Foundation
import ShepherdCore
@testable import ShepherdPersistence

/// Fixtures for the persistence tests.
///
/// Everything runs against an in-memory `DatabaseQueue`, which keeps the suite fast and makes
/// it behave identically on macOS and Linux.
enum PersistenceFixtures {
    static let repo = RepoRef(owner: "schnaq", name: "review")
    static let otherRepo = RepoRef(owner: "schnaq", name: "shepherd-web")

    static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_788_162_000 + offset)
    }

    static func agentActor() -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: "claude[bot]",
            displayName: "Claude",
            avatarURL: URL(string: "https://avatars.example/1"),
            kind: .agent(
                AgentIdentity(
                    id: "claude-code",
                    displayName: "Claude Code",
                    matchedBy: .login
                )
            )
        )
    }

    static func humanActor(_ login: String = "octocat") -> ShepherdCore.Actor {
        ShepherdCore.Actor(login: login, displayName: nil, avatarURL: nil, kind: .human)
    }

    static func summary(
        id: String = "PR_1",
        number: Int = 128,
        repo: RepoRef = PersistenceFixtures.repo,
        author: ShepherdCore.Actor = PersistenceFixtures.agentActor(),
        updatedAt: TimeInterval = 0,
        headRefOid: String = "abc123",
        relations: Set<Relation> = [.reviewRequested],
        checkRollup: CheckRollup? = CheckRollup(
            state: .failure,
            total: 3,
            successCount: 1,
            failureCount: 1,
            pendingCount: 1
        )
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Refactor the token store",
            author: author,
            updatedAt: date(updatedAt),
            createdAt: date(-3_600),
            isDraft: false,
            additions: 240,
            deletions: 96,
            changedFiles: 4,
            headRefName: "claude/refactor-token-store",
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: .changesRequested,
            checkRollup: checkRollup,
            myRelation: relations,
            labels: ["agent", "refactor"],
            mergeable: .mergeable
        )
    }

    static func detail(summary: PullRequestSummary = PersistenceFixtures.summary())
        -> PullRequestDetail {
        PullRequestDetail(
            summary: summary,
            bodyMarkdown: "Moves the Keychain wrapper behind a protocol.",
            commits: [
                CommitInfo(
                    oid: "1111111111111111111111111111111111111111",
                    messageHeadline: "refactor: hide the Keychain behind a protocol",
                    messageBody: "Co-Authored-By: Claude",
                    author: agentActor(),
                    committedDate: date(-1_800)
                )
            ],
            files: [
                ChangedFile(
                    path: "Sources/Auth/TokenStore.swift",
                    previousPath: nil,
                    status: .modified,
                    additions: 120,
                    deletions: 40,
                    patch: "@@ -1,3 +1,4 @@\n+protocol TokenStore {}",
                    isViewed: false
                ),
                ChangedFile(
                    path: "Sources/Auth/KeychainTokenStore.swift",
                    previousPath: "Sources/Auth/Keychain.swift",
                    status: .renamed,
                    additions: 100,
                    deletions: 50,
                    patch: nil,
                    isViewed: false
                ),
            ],
            threads: [
                ReviewThread(
                    id: "PRRT_1",
                    path: "Sources/Auth/TokenStore.swift",
                    line: 42,
                    side: .right,
                    isResolved: false,
                    isOutdated: false,
                    comments: [
                        ReviewComment(
                            id: "PRRC_1",
                            databaseID: 987_654_321,
                            author: humanActor(),
                            bodyMarkdown: "This should not force-unwrap.",
                            createdAt: date(-900),
                            pendingLocalID: nil
                        ),
                        ReviewComment(
                            id: "PRRC_2",
                            databaseID: 987_654_322,
                            author: agentActor(),
                            bodyMarkdown: "Fixed.",
                            createdAt: date(-600),
                            pendingLocalID: nil
                        ),
                    ]
                ),
                ReviewThread(
                    id: "PRRT_2",
                    path: "Sources/Auth/Keychain.swift",
                    line: 12,
                    side: .left,
                    isResolved: true,
                    isOutdated: true,
                    comments: []
                ),
            ],
            timeline: [
                TimelineEvent(
                    id: "commit:1111",
                    kind: .commit,
                    author: agentActor(),
                    createdAt: date(-1_800),
                    summary: "refactor: hide the Keychain behind a protocol"
                ),
                TimelineEvent(
                    id: "review:PRR_1",
                    kind: .reviewChangesRequested,
                    author: humanActor(),
                    createdAt: date(-900),
                    summary: "Requested changes"
                ),
            ],
            checks: [
                CheckRun(
                    id: "CR_1",
                    name: "ShepherdKit tests (macOS)",
                    status: .completed,
                    conclusion: .success,
                    detailsURL: URL(string: "https://github.com/schnaq/review/actions/runs/1"),
                    startedAt: date(-1_200),
                    completedAt: date(-1_000),
                    summary: "142 tests, 0 failures"
                ),
                CheckRun(
                    id: "CR_2",
                    name: "ShepherdKit tests (Linux)",
                    status: .completed,
                    conclusion: .failure,
                    detailsURL: nil,
                    startedAt: date(-1_200),
                    completedAt: date(-900),
                    summary: nil
                ),
            ]
        )
    }

    static func draft(prID: String = "PR_1", headRefOid: String = "abc123") -> ReviewDraft {
        // `draft_comments.localID` is the table's primary key, so two drafts sharing fixed
        // ids would silently steal each other's rows on save. Fresh ids per call keep drafts
        // for different pull requests independent, the way production comments are.
        ReviewDraft(
            prID: prID,
            verdict: .requestChanges,
            summaryBody: "Please fix the token handling.",
            comments: [
                DraftComment(
                    localID: UUID(),
                    path: "Sources/Auth/TokenStore.swift",
                    line: 42,
                    side: .right,
                    startLine: nil,
                    body: "Nit: rename this."
                ),
                DraftComment(
                    localID: UUID(),
                    path: "Sources/Auth/KeychainTokenStore.swift",
                    line: 20,
                    side: .left,
                    startLine: 15,
                    body: "This leaks the token."
                ),
            ],
            basedOnHeadOid: headRefOid,
            updatedAt: date(-60)
        )
    }
}

/// Fixtures for the track-record table (ADR 0027).
///
/// Its own namespace rather than more functions on ``PersistenceFixtures``: an outcome describes
/// a pull request that has *left* the inbox, so it shares none of that type's summary-shaped
/// defaults and would only be confusing beside them.
enum OutcomeFixtures {
    /// One closed pull request, ready to store.
    /// - Parameters:
    ///   - prID: The node id.
    ///   - number: The pull request number.
    ///   - repo: The repository.
    ///   - agentName: The agent's display name, or `nil` for a human.
    ///   - login: The author's login.
    ///   - title: The title, which revert detection matches on.
    ///   - merged: Whether it was merged.
    ///   - mergeCommitOid: The merge commit, which revert detection matches on.
    ///   - revertedBy: The node id of the pull request that reverted it.
    ///   - firstPushGreen: Whether the first push's checks were green.
    ///   - reviewRounds: How many reviews requested changes.
    ///   - changedLines: Added plus deleted lines.
    ///   - closedAt: The close time, as an offset from the fixture epoch.
    ///   - source: Which writer produced it.
    static func closed(
        prID: String,
        number: Int,
        repo: RepoRef = PersistenceFixtures.repo,
        agentName: String? = "Claude Code",
        login: String = "claude[bot]",
        title: String = "feat: something",
        merged: Bool,
        mergeCommitOid: String? = nil,
        revertedBy: String? = nil,
        firstPushGreen: Bool? = true,
        reviewRounds: Int = 1,
        changedLines: Int = 42,
        closedAt: TimeInterval = 0,
        source: PullRequestOutcomeSource = .backfill
    ) -> ClosedPullRequest {
        ClosedPullRequest(
            outcome: PullRequestOutcome(
                prID: prID,
                repo: repo,
                agentName: agentName,
                authorLogin: login,
                openedAt: PersistenceFixtures.date(closedAt - 3_600),
                closedAt: PersistenceFixtures.date(closedAt),
                merged: merged,
                revertedByPRID: revertedBy,
                firstPushCIGreen: firstPushGreen,
                reviewRounds: reviewRounds,
                changedLines: changedLines,
                source: source
            ),
            number: number,
            title: title,
            bodyMarkdown: "",
            mergeCommitOid: mergeCommitOid
        )
    }
}

/// Fixtures for the issues inbox (ADR 0032).
///
/// Its own namespace rather than more functions on ``PersistenceFixtures``: an issue row shares
/// none of that type's pull-request-shaped defaults — no head commit, no check rollup, no draft
/// state — and would only be confusing beside them.
enum IssueFixtures {
    /// A machine that opens pull requests, for the "has an agent pull request" facet.
    static func machineActor() -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: "dependabot[bot]",
            displayName: nil,
            avatarURL: URL(string: "https://avatars.example/2"),
            kind: .agent(
                AgentIdentity(id: "dependabot", displayName: "Dependabot", matchedBy: .login)
            )
        )
    }

    /// One linked pull request.
    /// - Parameters:
    ///   - number: The pull request number.
    ///   - repo: The repository it lives in — deliberately allowed to differ from the issue's.
    ///   - title: The title.
    ///   - state: GitHub's raw state string.
    ///   - author: The author, with detected provenance.
    static func link(
        number: Int,
        repo: RepoRef = PersistenceFixtures.repo,
        title: String = "fix: the timeout",
        state: String = "OPEN",
        author: ShepherdCore.Actor = PersistenceFixtures.humanActor()
    ) -> LinkedPullRequestReference {
        LinkedPullRequestReference(
            repo: repo,
            number: number,
            title: title,
            state: state,
            author: author
        )
    }

    /// One issue row.
    /// - Parameters:
    ///   - id: The node id.
    ///   - number: The issue number.
    ///   - repo: The repository.
    ///   - author: The author.
    ///   - createdAt: When it was opened, as an offset from the fixture epoch.
    ///   - updatedAt: When it was last updated, as an offset from the fixture epoch.
    ///   - state: Whether it is open or closed.
    ///   - relations: How the user relates to it.
    ///   - links: The pull requests that will close it.
    static func summary(
        id: String = "I_1",
        number: Int = 42,
        repo: RepoRef = PersistenceFixtures.repo,
        author: ShepherdCore.Actor = PersistenceFixtures.humanActor(),
        createdAt: TimeInterval = -3_600,
        updatedAt: TimeInterval = 0,
        state: IssueSummary.State = .open,
        relations: Set<IssueRelation> = [.assigned],
        links: [LinkedPullRequestReference] = []
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Login times out after the token refresh",
            author: author,
            createdAt: PersistenceFixtures.date(createdAt),
            updatedAt: PersistenceFixtures.date(updatedAt),
            closedAt: state == .closed ? PersistenceFixtures.date(updatedAt) : nil,
            state: state,
            stateReason: state == .closed ? "COMPLETED" : nil,
            labels: ["bug", "auth"],
            myRelation: relations,
            commentCount: 4,
            linkedPullRequests: links
        )
    }
}
