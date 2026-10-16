import ShepherdCore
import SwiftUI

/// What one event of the conversation tab says, and the symbol and colour it is drawn with
/// (ADR 0043).
///
/// ShepherdKit carries an event as values and no words, so every sentence is built here, through
/// the catalog. Pure and `static`, so `ConversationEventTextTests` reads each one without a window.
enum ConversationEventText {
    /// GitHub's sentence for the event, naming who caused it.
    /// - Parameter item: The event.
    /// - Returns: The sentence, without a full stop — the row draws the time beside it.
    static func sentence(for item: ConversationEventItem) -> String {
        let actor = item.actor?.bestName ?? String(localized: "Someone")
        switch item.event {
        case .labeled(let name, _):
            return String(localized: "\(actor) added the label \(name)")
        case .unlabeled(let name, _):
            return String(localized: "\(actor) removed the label \(name)")
        case .assigned(let login) where login == item.actor?.login:
            return String(localized: "\(actor) self-assigned this")
        case .assigned(let login):
            return String(localized: "\(actor) assigned \(login)")
        case .unassigned(let login):
            return String(localized: "\(actor) unassigned \(login)")
        case .reviewRequested(let reviewer):
            return String(localized: "\(actor) requested a review from \(reviewer)")
        case .reviewRequestRemoved(let reviewer):
            return String(localized: "\(actor) removed the review request for \(reviewer)")
        case .renamed(let from, let to):
            return String(localized: "\(actor) changed the title from \"\(from)\" to \"\(to)\"")
        case .readyForReview:
            return String(localized: "\(actor) marked this pull request as ready for review")
        case .convertedToDraft:
            return String(localized: "\(actor) converted this pull request to a draft")
        case .merged(let commitOid?, let into?):
            let shortOid = short(commitOid)
            return String(localized: "\(actor) merged commit \(shortOid) into \(into)")
        case .merged:
            return String(localized: "\(actor) merged this pull request")
        case .closed:
            return String(localized: "\(actor) closed this pull request")
        case .reopened:
            return String(localized: "\(actor) reopened this pull request")
        case .headRefDeleted(let branch?):
            return String(localized: "\(actor) deleted the branch \(branch)")
        case .headRefDeleted:
            return String(localized: "\(actor) deleted the head branch")
        case .headRefRestored:
            return String(localized: "\(actor) restored the head branch")
        case .baseRefChanged(let from?, let to?):
            return String(localized: "\(actor) changed the base branch from \(from) to \(to)")
        case .baseRefChanged:
            return String(localized: "\(actor) changed the base branch")
        case .forcePushed(let fromOid?, let toOid?):
            let before = short(fromOid)
            let after = short(toOid)
            return String(localized: "\(actor) force-pushed from \(before) to \(after)")
        case .forcePushed:
            return String(localized: "\(actor) force-pushed the branch")
        case .crossReferenced(let reference, _):
            // A plain string, the way a slug is built: an `Int` interpolated into a localized
            // string is formatted by the locale, and a German Mac would read `#1.024`.
            let slug = reference.repo.fullName + "#" + String(reference.number)
            let title = reference.title
            return String(localized: "\(actor) mentioned this in \(slug) \(title)")
        case .reviewDismissed(let message):
            let dismissed = String(localized: "\(actor) dismissed a review")
            // The dismisser's own words go after the sentence rather than into it: they are
            // somebody's prose in whatever language they wrote it, not a catalog value.
            let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return reason.isEmpty ? dismissed : "\(dismissed): \(reason)"
        case .autoMergeEnabled:
            return String(localized: "\(actor) enabled auto-merge")
        case .autoMergeDisabled:
            return String(localized: "\(actor) disabled auto-merge")
        }
    }

    /// The SF Symbol in front of the sentence.
    /// - Parameter event: The event.
    /// - Returns: The symbol's name.
    static func symbol(for event: ConversationEvent) -> String {
        switch event {
        case .labeled, .unlabeled: return "tag"
        case .assigned, .unassigned: return "person"
        case .reviewRequested, .reviewRequestRemoved, .readyForReview: return "eye"
        case .renamed: return "pencil"
        case .convertedToDraft: return "pencil.circle"
        case .merged, .autoMergeEnabled, .autoMergeDisabled: return "arrow.triangle.merge"
        case .closed, .reviewDismissed: return "xmark.circle"
        case .reopened: return "arrow.clockwise.circle"
        case .headRefDeleted, .headRefRestored: return "arrow.branch"
        case .baseRefChanged: return "arrow.left.arrow.right"
        case .forcePushed: return "arrow.up.circle"
        case .crossReferenced: return "link"
        }
    }

    /// The symbol's colour: the three events that change what the pull request *is* stand out,
    /// everything else stays quiet. The sentence says the same, so colour is never the only
    /// carrier.
    /// - Parameter event: The event.
    /// - Returns: The colour.
    static func tint(for event: ConversationEvent) -> Color {
        switch event {
        case .merged, .reopened: return Theme.success
        case .closed: return Theme.failure
        default: return Theme.textMuted
        }
    }

    /// A commit SHA as GitHub abbreviates it.
    private static func short(_ oid: String) -> String {
        String(oid.prefix(7))
    }
}
