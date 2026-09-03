import Foundation
import XCTest

@testable import ShepherdCore

/// The lane gate (ADR 0027): CI, size, sensitive paths — and nothing else, ever.
final class TrustLaneTests: XCTestCase {
    private let configuration = TrustLaneConfiguration.default

    // MARK: - The three conditions

    func testAGreenSmallCleanPullRequestIsAShortLook() {
        XCTAssertEqual(
            TrustLane.classify(input(files: 3, lines: 40), configuration: configuration),
            .shortLook
        )
    }

    func testEveryCIStateOtherThanSuccessIsAFullReview() {
        for state in CheckRollup.State.allCases where state != .success {
            XCTAssertEqual(
                TrustLane.classify(
                    input(state: state, files: 1, lines: 1),
                    configuration: configuration
                ),
                .fullReview,
                "\(state.rawValue) must not be a short look"
            )
        }
    }

    func testAPullRequestWithNoRollupAtAllIsAFullReview() {
        XCTAssertEqual(
            TrustLane.classify(input(state: nil, files: 1, lines: 1), configuration: configuration),
            .fullReview,
            "an unknown CI state is not a green one"
        )
    }

    func testASensitivePathIsAFullReviewHoweverSmallAndGreen() {
        XCTAssertEqual(
            TrustLane.classify(
                input(files: 1, lines: 1, sensitive: true),
                configuration: configuration
            ),
            .fullReview
        )
    }

    // MARK: - Every threshold at ±1

    func testTheFileThresholdIsInclusiveAndOneMoreIsAFullReview() {
        XCTAssertEqual(
            TrustLane.classify(input(files: 4, lines: 10), configuration: configuration),
            .shortLook,
            "one under the ceiling"
        )
        XCTAssertEqual(
            TrustLane.classify(input(files: 5, lines: 10), configuration: configuration),
            .shortLook,
            "exactly the ceiling is still small"
        )
        XCTAssertEqual(
            TrustLane.classify(input(files: 6, lines: 10), configuration: configuration),
            .fullReview,
            "one over the ceiling"
        )
    }

    func testTheLineThresholdIsInclusiveAndOneMoreIsAFullReview() {
        XCTAssertEqual(
            TrustLane.classify(input(files: 1, lines: 119), configuration: configuration),
            .shortLook
        )
        XCTAssertEqual(
            TrustLane.classify(input(files: 1, lines: 120), configuration: configuration),
            .shortLook,
            "exactly the ceiling is still small"
        )
        XCTAssertEqual(
            TrustLane.classify(input(files: 1, lines: 121), configuration: configuration),
            .fullReview
        )
    }

    func testTheChangedLinesAreAdditionsPlusDeletions() {
        let summary = Fixtures.summary(
            id: "PR_1",
            additions: 60,
            deletions: 61,
            changedFiles: 1,
            checkRollup: CheckRollup(state: .success, total: 3)
        )
        XCTAssertEqual(summary.churn, 121)
        XCTAssertEqual(
            TrustLane.classify(
                summary: summary,
                sensitivePaths: false,
                configuration: configuration
            ),
            .fullReview,
            "60 added and 61 deleted is 121 changed lines, which is one over"
        )
    }

    func testAConfiguredThresholdMovesTheBoundaryWithIt() {
        let wider = TrustLaneConfiguration(maxFiles: 6, maxChangedLines: 121)
        XCTAssertEqual(
            TrustLane.classify(input(files: 6, lines: 121), configuration: wider),
            .shortLook
        )
        XCTAssertEqual(
            TrustLane.classify(input(files: 7, lines: 121), configuration: wider),
            .fullReview
        )
    }

    // MARK: - The configuration itself

    func testTheDefaultsAreFiveFilesAndAHundredAndTwentyLines() {
        XCTAssertEqual(TrustLaneConfiguration.default.maxFiles, 5)
        XCTAssertEqual(TrustLaneConfiguration.default.maxChangedLines, 120)
    }

    func testAThresholdOfZeroOrLessIsClampedRatherThanEmptyingTheLane() {
        let clamped = TrustLaneConfiguration(maxFiles: 0, maxChangedLines: -7)
        XCTAssertEqual(clamped.maxFiles, TrustLaneConfiguration.minimumThreshold)
        XCTAssertEqual(clamped.maxChangedLines, TrustLaneConfiguration.minimumThreshold)
    }

