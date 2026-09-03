import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// Every evidence fact has a German sentence, and the catalog actually has the row (ADR 0026's
/// facts, ADR 0022's rules).
///
/// `Scripts/check-localization.py` proves that every key this renderer *writes* is in the catalog
/// with a German value whose specifiers match. What it cannot see is the other direction — that
/// every `EvidenceFact.Kind` the checker can *produce* reaches one of those keys — because that is
/// a fact about a Swift `switch`, not about a literal. A case that fell through to an empty string,
/// or a branch nobody ever renders, would pass the Python gate and show a German reviewer a blank
/// line or an English sentence.
///
/// So this test walks one sample per case *and per branch inside a case* — a count of one and a
/// count of many, an issue open, closed and in a state Shepherd does not model, with and without a
/// title, each of the four failed reads, each of the four match reasons — and asserts two things
/// about each: that it renders to a sentence at all, and that the German rendering **differs from
/// the English one**, which is the only way from inside the app to say "there is a German row and
/// it was used".
///
/// The German lookup goes through the compiled `de.lproj` **as a bundle of its own**, exactly as
/// `LocalizationTests` does and for the reason written up there at length: the `locale:` parameter
/// of `String(localized:…)` formats the arguments but does not choose the language table, so a
/// test that trusted the default bundle would pass on a German Mac and fail on an English one.
/// `Bundle(for:)` is the opposite end of the same trick: the test bundle carries no `Localizable`
/// table, so a lookup there gives the key back — which *is* the English sentence (ADR 0022).
@MainActor
final class EvidenceFactTextTests: XCTestCase {
    // MARK: - The samples

    /// One reason per case of ``ShepherdCore/AcceptanceMatch/Reason``, and one per branch:
    /// singular and plural words, a list long enough to be capped, both halves of a miss, and the
    /// on-device tail.
    private static let reasons: [AcceptanceMatch.Reason] = [
        .wordsAppear(present: ["retry"], total: 1),
        .wordsAppear(present: ["retry"], total: 4),
        .wordsAppear(present: ["retry", "upload", "timeout", "flaky", "stale"], total: 6),
        .readsAsAbout(similarity: 0.62),
        .noDistinctiveWord,
        .wordsMissing(present: [], total: 1, similarity: nil),
        .wordsMissing(present: [], total: 4, similarity: nil),
        .wordsMissing(present: ["retry"], total: 4, similarity: nil),
        .wordsMissing(present: ["retry", "upload"], total: 5, similarity: 0.45),
    ]

