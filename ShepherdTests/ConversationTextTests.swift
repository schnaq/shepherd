import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The conversation tab's own rules that are not an event (ADR 0043): the heading of a commit
/// group — which carries the catalog's only plural with two arguments — which threads start
/// folded, and what a fold becomes once the thread is resolved or reopened. English, because the
/// app tests run with `-testLanguage en`. *Quote reply*'s quoting is
/// ShepherdCore's (`MarkdownBlockTests`).
@MainActor
final class ConversationTextTests: XCTestCase {
    // MARK: - Commit groups

    private static let claude = ShepherdCore.Actor(
        login: "claude[bot]",
        displayName: "Claude Code",
        kind: .bot
    )
    private static let sophie = ShepherdCore.Actor(
        login: "sophie-mueller",
        displayName: "Sophie Müller",
        kind: .human
    )

    private func commits(_ authors: [ShepherdCore.Actor?]) -> [CommitInfo] {
        authors.enumerated().map { index, author in
            CommitInfo(
                oid: "c\(index)",
                messageHeadline: "Change \(index)",
                author: author,
                committedDate: Date(timeIntervalSince1970: Double(index) * 60)
            )
        }
    }

    func testOneAuthorsCommitsAreNamedAndCountedWithAgreement() {
        XCTAssertEqual(
            ConversationCommitsView.title(for: commits([Self.claude])),
            "Claude Code added 1 commit"
        )
        XCTAssertEqual(
            ConversationCommitsView.title(for: commits([Self.claude, Self.claude, Self.claude])),
            "Claude Code added 3 commits"
        )
    }

    func testCommitsByMoreThanOneAuthorAreOnlyCounted() {
        XCTAssertEqual(
            ConversationCommitsView.title(for: commits([Self.claude, Self.sophie, Self.claude])),
            "3 commits"
        )
        // An author GitHub could not resolve names nobody, and one commit is still singular.
        XCTAssertEqual(ConversationCommitsView.title(for: commits([nil])), "1 commit")
    }

    // MARK: - Folding a thread

    func testAnOpenThreadStartsOpenAndASettledOneStartsFolded() {
        let open = ReviewThread(id: "RT_open")
        let resolved = ReviewThread(id: "RT_resolved", isResolved: true)
        let outdated = ReviewThread(id: "RT_outdated", isOutdated: true)
        XCTAssertTrue(ConversationThreadView.isExpanded(open, isFlipped: false))
        XCTAssertFalse(ConversationThreadView.isExpanded(resolved, isFlipped: false))
        XCTAssertFalse(ConversationThreadView.isExpanded(outdated, isFlipped: false))
    }

    func testFlippingAThreadTurnsItTheOtherWay() {
        XCTAssertFalse(ConversationThreadView.isExpanded(ReviewThread(id: "RT_open"), isFlipped: true))
        XCTAssertTrue(
            ConversationThreadView.isExpanded(ReviewThread(id: "RT_resolved", isResolved: true), isFlipped: true)
        )
    }

    // MARK: - A fold across a change of resolution

    /// Whether `fresh` is drawn open once it replaces `shown`, given the flips the reviewer made.
    private func isExpanded(after flips: Set<String>, from shown: ReviewThread, to fresh: ReviewThread) -> Bool {
        let carried = ReviewModel.foldFlips(flips, from: [shown], to: [fresh])
        return ConversationThreadView.isExpanded(fresh, isFlipped: carried.contains(fresh.id))
    }

    func testResolvingAThreadFoldsIt() {
        let open = ReviewThread(id: "RT_1")
        let resolved = ReviewThread(id: "RT_1", isResolved: true)
        XCTAssertFalse(isExpanded(after: [], from: open, to: resolved), "from its own reply bar")
        XCTAssertFalse(isExpanded(after: ["RT_1"], from: open, to: resolved), "folded by hand before")
        let outdated = ReviewThread(id: "RT_1", isOutdated: true)
        XCTAssertFalse(
            isExpanded(after: ["RT_1"], from: outdated, to: ReviewThread(id: "RT_1", isResolved: true, isOutdated: true)),
            "an outdated thread the reviewer had unfolded"
        )
    }

    /// T5-7: Unresolve on a thread the reviewer had unfolded folded it, because the flip stayed.
    func testUnresolvingAThreadOpensIt() {
        XCTAssertTrue(isExpanded(
            after: ["RT_1"],
            from: ReviewThread(id: "RT_1", isResolved: true),
            to: ReviewThread(id: "RT_1")
        ))
        XCTAssertTrue(
            isExpanded(
                after: ["RT_1"],
                from: ReviewThread(id: "RT_1", isResolved: true, isOutdated: true),
                to: ReviewThread(id: "RT_1", isOutdated: true)
            ),
            "an outdated thread starts folded, and still opens"
        )
    }

    func testAFlipOutlivesADetailThatLeftItsThreadAsItWas() {
        let carried = ReviewModel.foldFlips(
            ["RT_open", "RT_resolved", "RT_new"],
            from: [ReviewThread(id: "RT_open"), ReviewThread(id: "RT_resolved", isResolved: true)],
            to: [
                ReviewThread(id: "RT_open"),
                ReviewThread(id: "RT_resolved", isResolved: true),
                ReviewThread(id: "RT_new", isResolved: true),
            ]
        )
        XCTAssertEqual(carried, ["RT_open", "RT_resolved", "RT_new"])
    }
}
