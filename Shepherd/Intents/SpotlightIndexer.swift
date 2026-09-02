import CoreSpotlight
import Foundation
import Observation
import ShepherdCore
import UniformTypeIdentifiers

/// The three Core Spotlight calls the export makes, as a seam.
///
/// A protocol for the usual two reasons. The first is testability: `CSSearchableIndex` writes into
/// the *system* index, so a unit test that used the real one would either fail on a runner with no
/// Spotlight or leave a hundred fixture pull requests in a developer's ⌘Space results. The second
/// is isolation: every implementation is `Sendable` and every method is `nonisolated async`, which
/// is what lets ``SpotlightIndexer`` — a `@MainActor` type — hand a batch over and have the
/// framework work happen off the main actor without any `CSSearchableItem` ever crossing an
/// isolation boundary (see ``CoreSpotlightIndex``).
protocol SpotlightIndexing: Sendable {
    /// Writes or replaces items, keyed by their unique identifier.
    /// - Parameter items: The batch.
    /// - Returns: Whether Spotlight accepted it. `false` means the caller must not remember these
    ///   items as exported, or the failure would be permanent.
    func index(_ items: [SpotlightItemFields]) async -> Bool

    /// Removes items by identifier.
    /// - Parameter identifiers: The ids to drop.
    /// - Returns: Whether Spotlight accepted the deletion.
    func delete(identifiers: [String]) async -> Bool

    /// Removes every pull-request item this app ever wrote.
    /// - Returns: Whether Spotlight accepted the deletion.
    func deleteDomain() async -> Bool
}

/// The production implementation: `CSSearchableIndex.default()`.
///
/// A `struct` with no state, so it is `Sendable` and its methods run on the generic executor
/// rather than on the main actor. Each method builds its `CSSearchableItem`s **inside** the
/// continuation closure, from the `Sendable` ``SpotlightItemFields`` it was given, so the
/// non-`Sendable` `NSObject`s exist only within one synchronous scope and are handed straight to a
/// thread-safe framework call. That is deliberate rather than incidental: passing an array of
/// `CSSearchableItem` across an `await` is exactly the shape Swift 6 strict concurrency rejects.
struct CoreSpotlightIndex: SpotlightIndexing {
    func index(_ items: [SpotlightItemFields]) async -> Bool {
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().indexSearchableItems(items.map(\.searchableItem)) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    func delete(identifiers: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: identifiers) { error in
                    continuation.resume(returning: error == nil)
                }
        }
    }

    func deleteDomain() async -> Bool {
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default()
                .deleteSearchableItems(
                    withDomainIdentifiers: [SpotlightExport.domainIdentifier]
                ) { error in
                    continuation.resume(returning: error == nil)
                }
        }
    }
}

extension SpotlightItemFields {
    /// The Core Spotlight object for these fields.
    ///
    /// `contentType: .content` rather than a document or a URL type: a pull request is not a file,
    /// and claiming a file type would invite Spotlight's UI to offer "Reveal in Finder" for
    /// something that has no path.
    ///
    /// `expirationDate = .distantFuture` is load-bearing. Core Spotlight expires items after
    /// **one month** by default, which is a sensible policy for a mail client and precisely wrong
    /// here: Shepherd knows exactly when a pull request stops being interesting — it leaves the
    /// inbox — and deletes the item then (``SpotlightExportPlan/deletions``). Leaving the default
    /// in place would mean long-lived pull requests silently vanishing from Spotlight while still
    /// sitting in the inbox, with nothing in the app to explain it.
    var searchableItem: CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.identifier = uniqueIdentifier
        attributes.title = title
        attributes.contentDescription = contentDescription
        attributes.keywords = keywords
        let item = CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier,
            domainIdentifier: SpotlightExport.domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }
}

/// What the Settings card says about the Spotlight export.
struct SpotlightExportStatus: Equatable, Sendable {
    /// Whether the user has the export switched on.
    var isEnabled = true
    /// Whether a batch is being written right now.
    var isExporting = false
    /// How many pull requests are currently in the system index.
    var itemCount = 0
}

