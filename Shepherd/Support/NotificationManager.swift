import AppIntents
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
    /// The pull requests this notification is about, by node id — what lets Siri and Apple
    /// Intelligence act on "this" with a read intent (ADR 0021's 2026-09-22 amendment).
    var pullRequestIDs: [String]

    /// Creates a payload.
    /// - Parameters:
    ///   - identifier: The de-duplication identifier.
    ///   - title: The bold first line.
    ///   - body: The body.
    ///   - categoryIdentifier: The category, for notifications a click should route.
    ///   - pullRequestIDs: The pull requests it is about, by node id.
    init(
        identifier: String,
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        pullRequestIDs: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.categoryIdentifier = categoryIdentifier
        self.pullRequestIDs = pullRequestIDs
    }

    /// The entities the system attaches to the notification.
    var entityIdentifiers: [EntityIdentifier] {
        pullRequestIDs.map { EntityIdentifier(for: PullRequestEntity.self, identifier: $0) }
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
    /// Answers `true` for a sync event that is somebody else's to announce.
    ///
    /// Today only a merge series (ADR 0041) sets it: the parked branch update it queued raises
    /// ``ShepherdSync/SyncEvent/draftConflict(_:)``, whose notice says "Review not sent" — about
    /// a review nobody wrote. The series says what happened in its chip and its summary.
    var suppresses: (@MainActor (SyncEvent) -> Bool)?

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
        if suppresses?(event) == true { return }
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
        content.appEntityIdentifiers = payload.entityIdentifiers

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
                body: summary.title,
                pullRequestIDs: [summary.id]
            )
        case .checksFailedOnOwnPR(let failure):
            guard settings.notifyOnChecksFailed else { return nil }
            let summary = failure.summary
            return NotificationPayload(
                identifier: "checks-failed-\(summary.id)-\(summary.headRefOid)",
                title: String(localized: "Checks failed · \(summary.slug)"),
                body: summary.title,
                pullRequestIDs: [summary.id]
            )
        case .draftConflict(let conflict):
            guard settings.notifyOnDraftConflict else { return nil }
            return NotificationPayload(
                identifier: "draft-conflict-\(conflict.prID)-\(conflict.actualHeadOid)",
                title: String(localized: "Review not sent · \(conflict.repo.fullName)#\(String(conflict.number))"),
                body: String(localized: "The pull request got new commits. Re-review before submitting."),
                pullRequestIDs: [conflict.prID]
            )
        case .changesRequestedOnOwnPR, .prMerged, .prUpdated, .mutationSent, .sweepCompleted,
             .syncFailed:
            // A mutation the user just triggered themselves needs no notification — the toast
            // says so, and the webhook dispatcher takes it from here (ADR 0012). That argument
            // used to be half true for a merge, whose toast could only say "queued": the app now
            // toasts the merge when the drain reports it sent (`AppEnvironment.confirmMerge(_:)`),
            // so the toast really does say it and this stays silent.
            // `changesRequestedOnOwnPR` exists for the auto-delegation rules (ADR 0016) and gets
            // no notification category of its own: the review already shows up in the inbox, and
            // an automatic start announces itself below. `sweepCompleted` is the routine
            // heartbeat of a working account — every two minutes, whether or not anything
            // happened — and notifying on it would be the loudest possible way to say nothing.
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
            body: String(localized: "\(summary.title) · nothing is pushed; open the delegation to review the diff."),
            pullRequestIDs: [summary.id]
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
            body: body,
            pullRequestIDs: [summary.id]
        )
    }

    // MARK: - Automatic merging (ADR 0018)

    /// The notice posted when automatic merging queued one or more merges.
    ///
    /// One notice per *pass*, not per merge: a Monday-morning sweep can queue a dozen, and a dozen
    /// banners would make the automation more disruptive than the dozen clicks it replaced. Not
    /// gated by a notification preference, for ADR 0016's reason — this is the app writing to
    /// GitHub unattended, which must always be visible, and the way to switch it off is to switch
    /// the rule off.
    ///
    /// The wording says **queued**, because that is what happened: the outbox sends the merge, and
    /// a head commit that moved in between parks it instead (ADR 0006). Claiming "merged" here
    /// would be the one lie in the whole feature.
    ///
    /// The identifier is keyed on the first entry's `(pull request, head commit)` pair, so a pass
    /// repeated for the same commit — a second sweep, a relaunch — collapses into the one banner
    /// instead of stacking.
    /// - Parameter entries: The audit lines just recorded, in the order they were queued.
    static func payload(forAutoMerged entries: [AutoMergeAuditEntry]) -> NotificationPayload? {
        guard let first = entries.first else { return nil }
        let identifier = "auto-merge-\(first.prID)-\(first.headRefOid)"
        guard entries.count > 1 else {
            return NotificationPayload(
                identifier: identifier,
                title: String(localized: "Auto-merge queued · \(first.slug)"),
                body: String(localized: "\(first.title) · green, approved, agent-authored. Shepherd queued a \(first.mergeMethod) merge."),
                pullRequestIDs: [first.prID]
            )
        }
        let slugs = entries.map(\.slug).joined(separator: ", ")
        return NotificationPayload(
            identifier: identifier,
            title: String(localized: "Auto-merge queued · \(entries.count) pull requests"),
            body: slugs,
            pullRequestIDs: entries.map(\.prID)
        )
    }

    // MARK: - Merge when checks pass (ADR 0037)

    /// The notice posted when a merge the user armed was queued because its checks went green.
    ///
    /// One notice per pass, like the auto-merge notice, and it says **queued** for the same
    /// reason: the outbox sends the merge, and a head that moved in between parks it instead.
    /// Not gated by any notification preference — the user is counting on this merge, and the
    /// moment it goes out is the moment they want to hear about it.
    /// - Parameter requests: The arms that fired, in the order they were queued.
    static func payload(forMergedWhenGreen requests: [MergeWhenGreenRequest]) -> NotificationPayload? {
        guard let first = requests.first else { return nil }
        let identifier = "merge-when-green-\(first.prID)-\(first.headRefOid)"
        guard requests.count > 1 else {
            return NotificationPayload(
                identifier: identifier,
                title: String(localized: "Checks passed · \(first.slug)"),
                body: String(localized: "\(first.title) · Shepherd queued the \(first.mergeMethod) merge you asked for."),
                pullRequestIDs: [first.prID]
            )
        }
        let slugs = requests.map(\.slug).joined(separator: ", ")
        return NotificationPayload(
            identifier: identifier,
            title: String(localized: "Checks passed · \(requests.count) merges queued"),
            body: slugs,
            pullRequestIDs: requests.map(\.prID)
        )
    }

    /// The notice posted when an armed merge was dropped instead of queued.
    ///
    /// One per arm, because each carries a reason the user has to act on differently: a push
    /// means re-reading the diff, a red check means fixing or re-running it, a conflict means a
    /// rebase. The identifier carries the reason, so a push that follows a failure is a second
    /// banner rather than a rewrite of the first.
    /// - Parameter abandonment: The dropped arm and why.
    static func payload(forAbandonedMergeWhenGreen abandonment: MergeWhenGreenAbandonment) -> NotificationPayload {
        let request = abandonment.request
        let body: String
        switch abandonment.reason {
        case .headMoved:
            body = String(localized: "\(request.title) · A new push arrived, so the commit you judged is no longer the one that would be merged. Not merged.")
        case .checksFailed:
            body = String(localized: "\(request.title) · A check failed on the commit you judged. Not merged.")
        case .noChecks:
            body = String(localized: "\(request.title) · The commit has no checks left to wait for. Not merged.")
        case .draft:
            body = String(localized: "\(request.title) · The pull request was turned back into a draft. Not merged.")
        case .conflicting:
            body = String(localized: "\(request.title) · GitHub reports conflicts with the base branch. Not merged.")
        }
        return NotificationPayload(
            identifier: "merge-when-green-dropped-\(request.prID)-\(request.headRefOid)-\(abandonment.reason.rawValue)",
            title: String(localized: "Not merged · \(request.slug)"),
            body: body,
            pullRequestIDs: [request.prID]
        )
    }

    // MARK: - Merge series (ADR 0041)

    /// How many skipped entries the summary notice names one by one; the rest are counted.
    static let mergeSeriesSkipsNamed = 3

    /// The one notice a finished merge series posts: "schnaq/shepherd: 4 merged, 1 skipped", and
    /// the first few skips with their reason.
    ///
    /// One per series rather than one per merge: every merge already toasts when it lands
    /// (``AppEnvironment``'s confirmation), and what the user is waiting for is "done, and here
    /// is what did not make it". No notice for a series the user cancelled before anything
    /// happened — they know, they pressed Cancel.
    /// - Parameter series: The finished series.
    /// - Returns: The notice, or `nil` when every entry was taken out by the user.
    static func payload(forFinishedMergeSeries series: MergeSeries) -> NotificationPayload? {
        let skipped = series.entries.compactMap { entry in
            entry.state.skipReason.map { (entry: entry, reason: $0) }
        }
        guard !series.entries.isEmpty,
              !skipped.allSatisfy({ $0.reason == .removedByUser }) || series.mergedCount > 0
        else { return nil }
        let repository = series.repository.fullName
        let mergedCount = series.mergedCount
        // The participles do not inflect for number in either language, so one key per shape is
        // plural-safe without a plural variation.
        let title = skipped.isEmpty
            ? String(localized: "\(repository): \(mergedCount) merged")
            : String(localized: "\(repository): \(mergedCount) merged, \(skipped.count) skipped")
        var lines = skipped.prefix(mergeSeriesSkipsNamed).map { skip in
            "#\(skip.entry.number) \(skip.entry.title) — \(skip.reason.title)"
        }
        let remainingSkips = skipped.count - mergeSeriesSkipsNamed
        if remainingSkips > 0 {
            lines.append(String(localized: "and \(remainingSkips) more"))
        }
        let body = lines.isEmpty
            ? String(localized: "The merge series is done. Every pull request in it was merged.")
            : lines.joined(separator: "\n")
        return NotificationPayload(
            identifier: "merge-series-finished-\(series.id)",
            title: title,
            body: body,
            pullRequestIDs: series.entries.map(\.prID)
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
/// The completion-handler form of the delegate callback is implemented, `nonisolated`, rather than
/// the `async` one: the centre calls its delegate off the main thread with a response that is not
/// `Sendable`, so an `async` witness on a main-actor class would have to ship that response across
/// an isolation boundary — which Swift 6 rightly refuses. Instead the one fact the router needs, the
/// category, is read where the response is, and only the decision hops onto the main actor.
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
    ///   - completionHandler: Told straight away — the centre only wants to know the click was
    ///     seen, and the navigation is not its business.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isDigest = response.notification.request.content.categoryIdentifier
            == NotificationCategory.digest
        completionHandler()
        guard isDigest else { return }
        let onDigestClicked = self.onDigestClicked
        Task { @MainActor in
            onDigestClicked()
        }
    }
}
