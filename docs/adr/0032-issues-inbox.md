# ADR 0032: Issues are a second inbox citizen — their own sweep, their own table, their own search index

Status: Accepted · Date: 2026-09-03

## Context

Shepherd v1 starts at the pull request. The founder interview behind
[`docs/plans/issues-inbox.md`](../plans/issues-inbox.md) started one step earlier, at *the issue an
agent should pick up*, and answered the design question in one sentence: an issue is **a second,
parallel citizen** — its own sweep, its own facets, its own search — and not a tab bolted onto the
pull-request inbox. This ADR records the data half of that answer, which is what everything above
it stands on.

Four facts about what is already here shape every decision below.

**There is already an `IssueSummary`, and it is not this.** ADR 0026's amendment added it so the
claims card can check a `fixes #N` reference against its acceptance bullets: no id, no author, no
timestamps, nothing persisted, because the body is needed only while the card is open. Reusing it
as the inbox row would mean persisting a type whose whole point is that it is not persisted, and
growing it the eleven fields a row needs would leave the claims card carrying them for nothing.

**The sweep's connection already returns issues.** `search(query:, type: ISSUE)` serves both kinds
of node; the inbox sweep simply asks for `... on PullRequest` and drops the rest. ADR 0027 already
made one sibling read on that connection — the closed-pull-request search, "the open prefix with
one word changed" — and it inherited the paging, the retry, the `Retry-After` backoff, the
rate-limit snapshot and the request log by construction.

**Every derived table so far is pruned by a cascade onto `pull_requests`.** `search_index`
(ADR 0019), `triage_verdicts` (ADR 0023) and `review_snapshots` (ADR 0028) are all *about* a pull
request in the inbox and all disappear with it; `pull_request_outcomes` (ADR 0027) is the single
exception, and it earns the exception by being about pull requests that have **left**.

**⌘K's search document is pinned by name and by field list.** ADR 0019 states what is indexed —
title, identity, labels, author, branch, description, changed paths, added diff lines — and the
weights each of those carries. An issue has three of those eight fields and will never have the
other five.

## Decision

### A new persisted row, beside `IssueSummary` rather than instead of it

`ShepherdCore/Models/Issue.swift` adds four types and changes nothing:

- `IssueRelation` — `assigned`, `authored`, `mentioned`. Three cases, because the rail offers
  three facets; a relation nothing can produce would be a case every `switch` handles for nothing.
- `LinkedPullRequestReference` — repository, number, title, GitHub's raw `state`, author. Stored
  **by value**, repository included, because the linked pull request may not be in the local inbox
  at all.
- `IssueRowSummary` — the row: node id, repository, number, title, author, `createdAt`,
  `updatedAt`, `closedAt`, state, raw `stateReason`, labels, relations, comment count, and the
  linked pull requests. `state` is `IssueSummary.State`, reused rather than re-declared: the
  open/closed/unknown vocabulary is the one thing the two types genuinely share.
- `IssueDetail` — the row plus `bodyMarkdown`, and nothing else. No comments, no timeline: the
  detail panel shows title, body, labels and links, so there is no `PullRequestDetail.timeline`
  twin to keep in step with a table nobody asked for.

`hasAgentPullRequest` is **derived** from the links' own provenance (`ActorKind.isMachine`, ADR
0008's detector unchanged) rather than stored beside them, which is what makes the facet, the chip
and the denormalised column below unable to disagree.

### The sweep is a sibling, not a mode

`IssueQuery` sits beside `InboxQuery` with the same shape and one word changed —
`is:issue is:open archived:false` — and carries the three facets the roadmap names and no
`involves:@me` catch-all: an issue reaches somebody by being assigned to them, opened by them or
mentioning them, and a fourth search would spend a call per cycle on rows the other three already
returned. `GitHubClient.searchOpenIssues(queries:)` is `searchOpenPullRequests`'s twin down to the
five-page cap and the merge-by-id, so it inherits every transport property rather than growing a
second read path, and it adds **no host**: this is `api.github.com`, through the same client, with
the same token.

