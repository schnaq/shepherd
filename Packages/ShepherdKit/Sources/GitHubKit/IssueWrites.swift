import Foundation
import ShepherdCore

/// What the issue staleness probe answers with (ADR 0032's Sprint 4a amendment).
///
/// The issue-side twin of the head SHA ``GitHubClient/headRefOid(repo:number:)`` returns, and it
/// is a small value rather than a bare `Date` for one reason: the probe already selects `closed`
/// on a query that has to be made anyway, and a queued reopen whose issue is already open is
/// worth being able to tell apart from one whose issue somebody else edited.
///
/// It carries no title, no body, no labels and no author. This is a precondition check, not a
/// read of the issue — the row the UI draws from comes from the sweep.
public struct IssueState: Sendable, Hashable {
    /// The issue's GraphQL node id, so a probe can be matched against the row that queued it.
    public var id: String
    /// The issue's current `updatedAt` — the field every issue write moves.
    public var updatedAt: Date
    /// Whether GitHub currently says the issue is closed.
    public var isClosed: Bool

    /// Creates a probe result.
    /// - Parameters:
    ///   - id: The issue's node id.
    ///   - updatedAt: The issue's current `updatedAt`.
    ///   - isClosed: Whether the issue is closed.
    public init(id: String, updatedAt: Date, isClosed: Bool) {
        self.id = id
        self.updatedAt = updatedAt
        self.isClosed = isClosed
    }

    /// Whether an action composed against `basedOnUpdatedAt` is stale.
    ///
    /// Compared with a one-second tolerance rather than for exact equality, and that is a
    /// property of the data rather than defensive rounding: GitHub's timestamps are second-precision
    /// ISO-8601, the stored row holds the same parsed value as a `Double`, and a difference below
    /// one second therefore cannot be a real edit — while an exact `!=` would be at the mercy of
    /// any future encoder that ever wrote a fractional second.
    ///
    /// Pure so the rule is unit-tested without a client (``ShepherdCore/ReviewDraft/isStale(against:)``'s
    /// reason).
    /// - Parameter basedOnUpdatedAt: The `updatedAt` the queued action was composed against.
    /// - Returns: `true` when the issue has moved on and nothing may be sent.
    public func isStale(against basedOnUpdatedAt: Date) -> Bool {
        abs(updatedAt.timeIntervalSince(basedOnUpdatedAt)) >= 1
    }
}

extension IssueCloseReason {
    /// The `state` value the REST endpoint expects for this close.
    ///
    /// Always `"closed"` — the reason is what varies — and it lives here so that the drain never
    /// spells a GitHub state word itself.
    public var apiState: String { "closed" }
}
