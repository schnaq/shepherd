# ADR 0041: Merge series — several pull requests, one after another, per repository

Status: Accepted · Date: 2026-09-25

## Context

Agents open pull requests faster than anyone merges them. A morning often ends with five green
agent pull requests in one repository that the reviewer has already decided to take. Bulk triage
(ADR 0015) can queue all five merges at once, but that only works when nothing moves in between.
Once the first one lands, the others are *behind* their base. On a repository that requires
branches to be up to date, GitHub refuses those merges (`405`), and the outbox parks them as failed
writes. Merge when checks pass (ADR 0037) waits for *one* pull request's build, and it gives up as
soon as the head moves, which is exactly what bringing a branch up to date does.

What is missing is an order. Merge the first, wait for GitHub to confirm it, bring the second up
to date, wait for its checks, merge it, and so on. When one fails, leave it and carry on with the
next. Christian asked for this on 2026-09-24. Most of these pull requests are independent agent
pull requests; stacks, meaning pull requests that build on each other, also occur. GitHub has
supported stacks natively since 2026-07-30 (public preview), including merging a whole stack, so
stacks get their own decision later, and this one does not try to rebase anything.

## Decision

### A series is an ordered list per repository, confirmed once

The inbox's ticks gain **Merge one after another…**, next to the bulk actions. Its sheet groups the
ticked pull requests by repository. It offers each repository's list in an order the reviewer can
drag, pre-sorted smallest first (fewest changed lines, then oldest), because small pull requests
cause the fewest conflicts for the ones after them. One merge method and one "delete branch" box
apply to the whole series. The sheet leaves out, with a reason, any pull request that could never
merge: draft, conflicting, changes requested, the reviewer's own pull request, a failed build, or a
merge already on its way. Running checks are *not* a reason to leave a pull request out, because
waiting for them is the point of the feature. Pressing **Start** is the only confirmation. From
then on nothing asks again.

Repositories run in parallel. Within a repository the series is strict: only the first unfinished
entry is active, and the next becomes active only once GitHub has confirmed the merge before it
(`mutationSent(.merged)`), or once that entry has been skipped.

### Each step reuses the existing merge path

The active entry is driven by the inbox sweep, like ADR 0037, and decided by one pure function,
`MergeSeriesPolicy.step`. The steps:

1. **Behind its base** (`mergeStateStatus == BEHIND`): queue `updateBranch(expectedHeadOid:)` in
   the outbox. That is GitHub's *Update branch* button: `PUT …/pulls/{n}/update-branch` with the
   pinned head as `expected_head_sha`. It is a GitHub API call through the outbox like every other
   write (ADR 0006), not a push. Shepherd still never pushes anything itself.
2. **Checks pending or mergeability unknown**: wait.
3. **Green, mergeable, on the pinned head**: queue the merge through
   `PullRequestActions.merge`. It is pinned to the head exactly like every other merge, and
   `hasMergeOnItsWay` still guarantees one merge per pull request.
4. **Anything that cannot turn into a merge by waiting** (failed build, conflict, draft, changes
   requested, a failed or parked outbox write for it, a merge GitHub refused, an update refused):
   mark the entry *skipped* with the reason and go on to the next entry.

### Re-pinning: only after Shepherd's own update, once

An update gives the pull request a new head commit, and ADR 0037's rule says a moved head abandons
the merge. A series therefore re-pins, but only under narrow conditions. After the drain confirms
the update it queued (`mutationSent(.branchUpdated)`), the next head the sweep reports becomes the
new pin, once. Any further change of head, or a change that arrives without such an update, skips
the entry as *head moved*. The residual race is that an agent pushes in the seconds between
GitHub's update and the sweep that reads it. That push would be merged unreviewed. It is accepted:
the reviewer asked for the series without reading each commit anyway, and bulk triage merges on
the same terms.

### `mergeStateStatus` joins the inbox query

GraphQL's `PullRequest.mergeStateStatus` (`BEHIND`, `BLOCKED`, `CLEAN`, `DIRTY`, `DRAFT`,
`HAS_HOOKS`, `UNSTABLE`, `UNKNOWN`) is fetched with every sweep and stored on the pull request row
(migration v9). The series only reads `BEHIND`. The field is optional; a server that does not send
it simply never triggers an update.

