import Foundation
import GitHubKit
import ShepherdCore

/// How a description's screenshots are read (ADR 0038 item 4, ADR 0007's 2026-09-22 amendment).
///
/// The sibling of ``ClaimChecking`` and ``ThreadDigesting``, and bound by the same two rules for
/// the same reason — a screenshot in a description is a colleague's content, and it can show
/// anything that was on their screen:
///
/// - **On-device only, as unreachability.** The one production conformer is
///   ``OnDeviceScreenshotReader``; nothing here takes an ``IntelligenceRouter``, a base URL or a
///   key, and ``IntelligenceProvider`` has no request for it. The cloud tiers keep receiving the
///   description as text and nothing else.
/// - **Attended.** The reviewer's click on *Read screenshots* is the only caller. Selecting a row
///   — which does start the text summary — downloads nothing.
protocol DescriptionScreenshotReading: Sendable {
    /// Whether this Mac can read images, and why not when it cannot. Asked once per panel.
    func availability() async -> OnDeviceAvailability

    /// Reads the screenshots.
    /// - Parameters:
    ///   - request: The title and the attachments being read, with the description's total.
    ///   - images: The downloaded bytes, one per attachment in `request.images`, in order.
    /// - Returns: What the model said the screenshots show, and how many it read.
    /// - Throws: ``IntelligenceError`` when the model is unavailable, declined, or no image could
    ///   be decoded.
    func read(_ request: ScreenshotReadingRequest, images: [Data]) async throws -> ScreenshotReading
}

/// Where the screenshots come from: GitHub's rendering of the description, and the signed links
/// in it (ADR 0038 item 4).
protocol DescriptionImageFetching: Sendable {
    /// The description as GitHub renders it, with every upload as a short-lived signed link.
    func pullRequestBodyHTML(repo: RepoRef, number: Int) async throws -> String
    /// One screenshot's bytes, fetched without the token.
    func descriptionImage(at url: URL) async throws -> Data
}

extension GitHubClient: DescriptionImageFetching {}