The links come from `Issue.closedByPullRequestsReferences(first: 5, includeClosedPrs: true)`,
selected **inside** the sweep for the reason `statusCheckRollup` sits inside the pull-request
sweep's `commits` selection: it is one more nested selection on a connection that is being paged
anyway, not a second round trip. `includeClosedPrs: true` is deliberate — an issue whose fix merged
last week is exactly the row somebody wants the link on.

**The `timelineItems` shape is kept as a fixture-tested fallback mapper.**
`closedByPullRequestsReferences` is part of the public schema and needs no preview header, so it is
the primary read; `CROSS_REFERENCED_EVENT` and `CONNECTED_EVENT` have been present for years and
carry the same two facts more verbosely. Both shapes have a fixture and a mapper, neither of which
the client sends by default, so a schema regression is a one-line switch rather than a rewrite —
and the *reason* the fallback needs its own logic is in its mapper: a connected event is always a
link, while a cross-reference is any mention, so only `willCloseTarget` separates "will fix this"
from "talked about this".

The facet merge is `mergeFacetResults`'s twin with one addition: the **links are unioned too**,
keyed by `owner/name#number`. `first: 5` caps each answer separately, so keeping only the freshest
copy's list would quietly drop a link the other two facets could see.

### Migration v7: four tables at once, and the two linking ones up front

`issues`, `issue_search_index`, `issue_linked_pull_requests` and `pull_request_closing_issues`, in
that creation order (so `DatabaseSchema.allTables` reversed is a foreign-key-safe deletion order,
which is what `eraseAllData()` walks). Landing all four now — although only the issues sweep writes
two of them today — means the sprint that fills in the `owner/repo#N` links in both directions
needs no migration of its own, and cannot end up ordered after a migration that depends on it.
`createV1` already establishes that one migration may create several related tables.

Five decisions live in that DDL, each mirroring a precedent:

- **`issues` follows `pull_requests`' exact column shape** for the author, the agent, the relations
  and the labels, so `IssueRecord` and `PullRequestRecord` share `ColumnCoding`'s helpers instead
  of inventing a second encoding for the same values.
- **`linkedPullRequestCount` and `hasAgentLinkedPullRequest` are denormalised onto the row**, the
  same choice the check rollup makes: the "has an agent pull request" facet filters the whole inbox
  on every click, and a scan across a side table for something the sweep already knows is the wrong
  shape. The full list stays in the side table for the panel; the two columns live on the row for
  the facet, and both are re-derived from the list on every write.
- **`issue_linked_pull_requests` has no foreign key onto `pull_requests`.** The linked pull request
  may be somebody else's, or never fetched, so the row is about what the sweep saw and not about a
  join that might not resolve — the reasoning `pull_request_outcomes` gives for storing its
  repository by value.
- **`pull_request_closing_issues` *is* keyed by `prID` and cascades with it**, because unlike the
  outcome table it is about a pull request that is in the inbox and disappears with it, exactly as
  `changed_files` does.
- **`issue_search_index` copies `search_index` (v3)** — nullable `vector`, the `documentHash` gate,
  `dimensions` stored beside the blob — for the reason ADR 0019 gives: two documents built by two
  schema versions must never be compared, and a gate this shape is already tested.

`repos` is now the parent of two cascading tables, so the repository prune is **shared**: a prune
that looked only at `pull_requests` would delete a repository the user has issues but no open pull
requests in, and take every one of those issues with it. That is one clause in one function
(`pruneOrphanedRepos`), called by both sweeps, and it has a test.

### The prune guard is the pull-request guard's outbox half, and only that half

`issuePruneGuardSQL` keeps a row alive while a `pending`, `sending` or `conflicted` outbox row
targets it. There is no `review_drafts` clause, because an issue has no review to draft. The outbox
names the node it targets in its existing `prID` column whichever kind of node that is: a second
column would be `NULL` for one of the two kinds on every row, and the guard is a question about
"is something queued against this id".

"Departed" is therefore **what the prune actually removed**, not what the search stopped returning
— the same definition `SyncEvent.prMerged` uses, and for the same reason: a row the guard kept is
not gone, and announcing it every two minutes for as long as the queued write lives would be wrong.

### The second sweep runs in the first one's cycle

