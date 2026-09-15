import Foundation
@testable import ShepherdCore

/// Small builders so the tests read as assertions rather than as object construction.
enum Fixtures {
    static let repo = RepoRef(owner: "schnaq", name: "review")

    static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_756_600_000 + offset)
    }

    static func makeActor(
        _ login: String,
        kind: ActorKind = .human
    ) -> ShepherdCore.Actor {
        ShepherdCore.Actor(login: login, displayName: nil, avatarURL: nil, kind: kind)
    }

    static func agent(_ id: String, _ displayName: String) -> ActorKind {
        .agent(AgentIdentity(id: id, displayName: displayName, matchedBy: .login))
    }

    static func summary(
        id: String,
        number: Int = 1,
        repo: RepoRef = Fixtures.repo,
        title: String = "Fix the thing",
        author: ShepherdCore.Actor = Fixtures.makeActor("octocat"),
        updatedAt: TimeInterval = 0,
        createdAt: TimeInterval = -3_600,
        isDraft: Bool = false,
        additions: Int = 10,
        deletions: Int = 2,
        changedFiles: Int = 3,
        headRefOid: String = "abc123",
        headRefName: String = "feature",
        reviewDecision: ReviewDecision? = nil,
        checkRollup: CheckRollup? = nil,
        relations: Set<Relation> = [],
        labels: [String] = [],
        mergeable: Mergeable? = .mergeable
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: author,
            updatedAt: date(updatedAt),
            createdAt: date(createdAt),
            isDraft: isDraft,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkRollup: checkRollup,
            myRelation: relations,
            labels: labels,
            mergeable: mergeable
        )
    }

    static func file(
        _ path: String,
        status: FileChangeStatus = .modified,
        additions: Int = 10,
        deletions: Int = 4,
        patch: String? = "@@ -1,3 +1,3 @@\n-old\n+new\n"
    ) -> ChangedFile {
        ChangedFile(
            path: path,
            previousPath: nil,
            status: status,
            additions: additions,
            deletions: deletions,
            patch: patch,
            isViewed: false
        )
    }

    /// The registry the detector tests run against — small, explicit, and independent of the
    /// bundled JSON so a registry edit cannot silently change the rules under test.
    static let testRegistry = AgentRegistry(
        agents: [
            AgentRegistryEntry(
                id: "claude-code",
                displayName: "Claude Code",
                loginPatterns: ["claude[bot]", "claude-code[bot]"],
                branchPrefixes: ["claude/"],
                commitTrailers: ["Co-Authored-By: Claude"]
            ),
            AgentRegistryEntry(
                id: "dependabot",
                displayName: "Dependabot",
                loginPatterns: ["dependabot[bot]"],
                branchPrefixes: ["dependabot/"],
                commitTrailers: []
            ),
        ]
    )
}
