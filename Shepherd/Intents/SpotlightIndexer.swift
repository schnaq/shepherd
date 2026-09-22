import AppIntents
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
        // The item *is* the pull request Siri and Shortcuts know as a `PullRequestEntity`, so the
        // system can hand the entity to an intent from a Spotlight result (ADR 0021's 2026-09-22
        // amendment). The framework does not read the association back outside a registered app,
        // so no test can observe it; the entity it is built from is tested instead.
        item.associateAppEntity(entity)
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
    /// Whether a domain deletion Shepherd asked for has not been confirmed by the framework yet.
    ///
    /// "Off means gone" is a promise about the *system* index, and the only evidence that it was
    /// kept is `deleteSearchableItems(withDomainIdentifiers:)` answering without an error. Until it
    /// does, the Settings card says so instead of "Off", and every sweep asks again.
    var domainDeletionPending = false
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
    /// The domain deletion in flight, if one is.
    ///
    /// Held for two reasons. A test awaits it rather than polling, as with ``passTask``. And an
    /// export must not start while it runs: the domain is one identifier shared by every item, so a
    /// deletion that lands *after* a fresh batch was written would wipe that batch — the toggle
    /// flipped off and on again, or a sign-out followed by the next account's first sweep. Rows that
    /// arrive meanwhile wait in ``pendingRows`` and are exported by the deletion task itself, once
    /// the framework has confirmed the domain is empty.
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
        // A deletion the framework has not confirmed is asked for again on every sweep, whether the
        // export is on or off: the items of the previous state are in the system index either way,
        // and the sweep is the one heartbeat this coordinator has.
        if status.domainDeletionPending, domainDeletionTask == nil {
            requestDomainDeletion()
        }
        guard settings.spotlightExportEnabled else { return }
        guard passTask == nil, domainDeletionTask == nil else {
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
    /// Writes items again that the system says it lost (`IndexedEntityQuery`, ADR 0021's
    /// 2026-09-22 amendment).
    ///
    /// Forgets what it believes it exported for those ids — every id when `identifiers` is `nil` —
    /// and runs the ordinary plan over today's rows, so a re-donation is the same diff, batch and
    /// failure handling as a sweep, and an id that has left the inbox is not written back.
    /// - Parameters:
    ///   - identifiers: The node ids to write again, or `nil` for all.
    ///   - rows: The inbox as the local database holds it now.
    func reindex(_ identifiers: [String]?, rows: [PullRequestSummary]) {
        if let identifiers {
            for identifier in identifiers { exported[identifier] = nil }
        } else {
            exported = [:]
        }
        considerExporting(rows: rows)
    }

    func disable() async {
        forgetExport()
        status.isEnabled = false
        requestDomainDeletion()
        // Awaited so that the caller's task ends with the framework's answer, not before it; the
        // status is already on screen, so nothing visible waits on this.
        if let task = domainDeletionTask {
            await task.value
        }
    }

    /// Drops everything. Called from "Sign out & erase local data".
    ///
    /// The domain deletion is not awaited: `signOutAndErase()` is not going to hold the UI while
    /// the system index catches up. What it *is* is ordered before the next export — see
    /// ``domainDeletionTask`` — so the next account's first sweep cannot race the previous
    /// account's removal.
    func reset() {
        forgetExport()
        status = SpotlightExportStatus(isEnabled: settings.spotlightExportEnabled)
        requestDomainDeletion()
    }

    /// Stops the pass and drops the baseline, without touching the system index.
    private func forgetExport() {
        passTask?.cancel()
        passTask = nil
        pendingRows = nil
        exported = [:]
        status.isExporting = false
        status.itemCount = 0
    }

    /// Asks the framework to delete the whole domain, once, and remembers whether it agreed.
    ///
    /// The result is not discarded — that was the gap: a transient framework error on the one call
    /// that keeps "off means gone" true would have left the previous account's titles in a
    /// system-wide index with nothing ever asking again, because the baseline had already been
    /// cleared and no later export touches identifiers that departed. Now the pending flag stays up
    /// until a deletion is confirmed, ``considerExporting(rows:)`` retries it on every sweep, and
    /// the Settings card says what is going on. When it succeeds and rows arrived in the meantime —
    /// the toggle went back on, or a new account signed in — they are exported here, after the
    /// deletion, which is the ordering the whole arrangement exists for.
    private func requestDomainDeletion() {
        status.domainDeletionPending = true
        guard domainDeletionTask == nil else { return }
        domainDeletionTask = Task(priority: .low) { [weak self] in
            guard let self else { return }
            let didDelete = await self.index.deleteDomain()
            self.status.domainDeletionPending = !didDelete
            self.domainDeletionTask = nil
            guard didDelete, let rows = self.pendingRows else { return }
            self.pendingRows = nil
            self.considerExporting(rows: rows)
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
