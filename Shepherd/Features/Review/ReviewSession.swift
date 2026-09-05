import Foundation
import ShepherdCore

/// One guided pass over the pull requests that are waiting for the user's review.
///
/// The queue is **frozen** when the session starts and never grows again. That is the whole
/// point: a session whose list kept absorbing whatever the next sweep imported would turn
/// "3 of 12" into a number that goes up while you work, and finishing would depend on other
/// people stopping — the review equivalent of whack-a-mole. Pull requests that arrive during a
/// session are waiting in the inbox afterwards, where they belong.
///
/// A pure value, deliberately, and for the same reason ``InboxMarkSelection`` and
/// ``MenuBarQuickInbox`` are: everything worth getting right here is a *transition* — what
/// "next" does on the last entry, what happens when the entry under the cursor was merged by
/// someone else in the meantime, what an empty queue means — and none of that can be verified by
/// clicking through a window.
///
/// It lives in the app target rather than in `ShepherdCore` because the two functions it is
/// built on are the app's: ``SmartView/needsMyReview`` decides what "waiting for you" means and
/// ``InboxModel/prioritySorted(_:)`` decides what order to work through it in. Pushing those
/// down into the package to move this type with them would give the queue a second definition of
/// "needs my review", which is exactly the split ``MenuBarQuickInbox`` was written to avoid.
///
/// Session state is **not persisted**. A session is a sitting, not a document: it is held in
/// ``AppEnvironment/reviewSession`` and is gone after a relaunch. Restoring one would mean
/// restoring a snapshot of an inbox that has since moved on, and asking the user to finish a
/// queue they no longer remember starting. Nothing about it belongs in the encrypted settings
/// document (ADR 0014) either — there is no preference here to sync.
struct ReviewSession: Equatable, Sendable {
    /// One pull request in the frozen queue.
    ///
    /// The slug and the title are copied in rather than looked up on demand, so the session bar
    /// can still name a pull request that has since dropped out of the local inbox.
    struct Item: Equatable, Sendable, Identifiable {
        /// The pull request's node id — the queue's identity, everywhere.
        let id: String
        /// `owner/repo#number`, as of the moment the queue was frozen.
        let slug: String
        /// The title, as of the moment the queue was frozen.
        let title: String

        /// Freezes an inbox row into a queue entry.
        /// - Parameter pullRequest: The row.
        init(_ pullRequest: PullRequestSummary) {
            id = pullRequest.id
            slug = pullRequest.slug
            title = pullRequest.title
        }

        /// Creates an entry directly. Used by tests and previews.
        /// - Parameters:
        ///   - id: The node id.
        ///   - slug: `owner/repo#number`.
        ///   - title: The title.
        init(id: String, slug: String, title: String) {
            self.id = id
            self.slug = slug
            self.title = title
        }
    }

    /// What one move of the cursor amounted to.
    ///
    /// Returned rather than applied, so the caller does the two things only it can do — route to
    /// the next pull request, and say out loud what was passed over — without the session having
    /// to know about routes or toasts.
    struct Advance: Equatable, Sendable {
        /// The entries that were walked past because they are no longer in the inbox, in queue
        /// order.
        var vanished: [Item] = []
        /// The entry now under the cursor, or `nil` when the queue is exhausted.
        var next: Item?

        /// Whether this move ran the session out of pull requests.
        var isFinished: Bool { next == nil }

        /// The one line to say about what was skipped, or `nil` when nothing was.
        var vanishedMessage: String? {
            guard let first = vanished.first else { return nil }
            guard vanished.count > 1 else {
                return String(localized: "Skipped \(first.slug) — it is no longer in your inbox.")
            }
            return String(
                localized: "Skipped \(vanished.count) pull requests that are no longer in your inbox."
            )
        }
    }

    /// What a finished session did, for the completion view it closes with.
    struct Summary: Equatable, Sendable {
        /// How many entries the queue held.
        var total: Int
        /// How many were acted on — a queued verdict, a merge, or an explicit "done".
        var reviewed: Int
        /// How many the user passed over on purpose.
        var skipped: Int
        /// How many were passed over because they had left the inbox.
        var vanished: Int
        /// How many were never reached, because the session was ended early.
        var remaining: Int
        /// How long the session lasted.
        var duration: TimeInterval

        /// The completion view's headline.
        ///
        /// The same distinction ``message`` draws below and for the same reason: a queue that ran
        /// out is complete, and a session left with pull requests still in it is not.
        var title: String {
            remaining > 0
                ? String(localized: "Session ended")
                : String(localized: "Session complete")
        }

        /// The whole summary as one sentence.
        ///
        /// This was the closing toast, and the toast is gone: a focus session is one
        /// of the two moments this app has anything to celebrate, and a banner that fades after
        /// seven seconds is the same surface a failed clipboard copy gets. It survives as the
        /// *spoken* form of ``ReviewSessionSummaryView``, which is announced as one element — so
        /// the sentence a screen-reader user hears and the rows a sighted user reads are the same
        /// numbers assembled once rather than twice.
        ///
        /// Two shapes rather than one: a queue that ran out is "complete", a session ended with
        /// pull requests still in it is not, and writing "complete" over an early exit would be
        /// the one sentence in the app that is not true.
        var message: String {
            var parts = [String(localized: "\(reviewed) reviewed")]
            if skipped > 0 {
                parts.append(String(localized: "\(skipped) skipped"))
            }
            if vanished > 0 {
                parts.append(String(localized: "\(vanished) gone"))
            }
            let counts = parts.joined(separator: ", ")
            let elapsed = RelativeDate.duration(duration)
            guard remaining > 0 else {
                return String(localized: "Session complete — \(counts) · \(elapsed)")
            }
            return String(
                localized: "Session ended — \(counts), \(remaining) left · \(elapsed)"
            )
        }
    }