/// Keeps the `pullRequests` Spotlight domain in step with the inbox (ADR 0021).
///
/// The fourth coordinator of the shape ``AutoMergeCoordinator``, ``DigestCoordinator`` and
/// ``SearchIndexCoordinator`` established, and the division of labour is theirs: the decision — what
/// leaves the app and which items have to change — is the pure ``SpotlightExportPlan``, and this
/// type supplies the rows, batches the calls and remembers what it wrote.
///
/// Four things about *when* it runs are decisions rather than mechanics:
///
/// - **The trigger is the rows a sweep wrote**, the same `onInboxRows` callback automatic merging
///   (ADR 0018) and the search index (ADR 0019) run on. Spotlight has to reflect the *content* of
///   the inbox, and that observation is the one place a change to it is reported.
/// - **A sweep that changed nothing costs no framework call at all.** The callback fires on every
///   inbox write, most of which move an `updatedAt` and nothing a Spotlight result shows, so the
///   plan is diffed against the fields last written and an empty plan returns before any task is
///   even started. Without that, Core Spotlight would be handed the entire inbox every couple of
///   minutes, forever.
/// - **It never touches the UI path.** The diff is a dictionary comparison over a few hundred small
///   structs on the main actor; everything after it is a low-priority `Task` that hands `Sendable`
///   values to a `nonisolated` seam, in batches, yielding between them.
/// - **Off means gone.** Switching the toggle off, or signing out, deletes the whole domain rather
///   than letting it decay: an index of the previous account's pull requests, outside the app's own
///   database and outside its control, is not something a switch may leave behind.
///
/// What it deliberately does **not** do is persist what it exported. The map below is memory, so the
/// first pass after a launch re-writes every item — one batched, idempotent call, once — rather
/// than keeping a second on-disk index of the index it already keeps. The failure mode that buys
/// is the important one: a persisted map that disagreed with Spotlight (a restore from backup, a
/// user who reindexed their volume) would leave items missing with nothing to trigger a repair.
@MainActor
@Observable
final class SpotlightIndexer {
    /// How many items go into one `indexSearchableItems` call.
    ///
    /// Fifty. Core Spotlight has no documented per-call ceiling, but a batch is also the unit of
    /// work that is thrown away when a pass is cancelled at sign-out, and each item is a handful of
    /// short strings — so this is small enough to yield often and large enough that a few hundred
    /// pull requests are a handful of calls rather than hundreds.
    static let batchSize = 50

    private let settings: AppSettings
    private let index: any SpotlightIndexing

    /// What Settings shows.
    private(set) var status = SpotlightExportStatus()

    /// The fields last successfully written, keyed by unique identifier.
    ///
    /// The diff's baseline, and it is only ever updated *after* the framework accepted a batch: an
    /// optimistic update would turn one transient failure into a permanently missing item, because
    /// nothing would ever mark it as needing an export again.
    private var exported: [String: SpotlightItemFields] = [:]

    /// The pass that is running, if one is.
    ///
    /// `private(set)` rather than private for the reason ``SearchIndexCoordinator/passTask`` is:
    /// a test awaits a pass instead of polling for its effects. Nothing in the app reads it.
    private(set) var passTask: Task<Void, Never>?
    /// Rows that arrived while a pass was running. One slot, last write wins — an intermediate
    /// state of the inbox is of no interest once a newer one is known.
    private var pendingRows: [PullRequestSummary]?
    /// The domain deletion ``reset()`` started, if one is in flight.
    ///
    /// Held for the same reason ``passTask`` is — a test awaits it rather than polling — and for
    /// no other: nothing in the app reads it, because nothing in the app has anything to do until
    /// the next account's first sweep, which is seconds away at the earliest.
    private(set) var domainDeletionTask: Task<Void, Never>?

    /// Creates an exporter.
    /// - Parameters:
    ///   - settings: Where the toggle lives.
    ///   - index: The Core Spotlight seam. The default is the system index.
    init(settings: AppSettings, index: any SpotlightIndexing = CoreSpotlightIndex()) {
        self.settings = settings
        self.index = index
        self.status.isEnabled = settings.spotlightExportEnabled
    }

