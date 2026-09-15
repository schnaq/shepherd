import XCTest

@testable import Shepherd

/// The one rule ``DiffRenderer`` carries: which of the two views draws a diff, given what the
/// setting says and whether a screen reader is listening.
///
/// Worth pinning because two views ask the question — the review screen, to choose a renderer,
/// and the file header, to decide whether a side-by-side/inline choice can be honoured at all —
/// and two copies of the same `switch` are two things that can drift into offering a layout the
/// renderer on screen cannot draw.
final class DiffRendererTests: XCTestCase {
    func testAnExplicitChoiceIgnoresVoiceOverInBothDirections() {
        XCTAssertTrue(DiffRenderer.native.usesNativeList(voiceOverEnabled: false))
        XCTAssertTrue(DiffRenderer.native.usesNativeList(voiceOverEnabled: true))
        XCTAssertFalse(DiffRenderer.web.usesNativeList(voiceOverEnabled: false))
        // The case the three-state setting exists for: a screen-reader user who prefers Monaco
        // and said so is not overruled.
        XCTAssertFalse(DiffRenderer.web.usesNativeList(voiceOverEnabled: true))
    }

    func testAutomaticFollowsVoiceOver() {
        XCTAssertTrue(DiffRenderer.automatic.usesNativeList(voiceOverEnabled: true))
        XCTAssertFalse(DiffRenderer.automatic.usesNativeList(voiceOverEnabled: false))
    }
}
