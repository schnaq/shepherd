import Foundation
import XCTest

@testable import ShepherdCore

/// The "since my review" interdiff and the finding states it feeds (ADR 0028).
final class InterdiffTests: XCTestCase {
    // MARK: - Fixtures

    private func file(
        _ path: String,
        patch: String?,
        status: FileChangeStatus = .modified,
        previousPath: String? = nil
    ) -> ChangedFile {
        ChangedFile(
            path: path,
            previousPath: previousPath,
            status: status,
            additions: 1,
            deletions: 1,
            patch: patch
        )
    }

    /// Round one: `let b` was changed to `3`.
    private let reviewedPatch = """
        @@ -1,5 +1,5 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
         let d = 5
         let e = 6
        """

    /// Round two: the agent changed the same line again.
    private let currentPatch = """
        @@ -1,5 +1,5 @@
         let a = 1
        -let b = 2
        +let b = 42
         let c = 4
         let d = 5
         let e = 6
        """

    /// Round two: the agent left `let b` alone and inserted a line above it.
    private let shiftedPatch = """
        @@ -1,5 +1,6 @@
         let a = 1
        +let inserted = 0
         let b = 3
         let c = 4
         let d = 5
         let e = 6
        """

    private func thread(
        id: String = "PRRT_1",
        path: String? = "a.swift",
        line: Int? = 2,
        originalLine: Int? = nil,
        isOutdated: Bool = false,
        isResolved: Bool = false,
        comments: [ReviewComment] = []
    ) -> ReviewThread {
        ReviewThread(
            id: id,
            path: path,
            line: line,
            originalLine: originalLine,
            side: .right,
            isResolved: isResolved,
            isOutdated: isOutdated,
            comments: comments.isEmpty ? [comment(login: "octocat")] : comments
        )
    }

    private func comment(
        id: String = "PRRC_1",
        login: String,
        body: String = "This should not force-unwrap.",
        at offset: TimeInterval = 0
    ) -> ReviewComment {
        ReviewComment(
            id: id,
            databaseID: nil,
            author: Fixtures.makeActor(login),
            bodyMarkdown: body,
            createdAt: Fixtures.date(offset)
        )
    }

    // MARK: - The file diff