    /// Considers the rows a sweep just wrote for export.
    ///
    /// Wired to ``SignedInSession/start(settings:notifications:onEvent:onInboxRows:)`` beside
    /// automatic merging and the search index, so all three see the same rows at the same moment.
    /// Idempotent, as that callback requires.
    /// - Parameter rows: Every inbox row the local database now holds.
    func considerExporting(rows: [PullRequestSummary]) {
        status.isEnabled = settings.spotlightExportEnabled
        guard settings.spotlightExportEnabled else { return }
        guard passTask == nil else {
            pendingRows = rows
            return
        }
        // Cheap enough to do before deciding whether there is anything to do at all: a dictionary
        // of a few hundred small structs, compared field by field. The point of doing it here is
        // that the overwhelmingly common answer is "nothing changed", and that answer must not cost
        // a task, a thread hop or a framework call.
        let plan = SpotlightExportPlan.make(rows: rows, exported: exported)
        guard !plan.isEmpty else { return }
        run(plan: plan)
    }

    /// Switches the export off: cancels the pass and deletes every item Shepherd wrote.
    ///
    /// Called from the toggle and from an applied settings document (ADR 0014), both through
    /// ``AppEnvironment/applySpotlightSetting()`` — one route, exactly as the diagnostics opt-in
    /// (ADR 0017) and the search index (ADR 0019) have one.
    func disable() async {
        passTask?.cancel()
        passTask = nil
        pendingRows = nil
        exported = [:]
        status.isEnabled = false
        status.isExporting = false
        status.itemCount = 0
        _ = await index.deleteDomain()
    }

    /// Drops everything. Called from "Sign out & erase local data".
    ///
    /// The domain deletion is fire-and-forget: `signOutAndErase()` is not going to hold the UI
    /// while the system index catches up, and there is no state left in the app that depends on the
    /// deletion having finished — `exported` is empty either way, so the next account's first pass
    /// re-writes everything it wants regardless.
    func reset() {
        passTask?.cancel()
        passTask = nil
        pendingRows = nil
        exported = [:]
        status = SpotlightExportStatus(isEnabled: settings.spotlightExportEnabled)
        domainDeletionTask = Task(priority: .low) { [index] in
            _ = await index.deleteDomain()
        }
    }

    // MARK: - Passes

    private func run(plan: SpotlightExportPlan) {
        status.isExporting = true
        passTask = Task(priority: .low) { [weak self] in
            guard let self else { return }
            var next: SpotlightExportPlan? = plan
            while let current = next {
                await self.apply(current)
                if Task.isCancelled { break }
                next = self.takePendingPlan()
            }
            self.status.isExporting = false
            self.passTask = nil
        }
    }

    /// The plan for the rows that arrived while the pass was running, if any.
    ///
    /// Diffed here rather than when the rows arrived, against the baseline the pass has since
    /// updated: a plan computed at arrival time would re-write items the running pass had already
    /// written in the meantime.
    private func takePendingPlan() -> SpotlightExportPlan? {
        guard let rows = pendingRows else { return nil }
        pendingRows = nil
        let plan = SpotlightExportPlan.make(rows: rows, exported: exported)
        return plan.isEmpty ? nil : plan
    }

    private func apply(_ plan: SpotlightExportPlan) async {
        if !plan.deletions.isEmpty {
            let didDelete = await index.delete(identifiers: plan.deletions)
            if didDelete {
                for identifier in plan.deletions {
                    exported.removeValue(forKey: identifier)
                }
            }
        }
        var start = 0
        while start < plan.upserts.count {
            guard !Task.isCancelled else { break }
            let batch = Array(
                plan.upserts[start..<min(start + Self.batchSize, plan.upserts.count)]
            )
            start += Self.batchSize
            let didIndex = await index.index(batch)
            // Re-checked *after* the call: cancellation is cooperative, so a batch that was in
            // flight when the toggle went off would otherwise put its items back into the baseline
            // `disable()` had just cleared — and the count on screen with them.
            guard !Task.isCancelled else { break }
            guard didIndex else { continue }
            for fields in batch {
                exported[fields.uniqueIdentifier] = fields
            }
            await Task.yield()
        }
        status.itemCount = exported.count
    }
}
