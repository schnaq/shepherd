import Foundation
import ShepherdCore
import XCTest

/// The tier-1 log reduction behind "why is CI red?" (plan §3.F).
///
/// Two halves, and both matter for a different reason:
///
/// - **The real logs.** `Tests/Fixtures/eval/ci-*.json` carry the tails of four real failures —
///   `xcodebuild`, `swift test`, npm/vitest and pytest — and the only property worth asserting
///   about a reduction is that *the answer survived it*: the file the failure points at is still
///   in the digest, and the digest is a small fraction of the log. A rule that keeps the wrong
///   lines still produces a plausible-looking digest, which is why this is checked against real
///   output rather than against synthetic lines written to match the rules.
/// - **The rules themselves**, one test each: no match at all, ANSI escapes, Actions timestamps,
///   duplicates, and the budget keeping the *last* matches.
///
/// It runs on Linux, which is the point (ADR 0007's rule for every pure decision).
final class LogDigestTests: XCTestCase {
    // MARK: - The eval fixtures

    /// One CI fixture, as `Tests/Fixtures/eval/ci-*.json` stores it.
    private struct CIFixture: Decodable {
        struct Expectation: Decodable {
            var failingTest: String?
            var file: String?
            var line: Int?
        }

        var checkName: String
        var logTail: [String]
        var expected: Expectation
    }

