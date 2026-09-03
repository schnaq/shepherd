import Foundation
import XCTest

@testable import ShepherdCore

/// What a pull-request description claims about itself (ADR 0026, plan §2.A).
///
/// The corpus below is thirty realistic bodies, written in the shapes this feature actually meets:
/// Claude Code's `## Summary` / `## Test plan` layout, Copilot's prose-then-bullets, Dependabot's
/// changelog dump, and the two-word human description. Each fixture asserts the *set of kinds*
/// rather than the quotes, because the quote is whichever sentence came first and pinning all
/// thirty of them would make the corpus a transcription exercise instead of a specification; the
/// quotes are asserted where they carry a rule (sentence scoping, decoration stripping).
///
/// The interesting failures the corpus is built to catch:
///
/// - a verb from the *next* bullet completing a claim in the one above it (sentence scoping);
/// - `1.2` and `v2.0.1` read as sentence boundaries;
/// - "no tests were added" read as a claim that tests were added;
/// - a bare `#42` far down the body read as a closing reference;
/// - `- [x] ` read as prose;
/// - a second sentence about scope producing a second scope line on the card.
final class ClaimExtractorTests: XCTestCase {
    // MARK: - Corpus

    private struct Fixture {
        let name: String
        let body: String
        let expected: [Claim.Kind]
    }

