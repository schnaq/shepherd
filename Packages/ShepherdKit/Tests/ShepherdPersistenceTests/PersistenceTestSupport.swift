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
