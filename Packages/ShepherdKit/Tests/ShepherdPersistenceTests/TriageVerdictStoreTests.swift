import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// The v4 triage verdicts (ADR 0023): the round trip, the upsert, the pruning that is a foreign
/// key, and what happens to a row this version cannot read.
///
/// In-memory `DatabaseQueue` like every other persistence suite, so it behaves identically on the
/// macOS and the Linux runner.
final class TriageVerdictStoreTests: XCTestCase {
    private func entry(
        prID: String = "PR_1",
        documentHash: String = "hash-1",
        kind: TriageVerdict.Kind = .fix,
        risk: TriageVerdict.Risk = .high,
        reason: String = "Touches the auth middleware and deletes two tests.",
        model: String = "test-model",
        classifiedAt: TimeInterval = 0
    ) -> TriageVerdictEntry {
        TriageVerdictEntry(
            prID: prID,
            documentHash: documentHash,
            verdict: TriageVerdict(kind: kind, risk: risk, reason: reason),
            modelIdentifier: model,
            classifiedAt: PersistenceFixtures.date(classifiedAt)
        )
    }

    func testTheSchemaGainsV4AndStaysAppendOnly() async throws {
        // Append-only: v4 is still the fourth migration whatever came after it; the full list
        // lives in `DatabaseManagerTests`.
        XCTAssertEqual(Array(DatabaseManager.migrator.migrations.prefix(4)), ["v1", "v2", "v3", "v4"])
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let columns = try db.columns(in: "triage_verdicts").map(\.name)
            XCTAssertEqual(
                columns.sorted(),
                [
                    "classifiedAt",
                    "documentHash",
                    "kind",
                    "modelIdentifier",
                    "prID",
                    "reason",
                    "risk",
                ]
            )
        }
    }

    func testAVerdictRoundTrips() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveTriageVerdicts([entry()])

        let stored = try await database.triageVerdicts()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.prID, "PR_1")
        XCTAssertEqual(stored.first?.documentHash, "hash-1")
        XCTAssertEqual(stored.first?.verdict.kind, .fix)
        XCTAssertEqual(stored.first?.verdict.risk, .high)
        XCTAssertEqual(
            stored.first?.verdict.reason,
            "Touches the auth middleware and deletes two tests."
        )
        XCTAssertEqual(stored.first?.modelIdentifier, "test-model")
        XCTAssertEqual(stored.first?.classifiedAt, PersistenceFixtures.date(0))
    }

    func testSavingIsAnUpsert() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveTriageVerdicts([entry()])
        try await database.saveTriageVerdicts([
            entry(documentHash: "hash-2", kind: .dependencyBump, risk: .low, reason: "A lockfile."),
        ])

        let stored = try await database.triageVerdicts()
        XCTAssertEqual(stored.count, 1, "one pull request cannot hold two opinions")
        XCTAssertEqual(stored.first?.documentHash, "hash-2")
        XCTAssertEqual(stored.first?.verdict.kind, .dependencyBump)
    }

    func testVerdictsAreFetchedByIdAndUnknownIdsAreAbsent() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.saveTriageVerdicts([entry(prID: "PR_1"), entry(prID: "PR_2")])

        let some = try await database.triageVerdicts(prIDs: ["PR_2", "PR_missing"])
        XCTAssertEqual(Set(some.keys), ["PR_2"])
        let none = try await database.triageVerdicts(prIDs: [])
        XCTAssertTrue(none.isEmpty)
    }

    func testAPullRequestLeavingTheInboxTakesItsVerdictWithIt() async throws {
        // The pruning, and there is no code for it: the foreign key does it inside whatever
        // transaction removed the pull request (v4 migration, ADR 0023).
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveTriageVerdicts([entry()])

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM pull_requests WHERE id = ?", arguments: ["PR_1"])
        }

        let stored = try await database.triageVerdicts()
        XCTAssertTrue(stored.isEmpty)
    }

    func testAVerdictForAPullRequestThatIsGoneIsSkippedRatherThanFailing() async throws {
        // What a pass that finished classifying a pull request the sweep meanwhile pruned must
        // do: write the rest of the batch and drop that one.
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])

        try await database.saveTriageVerdicts([entry(), entry(prID: "PR_vanished")])

        let stored = try await database.triageVerdicts()
        XCTAssertEqual(stored.map(\.prID), ["PR_1"])
    }

    func testDeletingByIdEmptiesWhatTheToggleAsksItTo() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.saveTriageVerdicts([entry(prID: "PR_1"), entry(prID: "PR_2")])

        try await database.deleteTriageVerdicts(prIDs: ["PR_1"])
        let remaining = try await database.triageVerdicts()
        XCTAssertEqual(remaining.map(\.prID), ["PR_2"])

        try await database.deleteTriageVerdicts(prIDs: ["PR_2"])
        let empty = try await database.triageVerdicts()
        XCTAssertTrue(empty.isEmpty)
    }

    func testARowThisVersionCannotReadIsSkippedRatherThanFailingTheFetch() async throws {
        // A verdict written by a Shepherd whose vocabulary was different. The fetch must survive
        // it: the table is a cache, so the honest answer is no chip and a re-classification.
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.saveTriageVerdicts([entry(prID: "PR_1")])
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO triage_verdicts
                        (prID, documentHash, kind, risk, reason, modelIdentifier, classifiedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["PR_2", "hash-x", "vibes", "cosmic", "", "test-model", 0]
            )
        }

        let stored = try await database.triageVerdicts()
        XCTAssertEqual(stored.map(\.prID), ["PR_1"])
        let unreadable = try await database.triageVerdicts(prIDs: ["PR_2"])
        XCTAssertTrue(unreadable.isEmpty, "the unreadable row is skipped, not substituted")
    }

    func testEraseTakesTheVerdictsWithIt() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveTriageVerdicts([entry()])

        try await database.eraseAllData()

        let stored = try await database.triageVerdicts()
        XCTAssertTrue(stored.isEmpty)
    }
}
