import XCTest
@testable import ShepherdCore

final class AgentDetectorTests: XCTestCase {
    private let detector = AgentDetector(registry: Fixtures.testRegistry)

    // MARK: - Login signal

    func testExactBotLoginIsPromotedToAgent() {
        let kind = detector.detect(
            author: AuthorSignal(login: "claude[bot]", isBotAccount: true)
        )
        XCTAssertEqual(kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(kind.agentIdentity?.matchedBy, .login)
        XCTAssertEqual(kind.provenanceLabel, "Claude Code")
    }

    func testLoginMatchingIsCaseInsensitive() {
        let kind = detector.detect(author: AuthorSignal(login: "Claude[Bot]", isBotAccount: true))
        XCTAssertEqual(kind.agentIdentity?.id, "claude-code")
    }

    func testSquareBracketsInPatternsAreLiteralNotCharacterClasses() {
        // "claude[bot]" must not behave like a glob character class matching "claudeb".
        XCTAssertEqual(
            detector.detect(author: AuthorSignal(login: "claudeb", isBotAccount: true)),
            .bot
        )
    }

    func testUnknownBotStaysABot() {
        let kind = detector.detect(
            author: AuthorSignal(login: "some-other[bot]", isBotAccount: true)
        )
        XCTAssertEqual(kind, .bot)
    }

    func testPlainUserIsHuman() {
        let kind = detector.detect(author: AuthorSignal(login: "octocat", isBotAccount: false))
        XCTAssertEqual(kind, .human)
    }

    // MARK: - Branch and trailer signals

    func testBranchPrefixPromotesAHumanTokenRun() {
        // The agent ran with a human's token: the account is a person, the branch is not.
        let kind = detector.detect(
            author: AuthorSignal(login: "octocat", isBotAccount: false),
            branchName: "claude/fix-login"
        )
        XCTAssertEqual(kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(kind.agentIdentity?.matchedBy, .branchPrefix)
    }

    func testBranchPrefixMatchingIsCaseInsensitive() {
        let kind = detector.detect(
            author: AuthorSignal(login: "octocat"),
            branchName: "Claude/Fix-Login"
        )
        XCTAssertEqual(kind.agentIdentity?.id, "claude-code")
    }

    func testCommitTrailerPromotesAHumanTokenRun() {
        let kind = detector.detect(
            author: AuthorSignal(login: "octocat", isBotAccount: false),
            branchName: "fix/login",
            commitTrailers: ["Co-Authored-By: Claude <noreply@anthropic.com>"]
        )
        XCTAssertEqual(kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(kind.agentIdentity?.matchedBy, .commitTrailer)
    }

    func testUnrelatedTrailerDoesNotPromote() {
        let kind = detector.detect(
            author: AuthorSignal(login: "octocat"),
            commitTrailers: ["Signed-off-by: Someone <someone@example.com>"]
        )
        XCTAssertEqual(kind, .human)
    }

    // MARK: - Precedence

    func testLoginWinsOverBranch() {
        let kind = detector.detect(
            author: AuthorSignal(login: "dependabot[bot]", isBotAccount: true),
            branchName: "claude/whatever"
        )
        XCTAssertEqual(kind.agentIdentity?.id, "dependabot")
        XCTAssertEqual(kind.agentIdentity?.matchedBy, .login)
    }

    func testBranchWinsOverTrailer() {
        let kind = detector.detect(
            author: AuthorSignal(login: "octocat"),
            branchName: "dependabot/npm_and_yarn/foo-1.0.0",
            commitTrailers: ["Co-Authored-By: Claude"]
        )
        XCTAssertEqual(kind.agentIdentity?.id, "dependabot")
        XCTAssertEqual(kind.agentIdentity?.matchedBy, .branchPrefix)
    }

    func testDetectionIsDeterministic() {
        let signal = AuthorSignal(login: "claude[bot]", isBotAccount: true)
        let first = detector.detect(author: signal, branchName: "claude/x")
        let second = detector.detect(author: signal, branchName: "claude/x")
        XCTAssertEqual(first, second)
    }

    // MARK: - Registry extension

    func testUserExtensionAddsANewAgent() {
        let extended = Fixtures.testRegistry.merging(extensions: [
            AgentRegistryEntry(
                id: "acme-bot",
                displayName: "Acme Bot",
                loginPatterns: ["acme-*"],
                branchPrefixes: [],
                commitTrailers: []
            )
        ])
        let kind = AgentDetector(registry: extended)
            .detect(author: AuthorSignal(login: "acme-releaser", isBotAccount: true))
        XCTAssertEqual(kind.agentIdentity?.id, "acme-bot")
    }

    func testUserExtensionReplacesABundledEntryInPlace() {
        let extended = Fixtures.testRegistry.merging(extensions: [
            AgentRegistryEntry(
                id: "claude-code",
                displayName: "Claude (custom)",
                loginPatterns: ["my-claude"],
                branchPrefixes: [],
                commitTrailers: []
            )
        ])
        XCTAssertEqual(extended.agents.count, Fixtures.testRegistry.agents.count)
        XCTAssertEqual(extended.agents.first?.id, "claude-code")

        let detector = AgentDetector(registry: extended)
        XCTAssertEqual(
            detector.detect(author: AuthorSignal(login: "my-claude")).agentIdentity?.displayName,
            "Claude (custom)"
        )
        // The replaced pattern is gone.
        XCTAssertEqual(
            detector.detect(author: AuthorSignal(login: "claude[bot]", isBotAccount: true)),
            .bot
        )
    }

    // MARK: - Bundled registry

    func testBundledRegistryLoadsAndCoversTheDocumentedAgents() throws {
        let registry = try AgentRegistry.bundled()
        let ids = Set(registry.agents.map(\.id))
        for expected in [
            "claude-code", "github-copilot", "openai-codex", "devin", "cursor",
            "dependabot", "renovate", "github-actions",
        ] {
            XCTAssertTrue(ids.contains(expected), "registry is missing \(expected)")
        }
        XCTAssertFalse(registry.agents.contains { $0.displayName.isEmpty })
    }

    func testBundledRegistryDetectsTheHeadlineAgents() throws {
        let detector = try AgentDetector()
        let cases: [(String, String)] = [
            ("claude[bot]", "claude-code"),
            ("copilot-swe-agent[bot]", "github-copilot"),
            ("codex[bot]", "openai-codex"),
            ("devin-ai-integration[bot]", "devin"),
            ("cursoragent", "cursor"),
            ("dependabot[bot]", "dependabot"),
            ("renovate[bot]", "renovate"),
            ("github-actions[bot]", "github-actions"),
        ]
        for (login, expectedID) in cases {
            let kind = detector.detect(author: AuthorSignal(login: login, isBotAccount: true))
            XCTAssertEqual(kind.agentIdentity?.id, expectedID, "login \(login)")
        }
    }

    func testResolveActorKeepsLoginAndAvatar() {
        let url = URL(string: "https://avatars.example/1")
        let resolved = detector.resolveActor(
            author: AuthorSignal(
                login: "claude[bot]",
                isBotAccount: true,
                displayName: "Claude",
                avatarURL: url
            )
        )
        XCTAssertEqual(resolved.login, "claude[bot]")
        XCTAssertEqual(resolved.displayName, "Claude")
        XCTAssertEqual(resolved.avatarURL, url)
        XCTAssertEqual(resolved.kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(resolved.bestName, "Claude")
    }
}
