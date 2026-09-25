import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// What a write-path toast says once it is worded by what the drain *did* with the row rather
/// than by what the user asked for (ADR 0006).
///
/// The bug these are about was neither a crash nor a wrong number: `submitReview` said
/// "Approved schnaq/review#182." the moment the row reached the outbox, and the drain could then
/// park that row as a conflict — so the confirmation was followed a second later by an alert
/// saying the review was never sent. A sentence is the whole feature here, which is why it is
/// asserted like one.
///
/// Expectations go through `String(localized:)` rather than through English literals, the way
/// `SpokenRowTests` states them: the lookup table is chosen from the runner's preferred
/// localisations, so a test spelled in English would fail on a German Mac for no reason
/// (`LocalizationTests` explains that at length). What is asserted is therefore which *sentence*
/// an outcome picks, and that two outcomes never pick the same one.
///
/// Nothing here needs a `SignedInSession`, a Keychain or a token — that is why the wording lives
/// in a `static` function: the outcome comes from the queue, and the sentence comes from the
/// outcome, so both halves can be checked without a session at all.
@MainActor
final class WriteOutcomeToastTests: XCTestCase {
    private let slug = "schnaq/review#182"

    private var everyWrite: [PullRequestActions.WriteKind] {
        [
            .review(.approve),
            .review(.requestChanges),
            .review(.comment),
            .reply,
            .thread(resolved: true),
            .thread(resolved: false),
            .merge,
            .readyForReview,
            .comment,
            .close(withComment: true),
            .close(withComment: false),
            .updateBranch,
        ]
    }

    // MARK: - Sent, parked, refused

    func testASentReviewSaysItHappened() {
        let toast = PullRequestActions.announcement(for: .sent, of: .review(.approve), slug: slug)
        XCTAssertEqual(toast?.message, String(localized: "Approved \(slug)."))
        XCTAssertEqual(toast?.kind, .success)
    }

    func testAParkedReviewSaysItWasHeldBackInsteadOfApproved() {
        // The sentence that used to be "Approved …". The alert it hands over to is the one
        // carrying the re-review button, so this toast points at that alert rather than
        // replacing it.
        let parked = PullRequestActions.announcement(
            for: .parked(reason: "Head moved from head-1 to head-2"),
            of: .review(.approve),
            slug: slug
        )
        XCTAssertEqual(
            parked?.message,
            String(localized: "Review held back — \(slug) changed since you started. See the alert.")
        )
        XCTAssertEqual(parked?.kind, .warning, "nothing is lost, so this is not a failure")
        XCTAssertNotEqual(
            parked?.message,
            PullRequestActions.announcement(for: .sent, of: .review(.approve), slug: slug)?.message,
            "a review that was never sent must not read like one that was"
        )
    }

    func testARefusedWriteCarriesWhatItWasRefusedWith() {
        let toast = PullRequestActions.announcement(
            for: .failed(reason: "422 Unprocessable Entity"),
            of: .review(.comment),
            slug: slug
        )
        XCTAssertEqual(
            toast?.message,
            String(localized: "Could not send the review for \(slug)") + ": 422 Unprocessable Entity"
        )
        XCTAssertEqual(toast?.kind, .failure)
    }

    func testARefusedWriteWithoutAReasonStillSaysWhatFailed() {
        let toast = PullRequestActions.announcement(for: .failed(reason: nil), of: .merge, slug: slug)
        XCTAssertEqual(toast?.message, String(localized: "Could not merge \(slug)"))
        XCTAssertEqual(toast?.kind, .failure)
    }

    // MARK: - The conversation writes

    func testACloseSaysWhetherItCarriedAComment() {
        // The two are different acts and the toast is the only place the user is told which one
        // went out: "Closed …" after typing three sentences would read as though they were lost.
        XCTAssertEqual(
            PullRequestActions.announcement(
                for: .sent,
                of: .close(withComment: true),
                slug: slug
            )?.message,
            String(localized: "Commented and closed \(slug).")
        )
        XCTAssertEqual(
            PullRequestActions.announcement(
                for: .sent,
                of: .close(withComment: false),
                slug: slug
            )?.message,
            String(localized: "Closed \(slug).")
        )
    }

