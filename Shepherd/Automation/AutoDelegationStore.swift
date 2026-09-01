import Foundation
import Observation
import ShepherdCore

/// Where the auto-delegation ledger lives between launches (ADR 0016).
///
/// `UserDefaults`, deliberately, and this is the one interesting choice in the file:
///
/// - It must survive a relaunch, because forgetting it means re-delegating work the agent has
///   already been sent. The database would too — but it is *erased* on sign-out and on "erase
///   local data", which is exactly the moment the account's pull requests stop mattering, so
///   the ledger is cleared there by hand instead (see ``reset()``).
/// - It carries no secret and no content: node ids, commit SHAs, a date and a counter. Nothing
///   here would be a leak in a plist that is not already in the inbox (ADR 0006's rule is about
///   *secrets*, and those stay in the Keychain).
/// - It is not a setting, so it does **not** travel in the settings document (ADR 0014): a day
///   counter and a per-Mac "already done this" set are the state of one machine's automation,
///   and sharing them would make one Mac's budget silently cap another's.
@MainActor
@Observable
final class AutoDelegationStore {
    private let defaults: UserDefaults
    private let key: String

    /// What automatic delegation has already done on this Mac.
    private(set) var ledger: AutoDelegationLedger

    /// Creates a store.
    /// - Parameters:
    ///   - defaults: The backing store. Injectable for tests.
    ///   - key: The defaults key. Injectable so two stores can share one suite in tests.
    init(defaults: UserDefaults = .standard, key: String = "delegation.autoLedger") {
        self.defaults = defaults
        self.key = key
        // The same tolerant Codable↔UserDefaults pair ``AppSettings`` stores its JSON blobs
        // with: a ledger from an older or newer build falls back to an empty one instead of
        // costing the launch.
        self.ledger = AppSettings.readJSON(defaults, key, default: AutoDelegationLedger())
    }

    /// How many automatic delegations already started today.
    /// - Parameters:
    ///   - now: The clock.
    ///   - timeZone: The time zone that decides where the day boundary is.
    func startsToday(now: Date = Date(), timeZone: TimeZone = .current) -> Int {
        ledger.starts(onDayOf: now, timeZone: timeZone)
    }

    /// Whether a rule already fired for this pull request at this head commit.
    /// - Parameter fingerprint: The pair to look for.
    func hasHandled(_ fingerprint: AutoDelegationLedger.Fingerprint) -> Bool {
        ledger.hasHandled(fingerprint)
    }

    /// Records a start — **before** the delegation is actually launched.
    ///
    /// The order matters and is the safe one: a crash between recording and launching costs one
    /// automatic run, while the reverse order would risk starting the same run again on every
    /// relaunch for as long as the pull request stays red.
    /// - Parameters:
    ///   - plan: What is about to be started.
    ///   - now: The clock.
    ///   - timeZone: The time zone that decides where the day boundary is.
    func record(_ plan: AutoDelegationPlan, now: Date = Date(), timeZone: TimeZone = .current) {
        ledger = ledger.recording(plan.fingerprint, at: now, timeZone: timeZone)
        persist()
    }

    /// Forgets everything. Called from "Sign out & erase local data".
    func reset() {
        ledger = AutoDelegationLedger()
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        AppSettings.writeJSON(defaults, ledger, key)
    }
}
