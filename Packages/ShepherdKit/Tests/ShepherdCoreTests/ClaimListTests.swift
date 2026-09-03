import Foundation
import XCTest

@testable import ShepherdCore

/// The twin of the optional on-device claim pass, and the merge that makes it *additive*
/// (ADR 0026's tier-2 amendment, plan §2.A).
///
/// Two halves, and both of them are where a wrong answer would do damage the card cannot recover
/// from:
///
/// - **Decoding is lenient about spelling and strict about substance.** A model writes
///   `"tests_added"` as readily as `"testsAdded"` and those are one answer; a `scopeLimited` with
///   no module, on the other hand, is a line whose evidence could only ever say "?" — so it is
///   dropped, and dropping it costs that entry and not the four good claims beside it.
/// - **The merge may only ever add.** The deterministic claims come out of it unchanged and in
///   their order, a model claim that repeats one of them disappears, and what survives is marked
///   as read by the model. A Mac with the model has to show a *superset* of the same card, or the
///   feature is not additive and ADR 0026 does not allow it.
final class ClaimListTests: XCTestCase {
    // MARK: - Helpers

    private func decode(_ json: String) throws -> ClaimList {
        try JSONDecoder().decode(ClaimList.self, from: Data(json.utf8))
    }

    private func patternClaims() -> [Claim] {
        [
            Claim(kind: .testsAdded, quote: "Tests added."),
            Claim(kind: .noBreakingChanges, quote: "No breaking changes."),
        ]
    }

    // MARK: - The default origin

    func testAClaimIsAPatternClaimUnlessItSaysOtherwise() {
        // The whole reason `origin` has a default: every call site written before tier 2 existed
        // means "the patterns read this", and none of them says so.
        XCTAssertEqual(Claim(kind: .testsAdded, quote: "Tests added.").origin, .pattern)
        for claim in ClaimExtractor.extract(from: "Tests added. Fixes #7.") {
            XCTAssertEqual(claim.origin, .pattern)
        }
    }

