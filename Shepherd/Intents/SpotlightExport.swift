import Foundation
import ShepherdCore

/// The wording a pull request gets on the two *system* surfaces — Spotlight and Shortcuts.
///
/// One place, because the two are read side by side: a Spotlight result's second line and the
/// `checks` property of a ``PullRequestEntity`` returned to a Shortcut describe the same fact, and
/// two independent spellings of "checks failing" would be a bug nobody notices. The wording is the
/// inbox CI dot's tooltip, deliberately, so a user who has hovered a row recognises the phrase.
///
/// A row's provenance is *not* re-implemented here: `ActorKind.localizedProvenanceLabel`
/// (`InboxSectionText.swift`) already is the one definition of what it is called on screen
/// (ADR 0008, ADR 0022), and the section headers and the Shortcuts entity both read it.
enum PullRequestMetadataText {
    /// How a rolled-up CI state is spelled out.
    ///
    /// A pull request with no checks says so rather than saying nothing: "owner/repo#12 · alice ·"
    /// with a trailing separator would look like a truncation.
    /// - Parameter rollup: The rolled-up state, or `nil` when the head commit has no checks.
    /// - Returns: One short phrase, never empty.
    static func checkState(_ rollup: CheckRollup?) -> String {
        switch rollup?.state {
        case .some(.success): return String(localized: "All checks passed")
        case .some(.failure): return String(localized: "Checks failing")
        case .some(.pending): return String(localized: "Checks running")
        case .some(.none), nil: return String(localized: "No checks")
        }
    }
}

/// Everything about one pull request that Shepherd is willing to hand to Spotlight (ADR 0021).
///
/// The type exists to make the export a **pure value**. `CSSearchableItem` and
/// `CSSearchableItemAttributeSet` are `NSObject`s that cannot be built or compared on a Linux
/// runner and are awkward to assert against anywhere; this struct is the whole mapping decision —
/// which fields leave the app's database and how they read — as three strings and a list, so
/// `ShepherdTests` can pin it and ``SpotlightIndexer`` is left with nothing but the framework call.
///
/// It is also the privacy boundary, expressed as a type. Spotlight's index lives **outside**
/// Shepherd's sandbox database: it is a system-wide store, it is backed up, it is readable by
/// Spotlight's own UI and by any process that can query `CSSearchQuery`, and Shepherd cannot
/// promise anything about its lifetime beyond calling `delete`. So what may enter it is the same
/// metadata GitHub itself shows to anyone who can see the pull request — its identity, its title,
/// its author, its CI state, its labels — and **nothing that was written in confidence**: no
/// description, no diff, no review comment, no agent output, and no draft of the user's own. There
/// is deliberately no field on this struct that could carry one, which is why the ADR calls the
/// absence structural rather than a rule to remember.
struct SpotlightItemFields: Equatable, Sendable {
    /// The item's identity in Spotlight: the pull request's GraphQL node id.
    ///
    /// The node id rather than the `owner/repo#number` slug, because it is the primary key
    /// everywhere else in Shepherd and because it survives a repository rename — a renamed
    /// repository would otherwise leave a duplicate item behind that nothing ever deletes.
    let uniqueIdentifier: String
    /// The pull request title, verbatim: the result's first line.
    let title: String
    /// `owner/repo#123 · alice · All checks passed` — the result's second line.
    let contentDescription: String
    /// Extra words the item should match on: labels, the agent's name, the repository.
    ///
    /// Keywords are how a query that is *not* in the title still finds the row — "automerge",
    /// "Claude Code", "review". Deduplicated and in a fixed order, so two identical inbox states
    /// produce two identical items and the diff below sees no change.
    let keywords: [String]
    /// The `PullRequestEntity` the item stands for, so Siri and Shortcuts receive the same thing
    /// from a Spotlight result as from their own search (ADR 0021's 2026-09-22 amendment).
    ///
    /// Left out of `==` on purpose: it is made of the same row, and the export's diff is about the
    /// four fields above — the entity is a handle that re-reads its row when it is resolved.
    let entity: PullRequestEntity

    static func == (lhs: SpotlightItemFields, rhs: SpotlightItemFields) -> Bool {
        lhs.uniqueIdentifier == rhs.uniqueIdentifier
            && lhs.title == rhs.title
            && lhs.contentDescription == rhs.contentDescription
            && lhs.keywords == rhs.keywords
    }

    /// Maps one inbox row onto what Spotlight is allowed to know about it.
    /// - Parameter pullRequest: The row, as the local database holds it.
    init(pullRequest: PullRequestSummary) {
        uniqueIdentifier = pullRequest.id
        entity = PullRequestEntity(pullRequest: pullRequest)
        title = pullRequest.title
        contentDescription = String(
            localized: "\(pullRequest.slug) · \(pullRequest.author.login) · \(PullRequestMetadataText.checkState(pullRequest.checkRollup))"
        )
        var words: [String] = pullRequest.labels
        if let agent = pullRequest.author.kind.agentIdentity {
            words.append(agent.displayName)
        }
        words.append(pullRequest.repo.owner)
        words.append(pullRequest.repo.name)
        var seen = Set<String>()
        var unique: [String] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            unique.append(trimmed)
        }
        keywords = unique
    }
}