`SyncEngine.runSweep()` calls `runIssueSweep()` in the same pass: no second timer, no second
cadence setting, because the two sections are read together and a user who presses *Refresh now*
expects both to move. It goes through two ports of its own — `IssueFetching` and `IssueSyncStoring`,
handed over together as `IssueCapture` — for ADR 0027's reason, so the engine keeps building and
testing on Linux against fakes and an engine built without them sweeps exactly as it did before: no
extra request, no extra query.

Two properties are load-bearing:

- **It cannot fail the cycle.** `runIssueSweep()` does not throw; a failure becomes one
  `SyncEvent.syncFailed` on the sweep stage. A GitHub account with issues disabled, or one search
  that timed out, must not take the review inbox down with it, and the review inbox is what
  Shepherd is for.
- **It is *reported* rather than swallowed**, which is the opposite of the track record's capture
  (ADR 0027). The user asked for this section; an inbox that is quietly two days stale is worse
  than a line saying what happened.

**No new `SyncEvent` case, and no new setting.** The digest line this block eventually wants reads
stored rows off `updatedAt` the way `DigestReport.make`'s review-request section already does, and
no notification bullet asks for an event. A "new issue assignment" notification would be a new case
*then*, added with the feature that wants it.

### A sibling search index, not a widened one

`IssueSearchDocument` is `SearchDocument`'s sibling with four fields — `title` (3), `identity` (3),
`labels` (2.5), `body` (1) — the same weights those fields carry there, and no `branch`, `paths`,
`added` or `author`. `IssueSearchRanker` duplicates the BM25 loop, the exact-reference override and
the similarity floor, sharing `SearchRankingOptions` and the two standard constants so a query
cannot be scored on two different curves depending on which section of the palette answers it.
`SearchQuery`'s parser is reused as it stands: `owner/name#128` and `#128` mean the same thing on
either side, and GitHub draws issues and pull requests from one number sequence.

Widening `SearchDocument` instead would mean either three permanently-`nil` fields for one of the
two kinds it would then represent, or a protocol earning an abstraction over two call sites that
will keep diverging — an issue gains no diff, ever. This codebase already answers "alike but not
the same thing" with a sibling (`ClosedPullRequestReading` beside `PullRequestFetching`,
`OutcomeCapture` beside `SyncStoring`), and ADR 0019's own field list is pinned by name.

One deliberate divergence: a query that is nothing but a `risk:`/`kind:` token returns **nothing**
here where its twin returns a listing. A structured-triage verdict is a statement about a pull
request (ADR 0023); there is no issue the filter could have narrowed, and listing the whole inbox
in answer would be an opinion nobody asked for.

## Consequences

- **Three more searches per cycle, and no new host.** The issues sweep is three
  `search(type: ISSUE)` calls on `api.github.com` beside the inbox sweep's five, at the same
  cadence, through the same client and the same conditional-request and rate-limit machinery. No
  outbox action, no webhook, no telemetry, and nothing in this ADR is a write.
- **Nothing about `pull_requests` changed shape.** The pull-request row, its records, its store and
  its search document are untouched; the only edit outside new files is the repository prune's
  second clause, which exists because `repos` now has two cascading children.
- **`IssueSummary` still means what it meant.** The claims card's read is unaffected, and a reader
  who finds both types has one sentence in each explaining which question it answers.
- **The facet is honest about what the sweep can see.** `first: 5` means an issue with a sixth
  linked pull request shows five; `hasAgentPullRequest` is true when *any* of the ones stored is
  machine-authored, so it can only ever understate. The chip beside a link carries the login, the
  kind and the agent's name — the sweep selects no branch name for a linked pull request, so
  branch-prefix detection cannot fire for one, which is the same information GitHub shows beside
  the link itself.
- **An issue can be held open indefinitely by a stuck outbox row**, exactly as a pull request can
  by a `conflicted` one. That is the guard working: the alternative is a queued write with nothing
  to apply itself to.
- **Two search indexes to keep fed.** The coordinator in the app target has to run a second pass
  over a second corpus and merge two ranked candidate sets into the one ordered list ⌘K's "the
  keyboard does not notice" rule requires. That is the price of not widening a type ADR 0019 pins,
  and it is one loop with two bodies rather than one body with three optional fields.
