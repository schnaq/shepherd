import Foundation
import Observation
import ShepherdCore
import ShepherdSync

/// Turns sweep events into automatic delegations, when the user asked for that (ADR 0016).
///
/// The division of labour is the same one ``WebhookCoordinator`` uses: the *decision* is a pure
/// function in `ShepherdCore` (``AutoDelegationPolicy``), and this type only supplies the inputs,
/// reserves the slot in the persistent ledger, and tells the user. It never starts a delegation
/// itself — it hands a plan back to ``AppEnvironment``, which starts one through the same
/// ``DelegationCenter`` a button press goes through, so the one-run-per-pull-request rule, the
/// worktree isolation, the turn/budget caps and the "never push" guarantee are the *same* code
/// (ADR 0011). There is deliberately no path here that approves, merges, pushes or submits
/// anything.
@MainActor
@Observable
final class AutoDelegationCoordinator {
    private let settings: AppSettings
    private let delegation: DelegationCenter
    private let store: AutoDelegationStore
    private let now: @MainActor () -> Date
    private let timeZone: TimeZone
    private let isConfigured: @MainActor (RepoRef) -> Bool
    private let notify: @MainActor (NotificationPayload) -> Void

    /// The last decision the coordinator made, for the Settings status line and for tests.
    private(set) var lastDecision: AutoDelegationDecision?

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: Where the rules live.
    ///   - delegation: The delegation centre, asked what is already running.
    ///   - store: The persistent ledger.
    ///   - now: The clock. Injectable so the day-boundary behaviour is testable.
    ///   - timeZone: The time zone that decides where the day boundary is.
    ///   - isConfigured: Whether a delegation for a repository could run at all — an agent CLI
    ///     was found and a local clone is configured. Injectable so tests need neither.
    ///   - notify: Where a notice goes. A closure rather than the ``NotificationManager`` itself
    ///     so the decision logic can be tested without a notification centre.
    init(
        settings: AppSettings,
        delegation: DelegationCenter,
        store: AutoDelegationStore,
        now: @escaping @MainActor () -> Date = { Date() },
        timeZone: TimeZone = .current,
        isConfigured: (@MainActor (RepoRef) -> Bool)? = nil,
        notify: @escaping @MainActor (NotificationPayload) -> Void = { _ in }
    ) {
        self.settings = settings
        self.delegation = delegation
        self.store = store
        self.now = now
        self.timeZone = timeZone
        self.isConfigured = isConfigured ?? { [settings] repo in
            guard settings.localCheckoutURL(for: repo) != nil else { return false }
            return AgentCLILocator.locate(configuration: settings.agentCLI) != nil
        }
        self.notify = notify
    }

    // MARK: - Status, for Settings

    /// How many automatic delegations started today.
    var startsToday: Int { store.startsToday(now: now(), timeZone: timeZone) }

    /// Today's budget.
    var dailyCap: Int { settings.autoDelegation.dailyCap }

    /// How many automatic delegations are running right now.
    var runningCount: Int { delegation.runningAutomaticCount }

    // MARK: - Deciding

    /// Considers one sync event.
    ///
    /// When the answer is "start", the ledger is written **here**, before the caller launches
    /// anything: reserving the slot first is what makes the dedup honest if the launch then fails
    /// (see ``AutoDelegationStore/record(_:now:timeZone:)``).
    /// - Parameter event: The event the sync engine emitted.
    /// - Returns: The delegation to start, or `nil` when nothing should happen.
    func plan(for event: SyncEvent) -> AutoDelegationPlan? {
        guard let signal = AutoDelegationCoordinator.signal(for: event) else { return nil }
        return plan(for: signal)
    }

    /// Considers one signal. The seam the tests drive.
    /// - Parameter signal: What the sweep noticed.
    /// - Returns: The delegation to start, or `nil`.
    func plan(for signal: AutoDelegationSignal) -> AutoDelegationPlan? {
        // Cheapest possible answer for the overwhelmingly common case: with the feature off, an
        // event costs one Bool read and nothing else — no locator, no file system, no ledger.
        guard settings.autoDelegation.isArmed(signal.trigger) else { return nil }

        let context = AutoDelegationContext(
            rules: settings.autoDelegation,
            isConfigured: isConfigured(signal.pullRequest.repo),
            hasRunningDelegation: delegation.isRunning(prID: signal.pullRequest.id),
            runningAutomaticCount: delegation.runningAutomaticCount,
            ledger: store.ledger,
            now: now(),
            timeZone: timeZone
        )
        let decision = AutoDelegationPolicy.decide(signal, context: context)
        lastDecision = decision

        switch decision {
        case .skip(let reason):
            // Only the caps are worth interrupting the user for: they mean a rule *would* have
            // fired. "Not a transition", "already handled" and friends happen constantly and are
            // not news.
            if reason.isCap {
                announce(
                    NotificationManager.payload(
                        forSkipped: signal,
                        reason: reason,
                        rules: settings.autoDelegation
                    )
                )
            }
            return nil

        case .start(let plan):
            store.record(plan, now: now(), timeZone: timeZone)
            announce(
                NotificationManager.payload(
                    forAutoDelegated: plan,
                    agent: settings.agentCLI.kind.displayName
                )
            )
            return plan
        }
    }

    /// Forgets the ledger. Called from "Sign out & erase local data".
    func reset() {
        store.reset()
        lastDecision = nil
    }

    // MARK: - Mapping

    /// The signal a sync event amounts to, if any.
    ///
    /// Only the two `…OnOwnPR` events carry a *transition*, which is the only thing a rule may
    /// act on. ``ShepherdSync/SyncEvent/prUpdated(_:)`` deliberately maps to nothing: it fires on
    /// every change of a tracked row, and "something moved" is not a condition.
    /// - Parameter event: The sync event.
    nonisolated static func signal(for event: SyncEvent) -> AutoDelegationSignal? {
        switch event {
        case .checksFailedOnOwnPR(let failure):
            return AutoDelegationSignal(
                trigger: .checksFailed,
                pullRequest: failure.summary,
                isTransition: failure.isTransition
            )
        case .changesRequestedOnOwnPR(let requested):
            return AutoDelegationSignal(
                trigger: .changesRequested,
                pullRequest: requested.summary,
                isTransition: requested.isTransition
            )
        case .newReviewRequest, .prMerged, .prUpdated, .draftConflict, .mutationSent,
             .syncFailed:
            return nil
        }
    }

    private func announce(_ payload: NotificationPayload?) {
        guard let payload else { return }
        notify(payload)
    }
}