    private let corpus: [Fixture] = [
        Fixture(
            name: "claude-code-classic",
            body: """
            ## Summary
            - Adds a retry loop to the uploader so a flaky network no longer fails a whole batch.
            - Only `Sources/Uploader/` changed.

            ## Test plan
            - [x] `swift test` passes locally
            - [x] Added unit tests for the retry path

            Fixes #142
            """,
            expected: [
                .testsAdded,
                .scopeLimited(module: "Sources/Uploader"),
                .fixesIssue(number: 142),
            ]
        ),
        Fixture(
            name: "claude-code-no-breaking",
            body: """
            ## Summary

            Rewrites the parser's error recovery. No breaking changes to the public API.

            ## Test plan

            - [x] All 412 tests pass
            - [x] Ran the integration suite twice

            Closes #77
            """,
            expected: [.testsAdded, .noBreakingChanges, .fixesIssue(number: 77)]
        ),
        Fixture(
            name: "copilot-prose-then-bullets",
            body: """
            This pull request fixes #310 by validating the webhook signature before parsing the body.

            ### Changes
            * `Sources/Automation/WebhookVerifier.swift`: constant-time compare
            * Tests added in `Tests/AutomationTests/`

            ### Notes
            Backwards compatible: the old header is still accepted.
            """,
            expected: [.testsAdded, .noBreakingChanges, .fixesIssue(number: 310)]
        ),
        Fixture(name: "terse-human", body: "typo fix", expected: []),
        Fixture(
            name: "terse-human-with-reference",
            body: "Bump the timeout, see #9 for the trace.",
            expected: [.fixesIssue(number: 9)]
        ),
        Fixture(
            name: "only-readme-no-other-changes",
            body: "Only the README changed, no other changes.",
            expected: [.scopeLimited(module: "README")]
        ),
        Fixture(
            name: "scope-named-with-an-article",
            body: "Only the parser changed; everything else is untouched.",
            expected: [.scopeLimited(module: "parser")]
        ),
        Fixture(
            name: "scope-named-as-a-type",
            body: "This just touches GitHubClient and nothing else.",
            expected: [.scopeLimited(module: "GitHubClient")]
        ),
        Fixture(
            name: "scope-named-as-a-file",
            body: "Only project.yml is modified.",
            expected: [.scopeLimited(module: "project.yml")]
        ),
        Fixture(
            name: "tests-negated-is-not-a-claim",
            body: """
            ## Summary
            Renames a private helper.

            No tests were added because the behaviour is unchanged.
            """,
            expected: []
        ),
        Fixture(
            name: "tests-green-suite-runs",
            body: "CI is green and the spec suite runs clean.",
            expected: [.testsAdded]
        ),
        Fixture(
            name: "breaking-non-hyphenated",
            body: "This is a non-breaking refactor of the sync engine.",
            expected: [.noBreakingChanges]
        ),
        Fixture(
            name: "breaking-backward-hyphenated",
            body: "Backward-compatible change: the old enum case stays.",
            expected: [.noBreakingChanges]
        ),
        Fixture(
            name: "issue-resolves-with-a-regression-test",
            body: "Resolves #1024 and adds a regression test that passes.",
            expected: [.testsAdded, .fixesIssue(number: 1024)]
        ),
        Fixture(
            name: "issue-two-references",
            body: "Fixes #4 and closes #5.",
            expected: [.fixesIssue(number: 4), .fixesIssue(number: 5)]
        ),
        Fixture(
            name: "issue-bare-reference-outside-the-first-paragraph",
            body: """
            ## Summary
            Refactors the digest.

            Related to #200 but does not close it.
            """,
            expected: []
        ),
        Fixture(
            name: "issue-bare-reference-in-the-first-paragraph",
            body: """
            ## Summary
            Refactors the uploader (#142) so the retry is testable.

            Nothing else.
            """,
            expected: [.fixesIssue(number: 142)]
        ),
        Fixture(
            name: "issue-reference-into-another-repository-is-not-ours",
            body: """
            ## Summary
            Mirrors the fix from octocat/Hello-World#123 into the uploader.

            Nothing else.
            """,
            expected: []
        ),
        Fixture(
            name: "agent-long-body-all-four-claims",
            body: """
            ## Summary

            This change makes the inbox sweep resilient to a 502 from GitHub's search API. The
            sweep now retries twice with jitter and, on a third failure, keeps the cached rows
            rather than pruning them.

            ## Implementation notes

            - `Sources/ShepherdSync/SyncEngine.swift` gains a `retrying` wrapper.
            - Only `Sources/ShepherdSync/` changed; no other changes.

            ## Test plan

            - [x] `swift test --filter ShepherdSyncTests` passes
            - [x] Added a fixture for the 502 path

            ## Compatibility

            No breaking changes.

            Fixes #488
            """,
            expected: [
                .testsAdded,
                .scopeLimited(module: "Sources/ShepherdSync"),
                .noBreakingChanges,
                .fixesIssue(number: 488),
            ]
        ),
        Fixture(
            name: "agent-terse-fix-plus-compatibility",
            body: """
            Fix #61: guard against a nil avatar URL.

            No breaking changes.
            """,
            expected: [.noBreakingChanges, .fixesIssue(number: 61)]
        ),
        Fixture(
            name: "no-claims-at-all",
            body: """
            ## Summary

            Moves two files. Nothing else worth saying.
            """,
            expected: []
        ),
        Fixture(name: "empty-body", body: "", expected: []),
        Fixture(name: "whitespace-only-body", body: "   \n\n  \n", expected: []),
        Fixture(
            name: "shouting-caps",
            body: "ONLY `SOURCES/PARSER/` CHANGED. TESTS ADDED. NO BREAKING CHANGES. FIXES #12",
            expected: [
                .testsAdded,
                .scopeLimited(module: "SOURCES/PARSER"),
                .noBreakingChanges,
                .fixesIssue(number: 12),
            ]
        ),
        Fixture(
            name: "a-version-number-is-not-a-sentence-boundary",
            body: "No breaking changes for the 1.2 API surface.",
            expected: [.noBreakingChanges]
        ),
        Fixture(
            name: "test-plan-heading-with-nothing-in-it",
            body: """
            ## Test plan

            Nothing to run here.
            """,
            expected: []
        ),
        Fixture(
            name: "dependabot-changelog",
            body: """
            Bumps [GRDB.swift](https://github.com/groue/GRDB.swift) from 7.11.0 to 7.12.0.

            Release notes: performance work in the statement cache.
            """,
            expected: []
        ),
        Fixture(
            name: "scope-is-a-workflow-file",
            body: """
            ## Summary
            Only `.github/workflows/ci.yml` changed to add the Linux job.
            """,
            expected: [.scopeLimited(module: ".github/workflows/ci.yml")]
        ),
        Fixture(
            name: "tests-and-scope-in-one-sentence",
            body: "Only `Tests/` changed and the new tests pass.",
            expected: [.testsAdded, .scopeLimited(module: "Tests")]
        ),
        Fixture(
            name: "german-body-with-an-english-keyword",
            body: "Kleiner Fix. Fixes #3.",
            expected: [.fixesIssue(number: 3)]
        ),
        Fixture(
            name: "numbered-list",
            body: """
            1. Adds the claim extractor.
            2. Only `Packages/ShepherdKit/Sources/ShepherdCore/Claims/` changed.
            3. Tests added and passing.
            """,
            expected: [
                .testsAdded,
                .scopeLimited(module: "Packages/ShepherdKit/Sources/ShepherdCore/Claims"),
            ]
        ),
        Fixture(
            name: "block-quote",
            body: """
            > Only the CLI changed.

            Fixes #500
            """,
            expected: [.scopeLimited(module: "CLI"), .fixesIssue(number: 500)]
        ),
        Fixture(
            name: "solely",
            body: "Solely `Shepherd/Features/Review/` is touched.",
            expected: [.scopeLimited(module: "Shepherd/Features/Review")]
        ),
    ]

    // MARK: - The corpus assertion