- **The linking tables exist before anything writes them.** `pull_request_closing_issues` is an
  empty table with a record type and no writer until the linking sprint lands — which is the
  *Sprint 3 — linking* amendment below. An empty table is cheap; a migration ordered after the
  feature that needs it is not.

---

## Amendment, 2026-09-03 — Sprint 2: a picker, not a route; the facets; the additive grammar

The data half above is what the section stands on. This amendment records the three decisions the
*section itself* makes, all of them taken in the founder review of 2026-09-03
(`docs/plans/issues-inbox.md` §10).

### One `InboxScreen` with a content-kind picker

`ContentKind { pullRequests, issues }` is a segmented control at the top of the rail, and
`InboxScreen` holds both models for its own lifetime and switches which one drives the rail, the
list and the panel. It is **not** a second top-level route, and the reason is that the keyboard
already works this way: `j`/`k`, ⌘K, the focus session and the menu-bar item all address *the
model that owns the selection* rather than a screen. A route would therefore duplicate the
toolbar, the digest card, the Settings sheet and the palette overlay for one control's worth of
difference — and it would give the focus session a second place to be started from.

Three properties fall out of holding both models rather than rebuilding one:

- **Switching the section disturbs nothing.** The pull-request model keeps its smart view, its
  facets, its cursor, its ticks and its half-typed key sequence, because it is never told anything
  happened. Both lists raise the same `ShortcutAction.selectNext`/`selectPrevious`, and the screen
  routes it to whichever section is showing.
- **Every other command stays a pull-request verb.** `r a`, `m`, `x` and the bulk actions are
  refused with one line while the issues section is up, rather than acting on a pull request the
  user cannot see. The two exceptions are the focus session, whose queue comes from the session's
  own observation and not from a screen's list, and the grouping commands, which change a
  preference.
- **The chosen kind is remembered per window, in `@SceneStorage`.** Not `@State`, because
  `InboxScreen` is rebuilt whenever the route changes and the picker would snap back to *Pull
  requests* after every trip to the review screen — including the trip a linked pull request in
  the issue panel just made. Not `AppSettings`, and therefore **not** in `SyncedSettingsDocument`
  (ADR 0014): which section a window happens to be showing is not a preference, and travelling
  between a user's Macs it could only ever arrive wrong.

`IssueInboxModel` mirrors `InboxModel`'s shape and diverges in one place: it is built from a
`DatabaseManager` and the existing `IssueFetching` seam rather than from a `SignedInSession`. The
narrower dependency is what makes its facet counts and its selection pruning testable without a
Keychain, a token or a network — the argument the claims card already makes for the same seam. It
also settles `IssueFilter.now`: the observation is as wide as the section and the facets narrow it
in Swift, so the model states one moment and no predicate ever reads the clock inside an
observation key.

### The facet list, and what each one is honest about

Four, in the order a triage pass reads them, and every one of them omits a level nobody is in —
the rule the AGENTS and REPOSITORIES facets already follow, because a rail row that filters to an
empty list is a dead end you have to click to discover.

| Facet | Where the logic lives | The honest part |
|---|---|---|
| **Agent pull requests** — *Nothing started yet* / *Has an agent pull request* | `IssueFacets.agentPullRequestFacets`, reading `IssueRowSummary.hasAgentPullRequest` | Drawn only when both halves are populated, so it can always narrow something. It can understate and never overstate: `first: 5` is what the sweep saw. |
| **Labels** | `IssueFacets.labelFacets`, sorted by count then name (case-insensitively, so equal counts keep their order between sweeps) | Capped, with the overflow counted in the same value as the rows — so the list and the "+3 more…" line cannot come from two different sorts. |
| **Age** | `IssueFacets.ageFacets` over `IssueAgeBucket` | Buckets `createdAt`, never `updatedAt`: an issue somebody commented on this morning has not become a new issue. |
| **Repository** | the model, mirroring `InboxModel.repositoryFacets` | The existing comparison (`isSameRepository(as:)`), so a link's casing resolves. |

All four are counted over the **whole section** rather than over the filtered list, exactly as the
pull-request rail's are: a facet whose counts changed when you selected one of its own rows could
not be used to compare them. The counting is pure and lives in
`ShepherdCore/Triage/IssueFacet.swift`, tested on the Linux runner.

