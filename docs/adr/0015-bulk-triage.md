# ADR 0015: Bulk triage — one confirmation, n ordinary outbox writes

Status: Accepted (v1.x, pulled into v1) · Date: 2026-09-01

## Context

The premise of the product is the agent-PR flood (README, ADR 0008): a handful of agents open
pull requests across every repository, most of them small, most of them green, and most of them
identical in shape — a dependency bump, a generated client, a mechanical refactor. Shepherd's
review path already makes *one* of those cheap: `j` to the row, `r a`, done. It does not make
*forty* of them cheap, and forty is the number the founder actually faces on a Monday morning.
Reviewing each one properly is the job; recording the same verdict forty times is not.

The roadmap parked this in v1.x ("bulk triage actions, one confirm"). The founder pulled it
forward, and the reason is the same one that put agent provenance in v1: without it the inbox
loses to a browser tab with forty tabs open, which is the situation Shepherd exists to end.

Two things make this more delicate than a loop around the existing approve action.

The first is that a bulk action is the one place where Shepherd could plausibly write to GitHub
on rows the user never looked at. A filter that quietly decides which of the selected pull
requests are "eligible" would be exactly that: the user ticks twelve, eight are written, and the
other four are… somewhere. Silent divergence between what was selected and what was written is
the failure mode to design against.

The second is the write path. Every mutation Shepherd performs goes through the persisted outbox
(ADR 0006): queued locally, drained by the sync engine, re-validated against the current head,
retried with backoff, parked as a conflict when the pull request moved on. A bulk action that
called `GitHubClient` in a loop would be a second write path with none of that — no offline, no
retry, no staleness check, and no `mutationSent` event, which is what webhooks hang off
(ADR 0012).

## Decision

- **The selection is visible, explicit and the user's.** Rows are ticked with `x`, ⌘-click or
  ⇧-click (range from the cursor), and the tick column appears with the first tick. The header
  shows *n* selected; Escape clears. There is a convenience — "select all green agent pull
  requests in this view" — but it only *ticks* rows; it never acts. Green means CI rollup
  success **and** mergeable **and** no changes requested **and** not a draft, and only
  agent-authored rows are preselected: a human's pull request never enters a bulk action through
  a single click.
- **One confirmation dialog, and it shows the partition.** `BulkTriageSheet` lists every
  selected pull request with the state the decision was made on (check dot, review decision) and
  says for each one what will happen: `approve`, `merge`, `approve + merge` — or `skipped ·
  <reason>`. A pull request that fails a precondition is **shown as skipped with its reason**,
  never silently dropped. Merge method is chosen here, defaulting to the last method used
  (shared with the single merge sheet).
- **The partition is a pure value, not view code.** `BulkTriagePlan` (`ShepherdCore/Triage/`)
  turns *(action, selected rows)* into an ordered list of entries, each with its steps, its skip
  reason and its caveats. The precondition order is fixed, so the reason a user is shown never
  depends on evaluation order: draft → conflicting → checks failing → checks running → changes
  requested → your own pull request → already/not approved. It is unit-tested for every case,
  including the ones that are easy to get wrong: GitHub refuses an approval on your own pull
  request (422), an already-approved pull request needs no second approval — so "approve &
  merge" degrades to a merge rather than skipping the row — and "merge selected" refuses
  anything not yet approved.
- **Preselect is conservative, the plan is permissive-with-a-note.** A pull request with *no*
  checks configured is not preselected (there is nothing green about it) but is still acted on
  when the user picks it by hand, carrying a visible `no checks` note. Unknown mergeability is a
  note on the merge step, not a refusal — the drain's merge preflight is the real guard.
- **Confirming enqueues, it does not write.** Each plan entry becomes one or two ordinary
  `OutboxItem`s through `PullRequestActions`, with the draft persisted first exactly as the
  single-pull-request path does. The approval is timestamped ahead of the merge queued behind it,
  because the drain sends rows in `createdAt` order and a branch-protection rule that needs the
  approval must see it first. The drain runs **once** for the batch instead of once per row.
