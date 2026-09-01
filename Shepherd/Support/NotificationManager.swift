import Foundation
import ShepherdCore
import ShepherdSync
import UserNotifications

/// Turns ``ShepherdSync/SyncEvent``s into macOS notifications.
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
    ) -> (identifier: String, title: String, body: String)? {
        switch event {
        case .newReviewRequest(let summary):
            guard settings.notifyOnReviewRequest else { return nil }
            return (
                "review-request-\(summary.id)",
                String(localized: "Review requested · \(summary.slug)"),
                summary.title
            )
        case .checksFailedOnOwnPR(let summary):
            guard settings.notifyOnChecksFailed else { return nil }
            return (
                "checks-failed-\(summary.id)-\(summary.headRefOid)",
                String(localized: "Checks failed · \(summary.slug)"),
                summary.title
            )
        case .draftConflict(let conflict):
            guard settings.notifyOnDraftConflict else { return nil }
            return (
                "draft-conflict-\(conflict.prID)-\(conflict.actualHeadOid)",
                String(localized: "Review not sent · \(conflict.repo.fullName)#\(conflict.number)"),
                String(localized: "The pull request got new commits. Re-review before submitting.")
            )
        case .prMerged, .prUpdated, .mutationSent, .syncFailed:
            // A mutation the user just triggered themselves needs no notification — the toast
            // already said so, and the webhook dispatcher takes it from here (ADR 0012).
            return nil
        }
    }
}