There is deliberately **no smart view, no grouping and no sort picker** on this side. The rail's
four smart views are review states; grouping and sorting would need a second vocabulary beside
`InboxFacet`/`InboxSortOrder`, and nothing asks for one — the order is the store's, most recently
updated first.

### The detail panel, and the hole Sprint 3 fills

`IssueDetailPanel` shows the provenance chip (unchanged — an issue's author comes from the same
`AgentDetector`), the state with GitHub's raw `stateReason` printed rather than translated, the
age, the labels, the body through the *same* `AttributedString` renderer the pull-request
description uses, and the "Linked pull requests" section built from
`IssueRowSummary.linkedPullRequests` at zero extra GitHub calls.

A row opens the review through `AppEnvironment.openReview(prID:)` when the pull request is in the
local inbox and github.com when it is not — the reference stores its repository by value precisely
because the second case is normal. `IssueLinkedPullRequestRow` carries an empty, commented
`badge` slot; the CI dot and the review decision Sprint 3 adds are resolved by a **local join**
against `pull_requests` and arrive as a view passed into that slot from a file of their own, so
the row never grows a database read. No comments and no timeline, as decided above.

### The grammar stays additive, and the section token is the odd one

- `DeepLink.issue(repo:number:)` ⇄ `shepherd://issue/<owner>/<repo>/<number>`, through the same
  three validators as `.pullRequest` — GitHub draws issues and pull requests from one number
  sequence, so one rule for both.
- `InboxDeepLinkFilter.issues` ⇄ `shepherd://inbox?filter=issues`. It names the *section* rather
  than a rail state, so `InboxRailSelection` answers `nil` for the smart view and the
  pull-request rail is left exactly as the user set it up. Widening it the way a facet token does
  would silently change what they come back to.
- `shepherd issue <owner>/<repo>#<number>` and `shepherd inbox issues`, with the reference reader
  now shared by both verbs and parameterised on the github.com path segment, so the two cannot
  drift into accepting different references. Usage and `--help` in the same commit, as ADR 0013
  requires.
- `DeepLinkRouter` follows `openPullRequest`'s rule unchanged: cache first, then one fetch of that
  one issue, stored with `pruneMissing: false` because a link is not a sweep and must not be
  treated as the complete set. That fetch is `GitHubClient.issueRow(repo:number:)` — the sweep's
  own field set under `repository { issue(number:) }`, so a row a link produced cannot be shaped
  differently from a swept one, and it claims no relation.

### ⌘K: two corpora, one slice

`SearchIndexCoordinator` runs a second pass over `issue_search_index`, triggered by a second
observation on the session (`onIssueRows`) — which is the only announcement the issues sweep
makes, since it emits no `SyncEvent` by decision above. The pass is the first one's twin: the
`sourceFingerprint` decides whether a body is read back out of SQLite, and only then does the
`documentHash` decide whether an embedding is spent, with `detailFetchedAt` in the first hash so
that opening an issue grows its document on the very next pass. *Rebuild index* clears both
tables, and the Settings line adds `issueSearchIndexStatistics()` to the one byte count the card
reports.

`CommandPaletteView.PaletteRow` gains a third case. Both ranked sets are computed to the same
limit and then **merged by score and sliced once**, which is what ADR 0019's "the keyboard does
not notice" rule needs: the palette has room for a fixed number of rows, and a quota per kind
would let a weak issue push out a strong pull request. Ties break towards the pull request and
then on node id, so the order is total. Selecting an issue row goes through
`AppEnvironment.openIssue(issueID:)` — one route, which is what makes "switch the section *and*
reveal the row even when a facet is hiding it" impossible to half-implement.

The one deliberate divergence from ADR 0019 stands and is now also enforced in the app layer: a
query that is nothing but a `risk:`/`kind:` token answers with **no issues at all**, and spends no
embedding finding that out.

### Consequences of this amendment

- **A second `ValueObservation` on `issues`, on the session.** The issues model observes again for
  its own filtered view, so there are two local `SELECT`s per issue write while the section is on
  screen. That is `inboxRows`' price paid a second time, for its reason: ⌘K has to be able to
  answer with an issue from the review screen, where no `IssueInboxModel` exists.
