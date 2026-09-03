import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of the session back-channel (ADR 0030): which button a finding gets, what the
/// confirmation sheet is handed, what argv the resume command becomes, and what a send is
/// deliberately *not*.
///
/// The parser and the message composer are `ShepherdCore`'s and are tested on Linux. Everything
/// here is a decision the app makes with them — and all of it is a value, because the two
/// composers own no state of their own beyond the sheet's `isPresented` flag.
@MainActor
final class SessionBackChannelTests: XCTestCase {
    private let worktree = URL(fileURLWithPath: "/tmp/shepherd/wt")
    private let claude = URL(fileURLWithPath: "/opt/homebrew/bin/claude")

    private let local = SessionReference(id: "session_01abc", kind: .local)
    private let remote = SessionReference(
        id: "session_01abc",
        url: URL(string: "https://claude.ai/code/session_01abc"),
        host: "claude.ai",
        kind: .remote
    )

    private func summary() -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Fix the off-by-one",
            author: ShepherdCore.Actor(
                login: "claude[bot]",
                kind: .agent(
                    AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
                )
            ),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            createdAt: Date(timeIntervalSince1970: 1_000),
            headRefName: "claude/fix",
            headRefOid: "0123456789abcdef",
            baseRefName: "main"
        )
    }

    // MARK: - Which button, if any

    func testNoReturnAddressMeansNoButton() {
        XCTAssertNil(
            SessionBackChannel.action(session: nil, configuration: AgentCLIConfiguration())
        )
    }

    func testALocalSessionGetsTheSendButtonOutOfTheBox() {
        XCTAssertEqual(
            SessionBackChannel.action(session: local, configuration: AgentCLIConfiguration()),
            .send(local)
        )
    }

    func testARemoteSessionOffersItsLinkUntilACommandIsConfigured() {
        var configuration = AgentCLIConfiguration()
        // The shipped state: no remote command, so the button links to the session.
        XCTAssertTrue(configuration.remoteSessionTemplate.isEmpty)
        guard let url = remote.url else { return XCTFail("the fixture has no URL") }
        XCTAssertEqual(
            SessionBackChannel.action(session: remote, configuration: configuration),
            .open(remote, url)
        )

        configuration.remoteSessionTemplate = "/usr/local/bin/agent remote {sessionURL} {message}"
        XCTAssertEqual(
            SessionBackChannel.action(session: remote, configuration: configuration),
            .send(remote)
        )
    }

    func testALocalSessionWithTheCommandClearedAndNoURLGetsNothing() {
        var configuration = AgentCLIConfiguration()
        configuration.sessionResumeTemplate = "   "
        XCTAssertNil(SessionBackChannel.action(session: local, configuration: configuration))
    }

    // MARK: - The plan the sheet and the run share

    func testThePlanComposesTheMessageOnceAndCarriesTheReturnAddress() {
        let plan = SessionBackChannel.plan(
            summary: summary(),
            session: local,
            path: "Sources/App.swift",
            line: 120,
            text: "This leaks the file handle when the guard fires.",
            round: 2
        )
        XCTAssertEqual(
            plan.message,
            """
            Review finding on schnaq/review#42, review round 2
            Sources/App.swift:120

            This leaks the file handle when the guard fires.

            https://github.com/schnaq/review/pull/42
            """
        )
        XCTAssertEqual(plan.session, local)
        XCTAssertEqual(plan.context.session, local)
        XCTAssertEqual(
            plan.context.origin,
            .reviewFinding(path: "Sources/App.swift", line: 120)
        )
        XCTAssertEqual(plan.context.prID, "PR_1")
        XCTAssertEqual(plan.context.headRefOid, "0123456789abcdef")
        // The reviewer's own words, and nobody else's: an empty author list means "the
        // reviewer's own" everywhere it is read, so no colleague's comment can travel here.
        XCTAssertEqual(plan.context.findingComments, ["This leaks the file handle when the guard fires."])
        XCTAssertTrue(plan.context.findingCommentAuthors.isEmpty)
    }

    func testASummaryPlanNamesNoLocation() {
        let plan = SessionBackChannel.plan(
            summary: summary(),
            session: local,
            path: nil,
            line: nil,
            text: "The rename is inconsistent."
        )
        XCTAssertEqual(
            plan.message,
            """
            Review finding on schnaq/review#42

            The rename is inconsistent.

            https://github.com/schnaq/review/pull/42
            """
        )
    }

    // MARK: - The command

    func testTheDefaultResumeCommandSubstitutesTheSessionIDAndKeepsTheMessageWhole() throws {
        let nasty = "fix `rm -rf /`; echo \"$(whoami)\" && exit\nsecond line"
        let invocation = try AgentCLIConfiguration().sessionInvocation(
            message: nasty,
            session: local,
            worktree: worktree,
            executable: claude
        )
        XCTAssertEqual(invocation.executable, claude)
        XCTAssertEqual(invocation.arguments, ["--resume", "session_01abc", "-p", nasty])
        // Exactly one argv element carries the message: the template is split first and the
        // placeholders are substituted into the already-split words afterwards.
        XCTAssertEqual(invocation.arguments.filter { $0 == nasty }.count, 1)
    }

    func testTheSessionURLAndWorktreePlaceholdersAreSubstituted() throws {
        var configuration = AgentCLIConfiguration()
        configuration.remoteSessionTemplate =
            "/usr/local/bin/agent --cwd {worktree} --session={sessionURL} --msg {message}"
        let invocation = try configuration.sessionInvocation(
            message: "have another look",
            session: remote,
            worktree: worktree,
            executable: nil
        )
        XCTAssertEqual(invocation.executable.path, "/usr/local/bin/agent")
        XCTAssertEqual(
            invocation.arguments,
            [
                "--cwd", "/tmp/shepherd/wt",
                "--session=https://claude.ai/code/session_01abc",
                "--msg", "have another look",
            ]
        )
    }

    func testAnEmptyOrPlaceholderlessSessionCommandIsRefused() {
        var configuration = AgentCLIConfiguration()
        XCTAssertThrowsError(
            try configuration.sessionInvocation(
                message: "m",
                session: remote,
                worktree: worktree,
                executable: nil
            )
        ) { error in
            XCTAssertEqual(error as? AgentCLIConfiguration.Failure, .emptySessionTemplate)
        }

        configuration.sessionResumeTemplate = "claude --resume {sessionID}"
        XCTAssertThrowsError(
            try configuration.sessionInvocation(
                message: "m",
                session: local,
                worktree: worktree,
                executable: claude
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentCLIConfiguration.Failure,
                .sessionTemplateMissingMessagePlaceholder
            )
        }
    }

    func testABareCommandNameIsOnlyResolvedWhenItIsTheLocatedCLI() {
        var configuration = AgentCLIConfiguration()
        configuration.sessionResumeTemplate = "some-other-agent --resume {sessionID} {message}"
        XCTAssertThrowsError(
            try configuration.sessionInvocation(
                message: "m",
                session: local,
                worktree: worktree,
                executable: claude
            )
        ) { error in
            XCTAssertEqual(error as? AgentCLIConfiguration.Failure, .executableNotFound)
        }
        // And with nothing located at all, the shipped default cannot be resolved either.
        XCTAssertThrowsError(
            try AgentCLIConfiguration().sessionInvocation(
                message: "m",
                session: local,
                worktree: worktree,
                executable: nil
            )
        ) { error in
            XCTAssertEqual(error as? AgentCLIConfiguration.Failure, .executableNotFound)
        }
    }

    func testBothCommandsSurviveAJSONRoundTripAndAnOlderDocument() throws {
        var configuration = AgentCLIConfiguration()
        configuration.sessionResumeTemplate = "/bin/agent resume {sessionID} {message}"
        configuration.remoteSessionTemplate = "/bin/agent remote {sessionURL} {message}"
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentCLIConfiguration.self, from: data),
            configuration
        )

        // Written before the fields existed: the defaults, not an empty local command.
        let older = try JSONDecoder().decode(
            AgentCLIConfiguration.self,
            from: Data(#"{"maxTurns":4}"#.utf8)
        )
        XCTAssertEqual(
            older.sessionResumeTemplate,
            AgentCLIConfiguration.defaultSessionResumeTemplate
        )
        XCTAssertTrue(older.remoteSessionTemplate.isEmpty)

        // An explicitly empty local command is kept: clearing the field is how the button is
        // switched off, and a default put back over it would switch it on again.
        let cleared = try JSONDecoder().decode(
            AgentCLIConfiguration.self,
            from: Data(#"{"sessionResumeTemplate":""}"#.utf8)
        )
        XCTAssertTrue(cleared.sessionResumeTemplate.isEmpty)
    }

    // MARK: - The prompt

    func testASessionRunSendsTheMessageWithNoPreambleInFrontOfIt() {
        let plan = SessionBackChannel.plan(
            summary: summary(),
            session: local,
            path: "a.swift",
            line: 3,
            text: "narrow this"
        )
        XCTAssertEqual(
            DelegationPrompt.full(for: plan.context, task: plan.message),
            plan.message
        )

        // The ordinary task run is unchanged: preamble first, the reviewer's text after it.
        var withoutSession = plan.context
        withoutSession.session = nil
        let prompt = DelegationPrompt.full(for: withoutSession, task: "narrow this")
        XCTAssertTrue(prompt.hasPrefix(DelegationPrompt.preamble(for: withoutSession)))
        XCTAssertTrue(prompt.lowercased().contains("do not push"))
    }

    // MARK: - What a send is not

    func testOpeningASessionDelegationIsNeitherAutomaticNorDrafted() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shepherd.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let center = DelegationCenter()
        let plan = SessionBackChannel.plan(
            summary: summary(),
            session: local,
            path: "a.swift",
            line: 3,
            text: "narrow this"
        )

        let model = center.open(
            context: plan.context,
            settings: settings,
            toasts: ToastCenter(),
            brief: nil
        )
        model.task = plan.message

        XCTAssertEqual(center.models.count, 1)
        // Not a rule's run: no badge, no ledger, no daily cap — the reviewer pressed Send in a
        // sheet that showed the message (ADR 0016 is not involved at all).
        XCTAssertFalse(model.isAutomatic)
        // Nothing to draft: the text is the reviewer's own words, already confirmed.
        XCTAssertNil(model.brief)
        XCTAssertFalse(model.canDraftBrief)
        XCTAssertEqual(model.context.session, local)
        XCTAssertEqual(model.task, plan.message)
        // Nothing has run and nothing has been pushed. This test's machine has no checkout
        // configured, which is also what the sheet would say.
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.hasPushed)
        XCTAssertEqual(model.readiness, .missingCheckout(repo: "schnaq/review"))
    }

    // MARK: - The row glyph's input

    func testTheGlyphFollowsTheMostRecentReferenceInTheHeadCommits() {
        let commits = [
            CommitInfo(
                oid: "a",
                messageHeadline: "first",
                messageBody: "Claude-Session: https://claude.ai/code/session_one",
                committedDate: Date(timeIntervalSince1970: 100)
            ),
            CommitInfo(
                oid: "b",
                messageHeadline: "second",
                messageBody: "Claude-Session: session_two",
                committedDate: Date(timeIntervalSince1970: 200)
            ),
        ]
        let reference = SessionReference.mostRecent(in: commits)
        XCTAssertEqual(reference?.id, "session_two")
        XCTAssertEqual(reference?.kind, .local)
        XCTAssertNotNil(
            SessionBackChannel.action(session: reference, configuration: AgentCLIConfiguration())
        )
    }
}