    /// The frozen queue, in the order it will be worked through.
    let items: [Item]
    /// When the session started, for the duration in the closing summary.
    let startedAt: Date

    /// Where the cursor is. `items.count` means "ran out".
    private(set) var cursor = 0
    /// How many entries were acted on.
    private(set) var reviewedCount = 0
    /// How many entries the user passed over on purpose.
    private(set) var skippedCount = 0
    /// How many entries were passed over because they had left the inbox.
    private(set) var vanishedCount = 0

    /// Creates a session over a frozen queue.
    ///
    /// Fails for an empty queue: there is no such thing as a guided pass over nothing, and a
    /// session bar reading "0 of 0" would be a dead end the user has to find their own way out
    /// of. The caller says "nothing needs your review" instead.
    /// - Parameters:
    ///   - items: The queue, already ordered.
    ///   - startedAt: When the session started.
    init?(items: [Item], startedAt: Date = Date()) {
        guard !items.isEmpty else { return nil }
        self.items = items
        self.startedAt = startedAt
    }

    /// Freezes the pull requests that are waiting for the user's review into a session queue.
    ///
    /// The filter and the order are the inbox's, not this type's: ``SmartView/needsMyReview`` and
    /// ``InboxModel/prioritySorted(_:)``, exactly as ``MenuBarQuickInbox/make(from:limit:)`` uses
    /// them. So the session works through the same list the window shows, in the same order,
    /// whichever surface started it — including ⌘K from the review screen, where no `InboxModel`
    /// exists to ask.
    ///
    /// The rail's *facet* filters are deliberately not applied. "Start review session" means
    /// "everything waiting for me", and a session silently shortened by a repository chip
    /// somebody clicked twenty minutes ago would be a queue the user cannot count.
    /// - Parameters:
    ///   - rows: Every cached inbox row.
    ///   - startedAt: When the session starts.
    /// - Returns: The session, or `nil` when nothing is waiting.
    static func make(
        from rows: [PullRequestSummary],
        startedAt: Date = Date()
    ) -> ReviewSession? {
        let waiting = rows.filter(SmartView.needsMyReview.matches)
        return ReviewSession(
            items: InboxModel.prioritySorted(waiting).map { Item($0) },
            startedAt: startedAt
        )
    }

    // MARK: - Where we are

    /// The pull request under the cursor, or `nil` when the queue is exhausted.
    var current: Item? {
        cursor < items.count ? items[cursor] : nil
    }

    /// How many entries the queue holds — the *m* of "n of m".
    var total: Int { items.count }

    /// The one-based position of the cursor — the *n* of "n of m".
    ///
    /// Clamped, so a session that has just run out reads "12 of 12" rather than "13 of 12".
    var position: Int { min(cursor + 1, items.count) }

    /// How many entries are still ahead, the one under the cursor included.
    var remaining: Int { max(0, items.count - cursor) }

    /// How far through the queue the session is, as `0…1`, for the progress track.
    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(cursor) / Double(items.count)
    }

    /// Whether the queue is exhausted.
    var isFinished: Bool { current == nil }

    // MARK: - Moving

    /// Records the entry under the cursor as reviewed and moves on.
    ///
    /// This is what a queued verdict, a queued merge, and "Done & next" all come down to.
    /// - Parameter present: The pull-request ids the local inbox still holds.
    /// - Returns: What the move amounted to.
    mutating func completeCurrent(present: Set<String>) -> Advance {
        guard !isFinished else { return Advance() }
        reviewedCount += 1
        cursor += 1
        return settle(present: present)
    }

    /// Passes over the entry under the cursor without counting it as reviewed.
    /// - Parameter present: The pull-request ids the local inbox still holds.
    /// - Returns: What the move amounted to.
    mutating func skipCurrent(present: Set<String>) -> Advance {
        guard !isFinished else { return Advance() }
        skippedCount += 1
        cursor += 1
        return settle(present: present)
    }

    /// Walks the cursor past entries that have left the inbox since the queue was frozen.
    ///
    /// Called after every move *and* once when the session is built, so the session never parks
    /// on a pull request that was merged or closed while the user was three entries back. Those
    /// entries are counted separately from the ones the user skipped on purpose — "3 skipped"
    /// should mean "you decided to move on", not "GitHub moved on".
    /// - Parameter present: The pull-request ids the local inbox still holds.
    /// - Returns: What was walked past, and what is now under the cursor.
    mutating func settle(present: Set<String>) -> Advance {
        var advance = Advance()
        while let item = current, !present.contains(item.id) {
            vanishedCount += 1
            cursor += 1
            advance.vanished.append(item)
        }
        advance.next = current
        return advance
    }

    // MARK: - Closing

    /// What the session did, as of a moment.
    /// - Parameter date: "Now" — injectable, so the duration is testable.
    /// - Returns: The summary the completion view reads.
    func summary(at date: Date = Date()) -> Summary {
        Summary(
            total: items.count,
            reviewed: reviewedCount,
            skipped: skippedCount,
            vanished: vanishedCount,
            remaining: remaining,
            duration: max(0, date.timeIntervalSince(startedAt))
        )
    }
}
