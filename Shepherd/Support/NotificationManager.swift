import Foundation
import ShepherdCore
import ShepherdSync
import UserNotifications

/// The categories Shepherd posts notifications under.
///
/// A category rather than a prefix match on the identifier: it is what a click is routed on
/// (``NotificationRouter``), and it survives any future change to how identifiers are built. No
/// category is *registered* with `setNotificationCategories(_:)`, because none of them declares
/// custom actions — the only interaction is the click on the notification itself.
enum NotificationCategory {
    /// The daily morning digest.
    static let digest = "shepherd.digest"
}

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
    /// The category a click is routed on, when this notification is clickable.
    var categoryIdentifier: String?

    /// Creates a payload.
    /// - Parameters:
    ///   - identifier: The de-duplication identifier.
    ///   - title: The bold first line.
    ///   - body: The body.
    ///   - categoryIdentifier: The category, for notifications a click should route.
    init(
        identifier: String,
        title: String,
        body: String,
        categoryIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
    }
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
    /// The delegate that receives clicks. Held here because `UNUserNotificationCenter.delegate`
    /// is a weak reference, so nothing else in the app keeps it alive.
    private var router: NotificationRouter?

    /// Creates a manager.
    /// - Parameter center: The notification centre. Injectable for tests.
    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Starts routing clicks on Shepherd's own notifications.
    ///
    /// Called from ``AppEnvironment/init(settings:tokenStore:secretStore:)`` rather than from
    /// `bootstrap()`: a notification the user clicked while the app was not running is delivered to
    /// the delegate shortly after launch, so the delegate has to exist by the earliest moment a
    /// SwiftUI app has any code of its own.
    /// - Parameter onDigestClicked: What to do when the morning digest is clicked.
    func routeClicks(onDigestClicked: @escaping @MainActor () -> Void) {
        guard router == nil else { return }
        let router = NotificationRouter(onDigestClicked: onDigestClicked)
        self.router = router
        center.delegate = router
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
        if let category = payload.categoryIdentifier {
            content.categoryIdentifier = category
        }

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

    // MARK: - Morning digest

    /// The notice the morning digest posts, or `nil` when there is nothing to report.
    ///
    /// Not gated by any of the three notification toggles above: the digest has an opt-in of its
    /// own (Settings → Sync), and a scheduled announcement the user asked for should not also
    /// depend on the switch for unsolicited review requests. An **empty** report produces no
    /// notification at all — "good morning, nothing happened" is not worth a banner, and the whole
    /// point of ``ShepherdCore/DigestReport/isEmpty`` is to make that decision here rather than in
    /// a view.
    ///
    /// The identifier carries the day, so the digest of one day replaces nothing and is replaced by
    /// nothing: an old, unread digest stays readable in Notification Centre, while a re-post on the
    /// same day (a clock jump, a settings document arriving) collapses into the one banner.
    /// - Parameters:
    ///   - report: What the digest found.
    ///   - dayStamp: The `yyyy-MM-dd` stamp of the delivery day.
    static func payload(forDigest report: DigestReport, dayStamp: String) -> NotificationPayload? {
        guard !report.isEmpty else { return nil }
        return NotificationPayload(
            identifier: "digest-\(dayStamp)",
            title: DigestPresentation.greeting,
            body: DigestPresentation.summary(for: report),
            categoryIdentifier: NotificationCategory.digest
        )
    }
}

/// Receives clicks on Shepherd's notifications and turns them into navigation.
///
/// Deliberately tiny and deliberately switch-free beyond one comparison: the only notification that
/// routes anywhere is the morning digest, which is the only one that is *not* about a single pull
/// request the user can already see. Every other notification keeps macOS's default behaviour —
/// clicking it brings the app forward — because a review request that yanked the app to a different
/// screen while somebody was mid-review would be hostile.
///
/// The `async` form of the delegate callback is implemented rather than the completion-handler one,
/// so the hop onto the main actor is the language's job instead of a captured closure's.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let onDigestClicked: @MainActor () -> Void

    /// Creates a router.
    /// - Parameter onDigestClicked: What to do when the morning digest is clicked.
    init(onDigestClicked: @escaping @MainActor () -> Void) {
        self.onDigestClicked = onDigestClicked
        super.init()
    }

    /// Handles a click on a notification.
    /// - Parameters:
    ///   - center: The notification centre.
    ///   - response: What the user did.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier
            == NotificationCategory.digest
        else { return }
        onDigestClicked()
    }
}
