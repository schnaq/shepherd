import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of ADR 0032's linking sprint: the "Closes" section on the pull-request screen,
/// and the badge that resolves a linked pull request against the local inbox.
///
/// The parsing and the storing are covered in ShepherdKit, on the Linux runner. What is tested
/// here is what a pure function in the package cannot see: the section's own rules (hidden when
/// there are none, the number and the state in the row, the right issue behind the click) and the
/// badge's one load-bearing property — nothing at all when the pull request is not cached.
///
/// The localised strings are asserted **structurally** rather than against English text, for
/// `LocalizationTests`' reason: on a German runner `String(localized:)` resolves to German, and a
/// test that compared literal English would pass or fail depending on the Mac it ran on.
@MainActor
final class ClosingIssuesTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let otherRepo = RepoRef(owner: "schnaq", name: "shepherd-web")

    private func issue(
        number: Int = 142,
        repo: RepoRef? = nil,
        title: String = "Uploads fail silently",
        state: IssueSummary.State = .open
    ) -> LinkedIssueReference {
        LinkedIssueReference(
            repo: repo ?? self.repo,
            number: number,
            title: title,
            state: state
        )
    }

    // MARK: - The section's rules

    func testTheSectionIsHiddenWhenThePullRequestClosesNothing() {
        XCTAssertTrue(ClosingIssuesCard.isHidden(for: []))
        XCTAssertFalse(ClosingIssuesCard.isHidden(for: [issue()]))
    }

    func testTheRowNamesTheIssueNumber() {
        let label = ClosingIssuesCard.label(for: issue(number: 142))
        XCTAssertTrue(label.contains("142"), label)
        XCTAssertTrue(label.contains("#"), label)
    }

    func testTheHeadingCarriesTheCountAndAgreesWithIt() {
        let one = ClosingIssuesCard.title(for: 1)
        let three = ClosingIssuesCard.title(for: 3)
        XCTAssertTrue(one.contains("1"), one)
        XCTAssertTrue(three.contains("3"), three)
        // The plural variation is the point of the key: one issue and three issues do not read
        // the same in either language.
        XCTAssertNotEqual(one, three)
    }

    func testEveryStateHasItsOwnGlyphAndWord() {
        XCTAssertEqual(ClosingIssuesCard.symbol(for: .open), "smallcircle.filled.circle")
        XCTAssertEqual(ClosingIssuesCard.symbol(for: .closed), "checkmark.circle")
        XCTAssertEqual(ClosingIssuesCard.symbol(for: .unknown), "questionmark.circle")

        let words = Set(
            IssueSummary.State.allCases.map { ClosingIssuesCard.stateTitle(for: $0) }
        )
        XCTAssertEqual(words.count, IssueSummary.State.allCases.count, "\(words)")
    }

    func testTheAccessibilityLabelCarriesTheNumberTheTitleAndTheState() {
        let sentence = ClosingIssuesCard.accessibilityLabel(
            for: issue(number: 7, title: "Token refresh logs the user out", state: .closed)
        )
        XCTAssertTrue(sentence.contains("7"), sentence)
        XCTAssertTrue(sentence.contains("Token refresh logs the user out"), sentence)
        XCTAssertTrue(
            sentence.contains(ClosingIssuesCard.stateTitle(for: .closed)),
            sentence
        )
    }

    // MARK: - Opening the right issue

    /// Collects what the section asked to open, so the click can be asserted without a window.
    private final class OpenCollector {
        var issues: [LinkedIssueReference] = []
    }

    func testTheRowOpensTheIssueItNames() {
        // The click hands back the whole reference, which is what makes
        // `AppEnvironment.openIssue` a one-line change later. Here it is asserted the way the
        // requirement is worded: the *right* issue.
        let collector = OpenCollector()
        let card = ClosingIssuesCard(
            issues: [issue(number: 142), issue(number: 7, state: .closed)],
            repo: repo,
            onOpen: { collector.issues.append($0) }
        )
        card.onOpen(card.issues[1])
        XCTAssertEqual(collector.issues.map(\.number), [7])
    }

    func testTheGitHubURLPointsAtTheIssueInItsOwnRepository() {
        XCTAssertEqual(
            ClosingIssuesCard.githubURL(for: issue(number: 142)).absoluteString,
            "https://github.com/schnaq/review/issues/142"
        )
        // A `closes owner/repo#1` reference keeps its own repository, so the link cannot open the
        // wrong issue.
        XCTAssertEqual(
            ClosingIssuesCard.githubURL(for: issue(number: 1, repo: otherRepo)).absoluteString,
            "https://github.com/schnaq/shepherd-web/issues/1"
        )
    }

    // MARK: - The badge's local join

    private func link(number: Int, repo: RepoRef? = nil) -> LinkedPullRequestReference {
        LinkedPullRequestReference(
            repo: repo ?? self.repo,
            number: number,
            title: "fix: the timeout",
            state: "OPEN",
            author: ShepherdCore.Actor(
                login: "octocat",
                displayName: nil,
                avatarURL: nil,
                kind: .human
            )
        )
    }

    private func summary(
        id: String,
        number: Int,
        repo: RepoRef? = nil,
        rollup: CheckRollup? = CheckRollup(state: .failure, total: 3, failureCount: 1),
        decision: ReviewDecision? = .changesRequested
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo ?? self.repo,
            number: number,
            title: "fix: the timeout",
            author: ShepherdCore.Actor(
                login: "octocat",
                displayName: nil,
                avatarURL: nil,
                kind: .human
            ),
            updatedAt: Date(timeIntervalSince1970: 1_788_162_000),
            createdAt: Date(timeIntervalSince1970: 1_788_158_400),
            headRefName: "fix/timeout",
            headRefOid: "abc123",
            baseRefName: "main",
            reviewDecision: decision,
            checkRollup: rollup,
            myRelation: [.reviewRequested]
        )
    }

    func testTheStatusReadsTheTwoFieldsOffACachedRow() {
        let status = LinkedPullRequestStatus(summary: summary(id: "PR_1", number: 128))
        XCTAssertEqual(status.checkRollup?.state, .failure)
        XCTAssertEqual(status.reviewDecision, .changesRequested)
        XCTAssertFalse(status.isEmpty)
    }

    func testARowWithNeitherARollupNorADecisionIsAsBlankAsNoRow() {
        let status = LinkedPullRequestStatus(
            summary: summary(id: "PR_1", number: 128, rollup: nil, decision: nil)
        )
        XCTAssertTrue(status.isEmpty)
    }

    func testALinkedPullRequestInTheInboxResolvesToItsState() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([summary(id: "PR_1", number: 128)])

        let status = await LinkedPullRequestStatusLoader.load(
            link(number: 128),
            from: database
        )

        XCTAssertEqual(status?.checkRollup?.state, .failure)
        XCTAssertEqual(status?.reviewDecision, .changesRequested)
    }

    func testALinkedPullRequestThatIsNotCachedResolvesToNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([summary(id: "PR_1", number: 128)])

        // Somebody else's pull request: it closes an issue the user is assigned to, but it was
        // never in this inbox. The badge draws nothing rather than a grey dot (ADR 0032).
        let elsewhere = await LinkedPullRequestStatusLoader.load(
            link(number: 128, repo: otherRepo),
            from: database
        )
        XCTAssertNil(elsewhere)

        let unknownNumber = await LinkedPullRequestStatusLoader.load(
            link(number: 9_999),
            from: database
        )
        XCTAssertNil(unknownNumber)
    }

    func testACachedPullRequestWithNothingToSayResolvesToNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            summary(id: "PR_1", number: 128, rollup: nil, decision: nil)
        ])

        let status = await LinkedPullRequestStatusLoader.load(
            link(number: 128),
            from: database
        )
        XCTAssertNil(status, "a badge with nothing in it is not drawn")
    }

    func testSignedOutResolvesToNothingRatherThanFailing() async {
        let status = await LinkedPullRequestStatusLoader.load(link(number: 128), from: nil)
        XCTAssertNil(status)
    }
}