- **No new GitHub call, no new event, no automation.** There is no bulk endpoint at GitHub and
  Shepherd invents none. Webhooks need nothing here: `review.submitted` and `pr.merged` already
  fire from `SyncEvent.mutationSent`, once per row, after it really reached GitHub (ADR 0012) —
  so a bulk run of twelve produces twelve honest events rather than one optimistic one. And bulk
  approve stays an explicit human action: auto-submitting reviews remains a non-goal (ROADMAP),
  and nothing here is triggered by a timer, a sweep or an AI verdict.

## Consequences

- Triaging forty green agent pull requests is one selection, one dialog and one keystroke,
  instead of forty round trips through the review screen — and it is still forty recorded,
  attributable reviews on GitHub, not a bypass.
- **One GitHub write per pull request.** A batch is *n* requests, and the outbox is the throttle:
  a drain claims at most `outboxBatchSize` (20) rows, the rest go out on the next drain, and
  GitHubKit's secondary-rate-limit backoff (`Retry-After`) applies unchanged. A user who selects
  a hundred pull requests gets a queue that empties over a couple of sweeps rather than a burst
  that trips GitHub's abuse detection. Nothing had to be added for that; it is what queueing
  through the outbox buys.
- Per-pull-request failures stay per-pull-request. One 422 does not roll back the other eleven;
  the row is marked failed or conflicted in the outbox, the conflict alert and the outbox lines in
  Settings surface it (see the amendment below), and a stale head parks that one merge instead of
  merging the wrong commit.
- The plan is the seam that makes the feature reviewable: "which pull requests does this touch"
  is answered by a tested function, and the dialog is a rendering of that function's output.
  Adding a fourth bulk action is a case in one enum plus a step rule.
- Marks are pruned to what is on screen whenever the list changes, so a bulk action can never
  touch a row the user cannot see. The cost is that switching smart views drops the selection —
  which is the honest trade: an invisible selection is worse than a lost one.
- `ShortcutAction` gained three cases, so every exhaustive switch over it had to be revisited
  (the review screen ignores them: the selection lives in the inbox). `AppSettings` gained the
  remembered merge method, which therefore also travels in `SyncedSettingsDocument` (ADR 0014's
  standing obligation).

## Amendment (2026-09-01): a bulk approval must not be able to disappear

Additive, inside the decision above — the partition, the confirmation dialog and the "n ordinary
outbox writes" rule are unchanged. Two things the first version got wrong about the *combination*
of bulk triage and local drafts.

**A comment-free draft is re-anchored to the head the user acted on.** A one-click verdict reuses
an existing draft so it never throws away inline comments (`ReviewDraft.verdict(_:on:existing:…)`).
That reuse also kept the draft's old `basedOnHeadOid`, which produced a silent loss: a pull request
with a bare local draft written on head A, pushed to (head B) and green again, would be bulk-
approved with the row still anchored to A — and the drain would park the review as a conflict
without ever sending it. A draft with no inline comments hangs off no particular line, so it is
now re-anchored to the head shown in the dialog, which is the state the user actually judged. A
draft **with** comments keeps its anchor: those comments reference lines of the commit they were
written on, and the staleness check is protection there, not a bug.

**And where the anchor is kept, the dialog says so.** Such an entry carries a new caveat,
`staleDraftComments` ("draft comments on an older commit"), beside `no checks` and
`mergeability unknown` — a note, not a refusal, shown *before* the confirm. `BulkTriagePlan.make`
therefore takes the drafts already on disk, and the inbox reads them for the ticked rows just
before the dialog opens.

**Parked conflicts are visible after the fact, too.** The sentence above previously claimed "the
existing conflict alert … surfaces it". It did not, twice over: `AppEnvironment` held exactly one
`DraftConflict`, so a drain that parked several reviews — which is precisely what a bulk run can
do — overwrote all but the last, and the pending-count line in Settings counts only `pending` and
`sending`, never `conflicted`. Both are fixed: the conflicts are queued (`DraftConflictQueue`) and
shown one alert at a time, in arrival order, with the alert naming how many are still behind it;
and `conflictedOutboxCount()` backs a standing "n conflicted — needs your attention" line in
Settings → Sync plus a "n not sent" marker in the title bar. A pending row drains by itself, a
parked one needs the user, so the second number stays on screen until someone acts on it.
