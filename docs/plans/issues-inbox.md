# The issues inbox and agent assignment

Status: Proposed · Date: 2026-09-03 · Source: founder interview 2026-09-02, `docs/ROADMAP.md`
v1.1 · Scope: v1.1

Shepherd v1 starts at the pull request. The founder's day starts one step earlier, at the issue an
agent should pick up. This plan turns the six bullets of
[`docs/ROADMAP.md`'s v1.1 section](../ROADMAP.md#v11--issues-inbox-and-agent-assignment) (lines
212–236) into four sprints, each a self-contained brief for one implementation agent working in
its own git worktree. The v1.1 theme, stated in the roadmap itself, is the guardrail every sprint
below is built to keep: Shepherd *assigns* and *watches*; it does not become an agent orchestrator.

Companion documents: [`agent-fleet.md`](agent-fleet.md) (the plan whose ADRs 0026/0027 this one
reuses without re-deciding them) and [`apple-intelligence-v2.md`](apple-intelligence-v2.md) (not
touched here — this whole block is tier 1, no model, exactly like the digest and the sweep it
extends).

---

## 0. What the interview decided, and what it re-decided from elsewhere

| Question | Answer | Consequence for the design |
|---|---|---|
| Where do issues fit relative to pull requests? | A second, parallel citizen — its own sweep, own facets, own search — not a tab bolted onto the PR inbox | New `issues` table, new `IssueQuery`, new `IssueRowSummary`; nothing about `pull_requests` changes shape |
| How much does Shepherd do once an agent is assigned? | Starts the delegation, records the assignment as a GitHub comment, then waits | Reuses ADR 0011's engine and guardrails; no new orchestration, no polling of the agent's own progress beyond what the delegation panel already shows |
| Who may assign unattended? | Nobody, in this cut | The rule-engine shape of ADR 0016 is *named* as the future home, not built now |
| Where does "linked issues on PR detail" belong? | Here — it was parked out of v1 for exactly this feature | Sprint 3 closes v1's parked item as part of this block, in both directions |
| What is the new API surface? | `shepherd://issue/...`, an `issues` inbox filter, two webhook events, one digest line | All additive under the existing grammars (ADR 0012, ADR 0013) |
| New host? | None | Every new read and write in this plan is `api.github.com` |

---

## 1. What already exists to build on

