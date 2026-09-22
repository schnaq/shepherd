import Foundation
import ShepherdCore

/// How one claim of the claims card is looked at more closely (ADR 0026's 2026-09-22 amendment,
/// ADR 0038 item 2).
///
/// The sibling of ``ClaimExtracting``, and bound by the same two rules for the same reason — the
/// claim is a sentence a colleague wrote:
///
/// - **On-device only, as unreachability.** The one production conformer is
///   ``OnDeviceClaimChecker``; nothing here takes an ``IntelligenceRouter``, a base URL or a key,
///   and ``IntelligenceProvider`` has no request for it. A diff too large for the window is a
///   sentence on the card, not a cloud rung.
/// - **Attended, one line at a time.** The reviewer's click on *Look closer* is the only caller;
///   no sweep, expansion or scroll starts a session.
///
/// What comes back is ``ShepherdCore/ClaimCheck``: places in the diff, each one found by Shepherd
/// in the patch before it is returned, and the trace of every read. Never a verdict — the line's
/// ✓ / ✗ / ? stays ``EvidenceChecker``'s.
protocol ClaimChecking: Sendable {
    /// Whether this Mac can run the check, and why not when it cannot. Asked once per screen.
    func availability() async -> OnDeviceAvailability

    /// Reads the diff for one claim.
    /// - Parameters:
    ///   - line: The claim and Shepherd's own facts about it.
    ///   - detail: The pull request, with its patches and checks.
    /// - Returns: The located notes and the trace. An empty list is an answer: the model read and
    ///   pointed at nothing Shepherd could find.
    /// - Throws: ``IntelligenceError`` when the model is unavailable, declined, or the claim and
    ///   its context did not fit the window.
    func check(
        _ line: ClaimsEvidenceReport.Line,
        in detail: PullRequestDetail
    ) async throws -> ClaimCheck
}
