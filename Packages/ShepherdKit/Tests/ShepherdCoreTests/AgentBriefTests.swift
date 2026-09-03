import Foundation
import XCTest

@testable import ShepherdCore

/// The delegation brief's twin (plan §3.E): what a model's answer decodes to, and what it renders
/// as in the task field.
///
/// Both halves run on Linux, which is the point of the twin existing at all (ADR 0007): the shape
/// a tier is asked for and the Markdown a reviewer ends up editing are pure values, so they are
/// pinned here rather than read off a screenshot on a Mac.
final class AgentBriefTests: XCTestCase {
    // MARK: - Decoding

    func testTheContractShapeDecodes() throws {
        let brief = try decodeBrief(
            #"""
            {"goal":"Fix the off-by-one in the retry bound.",
             "constraints":["Do not touch the upload API.","Keep the change under 20 lines."],
             "acceptance":["UploadTests passes.","The retry stops after three attempts."]}
            """#
        )
        XCTAssertEqual(brief.goal, "Fix the off-by-one in the retry bound.")
        XCTAssertEqual(
            brief.constraints,
            ["Do not touch the upload API.", "Keep the change under 20 lines."]
        )
        XCTAssertEqual(brief.acceptance, ["UploadTests passes.", "The retry stops after three attempts."])
    }

    func testAMechanicalFixNeedsNoListsAndOmittedKeysAreNotAnError() throws {
        let brief = try decodeBrief(#"{"goal":"Bump the lockfile."}"#)
        XCTAssertEqual(brief.goal, "Bump the lockfile.")
        XCTAssertEqual(brief.constraints, [])
        XCTAssertEqual(brief.acceptance, [])
    }

    func testBlankEntriesAndPaddingAreDroppedRatherThanRenderedAsEmptyBullets() throws {
        let brief = try decodeBrief(
            #"{"goal":"  Fix the retry bound.\n","constraints":["","  ","Nothing else."],"acceptance":[" "]}"#
        )
        XCTAssertEqual(brief.goal, "Fix the retry bound.")
        XCTAssertEqual(brief.constraints, ["Nothing else."])
        XCTAssertEqual(brief.acceptance, [])
    }

    func testABriefWithoutAGoalIsNotABrief() {
        XCTAssertThrowsError(
            try decodeBrief(#"{"constraints":["Do not push."],"acceptance":["Tests pass."]}"#)
        )
    }

    func testABriefRoundTripsThroughItsOwnKeys() throws {
        let original = AgentBrief(
            goal: "Fix the off-by-one.",
            constraints: ["Do not reformat."],
            acceptance: ["UploadTests passes."]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(String(data: try encoder.encode(original), encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"acceptance":["UploadTests passes."],"constraints":["Do not reformat."],"goal":"Fix the off-by-one."}"#
        )
        XCTAssertEqual(try decodeBrief(json), original)
    }

    // MARK: - Rendering

    func testTheMarkdownIsTheThreeSectionsInOrderWithOneBulletPerLine() {
        let brief = AgentBrief(
            goal: "Fix the off-by-one in the retry bound.",
            constraints: ["Do not touch the upload API.", "No reformatting."],
            acceptance: ["UploadTests passes."]
        )
        XCTAssertEqual(
            brief.markdown,
            """
            ## Goal

            Fix the off-by-one in the retry bound.

            ## Constraints

            - Do not touch the upload API.
            - No reformatting.

            ## Acceptance

            - UploadTests passes.
            """
        )
    }

    func testAnEmptySectionIsLeftOutRatherThanRenderedAsABareHeading() {
        let brief = AgentBrief(goal: "Bump the lockfile.")
        XCTAssertEqual(brief.markdown, "## Goal\n\nBump the lockfile.")
        XCTAssertFalse(brief.markdown.contains(AgentBrief.constraintsHeading))
        XCTAssertFalse(brief.markdown.contains(AgentBrief.acceptanceHeading))

        // A brief that decoded to nothing at all renders as nothing at all, rather than as three
        // headings a reviewer would have to delete before they could type.
        XCTAssertEqual(AgentBrief(goal: "").markdown, "")
    }

    func testTheHeadingsTheRendererWritesAreTheOnesThePromptCanName() {
        // The prompt asks for these exact strings; a renderer that spelled them differently would
        // produce a brief with two "Goal" sections in it.
        XCTAssertEqual(AgentBrief.goalHeading, "## Goal")
        XCTAssertEqual(AgentBrief.constraintsHeading, "## Constraints")
        XCTAssertEqual(AgentBrief.acceptanceHeading, "## Acceptance")
        let markdown = AgentBrief(goal: "g", constraints: ["c"], acceptance: ["a"]).markdown
        for heading in [
            AgentBrief.goalHeading, AgentBrief.constraintsHeading, AgentBrief.acceptanceHeading,
        ] {
            XCTAssertTrue(markdown.contains(heading), heading)
        }
    }
}

/// Decodes a brief from the JSON text a provider would have answered with.
/// - Parameter json: The provider's answer.
/// - Returns: The decoded brief.
/// - Throws: Whatever `JSONDecoder` throws.
private func decodeBrief(_ json: String) throws -> AgentBrief {
    try JSONDecoder().decode(AgentBrief.self, from: Data(json.utf8))
}
