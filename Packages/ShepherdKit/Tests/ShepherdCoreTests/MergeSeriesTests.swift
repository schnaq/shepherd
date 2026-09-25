import Foundation
import XCTest

@testable import ShepherdCore

/// The merge-series model: what it reports about itself, and how it survives storage (ADR 0041).
final class MergeSeriesTests: XCTestCase {
    private let clock = Fixtures.date(0)

    private func series(_ states: [MergeSeriesEntryState]) -> MergeSeries {
        MergeSeries(
            id: "S1",
            repository: Fixtures.repo,
            mergeMethod: "squash",
            deletesHeadBranch: true,
            createdAt: clock,
            entries: states.enumerated().map { offset, state in
                MergeSeriesEntry(
                    prID: "PR_\(offset)",
                    slug: "schnaq/review#\(offset)",
                    number: offset,
                    title: "Title",
                    pinnedHeadOid: "h\(offset)",
                    state: state,
                    activeSince: clock,
                    updateQueuedAt: offset == 2 ? clock : nil
                )
            }
        )
    }

    // MARK: - Reading

    func testTheActiveEntryIsTheFirstNeitherMergedNorSkipped() {
        let current = series([.merged, .skipped(.draft), .merging, .pending])
        XCTAssertEqual(current.activeEntry?.prID, "PR_2")
        XCTAssertEqual(current.activeIndex, 2)
        XCTAssertFalse(current.isFinished)
    }

    func testASeriesIsFinishedOnceEveryEntryIsMergedOrSkipped() {
        let current = series([.merged, .skipped(.draft), .merged])
        XCTAssertNil(current.activeEntry)
        XCTAssertTrue(current.isFinished)
        XCTAssertEqual(current.mergedCount, 2)
        XCTAssertEqual(current.skippedCount, 1)
    }

    func testAnEmptySeriesIsFinished() {
        XCTAssertTrue(series([]).isFinished)
    }

    func testPositionIsZeroBasedWithTheTotal() {
        let current = series([.pending, .pending, .pending])
        let position = current.position(of: "PR_1")
        XCTAssertEqual(position?.index, 1)
        XCTAssertEqual(position?.total, 3)
        XCTAssertNil(current.position(of: "PR_9"))
    }

    func testANewSeriesPinsEveryRowToItsCurrentHeadInTheGivenOrder() {
        let rows = [
            Fixtures.summary(id: "B", number: 2, headRefOid: "hb"),
            Fixtures.summary(id: "A", number: 1, headRefOid: "ha"),
        ]
        let current = MergeSeries(
            repository: Fixtures.repo,
            pullRequests: rows,
            mergeMethod: "rebase",
            deletesHeadBranch: false,
            id: "X",
            now: clock
        )
        XCTAssertEqual(current.entries.map(\.prID), ["B", "A"])
        XCTAssertEqual(current.entries.map(\.pinnedHeadOid), ["hb", "ha"])
        XCTAssertEqual(current.entries.map(\.slug), ["schnaq/review#2", "schnaq/review#1"])
        XCTAssertEqual(current.entries.map(\.state), [.pending, .pending])
        XCTAssertNil(current.entries.first?.activeSince)
        XCTAssertEqual(current.createdAt, clock)
        XCTAssertEqual(current.mergeMethod, "rebase")
    }

    func testTheListFindsOnlyTheRunningSeriesOfAPullRequest() {
        let finished = series([.merged])
        var running = series([.pending])
        running.id = "S2"
        let list = MergeSeriesList(series: [finished, running])
        XCTAssertEqual(list.series(containing: "PR_0")?.id, "S2")
        XCTAssertNil(list.series(containing: "PR_7"))
        XCTAssertNil(MergeSeriesList(series: [finished]).series(containing: "PR_0"))
    }

    // MARK: - Persistence

