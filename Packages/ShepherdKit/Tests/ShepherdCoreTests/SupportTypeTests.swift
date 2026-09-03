import XCTest
@testable import ShepherdCore

final class GlobPatternTests: XCTestCase {
    func testMatchesLiterals() {
        XCTAssertTrue(GlobPattern("claude[bot]").matches("claude[bot]"))
        XCTAssertFalse(GlobPattern("claude[bot]").matches("claude"))
    }

    func testStarMatchesAnyRun() {
        XCTAssertTrue(GlobPattern("acme-*").matches("acme-releaser"))
        XCTAssertTrue(GlobPattern("acme-*").matches("acme-"))
        XCTAssertFalse(GlobPattern("acme-*").matches("acme"))
        XCTAssertTrue(GlobPattern("*bot*").matches("some-bot-account"))
        XCTAssertTrue(GlobPattern("*").matches(""))
    }

    func testQuestionMarkMatchesExactlyOneCharacter() {
        XCTAssertTrue(GlobPattern("bo?").matches("bot"))
        XCTAssertFalse(GlobPattern("bo?").matches("bo"))
        XCTAssertFalse(GlobPattern("bo?").matches("bots"))
    }

    func testCaseSensitivityIsOptional() {
        XCTAssertTrue(GlobPattern("Claude*").matches("claude[bot]"))
        XCTAssertFalse(GlobPattern("Claude*").matches("claude[bot]", caseSensitive: true))
    }

    func testBacktrackingHandlesRepeatedStars() {
        XCTAssertTrue(GlobPattern("*a*b*c*").matches("xxaxxbxxcxx"))
        XCTAssertFalse(GlobPattern("*a*b*c*").matches("xxaxxcxxbxx"))
    }
}

final class CommitInfoTests: XCTestCase {
    func testSplitsHeadlineFromBody() {
        let (headline, body) = CommitInfo.splitMessage("feat: add inbox\n\nDetails here.\n")
        XCTAssertEqual(headline, "feat: add inbox")
        XCTAssertEqual(body, "\nDetails here.\n")
    }

    func testMessageWithoutBody() {
        let (headline, body) = CommitInfo.splitMessage("fix: typo")
        XCTAssertEqual(headline, "fix: typo")
        XCTAssertEqual(body, "")
    }

    func testParsesTrailers() {
        let trailers = CommitInfo.parseTrailers(in: """

            Some prose that is not a trailer.
            Co-Authored-By: Claude <noreply@anthropic.com>
            Signed-off-by: Someone <s@example.com>
            not a trailer at all
            """)
        XCTAssertEqual(trailers.count, 2)
        XCTAssertTrue(trailers.contains("Co-Authored-By: Claude <noreply@anthropic.com>"))
        XCTAssertTrue(trailers.contains("Signed-off-by: Someone <s@example.com>"))
    }

    func testTrailersAreDerivedFromTheBodyWhenNotSupplied() {
        let commit = CommitInfo(
            oid: "abc",
            messageHeadline: "feat: x",
            messageBody: "Co-Authored-By: Claude",
            committedDate: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(commit.trailers, ["Co-Authored-By: Claude"])
    }
}

final class OutboxBackoffTests: XCTestCase {
    func testBackoffGrowsExponentiallyThenPlateaus() {
        XCTAssertEqual(OutboxBackoff.delay(forAttempt: 0), 0)
        XCTAssertEqual(OutboxBackoff.delay(forAttempt: 1), 5)
        XCTAssertEqual(OutboxBackoff.delay(forAttempt: 2), 10)
        XCTAssertEqual(OutboxBackoff.delay(forAttempt: 3), 20)
        XCTAssertEqual(OutboxBackoff.delay(forAttempt: 20), 900)
    }

