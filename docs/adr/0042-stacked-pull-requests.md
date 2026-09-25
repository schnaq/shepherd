# ADR 0042: Stacked pull requests — shown as a tag, merged through GitHub's asynchronous merge

Status: Accepted · Date: 2026-09-25

## Context

GitHub has supported stacks natively since 2026-07-30 (public preview). A stack is an ordered
series of pull requests in one repository. The bottom one targets the trunk, and each one above
targets the branch of the one below. Merging a pull request in a stack merges every pull request
below it too, atomically: the whole group merges, or joins the merge queue, or nothing does. The
pull requests above stay open, and GitHub re-targets and rebases them itself.

Shepherd knew nothing about this, and that caused three problems.

1. A stacked pull request looked like any other. Nothing said that it builds on #412, or that
   merging it also merges #411.
2. **Merging one could not work.** A stack cannot be merged with the synchronous
   `PUT …/pulls/{n}/merge` that every Shepherd merge uses. GitHub requires the asynchronous merge
   API for it.
3. A merge series (ADR 0041) would bring an upper stack pull request "up to date" with *Update
   branch*, which is work GitHub does itself after the lower merge.

The schema was verified on 2026-09-25 against GitHub's GraphQL introspection and REST reference:

- GraphQL: `PullRequest.stack: PullRequestStack` has `number`, `size` and `baseRefName`.
  `PullRequest.stackEntry: PullRequestStackEntry` has `position`.
- REST: `PUT /repos/{o}/{r}/pulls/{n}/merge-async` takes `sha`, `merge_method` and `merge_action`,
  and answers `202` with `status` (`pending` | `merged` | `enqueued` | `failed`) and `details.uuid`.
  `GET …/merge-async/{uuid}` reports the same shape for 24 hours.

## Decision

### The sweep reads stack membership; the row shows it as a tag

The inbox sweep asks for `stack { number size baseRefName }` and `stackEntry { position }`, and
`PullRequestSummary.stack` stores them (`PullRequestStack`: number, size, position, base branch).
They are persisted in migration v10. The row carries a small chip, **Stack 2/3**. A stack is *not*
a grouping. Christian wants provenance to stay the grouping, and a chip neither moves rows nor
competes with the agent section.

The detail panel and the review screen list the stack from bottom to top: every row of the same
repository and stack number that the inbox holds, in position order. The current pull request is
marked, and each row is clickable.

### A merge of a stacked pull request goes through the asynchronous API

The outbox's `.merge` action stays the one merge write (ADR 0006). The drain chooses the endpoint:

- **Not in a stack**: the synchronous merge, exactly as before.
- **In a stack**:
  1. `PUT …/merge-async` with the pinned head as `sha`.
  2. Poll `GET …/merge-async/{uuid}` a few times with a short delay, for about ten seconds in
     total (3 polls × 3 s; see the amendment).
  3. The outcome:
     - `merged` → the row is sent, and the usual `mutationSent(.merged)` fires. The PRs below
       leave the inbox on the next sweep.
     - `enqueued` → sent, as `.mergeEnqueued` (*queued on GitHub*).
     - `failed` → the row is marked failed with GitHub's message.
     - Still `pending` after the polling window → sent, as `.mergeStarted`. The sweep then shows
       the result: the pull request leaves the inbox, or it stays open.

  The drain looks up stack membership in the stored pull request, which the sweep keeps current.
  The action itself needs no new field, so no outbox migration.

### The merge sheet says what else merges

For a stacked pull request that is not at the bottom, the merge sheet names the pull requests below
it that merge along ("Also merges #411 and #410, the pull requests below it in the stack"). The
button stays **Merge**, because this is what GitHub does and there is no way to merge the upper one
alone.

### A merge series knows about stacks

- The planner puts members of one stack in position order (bottom first), ahead of the size order.
- The series never queues *Update branch* for a pull request that is above the bottom of a stack,
  because GitHub re-targets and rebases those itself. The series waits for the new head instead,
  and re-pins once, under the same rule as after its own update (ADR 0041).
- When a lower entry's merge takes upper entries with it (the series merged #3 of a stack, and
  #1 and #2 are in the same series), those entries leave the inbox. The existing vanished-merge
  check confirms them with GitHub as merged.

## Consequences

