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
///
/// A merge series (ADR 0041) is one more source, and it slots in directly below the two that need
/// the reviewer: a failed or parked row still wins, because it is something to act on and the
/// series chip would only say "skipped" about it; above everything else, because while a series
/// runs, *where in the series* is the news — "Series 2/5 · merging" says more than "Merge queued".
/// A merged entry has no series chip and falls through to *Merged*.
enum RowWriteState: Equatable, Sendable {
    /// Writes Shepherd gave up on.
    case failed(Int)
    /// Writes held because the pull request moved on underneath them.
    case parked(Int)
    /// The pull request is part of a running merge series.
    case series(MergeSeriesChip)
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
    ///   - series: Where the pull request stands in a running merge series, if it is in one.
    /// - Returns: The state, or `nil` when the outbox holds nothing for it.
    static func make(
        items: [OutboxItem],
        for id: String,
        isMerging: Bool,
        wasMerged: Bool,
        series: MergeSeriesChip? = nil
    ) -> RowWriteState? {
        let mine = items.filter { $0.prID == id }
        let failed = mine.filter { $0.state == .failed }.count
        if failed > 0 { return .failed(failed) }
        let parked = mine.filter { $0.state == .conflicted }.count
        if parked > 0 { return .parked(parked) }
        let waiting = mine.filter { $0.state == .pending || $0.state == .sending }
        let mergeWaiting = waiting.contains { if case .merge = $0.action { true } else { false } }
        if var series, !wasMerged {
            // A merge on its way — the series' own, or one pressed by hand on an entry still
            // waiting its turn — reads as the series merging, so ``isMergeOnItsWay`` stays true
            // and the Merge button and `m` refuse a second one exactly as without a series.
            if isMerging || mergeWaiting { series.phase = .merging }
            return .series(series)
        }
        if isMerging { return .merging }
        if wasMerged { return .merged }
        if mergeWaiting {
            return .mergeQueued
        }
        return waiting.isEmpty ? nil : .queued(waiting.count)
    }

    /// Whether a merge is being sent, is queued or has landed — a state in which pressing Merge
    /// again could only queue a merge GitHub would refuse.
    var isMergeOnItsWay: Bool {
        switch self {
        case .merging, .mergeQueued, .merged: return true
        case .series(let chip): return chip.phase == .merging
        case .failed, .parked, .queued: return false
        }
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
        case .series(let chip):
            return chip.text
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
        case .series(let chip): return chip.color
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
        case .series(let chip):
            return chip.help
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

/// Where one pull request stands in a running merge series (ADR 0041), as its chip says it.
struct MergeSeriesChip: Equatable, Sendable {
    /// What the entry is doing.
    enum Phase: Equatable, Sendable {
        /// Waiting for its turn, or for GitHub's mergeability.
        case waiting
        /// A branch update is queued, or GitHub is still making its commit.
        case updatingBranch
        /// Its turn, and the checks on its head are running.
        case waitingForChecks
        /// The merge is queued.
        case merging
        /// Left behind, with the reason.
        case skipped(MergeSeriesSkipReason)
    }

    /// The one-based position in the series.
    var position: Int
    /// How many entries the series has.
    var total: Int
    /// What the entry is doing.
    var phase: Phase

    /// The chip for a pull request, or `nil` when it is not in the series or is already merged
    /// (the ordinary *Merged* chip says that).
    /// - Parameters:
    ///   - series: The running series.
    ///   - prID: The pull request's node id.
    ///   - row: The pull request as the caller shows it, for its head and its checks.
    static func make(series: MergeSeries, prID: String, row: PullRequestSummary?) -> MergeSeriesChip? {
        guard let place = series.position(of: prID) else { return nil }
        let entry = series.entries[place.index]
        let isActive = series.activeIndex == place.index
        let checksRunning = row?.checkRollup?.state == .pending
        let phase: Phase
        switch entry.state {
        case .merged:
            return nil
        case .skipped(let reason):
            phase = .skipped(reason)
        case .merging:
            phase = .merging
        case .updatingBranch:
            phase = .updatingBranch
        case .branchUpdated(let from):
            // Until the new head shows up, GitHub is still making the commit.
            phase = row == nil || row?.headRefOid == from ? .updatingBranch : .waitingForChecks
        case .pending:
            phase = isActive && checksRunning ? .waitingForChecks : .waiting
        }
        return MergeSeriesChip(position: place.index + 1, total: place.total, phase: phase)
    }

    /// The chip's words: "Series 2/5 · waiting".
    var text: String {
        switch phase {
        case .waiting:
            return String(localized: "Series \(position)/\(total) · waiting")
        case .updatingBranch:
            return String(localized: "Series \(position)/\(total) · updating branch")
        case .waitingForChecks:
            return String(localized: "Series \(position)/\(total) · waiting for checks")
        case .merging:
            return String(localized: "Series \(position)/\(total) · merging")
        case .skipped(let reason):
            return String(localized: "Series \(position)/\(total) · skipped: \(reason.title)")
        }
    }

    /// The chip's colour: the failure colour for a skip, the pending one for everything else.
    var color: Color {
        if case .skipped = phase { return Theme.failure }
        return Theme.pending
    }

    /// The chip's tooltip.
    var help: String {
        switch phase {
        case .waiting:
            return String(localized: "Part of a merge series. Shepherd merges it when its turn comes.")
        case .updatingBranch:
            return String(localized: "Part of a merge series. Shepherd asked GitHub to bring the branch up to date with its base.")
        case .waitingForChecks:
            return String(localized: "Part of a merge series. Shepherd merges it once its checks pass.")
        case .merging:
            return String(localized: "Part of a merge series. The merge is queued.")
        case .skipped(let reason):
            return reason.explanation
        }
    }
}

extension MergeSeriesSkipReason {
    /// The short reason, for the chip and the summary notice.
    var title: String {
        switch self {
        case .checksFailed: return String(localized: "checks failed")
        case .noChecks: return String(localized: "no checks")
        case .conflicting: return String(localized: "conflicts")
        case .draft: return String(localized: "draft")
        case .changesRequested: return String(localized: "changes requested")
        case .headMoved: return String(localized: "new commits")
        case .writeFailed: return String(localized: "a write failed")
        case .updateRefused: return String(localized: "update refused")
        case .mergeRefused: return String(localized: "merge refused")
        case .disappeared: return String(localized: "left the inbox")
        case .removedByUser: return String(localized: "removed")
        }
    }

    /// The tooltip.
    var explanation: String {
        switch self {
        case .checksFailed:
            return String(localized: "Skipped: a check failed on the commit the series was about to merge.")
        case .noChecks:
            return String(localized: "Skipped: the commit has no checks to wait for.")
        case .conflicting:
            return String(localized: "Skipped: GitHub reports conflicts with the base branch.")
        case .draft:
            return String(localized: "Skipped: the pull request was turned back into a draft.")
        case .changesRequested:
            return String(localized: "Skipped: a reviewer asked for changes.")
        case .headMoved:
            return String(localized: "Skipped: new commits arrived that nobody reviewed in this series.")
        case .writeFailed:
            return String(localized: "Skipped: a change for this pull request could not be sent to GitHub.")
        case .updateRefused:
            return String(localized: "Skipped: GitHub did not bring the branch up to date.")
        case .mergeRefused:
            return String(localized: "Skipped: GitHub refused the merge.")
        case .disappeared:
            return String(localized: "Skipped: the pull request left the inbox without being merged.")
        case .removedByUser:
            return String(localized: "Taken out of the series.")
        }
    }
}
