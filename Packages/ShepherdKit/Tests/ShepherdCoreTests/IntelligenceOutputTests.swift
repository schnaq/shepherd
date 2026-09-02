import Foundation
import XCTest

@testable import ShepherdCore

/// The `Codable` twins of the generated types (plan §0.4).
///
/// These are decoded straight out of a cloud provider's answer, so the tests are written the way
/// that answer arrives: as JSON text, including the spellings a model reaches for when it has not
/// read the prompt carefully. What is *not* tolerated is asserted too — an invented case is an
/// error, because presenting a default as the model's verdict would be a lie.
final class TriageVerdictTests: XCTestCase {
    func testTheContractShapeDecodes() throws {
        let verdict = try decode(
            TriageVerdict.self,
            from: #"{"kind":"fix","risk":"high","reason":"Touches auth middleware and deletes two tests."}"#
        )
        XCTAssertEqual(verdict.kind, .fix)
        XCTAssertEqual(verdict.risk, .high)
        XCTAssertEqual(verdict.reason, "Touches auth middleware and deletes two tests.")
    }

    func testEveryKindAndEveryRiskHasAWireSpelling() throws {
        for kind in TriageVerdict.Kind.allCases {
            let verdict = try decode(
                TriageVerdict.self,
                from: #"{"kind":"\#(kind.rawValue)","risk":"low","reason":"r"}"#
            )
            XCTAssertEqual(verdict.kind, kind)
        }
        for risk in TriageVerdict.Risk.allCases {
            let verdict = try decode(
                TriageVerdict.self,
                from: #"{"kind":"chore","risk":"\#(risk.rawValue)","reason":"r"}"#
            )
            XCTAssertEqual(verdict.risk, risk)
        }
    }

    func testTheSpellingsModelsActuallyUseAreTheSameAnswer() throws {
        for spelling in ["dependencyBump", "dependency_bump", "Dependency Bump", "DEPENDENCY-BUMP"] {
            let verdict = try decode(
                TriageVerdict.self,
                from: #"{"kind":"\#(spelling)","risk":"MEDIUM","reason":"Lockfile only."}"#
            )
            XCTAssertEqual(verdict.kind, .dependencyBump, spelling)
            XCTAssertEqual(verdict.risk, .medium, spelling)
        }
    }

