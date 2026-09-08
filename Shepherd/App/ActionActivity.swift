import Foundation
import Observation

/// Which user-initiated writes are in flight right now, so a button can go quiet while its
/// own write runs (and refuse a second click) without every view keeping its own flag.
///
/// Live testing found every write button in the app clickable and silent between the click and
/// the toast the drain eventually raises: a double click on *Approve* queued two reviews, and a
/// merge that took a second looked like a button that had not registered the press. The button
/// cannot answer that on its own — an outbox write is a `Task` a view starts and forgets — so the
/// answer is kept in one place beside the funnel every write already goes through
/// (``PullRequestActions``, ``IssueInboxModel/queue(_:on:)``) and read back by the buttons.
///
/// One object rather than a `@State` flag per surface, for the reason the funnel itself exists:
/// the same pull request is approved from the inbox panel, the review screen's composer bar, the
/// ⌘K palette and a keyboard shortcut, and a flag on any one of those would leave the other three
/// live. The key is *what is being written to*, not *which button was pressed*.
///
/// Nothing here is persisted and nothing survives a relaunch, deliberately: this is about the
/// second between a click and the outbox row, and ADR 0006 already owns everything after it —
/// a queued write that outlives the app is the outbox's business, and ``QueueStatusLine`` is
/// where the user reads about it.
@MainActor
@Observable
final class ActionActivity {
    /// Which verb is in flight.
    ///
    /// Coarser than ``ShepherdCore/OutboxAction``, but only where two writes really are the same
    /// press: the three verdicts share ``Kind/review`` because approving and requesting changes
    /// on one pull request half a second apart is a mistake either way. Where they are *not* the
    /// same press the kinds stay apart — the four issue verbs are four kinds, because a spinner
    /// on *Label* while somebody closed the issue is a button reporting a write it did not start.
    enum Kind: Hashable, Sendable {
        /// A review verdict: approve, request changes or comment.
        case review
        /// A merge.
        case merge
        /// A reply to a review comment, and the inline composer that writes one.
        case reply
        /// A review thread resolved or reopened. Keyed by the **thread's** id, not the pull
        /// request's: two threads on one pull request are two conversations.
        case thread
        /// A file's viewed flag.
        case viewed
        /// Taking a pull request out of draft state.
        case readyForReview
        /// A whole bulk-triage plan (ADR 0015), which targets no single row and is keyed
        /// `"bulk"`.
        case bulk
        /// A comment on an issue (ADR 0032) — including the one an agent handover records.
        case issueComment
        /// Assigning an issue to the signed-in user.
        case issueAssign
        /// Adding a label to an issue.
        case issueLabel
        /// Closing or reopening an issue.
        case issueState
    }

    /// One in-flight write: what it targets and what it is.
    struct Key: Hashable, Sendable {
        /// What the write targets: a pull request's node id, an issue's node id, a review
        /// thread's node id, or `"bulk"`. Which one is decided by ``kind``.
        let id: String
        /// Which verb.
        let kind: Kind
    }

    /// The writes in flight. Observed by every button that can start one.
    private(set) var running: Set<Key> = []

    /// Creates an empty tracker.
    init() {}

    /// Whether this exact write is in flight.
    /// - Parameters:
    ///   - id: The pull request's node id, the issue's node id, or `"bulk"`.
    ///   - kind: Which verb.
    /// - Returns: `true` while the write runs.
    func isRunning(_ id: String, _ kind: Kind) -> Bool {
        running.contains(Key(id: id, kind: kind))
    }

    /// Whether *any* of these writes is in flight against the same target.
    ///
    /// What a panel of sibling buttons asks. The issue triage row is the case it exists for: each
    /// of its buttons spins only for its own kind, so the person can see which write they started
    /// — and all of them stop answering while any of the four runs, because a second issue write
    /// queued behind the first is re-validated against an `updatedAt` the first one is about to
    /// move (ADR 0032).
    /// - Parameters:
    ///   - id: The target's node id.
    ///   - kinds: The verbs to ask about.
    /// - Returns: `true` while at least one of them runs.
    func isRunningAny(_ id: String, _ kinds: [Kind]) -> Bool {
        kinds.contains { isRunning(id, $0) }
    }

    /// Runs `body` with the key marked running; returns nil and does nothing if already running.
    ///
    /// The mark and the check are one `Set.insert` rather than a `contains` followed by an
    /// `insert`: this type is `@MainActor`, so there is no thread to lose the race to, but a
    /// caller that suspended between the two halves would be exactly the double click this
    /// exists to refuse. The release is a `defer`, so a body that leaves early — or is
    /// cancelled — cannot leave a button dark forever.
    /// - Parameters:
    ///   - id: The pull request's node id, the issue's node id, or `"bulk"`.
    ///   - kind: Which verb.
    ///   - body: The write.
    /// - Returns: What `body` returned, or `nil` when the same write was already in flight and
    ///   `body` was therefore never called.
    @discardableResult
    func run<T>(_ id: String, _ kind: Kind, _ body: () async -> T) async -> T? {
        let key = Key(id: id, kind: kind)
        guard running.insert(key).inserted else { return nil }
        defer { running.remove(key) }
        return await body()
    }
}