- One more nested selection on the sweep query, plus migration v10.
- Two new GitHubKit calls (`mergePullRequestAsync`, `asyncMergeStatus`) and two new sent kinds
  (`.mergeEnqueued`, `.mergeStarted`).
- A stacked merge's final outcome can arrive after the drain has let go of the row. It is then
  read off the next sweep, not off the outbox. That is the honest shape of an asynchronous API.
- Creating, extending or dissolving stacks (`POST /stacks`, `…/add`, `…/unstack`) stays on
  github.com and in `gh stack`. Shepherd shows stacks and merges them; it does not build them.

## Amendment 2026-09-25: implementation notes

What the build does, where it differs from the decision above, and what it leaves open.

- **The seam.** The drain gets stack membership through `StackMembershipLookup`, a closure on
  `SyncEngine.init`. It defaults to "never stacked", so every caller from before stacks merges
  synchronously, as before. The app wires it in `SignedInSession` to
  `DatabaseManager.isInStack(prID:)`. That read uses the same record as the row's chip: a pull
  request counts as stacked when all four stack columns hold a value. A pull request the inbox
  does not hold counts as unstacked. A lookup that throws means a retry, never a guess about the
  endpoint.
- **A stack newer than the sweep.** The stored summary can lag: a pull request stacked since the
  last sweep reads as unstacked, and the synchronous merge refuses it. When it refuses with `405`
  (and the pull request is not merged already) or `422`, the drain asks GitHub once
  (`pullRequestIsStacked`, REST `GET …/pulls/{n}` read for its `stack` object). If the pull
  request is stacked, the drain merges it through `merge-async` in the same step. Otherwise the
  refusal stands as before.
- **No branch deletion for a stack.** The drain never runs the branch-deletion follow-up after a
  stacked merge. GitHub re-targets the pull requests above and manages the stack's branches. The
  merge sheet shows *Delete the branch afterwards* as off and disabled for any stacked pull
  request, with a one-line reason. It queues the merge with `deletesHeadBranch: false` and leaves
  the remembered setting alone. The merge series sheet keeps its box, which still applies to the
  pull requests outside a stack. When any of them is stacked, its note adds "Branches of stacked
  pull requests are left to GitHub."
- **`409` means already enqueued, when it says so.** On `merge-async`, `409` is documented as "a
  merge request is already enqueued for this pull request", not a moved head. The drain sends such
  a row as `.mergeStarted`, so a crash after the `PUT` re-sends the row without that reading as a
  refusal. Only when GitHub's message says so, though (`GitHubClient.isMergeAlreadyUnderWay`,
  ignoring case: "already" together with "enqueued", "in progress" or "merge request"). Any other
  `409` is parked like a moved head, because nothing says it is harmless.
- **An unreadable acceptance is still an acceptance.** A `2xx` from `merge-async` whose body does not
  decode reads as `pending` without a uuid. The drain sends that as `.mergeStarted` without polling,
  and the sweep settles it. Failing the row would offer a retry of a merge that is running.
- **`400` means not mergeable.** `400` maps to `notMergeable`, as the synchronous `405` does. One
  `isPullRequestMerged` read tells a real refusal apart from a pull request that is already
  merged. A head-SHA `422` maps to `staleHead` and is parked. A `failed` status whose message
  names the head is parked as well.
- **Merge-queue timeout.** A merge series lets a `merging` entry go as *merge refused* when its
  outbox row is gone, its pull request is still open and nothing has been confirmed for an hour
  (ADR 0041). An accepted stacked merge looks exactly like that while GitHub's queue works. On
  `.mergeEnqueued` or `.mergeStarted` the coordinator therefore records `mergeAcceptedAt` on the
  entry (`MergeSeries.markMergeAccepted`). The deadline is then 24 hours from the acceptance, which
  is how long GitHub keeps an asynchronous merge's result
  (`MergeSeriesEntry.unconfirmedMergeDeadline`). The first acceptance counts. The event lives only
  in memory, so it is not the only signal. Any entry with a recorded `stackNumber` gets the same 24
  hours, counted from `mergeQueuedAt`, because a stack is always merged through the asynchronous
  path. An app that quits before the event arrives therefore still waits the day.