    func testASeriesWithEveryStateRoundTripsThroughJSON() throws {
        let original = series([
            .pending,
            .updatingBranch(from: "a"),
            .branchUpdated(from: "b"),
            .merging,
            .merged,
        ] + MergeSeriesSkipReason.allCases.map { .skipped($0) })
        let list = MergeSeriesList(series: [original])
        let decoded = try JSONDecoder().decode(MergeSeriesList.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(decoded, list)
    }

    func testAnEntryFromAnotherBuildDecodesTolerantly() throws {
        let json = """
        {"series":[{"id":"S","repository":{"owner":"o","name":"n"},"mergeMethod":"merge",
        "entries":[{"prID":"PR_1","pinnedHeadOid":"h","state":{"kind":"pending"},"laterField":1}]}]}
        """
        let decoded = try JSONDecoder().decode(MergeSeriesList.self, from: Data(json.utf8))
        let current = try XCTUnwrap(decoded.series.first)
        XCTAssertEqual(current.repository, RepoRef(owner: "o", name: "n"))
        XCTAssertFalse(current.deletesHeadBranch, "an unknown branch answer is the cautious one")
        let entry = try XCTUnwrap(current.entries.first)
        XCTAssertEqual(entry.prID, "PR_1")
        XCTAssertEqual(entry.pinnedHeadOid, "h")
        XCTAssertEqual(entry.state, .pending)
        XCTAssertEqual(entry.slug, "")
        XCTAssertNil(entry.activeSince)
        XCTAssertNil(entry.updateQueuedAt)
    }

    func testAnUnreadableStateBecomesATerminalSkipRatherThanAWrite() throws {
        let states = [
            #"{"kind":"rebasingStack"}"#,
            #"{"kind":"skipped","reason":"someLaterReason"}"#,
            #"{"kind":"updatingBranch"}"#,
            #""pending""#,
        ]
        for state in states {
            let json = #"{"prID":"PR_1","pinnedHeadOid":"h","state":\#(state)}"#
            let entry = try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(json.utf8))
            XCTAssertEqual(entry.state, .skipped(.disappeared), state)
        }
        let missing = try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(#"{"prID":"PR_1"}"#.utf8))
        XCTAssertEqual(missing.state, .skipped(.disappeared))
    }

    func testAnEntryWithoutAPinSkipsAsHeadMovedInsteadOfMerging() throws {
        let json = #"{"prID":"PR_1","state":{"kind":"pending"}}"#
        let entry = try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.pinnedHeadOid, "")
        let current = MergeSeries(
            id: "S", repository: Fixtures.repo, mergeMethod: "squash",
            deletesHeadBranch: false, createdAt: clock, entries: [entry]
        )
        let row = Fixtures.summary(
            id: "PR_1",
            headRefOid: "real",
            checkRollup: CheckRollup(state: .success, total: 1, successCount: 1)
        )
        let result = MergeSeriesPolicy.step(
            series: current, rows: ["PR_1": row], existingOutbox: [], failedWrites: [],
            now: clock, gracePeriod: 60
        )
        XCTAssertEqual(result.series.entry(for: "PR_1")?.state, .skipped(.headMoved))
        XCTAssertEqual(result.action, .none)
    }