    func testIdenticalRoundsProduceNothing() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: reviewedPatch)]
        )
        XCTAssertTrue(interdiff.isEmpty)
    }

    func testOneChangedLineIsOneHunkWithAbsoluteLineNumbers() throws {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        XCTAssertEqual(interdiff.count, 1)
        let changed = try XCTUnwrap(interdiff.first)
        XCTAssertEqual(changed.kind, .changed)
        XCTAssertEqual(changed.hunks.count, 1)
        let hunk = try XCTUnwrap(changed.hunks.first)
        XCTAssertEqual(hunk.header, "@@ -1,5 +1,5 @@")
        XCTAssertEqual(hunk.addedCurrentLines, [2])
        XCTAssertEqual(hunk.removedReviewedLines, [2])
        XCTAssertEqual(changed.addedLineCount, 1)
        XCTAssertEqual(changed.removedLineCount, 1)
    }

    func testATrailingNewlineDoesNotBecomeAPhantomLastLine() {
        // Every unified diff ends with a newline; the empty component after it is not a line.
        let patch = "@@ -1,2 +1,2 @@\n first\n-second\n+zweite\n"
        XCTAssertEqual(UnifiedPatch.reconstruct(after: patch), ["first", "zweite"])
        XCTAssertEqual(UnifiedPatch.hunks(in: patch).first?.lines.count, 3)
    }

    func testTheSynthesizedPatchRoundTripsThroughTheReconstructor() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        // The whole document fits inside one hunk plus its context, so the reconstruction of
        // the synthesized patch is the current round's document, line for line.
        XCTAssertEqual(
            UnifiedPatch.reconstruct(after: interdiff.first?.unifiedPatch),
            UnifiedPatch.reconstruct(after: currentPatch)
        )
    }

    func testAnAddedFileIsAWholeFileHunk() throws {
        let added = """
            @@ -0,0 +1,2 @@
            +first
            +second
            """
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [
                file("a.swift", patch: reviewedPatch),
                file("b.swift", patch: added, status: .added),
            ]
        )
        XCTAssertEqual(interdiff.map(\.path), ["b.swift"])
        let entry = try XCTUnwrap(interdiff.first)
        XCTAssertEqual(entry.kind, .added)
        XCTAssertEqual(entry.hunks.first?.header, "@@ -0,0 +1,2 @@")
        XCTAssertEqual(entry.changedFile().status, .added)
        XCTAssertEqual(UnifiedPatch.reconstruct(after: entry.unifiedPatch), ["first", "second"])
    }

    func testAFileThatLeftTheDiffIsRemoved() throws {
        let interdiff = Interdiff.compute(
            before: [
                file("a.swift", patch: reviewedPatch),
                file("b.swift", patch: "@@ -0,0 +1,2 @@\n+first\n+second", status: .added),
            ],
            after: [file("a.swift", patch: reviewedPatch)]
        )
        XCTAssertEqual(interdiff.map(\.path), ["b.swift"])
        let entry = try XCTUnwrap(interdiff.first)
        XCTAssertEqual(entry.kind, .removed)
        XCTAssertEqual(entry.hunks.first?.header, "@@ -1,2 +0,0 @@")
        XCTAssertEqual(entry.removedLineCount, 2)
        XCTAssertEqual(entry.changedFile().status, .removed)
    }

    func testARenameIsListedEvenWithIdenticalContent() throws {
        let interdiff = Interdiff.compute(
            before: [file("old.swift", patch: reviewedPatch)],
            after: [
                file(
                    "new.swift",
                    patch: reviewedPatch,
                    status: .renamed,
                    previousPath: "old.swift"
                )
            ]
        )
        let entry = try XCTUnwrap(interdiff.first)
        XCTAssertEqual(entry.kind, .renamed)
        XCTAssertEqual(entry.previousPath, "old.swift")
        XCTAssertTrue(entry.hunks.isEmpty)
        // No hunks means no patch to render: the viewer shows the file as unavailable rather
        // than an empty diff, and the finding state is what carries the information.
        XCTAssertNil(entry.changedFile().patch)
    }

    func testDistantChangesBecomeSeparateHunks() throws {
        let before = """
            @@ -1,12 +1,12 @@
             l1
            -l2
            +l2b
             l3
             l4
             l5
             l6
             l7
             l8
             l9
             l10
            -l11
            +l11b
             l12
            """
        let after = before
            .replacingOccurrences(of: "+l2b", with: "+l2c")
            .replacingOccurrences(of: "+l11b", with: "+l11c")
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: before)],
            after: [file("a.swift", patch: after)]
        )
        let changed = try XCTUnwrap(interdiff.first)
        XCTAssertEqual(changed.hunks.map(\.header), ["@@ -1,5 +1,5 @@", "@@ -8,5 +8,5 @@"])
        let rebuilt = UnifiedPatch.reconstruct(after: changed.unifiedPatch)
        XCTAssertEqual(rebuilt.count, 12)
        XCTAssertEqual(rebuilt[1], "l2c")
        XCTAssertEqual(rebuilt[10], "l11c")
        // The lines between the hunks are padding, not content: a synthesized patch carries
        // only what changed, exactly like GitHub's own.
        XCTAssertEqual(rebuilt[5], "")
    }

    // MARK: - Finding states

    func testAChangedAnchorIsAddressed() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: thread(line: 2),
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .addressed
        )
    }

    func testAnUntouchedAnchorInAChangedFileIsUnchanged() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: thread(line: 5),
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .unchanged
        )
    }

    func testAShiftedAnchorIsMoved() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: shiftedPatch)]
        )
        // `let b` was line 2 when it was reviewed and is line 3 now.
        XCTAssertEqual(
            FindingState.classify(
                thread: thread(line: 3),
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .moved
        )
    }

    func testARenamedFileMakesEveryFindingInItMoved() {
        let interdiff = Interdiff.compute(
            before: [file("old.swift", patch: reviewedPatch)],
            after: [
                file(
                    "new.swift",
                    patch: reviewedPatch,
                    status: .renamed,
                    previousPath: "old.swift"
                )
            ]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: thread(path: "old.swift", line: 2),
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .moved
        )
    }

    func testANewerCommentBySomebodyElseIsReplied() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        let answered = thread(
            line: 5,
            comments: [
                comment(id: "PRRC_1", login: "octocat", at: 0),
                comment(id: "PRRC_2", login: "claude[bot]", body: "Done.", at: 60),
            ]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: answered,
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .replied
        )
    }

    func testAChangedAnchorOutranksAReply() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        let answered = thread(
            line: 2,
            comments: [
                comment(id: "PRRC_1", login: "octocat", at: 0),
                comment(id: "PRRC_2", login: "claude[bot]", body: "Done.", at: 60),
            ]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: answered,
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .addressed
        )
    }

    func testAnOutdatedThreadIsClassifiedByTheLineItWasWrittenAgainst() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: thread(line: nil, originalLine: 2, isOutdated: true),
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .addressed
        )
    }

    func testAFileNobodyTouchedLeavesItsFindingsUnchanged() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        XCTAssertEqual(
            FindingState.classify(
                thread: thread(path: "other.swift", line: 9),
                interdiff: interdiff,
                viewerLogin: "octocat"
            ),
            .unchanged
        )
    }

    // MARK: - The findings list

    func testFindingsAreTheViewersOwnUnresolvedThreads() {
        let interdiff = Interdiff.compute(
            before: [file("a.swift", patch: reviewedPatch)],
            after: [file("a.swift", patch: currentPatch)]
        )
        let threads = [
            thread(id: "mine", line: 2, comments: [comment(login: "octocat", at: -60)]),
            thread(
                id: "somebody-else",
                line: 2,
                comments: [comment(login: "hubot", at: -60)]
            ),
            thread(
                id: "resolved",
                line: 2,
                isResolved: true,
                comments: [comment(login: "octocat", at: -60)]
            ),
            thread(id: "later-round", line: 2, comments: [comment(login: "octocat", at: 3_600)]),
        ]
        let findings = ReviewFindings.compute(
            threads: threads,
            interdiff: interdiff,
            viewerLogin: "octocat",
            reviewedAt: Fixtures.date(0)
        )
        XCTAssertEqual(findings.map(\.threadID), ["mine"])
        XCTAssertEqual(findings.first?.state, .addressed)
        XCTAssertEqual(findings.first?.excerpt, "This should not force-unwrap.")
        XCTAssertEqual(findings.first?.line, 2)
        XCTAssertFalse(findings.first?.isLineOutdated ?? true)
    }

    func testFindingsWithoutASnapshotTimestampKeepEveryThreadOfTheViewer() {
        let findings = ReviewFindings.compute(
            threads: [
                thread(id: "one", comments: [comment(login: "octocat", at: 0)]),
                thread(id: "two", comments: [comment(login: "octocat", at: 7_200)]),
            ],
            interdiff: [],
            viewerLogin: "OCTOCAT",
            reviewedAt: nil
        )
        XCTAssertEqual(findings.map(\.threadID), ["one", "two"])
        XCTAssertEqual(findings.map(\.state), [.unchanged, .unchanged])
    }
}
