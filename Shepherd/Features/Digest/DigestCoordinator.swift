import Foundation
import Observation
import ShepherdCore

/// Everything one due check needs from the signed-in session.
///
/// A value rather than the session itself, so the coordinator can be exercised — and reasoned
/// about — without a database: the digest reads two numbers off the session and nothing else.
struct DigestInputs: Sendable, Equatable {
    /// Every row the local inbox holds (``SignedInSession/inboxRows``).
    var pullRequests: [PullRequestSummary]
    /// Every issue row the local database holds (``SignedInSession/issueRows``), closed ones
    /// included — which is why that observation is the wide one (ADR 0032).
    var issues: [IssueRowSummary]
    /// How many outbox rows are parked as conflicted (``SignedInSession/conflictedOutboxCount``).
    var parkedReviewCount: Int

    /// Creates the inputs.
    /// - Parameters:
    ///   - pullRequests: Every cached inbox row.
    ///   - issues: Every cached issue row. Defaults to none, so a caller that predates the issues
    ///     inbox builds the inputs it always built.
    ///   - parkedReviewCount: How many mutations are parked as conflicted.
    init(
        pullRequests: [PullRequestSummary],
        issues: [IssueRowSummary] = [],
        parkedReviewCount: Int
    ) {
        self.pullRequests = pullRequests
        self.issues = issues
        self.parkedReviewCount = parkedReviewCount
    }
}

/// Delivers the morning digest: a notification when it is due, and a card in the inbox while the
/// day lasts.
///
/// The division of labour is ``AutoDelegationCoordinator``'s: the *decisions* are pure functions in
/// `ShepherdCore` — ``ShepherdCore/DigestSchedule/window(now:lastDeliveredAt:calendar:)`` for "is it
/// due" and ``ShepherdCore/DigestReport/make(pullRequests:issues:parkedReviewCount:windowStart:now:maxItemsPerSection:)``
/// for "what does it say" — and this type only supplies the inputs, records the delivery, and tells
/// the user.
///
/// Three properties are worth stating, because each of them is a decision that could plausibly have
/// gone the other way:
///
/// - **No launch agent, no daemon, no background task.** A `Task` in the app checks once a minute
///   while Shepherd is running, and the check is one `Bool` read when the feature is off. Shepherd
///   is a review inbox somebody keeps open; a digest that needed a login item to work would be a
///   much larger promise than the feature is worth, and one the app could not keep after a
///   sign-out.
/// - **A missed delivery is caught up, once, on the same day.** That is entirely the schedule's
///   rule; there is nothing here that remembers a pending delivery. See ``DigestSchedule``.
/// - **No cloud call, ever.** Everything in the digest comes from rows the sweep already wrote.
///   The digest fires unattended, so an on-device model would be the *only* intelligence tier this
///   path could ever use, and even that is not wired up: the deterministic lines are the feature,
///   and tier 2 would be a sentence on top of them (see `docs/ROADMAP.md`).
@MainActor
@Observable
final class DigestCoordinator {
    /// How often the due rule is evaluated.
    ///
    /// A minute, so a nine-o'clock digest arrives at nine o'clock rather than at the next sweep,
    /// and cheap enough to be uninteresting: with the feature off it is one `Bool`; with it on and
    /// nothing due it is a `dateComponents` call and two comparisons.
    static let checkInterval: Duration = .seconds(60)

    private let settings: AppSettings
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private let sleeper: any Sleeping
    private let interval: Duration
    private let notify: @MainActor (NotificationPayload) -> Void

    /// The digest the inbox is currently showing as a card, if any.
    ///
    /// Set when a digest is delivered, cleared by ``dismiss()`` and by the day rolling over. It is
    /// deliberately *not* persisted: the notification is the delivery, the card is the digest's
    /// presence in the app while the day lasts, and restoring a card after a relaunch would be a
    /// second announcement of something already announced.
    private(set) var report: DigestReport?

