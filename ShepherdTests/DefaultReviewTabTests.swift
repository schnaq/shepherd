import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// Which tab a review opens on (ADR 0026's amendment).
///
/// The rule is a pure `static` function for ``ReviewModel/defaultRoundView(for:)``'s reason —
/// so the four answers are asserted rather than inferred from task ordering — and this file is
/// its precedent's twin.
///
/// `@MainActor` because ``ReviewModel`` is: the rule is a `static` member of a main-actor class,
/// and reaching it from a nonisolated test is not allowed under Swift 6.
@MainActor
final class DefaultReviewTabTests: XCTestCase {
    private var createdSuites: [String] = []

    override func tearDown() {
        for name in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuites = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A description with a claim in it, of the shape agents write most often (ADR 0026).
    private let claiming = "Tests added for the error path.\n\nOnly `Sources/Parser/` changed."

    /// A description that asserts nothing checkable — the ordinary dependency bump.
    private let claimless = "Bumps the pinned toolchain from 1.2.3 to 1.2.4.\n\nSee the changelog."

    private func author(_ kind: ActorKind) -> ShepherdCore.Actor {
        ShepherdCore.Actor(login: "helper[bot]", displayName: "Helper", kind: kind)
    }

    /// A recognised coding agent. The registry id is deliberately a generic one: the rule is
    /// about *any* entry in the agent registry, not about a particular tool.
    private var agent: ActorKind {
        .agent(AgentIdentity(id: "coding-agent", displayName: "Coding Agent", matchedBy: .login))
    }

    private func detail(author kind: ActorKind, body: String) -> PullRequestDetail {
        PullRequestDetail(
            summary: PullRequestSummary(
                id: "PR_1",
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 7,
                title: "Fix the parser",
                author: author(kind),
                updatedAt: Date(timeIntervalSince1970: 2_000),
                createdAt: Date(timeIntervalSince1970: 1_000),
                headRefName: "fix/parser",
                headRefOid: "head-1",
                baseRefName: "main",
                myRelation: [.reviewRequested]
            ),
            bodyMarkdown: body
        )
    }

    private func makeSettings() -> AppSettings {
        let name = "com.schnaq.shepherd.tests.defaultTab.\(UUID().uuidString)"
        createdSuites.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("a fresh suite name always opens")
        }
        return AppSettings(defaults: defaults)
    }

    // MARK: - The rule

    func testAHumanPullRequestOpensOnFilesHoweverMuchItClaims() {
        XCTAssertEqual(
            ReviewModel.defaultTab(
                for: detail(author: .human, body: claiming),
                opensAgentPullRequestsOnConversation: true
            ),
            .files
        )
    }

    func testAnAgentPullRequestWithAClaimOpensOnConversation() {
        XCTAssertEqual(
            ReviewModel.defaultTab(
                for: detail(author: agent, body: claiming),
                opensAgentPullRequestsOnConversation: true
            ),
            .conversation
        )
    }

    func testAnAgentPullRequestWithNoClaimOpensOnFiles() {
        XCTAssertEqual(
            ReviewModel.defaultTab(
                for: detail(author: agent, body: claimless),
                opensAgentPullRequestsOnConversation: true
            ),
            .files
        )
    }

    func testAnAgentPullRequestWithNoDescriptionAtAllOpensOnFiles() {
        XCTAssertEqual(
            ReviewModel.defaultTab(
                for: detail(author: agent, body: ""),
                opensAgentPullRequestsOnConversation: true
            ),
            .files
        )
    }

    /// A bot that is not in the agent registry counts as a person, exactly as it does for the
    /// card's own collapsed/expanded default (ADR 0026).
    func testAnUnrecognisedBotCountsAsAPerson() {
        XCTAssertEqual(
            ReviewModel.defaultTab(
                for: detail(author: .bot, body: claiming),
                opensAgentPullRequestsOnConversation: true
            ),
            .files
        )
    }

    func testWithTheSettingOffEverythingOpensOnFiles() {
        for kind in [ActorKind.human, .bot, agent] {
            for body in [claiming, claimless] {
                XCTAssertEqual(
                    ReviewModel.defaultTab(
                        for: detail(author: kind, body: body),
                        opensAgentPullRequestsOnConversation: false
                    ),
                    .files
                )
            }
        }
    }

    /// The rule may never open a tab whose card is not there.
    ///
    /// Both halves read the same deterministic extractor, so this is a check that they still call
    /// the same one rather than two that happen to agree today: a claimless description produces
    /// an empty report — which is exactly what ``ClaimsEvidenceCardState/isHidden`` draws nothing
    /// for — and a claiming one produces the card the Conversation tab is being opened *for*.
    func testTheConversationDefaultAndTheCardAgreeOnWhatCounts() {
        let withClaims = detail(author: agent, body: claiming)
        let report = ClaimsEvidenceReport.build(
            detail: withClaims,
            summary: withClaims.summary
        )
        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(
            ReviewModel.defaultTab(for: withClaims, opensAgentPullRequestsOnConversation: true),
            .conversation
        )

        let withoutClaims = detail(author: agent, body: claimless)
        XCTAssertTrue(
            ClaimsEvidenceReport.build(
                detail: withoutClaims,
                summary: withoutClaims.summary
            ).isEmpty
        )
        XCTAssertEqual(
            ReviewModel.defaultTab(for: withoutClaims, opensAgentPullRequestsOnConversation: true),
            .files
        )
    }

    // MARK: - The setting

    func testTheSettingIsOnOutOfTheBoxAndSurvivesAWrite() {
        let settings = makeSettings()
        XCTAssertTrue(settings.opensAgentPullRequestsOnConversation)
        settings.opensAgentPullRequestsOnConversation = false
        XCTAssertFalse(settings.opensAgentPullRequestsOnConversation)
    }
}
