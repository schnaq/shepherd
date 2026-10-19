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

    /// A commit SHA as GitHub abbreviates it — ``ShepherdCore/CommitInfo/shortOid`` for the ones an
    /// event carries as a plain string.
    private static func short(_ oid: String) -> String {
        String(oid.prefix(7))
    }
}

// MARK: - Shared with the iPhone

/// The sentences the Mac's stream views and the phone's say in the same words, pulled out of both
/// so a catalog key and its German are written once (ADR 0044).
extension ConversationEventText {
    /// "Hidden — off-topic", in GitHub's word for why; "Hidden comment" for a reason this build
    /// does not know, or for none.
    /// - Parameter reason: ``ShepherdCore/ConversationComment/minimizedReason``.
    /// - Returns: The line.
    static func hiddenSentence(reason: String?) -> String {
        let why: String
        switch reason {
        case "off-topic": why = String(localized: "off-topic")
        case "outdated": why = String(localized: "outdated")
        case "resolved": why = String(localized: "resolved")
        case "duplicate": why = String(localized: "duplicate")
        case "spam": why = String(localized: "spam")
        case "abuse": why = String(localized: "abuse")
        default: return String(localized: "Hidden comment")
        }
        return String(localized: "Hidden — \(why)")
    }

    /// What a delete asks before anything is written: whose comment, from when, and that it
    /// cannot be undone — GitHub keeps no copy to restore.
    static func deleteQuestion(author: ShepherdCore.Actor, date: Date, now: Date = Date()) -> String {
        let name = author.bestName
        let when = RelativeDate.long(date, relativeTo: now)
        return String(localized: "\(name) wrote this comment \(when). It is deleted on GitHub, and that cannot be undone.")
    }

    /// What pressing a capsule does — its tooltip, and what a screen reader says after its label.
    static func reactionAction(for group: ReactionGroup) -> String {
        group.viewerHasReacted
            ? String(localized: "Remove your reaction")
            : String(localized: "Add your reaction")
    }

    /// One capsule in words — "Thumbs up. 2 reactions. including yours." — because the fill is
    /// what marks your own, and colour is never the only carrier.
    static func reactionSpokenLabel(for group: ReactionGroup) -> String {
        let count = group.count
        return SpokenRow.sentence([
            reactionName(of: group.content),
            String(localized: "\(count) reactions"),
            group.viewerHasReacted ? String(localized: "including yours") : nil,
        ])
    }

    /// GitHub's name for a reaction. The emoji alone would be read out by its Unicode name.
    static func reactionName(of content: ReactionContent) -> String {
        switch content {
        case .thumbsUp: return String(localized: "Thumbs up")
        case .thumbsDown: return String(localized: "Thumbs down")
        case .laugh: return String(localized: "Laugh")
        case .hooray: return String(localized: "Hooray")
        case .confused: return String(localized: "Confused")
        case .heart: return String(localized: "Heart")
        case .rocket: return String(localized: "Rocket")
        case .eyes: return String(localized: "Eyes")
        }
    }

    /// The verdict as the review's row says it, with its symbol and colour. The words carry it;
    /// the colour only repeats them.
    /// - Parameter state: The review's state.
    /// - Returns: The sentence after the name, an SF Symbol and its tint.
    static func verdict(_ state: ConversationReview.State) -> (sentence: String, symbol: String, tint: Color) {
        switch state {
        case .approved:
            return (String(localized: "approved these changes"), "checkmark.circle.fill", Theme.success)
        case .changesRequested:
            return (String(localized: "requested changes"), "exclamationmark.circle.fill", Theme.failure)
        case .commented:
            return (String(localized: "reviewed"), "eye", Theme.accentText)
        case .dismissed:
            return (String(localized: "reviewed — dismissed"), "eye.slash", Theme.textMuted)
        case .pending:
            return (String(localized: "has a pending review"), "clock", Theme.pending)
        }
    }

    /// "Claude Code added 3 commits" when one author pushed them all, "3 commits" otherwise.
    /// - Parameter commits: The group.
    /// - Returns: The heading.
    static func commitsTitle(for commits: [CommitInfo]) -> String {
        let count = commits.count
        if Set(commits.map(\.author?.login)).count == 1, let name = commits.first?.author?.bestName {
            return String(localized: "\(name) added \(count) commits")
        }
        return String(localized: "\(count) commits")
    }
}