    /// The repository's fixture directory, reached from this file rather than from a bundle.
    ///
    /// `ShepherdCoreTests` has no resources — adding a folder reference to `Package.swift` for
    /// four JSON files that already exist at a known path would be a build-system change to avoid
    /// a relative path. `#filePath` is absolute and settled at compile time, so this works
    /// whatever directory `swift test` was run from.
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // …/Tests/ShepherdCoreTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // …/ShepherdKit
            .deletingLastPathComponent() // …/Packages
            .deletingLastPathComponent() // the repository root
            .appendingPathComponent("Tests/Fixtures/eval")
    }

    func testTheFourRealLogsKeepTheirFailureAndLoseMostOfTheirBulk() throws {
        let directory = fixtureDirectory()
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ci-") && $0.hasSuffix(".json") }
            .sorted()
        XCTAssertEqual(names.count, 4, "the CI corpus lost a fixture: \(directory.path)")

        let limit = LogDigest.characterLimit(for: .onDevice)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let fixture = try JSONDecoder().decode(CIFixture.self, from: data)
            let log = fixture.logTail.joined(separator: "\n")
            let digest = LogDigest.reduce(log, budget: .onDevice)

            XCTAssertEqual(digest.totalLines, fixture.logTail.count, name)
            XCTAssertGreaterThan(digest.matchedLines, 0, "\(name): no line matched")
            XCTAssertLessThanOrEqual(digest.text.count, limit, name)
            XCTAssertLessThan(digest.lineCount, digest.totalLines, name)
            XCTAssertTrue(digest.wasTruncated, name)

            // The file the failure points at is the one thing a diagnosis needs to survive the
            // reduction. The *name* rather than the whole path: a runner prints an absolute path
            // (`xcodebuild`, `swift test`) or one relative to its own working directory (vitest,
            // pytest), and both spellings are the same answer.
            let file = try XCTUnwrap(fixture.expected.file, name)
            let fileName = String(try XCTUnwrap(file.split(separator: "/").last, name))
            XCTAssertTrue(
                digest.text.contains(fileName),
                "\(name): the digest no longer names \(fileName)"
            )
            if let test = fixture.expected.failingTest {
                // The test's name survives too, for every fixture whose log names one — pytest
                // and vitest spell it with a path prefix, so the last segment is what is checked.
                let leaf = String(
                    try XCTUnwrap(
                        test.split(separator: ":").last?.split(separator: ">").last,
                        name
                    )
                ).trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(
                    digest.text.contains(leaf),
                    "\(name): the digest no longer names \(leaf)"
                )
            }
        }
    }

    func testTheXcodebuildLogKeepsTheCompilerErrorAndTheBuildFailure() throws {
        let digest = try reduce("ci-01-xcodebuild-compile-error")

        XCTAssertTrue(
            digest.text.contains("SettingsSyncTests.swift:231:13: error: extra argument")
        )
        XCTAssertTrue(digest.text.contains("** TEST BUILD FAILED **"))
        // The compile lines of the files that built fine are what the budget is being saved for.
        XCTAssertFalse(digest.text.contains("SettingsView.swift"))
    }

    func testTheSwiftTestLogKeepsTheFailingCaseAndDropsThePassingOnes() throws {
        let digest = try reduce("ci-02-swift-test-assertion")

        XCTAssertTrue(digest.text.contains("testBlendedRankingKeepsExactMatchesFirst' failed"))
        XCTAssertTrue(digest.text.contains("SearchRankerTests.swift:212: error:"))
        XCTAssertFalse(digest.text.contains("AgentDetectorTests"), "a passing suite is not read")
    }

    func testTheNpmAndPytestLogsKeepTheirAssertion() throws {
        let vitest = try reduce("ci-03-npm-vitest-failure")
        XCTAssertTrue(vitest.text.contains("AssertionError: expected 41 to be 42"))
        XCTAssertTrue(vitest.text.contains("tests/render.test.ts"))
        XCTAssertTrue(vitest.text.contains("npm error"))

        let pytest = try reduce("ci-04-pytest-failure")
        XCTAssertTrue(pytest.text.contains("tests/test_catalog.py:64: AssertionError"))
        XCTAssertTrue(
            pytest.text.contains("FAILED tests/test_catalog.py::test_missing_german_row")
        )
        XCTAssertFalse(pytest.text.contains("test_specifiers.py"), "a passing file is not read")
    }

    // MARK: - The rules

    func testALogThatNamesNoFailureFallsBackToItsLastLines() {
        let log = (1...200).map { "step \($0) finished" }.joined(separator: "\n")
        let digest = LogDigest.reduce(log, budget: .onDevice)

        XCTAssertEqual(digest.totalLines, 200)
        XCTAssertEqual(digest.matchedLines, 0, "nothing matched, and the count says so")
        XCTAssertEqual(digest.lineCount, LogDigest.fallbackTailLines)
        XCTAssertTrue(digest.text.contains("step 200 finished"))
        XCTAssertTrue(digest.text.contains("step 161 finished"))
        XCTAssertFalse(digest.text.contains("step 160 finished"))
        XCTAssertTrue(digest.wasTruncated)
    }

    func testColourEscapesAreStrippedSoAColouredErrorStillMatches() {
        let log = """
            \u{1B}[32m✓ everything is fine\u{1B}[0m
            \u{1B}[1;31merror:\u{1B}[0m the build failed
            \u{1B}]0;a terminal title\u{07}after the title
            """
        let digest = LogDigest.reduce(log, budget: .onDevice)

        XCTAssertTrue(digest.text.contains("error: the build failed"))
        XCTAssertFalse(digest.text.contains("\u{1B}"), "no escape survives into a prompt")
        XCTAssertTrue(digest.text.contains("after the title"))
        XCTAssertEqual(
            LogDigest.strippingANSIEscapes("\u{1B}[2Kplain"),
            "plain",
            "a sequence with parameters and no colour is a sequence too"
        )
        XCTAssertEqual(LogDigest.strippingANSIEscapes("nothing to strip"), "nothing to strip")
    }

    func testActionsTimestampsAreStrippedButATimestampLikeSentenceIsNot() {
        let log = """
            2026-09-02T09:14:22.1189001Z Run swift test
            2026-09-02T09:14:23Z error: it broke
            2026-09-02 09:14:24 not an Actions prefix
            """
        let digest = LogDigest.reduce(log, budget: .onDevice)

        XCTAssertTrue(digest.text.contains("error: it broke"))
        XCTAssertFalse(digest.text.contains("2026-09-02T09:14:23Z"))
        XCTAssertTrue(digest.text.contains("Run swift test"))
        // A line whose first word merely looks date-ish keeps every character it had.
        XCTAssertTrue(digest.text.contains("2026-09-02 09:14:24 not an Actions prefix"))
        XCTAssertEqual(
            LogDigest.strippingActionsTimestamp("expected 2026-09-02T09:14:23Z, got nothing"),
            "expected 2026-09-02T09:14:23Z, got nothing",
            "a timestamp in the middle of a sentence is content"
        )
    }

    func testARepeatedErrorCostsOneLine() {
        let log = ([String](repeating: "error: the same thing", count: 20)
            + ["done"]).joined(separator: "\n")
        let digest = LogDigest.reduce(log, budget: .onDevice)

        XCTAssertEqual(digest.totalLines, 21)
        XCTAssertEqual(digest.lineCount, 2, "the error once, and the line after it")
        XCTAssertEqual(digest.matchedLines, 1)
        XCTAssertTrue(digest.wasTruncated)
    }

    func testOverBudgetTheLastFailuresAreTheOnesKept() {
        var lines: [String] = []
        for index in 1...200 {
            lines.append("error: failure number \(index) — " + String(repeating: "x", count: 60))
        }
        let digest = LogDigest.reduce(lines.joined(separator: "\n"), characterLimit: 1_200)

        XCTAssertLessThanOrEqual(digest.text.count, 1_200)
        XCTAssertTrue(digest.text.contains("failure number 200"), "the last failure is kept")
        XCTAssertFalse(digest.text.contains("failure number 1 —"), "the first one is given up")
        XCTAssertEqual(digest.totalLines, 200)
    }

    func testTheBudgetIsAFifthOfTheTierAndTheOnDeviceOneIsTheDocumentedCap() {
        // 20 % of the on-device budget's characters is 1,200 tokens of log — the plan's cap,
        // arrived at from the tier rather than written down twice.
        XCTAssertEqual(
            LogDigest.characterLimit(for: .onDevice),
            1_200 * TokenBudget.onDevice.charactersPerToken
        )
        XCTAssertGreaterThan(
            LogDigest.characterLimit(for: .cloud),
            LogDigest.characterLimit(for: .onDevice),
            "the rung a reviewer explicitly asks for sees more of the log"
        )
        XCTAssertEqual(
            LogDigest.characterLimit(for: TokenBudget(maxTokens: 10)),
            LogDigest.minimumCharacters,
            "a tiny budget still gets the floor"
        )
    }

    func testAnEmptyLogAndNoBudgetBothAnswerNothing() {
        XCTAssertTrue(LogDigest.reduce("", budget: .onDevice).isEmpty)
        XCTAssertTrue(LogDigest.reduce("\n\n\n", budget: .onDevice).isEmpty)
        XCTAssertTrue(LogDigest.reduce("error: something", characterLimit: 0).isEmpty)
    }

    func testOneLineLongerThanTheWholeBudgetIsCutRatherThanRefused() {
        let log = "error: " + String(repeating: "y", count: 5_000)
        let digest = LogDigest.reduce(log, characterLimit: 400)

        XCTAssertEqual(digest.lineCount, 1)
        XCTAssertEqual(digest.text.count, 400)
        XCTAssertTrue(digest.text.hasPrefix("error: "), "the head is the half that says what")
        XCTAssertTrue(digest.wasTruncated)
    }

    func testEveryMarkerThePlanNamesMatchesAndAnOrdinaryLineDoesNot() {
        let matching = [
            "Sources/App.swift:12:3: error: cannot find 'foo' in scope",
            "** TEST FAILED **",
            "Test Case 'MyTests.testThing' failed (0.1 seconds).",
            "Error: Process completed with exit code 1.",
            "✘ renders the marker",
            "✗ tests/render.test.ts",
            "npm ERR! code 1",
            "FAIL  tests/render.test.ts",
            "E       AssertionError: assert [] == [1]",
            "Traceback (most recent call last):",
            "panic: runtime error: index out of range",
        ]
        for line in matching {
            XCTAssertTrue(LogDigest.isFailureLine(line), line)
        }
        for line in [
            "Test Case 'MyTests.testThing' passed (0.1 seconds).",
            "note: Building targets in dependency order",
            "swift build --no-error-on-unmatched-pattern",
            "",
        ] {
            XCTAssertFalse(LogDigest.isFailureLine(line), line)
        }
    }

    // MARK: - Helpers

    /// Reduces one eval fixture at the on-device budget.
    private func reduce(_ name: String) throws -> LogDigest.Result {
        let url = fixtureDirectory().appendingPathComponent("\(name).json")
        let fixture = try JSONDecoder().decode(CIFixture.self, from: try Data(contentsOf: url))
        XCTAssertFalse(fixture.checkName.isEmpty)
        return LogDigest.reduce(fixture.logTail.joined(separator: "\n"), budget: .onDevice)
    }
}