    func testAnEncodedClaimWithoutAnOriginDecodesAsAPatternClaim() throws {
        // Built by stripping the key rather than by writing the JSON out, so the test asserts the
        // tolerance and not `Claim.Kind`'s synthesized encoding of an enum with payloads.
        let encoded = try JSONEncoder().encode(
            Claim(kind: .testsAdded, quote: "Tests added.", origin: .model)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "origin"))
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let claim = try JSONDecoder().decode(Claim.self, from: stripped)
        XCTAssertEqual(claim.origin, .pattern)
        XCTAssertEqual(claim.kind, .testsAdded)
    }

    func testAClaimRoundTripsWithItsOrigin() throws {
        let claim = Claim(kind: .fixesIssue(number: 142), quote: "Fixes #142.", origin: .model)
        let data = try JSONEncoder().encode(claim)
        XCTAssertEqual(try JSONDecoder().decode(Claim.self, from: data), claim)
    }

    // MARK: - Decoding the twin

    func testTheFlatShapeDecodesAllFourKinds() throws {
        let list = try decode(
            """
            {"claims": [
              {"kind": "testsAdded", "quote": "The suite is green locally."},
              {"kind": "scopeLimited", "module": "Sources/Uploader", "quote": "Nothing outside the uploader is touched."},
              {"kind": "noBreakingChanges", "quote": "Callers do not have to change."},
              {"kind": "fixesIssue", "issueNumber": 142, "quote": "This makes #142 go away."}
            ]}
            """
        )
        XCTAssertEqual(
            list.claims.map(\.kind),
            [
                .testsAdded,
                .scopeLimited(module: "Sources/Uploader"),
                .noBreakingChanges,
                .fixesIssue(number: 142),
            ]
        )
        XCTAssertEqual(list.claims.first?.quote, "The suite is green locally.")
    }

    func testTheKindSpellingIsLenientAndTheVocabularyIsNot() throws {
        let list = try decode(
            """
            {"claims": [
              {"kind": "tests_added", "quote": "Ran the suite."},
              {"kind": "No Breaking Changes", "quote": "Nothing breaks."},
              {"kind": "looksSafe", "quote": "This is a safe change."}
            ]}
            """
        )
        // The two spellings are the same two answers; the fifth shape does not exist, and
        // inventing a default for it would present a guess as the model's reading.
        XCTAssertEqual(list.claims.map(\.kind), [.testsAdded, .noBreakingChanges])
    }

    func testAnEntryMissingTheValueItsShapeNeedsCostsOnlyThatEntry() throws {
        let list = try decode(
            """
            {"claims": [
              {"kind": "scopeLimited", "quote": "Only the important bits changed."},
              {"kind": "scopeLimited", "module": "   ", "quote": "Just the parser."},
              {"kind": "fixesIssue", "quote": "Fixes the bug."},
              {"kind": "fixesIssue", "issueNumber": 0, "quote": "Closes the issue."},
              {"kind": "testsAdded", "quote": "  "},
              {"kind": "testsAdded", "quote": "Tests were added for the retry path."}
            ]}
            """
        )
        XCTAssertEqual(list.claims.count, 1, "five malformed entries, and the good one survives")
        XCTAssertEqual(list.claims.first?.kind, .testsAdded)
        XCTAssertEqual(list.claims.first?.quote, "Tests were added for the retry path.")
    }

    func testTheQuoteIsTrimmedAndAnAbsentListIsAnEmptyOne() throws {
        let list = try decode(#"{"claims": [{"kind": "testsAdded", "quote": "  Tests added.\n"}]}"#)
        XCTAssertEqual(list.claims.first?.quote, "Tests added.")
        // "The patterns already had everything" is the common answer, and a model expressing it
        // by leaving the key out is not an error.
        XCTAssertTrue(try decode("{}").isEmpty)
        XCTAssertTrue(try decode(#"{"claims": []}"#).isEmpty)
        XCTAssertTrue(ClaimList.empty.isEmpty)
    }

    func testTheTwinRoundTripsThroughItsFlatShape() throws {
        let list = ClaimList(claims: [
            ExtractedClaim(kind: .scopeLimited(module: "Sources/Parser"), quote: "Only the parser."),
            ExtractedClaim(kind: .fixesIssue(number: 7), quote: "Closes #7."),
        ])
        let encoder = JSONEncoder()
        // Slashes unescaped, so the assertion below can name the module the way a reader would.
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(list)
        XCTAssertEqual(try JSONDecoder().decode(ClaimList.self, from: data), list)
        // The encoded kind is the flat name and not Swift's enum-with-payload shape, because the
        // first one is what a model writes.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"scopeLimited\""), text)
        XCTAssertTrue(text.contains("\"Sources/Parser\""), text)
        XCTAssertFalse(text.contains("\"module\":\"\""), text)
    }

    // MARK: - Merging

    func testAModelClaimIsAddedAndMarkedAsRead() {
        let list = ClaimList(claims: [
            ExtractedClaim(kind: .scopeLimited(module: "Sources/Uploader"), quote: "Confined to the uploader."),
        ])
        let merged = list.merged(into: patternClaims())
        XCTAssertEqual(merged.count, 3)
        let added = merged.filter { $0.origin == .model }
        XCTAssertEqual(added.map(\.kind), [.scopeLimited(module: "Sources/Uploader")])
        XCTAssertEqual(added.first?.quote, "Confined to the uploader.")
    }

    func testTheDeterministicClaimsComeOutUntouched() {
        let patterns = patternClaims()
        let list = ClaimList(claims: [
            // Same shape, different sentence: tier 2 may not re-quote what tier 1 read.
            ExtractedClaim(kind: .testsAdded, quote: "A different sentence about tests."),
            ExtractedClaim(kind: .fixesIssue(number: 9), quote: "Closes #9."),
        ])
        let merged = list.merged(into: patterns)
        for claim in patterns {
            XCTAssertTrue(merged.contains(claim), "\(claim.kind) survived unchanged")
        }
        XCTAssertEqual(merged.filter { $0.origin == .pattern }.count, patterns.count)
    }

    func testADuplicateOfAPatternClaimIsDropped() {
        // Both by dedup key: "Only `Sources/Parser/` changed" and "no other changes" are one
        // claim about scope, so a model that phrases it differently adds no line.
        let patterns = [Claim(kind: .scopeLimited(module: ""), quote: "No other changes.")]
        let list = ClaimList(claims: [
            ExtractedClaim(kind: .scopeLimited(module: "Sources/Parser"), quote: "Just the parser."),
        ])
        let merged = list.merged(into: patterns)
        XCTAssertEqual(merged, patterns)
    }

    func testTwoModelClaimsOfTheSameShapeCollapseToTheFirst() {
        let list = ClaimList(claims: [
            ExtractedClaim(kind: .testsAdded, quote: "The suite passes."),
            ExtractedClaim(kind: .testsAdded, quote: "I ran the tests again."),
        ])
        let merged = list.merged(into: [])
        XCTAssertEqual(merged.map(\.quote), ["The suite passes."])
    }

    func testTwoIssuesAreTwoClaimsAndTheyAreOrderedByNumber() {
        let list = ClaimList(claims: [
            ExtractedClaim(kind: .fixesIssue(number: 12), quote: "Also #12."),
        ])
        let merged = list.merged(into: [Claim(kind: .fixesIssue(number: 4), quote: "Fixes #4.")])
        XCTAssertEqual(merged.map(\.kind), [.fixesIssue(number: 4), .fixesIssue(number: 12)])
    }

    func testTheMergedOrderIsTheCardsOrderRatherThanTheModelsOrder() {
        // The model answered breaking-changes first and tests last; the card reads tests, scope,
        // breaking, issues on every pull request, and a merged card has to read the same way.
        let list = ClaimList(claims: [
            ExtractedClaim(kind: .noBreakingChanges, quote: "Backwards compatible."),
            ExtractedClaim(kind: .fixesIssue(number: 3), quote: "Fixes #3."),
            ExtractedClaim(kind: .scopeLimited(module: "Sources/Parser"), quote: "Only the parser."),
            ExtractedClaim(kind: .testsAdded, quote: "Tests added."),
        ])
        XCTAssertEqual(
            list.merged(into: []).map(\.kind.sortIndex),
            [0, 1, 2, 3]
        )
    }

    func testAnEmptyAnswerLeavesTheClaimsExactlyAsTheyWere() {
        XCTAssertEqual(ClaimList.empty.merged(into: patternClaims()), patternClaims())
        XCTAssertTrue(ClaimList.empty.merged(into: []).isEmpty)
    }

    func testAClaimWithNothingToQuoteIsNeverMergedIn() {
        // Refused by the decoder and by the app's conversion too; this is the last of the three
        // gates, and it is the one whose output is drawn.
        let list = ClaimList(claims: [ExtractedClaim(kind: .testsAdded, quote: " \n ")])
        XCTAssertTrue(list.merged(into: []).isEmpty)
    }

    // MARK: - The flat vocabulary

    func testEveryShapeHasANameAndComesBackFromIt() {
        let kinds: [Claim.Kind] = [
            .testsAdded,
            .scopeLimited(module: "Sources/Parser"),
            .noBreakingChanges,
            .fixesIssue(number: 5),
        ]
        XCTAssertEqual(
            kinds.map(\.name),
            [.testsAdded, .scopeLimited, .noBreakingChanges, .fixesIssue]
        )
        XCTAssertEqual(Claim.Kind.Name.allCases.count, kinds.count)
        XCTAssertEqual(Claim.Kind(name: .testsAdded), .testsAdded)
        XCTAssertEqual(Claim.Kind(name: .noBreakingChanges), .noBreakingChanges)
        XCTAssertEqual(
            Claim.Kind(name: .scopeLimited, module: "Sources/Parser"),
            .scopeLimited(module: "Sources/Parser")
        )
        XCTAssertEqual(Claim.Kind(name: .fixesIssue, issueNumber: 5), .fixesIssue(number: 5))
        XCTAssertNil(Claim.Kind(name: .scopeLimited))
        XCTAssertNil(Claim.Kind(name: .scopeLimited, module: ""))
        XCTAssertNil(Claim.Kind(name: .fixesIssue))
        XCTAssertNil(Claim.Kind(name: .fixesIssue, issueNumber: 0))
    }
}
