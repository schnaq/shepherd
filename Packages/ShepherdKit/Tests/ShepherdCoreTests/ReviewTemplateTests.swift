import Foundation
import XCTest

@testable import ShepherdCore

/// Saved replies and per-repo review templates: the matching rule and the "only ever fill an empty
/// draft" rule.
///
/// Both halves are here because both are the sort of thing that is silently wrong: a template that
/// matches the wrong repository looks like a typo the user made, and a template that overwrites a
/// draft destroys review work that the app promised to keep (ADR 0006).
final class ReviewTemplateTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    private func template(_ pattern: String, _ body: String = "checklist") -> ReviewTemplate {
        ReviewTemplate(pattern: pattern, body: body)
    }

    // MARK: - Matching

    func testAnExactPatternMatchesOnlyThatRepository() {
        let exact = template("schnaq/review")
        XCTAssertTrue(exact.matches(repo))
        XCTAssertFalse(exact.matches(RepoRef(owner: "schnaq", name: "shepherd")))
        XCTAssertFalse(exact.matches(RepoRef(owner: "other", name: "review")))
        XCTAssertTrue(exact.isExact)
    }

    func testAnOwnerWildcardMatchesEveryRepositoryOfThatOwner() {
        let wildcard = template("schnaq/*")
        XCTAssertTrue(wildcard.matches(repo))
        XCTAssertTrue(wildcard.matches(RepoRef(owner: "schnaq", name: "shepherd")))
        XCTAssertFalse(wildcard.matches(RepoRef(owner: "schnaqq", name: "review")))
        XCTAssertFalse(wildcard.isExact)
    }

    func testMatchingIsCaseInsensitiveLikeEveryOtherRepositoryComparison() {
        XCTAssertTrue(template("Schnaq/*").matches(repo))
        XCTAssertTrue(template("schnaq/review").matches(RepoRef(owner: "Schnaq", name: "Review")))
    }

    func testAPatternWithoutABodyOrABodyWithoutAPatternNeverMatches() {
        XCTAssertFalse(template("schnaq/*", "   ").matches(repo))
        XCTAssertFalse(template("   ", "checklist").matches(repo))
        XCTAssertNil(
            ReviewTemplate.matching([template("schnaq/*", ""), template("", "x")], repo: repo)
        )
    }

    func testAWhitespacePaddedPatternStillMatches() {
        XCTAssertTrue(template("  schnaq/*  ").matches(repo))
    }

    /// Rule 1: an exact pattern beats a wildcard, wherever the two sit in the list.
    func testAnExactPatternWinsOverAWildcardInEitherOrder() {
        let exact = template("schnaq/review", "exact")
        let wildcard = template("schnaq/*", "wildcard")
        XCTAssertEqual(ReviewTemplate.matching([wildcard, exact], repo: repo)?.body, "exact")
        XCTAssertEqual(ReviewTemplate.matching([exact, wildcard], repo: repo)?.body, "exact")
    }

    /// Rule 2: between two wildcards, the one with more literal characters wins.
    func testTheMoreSpecificWildcardWins() {
        let everything = template("*", "everything")
        let owner = template("schnaq/*", "owner")
        let prefix = template("schnaq/rev*", "prefix")
        XCTAssertEqual(
            ReviewTemplate.matching([everything, owner, prefix], repo: repo)?.body,
            "prefix"
        )
        XCTAssertEqual(ReviewTemplate.matching([everything, owner], repo: repo)?.body, "owner")
        XCTAssertEqual(ReviewTemplate.matching([everything], repo: repo)?.body, "everything")
        XCTAssertEqual(everything.specificity, 0)
        XCTAssertEqual(owner.specificity, 7)
        XCTAssertEqual(prefix.specificity, 10)
    }

    /// Rule 3: equally specific patterns are decided by the user's own list order, first wins.
    func testEquallySpecificPatternsAreDecidedByListOrder() {
        let first = template("schnaq/rev?ew", "first")
        let second = template("schnaq/re?iew", "second")
        XCTAssertEqual(first.specificity, second.specificity)
        XCTAssertEqual(ReviewTemplate.matching([first, second], repo: repo)?.body, "first")
        XCTAssertEqual(ReviewTemplate.matching([second, first], repo: repo)?.body, "second")
    }

    func testNoTemplateMatchesAnUnrelatedRepository() {
        let templates = [template("schnaq/*"), template("acme/tools")]
        XCTAssertNil(ReviewTemplate.matching(templates, repo: RepoRef(owner: "other", name: "x")))
        XCTAssertNil(ReviewTemplate.matching([], repo: repo))
    }

    // MARK: - Prefilling a new draft

    private func draft(
        verdict: ReviewVerdict? = nil,
        summaryBody: String = "",
        comments: [DraftComment] = []
    ) -> ReviewDraft {
        ReviewDraft(
            prID: "PR_1",
            verdict: verdict,
            summaryBody: summaryBody,
            comments: comments,
            basedOnHeadOid: "abc123",
            updatedAt: Fixtures.date(0)
        )
    }

    private func prefill(
        draft: ReviewDraft?,
        summaryText: String = "",
        templates: [ReviewTemplate]? = nil
    ) -> String? {
        ReviewTemplate.prefill(
            templates: templates ?? [template("schnaq/*", "## Checklist\n- [ ] tests")],
            repo: repo,
            draft: draft,
            summaryText: summaryText
        )
    }

    func testAFreshReviewWithNoDraftIsPrefilled() {
        XCTAssertEqual(prefill(draft: nil), "## Checklist\n- [ ] tests")
    }

    func testAnEmptyDraftRowIsStillPrefilled() {
        // A draft row can exist while carrying nothing — a comment was added and deleted again.
        XCTAssertEqual(prefill(draft: draft()), "## Checklist\n- [ ] tests")
    }

    func testADraftWithAnythingInItIsNeverTouched() {
        let comment = DraftComment(path: "a.swift", line: 3, body: "nit")
        XCTAssertNil(prefill(draft: draft(comments: [comment])))
        XCTAssertNil(prefill(draft: draft(summaryBody: "already written")))
        XCTAssertNil(prefill(draft: draft(verdict: .approve)))
    }

    func testTextAlreadyInTheSummaryFieldIsNeverReplaced() {
        XCTAssertNil(prefill(draft: nil, summaryText: "I started typing"))
        // Whitespace is not text: a field holding only a stray newline still counts as empty.
        XCTAssertEqual(prefill(draft: nil, summaryText: " \n "), "## Checklist\n- [ ] tests")
    }

    func testNothingIsPrefilledWithoutAMatchingTemplateOrWithAnEmptyBody() {
        XCTAssertNil(prefill(draft: nil, templates: []))
        XCTAssertNil(prefill(draft: nil, templates: [template("acme/*", "not for you")]))
        XCTAssertNil(prefill(draft: nil, templates: [template("schnaq/*", "  \n ")]))
    }

    func testThePrefilledBodyIsTrimmed() {
        XCTAssertEqual(
            prefill(draft: nil, templates: [template("schnaq/*", "\n  checklist\n\n")]),
            "checklist"
        )
    }

    // MARK: - Inserting a saved reply

    func testInsertingIntoAnEmptyComposerYieldsJustTheReply() {
        XCTAssertEqual(SavedReply.inserting("Looks good!", into: ""), "Looks good!")
        XCTAssertEqual(SavedReply.inserting("Looks good!", into: "  \n\n "), "Looks good!")
    }

    func testInsertingAppendsAfterExactlyOneBlankLine() {
        XCTAssertEqual(SavedReply.inserting("second", into: "first"), "first\n\nsecond")
        XCTAssertEqual(SavedReply.inserting("second", into: "first\n\n\n  "), "first\n\nsecond")
    }

    func testInsertingTwiceStacksBothBodiesWithoutGrowingTheGap() {
        let once = SavedReply.inserting("a", into: "")
        let twice = SavedReply.inserting("b", into: once)
        XCTAssertEqual(twice, "a\n\nb")
    }

    func testInsertingKeepsLeadingWhitespaceOfWhatTheUserTyped() {
        XCTAssertEqual(SavedReply.inserting("b", into: "    indented"), "    indented\n\nb")
    }

    func testAnEmptyReplyChangesNothing() {
        XCTAssertEqual(SavedReply.inserting("   ", into: "typed"), "typed")
        XCTAssertEqual(SavedReply.inserting("", into: ""), "")
    }

    func testAReplyIsUsableOnlyWithBothANameAndABody() {
        XCTAssertTrue(SavedReply(name: "Nit", body: "please rename").isUsable)
        XCTAssertFalse(SavedReply(name: " ", body: "please rename").isUsable)
        XCTAssertFalse(SavedReply(name: "Nit", body: "\n").isUsable)
    }

    // MARK: - Codec

    func testBothTypesRoundTripThroughJSON() throws {
        let reply = SavedReply(name: "Nit", body: "please rename")
        let decodedReply = try JSONDecoder().decode(
            SavedReply.self,
            from: try JSONEncoder().encode(reply)
        )
        XCTAssertEqual(decodedReply, reply)

        let stored = template("schnaq/*", "## Checklist")
        let decodedTemplate = try JSONDecoder().decode(
            ReviewTemplate.self,
            from: try JSONEncoder().encode(stored)
        )
        XCTAssertEqual(decodedTemplate, stored)
    }
}