    /// One fact kind per case, and one per branch a count or a state opens inside a case.
    ///
    /// `requireEveryKindIsSampled(_:)` below is what keeps this list honest: it is a `switch` with
    /// no `default`, so a new case stops compiling here until it has been added.
    private static var kinds: [EvidenceFact.Kind] {
        var kinds: [EvidenceFact.Kind] = [
            .noTestFileChanged,
            .testFilesChanged(count: 1),
            .testFilesChanged(count: 3),
            .testFile(path: "Tests/ParserTests/LexerTests.swift", additions: 12, deletions: 3),
            .assertionRemoved(
                path: "Tests/UploadTests.swift",
                line: 12,
                snippet: "XCTAssertEqual(retries, 2)"
            ),
            .skippedTestAdded(
                path: "Tests/UploadTests.swift",
                line: 40,
                snippet: "throw XCTSkip(\"flaky\")"
            ),
            .noChecksConfigured,
            .ciGreen,
            .ciGreenCounted(passed: 1, total: 1),
            .ciGreenCounted(passed: 7, total: 7),
            .ciRed,
            .ciRedCounted(failed: 1, total: 1),
            .ciRedCounted(failed: 1, total: 7),
            .checkFailed(name: "Linux"),
            .ciUnfinished,
            .ciUnfinishedRunning(count: 1),
            .ciUnfinishedRunning(count: 2),
            .noChangedFiles,
            .topLevelPaths(count: 1, paths: ["Sources"]),
            .topLevelPaths(count: 9, paths: ["Sources", "Tests"]),
            .claimNamesNoModule,
            .noPathContainsToken(token: "Sources/Parser"),
            .filesUnderToken(inside: 8, total: 11, token: "Sources/Parser"),
            .fileOutsideToken(path: ".github/workflows/ci.yml", token: "Sources/Parser"),
            .exportedDeclarationChanged(
                path: "Sources/GitHubKit/GitHubClient.swift",
                line: 214,
                snippet: "public func issue(repo: RepoRef, number: Int) async throws"
            ),
            .manifestLineChanged(path: "Package.swift"),
            .schemaChanged(path: "Sources/ShepherdPersistence/Migrations/V5.swift"),
            .workflowChanged(path: ".github/workflows/ci.yml"),
            .configurationChanged(path: "project.yml"),
            .noReadableDiff,
            .noExportedDeclarationChanged,
            .lockfile(path: "Package.resolved"),
            .generatedFile(path: "web/dist/viewer.js"),
            .configurationFile(path: "project.yml"),
            .issueReferenced(number: 142, repo: "schnaq/review"),
            .issueNotFetched,
            .referenceIsPullRequest(number: 7),
            .noAcceptanceChecklist,
            .everyBulletMentioned,
            .bulletsMentioned(mentioned: 2, total: 3),
        ]
        kinds += IssueLookupFailure.allCases.map { EvidenceFact.Kind.issueLookupFailed($0) }
        for state in IssueSummary.State.allCases {
            for title in ["Uploads fail silently", ""] {
                for bulletCount in [1, 3] {
                    kinds.append(
                        .issueWithBullets(
                            number: 142,
                            title: title,
                            state: state,
                            bulletCount: bulletCount
                        )
                    )
                }
            }
        }
        kinds += reasons.map { reason in
            EvidenceFact.Kind.acceptanceBullet(text: "retry the flaky upload", reason: reason)
        }
        return kinds
    }

