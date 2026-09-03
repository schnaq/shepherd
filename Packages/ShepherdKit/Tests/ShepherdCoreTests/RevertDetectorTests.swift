import Foundation
import XCTest

@testable import ShepherdCore

/// Reading "this undoes that" out of a pull request's own text (ADR 0027).
final class RevertDetectorTests: XCTestCase {
    // MARK: - Titles

    func testGitHubsOwnRevertTitleIsRead() {
        let reference = RevertDetector.revertedTarget(
            title: #"Revert "feat(parser): accept trailing commas""#,
            body: ""
        )
        XCTAssertEqual(reference.revertedTitle, "feat(parser): accept trailing commas")
    }

    func testTheKeywordIsCaseInsensitiveAndAColonIsTolerated() {
        XCTAssertEqual(
            RevertDetector.quotedTitle(in: #"revert: "fix the thing""#),
            "fix the thing"
        )
        XCTAssertEqual(
            RevertDetector.quotedTitle(in: #"REVERT "fix the thing""#),
            "fix the thing"
        )
    }

    func testTypographicQuotesAreRead() {
        XCTAssertEqual(
            RevertDetector.quotedTitle(in: "Revert \u{201C}fix the thing\u{201D}"),
            "fix the thing"
        )
    }

    func testADoubleRevertTakesTheOuterQuotes() {
        XCTAssertEqual(
            RevertDetector.quotedTitle(in: #"Revert "Revert "fix the thing"""#),
            #"Revert "fix the thing""#,
            "the outer pair is what this pull request undoes"
        )
    }

    func testATitleThatMerelyMentionsRevertingIsNotARevert() {
        XCTAssertNil(RevertDetector.quotedTitle(in: "Reverted the migration by hand"))
        XCTAssertNil(RevertDetector.quotedTitle(in: "fix: stop reverting the config"))
        XCTAssertNil(RevertDetector.quotedTitle(in: "Revert"))
        XCTAssertNil(RevertDetector.quotedTitle(in: #"Revert """#), "an empty quote says nothing")
    }

    // MARK: - Bodies

    func testTheRevertsCommitLineIsRead() {
        let reference = RevertDetector.revertedTarget(
            title: "Revert something",
            body: """
                This reverts commit 4f3a9c1d2b8e7f6a5c4b3a2918273645abcdef01.

                It broke the nightly build.
                """
        )
        XCTAssertEqual(
            reference.revertedCommitOid,
            "4f3a9c1d2b8e7f6a5c4b3a2918273645abcdef01"
        )
    }

    func testAnAbbreviatedShaIsReadAndLowercased() {
        XCTAssertEqual(
            RevertDetector.revertedCommit(in: "This reverts commit 4F3A9C1."),
            "4f3a9c1"
        )
    }

    func testTheFirstRevertsCommitLineWins() {
        XCTAssertEqual(
            RevertDetector.revertedCommit(
                in: """
                    This reverts commit aaaaaaa.
                    This reverts commit bbbbbbb.
                    """
            ),
            "aaaaaaa"
        )
    }

    func testSomethingThatIsNotAShaIsIgnored() {
        XCTAssertNil(RevertDetector.revertedCommit(in: "This reverts commit yesterday."))
        XCTAssertNil(RevertDetector.revertedCommit(in: "This reverts commit abc."))
        XCTAssertNil(RevertDetector.revertedCommit(in: "nothing here"))
    }

    // MARK: - Numbers

    func testARevertsNumberPhraseIsRead() {
        XCTAssertEqual(RevertDetector.revertedNumber(in: "Reverts #142"), 142)
        XCTAssertEqual(RevertDetector.revertedNumber(in: "Revert of #7 for now"), 7)
        XCTAssertNil(RevertDetector.revertedNumber(in: "Fixes #142"))
    }

    func testARevertShapeIsRequiredBeforeANumberIsBelieved() {
        XCTAssertFalse(
            RevertDetector.isRevertShaped(
                title: "docs: explain the rollback",
                body: "We may have to revert #12 one day."
            )
        )
        XCTAssertTrue(
            RevertDetector.isRevertShaped(title: #"Revert "x""#, body: "")
        )
        XCTAssertTrue(
            RevertDetector.isRevertShaped(title: "undo the parser change", body: "This reverts commit aaaaaaa.")
        )
    }

    // MARK: - Linking

    func testARevertIsLinkedToItsTargetsMergeCommit() {
        let target = closed("PR_1", number: 10, title: "feat: parser", merged: true, oid: "aaaaaaa1", closedAt: 0)
        let revert = closed(
            "PR_2",
            number: 11,
            title: "Revert something else",
            merged: true,
            body: "This reverts commit aaaaaaa1.",
            closedAt: 100
        )
        XCTAssertEqual(
            RevertDetector.links(candidates: [target, revert]),
            ["PR_1": "PR_2"]
        )
    }

    func testAnAbbreviatedShaStillFindsTheFullMergeCommit() {
        let target = closed(
            "PR_1",
            number: 10,
            title: "feat: parser",
            merged: true,
            oid: "4f3a9c1d2b8e7f6a5c4b3a2918273645abcdef01",
            closedAt: 0
        )
        let revert = closed(
            "PR_2",
            number: 11,
            title: "Revert it",
            merged: true,
            body: "This reverts commit 4f3a9c1.",
            closedAt: 100
        )
        XCTAssertEqual(RevertDetector.links(candidates: [target, revert]), ["PR_1": "PR_2"])
    }

    func testARevertIsLinkedByTitleWhenThereIsNoShaToMatch() {
        let target = closed("PR_1", number: 10, title: "feat: parser", merged: true, closedAt: 0)
        let revert = closed(
            "PR_2",
            number: 11,
            title: #"Revert "feat: parser""#,
            merged: true,
            closedAt: 100
        )
        XCTAssertEqual(RevertDetector.links(candidates: [target, revert]), ["PR_1": "PR_2"])
    }

    func testARevertIsLinkedByNumber() {
        let target = closed("PR_1", number: 10, title: "feat: parser", merged: true, closedAt: 0)
        let revert = closed(
            "PR_2",
            number: 11,
            title: "Revert the parser change",
            merged: true,
            body: "Reverts #10",
            closedAt: 100
        )
        XCTAssertEqual(RevertDetector.links(candidates: [target, revert]), ["PR_1": "PR_2"])
    }

    func testATargetAlreadyOnDiskIsFoundToo() {
        let stored = closed("PR_1", number: 10, title: "feat: parser", merged: true, closedAt: 0)
        let revert = closed(
            "PR_2",
            number: 11,
            title: #"Revert "feat: parser""#,
            merged: true,
            closedAt: 100
        )
        XCTAssertEqual(
            RevertDetector.links(candidates: [revert], known: [stored]),
            ["PR_1": "PR_2"],
            "this is the case the stored title column exists for"
        )
    }

    func testAnUnmergedTargetIsNeverLinked() {
        let target = closed("PR_1", number: 10, title: "feat: parser", merged: false, closedAt: 0)
        let revert = closed(
            "PR_2",
            number: 11,
            title: #"Revert "feat: parser""#,
            merged: true,
            closedAt: 100
        )
        XCTAssertTrue(RevertDetector.links(candidates: [target, revert]).isEmpty)
    }

    func testARevertCannotPointForwardsInTime() {
        let target = closed("PR_1", number: 10, title: "feat: parser", merged: true, closedAt: 500)
        let revert = closed(
            "PR_2",
            number: 11,
            title: #"Revert "feat: parser""#,
            merged: true,
            closedAt: 100
        )
        XCTAssertTrue(
            RevertDetector.links(candidates: [target, revert]).isEmpty,
            "a pull request cannot undo something that closed after it"
        )
    }

    func testARevertNeverLinksToItself() {
        let selfish = closed(
            "PR_1",
            number: 10,
            title: #"Revert "Revert "x"""#,
            merged: true,
            closedAt: 0
        )
        XCTAssertTrue(RevertDetector.links(candidates: [selfish]).isEmpty)
    }

    func testARevertOnlyLinksInsideItsOwnRepository() {
        let target = closed(
            "PR_1",
            number: 10,
            title: "feat: parser",
            merged: true,
            repo: RepoRef(owner: "schnaq", name: "konduit"),
            closedAt: 0
        )
        let revert = closed(
            "PR_2",
            number: 11,
            title: #"Revert "feat: parser""#,
            merged: true,
            closedAt: 100
        )
        XCTAssertTrue(RevertDetector.links(candidates: [target, revert]).isEmpty)
    }

    func testTwoMergedPullRequestsWithTheSameTitleLinkToTheMoreRecentOne() {
        let older = closed("PR_1", number: 10, title: "chore: bump", merged: true, closedAt: 0)
        let newer = closed("PR_2", number: 11, title: "chore: bump", merged: true, closedAt: 100)
        let revert = closed(
            "PR_3",
            number: 12,
            title: #"Revert "chore: bump""#,
            merged: true,
            closedAt: 200
        )
        XCTAssertEqual(
            RevertDetector.links(candidates: [older, newer, revert]),
            ["PR_2": "PR_3"]
        )
    }

    func testAnEmptySetLinksNothing() {
        XCTAssertTrue(RevertDetector.links(candidates: []).isEmpty)
    }

    // MARK: - Fixtures

    private func closed(
        _ id: String,
        number: Int,
        title: String,
        merged: Bool,
        body: String = "",
        oid: String? = nil,
        repo: RepoRef? = nil,
        closedAt: TimeInterval
    ) -> ClosedPullRequest {
        ClosedPullRequest(
            outcome: PullRequestOutcome(
                prID: id,
                repo: repo ?? Fixtures.repo,
                agentName: "Claude Code",
                authorLogin: "claude[bot]",
                openedAt: Fixtures.date(closedAt - 3_600),
                closedAt: Fixtures.date(closedAt),
                merged: merged,
                source: .backfill
            ),
            number: number,
            title: title,
            bodyMarkdown: body,
            mergeCommitOid: oid
        )
    }
}
