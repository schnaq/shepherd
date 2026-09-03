import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// What the local inbox knows about a pull request an issue is linked to (ADR 0032's Sprint 3
/// amendment).
///
/// The issue sweep carries a linked pull request's number, title, state and author and nothing
/// else — `closedByPullRequestsReferences` selects no rollup and no review decision, and asking
/// GitHub for them would be one request per link on a list that redraws whenever a sweep lands.
/// So the two facts the roadmap asks the issue's list to show are resolved by a **local join**
/// instead: the pull request is looked up in `pull_requests` by `(repo, number)`, and when it is
/// there — the common case, because somebody who assigns issues usually reviews the resulting
/// pull requests — its cached rollup and decision are shown. When it is not, nothing is shown.
///
/// That is the whole design: zero new GitHub calls, and an honest blank where a fetch would have
/// been (ADR 0006's "the UI renders from the database").
struct LinkedPullRequestStatus: Equatable, Sendable {
    /// The rolled-up CI state the inbox has for this pull request, or `nil` when it has none.
    ///
    /// `nil` means *unknown*, never "no checks": a row the sweep has seen but whose checks
    /// nothing ever reported carries no rollup, and a green dot for that would be an invention.
    var checkRollup: CheckRollup?
    /// GitHub's aggregate review decision, or `nil` when there is none yet.
    var reviewDecision: ReviewDecision?

    /// Creates a status.
    /// - Parameters:
    ///   - checkRollup: The rolled-up CI state, if known.
    ///   - reviewDecision: The review decision, if any.
    init(checkRollup: CheckRollup? = nil, reviewDecision: ReviewDecision? = nil) {
        self.checkRollup = checkRollup
        self.reviewDecision = reviewDecision
    }

    /// Reads the two fields off a cached inbox row.
    /// - Parameter summary: The row the local join found.
    init(summary: PullRequestSummary) {
        self.checkRollup = summary.checkRollup
        self.reviewDecision = summary.reviewDecision
    }

    /// Whether there is nothing to draw.
    ///
    /// A pull request that *is* cached but has neither a rollup nor a decision yet — freshly
    /// opened, no checks reported, nobody has reviewed — is as blank as one that is not cached at
    /// all, and the badge treats the two alike rather than drawing an empty box.
    var isEmpty: Bool { checkRollup == nil && reviewDecision == nil }
}

/// Resolves a linked pull request against the local inbox.
///
/// A `@MainActor` helper rather than a model with state: the answer is one indexed read and the
/// view that asked owns the result for as long as it is on screen, so there is nothing to keep in
/// step with a sweep beyond re-asking — which ``LinkedPullRequestStatusBadge`` does through
/// `task(id:)`.
@MainActor
enum LinkedPullRequestStatusLoader {
    /// Looks one link up.
    /// - Parameters:
    ///   - reference: The link, as the issue sweep stored it.
    ///   - database: The local source of truth, or `nil` when there is no signed-in session —
    ///     which is a state and not a failure, and answers `nil` like any other cache miss.
    /// - Returns: The status, or `nil` when this pull request is not in the local inbox or has
    ///   nothing to say yet. A failed read is also `nil`: the honest degraded state of a badge is
    ///   no badge.
    static func load(
        _ reference: LinkedPullRequestReference,
        from database: DatabaseManager?
    ) async -> LinkedPullRequestStatus? {
        guard let database else { return nil }
        guard let summary = try? await database.fetchPullRequestSummary(
            repo: reference.repo,
            number: reference.number
        ) else { return nil }
        let status = LinkedPullRequestStatus(summary: summary)
        return status.isEmpty ? nil : status
    }
}

/// The CI dot and review decision beside a linked pull request, or nothing at all.
///
/// Drawn from the same two components an inbox row uses — ``CheckDotView`` and
/// ``ShepherdCore/ReviewDecision``'s chip — so a linked pull request and the same pull request in
/// the inbox cannot look different. It resolves itself: hand it the link and the database, and it
/// shows what the local join found, or nothing while there is nothing.
///
/// Sprint 3 provides it; the issue detail panel's linked-pull-request row is what places it.
struct LinkedPullRequestStatusBadge: View {
    /// The link to resolve.
    let reference: LinkedPullRequestReference
    /// The local source of truth, or `nil` when signed out.
    let database: DatabaseManager?

    /// The resolved status, or `nil` while it is unresolved, absent or blank.
    @State private var status: LinkedPullRequestStatus?

    var body: some View {
        content
            // Re-asked when the row is reused for another link, and re-asked when a sweep lands
            // only because the panel around it redraws with a new list — this view never polls.
            .task(id: reference.id) {
                status = await LinkedPullRequestStatusLoader.load(reference, from: database)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let status, !status.isEmpty {
            HStack(spacing: 6) {
                // Only when a rollup is actually known: `CheckDotView(state: nil)` is the muted
                // "no checks" dot, which is a different claim from "Shepherd has no idea".
                if let rollup = status.checkRollup {
                    CheckDotView(state: rollup.state)
                }
                if let decision = status.reviewDecision {
                    ChipView(text: decision.chipTitle, color: decision.chipColor, size: 10)
                }
            }
            .help(String(
                localized: "The state this pull request has in your inbox. Shepherd did not fetch anything for this list."
            ))
        }
    }
}
