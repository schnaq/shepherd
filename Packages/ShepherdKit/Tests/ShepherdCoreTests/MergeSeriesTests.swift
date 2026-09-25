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
        XCTAssertTrue(series.remove("A", mergingIsRemovable: true))
        XCTAssertEqual(series.entry(for: "A")?.state, .skipped(.removedByUser))

        series.cancel(removableMerging: [])
        XCTAssertEqual(series.entry(for: "B")?.state, .merging)
        XCTAssertEqual(series.entry(for: "C")?.state, .skipped(.removedByUser))
        series.cancel(removableMerging: ["B"])
        XCTAssertEqual(series.entry(for: "B")?.state, .skipped(.removedByUser))
        XCTAssertTrue(series.isFinished)
    }

    func testAnEntryFromAnOlderBuildDecodesWithoutAMergeTimestamp() throws {
        let json = #"{"prID":"A","slug":"s#1","number":1,"title":"A","pinnedHeadOid":"a","state":{"kind":"merging"}}"#
        let entry = try JSONDecoder().decode(MergeSeriesEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.state, .merging)
        XCTAssertNil(entry.mergeQueuedAt)
    }
}
