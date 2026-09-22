import ShepherdCore
import SwiftUI

/// What the outbox is doing for one pull request, as the one chip a row or the review header shows.
///
/// Before this, a merge that was on its way looked exactly like a pull request nobody had touched
/// until the next sweep removed it, and a write that failed was visible only in Settings → Sync.
/// The row now says it, from the two sources that already exist and nothing invented:
///
/// - ``ActionActivity`` for the second in which the click is being written and sent — *Merging…*;
/// - the outbox rows themselves (``InboxModel/outboxItems``, ADR 0006) for everything that
///   outlives that second — queued, parked, failed;
/// - the drain's ``ShepherdSync/SyncEvent/mutationSent(_:)`` for *Merged*, which is shown only
///   once GitHub has answered, never on the click. Until then the row says the merge is on its
///   way and nothing more.
///
/// One state, in a fixed order of what needs the reviewer most: a failure is something to act on,
/// a parked write is something to look at, a merge in flight is something to wait for.
enum RowWriteState: Equatable, Sendable {
    /// Writes Shepherd gave up on.
    case failed(Int)
    /// Writes held because the pull request moved on underneath them.
    case parked(Int)
    /// The merge click is being written and sent right now.
    case merging
    /// GitHub confirmed the merge; the row leaves the inbox with the next sweep.
    case merged
    /// A merge is queued and will be sent when the drain next runs.
    case mergeQueued
    /// Some other write is being sent, or is waiting to be.
    case queued(Int)

    /// The state for one pull request.
    /// - Parameters:
    ///   - items: Every outbox row, as the database observation delivers them.
    ///   - id: The pull request's node id.
    ///   - isMerging: Whether a merge click for it is running (``ActionActivity``).
    ///   - wasMerged: Whether the drain reported its merge as sent.
    /// - Returns: The state, or `nil` when the outbox holds nothing for it.
    static func make(
        items: [OutboxItem],
        for id: String,
        isMerging: Bool,
        wasMerged: Bool
    ) -> RowWriteState? {
        let mine = items.filter { $0.prID == id }
        let failed = mine.filter { $0.state == .failed }.count
        if failed > 0 { return .failed(failed) }
        let parked = mine.filter { $0.state == .conflicted }.count
        if parked > 0 { return .parked(parked) }
        if isMerging { return .merging }
        if wasMerged { return .merged }
        let waiting = mine.filter { $0.state == .pending || $0.state == .sending }
        if waiting.contains(where: { if case .merge = $0.action { true } else { false } }) {
            return .mergeQueued
        }
        return waiting.isEmpty ? nil : .queued(waiting.count)
    }

    /// The chip's words.
    var text: String {
        switch self {
        case .failed(let count):
            return count == 1
                ? String(localized: "Not sent")
                : String(localized: "\(count) not sent")
        case .parked(let count):
            return count == 1
                ? String(localized: "Parked")
                : String(localized: "\(count) parked")
        case .merging:
            return String(localized: "Merging…")
        case .merged:
            return String(localized: "Merged")
        case .mergeQueued:
            return String(localized: "Merge queued")
        case .queued(let count):
            return count == 1
                ? String(localized: "Sending")
                : String(localized: "\(count) sending")
        }
    }

    /// The chip's colour.
    var color: Color {
        switch self {
        case .failed, .parked: return Theme.failure
        case .merging, .mergeQueued, .queued: return Theme.pending
        case .merged: return Theme.success
        }
    }

    /// The chip's tooltip.
    var help: String {
        switch self {
        case .failed:
            return String(localized: "Shepherd could not send a change to GitHub. Open the pull request to retry it.")
        case .parked:
            return String(localized: "A change is held because the pull request moved on underneath it.")
        case .merging:
            return String(localized: "Shepherd is sending the merge to GitHub.")
        case .merged:
            return String(localized: "GitHub confirmed the merge. The pull request leaves the inbox with the next sync.")
        case .mergeQueued:
            return String(localized: "The merge is queued and goes out as soon as GitHub can be reached.")
        case .queued:
            return String(localized: "Shepherd is sending your change to GitHub.")
        }
    }
}
