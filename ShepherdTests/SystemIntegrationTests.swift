import AppIntents
import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The parts of App Intents and the Spotlight export that can be tested without the frameworks
/// running the app (ADR 0021).
///
/// The split is the same one ADR 0019 made for search and ADR 0018 made for auto-merge: the
/// *decision* is a pure value and is pinned here, while the framework call is a seam with one
/// production implementation and nothing left to assert. Concretely, three things are worth a test
/// and none of them needs Spotlight, Siri or Shortcuts to exist:
///
/// - **What leaves the app.** ``SpotlightItemFields`` is the entire mapping from an inbox row to a
///   Spotlight result, so a field added to it by accident is a failing test rather than a privacy
///   incident.
/// - **When a call is made at all.** ``SpotlightExportPlan`` is the diff, and the property that
///   makes the feature affordable — a sweep that moved an `updatedAt` and nothing else costs no
///   framework call — is exactly the kind of thing that regresses silently.
/// - **That the two parameter vocabularies still mirror the `shepherd://` grammar.** The Shortcuts
///   enums restate ADR 0013's tokens, and "somebody added a Settings tab" has to fail here rather
///   than turn into an action that quietly opens the wrong tab.
@MainActor
final class SystemIntegrationTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "shepherd.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removeSuite(named: suiteName)
    }

    // MARK: - Doubles

    /// A stand-in for `CSSearchableIndex.default()` that records what it was asked to do.
    ///
    /// An `actor` because the seam is `Sendable` and its methods are called from a task the
    /// exporter owns; it is also the only way to count calls without a captured `var`.
    private actor FakeSpotlightIndex: SpotlightIndexing {
        private(set) var batches: [[SpotlightItemFields]] = []
        private(set) var deletions: [[String]] = []
        private(set) var domainDeletions = 0

        private let accepts: Bool
        /// Overrides `accepts` for domain deletions only, so a test can fail the one call that
        /// keeps "off means gone" true while batches still succeed.
        private var domainDeletionAccepts: Bool?

        init(accepts: Bool = true) {
            self.accepts = accepts
        }

        func setDomainDeletionAccepts(_ value: Bool) {
            domainDeletionAccepts = value
        }

        /// Every identifier written, in the order the batches were written.
        var indexedIdentifiers: [String] {
            batches.flatMap { $0.map(\.uniqueIdentifier) }
        }

        func index(_ items: [SpotlightItemFields]) async -> Bool {
            batches.append(items)
            return accepts
        }

        func delete(identifiers: [String]) async -> Bool {
            deletions.append(identifiers)
            return accepts
        }

        func deleteDomain() async -> Bool {
            domainDeletions += 1
            return domainDeletionAccepts ?? accepts
        }
    }

    // MARK: - Fixtures

    private func summary(
        id: String,
        number: Int,
        title: String,
        login: String = "octocat",
        kind: ActorKind = .human,
        labels: [String] = [],
        checks: CheckRollup.State? = .success,
        updatedAt: TimeInterval = 0
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: login, kind: kind),
            updatedAt: clock.addingTimeInterval(updatedAt),
            createdAt: clock,
            headRefName: "feature/\(number)",
            headRefOid: "head-\(number)",
            baseRefName: "main",
            checkRollup: checks.map { CheckRollup(state: $0, total: 1, successCount: 1) },
            myRelation: [.reviewRequested],
            labels: labels,
            mergeable: .mergeable
        )
    }

    private var rows: [PullRequestSummary] {
        [
            summary(id: "PR_1", number: 1, title: "Fix the flaky login test", labels: ["bug"]),
            summary(id: "PR_2", number: 2, title: "Bump GRDB", labels: ["automerge"]),
            summary(id: "PR_3", number: 3, title: "A dark theme for the sidebar"),
        ]
    }

    private func makeSettings(spotlightExportEnabled: Bool = true) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.spotlightExportEnabled = spotlightExportEnabled
        return settings
    }

    /// Exports one set of rows and waits for the pass, which is what `passTask` is for.
    private func export(_ indexer: SpotlightIndexer, rows: [PullRequestSummary]) async {
        indexer.considerExporting(rows: rows)
        guard let task = indexer.passTask else { return }
        await task.value
    }

    // MARK: - What leaves the app

    func testTheItemCarriesTheTitleTheIdentityAndNothingWrittenInConfidence() {
        let row = summary(
            id: "PR_9",
            number: 128,
            title: "Retry the auth suite",
            login: "claude[bot]",
            kind: .agent(
                AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
            ),
            labels: ["bug", "automerge"]
        )

        let fields = SpotlightItemFields(pullRequest: row)

        XCTAssertEqual(fields.uniqueIdentifier, "PR_9", "the node id, not the slug")
        XCTAssertEqual(fields.title, "Retry the auth suite")
        XCTAssertEqual(
            fields.contentDescription,
            "schnaq/review#128 · claude[bot] · All checks passed"
        )
        // Labels first, then the agent's name, then the repository — a fixed order, so two
        // identical inbox states produce identical items and the diff sees no change.
        XCTAssertEqual(
            fields.keywords,
            ["bug", "automerge", "Claude Code", "schnaq", "review"]
        )
    }

    func testKeywordsSkipEmptyLabelsAndDoNotRepeatThemselves() {
        // A label equal to the repository name is not two keywords, and a whitespace-only label is
        // not a keyword at all.
        let row = summary(id: "PR_1", number: 1, title: "T", labels: ["review", "  ", "review"])
        XCTAssertEqual(
            SpotlightItemFields(pullRequest: row).keywords,
            ["review", "schnaq"]
        )
    }

    func testEveryCheckStateHasItsOwnSentenceIncludingNone() {
        XCTAssertEqual(
            PullRequestMetadataText.checkState(CheckRollup(state: .success)),
            "All checks passed"
        )
        XCTAssertEqual(
            PullRequestMetadataText.checkState(CheckRollup(state: .failure)),
            "Checks failing"
        )
        XCTAssertEqual(
            PullRequestMetadataText.checkState(CheckRollup(state: .pending)),
            "Checks running"
        )
        XCTAssertEqual(
            PullRequestMetadataText.checkState(CheckRollup(state: CheckRollup.State.none)),
            "No checks"
        )
        // A pull request whose head commit has no checks at all says so rather than trailing off.
        XCTAssertEqual(PullRequestMetadataText.checkState(nil), "No checks")
    }

    // MARK: - The diff

    func testAFirstPlanExportsEverythingInIdentifierOrder() {
        let plan = SpotlightExportPlan.make(rows: rows.reversed(), exported: [:])
        XCTAssertEqual(plan.upserts.map(\.uniqueIdentifier), ["PR_1", "PR_2", "PR_3"])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertFalse(plan.isEmpty)
    }

    func testASweepThatChangedNothingVisibleProducesAnEmptyPlan() {
        let exported = SpotlightExportPlan.desiredFields(rows: rows)
        // The same rows with a moved `updatedAt`: the inbox observation fires on every write, and
        // almost none of those writes change a title, an author, a label or a CI state. This is
        // the property that keeps the feature from handing Core Spotlight the whole inbox every
        // couple of minutes forever.
        let touched = rows.map { row in
            summary(
                id: row.id,
                number: row.number,
                title: row.title,
                labels: row.labels,
                updatedAt: 900
            )
        }
        let plan = SpotlightExportPlan.make(rows: touched, exported: exported)
        XCTAssertTrue(plan.isEmpty)
    }

    func testOnlyTheChangedPullRequestIsReExported() {
        let exported = SpotlightExportPlan.desiredFields(rows: rows)
        var changed = rows
        changed[1] = summary(id: "PR_2", number: 2, title: "Bump GRDB to 7.10", labels: ["automerge"])

        let plan = SpotlightExportPlan.make(rows: changed, exported: exported)

        XCTAssertEqual(plan.upserts.map(\.uniqueIdentifier), ["PR_2"])
        XCTAssertEqual(plan.upserts.first?.title, "Bump GRDB to 7.10")
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testAPullRequestThatLeftTheInboxIsDeletedRatherThanLeftToExpire() {
        let exported = SpotlightExportPlan.desiredFields(rows: rows)
        let plan = SpotlightExportPlan.make(rows: [rows[0], rows[2]], exported: exported)
        XCTAssertTrue(plan.upserts.isEmpty)
        XCTAssertEqual(plan.deletions, ["PR_2"])
    }

    func testAChangedRowAndADepartedRowTravelInOnePlan() {
        let exported = SpotlightExportPlan.desiredFields(rows: rows)
        let renamed = summary(id: "PR_1", number: 1, title: "Fix the login test", labels: ["bug"])
        let plan = SpotlightExportPlan.make(rows: [renamed, rows[1]], exported: exported)
        XCTAssertEqual(plan.upserts.map(\.uniqueIdentifier), ["PR_1"])
        XCTAssertEqual(plan.deletions, ["PR_3"])
    }

    // MARK: - The exporter

    func testAFirstExportWritesEveryPullRequestOnce() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)

        await export(indexer, rows: rows)

        let identifiers = await index.indexedIdentifiers
        XCTAssertEqual(identifiers, ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(indexer.status.itemCount, 3)
        XCTAssertFalse(indexer.status.isExporting)
    }

    func testASecondSweepOverUnchangedRowsMakesNoFrameworkCallAtAll() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)

        await export(indexer, rows: rows)
        await export(indexer, rows: rows)

        let batches = await index.batches.count
        XCTAssertEqual(batches, 1, "the second sweep had nothing to say")
    }

    func testARowThatOnlyChangedItsTitleCostsOneItem() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        var changed = rows
        changed[0] = summary(id: "PR_1", number: 1, title: "Fix the login test", labels: ["bug"])
        await export(indexer, rows: changed)

        let batches = await index.batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.last?.map(\.uniqueIdentifier), ["PR_1"])
        XCTAssertEqual(indexer.status.itemCount, 3)
    }

    func testAPrunedRowIsDeletedFromSpotlightAndFromTheCount() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        await export(indexer, rows: [rows[0], rows[1]])

        let deletions = await index.deletions
        XCTAssertEqual(deletions, [["PR_3"]])
        XCTAssertEqual(indexer.status.itemCount, 2)
    }

    func testARejectedBatchIsRetriedOnTheNextSweep() async {
        // The baseline is only advanced for a batch the framework accepted. Recording an item as
        // exported before the call succeeded would make one transient failure permanent, because
        // nothing would ever mark the item as needing an export again.
        let index = FakeSpotlightIndex(accepts: false)
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)

        await export(indexer, rows: rows)
        await export(indexer, rows: rows)

        let batches = await index.batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.last?.map(\.uniqueIdentifier), ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(indexer.status.itemCount, 0)
    }

    func testTheToggleOffExportsNothing() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(
            settings: makeSettings(spotlightExportEnabled: false),
            index: index
        )

        await export(indexer, rows: rows)

        let batches = await index.batches.count
        XCTAssertEqual(batches, 0)
        XCTAssertFalse(indexer.status.isEnabled)
    }

    func testSwitchingTheToggleOffDeletesTheWholeDomain() async {
        let index = FakeSpotlightIndex()
        let settings = makeSettings()
        let indexer = SpotlightIndexer(settings: settings, index: index)
        await export(indexer, rows: rows)

        settings.spotlightExportEnabled = false
        await indexer.disable()

        let domainDeletions = await index.domainDeletions
        XCTAssertEqual(domainDeletions, 1, "one domain deletion, not a list of identifiers")
        XCTAssertFalse(indexer.status.isEnabled)
        XCTAssertEqual(indexer.status.itemCount, 0)
    }

    func testSignOutDeletesTheWholeDomainAndForgetsWhatWasExported() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        indexer.reset()
        if let task = indexer.domainDeletionTask {
            await task.value
        }

        let domainDeletions = await index.domainDeletions
        XCTAssertEqual(domainDeletions, 1)
        XCTAssertEqual(indexer.status.itemCount, 0)

        // The baseline is gone with it, so the next account's first sweep re-writes everything
        // rather than believing the previous account's export.
        await export(indexer, rows: rows)
        let identifiers = await index.indexedIdentifiers
        XCTAssertEqual(identifiers, ["PR_1", "PR_2", "PR_3", "PR_1", "PR_2", "PR_3"])
    }

    func testAFailedDomainDeletionIsRetriedOnTheNextSweepAndBlocksTheExportUntilItSucceeds() async {
        let index = FakeSpotlightIndex()
        let settings = makeSettings()
        let indexer = SpotlightIndexer(settings: settings, index: index)
        await export(indexer, rows: rows)

        await index.setDomainDeletionAccepts(false)
        settings.spotlightExportEnabled = false
        await indexer.disable()
        XCTAssertTrue(indexer.status.domainDeletionPending, "the framework said no, and that is remembered")

        // Back on before the removal ever succeeded. The rows must wait: exporting into a domain
        // that is about to be deleted would lose them, and exporting into one that still holds the
        // old items would not be the fresh start the toggle promises either.
        await index.setDomainDeletionAccepts(true)
        settings.spotlightExportEnabled = true
        indexer.considerExporting(rows: rows)
        XCTAssertNil(indexer.passTask, "no export while the deletion is unconfirmed")
        if let task = indexer.domainDeletionTask {
            await task.value
        }
        if let task = indexer.passTask {
            await task.value
        }

        let domainDeletions = await index.domainDeletions
        XCTAssertEqual(domainDeletions, 2, "asked once by the toggle, once more by the sweep")
        XCTAssertFalse(indexer.status.domainDeletionPending)
        let identifiers = await index.indexedIdentifiers
        XCTAssertEqual(identifiers, ["PR_1", "PR_2", "PR_3", "PR_1", "PR_2", "PR_3"], "exported after the deletion, not before")
        XCTAssertEqual(indexer.status.itemCount, 3)
    }

    func testRowsArrivingDuringASignOutDeletionAreExportedOnlyAfterIt() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        // Same main-actor turn: the deletion task exists but has not run, and the next account's
        // first sweep is already here.
        indexer.reset()
        indexer.considerExporting(rows: rows)
        XCTAssertNil(indexer.passTask, "the sweep waits for the domain to be empty")
        if let task = indexer.domainDeletionTask {
            await task.value
        }
        if let task = indexer.passTask {
            await task.value
        }

        let domainDeletions = await index.domainDeletions
        XCTAssertEqual(domainDeletions, 1)
        let identifiers = await index.indexedIdentifiers
        XCTAssertEqual(identifiers, ["PR_1", "PR_2", "PR_3", "PR_1", "PR_2", "PR_3"])
    }

    // MARK: - Resolving a system-supplied identifier

    func testASpotlightIdentifierResolvesToItsCachedRow() {
        XCTAssertEqual(
            PullRequestIdentifierLookup.row(nodeID: "PR_2", in: rows)?.number,
            2
        )
        XCTAssertNil(PullRequestIdentifierLookup.row(nodeID: "PR_gone", in: rows))
        XCTAssertNil(PullRequestIdentifierLookup.row(nodeID: "PR_1", in: []))
    }

    // MARK: - The parameter vocabularies mirror ADR 0013's grammar

    func testEveryInboxFilterOptionIsADeepLinkToken() {
        XCTAssertEqual(
            Set(InboxFilterOption.allCases.map(\.rawValue)),
            Set(InboxDeepLinkFilter.keywordTokens),
            "the Shortcuts parameter and the shepherd:// grammar are the same vocabulary"
        )
        for option in InboxFilterOption.allCases {
            XCTAssertEqual(
                option.deepLinkFilter,
                InboxDeepLinkFilter(token: option.rawValue),
                "\(option.rawValue) must resolve to its own filter"
            )
            XCTAssertNotNil(option.deepLinkFilter)
        }
        // And the mapping is the obvious one, not merely a non-nil one.
        XCTAssertEqual(InboxFilterOption.needsMyReview.deepLinkFilter, .needsMyReview)
        XCTAssertEqual(InboxFilterOption.mine.deepLinkFilter, .myPullRequests)
        XCTAssertEqual(InboxFilterOption.approvedByMe.deepLinkFilter, .approvedByMe)
    }

    func testEverySettingsTabHasAShortcutsOption() {
        XCTAssertEqual(
            Set(SettingsTabOption.allCases.map(\.rawValue)),
            Set(SettingsDeepLinkTab.allCases.map(\.token)),
            "a Settings tab added to the grammar needs an option here, or the action opens Account"
        )
        for option in SettingsTabOption.allCases {
            XCTAssertEqual(option.deepLinkTab?.token, option.rawValue)
        }
    }

    func testEveryOptionHasADisplayNameForTheShortcutsPicker() {
        // A missing case display representation is a case that shows up as its raw value — or not
        // at all — in the Shortcuts picker, which is invisible until a user goes looking.
        for option in InboxFilterOption.allCases {
            XCTAssertNotNil(InboxFilterOption.caseDisplayRepresentations[option])
        }
        for option in SettingsTabOption.allCases {
            XCTAssertNotNil(SettingsTabOption.caseDisplayRepresentations[option])
        }
    }

    // MARK: - The entity

    func testTheEntityCarriesIdentityAndMetadataOnly() {
        let row = summary(
            id: "PR_9",
            number: 128,
            title: "Retry the auth suite",
            login: "claude[bot]",
            kind: .agent(
                AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
            ),
            checks: .failure
        )

        let entity = PullRequestEntity(pullRequest: row)

        XCTAssertEqual(entity.id, "PR_9")
        XCTAssertEqual(entity.slug, "schnaq/review#128")
        XCTAssertEqual(entity.title, "Retry the auth suite")
        XCTAssertEqual(entity.author, "claude[bot]")
        XCTAssertEqual(entity.checks, "Checks failing")
        // The provenance label is ADR 0008's one definition, so a shortcut that groups by it
        // groups the way the inbox's sections do.
        XCTAssertEqual(entity.provenance, "Claude Code")
    }

    func testAHumanAuthoredPullRequestSaysSoRatherThanNamingNoAgent() {
        let entity = PullRequestEntity(pullRequest: summary(id: "PR_1", number: 1, title: "T"))
        XCTAssertEqual(entity.provenance, "People")
    }

    // MARK: - Siri and Apple Intelligence (ADR 0021's 2026-09-22 amendment)

    func testASpotlightItemNamesItsPullRequestEntity() {
        let fields = SpotlightItemFields(pullRequest: summary(id: "PR_9", number: 9, title: "T"))
        XCTAssertEqual(fields.entity.id, "PR_9", "the entity is the item's own pull request")
        XCTAssertEqual(fields.entity.title, "T")
    }

    func testReindexingSomeIdentifiersWritesOnlyThoseAgain() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        indexer.reindex(["PR_2", "PR_GONE"], rows: rows)
        if let task = indexer.passTask { await task.value }

        let batches = await index.batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.last?.map(\.uniqueIdentifier), ["PR_2"], "a row that left the inbox is not written back")
        XCTAssertEqual(indexer.status.itemCount, 3)
    }

    func testReindexingKeepsTheDeletionOwedForARowThatLeft() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        indexer.reindex(nil, rows: [rows[0], rows[1]])
        if let task = indexer.passTask { await task.value }

        let deletions = await index.deletions
        XCTAssertEqual(deletions.flatMap { $0 }, ["PR_3"], "the row that left is still deleted")
        XCTAssertEqual(indexer.status.itemCount, 2)
    }

    func testReindexingEverythingWritesEveryRowAgain() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(), index: index)
        await export(indexer, rows: rows)

        indexer.reindex(nil, rows: rows)
        if let task = indexer.passTask { await task.value }

        let identifiers = await index.indexedIdentifiers
        XCTAssertEqual(identifiers, ["PR_1", "PR_2", "PR_3", "PR_1", "PR_2", "PR_3"])
    }

    func testReindexingWithTheExportOffWritesNothing() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(settings: makeSettings(spotlightExportEnabled: false), index: index)

        indexer.reindex(nil, rows: rows)
        if let task = indexer.passTask { await task.value }

        let batches = await index.batches
        XCTAssertTrue(batches.isEmpty)
    }

    func testAReviewRequestNotificationCarriesItsPullRequest() throws {
        let row = summary(id: "PR_4", number: 4, title: "Retry uploads")
        let payload = try XCTUnwrap(
            NotificationManager.payload(for: .newReviewRequest(row), settings: makeSettings())
        )
        XCTAssertEqual(payload.pullRequestIDs, ["PR_4"])
        XCTAssertEqual(
            payload.entityIdentifiers,
            [EntityIdentifier(for: PullRequestEntity.self, identifier: "PR_4")]
        )
    }

    func testTheDigestNotificationIsAboutNoSinglePullRequest() {
        XCTAssertEqual(NotificationPayload(identifier: "d", title: "t", body: "b").pullRequestIDs, [])
    }
}
