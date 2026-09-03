import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of "since my review": which round a review opens on, what the file list is
/// filtered to, and what the inbox row says (ADR 0028).
///
/// The interdiff itself is `ShepherdCore`'s and is tested on Linux; everything here is about
/// the decisions the screens make with it.
///
/// `@MainActor` because ``ReviewModel`` is: its round-view default is a `static` member of a
/// main-actor class, and reaching it from a nonisolated test is not allowed under Swift 6.
@MainActor
final class SinceReviewTests: XCTestCase {
    private let reviewedPatch = """
        @@ -1,4 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
         let d = 5
        """

    private let currentPatch = """
        @@ -1,4 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 42
         let c = 4
         let d = 5
        """

    private func summary(headRefOid: String) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 7,
            title: "Fix the parser",
            author: ShepherdCore.Actor(login: "claude[bot]", kind: .bot),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            createdAt: Date(timeIntervalSince1970: 1_000),
            isDraft: false,
            headRefName: "claude/fix",
            headRefOid: headRefOid,
            baseRefName: "main",
            myRelation: [.reviewRequested]
        )
    }

    private func file(_ path: String, patch: String) -> ChangedFile {
        ChangedFile(path: path, status: .modified, additions: 1, deletions: 1, patch: patch)
    }

    private func thread(id: String, line: Int, login: String = "octocat") -> ReviewThread {
        ReviewThread(
            id: id,
            path: "a.swift",
            line: line,
            side: .right,
            comments: [
                ReviewComment(
                    id: "\(id)-c1",
                    author: ShepherdCore.Actor(login: login, kind: .human),
                    bodyMarkdown: "Please add a test for the error path.",
                    createdAt: Date(timeIntervalSince1970: 1_500)
                )
            ]
        )
    }

    private func detail(headRefOid: String, threads: [ReviewThread] = []) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(headRefOid: headRefOid),
            files: [file("a.swift", patch: currentPatch), file("b.swift", patch: reviewedPatch)],
            threads: threads
        )
    }

    private func snapshot(head: String = "head-1") -> ReviewSnapshot {
        ReviewSnapshot(
            prID: "PR_1",
            reviewedHeadOid: head,
            reviewedAt: Date(timeIntervalSince1970: 1_600),
            files: [
                file("a.swift", patch: reviewedPatch),
                file("b.swift", patch: reviewedPatch),
            ]
        )
    }

    private func round(currentHead: String = "head-2") -> SinceReviewRound {
        SinceReviewLoader.compute(
            snapshot: snapshot(),
            roundCount: 2,
            detail: detail(headRefOid: currentHead, threads: [thread(id: "PRRT_1", line: 2)]),
            viewerLogin: "octocat"
        )
    }

    // MARK: - The default round view

    func testAMovedHeadWithABaselineOpensOnSinceYourReview() {
        let computed = round()
        XCTAssertTrue(computed.hasMoved)
        XCTAssertTrue(computed.isOffered)
        XCTAssertEqual(ReviewModel.defaultRoundView(for: computed), .sinceReview)
    }

    func testWithoutABaselineTheScreenOpensOnAllFiles() {
        XCTAssertEqual(ReviewModel.defaultRoundView(for: nil), .all)
    }

    func testABaselineOfTheCurrentHeadOpensOnAllFiles() {
        let computed = round(currentHead: "head-1")
        XCTAssertFalse(computed.hasMoved)
        XCTAssertFalse(computed.isOffered)
        XCTAssertTrue(computed.interdiff.isEmpty)
        XCTAssertEqual(ReviewModel.defaultRoundView(for: computed), .all)
    }

    func testAnEmptyBaselineOrAnEmptyPullRequestStillProducesAnInterdiff() {
        let computed = SinceReviewLoader.compute(
            snapshot: ReviewSnapshot(
                prID: "PR_1",
                reviewedHeadOid: "head-1",
                reviewedAt: Date(timeIntervalSince1970: 1_600),
                files: []
            ),
            roundCount: 1,
            detail: detail(headRefOid: "head-2"),
            viewerLogin: "octocat"
        )
        // Every file of the pull request looks new against an empty baseline, so this *is*
        // offered — the honest failure is the one where the interdiff finds nothing at all.
        XCTAssertEqual(computed.interdiff.map(\.kind), [.added, .added])
        let unreadable = SinceReviewLoader.compute(
            snapshot: snapshot(),
            roundCount: 1,
            detail: PullRequestDetail(summary: summary(headRefOid: "head-2"), files: []),
            viewerLogin: "octocat"
        )
        XCTAssertEqual(unreadable.interdiff.map(\.kind), [.removed, .removed])
    }

    // MARK: - Filtering

    func testTheRoundListsOnlyTheFilesThatChangedBetweenTheHeads() {
        let computed = round()
        // `b.swift` is identical in both rounds and disappears; `a.swift` changed.
        XCTAssertEqual(computed.interdiff.map(\.path), ["a.swift"])
        XCTAssertEqual(computed.changedFiles.map(\.path), ["a.swift"])
    }

    func testTheRoundsFilesCarryTheSynthesizedPatchForTheViewer() throws {
        let computed = round()
        let changed = try XCTUnwrap(computed.changedFiles.first)
        XCTAssertEqual(changed.status, .modified)
        let patch = try XCTUnwrap(changed.patch)
        XCTAssertTrue(patch.hasPrefix("@@ "))
        // The viewer's own reconstruction has to be able to read it: that is what lets the
        // round go through the existing `loadFile` path with no new bridge message.
        let reconstruction = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertTrue(reconstruction.modified.contains("let b = 42"))
        XCTAssertTrue(reconstruction.original.contains("let b = 3"))
    }

    func testTheFileListOfARoundIsTheOrdinaryPrioritisedList() {
        let computed = round()
        let priorities = FilePrioritizer.prioritize(
            computed.changedFiles,
            context: PrioritizationContext()
        )
        XCTAssertEqual(priorities.map(\.file.path), ["a.swift"])
    }

    // MARK: - Findings

    func testTheViewersFindingIsClassifiedAgainstTheRound() throws {
        let computed = round()
        XCTAssertEqual(computed.findings.map(\.threadID), ["PRRT_1"])
        XCTAssertEqual(computed.findings.first?.state, .addressed)
        XCTAssertEqual(computed.unchangedFindingCount, 0)
    }

    func testAFindingOnALineNobodyTouchedCountsAsUnchanged() {
        let computed = SinceReviewLoader.compute(
            snapshot: snapshot(),
            roundCount: 2,
            detail: detail(headRefOid: "head-2", threads: [thread(id: "PRRT_2", line: 4)]),
            viewerLogin: "octocat"
        )
        XCTAssertEqual(computed.findings.first?.state, .unchanged)
        XCTAssertEqual(computed.unchangedFindingCount, 1)
    }

    func testSomebodyElsesThreadIsNotOneOfYourFindings() {
        let computed = SinceReviewLoader.compute(
            snapshot: snapshot(),
            roundCount: 2,
            detail: detail(
                headRefOid: "head-2",
                threads: [thread(id: "PRRT_3", line: 2, login: "hubot")]
            ),
            viewerLogin: "octocat"
        )
        XCTAssertTrue(computed.findings.isEmpty)
    }

    // MARK: - The inbox row

    func testTheRowChipCountsRoundsAndUnchangedFindings() {
        XCTAssertNil(ReviewRoundsSummary(roundCount: 0, unchangedFindingCount: 0).chipText)
        XCTAssertEqual(
            ReviewRoundsSummary(roundCount: 3, unchangedFindingCount: 0).chipText,
            "3 rounds"
        )
        XCTAssertEqual(
            ReviewRoundsSummary(roundCount: 3, unchangedFindingCount: 2).chipText,
            "3 rounds · 2 findings unchanged"
        )
    }

    func testEveryFindingStateHasALabelAndAnExplanation() {
        for state in FindingState.allCases {
            XCTAssertFalse(state.localizedTitle.isEmpty)
            XCTAssertFalse(state.explanation.isEmpty)
            XCTAssertFalse(state.systemImage.isEmpty)
        }
    }

    func testBothRoundViewsHaveATitle() {
        XCTAssertEqual(RoundView.allCases.count, 2)
        for view in RoundView.allCases {
            XCTAssertFalse(view.title.isEmpty)
        }
    }
}