    func testAKindNobodyDeclaredIsAnError() {
        XCTAssertThrowsError(
            try decode(
                TriageVerdict.self,
                from: #"{"kind":"security","risk":"low","reason":"r"}"#
            )
        )
        XCTAssertThrowsError(
            try decode(
                TriageVerdict.self,
                from: #"{"kind":"fix","risk":"catastrophic","reason":"r"}"#
            )
        )
        // The verdict itself is required: a classification with no kind is not a classification.
        XCTAssertThrowsError(
            try decode(TriageVerdict.self, from: #"{"risk":"low","reason":"r"}"#)
        )
    }

    func testAForgottenReasonCostsThePopoverAndNotTheChip() throws {
        let verdict = try decode(TriageVerdict.self, from: #"{"kind":"docs","risk":"low"}"#)
        XCTAssertEqual(verdict.kind, .docs)
        XCTAssertEqual(verdict.reason, "")

        let padded = try decode(
            TriageVerdict.self,
            from: #"{"kind":"docs","risk":"low","reason":"  Only the README.\n "}"#
        )
        XCTAssertEqual(padded.reason, "Only the README.")
    }

    func testAVerdictRoundTripsThroughItsOwnKeys() throws {
        let original = TriageVerdict(kind: .refactor, risk: .medium, reason: "Extracts a ranker.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(original), encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"kind":"refactor","reason":"Extracts a ranker.","risk":"medium"}"#
        )
        XCTAssertEqual(try decode(TriageVerdict.self, from: json), original)
    }
}

/// The "Why is CI red?" answer.
final class CIDiagnosisTests: XCTestCase {
    func testTheContractShapeDecodes() throws {
        let diagnosis = try decode(
            CIDiagnosis.self,
            from: """
                {"failingTest":"testGermanRowsExistForEveryKey","file":"ShepherdTests/LocalizationTests.swift",
                 "line":118,"hypothesis":"A new string has no German row yet.","confidence":"high"}
                """
        )
        XCTAssertEqual(diagnosis.failingTest, "testGermanRowsExistForEveryKey")
        XCTAssertEqual(diagnosis.file, "ShepherdTests/LocalizationTests.swift")
        XCTAssertEqual(diagnosis.line, 118)
        XCTAssertEqual(diagnosis.hypothesis, "A new string has no German row yet.")
        XCTAssertEqual(diagnosis.confidence, .high)
    }

    func testALogThatNamedNothingStillYieldsAHypothesis() throws {
        let diagnosis = try decode(
            CIDiagnosis.self,
            from: #"{"hypothesis":"The build ran out of disk space.","confidence":"low"}"#
        )
        XCTAssertNil(diagnosis.failingTest)
        XCTAssertNil(diagnosis.file)
        XCTAssertNil(diagnosis.line)
        XCTAssertEqual(diagnosis.confidence, .low)
    }

    func testEmptyLocatorsAreAsAbsentAsMissingOnes() throws {
        let diagnosis = try decode(
            CIDiagnosis.self,
            from: #"{"failingTest":"","file":"   ","line":null,"hypothesis":"Unclear.","confidence":"low"}"#
        )
        XCTAssertNil(diagnosis.failingTest)
        XCTAssertNil(diagnosis.file)
        XCTAssertNil(diagnosis.line)
    }

    func testAQuotedLineNumberIsStillALineNumber() throws {
        let quoted = try decode(
            CIDiagnosis.self,
            from: #"{"line":"88","hypothesis":"Off-by-one in the window.","confidence":"medium"}"#
        )
        XCTAssertEqual(quoted.line, 88)

        // And a line that is not a number at all is simply not shown, rather than an error: it is
        // the least load-bearing field on the card.
        let vague = try decode(
            CIDiagnosis.self,
            from: #"{"line":"somewhere near the top","hypothesis":"Unclear.","confidence":"low"}"#
        )
        XCTAssertNil(vague.line)
    }

    func testAModelThatDidNotSayHowSureItIsIsNotSure() throws {
        let diagnosis = try decode(
            CIDiagnosis.self,
            from: #"{"hypothesis":"Probably the snapshot fixture.","file":"Tests/Snapshots.swift"}"#
        )
        XCTAssertEqual(diagnosis.confidence, .low)
    }

    func testTheHypothesisIsRequiredBecauseItIsTheAnswer() {
        XCTAssertThrowsError(
            try decode(CIDiagnosis.self, from: #"{"file":"A.swift","confidence":"high"}"#)
        )
    }

    func testADiagnosisRoundTripsThroughItsOwnKeys() throws {
        let original = CIDiagnosis(
            failingTest: "testSweep",
            file: "Sources/Sync.swift",
            line: 12,
            hypothesis: "The fixture clock is fixed to a Sunday.",
            confidence: .medium
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(original), encoding: .utf8))
        XCTAssertEqual(try decode(CIDiagnosis.self, from: json), original)
        XCTAssertTrue(json.contains(#""failingTest":"testSweep""#))
        XCTAssertTrue(json.contains(#""confidence":"medium""#))
    }
}

/// The thread digest, which only ever comes from the on-device tier.
final class ThreadDigestTests: XCTestCase {
    func testTheContractShapeDecodes() throws {
        let digest = try decode(
            ThreadDigest.self,
            from: """
                {"state":"blocked","summary":"Agreed to split the migration; waiting on the schema review.",
                 "openQuestions":["Who owns the v4 migration?","Does the index need rebuilding?"]}
                """
        )
        XCTAssertEqual(digest.state, .blocked)
        XCTAssertEqual(
            digest.summary,
            "Agreed to split the migration; waiting on the schema review."
        )
        XCTAssertEqual(digest.openQuestions.count, 2)
        XCTAssertEqual(digest.openQuestions.first, "Who owns the v4 migration?")
    }

    func testEveryStateHasAWireSpelling() throws {
        for state in ThreadDigest.State.allCases {
            let digest = try decode(
                ThreadDigest.self,
                from: #"{"state":"\#(state.rawValue)","summary":"s"}"#
            )
            XCTAssertEqual(digest.state, state)
        }
        XCTAssertEqual(
            try decode(ThreadDigest.self, from: #"{"state":"Agreed","summary":"s"}"#).state,
            .agreed
        )
    }

    func testAnOmittedQuestionListMeansNoOpenQuestions() throws {
        let digest = try decode(
            ThreadDigest.self,
            from: #"{"state":"agreed","summary":"Both agreed to rename the field."}"#
        )
        XCTAssertEqual(digest.openQuestions, [])
    }

    func testBlankQuestionsAreDroppedRatherThanDrawnAsEmptyBullets() throws {
        let digest = try decode(
            ThreadDigest.self,
            from: #"{"state":"open","summary":"Still discussing.","openQuestions":["", "  ","Which cap?"]}"#
        )
        XCTAssertEqual(digest.openQuestions, ["Which cap?"])
    }

    func testADigestRoundTripsThroughItsOwnKeys() throws {
        let original = ThreadDigest(
            state: .open,
            summary: "Two options on the table.",
            openQuestions: ["Which one ships first?"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(original), encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"openQuestions":["Which one ships first?"],"state":"open","summary":"Two options on the table."}"#
        )
        XCTAssertEqual(try decode(ThreadDigest.self, from: json), original)
    }
}

/// Decodes one of the twins from the JSON text a provider would have answered with.
/// - Parameters:
///   - type: The twin.
///   - json: The provider's answer.
/// - Returns: The decoded value.
/// - Throws: Whatever `JSONDecoder` throws.
private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
