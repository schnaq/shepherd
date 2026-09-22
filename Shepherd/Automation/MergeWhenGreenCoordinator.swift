import Foundation
import GitHubKit
import Observation
import ShepherdCore

/// One armed merge a pass queued.
struct MergeWhenGreenQueuedWrite: Sendable, Equatable {
    /// The arm, as the user recorded it.
    var request: MergeWhenGreenRequest
    /// The pull request, as the sweep that saw it go green knows it.
    var pullRequest: PullRequestSummary
}

/// One armed merge a pass gave up on.
struct MergeWhenGreenAbandonment: Sendable, Equatable {
    /// The arm that was dropped.
    var request: MergeWhenGreenRequest
    /// Why.
    var reason: MergeWhenGreenAbandonReason
}

/// What one pass did.
struct MergeWhenGreenPassResult: Sendable, Equatable {
    /// The merges queued, in the order the arms were recorded.
    var queued: [MergeWhenGreenQueuedWrite] = []
    /// The arms dropped, in the same order.
    var abandoned: [MergeWhenGreenAbandonment] = []
}

/// How a fired merge reaches the outbox.
///
/// The same seam ``AutoMergeWriting`` is, one argument wider: in the app it is
/// ``PullRequestActions/merge(_:method:deletesHeadBranch:)`` — the function the merge sheet's
/// *Merge* button calls — and in the tests a closure that records what it was asked to write.
/// The branch answer travels because the user ticked (or did not tick) the box on the sheet that
/// armed the merge, and their answer is what gets written, not the box's state at firing time.
typealias MergeWhenGreenWriting = @MainActor (PullRequestSummary, MergeMethod, Bool) async -> Void

/// Merges a pull request the user already decided on, once its checks turn green (ADR 0037).
///
/// The division of labour is ``AutoMergeCoordinator``'s: the *decision* is the pure
/// ``ShepherdCore/MergeWhenGreenPolicy``, and this type records the arm, supplies the inputs,
/// performs the write through the seam above and tells the user. The difference from ADR 0018 is
/// what the decision *is*. A rule decides on the user's behalf and therefore demands approval,
/// agent authorship and a green build before it will look. An arm is the user's own verdict on a
/// named commit, made with the checks visibly still running; the only question left is whether
/// that commit went green and is still the commit that would be merged.
///
/// It runs where auto-merge runs, on the rows a sweep wrote, and for the same reason: the one
/// transition it is about — the last check finishing — bumps nothing GitHub reports as a change,
/// so the persisted rows are the honest source. With nothing armed a pass is one `isEmpty` read.
@MainActor
@Observable
final class MergeWhenGreenCoordinator {
    /// How long an arm outlives its pull request's disappearance from the inbox.
    ///
    /// A row leaves the inbox when GitHub's search stops returning it — which is what happens when
    /// somebody merges or closes the pull request, and also, for one sweep now and then, when the
    /// search is momentarily behind. Dropping the arm on the first missing sweep would let that
    /// second case silently throw away a decision the user is counting on, so a missing row is a
    /// *wait*, and only an arm that has been waiting this long with nothing to look at is
    /// forgotten. Seven days: long past any search hiccup, and long enough that a pull request
    /// reopened at the same head is, for practical purposes, a new one.
    static let missingRowGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    private let settings: AppSettings
    private let store: MergeWhenGreenStore
    private let now: @MainActor () -> Date
    private let notify: @MainActor (NotificationPayload) -> Void

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: Where the remembered merge method lives, as the fallback for an arm whose
    ///     own method cannot be read.
    ///   - store: The persistent list of arms.
    ///   - now: The clock. Injectable so an arm's timestamp is assertable.
    ///   - notify: Where the notices go. A closure rather than the ``NotificationManager``
    ///     itself, so the logic can be tested without a notification centre.
    init(
        settings: AppSettings,
        store: MergeWhenGreenStore,
        now: @escaping @MainActor () -> Date = { Date() },
        notify: @escaping @MainActor (NotificationPayload) -> Void = { _ in }
    ) {
        self.settings = settings
        self.store = store
        self.now = now
        self.notify = notify
    }

    // MARK: - Arming

    /// How many merges are waiting for green on this Mac.
    var armedCount: Int { store.list.entries.count }

    /// Whether a merge is armed for this pull request *at this head*.
    ///
    /// A sheet opened on a newer push answers `false`, because the arm was about the older one —
    /// and the next pass will drop it for exactly that reason.
    /// - Parameter summary: The pull request, as the caller sees it.
    func isArmed(_ summary: PullRequestSummary) -> Bool {
        store.isArmed(pullRequestID: summary.id, headRefOid: summary.headRefOid)
    }