| Piece | Where | Used by |
|---|---|---|
| The inbox sweep's facet-query shape (`InboxQuery`, `is:pr is:open archived:false` + relation facets, merged by `ResponseMapping.mergeFacetResults`) | `Packages/ShepherdKit/Sources/GitHubKit/GraphQL/GraphQLDocuments.swift:9-115`, `GitHubClient.searchOpenPullRequests` | Sprint 1's `IssueQuery` is the same shape, one word changed, exactly as ADR 0027's closed-PR search is |
| `search(query:, type: ISSUE)` already returns both `Issue` and `PullRequest` nodes; the sweep only asks for the `... on PullRequest` fragment | `GraphQLDocuments.searchPullRequests` | Sprint 1 adds a sibling document with `... on Issue` instead — same endpoint, same paging, same retry |
| The ephemeral, unpersisted `IssueSummary` (number, title, body, state, `isPullRequest`) and `GitHubClient.issue(repo:number:)`, REST, ETag-cached (ADR 0026's amendment) | `ShepherdCore/Models/IssueSummary.swift`, `GitHubKit/GitHubClient.swift:340-356` | Explicitly **not** reused as the inbox row (see §2.1) — it exists for a different job and stays as it is |
| `AcceptanceCriteria`/`AcceptanceMatcher` reading checklists out of an issue body | `ShepherdCore/Claims/AcceptanceCriteria.swift` | Nothing here; noted so nobody re-derives bullet parsing for the assignment brief |
| `PullRequestSummary` / `PullRequestDetail` split (list row vs. fetched detail), and the record pattern that mirrors it 1:1 (`PullRequestRecord`) | `ShepherdCore/Models/PullRequest.swift`, `ShepherdPersistence/Records.swift:100-160` | The template for `IssueRowSummary` / `IssueDetail` / `IssueRecord` |
| Migrations v1–v6, append-only, one `DatabaseSchema.allTables` list, `pruneGuardSQL` keeping a row alive while a draft or a pending/sending/conflicted outbox row targets it | `ShepherdPersistence/DatabaseManager.swift`, `InboxStore.swift:55-125` | Migration v7's exact shape and the issue prune guard |
| `search_index` (v3): one row per pull request, `documentHash`/`sourceFingerprint` staleness gates, `ON DELETE CASCADE` pruning (ADR 0019) | `ShepherdPersistence/SearchIndexStore.swift`, `ShepherdCore/Search/SearchDocument.swift` | The pattern `issue_search_index` mirrors, field for field |
| `SearchRanker.rank` (BM25 half, cosine half, exact-reference override, similarity floor) | `ShepherdCore/Search/SearchRanker.swift` | Mirrored rather than generalised (see §2.1's reasoning) |
| `DeepLink` / `ShepherdCommandLine`, closed vocabularies, round-trip tested, additive-only grammar (ADR 0013) | `ShepherdCore/Routing/DeepLink.swift`, `ShepherdCore/Routing/ShepherdCommandLine.swift` | Sprint 2's `shepherd://issue/...` case and `issues` filter token |
| Outbox: `OutboxAction` enum, `OutboxItem`, exponential backoff, drain claims a row inside the write transaction (ADR 0006) | `ShepherdCore/Models/Outbox.swift`, `ShepherdPersistence/OutboxStore.swift` | Sprint 4's five new `OutboxAction` cases — no schema change to the `outbox` table itself |
| `DelegationContext` / `DelegationPrompt` / `DelegationCenter`, one delegation per target, worktree ground rules that currently *forbid* branching and pushing | `Shepherd/Features/Delegation/DelegationContext.swift`, `DelegationCenter.swift` | Sprint 4's new `.issue` origin, and the one ground-rule change that origin needs (§4.3) |
| Webhook envelope, `WebhookEvent`/`WebhookCoordinator`, additive under `"v": 1` (ADR 0012) | `Shepherd/Automation/` (per `docs/ARCHITECTURE.md`), `docs/WEBHOOKS.md` | Sprint 4's `issue.assigned_to_agent` / `issue.closed` events |
| `DigestReport.make`, one `DigestSectionKind` per line, tier 1 only, no network in the whole path | `ShepherdCore/Digest/DigestReport.swift` | Sprint 4's new section kind(s) |
| `AgentDetector`/`Actor`/`ActorKind` (provenance) | `ShepherdCore/Agents/AgentDetector.swift`, `ShepherdCore/Models/Actor.swift` | Reused **unchanged** everywhere an issue or a linked pull request needs a provenance chip |
| `FilePrioritizer`/`TrustLane`/`AutoDelegationPolicy` (the things that must *not* gain a new input) | `ShepherdCore/Heuristics/`, `Trust/`, `Automation/` | None of this block touches them — issues are not pull requests and do not enter a trust lane |

---

## 2. Sprint 1 — issue model, sweep, migration v7, store, sync events, ⌘K index

One implementation agent, one worktree, `ShepherdKit` only (Linux-testable — no Xcode needed).
Delivers the roadmap's first bullet's data half.

### 2.1 The model: a new, persisted `IssueRowSummary` — not `IssueSummary`

`IssueSummary` (ADR 0026's amendment) is deliberately unpersisted, has no id, no author and no
timestamps, and answers exactly one question ("what does the referenced issue ask for"). Reusing
it for the inbox row would mean bolting all of `PullRequestSummary`'s shape onto a type whose
whole point is "nothing here is persisted." New file, new type:

`ShepherdCore/Models/Issue.swift`:

```swift
public enum IssueRelation: String, Sendable, Codable, Hashable, CaseIterable {
    case assigned, authored, mentioned
}

public struct LinkedPullRequestReference: Sendable, Codable, Hashable, Identifiable {
    public var repo: RepoRef
    public var number: Int
    public var title: String
    public var state: String        // GitHub's PR state: OPEN / CLOSED / MERGED, kept raw & tolerant
    public var author: Actor
    public var id: String { "\(repo.fullName)#\(number)" }
}

public struct IssueRowSummary: Sendable, Codable, Hashable, Identifiable {
    public let id: String                    // GraphQL node id
    public var repo: RepoRef
    public var number: Int
    public var title: String
    public var author: Actor
    public var createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var state: IssueSummary.State     // reuses ADR 0026's open/closed/unknown enum
    public var stateReason: String?          // GitHub's raw reason; tolerant, like PullRequestOutcome.source
    public var labels: [String]
    public var myRelation: Set<IssueRelation>
    public var commentCount: Int
    public var linkedPullRequests: [LinkedPullRequestReference]

    public var slug: String { "\(repo.fullName)#\(number)" }
    public var hasAgentPullRequest: Bool {
        linkedPullRequests.contains { $0.author.kind.isMachine }
    }
}
```

`IssueDetail` mirrors `PullRequestDetail` minimally — `summary: IssueRowSummary`,
`bodyMarkdown: String` — with comments/timeline deliberately **out of scope** for v1.1 (no bullet
asks for an issue conversation view; the detail panel in Sprint 2 shows title, body, labels and
linked pull requests, nothing else).

### 2.2 GraphQL: a sibling sweep, same connection

New facet type, `InboxQuery`'s twin:

```swift
public struct IssueQuery: Sendable, Hashable {
    public var rawQuery: String
    public var impliedRelations: Set<IssueRelation>
    public static let openIssuePrefix = "is:issue is:open archived:false"
    public static let assigned  = IssueQuery(rawQuery: "\(openIssuePrefix) assignee:@me", impliedRelations: [.assigned])
    public static let authored  = IssueQuery(rawQuery: "\(openIssuePrefix) author:@me",   impliedRelations: [.authored])
    public static let mentioned = IssueQuery(rawQuery: "\(openIssuePrefix) mentions:@me", impliedRelations: [.mentioned])
    public static let defaultSweep: [IssueQuery] = [.assigned, .authored, .mentioned]
}
```

Exactly the roadmap's three facets — no `involves:@me` catch-all, because the roadmap names only
"assigned to you, opened by you, mentioning you." Lives beside `InboxQuery` in
`GraphQLDocuments.swift`.

New document, `GraphQLDocuments.searchIssues`, the same `search(query:, type: ISSUE, first:, after:)`
connection the PR sweep uses, with `... on Issue` in place of `... on PullRequest`:

```graphql
query ShepherdIssueSweep($q: String!, $first: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on Issue {
        id
        number
        title
        createdAt
        updatedAt
        closedAt
        closed
        stateReason
        repository { name owner { login } }
        author { __typename login avatarUrl }
        labels(first: 20) { nodes { name } }
        comments { totalCount }
        closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
          totalCount
          nodes {
            number
            title
            state
            repository { name owner { login } }
            author { __typename login avatarUrl }
          }
        }
      }
    }
  }
}
```

**Uncertain field, flagged rather than assumed:** `closedByPullRequestsReferences` is the
"Development panel" equivalent on `Issue` — the field that answers "which pull requests will close
this." `closingIssuesReferences` on `PullRequest` (the other direction, Sprint 3) is long-stable and
documented; the issue-side connection was added to GitHub's public schema later. **The first task of
this sprint is a live introspection check** (`{ __type(name: "Issue") { fields { name } } }` against
`api.github.com/graphql`) to confirm the field name, its arguments (`includeClosedPrs`,
`userLinkedOnly`) and that it needs no preview header. If it is unavailable or shaped differently
than above, the fallback is `Issue.timelineItems(itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT], first: 20)`,
walking `CrossReferencedEvent.source`/`willCloseTarget` and `ConnectedEvent.subject` — more verbose,
definitely present, and the same fallback Sprint 3 should reach for on the PR side if the equivalent
ever regresses. This is fetched **inside the sweep**, not as a second round trip, because it is one
more nested selection on a connection the sweep already pages — the same reasoning that puts
`statusCheckRollup` inside the PR sweep's `commits` selection.

New `GitHubClient.searchOpenIssues(queries: [IssueQuery] = IssueQuery.defaultSweep) async throws -> [IssueRowSummary]`,
copying `searchOpenPullRequests`'s five-page cap and merge-by-id logic (`ResponseMapping.mergeFacetResults`'s
issue twin). New `ResponseMapping.issueRowSummary(from:relations:detector:)`.

### 2.3 Migration v7

One migration, all four tables this whole block needs — deliberately, because the instruction from
the roadmap review is "next is v7" (singular), and because `createV1` already establishes that one
migration may create several related tables at once. Landing the linking tables now, even though
Sprint 3 is what populates and shows them, means Sprint 3 and Sprint 4 need no migration of their
own.

```sql
CREATE TABLE issues (
    id TEXT PRIMARY KEY NOT NULL,
    repoFullName TEXT NOT NULL REFERENCES repos(fullName) ON DELETE CASCADE,
    number INTEGER NOT NULL,
    title TEXT NOT NULL,
    authorLogin TEXT NOT NULL,
    authorDisplayName TEXT,
    authorAvatarURL TEXT,
    authorKind TEXT NOT NULL,
    agentID TEXT,
    agentDisplayName TEXT,
    agentMatchedBy TEXT,
    createdAt REAL NOT NULL,
    updatedAt REAL NOT NULL,
    closedAt REAL,
    state TEXT NOT NULL DEFAULT 'open',
    stateReason TEXT,
    relations TEXT NOT NULL DEFAULT '',
    labels TEXT NOT NULL DEFAULT '[]',
    commentCount INTEGER NOT NULL DEFAULT 0,
    linkedPullRequestCount INTEGER NOT NULL DEFAULT 0,
    hasAgentLinkedPullRequest INTEGER NOT NULL DEFAULT 0,
    bodyMarkdown TEXT,
    detailFetchedAt REAL
);
CREATE UNIQUE INDEX idx_issues_repo_number ON issues(repoFullName, number);
CREATE INDEX idx_issues_updatedAt ON issues(updatedAt);

CREATE TABLE issue_search_index (
    issueID TEXT PRIMARY KEY NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    documentHash TEXT NOT NULL,
    modelIdentifier TEXT,
    dimensions INTEGER NOT NULL DEFAULT 0,
    vector BLOB,
    indexedAt REAL NOT NULL
);

CREATE TABLE issue_linked_pull_requests (
    issueID TEXT NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    prRepoFullName TEXT NOT NULL,
    prNumber INTEGER NOT NULL,
    prTitle TEXT NOT NULL,
    prState TEXT NOT NULL,
    authorLogin TEXT NOT NULL,
    authorKind TEXT NOT NULL,
    agentDisplayName TEXT,
    sortIndex INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (issueID, prRepoFullName, prNumber)
);

CREATE TABLE pull_request_closing_issues (
    prID TEXT NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
    issueRepoFullName TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    issueTitle TEXT NOT NULL,
    issueState TEXT NOT NULL,
    sortIndex INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (prID, issueRepoFullName, issueNumber)
);
```

Five decisions, each mirroring a precedent already in the schema:

- **`issues` follows `pull_requests`' exact column shape** for author/agent/relations/labels
  (`authorKind`, `agentID`, `relations` as a joined string, `labels` as JSON) so `PullRequestRecord`
  and the new `IssueRecord` share `ColumnCoding` helpers rather than inventing a second encoding.
- **`linkedPullRequestCount`/`hasAgentLinkedPullRequest` are denormalised onto the row**, the same
  choice `PullRequestSummary.checkRollup` makes: the "has an agent pull request" facet has to filter
  the whole inbox on every keystroke of a facet click, and a table scan across `issue_linked_pull_requests`
  for that is the wrong shape for something the sweep already knows. The full list lives in the side
  table for the detail panel; the two summary columns live on the row for the facet.
- **No foreign key from `issue_linked_pull_requests` to `pull_requests`.** The linked pull request
  may not be in the local inbox at all (assigned to someone else, not yet detail-fetched); the row
  is about what the sweep saw, not about a join that might not resolve — the same reasoning
  `pull_request_outcomes` (v6) gives for storing the repository by value.
- **`pull_request_closing_issues` is keyed by `prID`, cascades with it**, because unlike the issue
  outcome table this *is* about a pull request in the inbox and disappears with it, same as
  `changed_files`.
- **`issue_search_index` copies `search_index` (v3) exactly**, including the nullable `vector` and
  the two-hash staleness gate, for the reason ADR 0019 gives: two documents from two schema versions
  must never be compared, and a hash gate this shape is already tested.

`DatabaseSchema.allTables` gains, in creation order (so reverse deletion is FK-safe):
`"issues"`, `"issue_search_index"`, `"issue_linked_pull_requests"`, `"pull_request_closing_issues"`.
`DatabaseManager.migrator` gains `migrator.registerMigration("v7", migrate: DatabaseSchema.addV7)`.

### 2.4 Store

`ShepherdPersistence/IssueStore.swift`, mirroring `InboxStore.swift`:

- `IssueFilter` (repo, anyOfRelations, agentID, isMachineAuthored, hasLinkedAgentPullRequest: Bool?,
  ageBucket, includeClosed, limit) — the `InboxFilter` shape plus the two issue-only axes.
- `issuePruneGuardSQL = "id NOT IN (SELECT prID FROM outbox WHERE state IN ('pending','sending','conflicted'))"` —
  the PR guard's `outbox` half only; there is no draft-equivalent for an issue.
- `saveIssueSummaries(_:pruneMissing:)` / `fetchIssues(filter:)` / `fetchIssueSummary(id:)`, upserting
  `IssueRecord` the way `savePullRequestSummaries` upserts `PullRequestRecord`, including the same
  "an empty `myRelation` from a detail-shaped write keeps what the sweep saw" rule.
- `saveIssueDetail(_:)` / `fetchIssueDetail(id:)` for the body (Sprint 2's detail panel).
- `observeIssues(filter:)` — a `ValueObservation`, `observeInbox`'s twin, for `IssueInboxModel`
  (Sprint 2).

### 2.5 Sync engine: a second sweep in the same cycle

`SyncEngine.runSweep()` gains a call to a new private `runIssueSweep()`, invoked in the same pass —
no second timer, no second cadence setting. It repeats `runSweep`'s delta logic exactly: fetch
`store.fetchIssues()` as "previous," `github.searchOpenIssues()` as "current," detect first
sightings, prune what the search stopped returning (guarded by `issuePruneGuardSQL`), save. New
port `IssueFetching` (mirroring `PullRequestFetching`) and `IssueSyncStoring` (mirroring the issue
half of `SyncStoring`), both satisfied by `GitHubClient`/`DatabaseManager` extensions exactly as
`PullRequestFetching`/`SyncStoring` already are — so `SyncEngine`'s tests keep running against fakes
with no network, on Linux.

**No new `SyncEvent` case in this sprint.** The roadmap's digest line (Sprint 4) reads stored rows
directly the way `DigestReport.make`'s `newReviewRequests` section already does off
`updatedAt >= windowStart`, so an event is not needed to make that line work, and there is no
notification bullet in the roadmap that would need one. If a future "new issue assignment"
notification is wanted, that is a new `SyncEvent` case then, not now — noted under §5.

### 2.6 ⌘K index: a parallel `IssueSearchDocument`, not a generalised `SearchDocument`

`SearchDocument` (ADR 0019) is pinned by name and by field list; extending it to carry issue-shaped
fields (no branch, no diff, no changed paths) would either widen a type the ADR explicitly keeps
narrow, or grow optionals that are always `nil` for one of the two kinds it would then represent.
The recommendation here, consistent with how this codebase treats "two features that are alike but
not the same thing" (`ClosedPullRequestReading` beside `PullRequestFetching`, `OutcomeCapture`
beside `SyncStoring`), is a **sibling type**, not a generalisation:

`ShepherdCore/Search/IssueSearchDocument.swift` — `IssueSearchDocument.make(source:budget:)`, same
`Field` weighting philosophy but four fields only: `title` (3), `identity` (3), `labels` (2.5),
`body` (1) — no `branch`, `paths` or `added`, because an issue has none of those. Same
`SearchText.tokens`/`SearchContentHash.hex` reuse, same `documentHash`/`sourceFingerprint` pair.
`IssueSearchRanker.rank` duplicates `SearchRanker`'s BM25 loop (`k1 = 1.2`, `b = 0.75`) byte for
byte — a small, deliberate duplication over a shared generic, because the ranking math is eleven
lines and a shared protocol would buy an abstraction for two call sites that will keep diverging
(issues gain no diff, ever). `SearchIndexCoordinator` (app target, Sprint 2) runs both passes off
the same `onInboxRows`-shaped callback, now fed by both sweeps.

⌘K's palette (`CommandPaletteView.PaletteRow`, ADR 0019) gains a third case, `.issue(IssueSearchResult)`,
merged into the same one ordered list the ADR's "the keyboard does not notice" rule requires — both
ranked candidate sets are computed, then merged by score before the list is sliced to its limit, so
there is still exactly one cursor.

### 2.7 Tests (Linux, `swift test`)

- `IssueQueryTests` — the three facet strings, `defaultSweep`'s order.
- `ResponseMappingIssueTests` — a fixture GraphQL response per facet, including the
  `closedByPullRequestsReferences` node shape (and its fallback shape, both fixture-tested so
  the live-schema uncertainty above has a regression test either way it resolves).
- `DatabaseManagerTests` — migration v7 applies cleanly on top of v1–v6; round-trips an
  `IssueRowSummary` through `IssueRecord`; `eraseAllData()` empties all four new tables;
  `issuePruneGuardSQL` keeps a row alive under a pending outbox action and lets it go once that
  action succeeds or fails terminally.
- `IssueSearchDocumentTests` / `IssueSearchRankerTests` — the `SearchDocumentTests`/`SearchRankerTests`
  fixtures, adapted: no-embeddings fallback, exact-reference override, empty query.
- `SyncEngineTests` — a new `runIssueSweep` fixture on the existing scripted `PullRequestFetching`
  double, extended with `IssueFetching`: first sighting, prune on disappearance, guard respected.

### 2.8 Effort and ADR

**Effort: L** (four tables, a new sweep, a new search sibling, and the schema introspection spike).
**Writes ADR 0032**: issues as a first-class inbox citizen — the model split from `IssueSummary`,
the sweep as a sibling of ADR 0005's, migration v7's shape, and the search index as a sibling of
ADR 0019's rather than an extension of it.

---

## 3. Sprint 2 — inbox section, facets, issue detail panel, deep link/CLI filter, provenance chip

App-target work (Xcode required for the UI half; the pure `DeepLink`/`ShepherdCommandLine` changes
are Linux-testable and should be written and tested before the SwiftUI work starts). Depends on
Sprint 1's store and sweep; **partly parallel with Sprint 3** (see §6) once Sprint 1 has landed,
because the "has an agent pull request" facet's *data* (denormalised in Sprint 1's migration) is
already there — only Sprint 3's PR-detail-side UI is a hard dependency-free addition on top.

### 3.1 Content-kind switch, not a new smart view

The existing `InboxSidebar`/`InboxListView`/`InboxDetailPanel` are built around one `InboxModel`
observing `pull_requests`. Rather than teach that model two shapes, add a top-level
`ContentKind: .pullRequests | .issues` picker at the top of `InboxSidebar` (a segmented control,
Linear-style), and a parallel `IssueInboxModel` (`Features/Inbox/IssueInboxModel.swift`) mirroring
`InboxModel`'s shape — `observeIssues(filter:)`, `smartView`-equivalent, `laneFacets`-equivalent —
but with issue-only facets. `InboxScreen` holds both models and switches which one drives
`InboxListView`/`InboxSidebar`/the detail panel based on `ContentKind`. `j`/`k`
(`KeySequenceState`) and ⌘K are unaffected: they operate on "the model that owns the current
selection," which is already how the focus session and the menu-bar item avoid caring which screen
is up.

### 3.2 Facets

New `IssueSidebar` section (or `InboxSidebar` branching on `ContentKind`, implementer's call, but
the facet *logic* is pure and belongs in `ShepherdCore/Triage/IssueFacet.swift` regardless of where
the view lives, mirroring `TriageFacet.swift`'s split):

- **Repository** — reuses the existing repository-facet component unchanged (`RepoRef` comparison,
  `isSameRepository(as:)`).
- **Label** — new; issues carry `labels` the same shape pull requests do, but there is no label
  facet today. `IssueLabelFacet(name: String, count: Int)`, sorted by count then name, capped at a
  reasonable row count (mirror the risk facet's "absent when it would filter to nothing" rule).
- **Age** — new pure type `IssueAgeBucket` (`.today`, `.thisWeek`, `.thisMonth`, `.older`), bucketed
  off `createdAt` against `now`, Linux-tested like every other faceting rule in `ShepherdCore/Triage/`.
- **Has an agent pull request / has none** — reads `IssueRowSummary.hasAgentPullRequest` directly
  (Sprint 1's denormalised column); ships functional from the moment Sprint 1 lands, independent of
  Sprint 3's UI.

### 3.3 Issue detail panel

`Features/Inbox/IssueDetailPanel.swift`, the `InboxDetailPanel`'s shape: title, provenance chip
(`ProvenanceChip`, unchanged), labels, state, age, body rendered the same way the PR description is
(`AttributedString`, not the Monaco bridge — issues have no diff). A "Linked pull requests" section
is present but empty until Sprint 3 populates `issue_linked_pull_requests` beyond the sweep's cheap
nested fields; until then it shows the count-only summary Sprint 1 already stores.

### 3.4 Deep link and CLI

`DeepLink` gains one case:

```swift
case issue(repo: RepoRef, number: Int)   // shepherd://issue/<owner>/<repo>/<number>
```

parsed and serialised exactly like `.pullRequest` (same `DeepLinkValidation.owner/repositoryName/number`),
opening the issue detail panel through the same "cache first, then fetch that one issue" rule
`openPullRequest` in `DeepLinkRouter.swift:131-151` already follows — a new
`AppEnvironment.openIssue(issueID:)` beside `openReview(prID:)`.

`InboxDeepLinkFilter` gains one token:

```swift
case issues   // shepherd://inbox?filter=issues
```

interpreted by `InboxRailSelection`'s mapping as "switch `ContentKind` to `.issues`, no further
narrowing" — the same "raise it, let the screen that owns the state run it" mechanism the digest
card's `filter=` links already use, so this is additive to the existing grammar and needs no new
routing concept.

`ShepherdCommandLine` gains a new top-level verb, `shepherd issue <owner>/<repo>#<number>` →
`.open(.issue(...))`, and `shepherd inbox issues` as a shorthand for `--filter issues`. Usage text
and `--help` updated in the same commit (ADR 0013's own rule: the grammar is a public interface,
additive only).

### 3.5 Provenance chip

Reused unchanged: `ProvenanceChip` already takes an `Actor`, and an issue's `author: Actor` is
produced by the same `AgentDetector` the PR sweep uses. No new detection logic.

### 3.6 Tests

- `DeepLinkTests` — `.issue` round-trips through `parse`/`urlString`; `.issues` filter token
  parses and rejects malformed input the way every other token does.
- `ShepherdCommandLineTests` — `shepherd issue owner/repo#42`, `shepherd inbox issues`.
- `IssueAgeBucketTests`, `IssueLabelFacetTests` — pure, Linux.
- App: `IssueInboxModelTests` (facet counts, selection pruning on list change, mirroring
  `InboxModel`'s own tests) and a snapshot/interaction test that `ContentKind` switching does not
  disturb `j`/`k` state.

### 3.7 Localisation estimate

Roughly 35–45 new keys: the content-kind picker, three facet headers and their tooltips, the age
bucket labels, the empty-state strings for "no issues," the detail panel's chrome (state, labels
header, "linked pull requests," empty variant), and the CLI's unlocalised `--help` additions (which
do **not** count against the catalog, per ADR 0022's CLI exclusion).

### 3.8 Effort and ADR

**Effort: M.** **Amends ADR 0032**: the content-kind split (a picker, not a second window), the
facet list, and the additive deep-link/CLI grammar.

---

## 4. Sprint 3 — issue ↔ pull request linking, both directions

Depends on Sprint 1's schema (the two linking tables already exist) and, for the PR-detail UI half,
on `ConversationView`'s existing layout. Independent of Sprint 2's facet UI beyond needing
`IssueDetailPanel` to exist as a place to render the issue-side list — so it can start once Sprint 1
lands and finish in parallel with the tail of Sprint 2 (see §6).

### 4.1 PR → Issue ("closes #123"), the parked v1 item

`GraphQLDocuments.pullRequestClosingIssues`, a small additive GraphQL call inside
`GitHubClient.fetchDetail(repo:number:)`, alongside the existing `reviewThreads` GraphQL call:

```graphql
query ShepherdPullRequestClosingIssues($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      closingIssuesReferences(first: 10) {
        totalCount
        nodes { number title state repository { name owner { login } } }
      }
    }
  }
}
```

`closingIssuesReferences` is a long-stable, documented field (unlike its issue-side counterpart in
Sprint 1) — confidence is high here, but a live introspection check before writing the mapper costs
nothing and is worth doing anyway since the two calls are adjacent work.

New `PullRequestDetail.closingIssues: [LinkedIssueReference]` (a small value: `repo`, `number`,
`title`, `state: IssueSummary.State`). Stored in `pull_request_closing_issues` (Sprint 1's table),
written by `savePullRequestDetail` the same way `changed_files`/`review_threads` are replaced on
every detail fetch. `ConversationView` gains a small "Closes" section above the description — title,
state, one keystroke (`DeepLink.issue`) to open — which is exactly the parked roadmap item's original
wording.

### 4.2 Issue → Pull Request (the Development panel), reusing the sweep's own fetch

Sprint 1's issue sweep already selects `closedByPullRequestsReferences` (with author fields) as a
cheap nested connection — this sprint is what **stores it into `issue_linked_pull_requests`** (Sprint
1 only used it to compute the two denormalised summary columns) and **renders it**: the issue detail
panel's "Linked pull requests" section lists each one with title, state and provenance chip.

**CI dot and review decision**, which the roadmap asks the issue's list to show, are **not** a new
fetch: `IssueDetailPanel` looks the linked pull request up by `(repo, number)` against the
already-cached `pull_requests` table (the common case — a maintainer assigning issues is usually
also reviewing the resulting pull request) and shows its `checkRollup`/`reviewDecision` when found,
omitting them silently otherwise. This keeps the whole feature at zero new GitHub calls beyond the
one nested field the sweep already carries — consistent with ADR 0006 and with how the digest reuses
inbox rows rather than fetching state of its own.

### 4.3 Tests

- `GitHubClient`/`ResponseMapping` fixture tests for `closingIssuesReferences`, including the
  zero-, one- and several-issue shapes.
- `DatabaseManagerTests` — `pull_request_closing_issues` cascades with its pull request;
  `issue_linked_pull_requests` cascades with its issue; both round-trip.
- App: `ConversationView`'s "Closes" section renders and opens the right issue; `IssueDetailPanel`'s
  linked-PR row shows a CI dot only when the pull request is locally cached, and degrades cleanly
  otherwise.

### 4.4 Localisation estimate

10–15 keys: "Closes #N," the closing-issue state labels, the linked-PR section header and its empty
variant, "not currently in your inbox" (the degraded CI-dot case).

### 4.5 Effort and ADR

**Effort: M.** **Amends ADR 0032**: both linking directions, the decision to read the issue-side
connection inside the existing sweep rather than as a per-issue detail fetch, and the decision to
resolve CI state by local join rather than by a second fetch.

---

## 5. Sprint 4 — assign-to-agent delegation, issue triage writes, webhooks, digest line

Depends on Sprints 1–3 for the issue model and (for the assignment comment) nothing from linking —
so it can start once Sprint 1 lands, though the digest's "agent pull requests that closed one" line
wants Sprint 3's linking data to be meaningful and should land last in practice.

### 5.1 Outbox: five new actions, zero schema change

`OutboxAction` gains:

```swift
case addIssueComment(body: String, basedOnUpdatedAt: Date)
case addIssueLabel(name: String, basedOnUpdatedAt: Date)
case addIssueAssignee(login: String, basedOnUpdatedAt: Date)
case closeIssue(reason: String, basedOnUpdatedAt: Date)      // "completed" | "not_planned"
case reopenIssue(basedOnUpdatedAt: Date)
```

No migration needed: `outbox.payload` already stores the whole `OutboxAction` enum as an opaque
blob (`ColumnCoding`), so a new case is purely additive to the Swift type, the way a new
`WebhookEvent` case was additive to that enum. `OutboxItem.prID`/`repo`/`number` are reused
**generically** as "the target's id/repo/number" — documented at the call site rather than renamed,
to avoid a mechanical rename touching every existing PR-only call site for no behavioural change.

**Staleness precondition** (the roadmap's explicit ask, "the same staleness precondition the review
writes have"): each new case carries `basedOnUpdatedAt`, the issue's `updatedAt` at enqueue time.
Before executing, the drain probes the issue's current `updatedAt` with a new, minimal GraphQL query
(`GraphQLDocuments.issueState`, mirroring `pullRequestHead`'s shape — `id updatedAt state`); a
mismatch parks the row as `.conflicted`, exactly like `ReviewDraft.basedOnHeadOid` does for a review
submission. Additive REST calls on `GitHubClient`:

- `POST /repos/{o}/{r}/issues/{n}/comments` — `addIssueComment`
- `POST /repos/{o}/{r}/issues/{n}/labels` — `addIssueLabel` (additive endpoint, not the full-replace
  `PATCH`, so two queued label writes cannot race each other into one lost update)
- `POST /repos/{o}/{r}/issues/{n}/assignees` — `addIssueAssignee`
- `PATCH /repos/{o}/{r}/issues/{n}` with `{state, state_reason}` only — `closeIssue`/`reopenIssue`

### 5.2 Assign an issue to an agent

`DelegationContext.Origin` gains `.issue` (a genuine new case, not a field on an existing one — the
task is not anchored to a file or a thread, and the worktree's ground rules are genuinely different,
below). New factory `DelegationContext.issue(_:template:)`, rendering title/body/labels/repository
through a template the way `AutoDelegationRules`' `{{…}}` template works (ADR 0016), reusing
`AgentBriefDrafter`'s ✨ button unchanged for the optional drafted version (ADR 0011's 2026-09-03
amendment already covers "a brief drafted from a `DelegationContext`" generically).

**The ground-rule change this sprint has to make explicit.** `DelegationPrompt.preamble`'s existing
text forbids creating a branch, switching branches or opening a pull request — correct for
addressing an *existing* pull request, wrong for an issue assignment, whose entire point is a new
pull request. `DelegationPrompt` gains a second preamble, selected by `context.origin`:

- `.pullRequest` / `.reviewFinding`: unchanged — no branch, no push, no PR.
- `.issue`: the worktree is created at the repository's default branch tip (a new
  `GitWorktree` entry point, `addForNewWork`, alongside the existing head-SHA-keyed one — a local
  `git` operation, no new GitHub read), on a Shepherd-assigned branch name (deterministic, e.g.
  `agent/issue-{number}`, so **Shepherd** names the branch rather than asking the agent to invent
  one — the smallest ground rule that still lets the agent open a pull request when its own CLI has
  push access). The preamble says the agent *may* commit, push and open a pull request when the work
  is ready, using whatever git/GitHub credentials its own CLI already has — which is unchanged from
  ADR 0011's existing rule that Shepherd "inherits whatever auth that CLI has" and never touches it.
  **Shepherd itself still never pushes**: no new code path calls `git push` outside the existing,
  human-pressed "Commit & push" button, which remains available as the fallback when the agent's own
  environment cannot push.

Assignment also enqueues `.addIssueComment(body: "Assigned to <agent> via Shepherd", …)` through the
outbox, so the record is visible on GitHub and to teammates, as the roadmap asks. `DelegationCenter`'s
"one run per target" dictionary is keyed by `DelegationContext.id` (already generic), so an issue and
a pull request can never collide even though both currently reuse the `prID`-named field.

### 5.3 Webhooks

Two additive events under `"v": 1` (ADR 0012):

- `issue.assigned_to_agent` — fired from `DelegationModel`'s terminal "started" moment for an
  `.issue`-origin context (mirroring `delegation.finished`'s hook point, but at start, since the
  roadmap event name is about the assignment, not the run's outcome — implementer should confirm
  against `WebhookCoordinator.plan(for:)`'s existing hook points which moment is cheapest and most
  honest; recorded as an open question below).
- `issue.closed` — fired from the outbox drain's `mutationSent` for a successful `closeIssue`, the
  same hook `review.submitted`/`pr.merged` already use.

Payload shape follows the existing envelope (`docs/WEBHOOKS.md`): repository, number, title, URL,
author with provenance, and a small `details` object (`{agent, template}` for the first event,
`{reason}` for the second) — no comment bodies, no issue body, consistent with ADR 0012's "describes
what happened, not what was written."

### 5.4 Digest line

`DigestSectionKind` gains `issuesAssignedToYou` (windowed, exactly like `newReviewRequests`:
`issues.filter { $0.myRelation.contains(.assigned) && $0.updatedAt >= windowStart }`) and
`agentPullRequestsThatClosedAnIssue` (not windowed — a state, like the green-agent-PR line): issues
where `state == .closed`, `stateReason == "completed"`, `closedAt >= windowStart`, and the closing
pull request (via `pull_request_closing_issues` or `issue_linked_pull_requests`) was agent-authored.
Both stay **tier 1, no network**, reading only stored rows — `DigestReport.make` gains an `issues:
[IssueRowSummary]` parameter beside `pullRequests:`, and both new sections are built the same way
`append(&sections, …)` builds the existing four.

### 5.5 Tests

- `OutboxActionTests` — the five new cases encode/decode; the drain's staleness probe parks on a
  changed `updatedAt` and proceeds when it matches (mirroring `DraftConflict` tests).
- `DelegationPromptTests` — `.issue` origin produces the branch-permitting preamble; the other two
  origins are unchanged (a reflective/exhaustive test, the pattern ADR 0023/0027 use for "this rule
  cannot silently widen").
- `WebhookCoordinatorTests` — both new events' `plan(for:)` mappings, payload shape pinned.
- `DigestReportTests` — both new sections, including "state survives the night" for the
  not-windowed one and "quiet on the second morning is correct" for the windowed one.

### 5.6 Localisation estimate

20–25 keys: the assignment comment template's user-facing copy (Settings → Delegation's template
editor), the two digest lines, the issue triage buttons (label/assign/close/reopen/comment) and
their confirmation toasts, the new preamble's Settings-visible summary text.

### 5.7 Effort and ADR

**Effort: L** (the ground-rule branch is the substantive design work, not the outbox plumbing).
**Amends ADR 0032** with the assignment flow, and **amends ADR 0011** with the one ground-rule
exception this sprint needs (a dated amendment in `0011-delegate-to-local-agent-cli.md`, the same
shape as its existing 2026-09-03 amendment) — because changing what a delegation's preamble may say
is a decision about that ADR, not just about issues.

---

## 6. Sequence

```
Sprint 1  — issue model, sweep, migration v7 (all four tables), store, ⌘K index    ~1.5 weeks
            → foundation everything else needs; nothing below starts before this lands

Sprint 2  — inbox section, facets, detail panel, deep link/CLI          ~1 week    ┐
Sprint 3  — issue ↔ PR linking, both directions                        ~1 week    ┘  parallel,
            after Sprint 1: Sprint 2's facet *data* and Sprint 3's fetch are both already
            in Sprint 1's schema; the two sprints only share `IssueDetailPanel`'s shell
            (Sprint 2 builds the empty section, Sprint 3 fills it) — coordinate that one file's
            ownership up front, or land Sprint 2's shell one day ahead

Sprint 4  — assignment delegation, triage outbox, webhooks, digest      ~1.5 weeks
            → wants Sprint 1 (issue model), benefits from Sprint 3 (the digest's second line is
              meaningless without linking data) but does not hard-depend on Sprint 2's UI
```

Total: roughly 5 weeks across four sprints, two of which run concurrently.

---

## 7. Not in this block, with the reason

- **Unattended assignment rules** ("every issue with label `agent-ok`"). The roadmap names this
  explicitly as a later, separate opt-in under ADR 0016's condition-enum-plus-checkbox shape. This
  block only ships the button.
- **Issue creation.** Nothing here lets Shepherd open a new issue on GitHub; the whole feature is
  about issues that already exist.
- **Project boards.** Not named anywhere in the interview or the roadmap; a different GitHub object
  entirely, with its own permission and query surface.
- **Notifications for new issue assignments.** The digest covers "since the last digest"; a live
  macOS notification (the `SyncEvent` case Sprint 1 deliberately does not add) is a small follow-up
  if wanted, not part of this cut.
- **Issue conversation/comment thread view.** The detail panel shows the body, not a timeline;
  `PullRequestDetail.timeline`'s shape is not mirrored here.

---

## 8. Privacy statement

No new host anywhere in this plan. Every read is `api.github.com` (GraphQL `search`, the two new
GraphQL detail queries, the issue-state staleness probe) and every write is `api.github.com` REST
(`POST .../comments`, `POST .../labels`, `POST .../assignees`, `PATCH .../issues/{n}`) — the same
host and the same token the pull-request path already uses. The two new webhook events travel to
the URL the user already configured (ADR 0012); no payload in this plan carries an issue body or a
comment body. `CONTRIBUTING.md`'s host list needs one new bullet naming the issue endpoints, not a
new entry.

---

## 9. Definition of done, per sprint

- Works with the on-device model absent or intelligence off entirely — this whole block is tier 1;
  nothing in it may call `IntelligenceRouter`.
- Migration v7 listed in `DatabaseManagerTests`; every new table round-trips and cascades correctly
  on Linux.
- No new outbox precondition is skipped: every write added in Sprint 4 carries a staleness check.
- New GitHub reads are ETag-cached where GitHub sends a validator, and named in `CONTRIBUTING.md`'s
  host list — all `api.github.com`, no new host.
- Strings in the catalog, `Scripts/check-localization.py` green, German rows present.
- New settings (if any — the template text in Settings → Delegation) travel in
  `SyncedSettingsDocument` with a `SettingsSyncTests` fixture.
- ADR 0032 written (Sprint 1) and amended (Sprints 2–4); ADR 0011 amended (Sprint 4); both linked
  from `docs/adr/README.md`; `docs/FEATURES.md` paragraph added; roadmap bullets ticked.

---

## 10. Decisions taken on the open questions (2026-09-03)

- **`Issue.closedByPullRequestsReferences`** is part of GitHub's public GraphQL schema (arguments
  `first`, `after`, `includeClosedPrs`, `userLinkedOnly`, `orderBy`; no preview header). Sprint 1
  builds on it and keeps the `timelineItems` shape as a fixture-tested fallback mapper only, so a
  schema regression is a one-line switch rather than a rewrite. If the live schema disagrees, the
  fallback becomes the primary and the plan is corrected here.
- **`issue.assigned_to_agent` fires on the assignment comment's `mutationSent`**, not at delegation
  start — ADR 0012's rule is "what happened", and the comment is the visible record of it.
- **One `InboxScreen` with a content-kind picker**, not a second top-level route: `j`/`k`, ⌘K, the
  focus session and the menu-bar item all address "the model that owns the selection" already, and
  a second route would duplicate the chrome for one segmented control's worth of difference.
- **Sprint 4's ground-rule change to ADR 0011** (an issue-origin delegation may commit, push and
  open a pull request with the agent's own credentials; Shepherd itself still never pushes) is put
  to the owner before Sprint 4 starts. Sprints 1–3 do not depend on the answer.