    func testAnAbsurdThresholdIsClampedToTheDocumentedCeiling() {
        let clamped = TrustLaneConfiguration(maxFiles: 10_000, maxChangedLines: 10_000_000)
        XCTAssertEqual(clamped.maxFiles, TrustLaneConfiguration.maximumFiles)
        XCTAssertEqual(clamped.maxChangedLines, TrustLaneConfiguration.maximumChangedLines)
    }

    func testTheConfigurationDecodesTolerantlyAndStillClamps() throws {
        let json = Data(#"{"maxFiles": 0, "maxChangedLines": "nonsense"}"#.utf8)
        let decoded = try JSONDecoder().decode(TrustLaneConfiguration.self, from: json)
        XCTAssertEqual(decoded.maxFiles, TrustLaneConfiguration.minimumThreshold)
        XCTAssertEqual(
            decoded.maxChangedLines,
            120,
            "an unreadable threshold falls back to the default rather than costing the value"
        )
    }

    func testAnEmptyDocumentDecodesToTheDefaults() throws {
        let decoded = try JSONDecoder().decode(
            TrustLaneConfiguration.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(decoded, TrustLaneConfiguration.default)
    }

    // MARK: - History never gates (ADR 0027)

    /// The rule that makes the lane safe, asserted on the *type* of the classifier's input.
    ///
    /// `TrustLane.classify(_:configuration:)` takes a ``TrustLaneInput`` and a
    /// ``TrustLaneConfiguration`` and nothing else, so this walks both and fails if anything
    /// reachable from either is a track-record type. It is the compile-level half of ADR 0027's
    /// promise — the moment somebody adds an outcome, a record or a count to the input, the lane
    /// *can* be moved by history, and a promise nobody can see being broken is not a promise.
    func testTheLanesInputsCannotSeeAnyHistory() {
        assertNoHistory(
            in: TrustLaneInput(
                checkState: .success,
                changedFiles: 1,
                changedLines: 1,
                sensitivePaths: false
            ),
            label: "TrustLaneInput"
        )
        assertNoHistory(in: TrustLaneConfiguration.default, label: "TrustLaneConfiguration")
        // And the convenience overload's other input, which is the inbox row itself.
        assertNoHistory(in: Fixtures.summary(id: "PR_1"), label: "PullRequestSummary")
    }

    func testTwoPullRequestsWithIdenticalLaneInputsGetTheSameLane() {
        // The behavioural half of the same rule: the only thing that differs between these two
        // is the author, which is what a track record is counted per — and it changes nothing.
        let human = Fixtures.summary(
            id: "PR_1",
            author: Fixtures.makeActor("octocat"),
            additions: 5,
            deletions: 5,
            changedFiles: 2,
            checkRollup: CheckRollup(state: .success, total: 2)
        )
        let agent = Fixtures.summary(
            id: "PR_2",
            author: Fixtures.makeActor(
                "claude[bot]",
                kind: Fixtures.agent("claude-code", "Claude Code")
            ),
            additions: 5,
            deletions: 5,
            changedFiles: 2,
            checkRollup: CheckRollup(state: .success, total: 2)
        )
        XCTAssertEqual(
            TrustLane.classify(summary: human, sensitivePaths: false),
            TrustLane.classify(summary: agent, sensitivePaths: false)
        )
    }

    /// Fails when any value reachable from `value` is a track-record type.
    ///
    /// Names rather than types, for ``StructuredTriageTests``' reason: `Mirror` reports
    /// `type(of:)`, and a field added as `TrackRecord?`, `[PullRequestOutcome]` or
    /// `TrackRecordSubject` all spell it in there.
    private func assertNoHistory(
        in value: Any,
        label: String,
        depth: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard depth < 6 else { return }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            let typeName = "\(type(of: child.value))"
            XCTAssertFalse(
                TrustLaneTests.isHistoryType(typeName),
                """
                \(label) reached a \(typeName) through \(child.label ?? "?"). ADR 0027: the lane \
                gate is CI, size and sensitive paths — a track record informs the badge and the \
                sort, never the lane.
                """,
                file: file,
                line: line
            )
            assertNoHistory(
                in: child.value,
                label: "\(label).\(child.label ?? "?")",
                depth: depth + 1,
                file: file,
                line: line
            )
        }
    }

    /// Whether a type name is one of the track record's.
    ///
    /// Shared with ``StructuredTriageTests``' automation check, which asserts the same three
    /// families are unreachable from every input that can write to GitHub or start an agent.
    static func isHistoryType(_ typeName: String) -> Bool {
        typeName.contains("TrackRecord")
            || typeName.contains("PullRequestOutcome")
            || typeName.contains("ClosedPullRequest")
    }

    // MARK: - Fixtures

    private func input(
        state: CheckRollup.State? = .success,
        files: Int,
        lines: Int,
        sensitive: Bool = false
    ) -> TrustLaneInput {
        TrustLaneInput(
            checkState: state,
            changedFiles: files,
            changedLines: lines,
            sensitivePaths: sensitive
        )
    }
}

/// The sensitive-path exclusion (ADR 0027), over ``FilePrioritizer``'s own classifications.
final class TrustSensitivePathTests: XCTestCase {
    func testAWorkflowFileIsSensitive() {
        XCTAssertTrue(TrustSensitivePaths.isSensitive(Fixtures.file(".github/workflows/ci.yml")))
        XCTAssertTrue(
            TrustSensitivePaths.isSensitive(Fixtures.file("nested/.github/workflows/ci.yml"))
        )
    }

