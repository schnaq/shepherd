import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The evaluation corpus for the intelligence features (plan §0.4).
///
/// **Not part of CI**, and that is the point. Every other suite in this target is a statement
/// about code; this one measures a *model*, and a model's answers move without anybody touching
/// the repository — Apple ships a new on-device model with an OS update, a BYOK endpoint swaps
/// what it serves. A suite that fails for that reason would be a broken build nobody caused, so
/// the harness is opt-in: `SHEPHERD_EVAL=1 xcodebuild … test` runs it, and the four CI jobs never
/// set the variable.
///
/// What it asserts *today* is the corpus itself: that every fixture decodes, that its expected
/// verdict is a case the domain actually has, and that the CI fixtures carry a log tail of a
/// realistic size. The model calls come with the features that produce them (§3.A, §3.F) — the
/// point of landing the corpus first is that the features arrive with something to be measured
/// against instead of a promise of one.
///
/// See `Scripts/eval-intelligence/README.md` for the harness contract and how to run it.
final class IntelligenceEvalTests: XCTestCase {
    // MARK: - Fixture shapes

    /// One anonymised pull request and the verdict a human would give it.
    private struct PullRequestFixture: Decodable {
        struct File: Decodable {
            var path: String
            var status: String
            var additions: Int
            var deletions: Int
        }

        struct Expectation: Decodable {
            var kind: String
            var risk: String
        }

        var id: String
        var title: String
        var body: String
        var files: [File]
        /// The tier-1 risk hints the classifier is given alongside the search document, in the
        /// wording `FilePrioritizer` produces them in ("touches auth", "deletes tests").
        var riskHints: [String]
        var expected: Expectation
    }

    /// One failing check and the diagnosis a human would give it.
    private struct CIFixture: Decodable {
        struct Expectation: Decodable {
            /// `nil` where the log names no test — a compile error in a test target, say.
            var failingTest: String?
            var file: String?
            var line: Int?
        }

        var checkName: String
        /// The tail as separate lines, which is how a log is authored and counted here; the
        /// harness joins them with newlines before handing them to a digest.
        var logTail: [String]
        var expected: Expectation
    }

    // MARK: - Loading

    /// Skips the whole suite unless the harness was asked for.
    private func requireEvalRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SHEPHERD_EVAL"] == "1",
            "The intelligence evaluation harness is opt-in: set SHEPHERD_EVAL=1 to run it."
        )
    }

    /// The fixture directory, copied into the test bundle as a folder reference by `project.yml`.
    private func fixtureDirectory() throws -> URL {
        let bundle = Bundle(for: IntelligenceEvalTests.self)
        guard let directory = bundle.url(forResource: "eval", withExtension: nil) else {
            XCTFail("The eval fixture folder reference is missing from the test bundle")
            throw XCTSkip("No fixtures")
        }
        return directory
    }

    /// The fixture files whose name starts with `prefix`, sorted by path.
    private func fixtureURLs(prefix: String) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: try fixtureDirectory(),
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.path < $1.path }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: try Data(contentsOf: url))
    }

    // MARK: - The corpus

    func testEveryPullRequestFixtureDecodesIntoSomethingTheDomainCanRepresent() throws {
        try requireEvalRun()
        let urls = try fixtureURLs(prefix: "pr-")
        XCTAssertGreaterThanOrEqual(urls.count, 12, "The corpus lost fixtures")

        var kinds = Set<TriageVerdict.Kind>()
        var risks = Set<TriageVerdict.Risk>()

        for url in urls {
            let name = url.lastPathComponent
            let fixture = try decode(PullRequestFixture.self, at: url)
            XCTAssertFalse(fixture.id.isEmpty, name)
            XCTAssertFalse(fixture.title.isEmpty, name)
            XCTAssertFalse(fixture.files.isEmpty, name)

            // The expected verdict has to be a case the twin actually has, or the harness would
            // be measuring against a spelling nothing can produce.
            let kind = TriageVerdict.Kind(rawValue: fixture.expected.kind)
            let risk = TriageVerdict.Risk(rawValue: fixture.expected.risk)
            XCTAssertNotNil(kind, "\(name): unknown kind “\(fixture.expected.kind)”")
            XCTAssertNotNil(risk, "\(name): unknown risk “\(fixture.expected.risk)”")
            if let kind { kinds.insert(kind) }
            if let risk { risks.insert(risk) }

            for file in fixture.files {
                XCTAssertFalse(file.path.isEmpty, name)
                XCTAssertNotNil(
                    FileChangeStatus(rawValue: file.status),
                    "\(name): unknown status “\(file.status)”"
                )
                XCTAssertGreaterThanOrEqual(file.additions, 0, name)
                XCTAssertGreaterThanOrEqual(file.deletions, 0, name)
            }
        }

        // Coverage is the property that makes precision-per-field meaningful: a corpus with no
        // `chore` in it cannot tell anybody how often `chore` is confused with `refactor`.
        XCTAssertEqual(kinds, Set(TriageVerdict.Kind.allCases), "A kind has no fixture")
        XCTAssertEqual(risks, Set(TriageVerdict.Risk.allCases), "A risk has no fixture")
    }

    func testEveryCIFixtureDecodesAndCarriesARealisticLogTail() throws {
        try requireEvalRun()
        let urls = try fixtureURLs(prefix: "ci-")
        XCTAssertGreaterThanOrEqual(urls.count, 4, "The corpus lost fixtures")

        for url in urls {
            let name = url.lastPathComponent
            let fixture = try decode(CIFixture.self, at: url)
            XCTAssertFalse(fixture.checkName.isEmpty, name)
            // Long enough to need digesting, short enough to be a *tail* — the range the plan's
            // `LogDigest` is designed against.
            XCTAssertTrue(
                (30...60).contains(fixture.logTail.count),
                "\(name): \(fixture.logTail.count) lines is not a 30–60 line tail"
            )
            XCTAssertFalse(
                fixture.logTail.allSatisfy(\.isEmpty),
                "\(name): the log tail is blank"
            )
            // A diagnosis is worth measuring only if the fixture states at least one thing to
            // measure. A missing test name is legitimate (a compile error names none); a fixture
            // that expects nothing at all is not.
            let expectation = fixture.expected
            XCTAssertTrue(
                expectation.failingTest != nil || expectation.file != nil,
                "\(name): the expectation names neither a test nor a file"
            )
            if let line = expectation.line {
                XCTAssertGreaterThan(line, 0, name)
            }
        }
    }

    func testTheFixtureDirectoryHoldsNothingTheHarnessWouldSkipSilently() throws {
        try requireEvalRun()
        let contents = try FileManager.default.contentsOfDirectory(
            at: try fixtureDirectory(),
            includingPropertiesForKeys: nil
        )
        for url in contents where url.pathExtension == "json" {
            let name = url.lastPathComponent
            XCTAssertTrue(
                name.hasPrefix("pr-") || name.hasPrefix("ci-"),
                "\(name) is in the corpus but matches no fixture kind — see the harness README"
            )
        }
    }
}
