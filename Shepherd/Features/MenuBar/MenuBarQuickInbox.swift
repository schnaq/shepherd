import Foundation
import ShepherdCore

/// What the menu-bar quick inbox shows, derived from the rows the local database handed over.
///
/// A pure value, for the same reason ``InboxRailSelection`` and ``InboxMarkSelection`` are: the
/// two things worth getting right — where the list is cut off and how a count is written once it
/// no longer fits in a menu-bar item — are exactly the things nobody can verify by squinting at a
/// popover.
///
/// The *filter* belongs to this type rather than to the caller, so the badge and the list can
/// never disagree about what "waiting for you" means: both go through ``needsMyReview(in:)``,
/// which is ``SmartView/needsMyReview`` — the same predicate the rail's count uses. The order is
/// ``InboxModel/prioritySorted(_:)``, the same deterministic "look at this first" order the
/// inbox's priority sort uses, so the eight rows in the menu are the top eight of the list the
/// window shows rather than a second opinion about urgency.
struct MenuBarQuickInbox: Equatable, Sendable {
    /// How many rows the menu shows before it starts counting the rest.
    ///
    /// Eight is what fits above the footer without the menu turning into a scrolling list; the
    /// point of the quick inbox is "is anything waiting, and can I open it", not triage.
    static let rowLimit = 8

    /// The highest number the badge writes out. Above this it becomes `"99+"`, because a
    /// four-digit badge would push every other menu-bar item across the screen.
    static let badgeCeiling = 99

    /// The rows to render, at most ``rowLimit`` of them, most urgent first.
    let rows: [PullRequestSummary]

    /// How many pull requests are waiting in total — the badge number, uncapped.
    let total: Int

    /// Creates a value.
    /// - Parameters:
    ///   - rows: The rows to render.
    ///   - total: How many are waiting in total.
    init(rows: [PullRequestSummary], total: Int) {
        self.rows = rows
        self.total = total
    }

    /// Whether nothing at all is waiting.
    var isEmpty: Bool { total == 0 }

    /// How many waiting pull requests are *not* in ``rows`` — the "12 more…" number.
    var overflow: Int { max(0, total - rows.count) }

    // MARK: - Deriving

    /// The rows that are waiting for the user's review, in no particular order.
    ///
    /// Exposed on its own so the badge can be counted without sorting: the menu-bar item is
    /// re-rendered on every sweep, the popover only when it is open.
    /// - Parameter rows: Every cached inbox row.
    /// - Returns: The subset that needs the user's review.
    static func needsMyReview(in rows: [PullRequestSummary]) -> [PullRequestSummary] {
        rows.filter(SmartView.needsMyReview.matches)
    }

    /// How many pull requests are waiting for the user's review.
    /// - Parameter rows: Every cached inbox row.
    /// - Returns: The badge number.
    static func count(in rows: [PullRequestSummary]) -> Int {
        rows.reduce(into: 0) { total, row in
            if SmartView.needsMyReview.matches(row) { total += 1 }
        }
    }

    /// Builds the menu's contents from every cached inbox row.
    /// - Parameters:
    ///   - rows: Every cached inbox row.
    ///   - limit: How many rows to show. Defaults to ``rowLimit``; a limit below one shows none.
    /// - Returns: The truncated, ordered rows plus the total.
    static func make(
        from rows: [PullRequestSummary],
        limit: Int = MenuBarQuickInbox.rowLimit
    ) -> MenuBarQuickInbox {
        let waiting = needsMyReview(in: rows)
        let shown = InboxModel.prioritySorted(waiting).prefix(max(0, limit))
        return MenuBarQuickInbox(rows: Array(shown), total: waiting.count)
    }

    // MARK: - Badge

    /// The badge text for a count, or `nil` when there is nothing to say.
    ///
    /// `nil` at zero on purpose: an item that reads "0" is a permanent reminder of nothing, so
    /// an empty inbox shows the symbol alone.
    /// - Parameter count: How many pull requests are waiting.
    /// - Returns: The text to put next to the symbol, or `nil` for none.
    static func badgeText(count: Int) -> String? {
        guard count > 0 else { return nil }
        guard count <= badgeCeiling else { return "\(badgeCeiling)+" }
        return "\(count)"
    }
}
