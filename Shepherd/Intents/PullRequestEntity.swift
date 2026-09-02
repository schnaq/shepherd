import AppIntents
import Foundation
import ShepherdCore

/// One pull request, as Shortcuts and Siri are allowed to see it (ADR 0021).
///
/// An `AppEntity` is a *typed handle* the system may keep: a shortcut the user builds today stores
/// this entity's `id` and asks for it again next week, and Spotlight and Siri show its
/// `displayRepresentation` in pickers. Two consequences shape the type.
///
/// **It carries metadata and only metadata.** Identity, title, author, CI state, provenance — the
/// same fields ``SpotlightItemFields`` exports and for the same reason: the entity leaves the app.
/// It is handed to Shortcuts, where it can be dropped into any other action — a note, an email, a
/// web request the user built. There is deliberately no description, no diff, no review comment and
/// no draft on it, so "a shortcut that mails my pull-request diffs somewhere" is not something a
/// user can assemble by accident out of Shepherd's own actions.
///
/// **It is a handle, not a snapshot.** ``PullRequestEntityQuery`` re-reads the row from the local
/// database every time the system asks, so a stored shortcut acts on today's state of the pull
/// request rather than on the title it had when the shortcut was built. A pull request that has
/// left the inbox resolves to nothing, and the intent using it says so.
struct PullRequestEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Pull Request")
    }

    /// The query the system uses to resolve and suggest entities.
    ///
    /// Computed rather than a stored `static var`: a mutable static would be global mutable state,
    /// which Swift 6 strict concurrency refuses, and the query is a stateless value anyway.
    static var defaultQuery: PullRequestEntityQuery { PullRequestEntityQuery() }

    /// The pull request's GraphQL node id — Shepherd's primary key everywhere (ADR 0006).
    var id: String

    /// `owner/repo#123`.
    @Property(title: "Pull Request")
    var slug: String

    /// The pull-request title.
    @Property(title: "Title")
    var title: String

    /// The author's GitHub login.
    @Property(title: "Author")
    var author: String

    /// "All checks passed" / "Checks failing" / "Checks running" / "No checks".
    @Property(title: "Checks")
    var checks: String

    /// The agent's name when an agent wrote it, otherwise "People" or "Bots" (ADR 0008).
    ///
    /// ``ShepherdCore/ActorKind/provenanceLabel``, unchanged: the one definition of what a row's
    /// provenance is called, so a shortcut that groups by it groups the way the inbox does.
    @Property(title: "Provenance")
    var provenance: String

    /// Maps an inbox row onto the entity.
    /// - Parameter pullRequest: The row, as the local database holds it.
    init(pullRequest: PullRequestSummary) {
        id = pullRequest.id
        slug = pullRequest.slug
        title = pullRequest.title
        author = pullRequest.author.login
        checks = PullRequestMetadataText.checkState(pullRequest.checkRollup)
        provenance = pullRequest.author.kind.provenanceLabel
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(slug)", subtitle: "\(title)")
    }

    // MARK: - Reading the local inbox

    /// Resolves stored entity ids against the cached inbox rows.
    ///
    /// Answers with what it can find rather than throwing: the system calls this to redraw a
    /// picker and to rehydrate a shortcut's parameter, and an error there would surface as a
    /// broken shortcut rather than as "that pull request is gone". The intent that *acts* on the
    /// entity is where the missing case becomes a sentence.
    /// - Parameter ids: The node ids the system remembered.
    /// - Returns: The entities that still exist, in the order the ids were given.
    @MainActor
    static func entities(ids: [String]) -> [PullRequestEntity] {
        let rows = IntentBridge.environment?.session?.inboxRows ?? []
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return ids.compactMap { byID[$0] }.map(PullRequestEntity.init(pullRequest:))
    }

    /// The pull requests waiting for the user's review, most urgent first.
    ///
    /// The suggestion list *and* the answer ``GetReviewQueueIntent`` returns, which is deliberate:
    /// "the pull requests Siri offers me" and "the pull requests Shepherd says need me" must be
    /// the same list. Both halves are borrowed rather than restated —
    /// ``MenuBarQuickInbox/needsMyReview(in:)`` (which is `SmartView.needsMyReview`, the rail's own
    /// predicate) and ``InboxModel/prioritySorted(_:)`` — so the badge, the focus session, the
    /// morning digest and Shortcuts cannot disagree about what is waiting or in what order.
    /// - Parameter limit: How many to return at most.
    /// - Returns: The queue, or an empty list when nobody is signed in.
    @MainActor
    static func reviewQueue(limit: Int = 25) -> [PullRequestEntity] {
        let rows = IntentBridge.environment?.session?.inboxRows ?? []
        let waiting = MenuBarQuickInbox.needsMyReview(in: rows)
        return InboxModel.prioritySorted(waiting)
            .prefix(max(0, limit))
            .map(PullRequestEntity.init(pullRequest:))
    }

    /// Finds pull requests by what the user typed, for Shortcuts' own search field.
    ///
    /// Routed through ``SearchIndexCoordinator/results(for:limit:)`` — the ⌘K ranker (ADR 0019) —
    /// rather than a second `contains(title)`: it already blends the lexical and on-device semantic
    /// halves, it already resolves an exact `owner/repo#123`, and it is already local-only, which
    /// is the property that matters most here. A search field in Shortcuts must not become the one
    /// place Shepherd calls out to a provider.
    /// - Parameters:
    ///   - text: What the user typed.
    ///   - limit: How many to return at most.
    /// - Returns: The best matches, best first.
    @MainActor
    static func matches(for text: String, limit: Int = 10) async -> [PullRequestEntity] {
        guard let environment = IntentBridge.environment, environment.session != nil else {
            return []
        }
        let results = await environment.search.results(for: text, limit: limit)
        return results.map { PullRequestEntity(pullRequest: $0.summary) }
    }
}

/// How the system finds ``PullRequestEntity`` values (ADR 0021).
///
/// `EntityStringQuery` rather than the plain `EntityQuery`, because the extra requirement —
/// ``entities(matching:)`` — is what turns "Open Pull Request" in Shortcuts from a fixed picker
/// into a search field. Every method reads the **local database only**: there is no GitHub call
/// anywhere in this file, which is the same promise ADR 0019 makes about the palette and for the
/// same reason (a query field is typed into, repeatedly, by something that is not a review).
struct PullRequestEntityQuery: EntityStringQuery {
    /// Resolves ids a shortcut stored earlier.
    func entities(for identifiers: [String]) async throws -> [PullRequestEntity] {
        await PullRequestEntity.entities(ids: identifiers)
    }

    /// What the picker offers before the user has typed anything: the current review queue.
    func suggestedEntities() async throws -> [PullRequestEntity] {
        await PullRequestEntity.reviewQueue()
    }

    /// What the picker offers once the user types.
    func entities(matching string: String) async throws -> [PullRequestEntity] {
        await PullRequestEntity.matches(for: string)
    }
}