    func testBackoffIsMonotonic() {
        var previous = 0.0
        for attempt in 1...12 {
            let delay = OutboxBackoff.delay(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }
}

final class ModelCodingTests: XCTestCase {
    func testPullRequestSummaryRoundTripsThroughJSON() throws {
        let summary = Fixtures.summary(
            id: "PR_kwDO",
            author: Fixtures.makeActor(
                "claude[bot]",
                kind: Fixtures.agent("claude-code", "Claude Code")
            ),
            reviewDecision: .changesRequested,
            checkRollup: CheckRollup(
                state: .failure,
                total: 3,
                successCount: 1,
                failureCount: 1,
                pendingCount: 1
            ),
            relations: [.reviewRequested, .mentioned],
            labels: ["bug", "agent"]
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(PullRequestSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
        XCTAssertEqual(decoded.author.kind.agentIdentity?.id, "claude-code")
    }

    func testReviewDraftRoundTripsThroughJSON() throws {
        let draft = ReviewDraft(
            prID: "PR_1",
            verdict: .requestChanges,
            summaryBody: "Please fix the token handling.",
            comments: [
                DraftComment(path: "Sources/A.swift", line: 12, side: .right, body: "Nit."),
                DraftComment(
                    path: "Sources/B.swift",
                    line: 40,
                    side: .left,
                    startLine: 30,
                    body: "This leaks."
                ),
            ],
            basedOnHeadOid: "deadbeef",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(ReviewDraft.self, from: data), draft)
    }

    func testOutboxActionRoundTripsThroughJSON() throws {
        let actions: [OutboxAction] = [
            .submitReview(ReviewDraft(prID: "PR_1", basedOnHeadOid: "abc")),
            .replyToComment(commentDatabaseID: 42, body: "Thanks!"),
            .resolveThread(threadID: "RT_1"),
            .unresolveThread(threadID: "RT_2"),
            .merge(method: "squash", expectedHeadOid: "abc"),
            .markReadyForReview,
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(OutboxAction.self, from: data), action)
        }
        XCTAssertEqual(
            actions.map(\.kind),
            [
                "submitReview", "replyToComment", "resolveThread", "unresolveThread",
                "merge", "markReadyForReview",
            ]
        )
    }

    func testTheFiveIssueActionsRoundTripThroughJSON() throws {
        let queuedAt = Date(timeIntervalSince1970: 1_788_162_000)
        let actions: [OutboxAction] = [
            .addIssueComment(body: "On it.", basedOnUpdatedAt: queuedAt),
            .addIssueLabel(name: "needs-triage", basedOnUpdatedAt: queuedAt),
            .addIssueAssignee(login: "octocat", basedOnUpdatedAt: queuedAt),
            .closeIssue(reason: .completed, basedOnUpdatedAt: queuedAt),
            .closeIssue(reason: .notPlanned, basedOnUpdatedAt: queuedAt),
            .reopenIssue(basedOnUpdatedAt: queuedAt),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(OutboxAction.self, from: data), action)
        }
        XCTAssertEqual(
            actions.map(\.kind),
            [
                "addIssueComment", "addIssueLabel", "addIssueAssignee", "closeIssue",
                "closeIssue", "reopenIssue",
            ]
        )
        // Every one of them carries the staleness key, which is what the drain's precondition
        // reads: a case that forgot it would answer `nil` here and would be sent blind.
        XCTAssertEqual(actions.map(\.basedOnIssueUpdatedAt), Array(repeating: queuedAt, count: 6))
        XCTAssertTrue(actions.allSatisfy(\.targetsIssue))
    }

    func testAPullRequestActionCarriesNoIssueStalenessKey() {
        let actions: [OutboxAction] = [
            .submitReview(ReviewDraft(prID: "PR_1", basedOnHeadOid: "abc")),
            .replyToComment(commentDatabaseID: 42, body: "Thanks!"),
            .resolveThread(threadID: "RT_1"),
            .unresolveThread(threadID: "RT_2"),
            .merge(method: "squash", expectedHeadOid: "abc"),
            .markReadyForReview,
        ]
        XCTAssertTrue(actions.allSatisfy { $0.basedOnIssueUpdatedAt == nil })
        XCTAssertTrue(actions.allSatisfy { !$0.targetsIssue })
    }

    func testARowWrittenBeforeTheIssueActionsExistedStillDecodes() throws {
        // The bytes an older build wrote: the payload column is an opaque blob of this very
        // enum, so "no migration" is only true if the old discriminators still decode.
        let legacy = Data(#"{"resolveThread":{"threadID":"RT_legacy"}}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(OutboxAction.self, from: legacy),
            .resolveThread(threadID: "RT_legacy")
        )
    }

    func testTheCloseReasonsAreGitHubsOwnTwoWords() {
        XCTAssertEqual(
            IssueCloseReason.allCases.map(\.rawValue).sorted(),
            ["completed", "not_planned"]
        )
    }

    func testCheckRollupIsDerivedFromRuns() {
        let runs = [
            CheckRun(id: "1", name: "build", status: .completed, conclusion: .success),
            CheckRun(id: "2", name: "test", status: .completed, conclusion: .failure),
            CheckRun(id: "3", name: "lint", status: .inProgress),
            CheckRun(id: "4", name: "skipped", status: .completed, conclusion: .skipped),
        ]
        let rollup = CheckRollup(runs: runs)
        XCTAssertEqual(rollup.state, .failure)
        XCTAssertEqual(rollup.total, 4)
        XCTAssertEqual(rollup.successCount, 2)
        XCTAssertEqual(rollup.failureCount, 1)
        XCTAssertEqual(rollup.pendingCount, 1)
    }

    func testEmptyCheckListRollsUpToNone() {
        XCTAssertEqual(CheckRollup(runs: []).state, CheckRollup.State.none)
    }

    func testRepoRefParsing() {
        XCTAssertEqual(RepoRef.parse(fullName: "schnaq/review"), Fixtures.repo)
        XCTAssertNil(RepoRef.parse(fullName: "schnaq"))
        XCTAssertNil(RepoRef.parse(fullName: "schnaq/review/extra"))
        XCTAssertNil(RepoRef.parse(fullName: "/review"))
    }

    func testChangedFileConveniences() {
        let file = Fixtures.file("web/diff-viewer/src/Bridge.ts", additions: 5, deletions: 3)
        XCTAssertEqual(file.fileName, "Bridge.ts")
        XCTAssertEqual(file.fileExtension, "ts")
        XCTAssertEqual(file.churn, 8)
        XCTAssertTrue(file.hasPatch)
        XCTAssertNil(Fixtures.file("Makefile").fileExtension)
    }

    func testFileChangeStatusMapsUnknownValuesToModified() {
        XCTAssertEqual(FileChangeStatus.fromAPI("added"), .added)
        XCTAssertEqual(FileChangeStatus.fromAPI("removed"), .removed)
        XCTAssertEqual(FileChangeStatus.fromAPI("renamed"), .renamed)
        XCTAssertEqual(FileChangeStatus.fromAPI("copied"), .modified)
        XCTAssertEqual(FileChangeStatus.fromAPI("nonsense"), .modified)
    }
}

final class ConditionalCacheTests: XCTestCase {
    func testInMemoryCacheStoresAndRemoves() async {
        let cache = InMemoryConditionalCache()
        let entry = ConditionalCacheEntry(
            etag: "W/\"abc\"",
            lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
            payload: Data("body".utf8),
            storedAt: Date(timeIntervalSince1970: 1)
        )
        await cache.store(entry, for: "https://api.github.com/notifications")

        let fetched = await cache.entry(for: "https://api.github.com/notifications")
        XCTAssertEqual(fetched, entry)
        XCTAssertTrue(entry.isUsable)

        await cache.remove(for: "https://api.github.com/notifications")
        let afterRemoval = await cache.entry(for: "https://api.github.com/notifications")
        XCTAssertNil(afterRemoval)
    }

    func testRemoveAllEmptiesTheCache() async {
        let cache = InMemoryConditionalCache()
        await cache.store(ConditionalCacheEntry(etag: "1"), for: "a")
        await cache.store(ConditionalCacheEntry(etag: "2"), for: "b")
        var count = await cache.count
        XCTAssertEqual(count, 2)
        await cache.removeAll()
        count = await cache.count
        XCTAssertEqual(count, 0)
    }
}

final class SleepingTests: XCTestCase {
    func testRecordingSleeperDoesNotWaitButRemembers() async throws {
        let sleeper = RecordingSleeper()
        try await sleeper.sleep(for: .seconds(120))
        try await sleeper.sleep(for: .milliseconds(500))
        let recorded = await sleeper.recorded
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first?.inSeconds ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(recorded.last?.inSeconds ?? 0, 0.5, accuracy: 0.001)
    }
}
