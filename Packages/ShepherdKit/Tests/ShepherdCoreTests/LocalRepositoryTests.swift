import XCTest
@testable import ShepherdCore

/// What "Add a local repository…" reads out of a clone's `origin`, and what it decides before
/// changing anything.
final class GitRemoteTests: XCTestCase {
    private let shepherd = RepoRef(owner: "schnaq", name: "shepherd")

    // MARK: - github.com, every spelling git writes

    func testReadsAnHTTPSRemote() {
        XCTAssertEqual(GitRemote.read("https://github.com/schnaq/shepherd"), .github(shepherd))
    }

    func testReadsAnHTTPSRemoteWithDotGit() {
        XCTAssertEqual(GitRemote.read("https://github.com/schnaq/shepherd.git"), .github(shepherd))
    }

    func testReadsAnHTTPSRemoteWithCredentialsInIt() {
        XCTAssertEqual(
            GitRemote.read("https://x-access-token@github.com/schnaq/shepherd.git"),
            .github(shepherd)
        )
    }

    func testReadsTheSCPLikeSSHRemote() {
        XCTAssertEqual(GitRemote.read("git@github.com:schnaq/shepherd.git"), .github(shepherd))
    }

    func testReadsTheSCPLikeSSHRemoteWithoutDotGit() {
        XCTAssertEqual(GitRemote.read("git@github.com:schnaq/shepherd"), .github(shepherd))
    }

    func testReadsAnSSHURLRemote() {
        XCTAssertEqual(GitRemote.read("ssh://git@github.com/schnaq/shepherd"), .github(shepherd))
    }

    func testReadsAnSSHURLRemoteWithAPort() {
        XCTAssertEqual(
            GitRemote.read("ssh://git@ssh.github.com:443/schnaq/shepherd.git"),
            .github(shepherd)
        )
    }

    func testIgnoresTrailingNewlineAndSlash() {
        XCTAssertEqual(GitRemote.read("https://github.com/schnaq/shepherd/\n"), .github(shepherd))
    }

    func testKeepsTheCasingTheRemoteHas() {
        XCTAssertEqual(
            GitRemote.read("git@GitHub.com:Schnaq/Shepherd.git"),
            .github(RepoRef(owner: "Schnaq", name: "Shepherd"))
        )
    }

    // MARK: - Refusals

    func testRecognisesAnEnterpriseHost() {
        XCTAssertEqual(
            GitRemote.read("git@github.example.com:team/app.git"),
            .enterpriseHost("github.example.com")
        )
        XCTAssertEqual(
            GitRemote.read("https://acme.ghe.com/team/app"),
            .enterpriseHost("acme.ghe.com")
        )
    }

    func testRecognisesAnotherHost() {
        XCTAssertEqual(GitRemote.read("git@gitlab.com:team/app.git"), .otherHost("gitlab.com"))
        XCTAssertEqual(
            GitRemote.read("https://bitbucket.org/team/app.git"),
            .otherHost("bitbucket.org")
        )
    }

    func testDoesNotLetAPathPretendToBeGitHub() {
        XCTAssertEqual(
            GitRemote.read("https://evil.com/github.com/a/b"),
            .otherHost("evil.com")
        )
    }

    func testRefusesALocalPath() {
        XCTAssertEqual(GitRemote.read("/srv/git/app.git"), .unreadable)
        XCTAssertEqual(GitRemote.read("./a:b"), .unreadable)
        XCTAssertEqual(GitRemote.read(""), .unreadable)
    }

    func testRefusesAGitHubPathThatIsNotOwnerAndName() {
        XCTAssertEqual(GitRemote.read("https://github.com/schnaq"), .unreadable)
        XCTAssertEqual(GitRemote.read("https://github.com/a/b/c"), .unreadable)
        XCTAssertEqual(GitRemote.read("git@github.com:a b/c"), .unreadable)
    }
}

/// How a free-text task becomes a branch name.
final class RepositoryTaskBranchTests: XCTestCase {
    func testLowercasesAndDashes() {
        XCTAssertEqual(
            RepositoryTaskBranch.slug(from: "Fix the flaky Login test!"),
            "fix-the-flaky-login-test"
        )
    }

    func testReadsOnlyTheFirstNonEmptyLine() {
        XCTAssertEqual(
            RepositoryTaskBranch.slug(from: "\n  \nAdd dark mode\nMore detail here"),
            "add-dark-mode"
        )
    }

    func testKeepsTheBaseLetterOfAnAccent() {
        XCTAssertEqual(RepositoryTaskBranch.slug(from: "Übersetzung prüfen"), "ubersetzung-prufen")
    }

    func testCollapsesRunsAndTrimsEdges() {
        XCTAssertEqual(RepositoryTaskBranch.slug(from: "  --a   //  b__c--  "), "a-b-c")
    }

