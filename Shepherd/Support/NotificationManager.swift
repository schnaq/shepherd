import Foundation
import ShepherdCore
import ShepherdSync
import UserNotifications

/// One notification Shepherd wants to show.
///
/// A value rather than three loose strings, so the mapping functions below can be unit-tested
/// without a notification centre and so an automation's notice can be built in one place and
/// posted in another (ADR 0016).
struct NotificationPayload: Sendable, Equatable {
    /// The de-duplication identifier. macOS replaces a notification with the same id.
    var identifier: String
    /// The bold first line.
    var title: String
    /// The body.
    var body: String
}

/// Turns ``ShepherdSync/SyncEvent``s — and Shepherd's own automatic actions — into macOS
/// notifications.
///
/// Authorisation is requested lazily — the first time an event would actually produce a
/// notification — so a user who never enables notifications is never prompted.
@MainActor
final class NotificationManager {
    private let center: UNUserNotificationCenter
    private var authorizationRequested = false
    private var isAuthorized = false

    /// Creates a manager.
    /// - Parameter center: The notification centre. Injectable for tests.
    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Asks for authorisation once per launch, and remembers the answer.
    /// - Returns: Whether notifications may be posted.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        if authorizationRequested { return isAuthorized }
        authorizationRequested = true
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            isAuthorized = false
        }
        return isAuthorized
    }

    /// Posts a notification for a sync event, if the user asked for that category.
    /// - Parameters:
    ///   - event: The event the sync engine emitted.
    ///   - settings: The user's notification preferences.
    func present(_ event: SyncEvent, settings: AppSettings) async {
        guard let payload = Self.payload(for: event, settings: settings) else { return }
        await present(payload)
    }

    /// Posts a prepared notification.
    ///
    /// The one delivery path: the sync mapping and the auto-delegation notices both end here.
    /// - Parameter payload: What to show.
    func present(_ payload: NotificationPayload) async {
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
        // A failure here is cosmetic: the inbox already shows the change.
        try? await center.add(request)
    }

    /// The notification text for an event, or `nil` when nothing should be shown.
    ///
    /// Pure and `static` so the mapping is unit-testable without a notification centre.
    /// - Parameters:
    ///   - event: The sync event.
    ///   - settings: The user's preferences.
    static func payload(
        for event: SyncEvent,
        settings: AppSettings
    ) -> NotificationPayload? {
        switch event {
        case .newReviewRequest(let summary):
            guard settings.notifyOnReviewRequest else { return nil }
            return NotificationPayload(
                identifier: "review-request-\(summary.id)",
                title: String(localized: "Review requested · \(summary.slug)"),
                body: summary.title
            )
        case .checksFailedOnOwnPR(let failure):
            guard settings.notifyOnChecksFailed else { return nil }
            let summary = failure.summary
            return NotificationPayload(
                identifier: "checks-failed-\(summary.id)-\(summary.headRefOid)",
                title: String(localized: "Checks failed · \(summary.slug)"),
                body: summary.title
            )
        case .draftConflict(let conflict):
            guard settings.notifyOnDraftConflict else { return nil }
            return NotificationPayload(
                identifier: "draft-conflict-\(conflict.prID)-\(conflict.actualHeadOid)",
                title: String(localized: "Review not sent · \(conflict.repo.fullName)#\(conflict.number)"),
                body: String(localized: "The pull request got new commits. Re-review before submitting.")
            )
        case .changesRequestedOnOwnPR, .prMerged, .prUpdated, .mutationSent, .syncFailed:
            // A mutation the user just triggered themselves needs no notification — the toast
            // already said so, and the webhook dispatcher takes it from here (ADR 0012).
            // `changesRequestedOnOwnPR` exists for the auto-delegation rules (ADR 0016) and gets
            // no notification category of its own: the review already shows up in the inbox, and
            // an automatic start announces itself below.
            return nil
        }
    }

    // MARK: - Automatic delegation (ADR 0016)

    /// The notice posted when a rule started a delegation.
    ///
    /// Not gated by a notification preference, on purpose: this is Shepherd acting on its own,
    /// and something the app did unattended must always be visible. The way to switch it off is
    /// to switch the rule off.
    /// - Parameters:
    ///   - plan: What was started.
    ///   - agent: The agent CLI's display name.
    static func payload(
        forAutoDelegated plan: AutoDelegationPlan,
        agent: String
    ) -> NotificationPayload {
        let summary = plan.pullRequest
        let reason: String
        switch plan.trigger {
        case .checksFailed:
            reason = String(localized: "CI failed")
        case .changesRequested:
            reason = String(localized: "changes were requested")
        }
        return NotificationPayload(
            identifier: "auto-delegation-\(summary.id)-\(summary.headRefOid)",
            title: String(localized: "Auto-delegated \(summary.slug) to \(agent) — \(reason)"),
            body: String(localized: "\(summary.title) · nothing is pushed; open the delegation to review the diff.")
        )
    }

    /// The notice posted when a cap stopped a rule that would otherwise have fired.
    ///
    /// Only the caps produce one (``ShepherdCore/AutoDelegationSkipReason/isCap``): the user asked
    /// for automation and did not get it, which is worth a line. Every other skip is silent.
    /// - Parameters:
    ///   - signal: What the sweep noticed.
    ///   - reason: Why nothing was started.
    ///   - rules: The rules in force, for the numbers in the text.
    static func payload(
        forSkipped signal: AutoDelegationSignal,
        reason: AutoDelegationSkipReason,
        rules: AutoDelegationRules
    ) -> NotificationPayload? {
        let summary = signal.pullRequest
        let body: String
        switch reason {
        case .dailyCapReached:
            body = String(localized: "Today's limit of \(rules.dailyCap) automatic delegations is used up. Start it by hand from the pull request.")
        case .concurrencyCapReached:
            body = String(localized: "\(rules.concurrencyCap) automatic delegations are already running. Start it by hand from the pull request.")
        case .disabled, .triggerNotArmed, .notOwnPullRequest, .notATransition, .notConfigured,
             .alreadyHandled, .delegationRunning:
            return nil
        }
        return NotificationPayload(
            identifier: "auto-delegation-capped-\(summary.id)-\(summary.headRefOid)",
            title: String(localized: "Not auto-delegated · \(summary.slug)"),
            body: body
        )
    }
}