    private var task: Task<Void, Never>?
    /// What the loop reads its inputs from, set by ``start(source:)``.
    ///
    /// Held rather than captured by the loop's `Task`, so the only thing that task closes over is
    /// a weak `self` — a `@MainActor` class, and therefore `Sendable` without an argument.
    @ObservationIgnored private var source: (@MainActor () -> DigestInputs?)?

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: Where the schedule and the last-delivery date live.
    ///   - now: The clock. Injectable so the due behaviour is testable.
    ///   - calendar: The calendar, which carries the time zone that decides where a day ends.
    ///   - sleeper: How the loop waits. Injectable so a test never waits a minute.
    ///   - interval: How often the due rule is evaluated.
    ///   - notify: Where the notice goes. A closure rather than the ``NotificationManager`` itself,
    ///     so the delivery logic can be tested without a notification centre.
    init(
        settings: AppSettings,
        now: @escaping @MainActor () -> Date = { Date() },
        calendar: Calendar = .current,
        sleeper: any Sleeping = SystemSleeper(),
        interval: Duration = DigestCoordinator.checkInterval,
        notify: @escaping @MainActor (NotificationPayload) -> Void = { _ in }
    ) {
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.sleeper = sleeper
        self.interval = interval
        self.notify = notify
    }

    // MARK: - The loop

    /// Starts the once-a-minute due check. Safe to call more than once.
    ///
    /// The first check runs immediately rather than after a minute, so a Mac that wakes up at
    /// half past nine delivers the digest as it comes back rather than a minute later.
    /// - Parameter source: What the current session holds, or `nil` when there is nothing to report
    ///   on yet — signed out, or the inbox observation has not spoken yet. A tick with no source
    ///   does nothing at all and is retried on the next one, which is what stops a digest being
    ///   delivered as "empty" in the second between launch and the first `SELECT`.
    func start(source: @escaping @MainActor () -> DigestInputs?) {
        self.source = source
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.check()
                do {
                    try await self.sleeper.sleep(for: self.interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops the due check.
    func stop() {
        task?.cancel()
        task = nil
        source = nil
    }

    /// One due check against the source ``start(source:)`` was given.
    @discardableResult
    func check() -> DigestReport? {
        guard let source else { return nil }
        return check(source: source)
    }

    /// One due check. The seam the tests drive.
    /// - Parameter source: What the current session holds, or `nil`.
    /// - Returns: The digest that was delivered, or `nil` when nothing was.
    @discardableResult
    func check(source: @MainActor () -> DigestInputs?) -> DigestReport? {
        let moment = now()
        expireCard(at: moment)
        // Cheapest possible answer for the overwhelmingly common case: with the feature off a tick
        // costs one `Bool` read, and any card left over from a schedule the user just switched off
        // goes with it.
        guard settings.digest.isEnabled else {
            report = nil
            return nil
        }
        guard let window = settings.digest.window(
            now: moment,
            lastDeliveredAt: settings.digestLastDeliveredAt,
            calendar: calendar
        ) else { return nil }
        guard let inputs = source() else { return nil }
        return deliver(window: window, inputs: inputs, at: moment)
    }

    /// Hides the card. The digest itself is not re-delivered — that is a once-a-day event.
    func dismiss() {
        report = nil
    }

    /// Forgets what this Mac has delivered. Called from "Sign out & erase local data".
    ///
    /// The *schedule* is a setting and stays; the delivery date and the card name pull requests of
    /// the account that is leaving, exactly as ``AutoDelegationStore/reset()`` argues about the
    /// ledger.
    func reset() {
        report = nil
        settings.digestLastDeliveredAt = nil
    }

    // MARK: - Delivering

    private func deliver(
        window: DigestWindow,
        inputs: DigestInputs,
        at moment: Date
    ) -> DigestReport? {
        let built = DigestReport.make(
            pullRequests: inputs.pullRequests,
            issues: inputs.issues,
            parkedReviewCount: inputs.parkedReviewCount,
            windowStart: window.start,
            now: moment
        )
        // Recorded whether or not there was anything to say. "Nothing came in overnight" is a
        // *successful* digest: a Mac with a quiet inbox must not go on re-checking every minute for
        // the rest of the day, and the next window has to start here rather than at the last
        // interesting morning.
        settings.digestLastDeliveredAt = moment
        guard !built.isEmpty else {
            report = nil
            return nil
        }
        report = built
        if let payload = NotificationManager.payload(
            forDigest: built,
            dayStamp: AutoDelegationLedger.dayStamp(for: moment, timeZone: calendar.timeZone)
        ) {
            notify(payload)
        }
        return built
    }

    /// Drops a card that belongs to a previous day.
    ///
    /// This is the "disappears by itself after the day" half: the card is not a permanent piece of
    /// inbox chrome, and a digest still sitting above the list the next afternoon would be reporting
    /// on a night two nights ago.
    private func expireCard(at moment: Date) {
        guard let report else { return }
        guard !calendar.isDate(report.generatedAt, inSameDayAs: moment) else { return }
        self.report = nil
    }
}