    func testACommentIsNotAnnouncedAsAReview() {
        // A conversation comment and a `COMMENT` review are different things on GitHub, and a
        // user who posted the first must not be told the second happened.
        let comment = PullRequestActions.announcement(for: .sent, of: .comment, slug: slug)
        XCTAssertEqual(comment?.message, String(localized: "Comment posted on \(slug)."))
        XCTAssertNotEqual(
            comment?.message,
            PullRequestActions.announcement(
                for: .sent,
                of: .review(.comment),
                slug: slug
            )?.message
        )
    }

    // MARK: - Queued is not done

    func testAWriteStillInTheQueueSaysQueuedRatherThanDone() {
        // The offline case, and the one outcome that is no problem: the row is on disk and the
        // engine keeps trying. It still may not claim the verdict landed.
        let queued = PullRequestActions.announcement(for: .queued, of: .review(.approve), slug: slug)
        XCTAssertEqual(queued?.message, String(localized: "Approval queued for \(slug)."))
        XCTAssertEqual(queued?.kind, .success)
    }

    func testEveryWriteTellsQueuedApartFromSent() {
        for write in everyWrite {
            guard let queued = PullRequestActions.announcement(
                for: .queued,
                of: write,
                slug: slug
            ) else {
                XCTFail("\(write) says nothing about being queued")
                continue
            }
            // Only a merge is silent when it lands, and it is silent here on purpose.
            guard let sent = PullRequestActions.announcement(
                for: .sent,
                of: write,
                slug: slug
            ) else {
                continue
            }
            XCTAssertNotEqual(
                sent.message,
                queued.message,
                "\(write) says the same thing whether or not it landed"
            )
        }
    }

    // MARK: - The merge is confirmed from the other end

    func testAMergeSaysNothingAtTheButtonWhenItLanded() {
        // A landed merge is announced once, from `mutationSent` in `AppEnvironment`, because that
        // is also the only place a merge sent by a *later* drain can be announced from. Saying it
        // here as well would put two toasts on screen for one merge.
        XCTAssertNil(PullRequestActions.announcement(for: .sent, of: .merge, slug: slug))
        XCTAssertEqual(
            PullRequestActions.announcement(for: .queued, of: .merge, slug: slug)?.message,
            String(localized: "Merge queued for \(slug).")
        )
    }

    func testAParkedMergeSaysSoRatherThanStayingSilent() {
        // The other half of the case above: a write that says nothing when it lands must still
        // say something when it never will.
        let toast = PullRequestActions.announcement(
            for: .parked(reason: "The pull request moved on before the merge could run"),
            of: .merge,
            slug: slug
        )
        XCTAssertEqual(
            toast?.message,
            String(localized: "Merge held back — \(slug) changed since you started. See the alert.")
        )
        XCTAssertEqual(toast?.kind, .warning)
    }

    // MARK: - Nothing is left without a sentence

    func testEveryWriteHasSomethingToSayAboutBeingParkedOrRefused() {
        let outcomes: [OutboxWriteOutcome] = [
            .parked(reason: "Head moved from head-1 to head-2"),
            .failed(reason: "422 Unprocessable Entity"),
        ]
        for write in everyWrite {
            for outcome in outcomes {
                let toast = PullRequestActions.announcement(for: outcome, of: write, slug: slug)
                XCTAssertNotNil(toast, "\(write) is silent about \(outcome)")
                XCTAssertFalse(toast?.message.isEmpty ?? true)
                XCTAssertNotEqual(
                    toast?.kind,
                    .success,
                    "\(write) tints \(outcome) as if it had worked"
                )
            }
        }
    }
}
