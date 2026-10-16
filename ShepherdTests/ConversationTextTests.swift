import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The conversation tab's own text that is not an event (ADR 0043): a post as *Quote reply* puts
/// it into the comment field, and the heading of a commit group — which carries the catalog's only
/// plural with two arguments. English, because the app tests run with `-testLanguage en`.
@MainActor
final class ConversationTextTests: XCTestCase {
    // MARK: - Quote reply

    func testAQuoteMarksEveryLineOfAnLFBody() {
        XCTAssertEqual(
            ReviewModel.quoted("Looks good.\nOne nit below."),
            "> Looks good.\n> One nit below."
        )
    }

    func testAQuoteKeepsEveryParagraphOfACRLFBodyInsideIt() {
        // What github.com sends for a comment typed there. Swift reads CRLF as one character, so
        // a split on "\n" alone quoted the first paragraph and sent the rest unquoted.
        XCTAssertEqual(
            ReviewModel.quoted("First paragraph.\r\n\r\nSecond paragraph,\r\nsecond line."),
            "> First paragraph.\n>\n> Second paragraph,\n> second line."
        )
    }

    func testAQuoteDropsTheTrailingLineBreak() {
        XCTAssertEqual(ReviewModel.quoted("Only line.\n"), "> Only line.")
        XCTAssertEqual(ReviewModel.quoted("Only line.\r\n"), "> Only line.")
    }

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
}
