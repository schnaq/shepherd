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
  2. Poll `GET …/merge-async/{uuid}` a few times with a short delay, for about 30 s in total.
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