/// Parsing the Actions job id out of a check's `detailsURL` (plan §3.F).
///
/// The whole job-log read hangs off this one property, and it is the kind of parser that fails
/// quietly: an off-by-one in the path components yields a plausible number that would read
/// another job's log. So every shape GitHub actually puts in a `detailsURL` is listed here — and
/// so is every shape that must answer `nil`, because "this check has no readable log" is a
/// supported answer the tool depends on.
final class CheckRunJobIDTests: XCTestCase {
    /// A failing check with one `detailsURL`.
    private func check(_ url: String?) -> CheckRun {
        CheckRun(
            id: "1",
            name: "App build (macOS)",
            status: .completed,
            conclusion: .failure,
            detailsURL: url.flatMap { URL(string: $0) }
        )
    }

    func testAnActionsJobURLYieldsItsJobID() {
        XCTAssertEqual(
            check("https://github.com/schnaq/review/actions/runs/1234/job/98765").actionsJobID,
            98_765
        )
        // The fragment Actions itself appends when it links to a step.
        XCTAssertEqual(
            check("https://github.com/schnaq/review/actions/runs/1234/job/98765#step:6:1")
                .actionsJobID,
            98_765
        )
        // A GitHub Enterprise Server host, and one with a path prefix in front of the owner.
        XCTAssertEqual(
            check("https://github.example.com/gh/schnaq/review/actions/runs/1/job/42")
                .actionsJobID,
            42
        )
    }

    func testEveryOtherShapeOfCheckHasNoJobID() {
        for url in [
            // The run, not the job — which is what the check-runs fixture in `GitHubKitTests`
            // carries, and what a check run created by an app rather than by a job looks like.
            "https://github.com/schnaq/review/actions/runs/1",
            // Other CI systems: the plan's Buildkite and CircleCI case.
            "https://buildkite.com/schnaq/review/builds/512",
            "https://app.circleci.com/pipelines/github/schnaq/review/88/workflows/abc/jobs/3",
            // Malformed or hostile spellings of the Actions shape.
            "https://github.com/schnaq/review/actions/runs/1/job/",
            "https://github.com/schnaq/review/actions/runs/1/job/not-a-number",
            "https://github.com/schnaq/review/actions/runs/1/job/0",
            "https://github.com/schnaq/review/actions/jobs/98765",
        ] {
            XCTAssertNil(check(url).actionsJobID, url)
        }
        XCTAssertNil(check(nil).actionsJobID, "a check with no details URL")
    }
}