    /// The arm for a pull request, if any — for a surface that wants to say how it was armed.
    /// - Parameter prID: The pull request's node id.
    func request(forPullRequestID prID: String) -> MergeWhenGreenRequest? {
        store.request(forPullRequestID: prID)
    }

    /// Records the user's decision: merge this commit, this way, once its checks are green.
    ///
    /// Everything the write will need is copied in now, because now is when the user saw it.
    /// - Parameters:
    ///   - summary: The pull request, at the head the user is looking at.
    ///   - method: The merge method the sheet showed.
    ///   - deletesHeadBranch: The branch box as the sheet showed it.
    /// - Returns: What was recorded.
    @discardableResult
    func arm(
        _ summary: PullRequestSummary,
        method: MergeMethod,
        deletesHeadBranch: Bool
    ) -> MergeWhenGreenRequest {
        let request = MergeWhenGreenRequest(
            prID: summary.id,
            slug: summary.slug,
            title: summary.title,
            headRefOid: summary.headRefOid,
            mergeMethod: method.rawValue,
            deletesHeadBranch: deletesHeadBranch,
            armedAt: now()
        )
        store.arm(request)
        return request
    }

    /// Forgets an arm, because the user changed their mind.
    /// - Parameter prID: The pull request's node id.
    func disarm(pullRequestID prID: String) {
        store.disarm(pullRequestID: prID)
    }

    /// Forgets every arm. Called from "Sign out & erase local data".
    func reset() {
        store.reset()
    }

    // MARK: - Deciding

    /// Considers every armed merge against the rows a sweep just wrote.
    ///
    /// - Parameters:
    ///   - rows: Every inbox row the local database holds (``SignedInSession/inboxRows``).
    ///   - existingOutbox: The node ids of pull requests the outbox still holds a write for.
    ///   - write: How a merge reaches the outbox.
    /// - Returns: What was queued and what was dropped.
    @discardableResult
    func run(
        rows: [PullRequestSummary],
        existingOutbox: Set<String>,
        write: MergeWhenGreenWriting
    ) async -> MergeWhenGreenPassResult {
        let armed = store.list.entries
        // The common case, answered before anything is looked up: nothing armed, nothing to do.
        guard !armed.isEmpty else { return MergeWhenGreenPassResult() }

        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moment = now()
        var result = MergeWhenGreenPassResult()

        for request in armed {
            guard let row = rowsByID[request.prID] else {
                // Not in the inbox: merged or closed by somebody else — not Shepherd's news, so no
                // notice — or a search that is one sweep behind. The two are told apart only by
                // time (``missingRowGracePeriod``), so the arm is kept until then and forgotten
                // quietly afterwards. If the row comes back at the armed head, the decision still
                // stands; at any other head the next pass drops it with a notice, as for a push.
                if moment.timeIntervalSince(request.armedAt) > Self.missingRowGracePeriod {
                    store.disarm(pullRequestID: request.prID)
                }
                continue
            }
            let decision = MergeWhenGreenPolicy.decide(
                request: request,
                pullRequest: row,
                // The merges this pass has already queued are in the outbox now, but the set
                // was read before the pass began; adding them keeps "one write in flight" true
                // within the pass too.
                existingOutbox: existingOutbox.union(result.queued.map(\.pullRequest.id))
            )
            switch decision {
            case .wait:
                continue
            case .abandon(let reason):
                store.disarm(pullRequestID: request.prID)
                result.abandoned.append(MergeWhenGreenAbandonment(request: request, reason: reason))
            case .merge:
                // Spent before the write, on this side of the `await`: a second pass that starts
                // while this one is writing sees no arm and asks for nothing. The same order —
                // and the same trade — as the auto-merge ledger's.
                store.disarm(pullRequestID: request.prID)
                let method = MergeMethod(rawValue: request.mergeMethod) ?? settings.defaultMergeMethod
                await write(row, method, request.deletesHeadBranch)
                result.queued.append(MergeWhenGreenQueuedWrite(request: request, pullRequest: row))
            }
        }

        announce(result)
        return result
    }

    /// Posts the notices for one pass: one for everything queued, one per arm dropped.
    ///
    /// The merges share a banner for ``AutoMergeCoordinator``'s reason — they are all the same
    /// news. The abandonments do not, because each one carries a different reason the user needs
    /// to act on, and there is rarely more than one. Neither is gated by a notification
    /// preference: something the app did — or decided not to do — with a merge the user is
    /// counting on must always be visible.
    private func announce(_ result: MergeWhenGreenPassResult) {
        if let payload = NotificationManager.payload(forMergedWhenGreen: result.queued.map(\.request)) {
            notify(payload)
        }
        for abandonment in result.abandoned {
            notify(NotificationManager.payload(forAbandonedMergeWhenGreen: abandonment))
        }
    }
}