- **Planner order.** Members of one stack are not ordered through a comparator: "same stack →
  position, otherwise size" is not transitive, so a sort that used it would be undefined. The size
  order is computed first. Then each stack's members are written back into the slots they landed
  in, in position order. An unrelated pull request keeps its slot, even between two members.
- **Reordering never inverts a stack.** The same slot rewrite (`MergeSeriesPlan.stacksBottomFirst`)
  runs after every move on the merge series sheet, so swapping two members of one stack does
  nothing. It runs once more when a series starts (`MergeSeries.init(repository:pullRequests:…)`),
  as a backstop for any caller.
- **An excluded member takes the ones above it out.** Merging a stacked pull request merges the
  ones below it. So when the planner excludes a member, every ticked member above it in the same
  stack is excluded too, as *one below it is excluded* (`belowInStackExcluded`). A member with a
  reason of its own shows that reason instead.
- **Series entries remember their stack.** `MergeSeriesEntry` stores `stackNumber` and
  `stackPosition` from the row when **Start** is pressed. The rows can't be relied on here: once
  the pull request below merges, GitHub re-numbers or dissolves the stack and rebases the one above,
  and the row's current position no longer shows that anything merged.
- **Re-pin after a lower merge.** The decision above says "waits for the new head". The build does
  not wait. A `pending` entry whose head differs from its pin is re-pinned once
  (`repinnedAfterStackMerge`) when an entry of the same stack, lower when the series started, is
  `merged`. The same applies when the restack happened outside the series, for example when the
  pull request below was merged on github.com: the row's current stack position is lower than the
  entry's recorded `stackPosition`, or the row is no longer in a stack while the entry recorded one.
  The stack number is not compared, because GitHub re-numbers the stack after a merge. An entry
  that was the bottom never counts as restacked: nothing below it can have merged. A
  seconds-old head gets the same no-checks grace as one produced by Shepherd's own
  update. A second head change is a push and is skipped as *head moved*. The series takes the new
  head when it arrives and does not wait for one: with a merge commit, a re-target can leave the
  head unchanged, and then there is nothing to wait for. An unchanged head just merges.
- **No *Update branch* above the bottom.** The row's *current* `stack.position > 1` decides. Once
  the pull requests below it have merged, a pull request is the bottom and targets the trunk, and
  updating it is the series' job again. Where the series would otherwise update, it waits.
  `restackWaitSince` bounds that wait by the series' grace period, and it is cleared once the pull
  request is no longer behind. After the grace period the entry is skipped as *update refused*
  ("GitHub did not bring the branch up to date"). Without the bound, one upper pull request whose
  lower ones never merge would hold the series for ever.
- **Taken-along entries — correction.** The decision above says the vanished-merge check confirms
  entries that an upper merge took along. That check only asks about `merging` entries. A series
  always merges a stack's members bottom first: the planner orders them that way, and neither
  reordering on the sheet nor any caller of `MergeSeries.init` can invert them. So a lower entry
  is always merged before an upper one, and this does not come up.
- **UI.** The *Stack 2/3* chip uses the neutral secondary colour. Its tooltip reads "Part of a
  GitHub stack: 2 of 3, on main". The stack card is in the inbox's detail panel under the header,
  and in the review screen's conversation tab beside *Closes*. It is built from
  `PullRequestStackOverview` over every inbox row minus the ignored ones (what the inbox itself
  holds), not the filtered list. The review screen and its merge sheet apply the same ignore
  filter. A click selects the
  other pull request in the inbox when the rail shows it, and otherwise opens its review. The
  merge sheet names the pull requests below only when the inbox holds all of them. Otherwise it
  gives the count, because naming some of them would understate what the merge takes along.
- **Poll window.** The drain holds a stacked merge for at most 3 polls × 3 s
  (`SyncConfiguration.asyncMergePollCount` / `asyncMergePollInterval`), about ten seconds. The row
  holds up every outbox row behind it while it waits, and the sweep reads the outcome later anyway.
- **Known limits.**
  - A stacked merge that is still `pending` after the poll window is sent as `.mergeStarted` and
    never emits `mutationSent(.merged)`. The row's disappearance on the next sweep is the only
    confirmation. There is no merged toast and no webhook for it.
  - REST's `stack.position` is assumed to be 1-based, like GraphQL's documented
    `stackEntry.position`. The REST reference does not say.