/// What one Spotlight sweep has to do: the items to write and the ids to remove (ADR 0021).
///
/// Computed against the fields the exporter *last wrote*, not against the rows it last saw, and
/// that distinction is the whole reason the type exists. The inbox observation speaks on **every**
/// inbox write — a sweep that moved one `updatedAt`, an outbox drain, a detail fetch storing a diff
/// (ADR 0019 relies on the same callback) — and almost none of those writes change a title, an
/// author, a label or a CI state. Comparing the *exported* representation therefore collapses the
/// common case to "nothing to do", and the exporter can then skip the framework call entirely
/// rather than handing Core Spotlight a few hundred identical items every couple of minutes.
///
/// A pure value with a total order, for the usual reason: the plan is what the tests assert, and a
/// dictionary's iteration order would make "which items were written" unstateable.
struct SpotlightExportPlan: Equatable, Sendable {
    /// The items to hand to `indexSearchableItems`, ordered by identifier.
    ///
    /// An upsert covers both "new to Spotlight" and "changed since it was written": Core Spotlight
    /// has one call for both, keyed by the unique identifier, so the distinction would be a
    /// difference this type invents and nothing consumes.
    var upserts: [SpotlightItemFields] = []
    /// The identifiers to remove, ordered.
    ///
    /// A pull request that left the inbox — merged, closed, or pruned because the user is no longer
    /// involved — leaves Spotlight in the same breath. Leaving it behind would make Spotlight the
    /// one surface in Shepherd that still lists merged pull requests, and it would do so for a
    /// month (that is Core Spotlight's default expiry) with no way for the user to tell why.
    var deletions: [String] = []

    /// Whether the sweep has nothing to do — the common case, and the one that must cost nothing.
    var isEmpty: Bool { upserts.isEmpty && deletions.isEmpty }

    /// The fields every current inbox row should be represented by, keyed by identifier.
    /// - Parameter rows: Every inbox row the local database now holds.
    /// - Returns: The desired state of the `pullRequests` domain.
    static func desiredFields(rows: [PullRequestSummary]) -> [String: SpotlightItemFields] {
        Dictionary(
            rows.map { ($0.id, SpotlightItemFields(pullRequest: $0)) },
            // A duplicate id cannot happen (it is the table's primary key) and is resolved rather
            // than trapped: `Dictionary(uniqueKeysWithValues:)` would crash the app over a
            // duplicate row, which is a wildly disproportionate response to a search index.
            uniquingKeysWith: { _, last in last }
        )
    }

    /// Diffs the inbox against what was last exported.
    /// - Parameters:
    ///   - rows: Every inbox row the local database now holds.
    ///   - exported: The fields the exporter last wrote, keyed by identifier.
    /// - Returns: The plan. ``isEmpty`` when the exported state already matches.
    static func make(
        rows: [PullRequestSummary],
        exported: [String: SpotlightItemFields]
    ) -> SpotlightExportPlan {
        let desired = desiredFields(rows: rows)
        var plan = SpotlightExportPlan()
        plan.upserts = desired.values
            .filter { exported[$0.uniqueIdentifier] != $0 }
            .sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
        plan.deletions = exported.keys
            .filter { desired[$0] == nil }
            .sorted()
        return plan
    }
}

/// The Core Spotlight domain, and resolving a system-supplied identifier back to a pull request.
enum SpotlightExport {
    /// The Core Spotlight domain every pull-request item is filed under.
    ///
    /// One domain, so switching the feature off — or signing out — is a single
    /// `deleteSearchableItems(withDomainIdentifiers:)` rather than a list of ids the app would
    /// have to have kept. That is the difference between a toggle that is honest and a toggle that
    /// leaves the previous account's pull requests in the system index.
    static let domainIdentifier = "pullRequests"
}

/// Turning an identifier the *system* handed back into the row it stands for (ADR 0021).
///
/// Both system surfaces have the same problem in the same shape. Spotlight returns a clicked
/// result as a `CSSearchableItemActivityIdentifier` and nothing else; Shortcuts returns a stored
/// ``PullRequestEntity`` whose `id` is all that survived being written to disk weeks ago. Neither
/// carries a repository and a number, which is what ``ShepherdCore/DeepLink/pullRequest(repo:number:)``
/// needs — so both resolve their identifier against the cached inbox rows, through this one pure
/// function. It is the mirror image of ``AppEnvironment/pullRequestID(repo:number:in:)``, which
/// resolves the other direction for a `shepherd://` link, and it is a free function for the same
/// reason: it is the part of the hand-off worth testing.
enum PullRequestIdentifierLookup {
    /// Finds the pull request a node id stands for.
    /// - Parameters:
    ///   - nodeID: The GraphQL node id the system handed back.
    ///   - rows: The cached inbox rows.
    /// - Returns: The row, or `nil` when the pull request is no longer in the inbox — a stale
    ///   Spotlight item the next sweep deletes, a shortcut built against a pull request that has
    ///   since been merged, or an item from an account that has since signed out.
    static func row(nodeID: String, in rows: [PullRequestSummary]) -> PullRequestSummary? {
        rows.first { $0.id == nodeID }
    }
}