    /// The compiled German table, loaded as a bundle so the lookup cannot depend on the runner.
    private func germanTable() throws -> Bundle {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "de", withExtension: "lproj"),
            "no de.lproj in the app bundle: the String Catalog was not compiled for German"
        )
        return try XCTUnwrap(Bundle(url: url), "de.lproj is not loadable as a bundle")
    }

    /// The bundle with no `Localizable` table, whose lookups give the key — the English string —
    /// back.
    private var englishTable: Bundle { Bundle(for: Self.self) }

    // MARK: - Every kind renders

    func testEveryFactKindRendersToASentence() {
        for kind in Self.kinds {
            let sentence = kind.localizedSentence(bundle: englishTable)
            XCTAssertFalse(sentence.isEmpty, "\(kind) renders to nothing")
            XCTAssertTrue(sentence.hasSuffix("."), "not a sentence: “\(sentence)”")
        }
    }

    func testEveryMatchReasonRendersToASentence() {
        for reason in Self.reasons {
            let sentence = reason.localizedSentence(bundle: englishTable)
            XCTAssertFalse(sentence.isEmpty, "\(reason) renders to nothing")
            XCTAssertTrue(sentence.hasSuffix("."), "not a sentence: “\(sentence)”")
        }
    }

    /// No two samples render the same sentence.
    ///
    /// Which is how this file notices that a branch was *added* to a case and the sample list did
    /// not grow with it: two samples of one case that come out identical mean one of the two keys
    /// is unreachable, and an unreachable key is a stale catalog row the Python gate will then
    /// report — but only if it is in the catalog at all.
    func testTheSamplesAreAllDifferentSentences() {
        let sentences = Self.kinds.map { $0.localizedSentence(bundle: englishTable) }
        XCTAssertEqual(Set(sentences).count, sentences.count)
    }

    // MARK: - Every kind has a German row

    func testEveryFactKindHasAGermanRow() throws {
        let german = try germanTable()
        for kind in Self.kinds {
            let translated = kind.localizedSentence(bundle: german)
            XCTAssertFalse(translated.isEmpty, "\(kind) renders to nothing in German")
            XCTAssertNotEqual(
                translated,
                kind.localizedSentence(bundle: englishTable),
                "no German row for \(kind)"
            )
        }
    }

    func testEveryMatchReasonHasAGermanRow() throws {
        let german = try germanTable()
        for reason in Self.reasons {
            let translated = reason.localizedSentence(bundle: german)
            XCTAssertFalse(translated.isEmpty, "\(reason) renders to nothing in German")
            XCTAssertNotEqual(
                translated,
                reason.localizedSentence(bundle: englishTable),
                "no German row for \(reason)"
            )
        }
    }

    /// The German keeps what may not be translated: the path, the code and the number.
    func testTheGermanSentenceInterpolatesPathsAndSnippetsVerbatim() throws {
        let german = try germanTable()
        let fact = EvidenceFact(
            kind: .assertionRemoved(
                path: "Tests/UploadTests.swift",
                line: 12,
                snippet: "XCTAssertEqual(retries, 2)"
            ),
            path: "Tests/UploadTests.swift",
            line: 12
        )
        let sentence = fact.localizedSentence(bundle: german)
        XCTAssertTrue(sentence.contains("Tests/UploadTests.swift"), sentence)
        XCTAssertTrue(sentence.contains("XCTAssertEqual(retries, 2)"), sentence)
        XCTAssertTrue(sentence.contains("12"), sentence)
        // German quotes its quotations (ADR 0022's typography) — the value inside them is
        // untouched.
        XCTAssertTrue(sentence.contains("„Tests/UploadTests.swift“"), sentence)
    }

    /// The English half is `ShepherdCore`'s and is *not* what the card draws.
    ///
    /// The two renderings of one fact have to stay two: a GitHub comment carries the English one
    /// (`ClaimsEvidenceCardState.commentText(for:)`) whatever language the reviewer's Mac is in.
    func testTheEnglishSentenceIsUnchangedByTheLocalisedOne() {
        let fact = EvidenceFact(kind: .ciGreenCounted(passed: 7, total: 7))
        XCTAssertEqual(fact.englishSentence, "CI is green: 7 of 7 checks passed.")
        XCTAssertEqual(
            fact.localizedSentence(bundle: englishTable),
            "CI is green: 7 of 7 checks passed."
        )
    }

    // MARK: - Exhaustiveness

    /// Adding a case to ``ShepherdCore/EvidenceFact/Kind`` has to stop this file compiling.
    ///
    /// A `switch` with no `default` is the cheapest way to say "there is a list above that has to
    /// grow with you": the compiler points here, the fix is one sample, and the two assertions
    /// then cover the new sentence and its German row.
    private func requireEveryKindIsSampled(_ kind: EvidenceFact.Kind) {
        switch kind {
        case .noTestFileChanged, .testFilesChanged, .testFile, .assertionRemoved,
            .skippedTestAdded, .noChecksConfigured, .ciGreen, .ciGreenCounted, .ciRed,
            .ciRedCounted, .checkFailed, .ciUnfinished, .ciUnfinishedRunning, .noChangedFiles,
            .topLevelPaths, .claimNamesNoModule, .noPathContainsToken, .filesUnderToken,
            .fileOutsideToken, .exportedDeclarationChanged, .manifestLineChanged, .schemaChanged,
            .workflowChanged, .configurationChanged, .noReadableDiff,
            .noExportedDeclarationChanged, .lockfile, .generatedFile, .configurationFile,
            .issueReferenced, .issueNotFetched, .issueLookupFailed, .referenceIsPullRequest,
            .noAcceptanceChecklist, .issueWithBullets, .everyBulletMentioned, .bulletsMentioned,
            .acceptanceBullet:
            break
        }
    }

    /// The same guard for the four match reasons.
    private func requireEveryReasonIsSampled(_ reason: AcceptanceMatch.Reason) {
        switch reason {
        case .wordsAppear, .readsAsAbout, .noDistinctiveWord, .wordsMissing:
            break
        }
    }

    func testTheSampleListsCoverEveryCase() {
        for kind in Self.kinds { requireEveryKindIsSampled(kind) }
        for reason in Self.reasons { requireEveryReasonIsSampled(reason) }
    }
}