    func testAnAuthOrSecretPathIsSensitive() {
        XCTAssertTrue(TrustSensitivePaths.isSensitive(Fixtures.file("Sources/Auth/Token.swift")))
        XCTAssertTrue(
            TrustSensitivePaths.isSensitive(Fixtures.file("Sources/App/SecretStore.swift"))
        )
    }

    func testAMigrationIsSensitiveAtTheRootAndNested() {
        XCTAssertTrue(TrustSensitivePaths.isSensitive(Fixtures.file("migrations/0007_add.sql")))
        XCTAssertTrue(TrustSensitivePaths.isSensitive(Fixtures.file("db/migrate/0007_add.sql")))
        XCTAssertTrue(
            TrustSensitivePaths.isSensitive(Fixtures.file("Sources/Schema/schema.sql"))
        )
    }

    func testADeletedTestIsSensitiveAndAnEditedOneIsNot() {
        XCTAssertTrue(
            TrustSensitivePaths.isSensitive(
                Fixtures.file("Tests/ParserTests.swift", status: .removed)
            )
        )
        XCTAssertFalse(
            TrustSensitivePaths.isSensitive(
                Fixtures.file("Tests/ParserTests.swift", status: .modified)
            )
        )
    }

    func testAnOrdinarySourceFileIsNotSensitive() {
        XCTAssertFalse(TrustSensitivePaths.isSensitive(Fixtures.file("Sources/App/View.swift")))
        XCTAssertFalse(TrustSensitivePaths.isSensitive(Fixtures.file("README.md")))
        XCTAssertFalse(
            TrustSensitivePaths.isSensitive(Fixtures.file("Sources/Onboarding/Latest.swift"))
        )
    }

    func testGeneratedContentIsExemptFromTheSecurityHints() {
        XCTAssertFalse(
            TrustSensitivePaths.isSensitive(Fixtures.file("node_modules/auth-lib/index.js")),
            "a vendored bundle that mentions auth is not the auth layer"
        )
    }

    func testTheUsersOwnHintsAreHonoured() {
        let file = Fixtures.file("Sources/Billing/Invoice.swift")
        XCTAssertFalse(TrustSensitivePaths.isSensitive(file))
        XCTAssertTrue(TrustSensitivePaths.isSensitive(file, extraHints: ["billing"]))
    }

    func testOneSensitiveFileIsEnoughAndAnEmptyListIsNot() {
        XCTAssertTrue(
            TrustSensitivePaths.contains(files: [
                Fixtures.file("Sources/App/View.swift"),
                Fixtures.file(".github/workflows/ci.yml"),
            ])
        )
        XCTAssertFalse(TrustSensitivePaths.contains(files: []))
    }
}
