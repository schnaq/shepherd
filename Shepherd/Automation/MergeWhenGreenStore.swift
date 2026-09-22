import Foundation
import Observation
import ShepherdCore

/// Where the merges waiting for green live between launches (ADR 0037).
///
/// `UserDefaults`, for ``AutoMergeStore``'s reasons: it must survive a relaunch — a user who
/// pressed *Merge when checks pass* and quit for the evening expects the merge in the morning, not
/// a forgotten click — it carries no secret, and it is not a setting, so it does **not** travel in
/// the settings document (ADR 0014). The last point is stronger here than for the auto-merge
/// ledger: the arm records that *this user, on this Mac* looked at a commit and judged it. A
/// second Mac has no way of knowing that, so it must not merge on the first one's behalf.
///
/// Cleared on sign-out (``reset()``): the arms name the leaving account's pull requests.
@MainActor
@Observable
final class MergeWhenGreenStore {
    private let defaults: UserDefaults
    private let key: String

    /// The merges armed on this Mac.
    private(set) var list: MergeWhenGreenList

    /// Creates a store.
    /// - Parameters:
    ///   - defaults: The backing store. Injectable for tests.
    ///   - key: The defaults key. Injectable so two stores can share one suite in tests.
    init(defaults: UserDefaults = .standard, key: String = "automation.mergeWhenGreen") {
        self.defaults = defaults
        self.key = key
        // The same tolerant Codable↔UserDefaults pair the other stores use: a list from another
        // build falls back to an empty one instead of costing the launch.
        self.list = AppSettings.readJSON(defaults, key, default: MergeWhenGreenList())
    }

    /// The arm for a pull request, if any.
    /// - Parameter prID: The pull request's node id.
    func request(forPullRequestID prID: String) -> MergeWhenGreenRequest? {
        list.request(forPullRequestID: prID)
    }

    /// Whether a merge is armed for this pull request at this head commit.
    func isArmed(pullRequestID prID: String, headRefOid: String) -> Bool {
        list.isArmed(pullRequestID: prID, headRefOid: headRefOid)
    }

    /// Arms a merge. A second arm for the same pull request replaces the first.
    /// - Parameter request: What the user asked for.
    func arm(_ request: MergeWhenGreenRequest) {
        list = list.arming(request)
        persist()
    }

    /// Forgets one pull request's arm — because the user cancelled it, because its merge was just
    /// queued, or because the commit it was about is gone.
    /// - Parameter prID: The pull request's node id.
    func disarm(pullRequestID prID: String) {
        guard list.request(forPullRequestID: prID) != nil else { return }
        list = list.disarming(pullRequestID: prID)
        persist()
    }

    /// Forgets everything. Called from "Sign out & erase local data".
    func reset() {
        list = MergeWhenGreenList()
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        if list.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            AppSettings.writeJSON(defaults, list, key)
        }
    }
}
