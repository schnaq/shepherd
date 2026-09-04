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

---

## Amendment, 2026-09-03 — Sprint 3: the link in both directions

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

---

## Amendment, 2026-09-03 — Sprint 4a: issue writes, the `issue.closed` event and the digest lines

The section reads. This amendment records what it may now *write*, and the three decisions that
took: what a queued issue write is re-validated against, which GitHub endpoint each one uses, and
what the morning digest is allowed to say about issues.

It is deliberately **half** of the plan's Sprint 4. The other half — assigning an issue to a local
agent — waits on the owner's answer to the ground-rule question ADR 0011 raises
(`docs/plans/issues-inbox.md` §10: may an issue-origin delegation commit, push and open a pull
request with the agent's own credentials?). Nothing here anticipates that answer:
`DelegationContext.Origin` is unchanged, `DelegationPrompt`'s preamble is unchanged, there is no
new `GitWorktree` entry point, there is no "Assign to agent" button, and the second webhook event
the roadmap names — `issue.assigned_to_agent` — is **not** here. Everything below stands on its
own whichever way that decision goes.

### Five outbox actions, and no migration

`OutboxAction` gains `addIssueComment`, `addIssueLabel`, `addIssueAssignee`, `closeIssue` and
`reopenIssue`. `outbox.payload` already stores the whole enum as an opaque blob, so a new case is
additive to the Swift type and to nothing else — the same shape a new `WebhookEvent` case had —
and a row an older build wrote still decodes because its discriminator is still one of the cases.
There is no schema change in this sprint at all.

`OutboxItem.prID`, `.repo` and `.number` are reused **generically** as the target's node id,
repository and number, documented on the type and at every call site that fills them in, rather
than renamed. A mechanical rename would touch every existing pull-request write for no behavioural
change, and the one place that already asked the generic question — `issuePruneGuardSQL`, "is
something queued against this id" — was written that way in Sprint 1 precisely because the answer
was going to have to serve both kinds.

`closeIssue` carries a small `IssueCloseReason` enum rather than `merge`'s raw string, and the
asymmetry is the point: a merge method is one of three words GitHub may grow, while "completed or
not planned" is the *whole* of the choice the button offers and the two halves read differently in
the UI. A row from a build that knew a third reason simply fails to decode, which
`claimReadyOutboxItems` already skips rather than letting it poison the queue.

### The precondition is `updatedAt`, and a failed probe is not a conflict

Every one of the five carries `basedOnUpdatedAt`, and the drain re-reads the issue before it sends
anything: `GraphQLDocuments.issueState` (`id updatedAt closed`), `pullRequestHead`'s shape with the
other node in it. A mismatch parks the row as `conflicted`. This is `ReviewDraft.basedOnHeadOid`'s
rule on the field an issue actually has — GitHub moves `updatedAt` for every edit, label,
assignment, comment and state change, and an issue has no head commit to compare.

Three details are decisions:

- **It is GraphQL, not the REST `GET /repos/…/issues/{n}` the claims card makes.** That read is
  ETag-cached on its URL (ADR 0026's amendment), and a probe that can be answered out of a cache is
  not a probe.
- **A parked issue row emits no `SyncEvent.draftConflict`.** That event promises something an issue
  write cannot offer: a review draft still on disk that the user can re-apply against the new head,
  and an alert that says so. A parked issue write is parked, counted by `conflictedOutboxCount()`
  beside every other parked row, shown per issue in the detail panel, and left for the user — which
  is the whole of what ADR 0006 asks for.
- **A probe that could not be *made* is a plain failure and therefore a backoff**, not a conflict.
  The two are genuinely different: a conflict is a fact about the issue that will not change by
  waiting, while an unreachable network says nothing about the issue at all. Parking on it would
  turn every tunnel into a pile of rows somebody has to clear by hand.

The comparison has a one-second tolerance rather than being an exact `!=`. GitHub's timestamps are
second-precision ISO-8601 and the stored row holds the same parsed value, so a sub-second
difference cannot be a real edit — while an exact comparison would be at the mercy of any future
encoder that wrote a fractional second.

The writes go through a **third port**, `IssueWriting`, beside the sweep's `IssueFetching` and
`IssueSyncStoring`. `ClosedPullRequestReading`'s argument, a third time: the sweep's port is what
every sweep test already implements, and the drain is a different moment with a different failure
mode. It is handed to the engine as its own optional parameter rather than as a field on
`IssueCapture`, because that value's own reasoning — "neither half is any use without the other" —
is not true here: a drain that sends a queued comment needs no sweep.

### The label endpoint is the additive one

- `POST /repos/{o}/{r}/issues/{n}/comments`
- `POST …/issues/{n}/labels` — **additive**, never the full-replace `PATCH` with a `labels` array
- `POST …/issues/{n}/assignees` — additive for the same reason
- `PATCH …/issues/{n}` carrying `state` and `state_reason` and **nothing else**

The additive endpoints are the interesting choice. Two label writes queued a second apart would
each carry the list as it was when they were composed, so a full-replace `PATCH` would let the
second silently undo the first — a lost update the staleness probe cannot catch, because both
writes are perfectly fresh. `POST .../labels` cannot lose one. The same argument makes the state
`PATCH` carry two keys: that endpoint would happily rewrite the title, the body, the labels and the
assignees, and a body that mentioned them would overwrite whatever somebody else changed in the
meantime.

All four are `api.github.com`, through the client that already holds the token, the retry policy
and the rate-limit backoff. **No new host**, and `CONTRIBUTING.md` gains one bullet naming them
rather than a new entry.

### `issue.closed`, and an envelope with a second subject

One webhook event, fired from the outbox drain's `mutationSent` — the hook `review.submitted` and
`pr.merged` already use, and for their reason: a close still waiting out a retry has closed
nothing. It fires only for issues **Shepherd** closed; an issue closed on github.com merely leaves
the inbox on the next sweep, and a sweep of open issues cannot say why one went, which is exactly
the reasoning that keeps `pr.merged` to merges Shepherd performed.

Its envelope carries an `issue` object where every other event carries `pullRequest`. That is a
second *subject*, not a widened one: an issue has no branch, no base branch, no head SHA, no draft
flag and no diff counts, and nulling five keys on every one of them would make a receiver guard a
shape the producer never fills in — the argument this ADR already makes for `IssueRowSummary`
beside `PullRequestSummary`. It stays at `"v": 1` in the strictest sense, because no event that
existed before it gained, lost or renamed a key.

Ten keys: where it is, what it is called, who wrote it and with what provenance. No body, no
labels, no comment count, no linked pull requests — ADR 0012's rule that the payload describes what
happened and the receiver follows the `url` for the substance. `details` is `{ "reason": … }`,
GitHub's own raw `state_reason` word, unmapped.

The four other writes — comment, label, assignee, reopen — reach GitHub through the same drain and
are deliberately mapped to **nothing**. v1 promised no event for them, and adding one later is
additive.

### Two digest lines, one an event and one a state

`DigestSectionKind` gains `issuesAssignedToYou` and `agentPullRequestsThatClosedAnIssue`, both
tier 1 and both reading rows the two sweeps already wrote. Nothing in the digest's path calls
GitHub, an endpoint or a model, and that rule is unchanged.

The split between them is the same one the existing four make. "An issue was assigned to you" is an
**event** and is windowed on `updatedAt` — GitHub moves `updatedAt` when somebody assigns you, so
`createdAt` would miss the commonest overnight shape of all, an old issue handed over this morning.
"An agent's pull request closed one of these as completed" is a **state**, and is therefore not
windowed at all: a windowed version would go quiet on the second morning precisely because nothing
had been done about it, which is the failure the green-agent-pull-request line was shaped to avoid.

The plan's own §5.4 spells that second predicate with a `closedAt >= windowStart` clause while also
calling it "not windowed — a state, like the green-agent-PR line", and §5.5 asks for a *"state
survives the night"* test. The two cannot both hold, and this amendment resolves it in favour of
the state: the section is `state == .closed`, `stateReason == "completed"` (case-insensitively —
the field is raw and this is the one equality anything performs on it) and
`IssueRowSummary.hasAgentPullRequest`. It cannot repeat itself for long, and that is a property of
the data rather than a cap somebody added: the issues sweep searches `is:open`, so a closed row is
pruned on the next pass. `pull_request_closing_issues` is not read — the links on the issue's own
row are what the facet, the chip and this line all already agree on, so a second source could only
disagree.

`completed` and not any closed state, because "not planned" is a decision somebody took *instead*
of the work, and reporting it as an agent's success would be a lie.

Two consequences worth stating:

- **`DigestReport.make` gains `issues:` with a default of none**, so every existing call site both
  compiles and keeps producing the report it produced. `DigestReport.Item.prID` carries the issue's
  node id for an issue row — the same generic reuse `OutboxItem`'s three fields make, for the same
  reason, and `DigestSectionKind.isAboutIssues` is what tells a reader which it is holding.
- **The session's issue observation is now the wide one** (`includeClosed: true`). The second line
  is a statement about a closed row, and the section's own observation deliberately shows only open
  ones. Nothing on screen changes — `IssueInboxModel` keeps its own, narrower observation — and the
  extra rows exist only between a close and the next sweep. ⌘K's second corpus reads the same
  source and can therefore find an issue that was closed minutes ago, which is a better answer than
  "no results".

### The panel writes, and it writes the way everything else does

`IssueDetailPanel` gains an actions row — comment through a small composer sheet, a label picker, a
single *Assign to me*, close as completed or not planned, reopen — and every button enqueues an
`OutboxItem` and asks the engine to drain. Nothing in `Features/Inbox/` calls `GitHubClient` for a
mutation, which is ADR 0006's rule and `PullRequestActions`' shape.

Three smaller decisions:

- **The label picker is fed by the labels the section has already seen** in that repository, minus
  the ones the row carries. A `GET /repos/{o}/{r}/labels` would be a new request on every panel for
  a list Shepherd is holding anyway; the menu says what it is offering, and github.com is one click
  away for a label nothing here carries.
- **No new global shortcuts.** The issues section already refuses `r a`, `m` and `x` with one line
  (Sprint 2's amendment); giving the issue writes keys of their own would be a second verb
  vocabulary beside `ShortcutAction`, and nothing asks for one.
- **The panel shows the two outbox states the pull-request side shows** — waiting to be sent, and
  parked — about this one issue. The standing counts in Settings → Sync and the title bar are
  unchanged and already cover these rows whichever kind of node they target; the per-issue line is
  what makes them findable from where they were queued.

---

## Amendment, 2026-09-03 — closed issues outlive the sweep

Sprint 4a's second digest line — *"an agent's pull request closed one of these as completed"* —
could not fire, and the reason is one sentence: the sweep searches `is:open` and prunes every row
the search stopped returning, so an issue that closes **vanishes** on the next pass, two minutes
later. The row was never marked closed, `closedAt` and `stateReason` were never learned, and a
line that reads `state == .closed` off stored rows was reading rows that no longer existed. The
same sentence is in that amendment, phrased as a virtue — "it cannot repeat itself for long,
because the sweep searches `is:open`, so a closed row is pruned on the next pass" — and it was
wrong: the row is not pruned *after* the line has been said, it is pruned *instead*.

This amendment fixes it the way ADR 0027 already fixes the same problem for pull requests, and
takes three decisions.

### One read per disappearance, on the row that is going

`runIssueSweep()` no longer hands the search's results straight to the prune. The rows the search
stopped returning go through `captureIssueOutcomes(for:)` first, which is `captureOutcomes(for:)`
with the same shape and the same manners: **sequential**, one request each, **swallowed**
failures. The read is `GitHubClient.issueRow(repo:number:)` — Sprint 2's by-number query, already
written, already selecting `closedByPullRequestsReferences` — reached through one more requirement
on the existing `IssueFetching` port rather than through a port of its own, because unlike
`ClosedPullRequestReading` it reads the *same shape* the sweep does, through the same mapper, from
the same client.

Four answers, and the answer decides the row's fate:

| What the read says | What happens |
|---|---|
| Closed | `state`, `stateReason`, `closedAt`, `updatedAt` and `linkedPullRequests` are written onto the **stored** row, which is kept |
| Still open | pruned, exactly as today: it left the user's facets (unassigned, mention edited away), and an issue that is nobody's business here is not inbox data |
| No such issue | pruned, for the same reason |
| The read failed | the row is kept **unchanged** and read again next sweep |

The captured row is the stored one with five fields replaced, not the fetched one: a by-number read
claims no relation (`GitHubClient.issueRow`'s own decision), and the stored row is what the facets,
the search index and the digest have been reading all along. `saveIssueSummaries`' existing rule —
an empty relation set keeps what the sweep saw — makes that a belt beside the braces.

Writing the outcome **onto the row** rather than into an outcome table is the one place this
diverges from ADR 0027, and it is forced: `pull_request_outcomes` exists because a track record is
about pull requests that have left, while everything that reads a closed issue — the digest line,
⌘K's second corpus, the panel a `shepherd://issue/…` link opens — reads `issues`. A second table
would be a second source for one fact, which is the thing this ADR keeps refusing.

The reads are **capped at ten per sweep** (`SyncEngine.maxIssueOutcomeReadsPerSweep`). The
pull-request capture needs no cap because a disappearance there is a merge or a close; an issue
also disappears when somebody unassigns the user from twenty of them at once, and twenty extra
requests in one cycle is how a sweep meets the secondary rate limit. Rows over the cap are *kept*,
not pruned, so the next sweep reads the next ten and the queue drains at that rate.

### Closed rows are kept for fourteen days, and then they go

`SyncEngine.closedIssueRetention` is 14 days, measured from `closedAt` (falling back to `updatedAt`
for a row GitHub reported closed without one — a missing timestamp must not mean "keep forever").
A closed row older than that is not written back, and the sweep's own prune therefore takes it.

Fourteen days is a compromise between the two things the row is kept for. The digest line is a
**state**, not an event (Sprint 4a), so it has to survive more than one night — a retention of one
day would reintroduce exactly the failure that amendment argued against. ⌘K's second corpus reads
the same rows, and "the issue you closed last Tuesday" is a better answer than *no results*.
Against that: `issues` has no other reaper at all, because the sweep only ever searches open ones,
so without a window the table grows for as long as the app is installed. Two weeks of closed issues
is a few hundred rows at worst, and a number in a constant with a name is a number somebody can
change.

This is the second table that outlives what created it, and it now has the same obligation
`pull_request_outcomes` has: it is swept by hand, and the hand is in `runIssueSweep()`.

### Nothing on screen changes

The section's own observation (`IssueInboxModel.startObserving`) is `IssueFilter()` — `includeClosed`
defaults to `false` — so the issues list, the four facets and the counts are exactly what they were.
The session's observation is the wide one already (`includeClosed: true`, Sprint 4a), so the digest
and ⌘K see the retained rows without a line of their own, and the ⌘K corpus indexes them for the
window exactly as that amendment says it should.

The cost is one more `repository { issue(number:) }` GraphQL read on `api.github.com` per
disappearance, capped at ten per sweep, on the host that is already on `CONTRIBUTING.md`'s list.
No new host, no new table, no new setting and no new `SyncEvent`.

### And the write nobody could see

A second, smaller thing, fixed in the same pass because it is the other half of "the panel tells
the truth about the outbox". Sprint 4a's panel shows the two outbox states the pull-request side
shows — waiting to be sent, and parked. There is a third: `SyncEngine` fails an issue row
**non-retriably** when the app was built without an `IssueWriting` port, and GitHub's own 4xx
answers end the same way. Such a row is `failed`, which is neither `pending`/`sending` nor
`conflicted`, so neither counter saw it and the click looked as though it had worked.

`IssueInboxModel.failedWriteCount(for:)` counts it, `IssueDetailPanel` draws it in the failure
colour beside the other two, and `DatabaseManager.failedOutboxCount()` is the standing count beside
`pendingOutboxCount()` and `conflictedOutboxCount()`. It stays scoped to the issue panel: the
pull-request side has the same gap, and closing it there is a change to a surface this ADR does not
own.

## Amendment, 2026-09-04 — the section shows the rows it kept

The amendment above closes with a section called *"Nothing on screen changes"*, and it was true in
a way nobody wanted. Closed issues now survive on disk for fourteen days, ⌘K indexes them and the
palette draws them with a *Closed* chip — and clicking one switched to the issues section and then
showed **nothing at all**. `IssueInboxModel.startObserving()` observed `IssueFilter()`, whose
`includeClosed` is `false`, so `allRows` could not contain a closed issue in the first place;
`reveal(issueID:)` therefore took its "not cached yet" branch, parked the ask in `pendingReveal`
and waited for an observation value that could never arrive. The chip's own comment named the
reason and called it a feature — the row is "not in the open-only section" — which is a label
pasted on a dead click. The same click from `shepherd://issue/…` and from `shepherd issue
owner/repo#128` failed identically.

The fix is not "show closed issues": a triage section is a list of work still to be done, and a
backlog that mixed in everything closed in the last fortnight would be a worse list for the reader
who never asked. So the widening happens in the query and the narrowing happens in a facet, and
that split is this amendment's decision.

### The observation is the wide one; a facet keeps today's list

`IssueInboxModel` observes `IssueFilter(now:includeClosed:)` with `includeClosed: true` — the
filter `SignedInSession` has been using for the digest and ⌘K since Sprint 4a, now the section's
too, so there is one answer to "which issue rows does this Mac hold" rather than two. A fifth rail
facet, `stateFilter: IssueStateFilter?`, decides what reaches the screen and **defaults to
`.open`**.

That default is the whole of "nothing changes for a user who does not ask". `IssueStateFilter` has
two cases where `IssueSummary.State` has three, and `.open` means *not closed* rather than
*equal to open*, because that is exactly where the store's `includeClosed` has always drawn the
line: an issue whose state GitHub reported in a word this build does not model stayed on screen
before this facet existed and stays on screen now. `nil` means "open and closed", precisely as
`nil` means "all" for the four facets beside it.

The rail row is drawn as soon as **either** half is populated, which is deliberately not the
agent-pull-request facet's "both halves or nothing" rule. That rule exists because a one-sided
two-valued facet can only filter to everything or to nothing; this facet starts *selected*, so its
row is the thing on screen that says what the list is currently leaving out — and the reader whose
open list has finally emptied is exactly the reader who wants to see *Closed 3*. Its tooltip says
the part that is not guessable: the window reaches back fourteen days and an issue closed before
that is gone from this Mac, github.com being the place to look. The number is prose there rather
than interpolated, because `SyncEngine.closedIssueRetention` is internal to `ShepherdSync` and a
second hard-coded fourteen would be a worse honesty than a sentence.

### The other four facets are counted over the state facet's half

The four counts were read off `allRows`, and leaving them there would have changed every number in
the rail the moment the observation widened — a closed issue would have added itself to LABELS, to
AGE and to REPOSITORIES while the list it belongs to was not on screen, which is a rail whose
numbers nothing visible adds up to. They are now counted over `stateScopedRows`: the rows the
*state* facet has chosen. With the default that reproduces every count the rail printed before
closed rows were observed at all, and with *Closed* selected the labels, ages and repositories
describe the closed rows, which is what a reader who has just asked for them wants to read.

`stateFacets` is the one facet still counted over everything, for the reason the others are not
counted over the filtered list: a *Closed* row that vanished the moment *Open* was selected would
put the retained issues back out of reach.

One visible consequence is worth writing down, because it is a change and not a bug. The list's two
empty states are told apart by `allRows` against `visibleRows`, and `allRows` is now the wider set —
so a user whose only remaining issues are closed ones reads *"Nothing matches these facets"* where
they used to read *"No issues yet"*. That is the more accurate of the two sentences: clearing the
facets does show them, the STATE row says how many there are, and *"land here on the next sweep"*
would have been advice about rows that are already here.

### Clearing the facets clears the state, and the reveal insists

`clearFacets()` — the header's ✕ and Escape — sets the state facet to `nil` along with the other
four, which is what lets `reveal(issueID:)` keep its existing shape: select the row, then widen if
the rail is hiding it. Two details fell out of doing that honestly. The state facet is cleared
**first**, because each of the five assignments clamps the selection and clearing the widest axis
last would run four clamps against a list that still hides the row — and a clamp that lands on the
first row of the section fetches that row's body for nobody. And `reveal` asks for its row once
more after the widening, because those clamps happen one per assignment: a row that two facets
were hiding is still hidden while the first of them is being cleared, so the cursor could be moved
off it on the way through. A cursor that survived makes the second ask a no-op. `pendingReveal` is
untouched and still means what it meant: the issue is not in the local cache at all, and the next
observation value will honour the ask.

`hasActiveFacet` counts the state facet only when it is narrower than the section's default.
`.open` *is* that default and `nil` widens rather than narrows, so neither is something to tell a
user to clear.

### A closed row says it is closed

The list row draws a *Closed* chip beside the provenance chip, in the panel's and the ⌘K row's word
for it rather than a third one, and the header's facet chip says *Closed* when that half is
selected — it leads the other four there, because a list of triage work showing closed issues is
the most surprising thing that list can be doing. The detail panel needed nothing: its state chip
has said *Closed*, with GitHub's own reason beside it, since Sprint 2, and a second statement of
one fact in one panel is how two of them come to disagree.

The ⌘K row keeps its chip and loses its comment's claim. Whether an issue is already dealt with is
the first thing a reader wants off a search result, so the chip is worth its width; it is simply no
longer a warning that the click goes nowhere.

### What this does not change

No new host, no new request, no new table, no migration and no setting. The section's observation
is a wider read of a table this Mac already holds, and the rows it now carries are the ones the
sweep was already keeping. The sweep, the retention window, the digest lines and the ⌘K index are
untouched: this amendment is about which of the rows already on disk the section is willing to
draw.