    func testIsNeverLongerThanTheLimitAndCutsAtAWord() {
        let slug = RepositoryTaskBranch.slug(
            from: "Refactor the settings synchronisation layer so that every group round-trips"
        )
        XCTAssertLessThanOrEqual(slug.count, RepositoryTaskBranch.maximumSlugLength)
        XCTAssertEqual(slug, "refactor-the-settings-synchronisation")
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func testFallsBackWhenNothingIsUsable() {
        XCTAssertEqual(RepositoryTaskBranch.slug(from: "???"), "task")
        XCTAssertEqual(RepositoryTaskBranch.slug(from: ""), "task")
        XCTAssertEqual(RepositoryTaskBranch.slug(from: "Проверка"), "task")
    }

    func testBranchNameIsInTheAgentNamespace() {
        XCTAssertEqual(RepositoryTaskBranch.branchName(slug: "add-dark-mode"), "agent/add-dark-mode")
    }

    func testAFreeSlugIsKept() {
        let unique = RepositoryTaskBranch.unique("add-dark-mode", isTaken: { _ in false }, suffix: { "beef" })
        XCTAssertEqual(unique, "add-dark-mode")
    }

    func testATakenSlugGetsASuffix() {
        let unique = RepositoryTaskBranch.unique(
            "add-dark-mode",
            isTaken: { $0 == "add-dark-mode" },
            suffix: { "beef" }
        )
        XCTAssertEqual(unique, "add-dark-mode-beef")
    }

    func testASuffixedSlugStaysWithinTheLimit() {
        let long = String(repeating: "a", count: RepositoryTaskBranch.maximumSlugLength)
        let unique = RepositoryTaskBranch.unique(long, isTaken: { $0 == long }, suffix: { "beef" })
        XCTAssertEqual(unique?.count, RepositoryTaskBranch.maximumSlugLength)
        XCTAssertEqual(unique?.hasSuffix("-beef"), true)
    }

    func testGivesUpInsteadOfLoopingForever() {
        XCTAssertNil(RepositoryTaskBranch.unique("x", isTaken: { _ in true }, suffix: { "beef" }))
    }

    func testRandomSuffixIsFourHexDigits() {
        let suffix = RepositoryTaskBranch.randomSuffix()
        XCTAssertEqual(suffix.count, 4)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

/// What "Add a local repository…" finds already done.
final class LocalRepositoryLinkTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "shepherd")

    private func state(
        watched: [RepoRef] = [],
        checkouts: [String: String] = [:],
        path: String = "/Users/me/code/shepherd",
        maximum: Int = 10
    ) -> LocalRepositoryLink {
        LocalRepositoryLink.state(
            repo: repo,
            path: path,
            watched: watched,
            checkouts: checkouts,
            maximumWatched: maximum
        )
    }

    func testAFreshRepositoryHasBothHalvesToDo() {
        XCTAssertEqual(state(), LocalRepositoryLink(checkout: .unlinked, watch: .notWatched))
        XCTAssertFalse(state().isComplete)
    }

    func testTheSameFolderIsAlreadyLinkedIgnoringCaseAndATrailingSlash() {
        let result = state(checkouts: ["Schnaq/Shepherd": "/Users/me/code/shepherd/"])
        XCTAssertEqual(result.checkout, .linkedHere)
    }

    func testAnotherFolderIsReportedWithItsPath() {
        let result = state(checkouts: ["schnaq/shepherd": "/Volumes/old/shepherd"])
        XCTAssertEqual(result.checkout, .linkedElsewhere(path: "/Volumes/old/shepherd"))
    }

    func testAnEmptyPathCountsAsUnlinked() {
        XCTAssertEqual(state(checkouts: ["schnaq/shepherd": "  "]).checkout, .unlinked)
    }

    func testAWatchedRepositoryIsRecognisedIgnoringCase() {
        let result = state(watched: [RepoRef(owner: "SCHNAQ", name: "shepherd")])
        XCTAssertEqual(result.watch, .watched)
    }

    func testAFullWatchListIsReported() {
        let others = (0..<3).map { RepoRef(owner: "o", name: "r\($0)") }
        XCTAssertEqual(state(watched: others, maximum: 3).watch, .listFull)
    }

    func testAWatchedRepositoryOnAFullListIsStillJustWatched() {
        let list = [repo, RepoRef(owner: "o", name: "r")]
        XCTAssertEqual(state(watched: list, maximum: 2).watch, .watched)
    }

    func testCompleteWhenBothAreDone() {
        let result = state(
            watched: [repo],
            checkouts: ["schnaq/shepherd": "/Users/me/code/shepherd"]
        )
        XCTAssertTrue(result.isComplete)
    }
}

/// What of a remote URL may be shown, and how case variants of one repository are collapsed.
final class LocalRepositoryHygieneTests: XCTestCase {
    func testRedactionDropsCredentialsQueryAndFragment() {
        XCTAssertEqual(
            GitRemote.redacted("https://me:ghp_secret@github.com/a b/c?x=1#y"),
            "https://github.com/a b/c"
        )
        XCTAssertEqual(
            GitRemote.redacted("https://ghp_token@example.com/team/app"),
            "https://example.com/team/app",
            "a username alone can be a token"
        )
    }

    func testRedactionLeavesCredentialFreeURLsAlone() {
        XCTAssertEqual(GitRemote.redacted("git@github.com:a/b.git"), "git@github.com:a/b.git")
        XCTAssertEqual(GitRemote.redacted("/srv/git/app.git\n"), "/srv/git/app.git")
        XCTAssertEqual(
            GitRemote.redacted("https://github.com/a/b/c@d"),
            "https://github.com/a/b/c@d",
            "an @ in the path is not userinfo"
        )
    }

    func testCaseVariantsCollapseToOneStableEntry() {
        let collapsed = LocalRepositoryLink.collapsingCaseVariants([
            "schnaq/review": "/b",
            "Schnaq/Review": "/a",
            "other/repo": "/c",
        ])
        XCTAssertEqual(collapsed, ["Schnaq/Review": "/a", "other/repo": "/c"])
    }

    func testAPathBeatsAnEmptyVariant() {
        let collapsed = LocalRepositoryLink.collapsingCaseVariants([
            "Schnaq/Review": "  ",
            "schnaq/review": "/b",
        ])
        XCTAssertEqual(collapsed, ["schnaq/review": "/b"])
    }

    func testAMapWithoutVariantsIsUnchanged() {
        let map = ["a/b": "/x", "c/d": "/y"]
        XCTAssertEqual(LocalRepositoryLink.collapsingCaseVariants(map), map)
    }
}