    func testAnUnreadableListIsEmptyRatherThanFatal() throws {
        let decoded = try JSONDecoder().decode(MergeSeriesList.self, from: Data(#"{"series":"nonsense"}"#.utf8))
        XCTAssertEqual(decoded.series, [])
        let entries = try JSONDecoder().decode(
            MergeSeries.self,
            from: Data(#"{"id":"S","entries":"nonsense"}"#.utf8)
        )
        XCTAssertEqual(entries.entries, [])
        XCTAssertTrue(entries.isFinished)
    }

    func testAMergingEntryIsRemovableOnlyWhenTheCallerSaysItsRowIsGone() {
        var series = MergeSeries(
            repository: RepoRef(owner: "schnaq", name: "review"),
            mergeMethod: "squash",
            deletesHeadBranch: false,
            createdAt: Date(timeIntervalSince1970: 0),
            entries: [
                MergeSeriesEntry(prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a", state: .merging),
                MergeSeriesEntry(prID: "B", slug: "s#2", number: 2, title: "B", pinnedHeadOid: "b", state: .merging),
                MergeSeriesEntry(prID: "C", slug: "s#3", number: 3, title: "C", pinnedHeadOid: "c"),
            ]
        )
        XCTAssertFalse(series.remove("A"))
        XCTAssertTrue(series.remove("A", hasNoUnsentWrite: true))
        XCTAssertEqual(series.entry(for: "A")?.state, .skipped(.removedByUser))

        series.cancel(withoutUnsentWrites: [])
        XCTAssertEqual(series.entry(for: "B")?.state, .merging)
        XCTAssertEqual(series.entry(for: "C")?.state, .skipped(.removedByUser))
        series.cancel(withoutUnsentWrites: ["B"])
        XCTAssertEqual(series.entry(for: "B")?.state, .skipped(.removedByUser))
        XCTAssertTrue(series.isFinished)
    }

    func testAnEntryUpdatingItsBranchIsRemovableOnlyWhenTheCallerSaysItsRowIsGone() {
        var series = MergeSeries(
            repository: RepoRef(owner: "schnaq", name: "review"),
            mergeMethod: "squash",
            deletesHeadBranch: false,
            createdAt: Date(timeIntervalSince1970: 0),
            entries: [
                MergeSeriesEntry(prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a", state: .updatingBranch(from: "a")),
            ]
        )
        XCTAssertFalse(series.remove("A"), "its update is still to go out, and the entry keeps the alert down")
        XCTAssertEqual(series.entry(for: "A")?.state, .updatingBranch(from: "a"))
        XCTAssertTrue(series.remove("A", hasNoUnsentWrite: true))
        XCTAssertEqual(series.entry(for: "A")?.state, .skipped(.removedByUser))
    }

    func testCancelLetsAnUnsentUpdateGoOutAndThenRemovesItsEntryInsteadOfMergingIt() {
        var series = MergeSeries(
            repository: RepoRef(owner: "schnaq", name: "review"),
            mergeMethod: "squash",
            deletesHeadBranch: false,
            createdAt: Date(timeIntervalSince1970: 0),
            entries: [
                MergeSeriesEntry(prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a", state: .updatingBranch(from: "a")),
                MergeSeriesEntry(prID: "B", slug: "s#2", number: 2, title: "B", pinnedHeadOid: "b"),
            ]
        )
        series.cancel()
        XCTAssertEqual(series.entry(for: "A")?.state, .updatingBranch(from: "a"), "still waiting for its update")
        XCTAssertEqual(series.entry(for: "A")?.removalRequested, true)
        XCTAssertEqual(series.entry(for: "B")?.state, .skipped(.removedByUser))

        XCTAssertTrue(series.markBranchUpdated("A"))
        XCTAssertEqual(series.entry(for: "A")?.state, .skipped(.removedByUser), "no merge after a Cancel")
        XCTAssertTrue(series.isFinished)
    }

    func testTheRemovalRequestSurvivesARoundTripAndDefaultsToNo() throws {
        let entry = MergeSeriesEntry(
            prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a",
            state: .updatingBranch(from: "a"), removalRequested: true
        )
        let decoded = try JSONDecoder().decode(MergeSeriesEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        let older = #"{"prID":"A","slug":"s#1","number":1,"title":"A","pinnedHeadOid":"a","state":{"kind":"pending"}}"#
        XCTAssertFalse(try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(older.utf8)).removalRequested)
    }

    func testAnEntryFromAnOlderBuildDecodesWithoutAMergeTimestamp() throws {
        let json = #"{"prID":"A","slug":"s#1","number":1,"title":"A","pinnedHeadOid":"a","state":{"kind":"merging"}}"#
        let entry = try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.state, .merging)
        XCTAssertNil(entry.mergeQueuedAt)
    }

    // MARK: - Stacks (ADR 0042)

    func testANewSeriesRemembersEachRowsPlaceInItsStack() {
        var stacked = Fixtures.summary(id: "A", headRefOid: "a")
        stacked.stack = PullRequestStack(number: 7, size: 3, position: 2, baseRefName: "main")
        let loose = Fixtures.summary(id: "B", headRefOid: "b")
        let series = MergeSeries(
            repository: Fixtures.repo,
            pullRequests: [stacked, loose],
            mergeMethod: "squash",
            deletesHeadBranch: false,
            now: clock
        )
        XCTAssertEqual(series.entries[0].stackNumber, 7)
        XCTAssertEqual(series.entries[0].stackPosition, 2)
        XCTAssertNil(series.entries[1].stackNumber)
        XCTAssertNil(series.entries[1].stackPosition)
    }

    func testANewSeriesNeverMergesAStackTopFirstWhateverOrderItWasGiven() {
        // The user dragged the top of the stack ahead of its bottom, with a loose pull request in
        // between. Merging the top first would take the bottom along unchecked.
        var top = Fixtures.summary(id: "TOP", headRefOid: "t")
        top.stack = PullRequestStack(number: 7, size: 2, position: 2, baseRefName: "main")
        let loose = Fixtures.summary(id: "LOOSE", headRefOid: "l")
        var bottom = Fixtures.summary(id: "BOTTOM", headRefOid: "b")
        bottom.stack = PullRequestStack(number: 7, size: 2, position: 1, baseRefName: "main")
        let series = MergeSeries(
            repository: Fixtures.repo,
            pullRequests: [top, loose, bottom],
            mergeMethod: "squash",
            deletesHeadBranch: false,
            now: clock
        )
        XCTAssertEqual(series.entries.map(\.prID), ["BOTTOM", "LOOSE", "TOP"])
        XCTAssertEqual(series.entries.map(\.pinnedHeadOid), ["b", "l", "t"])
    }

    func testTheStackFieldsSurviveARoundTrip() throws {
        let entry = MergeSeriesEntry(
            prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a",
            state: .merging,
            stackNumber: 7,
            stackPosition: 2,
            repinnedAfterStackMerge: true,
            restackWaitSince: Fixtures.date(10),
            mergeAcceptedAt: Fixtures.date(20)
        )
        let decoded = try JSONDecoder().decode(MergeSeriesEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
    }

    func testAnEntryFromBeforeStacksDecodesAsInNoStack() throws {
        let json = #"{"prID":"A","slug":"s#1","number":1,"title":"A","pinnedHeadOid":"a","state":{"kind":"merging"}}"#
        let entry = try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.stackNumber)
        XCTAssertNil(entry.stackPosition)
        XCTAssertFalse(entry.repinnedAfterStackMerge)
        XCTAssertNil(entry.restackWaitSince)
        XCTAssertNil(entry.mergeAcceptedAt)
    }

    func testAnAcceptedMergeIsRecordedOnceAndOnlyOnAMergingEntry() {
        var current = series([.merging, .pending])
        XCTAssertTrue(current.markMergeAccepted("PR_0", at: Fixtures.date(5)))
        XCTAssertEqual(current.entries[0].state, .merging, "accepted is not merged")
        XCTAssertEqual(current.entries[0].mergeAcceptedAt, Fixtures.date(5))
        XCTAssertFalse(current.markMergeAccepted("PR_0", at: Fixtures.date(50)), "the first acceptance counts")
        XCTAssertEqual(current.entries[0].mergeAcceptedAt, Fixtures.date(5))
        XCTAssertFalse(current.markMergeAccepted("PR_1", at: Fixtures.date(5)))
        XCTAssertNil(current.entries[1].mergeAcceptedAt)
        XCTAssertFalse(current.markMergeAccepted("PR_9", at: Fixtures.date(5)))
    }

    func testAnUnconfirmedMergeIsWaitedForTheGracePeriodFromWhenItWasQueued() {
        let entry = MergeSeriesEntry(
            prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a",
            state: .merging, activeSince: Fixtures.date(0), mergeQueuedAt: Fixtures.date(100)
        )
        XCTAssertEqual(entry.unconfirmedMergeDeadline(gracePeriod: 3_600, now: Fixtures.date(999)), Fixtures.date(3_700))
    }

    func testAMergeGitHubAcceptedIsWaitedForADayFromTheAcceptance() {
        let entry = MergeSeriesEntry(
            prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a",
            state: .merging, mergeQueuedAt: Fixtures.date(100), mergeAcceptedAt: Fixtures.date(130)
        )
        XCTAssertEqual(MergeSeriesEntry.acceptedMergeGracePeriod, 24 * 3_600)
        XCTAssertEqual(
            entry.unconfirmedMergeDeadline(gracePeriod: 3_600, now: Fixtures.date(999)),
            Fixtures.date(130 + 24 * 3_600)
        )
    }

    func testAStackedMergeIsWaitedForADayEvenWhenTheAcceptanceWasNeverSeen() {
        // The acceptance event lives in memory only; an app that quit before it arrived still
        // knows from the entry that this merge went through GitHub's asynchronous path.
        let entry = MergeSeriesEntry(
            prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a",
            state: .merging, mergeQueuedAt: Fixtures.date(100), stackNumber: 7, stackPosition: 1
        )
        XCTAssertEqual(
            entry.unconfirmedMergeDeadline(gracePeriod: 3_600, now: Fixtures.date(999)),
            Fixtures.date(100 + 24 * 3_600)
        )
    }

    func testAnUnconfirmedMergeWithoutAnyTimestampCountsFromNow() {
        let entry = MergeSeriesEntry(
            prID: "A", slug: "s#1", number: 1, title: "A", pinnedHeadOid: "a", state: .merging
        )
        XCTAssertEqual(entry.unconfirmedMergeDeadline(gracePeriod: 60, now: Fixtures.date(10)), Fixtures.date(70))
    }
}
