import Foundation
import XCTest

@testable import Shepherd

/// The one thing every write button now asks before it draws itself, and the one thing that
/// stops a second click.
///
/// Live testing found every write in the app clickable and silent between the click and the
/// toast — a double click on *Approve* queued two reviews — so ``ActionActivity`` was put at the
/// funnel and the buttons were made to read it. The three properties below are the whole of the
/// contract the buttons lean on: the key is running while the body runs and not afterwards, a
/// second call on the same key does nothing at all, and two different keys do not see each
/// other.
///
/// Asserted directly rather than through ``PullRequestActions``: that needs a
/// `SignedInSession`, which wants the Keychain and the real database file, and the decision this
/// class makes is the whole of what the wrapper contributes.
@MainActor
final class ActionActivityTests: XCTestCase {
    /// The key is running for exactly as long as the body, and is released afterwards.
    func testRunMarksTheKeyRunningForTheDurationOfTheBody() async {
        let activity = ActionActivity()
        XCTAssertFalse(activity.isRunning("PR_1", .review))

        let sawItselfRunning = await activity.run("PR_1", .review) {
            activity.isRunning("PR_1", .review)
        }

        XCTAssertEqual(sawItselfRunning, true)
        XCTAssertFalse(activity.isRunning("PR_1", .review))
        XCTAssertTrue(activity.running.isEmpty)
    }

    /// A second call on the same key returns `nil` and never reaches its body — which is what
    /// makes a double click cost one write instead of two.
    func testSecondRunOnTheSameKeyIsRefusedAndItsBodyNeverRuns() async {
        let activity = ActionActivity()
        var innerDidRun = false

        let outer: Bool? = await activity.run("PR_1", .review) {
            let inner: Bool? = await activity.run("PR_1", .review) {
                innerDidRun = true
                return true
            }
            XCTAssertNil(inner)
            return true
        }

        XCTAssertEqual(outer, true)
        XCTAssertFalse(innerDidRun)
        // And the refused call did not take the running key with it on its way out.
        XCTAssertFalse(activity.isRunning("PR_1", .review))
    }

    /// A panel of sibling buttons asks about several kinds at once: each spins for its own, and
    /// all of them go quiet while any of them runs.
    func testIsRunningAnyAnswersForASetOfKindsOnOneTarget() async {
        let activity = ActionActivity()
        let issueKinds: [ActionActivity.Kind] = [
            .issueComment, .issueAssign, .issueLabel, .issueState,
        ]
        XCTAssertFalse(activity.isRunningAny("I_1", issueKinds))

        await activity.run("I_1", .issueLabel) {
            // Only the button that started it spins…
            XCTAssertTrue(activity.isRunning("I_1", .issueLabel))
            XCTAssertFalse(activity.isRunning("I_1", .issueState))
            // …and every button on the row is nonetheless out of action.
            XCTAssertTrue(activity.isRunningAny("I_1", issueKinds))
            // A different issue is untouched by all of it.
            XCTAssertFalse(activity.isRunningAny("I_2", issueKinds))
        }

        XCTAssertFalse(activity.isRunningAny("I_1", issueKinds))
    }

    /// Two keys are independent — a different pull request, and a different verb on the same one.
    func testDifferentKeysDoNotBlockEachOther() async {
        let activity = ActionActivity()
        var otherPullRequestDidRun = false
        var otherKindDidRun = false

        await activity.run("PR_1", .review) {
            XCTAssertFalse(activity.isRunning("PR_2", .review))
            XCTAssertFalse(activity.isRunning("PR_1", .merge))

            let otherPullRequest: Bool? = await activity.run("PR_2", .review) {
                otherPullRequestDidRun = true
                return true
            }
            let otherKind: Bool? = await activity.run("PR_1", .merge) {
                otherKindDidRun = true
                return true
            }

            XCTAssertEqual(otherPullRequest, true)
            XCTAssertEqual(otherKind, true)
        }

        XCTAssertTrue(otherPullRequestDidRun)
        XCTAssertTrue(otherKindDidRun)
        XCTAssertTrue(activity.running.isEmpty)
    }
}
