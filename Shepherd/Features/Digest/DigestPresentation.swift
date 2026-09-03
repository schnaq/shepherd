import ShepherdCore
import SwiftUI

/// The words and the colours the morning digest is told in.
///
/// One place, used by both surfaces: the macOS notification (a title and a single body line) and
/// the inbox card (one row per section). A digest whose banner and card disagreed about the numbers
/// would be worse than no digest at all, and the numbers are the only thing either of them says.
///
/// Nothing here decides *what* is in the digest — that is ``ShepherdCore/DigestReport``, which is
/// pure and tested. This is the presentation layer and holds no judgement.
enum DigestPresentation {
    /// The notification title and the card's caption.
    ///
    /// Fixed rather than time-of-day aware on purpose: the digest *is* the morning digest, and a
    /// delivery that lands at eleven because the Mac was asleep is still this morning's.
    static var greeting: String { String(localized: "Good morning") }

    /// The one body line of the notification: every section, shortest form, separated by a middot.
    /// - Parameter report: What the digest found.
    static func summary(for report: DigestReport) -> String {
        report.sections.map(line(for:)).joined(separator: " · ")
    }

    /// One section as a sentence fragment — "4 new review requests".
    /// - Parameter section: The section to describe.
    static func line(for section: DigestReport.Section) -> String {
        let count = section.count
        switch section.kind {
        case .newReviewRequests:
            return count == 1
                ? String(localized: "1 new review request")
                : String(localized: "\(count) new review requests")
        case .issuesAssignedToYou:
            return count == 1
                ? String(localized: "1 issue assigned to you")
                : String(localized: "\(count) issues assigned to you")
        case .greenAgentPullRequests:
            return count == 1
                ? String(localized: "1 green agent pull request ready")
                : String(localized: "\(count) green agent pull requests ready")
        case .agentPullRequestsThatClosedAnIssue:
            return count == 1
                ? String(localized: "1 issue closed by an agent pull request")
                : String(localized: "\(count) issues closed by agent pull requests")
        case .ownPullRequestsNeedingAttention:
            return count == 1
                ? String(localized: "1 of your pull requests needs attention")
                : String(localized: "\(count) of your pull requests need attention")
        case .parkedReviews:
            return count == 1
                ? String(localized: "1 queued review was not sent")
                : String(localized: "\(count) queued reviews were not sent")
        case .failedWrites:
            return count == 1
                ? String(localized: "1 queued write was given up on")
                : String(localized: "\(count) queued writes were given up on")
        }
    }

    /// What the section's button does, spelled out for the tooltip.
    /// - Parameter kind: The section kind.
    static func help(for kind: DigestSectionKind) -> String {
        switch kind {
        case .newReviewRequests:
            return String(localized: "Show the pull requests waiting for your review")
        case .issuesAssignedToYou:
            return String(localized: "Show the issues section of the inbox")
        case .greenAgentPullRequests:
            return String(localized: "Select the green agent pull requests, ready for bulk triage")
        case .agentPullRequestsThatClosedAnIssue:
            return String(localized: "Show the issues section, where the closed ones still are")
        case .ownPullRequestsNeedingAttention:
            return String(localized: "Show your own pull requests")
        case .parkedReviews:
            return String(localized: "Open Settings → Sync, where the parked reviews are listed")
        case .failedWrites:
            return String(localized: "Open Settings → Sync, where each one can be retried or discarded")
        }
    }

    /// The SF Symbol in front of a section's line.
    /// - Parameter kind: The section kind.
    static func systemImage(for kind: DigestSectionKind) -> String {
        switch kind {
        case .newReviewRequests: return "tray.and.arrow.down"
        case .issuesAssignedToYou: return "smallcircle.circle"
        case .greenAgentPullRequests: return "checkmark.circle"
        case .agentPullRequestsThatClosedAnIssue: return "checkmark.circle.badge.checkmark"
        case .ownPullRequestsNeedingAttention: return "exclamationmark.triangle"
        case .parkedReviews: return "tray.full"
        case .failedWrites: return "xmark.octagon"
        }
    }

    /// The section's tint. Semantic tokens only, like every colour in the app.
    /// - Parameter kind: The section kind.
    static func tint(for kind: DigestSectionKind) -> Color {
        switch kind {
        case .newReviewRequests: return Theme.accentText
        case .issuesAssignedToYou: return Theme.accentText
        case .greenAgentPullRequests: return Theme.success
        case .agentPullRequestsThatClosedAnIssue: return Theme.success
        case .ownPullRequestsNeedingAttention: return Theme.failure
        case .parkedReviews: return Theme.pending
        case .failedWrites: return Theme.failure
        }
    }

    /// The card's second caption: which span the digest covers.
    /// - Parameters:
    ///   - report: The digest.
    ///   - now: The clock, for the relative wording.
    static func windowDescription(for report: DigestReport, now: Date = Date()) -> String {
        String(localized: "since \(RelativeDate.long(report.windowStart, relativeTo: now))")
    }
}