### State and visibility

- Series live in `UserDefaults` on this Mac (`automation.mergeSeries`) and are not synced, like ADR
  0037's arms. A series survives a relaunch.
- Every row that is part of a series carries a chip: *Series 2/5 · waiting*, *· updating branch*,
  *· waiting for checks*, *· merging*, *· skipped: …*. The review screen shows the same state with
  **Remove from series**.
- Settings → Sync lists running series with **Cancel**.
- When a repository's series is finished, one notification sums it up: *schnaq/shepherd: 4 merged,
  1 skipped*.
- An entry whose row has left the inbox without a confirmed merge (closed elsewhere, filtered
  out) is skipped after the grace period ADR 0037 uses.

## Consequences

- A new outbox action, `updateBranch`, and a new sent kind, `.branchUpdated`. Existing outbox rows
  need no migration (the payload is opaque).
- `PullRequestSummary` gains `mergeStateStatus`, with a database migration.
- The series never decides *whether* a pull request should be merged. The reviewer did that by
  ticking it and pressing Start. It decides only *when*, with the same pins and the same outbox as
  a merge from the sheet.
- Stacks (GitHub's native stacked pull requests) are not handled here. A stacked pull request
  can be merged only through GitHub's asynchronous merge API, which the outbox does not speak yet.
  Until that ADR exists, a series skips such a merge as *refused by GitHub* instead of retrying it.

## Amendment 2026-09-25: what implementation taught

- **Grace period is one hour**, not ADR 0037's seven days, for a missing row and for an update
  whose commit does not appear. A series is being waited on, and one stuck entry holds every
  entry behind it.
- **Behind comes before running checks.** A behind entry whose checks have not failed is updated
  at once; waiting for the old head's checks first would run CI twice per entry.
- **Checks may take a moment to register on an updated head.** A head produced by Shepherd's own
  update that shows no checks waits (up to `updateQueuedAt` + grace) instead of being skipped as
  *no checks*.
- **Fresh rows after a merge.** Once GitHub confirms entry *n* while its row is still in the
  inbox, entry *n + 1* is not stepped until a sweep shows the merged pull request gone (at most ten
  minutes): the rows until then show *n + 1* as it was before its base moved, typically `CLEAN`,
  which would queue a merge GitHub refuses. The gate is kept in memory only; after a relaunch the
  first sweep runs at once.
- **Failed writes count only from the entry's own turn**: a failed or parked outbox row counts
  against an entry only if it was created at or after the entry's `activeSince`. An old parked
  `405` from an earlier bulk merge does not skip it, and a failed row never counts as a write in
  flight.
- **Outcomes are also read off the outbox.** A `merging` entry whose row left the outbox without a
  failure and whose pull request left the inbox is asked about once per pass on GitHub
  (`GET …/pulls/{number}/merge`): merged → merged, not merged → skipped as *left the inbox*, no
  answer → asked again next pass. An `updatingBranch` entry whose row left without a failure was
  accepted. Only merge and update-branch rows count; an outbox that cannot be read skips the pass
  instead of reading as empty. The events are the fast path, not the only one.
- **A `merging` entry is bounded.** With no outbox row, no failure, no confirmation and the pull
  request still open for an hour after the merge was queued (`mergeQueuedAt`), it is skipped as
  *merge refused*: the merge was never written or its row was discarded. For the same reason
  *Remove from series* and *Cancel* take out a `merging` or `updatingBranch` entry once the outbox
  holds no unsent row for it. While an update is still unsent, Remove is not offered, and Cancel
  lets the update go out and removes the entry once it is settled, never merging it.
- **No draft-conflict alert or notification for a series' update.** A stale pin on a branch update
  parks the row as a conflict, and the drain raises `draftConflict`. For an entry the series is
  updating from exactly that pin, the "review not sent" alert and notification are suppressed;
  the series skips the entry as *update refused* and says so in its chip and summary.
