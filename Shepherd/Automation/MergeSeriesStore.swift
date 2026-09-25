import Foundation
import Observation
import ShepherdCore

/// Where the running merge series live between launches (ADR 0041).
///
/// `UserDefaults`, for ``MergeWhenGreenStore``'s reasons, which apply word for word: a series
/// must survive a relaunch (five merges can take an afternoon of CI), it carries no secret, and it
/// records a decision *this user on this Mac* made by pressing Start, so it does not travel in the
/// settings document (ADR 0014). A second Mac cannot know what was decided here.
///
/// The store is dumb on purpose: it holds and persists values. Every state change is made by
/// ``ShepherdCore/MergeSeriesPolicy`` or by the mutating methods on ``ShepherdCore/MergeSeries``,
/// and ``MergeSeriesCoordinator`` decides when to call them.
///
/// Cleared on sign-out (``reset()``): the series name the leaving account's pull requests.
@MainActor
@Observable
final class MergeSeriesStore {
    private let defaults: UserDefaults
    private let key: String

    /// Every series on this Mac, oldest first. A finished series is kept only until it has been
    /// announced (``MergeSeriesCoordinator``), then pruned.
    private(set) var list: MergeSeriesList

    /// Creates a store.
    /// - Parameters:
    ///   - defaults: The backing store. Injectable for tests.
    ///   - key: The defaults key. Injectable so two stores can share one suite in tests.
    init(defaults: UserDefaults = .standard, key: String = "automation.mergeSeries") {
        self.defaults = defaults
        self.key = key
        // Tolerant like the other automation stores: a list from another build falls back to an
        // empty one instead of costing the launch.
        self.list = AppSettings.readJSON(defaults, key, default: MergeSeriesList())
    }

    /// The series, oldest first.
    var series: [MergeSeries] { list.series }

    /// Whether any series is still unfinished.
    var hasRunningSeries: Bool { list.series.contains { !$0.isFinished } }

    /// The unfinished series a pull request belongs to, if any.
    /// - Parameter prID: The pull request's node id.
    func series(containing prID: String) -> MergeSeries? {
        list.series(containing: prID)
    }

    /// Stores a series: replaces the one with the same id, or appends it.
    /// - Parameter series: The series as it stands now.
    func save(_ series: MergeSeries) {
        if let index = list.series.firstIndex(where: { $0.id == series.id }) {
            list.series[index] = series
        } else {
            list.series.append(series)
        }
        persist()
    }

    /// Stores several series in one write — what Start does, one per repository.
    /// - Parameter series: The new series.
    func add(_ series: [MergeSeries]) {
        guard !series.isEmpty else { return }
        list.series.append(contentsOf: series)
        persist()
    }

    /// Changes one series in place, and persists only when something changed.
    /// - Parameters:
    ///   - id: The series id.
    ///   - change: The mutation; returns whether it changed anything.
    /// - Returns: The series after the change, or `nil` when no series has this id.
    @discardableResult
    func update(_ id: String, _ change: (inout MergeSeries) -> Bool) -> MergeSeries? {
        guard let index = list.series.firstIndex(where: { $0.id == id }) else { return nil }
        if change(&list.series[index]) { persist() }
        return list.series[index]
    }

    /// Forgets one series — after its summary was announced, or when it was never announceable.
    /// - Parameter id: The series id.
    func remove(_ id: String) {
        guard list.series.contains(where: { $0.id == id }) else { return }
        list.series.removeAll { $0.id == id }
        persist()
    }

    /// Forgets everything. Called from "Sign out & erase local data".
    func reset() {
        list = MergeSeriesList()
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
