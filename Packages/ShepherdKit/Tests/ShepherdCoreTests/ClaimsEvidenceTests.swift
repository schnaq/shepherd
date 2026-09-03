import Foundation
import XCTest

@testable import ShepherdCore

/// What the diff and CI say about a claim, and how a status is derived from facts (ADR 0026).
///
/// The evidence side of the card is where a wrong answer does damage: a ✗ beside a claim that was
/// true is an accusation, and a ✓ beside a claim contradicted by the hunk two lines down is worse
/// than no card. So every rule in ``EvidenceChecker``'s documentation has a case here, and the
/// three that matter most have their own:
///
/// - **Assertion drift outranks a green CI.** Deleting the assertion makes CI greener; the card
///   has to say ✗ anyway, because that is the pull request this feature exists for.
/// - **An unmatched module is "?" and not "✗".** Shepherd cannot know that "the parser" means
///   `Sources/Syntax/`, and a contradiction it cannot substantiate is the one thing ADR 0026
///   forbids.
/// - **Line numbers come out of the hunk headers.** A fact that links to the wrong line is a fact
///   the reviewer stops trusting, and an off-by-one in a diff walker is invisible in review.
final class ClaimsEvidenceTests: XCTestCase {
    // MARK: - Fixtures

    private func detail(
        body: String = "",
        files: [ChangedFile] = [],
        checks: [CheckRun] = [],
        rollup: CheckRollup? = nil
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: Fixtures.summary(id: "PR_1", checkRollup: rollup),
            bodyMarkdown: body,
            files: files,
            checks: checks
        )
    }

    private func check(_ name: String, _ conclusion: CheckRun.Conclusion) -> CheckRun {
        CheckRun(id: name, name: name, status: .completed, conclusion: conclusion)
    }

    /// Named `evidence` rather than `verdict` so a test can write `let verdict = evidence(…)`
    /// without the local shadowing the helper in its own initial value.
    private func evidence(_ kind: Claim.Kind, _ detail: PullRequestDetail) -> EvidenceVerdict {
        EvidenceChecker.check(Claim(kind: kind, quote: "quoted sentence"), in: detail)
    }

    // MARK: - Tests claim

    func testATestFileAndAGreenCISupportTheClaim() {
        let verdict = evidence(
            .testsAdded,
            detail(
                files: [Fixtures.file("Tests/ParserTests/LexerTests.swift", status: .added)],
                checks: [check("Linux", .success), check("macOS", .success)]
            )
        )
        XCTAssertEqual(verdict.status, .ok)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("CI is green: 2 of 2 checks passed.") })
        XCTAssertTrue(verdict.facts.contains { $0.path == "Tests/ParserTests/LexerTests.swift" })
    }

    func testNoTestFileAndARedCIContradictTheClaim() {
        let verdict = evidence(
            .testsAdded,
            detail(
                files: [Fixtures.file("Sources/Parser/Lexer.swift")],
                checks: [check("Linux", .failure), check("macOS", .success)]
            )
        )
        XCTAssertEqual(verdict.status, .contradicted)
        XCTAssertTrue(
            verdict.facts.contains { $0.englishSentence == "No changed file matches a test naming convention." }
        )
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("CI is red: 1 of 2 checks failed.") })
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence == "Check “Linux” failed." })
    }

    func testATestFileWithCIStillRunningIsUnclear() {
        let verdict = evidence(
            .testsAdded,
            detail(
                files: [Fixtures.file("Tests/ParserTests/LexerTests.swift")],
                checks: [CheckRun(id: "1", name: "Linux", status: .inProgress)]
            )
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("CI has not finished") })
    }

    func testNoChecksAtAllIsSaidRatherThanAssumedGreen() {
        let verdict = evidence(
            .testsAdded,
            detail(files: [Fixtures.file("Tests/ParserTests/LexerTests.swift")])
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(
            verdict.facts.contains { $0.englishSentence == "No checks are configured for this commit." }
        )
    }

    // MARK: - Assertion drift

    func testARemovedAssertionContradictsTheClaimEvenWithAGreenCI() {
        let patch = """
        @@ -10,6 +10,5 @@
         context a
         context b
        -        XCTAssertEqual(retries, 2)
         context c
        """
        let verdict = evidence(
            .testsAdded,
            detail(
                files: [Fixtures.file("Tests/UploadTests.swift", patch: patch)],
                checks: [check("Linux", .success)]
            )
        )
        XCTAssertEqual(verdict.status, .contradicted)
        let drift = verdict.facts.first { $0.englishSentence.contains("removes an assertion") }
        XCTAssertEqual(drift?.path, "Tests/UploadTests.swift")
        // Two context rows after `@@ … +10 @@`, so the deletion sits in front of head line 12.
        XCTAssertEqual(drift?.line, 12)
        XCTAssertEqual(
            drift?.englishSentence,
            "“Tests/UploadTests.swift” removes an assertion at line 12: “XCTAssertEqual(retries, 2)”."
        )
    }

    func testAnAddedSkipContradictsTheClaim() {
        let patch = """
        @@ -1,3 +1,4 @@
         keep
        +    XCTSkip("flaky on CI")
         keep2
        """
        let verdict = evidence(
            .testsAdded,
            detail(
                files: [Fixtures.file("Tests/UploadTests.swift", patch: patch)],
                checks: [check("Linux", .success)]
            )
        )
        XCTAssertEqual(verdict.status, .contradicted)
        let drift = verdict.facts.first { $0.englishSentence.contains("adds a skipped test") }
        XCTAssertEqual(drift?.line, 2)
    }

    func testEveryDriftMarkerIsRecognised() {
        let removals = [
            "XCTAssertTrue(ok)",
            "expect(value).toBe(2)",
            "assert x == 1",
            "assert(x == 1)",
            "assertEquals(a, b)",
            "t.Fatalf(\"boom\")",
            "t.Errorf(\"boom\")",
        ]
        for line in removals {
            let patch = "@@ -1,2 +1,1 @@\n context\n-\(line)\n"
            let facts = EvidenceChecker.assertionDrift(
                in: [Fixtures.file("Tests/Thing.swift", patch: patch)]
            )
            XCTAssertEqual(facts.count, 1, "“\(line)” was not read as a removed assertion")
        }
        let additions = [
            "XCTSkip(\"x\")",
            "test.skip(\"x\")",
            "xit(\"x\")",
            "xdescribe(\"x\")",
            "@unittest.skip(\"x\")",
            "pytest.mark.skip",
            "t.Skip(\"x\")",
        ]
        for line in additions {
            let patch = "@@ -1,1 +1,2 @@\n context\n+\(line)\n"
            let facts = EvidenceChecker.assertionDrift(
                in: [Fixtures.file("Tests/Thing.swift", patch: patch)]
            )
            XCTAssertEqual(facts.count, 1, "“\(line)” was not read as an added skip")
        }
    }

    func testAFileWithNoPatchContributesNoDrift() {
        XCTAssertTrue(
            EvidenceChecker.assertionDrift(
                in: [Fixtures.file("Tests/Thing.swift", patch: nil)]
            ).isEmpty
        )
    }

    // MARK: - Scope claim

    func testEveryChangedFileUnderTheNamedModuleSupportsTheClaim() {
        let verdict = evidence(
            .scopeLimited(module: "Sources/Parser"),
            detail(
                files: [
                    Fixtures.file("Sources/Parser/Lexer.swift"),
                    Fixtures.file("Sources/Parser/Parser.swift"),
                ]
            )
        )
        XCTAssertEqual(verdict.status, .ok)
        XCTAssertTrue(
            verdict.facts.contains { $0.englishSentence == "2 of 2 changed files are under “Sources/Parser”." }
        )
    }

    func testAFileOutsideTheNamedModuleContradictsTheClaimAndIsLinkable() {
        let verdict = evidence(
            .scopeLimited(module: "Sources/Parser"),
            detail(
                files: [
                    Fixtures.file("Sources/Parser/Lexer.swift"),
                    Fixtures.file(".github/workflows/ci.yml"),
                ]
            )
        )
        XCTAssertEqual(verdict.status, .contradicted)
        let outside = verdict.facts.first { $0.englishSentence.contains("is outside") }
        XCTAssertEqual(outside?.path, ".github/workflows/ci.yml")
        XCTAssertTrue(
            verdict.facts.contains {
                $0.englishSentence == "“.github/workflows/ci.yml” changes a CI workflow."
            }
        )
    }

    func testAModuleThatMatchesNoPathIsUnclearRatherThanContradicted() {
        let verdict = evidence(
            .scopeLimited(module: "Fabricator"),
            detail(files: [Fixtures.file("Sources/Parser/Lexer.swift")])
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("No changed path contains") })
    }

    func testNoOtherChangesNamesNoModuleAndSaysSo() {
        let verdict = evidence(
            .scopeLimited(module: ""),
            detail(files: [Fixtures.file("Sources/Parser/Lexer.swift")])
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("names no module") })
    }

    func testARenamedFilesPreviousPathCountsTowardsTheModule() {
        let renamed = ChangedFile(
            path: "Sources/Parser/Lexer.swift",
            previousPath: "Sources/Old/Lexer.swift",
            status: .renamed,
            patch: "@@ -1,1 +1,1 @@\n-a\n+b\n"
        )
        XCTAssertEqual(
            evidence(.scopeLimited(module: "Sources/Old"), detail(files: [renamed])).status,
            .ok
        )
    }

    func testTheFourClassificationFlagsAreSeparateFacts() {
        let verdict = evidence(
            .scopeLimited(module: ""),
            detail(
                files: [
                    Fixtures.file(".github/workflows/ci.yml"),
                    Fixtures.file("Package.resolved"),
                    Fixtures.file("web/dist/viewer.js"),
                    Fixtures.file("project.yml"),
                ]
            )
        )
        let texts = verdict.facts.map(\.englishSentence)
        XCTAssertTrue(texts.contains("“.github/workflows/ci.yml” changes a CI workflow."))
        XCTAssertTrue(texts.contains("“Package.resolved” is a dependency lockfile."))
        XCTAssertTrue(texts.contains("“web/dist/viewer.js” is a generated or vendored file."))
        XCTAssertTrue(texts.contains("“project.yml” is configuration."))
    }

    func testTheTopLevelPathsAreNamed() {
        let verdict = evidence(
            .scopeLimited(module: "Sources"),
            detail(
                files: [
                    Fixtures.file("Sources/Parser/Lexer.swift"),
                    Fixtures.file("Tests/ParserTests/LexerTests.swift"),
                    Fixtures.file("README.md"),
                ]
            )
        )
        XCTAssertTrue(
            verdict.facts.contains {
                $0.englishSentence == "The pull request touches 3 top-level paths: “(repository root)”, “Sources”, “Tests”."
            }
        )
    }

    // MARK: - Breaking-changes claim

    func testARemovedPublicSwiftDeclarationContradictsTheClaim() {
        let patch = """
        @@ -20,7 +20,6 @@
         struct Client {
        -    public func issue(number: Int) -> String { "x" }
         }
        """
        let verdict = evidence(
            .noBreakingChanges,
            detail(files: [Fixtures.file("Sources/GitHubKit/GitHubClient.swift", patch: patch)])
        )
        XCTAssertEqual(verdict.status, .contradicted)
        let fact = verdict.facts.first { $0.englishSentence.contains("exported declaration") }
        XCTAssertEqual(fact?.path, "Sources/GitHubKit/GitHubClient.swift")
        XCTAssertEqual(fact?.line, 21)
    }

    func testARemovedInternalSwiftFunctionIsNotABreakingChange() {
        let patch = """
        @@ -20,7 +20,6 @@
         struct Client {
        -    func helper(number: Int) -> String { "x" }
         }
        """
        let verdict = evidence(
            .noBreakingChanges,
            detail(files: [Fixtures.file("Sources/GitHubKit/GitHubClient.swift", patch: patch)])
        )
        XCTAssertEqual(verdict.status, .ok)
    }

    func testExportedDeclarationsAreRecognisedPerLanguage() {
        let cases: [(String, String)] = [
            ("web/src/parse.ts", "export function parse(input: string) {}"),
            ("web/src/parse.js", "declare const x: number"),
            ("cmd/serve/main.go", "func Parse(input string) error {"),
            ("cmd/serve/types.go", "type Config struct {"),
            ("tools/build.py", "def parse(text):"),
            ("tools/build.py", "class Builder:"),
        ]
        for (path, line) in cases {
            let patch = "@@ -1,2 +1,1 @@\n context\n-\(line)\n"
            let verdict = evidence(
                .noBreakingChanges,
                detail(files: [Fixtures.file(path, patch: patch)])
            )
            XCTAssertEqual(verdict.status, .contradicted, "“\(line)” in \(path) was not flagged")
        }
    }

    func testAPrivatePythonFunctionIsNotExported() {
        let patch = "@@ -1,2 +1,1 @@\n context\n-def _helper(text):\n"
        XCTAssertEqual(
            evidence(.noBreakingChanges, detail(files: [Fixtures.file("tools/build.py", patch: patch)]))
                .status,
            .ok
        )
    }

    func testAMigrationIsAQuestionRatherThanAContradiction() {
        let patch = "@@ -1,1 +1,2 @@\n let x = 1\n+let y = 2\n"
        let verdict = evidence(
            .noBreakingChanges,
            detail(files: [Fixtures.file("Sources/ShepherdPersistence/Migrations/V5.swift", patch: patch)])
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("schema or a migration") })
    }

    func testAManifestDependencyLineIsAQuestion() {
        let patch = """
        @@ -8,7 +8,7 @@
         dependencies: [
        -        .package(url: "https://example.com/a", from: "1.0.0")
        +        .package(url: "https://example.com/a", from: "2.0.0")
         ]
        """
        let verdict = evidence(
            .noBreakingChanges,
            detail(files: [Fixtures.file("Package.swift", patch: patch)])
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("version or dependency line") })
    }

    func testAnUnreadableDiffIsAQuestion() {
        let verdict = evidence(
            .noBreakingChanges,
            detail(files: [Fixtures.file("Resources/icon.png", patch: nil)])
        )
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("No diff was readable") })
    }

    func testAWorkflowChangeAloneDoesNotMoveTheBreakingStatus() {
        let patch = "@@ -1,1 +1,2 @@\n on: push\n+  workflow_dispatch:\n"
        let verdict = evidence(
            .noBreakingChanges,
            detail(files: [Fixtures.file(".github/workflows/ci.yml", patch: patch)])
        )
        XCTAssertEqual(verdict.status, .ok)
        XCTAssertTrue(verdict.facts.contains { $0.englishSentence.contains("changes a CI workflow") })
    }

    // MARK: - Issue claim

    func testAnIssueReferenceIsAlwaysUnclearAndCarriesItsURL() {
        let verdict = evidence(.fixesIssue(number: 142), detail())
        XCTAssertEqual(verdict.status, .unclear)
        XCTAssertEqual(verdict.facts.count, 2)
        XCTAssertEqual(
            verdict.facts.first?.url,
            URL(string: "https://github.com/schnaq/review/issues/142")
        )
        XCTAssertEqual(
            verdict.facts.last?.englishSentence,
            "Acceptance criteria not checked — the issue is not fetched."
        )
    }

    // MARK: - The report

    func testAnEmptyDescriptionProducesNoCard() {
        let report = ClaimsEvidenceReport.build(
            detail: detail(body: "typo fix"),
            summary: Fixtures.summary(id: "PR_1")
        )
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.lines.isEmpty)
    }

    func testTheReportKeepsTheExtractorsOrderAndOneLinePerClaim() {
        let report = ClaimsEvidenceReport.build(
            detail: detail(
                body: """
                Fixes #7. No breaking changes. Only `Sources/` changed. Tests added.
                """,
                files: [Fixtures.file("Sources/Parser/Lexer.swift")],
                checks: [check("Linux", .success)]
            ),
            summary: Fixtures.summary(id: "PR_1")
        )
        XCTAssertEqual(
            report.lines.map(\.claim.kind),
            [
                .testsAdded,
                .scopeLimited(module: "Sources"),
                .noBreakingChanges,
                .fixesIssue(number: 7),
            ]
        )
        XCTAssertEqual(report.lines.map(\.id).count, Set(report.lines.map(\.id)).count)
    }

    func testTheGivenSummaryWinsOverTheStoredOne() {
        // No fetched check runs, and the two rollups disagree: the row handed in is the newer
        // one, so a green row must produce a green fact.
        var stale = detail(
            body: "Tests added.",
            files: [Fixtures.file("Tests/ParserTests/LexerTests.swift")],
            rollup: CheckRollup(state: .failure, total: 1, failureCount: 1)
        )
        stale.checks = []
        let report = ClaimsEvidenceReport.build(
            detail: stale,
            summary: Fixtures.summary(
                id: "PR_1",
                checkRollup: CheckRollup(state: .success, total: 1, successCount: 1)
            )
        )
        XCTAssertEqual(report.lines.first?.verdict.status, .ok)
    }

    func testContradictedLinesAreTheOnesOfferedAsAComment() {
        let report = ClaimsEvidenceReport.build(
            detail: detail(
                body: "Tests added.",
                files: [Fixtures.file("Sources/Parser/Lexer.swift")],
                checks: [check("Linux", .failure)]
            ),
            summary: Fixtures.summary(id: "PR_1")
        )
        XCTAssertEqual(report.contradictedLines.map(\.claim.kind), [.testsAdded])
    }

    func testEveryFactIsASentence() {
        let report = ClaimsEvidenceReport.build(
            detail: detail(
                body: """
                Only `Sources/Parser/` changed. Tests added. No breaking changes. Fixes #9.
                """,
                files: [
                    Fixtures.file("Sources/Parser/Lexer.swift", patch: "@@ -1,1 +1,2 @@\n a\n+b\n"),
                    Fixtures.file("Package.resolved"),
                    Fixtures.file(".github/workflows/ci.yml"),
                ],
                checks: [check("Linux", .failure)]
            ),
            summary: Fixtures.summary(id: "PR_1")
        )
        XCTAssertFalse(report.isEmpty)
        for line in report.lines {
            XCTAssertFalse(line.verdict.facts.isEmpty, "\(line.claim.kind) produced no facts")
            for fact in line.verdict.facts {
                XCTAssertTrue(
                    fact.englishSentence.hasSuffix("."),
                    "not a sentence: “\(fact.englishSentence)”"
                )
            }
        }
    }

    // MARK: - The fact as data

    /// A fact is a ``EvidenceFact/Kind`` *plus* a rendering of it, and both halves are asserted.
    ///
    /// The kind is what the app localises (ADR 0022's follow-up to ADR 0026) and the English
    /// sentence is what a log line, a test and a *Turn into a comment* insertion read — so a
    /// change to either one is a change somebody has to mean.
    func testAFactCarriesItsValuesAndRendersThemInEnglish() {
        let verdict = evidence(
            .testsAdded,
            detail(
                files: [
                    Fixtures.file(
                        "Tests/ParserTests/LexerTests.swift",
                        additions: 12,
                        deletions: 3
                    )
                ],
                checks: [check("Linux", .success)]
            )
        )
        XCTAssertEqual(
            verdict.facts.map(\.kind),
            [
                .testFilesChanged(count: 1),
                .testFile(
                    path: "Tests/ParserTests/LexerTests.swift",
                    additions: 12,
                    deletions: 3
                ),
                .ciGreenCounted(passed: 1, total: 1),
            ]
        )
        XCTAssertEqual(
            verdict.facts.map(\.englishSentence),
            [
                "1 changed file matches a test naming convention.",
                "“Tests/ParserTests/LexerTests.swift” is a test file (+12 −3).",
                "CI is green: 1 of 1 check passed.",
            ]
        )
    }

    /// The four sentence shapes a count changes, at both ends of the range.
    ///
    /// English needs two forms and German needs two different ones, which is the whole reason the
    /// count travels as a number rather than as "1 file" (ADR 0022's plural rules).
    func testTheCountedSentencesAgreeWithTheirCounts() {
        XCTAssertEqual(
            EvidenceFact.Kind.testFilesChanged(count: 1).englishSentence,
            "1 changed file matches a test naming convention."
        )
        XCTAssertEqual(
            EvidenceFact.Kind.testFilesChanged(count: 4).englishSentence,
            "4 changed files match a test naming convention."
        )
        XCTAssertEqual(
            EvidenceFact.Kind.ciUnfinishedRunning(count: 1).englishSentence,
            "CI has not finished: 1 check is still running."
        )
        XCTAssertEqual(
            EvidenceFact.Kind.ciUnfinishedRunning(count: 3).englishSentence,
            "CI has not finished: 3 checks are still running."
        )
        XCTAssertEqual(
            EvidenceFact.Kind.topLevelPaths(count: 1, paths: ["Sources"]).englishSentence,
            "The pull request touches 1 top-level path: “Sources”."
        )
        // More paths than the list names: the ellipsis is the renderer's, from `count` alone.
        XCTAssertEqual(
            EvidenceFact.Kind.topLevelPaths(count: 9, paths: ["Sources", "Tests"]).englishSentence,
            "The pull request touches 9 top-level paths: “Sources”, “Tests”, …."
        )
    }

    /// The id is still what it says and where, so a `ForEach` over two facts about one file is
    /// stable and distinct.
    func testTwoFactsAboutOneFileHaveDifferentIDs() {
        let first = EvidenceFact(
            kind: .assertionRemoved(path: "Tests/A.swift", line: 12, snippet: "XCTAssert(a)"),
            path: "Tests/A.swift",
            line: 12
        )
        let second = EvidenceFact(
            kind: .assertionRemoved(path: "Tests/A.swift", line: 20, snippet: "XCTAssert(b)"),
            path: "Tests/A.swift",
            line: 20
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.hasSuffix("|Tests/A.swift|12"), first.id)
        XCTAssertTrue(first.id.hasPrefix(first.englishSentence), first.id)
    }

    // MARK: - The walker

    func testTheHunkWalkerTracksBothSidesLineNumbers() {
        let patch = """
        @@ -5,4 +7,5 @@
         context
        -removed
        +added one
        +added two
         tail
        """
        let rows = PatchWalker.rows(in: patch)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].kind, .context)
        XCTAssertEqual(rows[0].baseLine, 5)
        XCTAssertEqual(rows[0].headLine, 7)
        XCTAssertEqual(rows[1].kind, .removed)
        XCTAssertEqual(rows[1].baseLine, 6)
        XCTAssertEqual(rows[1].headLine, 8)
        XCTAssertEqual(rows[2].kind, .added)
        XCTAssertEqual(rows[2].headLine, 8)
        XCTAssertEqual(rows[3].headLine, 9)
        XCTAssertEqual(rows[4].kind, .context)
        XCTAssertEqual(rows[4].baseLine, 7)
        XCTAssertEqual(rows[4].headLine, 10)
    }

    func testTextBeforeTheFirstHunkAndNoNewlineMarkersAreIgnored() {
        let patch = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let rows = PatchWalker.rows(in: patch)
        XCTAssertEqual(rows.map(\.kind), [.removed, .added])
    }
}