    func testEveryFixtureExtractsExactlyTheExpectedKinds() {
        XCTAssertGreaterThanOrEqual(corpus.count, 30, "the corpus is the specification")
        for fixture in corpus {
            let extracted = ClaimExtractor.extract(from: fixture.body).map(\.kind)
            XCTAssertEqual(
                extracted,
                fixture.expected,
                "fixture “\(fixture.name)” extracted \(extracted) instead of \(fixture.expected)"
            )
        }
    }

    func testEveryExtractedClaimQuotesANonEmptySentenceFromTheBody() {
        for fixture in corpus {
            for claim in ClaimExtractor.extract(from: fixture.body) {
                XCTAssertFalse(
                    claim.quote.trimmingCharacters(in: .whitespaces).isEmpty,
                    "fixture “\(fixture.name)” produced a claim with no quote"
                )
            }
        }
    }

    // MARK: - Ordering and deduplication

    func testClaimsAreOrderedTestsScopeBreakingIssueWhateverTheBodysOrder() {
        let body = """
        Fixes #7. No breaking changes. Only `Sources/` changed. Tests added.
        """
        XCTAssertEqual(
            ClaimExtractor.extract(from: body).map(\.kind),
            [
                .testsAdded,
                .scopeLimited(module: "Sources"),
                .noBreakingChanges,
                .fixesIssue(number: 7),
            ]
        )
    }

    func testTwoSentencesAboutScopeProduceOneLine() {
        let body = """
        Only `Sources/Parser/` changed.
        There are no other changes.
        """
        let claims = ClaimExtractor.extract(from: body)
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.kind, .scopeLimited(module: "Sources/Parser"))
        XCTAssertEqual(claims.first?.quote, "Only `Sources/Parser/` changed.")
    }

    func testTheSameIssueTwiceIsOneClaimAndTwoIssuesAreTwo() {
        XCTAssertEqual(
            ClaimExtractor.extract(from: "Fixes #12. Also closes #12.").map(\.kind),
            [.fixesIssue(number: 12)]
        )
        XCTAssertEqual(
            ClaimExtractor.extract(from: "Fixes #12. Also closes #13.").map(\.kind),
            [.fixesIssue(number: 12), .fixesIssue(number: 13)]
        )
    }

    func testExtractionIsDeterministic() {
        let body = corpus.first { $0.name == "agent-long-body-all-four-claims" }?.body ?? ""
        let first = ClaimExtractor.extract(from: body)
        let second = ClaimExtractor.extract(from: body)
        XCTAssertEqual(first, second)
    }

    // MARK: - Sentence scoping

    func testAVerbFromTheNextBulletCannotCompleteAClaimInTheOneAbove() {
        // "tests" is on one line and "added" on the next: two sentences, no claim.
        let body = """
        - Reordered the tests
        - Nothing else
        """
        XCTAssertEqual(ClaimExtractor.extract(from: body).map(\.kind), [])
    }

    func testDecorationIsStrippedFromTheQuote() {
        let claims = ClaimExtractor.extract(from: "- [x] `swift test` passes locally")
        XCTAssertEqual(claims.map(\.kind), [.testsAdded])
        XCTAssertEqual(claims.first?.quote, "`swift test` passes locally")
    }

    func testSentencesAreCutAtTerminatorsFollowedByWhitespaceOnly() {
        XCTAssertEqual(
            ClaimText.sentences(in: "Ships v2.0.1. Tests pass."),
            ["Ships v2.0.1.", "Tests pass."]
        )
    }

    func testTheFirstParagraphSkipsLeadingHeadings() {
        let body = """
        ## Summary

        Closes the gap in #4.

        Later mention of #5.
        """
        XCTAssertEqual(ClaimText.firstParagraph(of: body), "Closes the gap in #4.")
    }

    // MARK: - Module tokens

    func testModuleTokenPrefersTheMostSpecificShape() {
        XCTAssertEqual(ClaimExtractor.module(after: " `Sources/Parser/` and nothing else"), "Sources/Parser")
        XCTAssertEqual(ClaimExtractor.module(after: " Sources/Parser changed"), "Sources/Parser")
        XCTAssertEqual(ClaimExtractor.module(after: " project.yml changed"), "project.yml")
        XCTAssertEqual(ClaimExtractor.module(after: " GitHubClient changed"), "GitHubClient")
        XCTAssertEqual(ClaimExtractor.module(after: " the parser changed"), "parser")
    }

    func testAGenericNounAfterTheArticleIsNotAModule() {
        XCTAssertNil(ClaimExtractor.module(after: " the same files as before"))
        XCTAssertNil(ClaimExtractor.module(after: " the tests"))
        XCTAssertNil(ClaimExtractor.module(after: " a formatting pass"))
    }
}