- **A pull-request verb raised while the issues section is up is refused, not queued.** One toast,
  one sentence. The alternative — acting on the invisible pull-request selection — is the failure
  this rule exists to prevent.
- **`@SceneStorage` is the first per-window UI state in the app.** There was no existing mechanism
  for it; `@State` in `InboxScreen` was the closest thing and it does not survive the route swap.
  Anything else that needs per-window state should use the same one rather than inventing a third.
- **Nothing about the pull-request section changed shape.** `InboxModel` gained one guard in
  `apply(_:)` and `InboxRailSelection` gained an optional smart view and a content kind; the
  Settings row moved into a shared `RailSettingsRow`. `InboxSidebar`, `InboxListView` and
  `InboxDetailPanel` are otherwise untouched.

### Sprint 3 — linking

The link is read in **both directions**, and each direction is read where the round trip already
happens.

**Issue → pull request is the sweep's own nested field, not a per-issue fetch.**
`closedByPullRequestsReferences` was already selected inside `searchIssues` (above); this sprint is
what *stores* it — `saveIssueSummaries` replaces `issue_linked_pull_requests` and re-derives the two
denormalised columns from the list on every write — and what draws it. A per-issue detail fetch for
the links would have cost one request per row of a section that redraws whenever a sweep lands, to
learn something the page being paged anyway already carries. `fetchLinkedPullRequests(issueID:)` is
the narrow read for the panel that lists them, and it is the honest read after a *detail*-shaped
write, where `saveIssueDetail` deliberately leaves the stored links alone because an empty list
there means "this fetch learned nothing about them".

**Pull request → issue is one more field on the existing detail fetch.**
`GraphQLDocuments.pullRequestClosingIssues` (`closingIssuesReferences(first: 10)`) is sent from
inside `GitHubClient.fetchDetail(repo:number:)`, beside the `reviewThreads` call that is already
GraphQL, and maps onto `LinkedIssueReference` — `repo`, `number`, `title`, `state` — carried on
`PullRequestDetail.closingIssues` and stored in `pull_request_closing_issues`, replaced on every
`savePullRequestDetail` exactly as `changed_files` is. Three details are decisions:

- **It is the one read of that fetch whose failure is tolerated.** Without the files, the commits
  or the threads there is nothing to review, so those errors travel; the closing issues are a
  section *above* the description, and a token that cannot see the issues' repository must cost the
  section rather than the review. The attempt is still in the request log, which is this package's
  only logging channel.
- **Empty means "no section", whichever way it got there.** A pull request that closes nothing and
  one whose links GitHub declined to resolve are the same blank, because a reader cannot act on the
  difference and a "could not read the links" line on every pull request would be noise.
- **`PullRequestDetail` decodes tolerantly.** Every list defaults to empty on the way in and the
  summary stays required, so a record encoded before this field existed is still a record. That is
  `Claim`'s rule, applied to a bigger type.

**CI state on a linked pull request is a local join, never a second fetch.** The sweep's link
carries a number, a title, a raw state and an author, and nothing about checks or reviews. So
`LinkedPullRequestStatus` (app target) looks the pull request up in `pull_requests` by
`(repo, number)` — `fetchPullRequestSummary(repo:number:)`, the store's only lookup without a node
id, on `idx_pull_requests_repo_number` — and shows the *cached* `checkRollup` and `reviewDecision`
through the inbox row's own components. When the pull request is not cached, which is what
somebody else's fix looks like, the badge draws **nothing**: an absent rollup is not a grey dot,
and "unknown" is not "no checks". The whole feature therefore adds **no GitHub request** beyond the
one field above, and no host — this is ADR 0006's "the UI renders from the database", and the
reasoning the digest gives for reading inbox rows rather than fetching state of its own.

One consequence worth stating: the two directions can disagree, and that is correct rather than a
bug to fix. `issue_linked_pull_requests` is what the *issues sweep* saw, capped at five;
`pull_request_closing_issues` is what a *pull request's detail fetch* saw, capped at ten; neither
is derived from the other, and an issue nobody assigned to the user is in the second table and
never in the first. A join between them would have to invent an authority that does not exist.
