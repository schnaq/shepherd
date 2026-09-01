import Foundation
import Observation
import ShepherdCore

/// Where the auto-merge ledger — which is also the audit log — lives between launches
/// (ADR 0018).
///
/// `UserDefaults`, for the three reasons ``AutoDelegationStore`` gives, and one more:
///
/// - It must survive a relaunch, because forgetting it means queueing a merge Shepherd already
///   queued. The database would survive too, but it is *erased* on sign-out and on "erase local
///   data", which is exactly when the account's pull requests stop mattering — so the ledger is
///   cleared there by hand instead (see ``reset()``).
/// - It carries no secret: node ids, commit SHAs, a slug, a title and a date. Nothing here is
///   not already in the inbox (ADR 0006's rule is about *secrets*, and those stay in the
///   Keychain).
/// - It is not a setting, so it does **not** travel in the settings document (ADR 0014): the
///   rules travel, a per-Mac "already queued that" does not.
/// - And it is the only record of something Shepherd did unattended. That is the extra reason it
///   is one list rather than a dedup set plus a log: the thing the user reads *is* the thing the
///   deduplication reads, so the audit log cannot quietly disagree with what will happen next.
@MainActor
@Observable
final class AutoMergeStore {
    /// How many entries the Automation settings tab lists.
    ///
    /// Ten, not the whole hundred the ledger keeps: the card answers "is this doing what I think
    /// it is doing", which the last ten answer as well as the last hundred would.
    static let displayedEntryCount = 10

    private let defaults: UserDefaults
    private let key: String

    /// What automatic merging has already queued on this Mac.
    private(set) var ledger: AutoMergeLedger

    /// Creates a store.
    /// - Parameters:
    ///   - defaults: The backing store. Injectable for tests.
    ///   - key: The defaults key. Injectable so two stores can share one suite in tests.
    init(defaults: UserDefaults = .standard, key: String = "automation.autoMergeLedger") {
        self.defaults = defaults
        self.key = key
        // The same tolerant Codable↔UserDefaults pair ``AppSettings`` stores its JSON blobs with:
        // a ledger from an older or newer build falls back to an empty one instead of costing the
        // launch.
        self.ledger = AppSettings.readJSON(defaults, key, default: AutoMergeLedger())
    }

    /// Whether a merge was already queued for this pull request at this head commit.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - headRefOid: The head commit.
    func hasQueued(prID: String, headRefOid: String) -> Bool {
        ledger.hasQueued(prID: prID, headRefOid: headRefOid)
    }

    /// The entries the settings card shows, newest first.
    var displayedEntries: [AutoMergeAuditEntry] {
        ledger.recent(limit: AutoMergeStore.displayedEntryCount)
    }

    /// How many merges are on record.
    var entryCount: Int { ledger.entries.count }

    /// Records a queued merge — **before** the outbox row is written.
    ///
    /// The order is ``AutoDelegationStore/record(_:now:timeZone:)``'s, and the trade is the same
    /// one: a crash between recording and enqueueing costs one automatic merge, while the reverse
    /// order would risk queueing the same merge again on every sweep until the pull request
    /// moved.
    /// - Parameter entry: What is about to be queued.
    func record(_ entry: AutoMergeAuditEntry) {
        ledger = ledger.recording(entry)
        persist()
    }

    /// Forgets the log, because the user pressed *Clear*.
    ///
    /// Clearing the log clears the deduplication with it — they are one list — and that is
    /// deliberate rather than a leak: the only pull requests this can affect are ones that are
    /// *still open and still eligible*, which is precisely the case where queueing the merge
    /// again is the right answer. Anything already merged has left the inbox, and anything with a
    /// write still in the outbox is refused by ``ShepherdCore/AutoMergePolicy`` on the other
    /// check.
    func clear() {
        ledger = AutoMergeLedger()
        defaults.removeObject(forKey: key)
    }

    /// Forgets everything. Called from "Sign out & erase local data".
    func reset() {
        clear()
    }

    private func persist() {
        AppSettings.writeJSON(defaults, ledger, key)
    }
}
