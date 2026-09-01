# ADR 0018: Opt-in auto-merge rules (green, approved, agent-authored)

Status: Accepted (v1.x) · Date: 2026-09-01

## Context

Bulk triage (ADR 0015) made forty green agent pull requests cheap: tick, confirm, done. The
founder's remaining complaint is about the pull requests that were *already* decided. An agent
opens a dependency bump, CI goes green, a human reads it and approves it — and then it sits there
until somebody comes back and presses merge. The judgement happened at the approval; the merge is
bookkeeping, and it is bookkeeping the reviewer has to remember to come back for.

Auto-delegation (ADR 0016) is the sibling of this feature and settled most of its design
questions: opt-in and off by default, the decision as a pure function in `ShepherdCore`, a
persisted ledger so nothing fires twice, a notification because something the app did unattended
must be visible. What it explicitly did *not* settle is this action. ADR 0016's third failure
mode reads "no auto-push, no auto-approve, no auto-merge", and the roadmap's non-goals repeat it.

That sentence is still the right line, and this ADR does not cross it — it names precisely where
the line is. The thing ADR 0016 refused was Shepherd *forming a verdict* on its own: approving,
submitting a review, deciding that a change is good. Merging a pull request that a human has
already approved forms no verdict. It records one that exists, at the moment GitHub says the
conditions the reviewer was waiting for are met. Auto-approve remains a non-goal and always will
be, because it is the other thing.

Three failure modes have to be designed out rather than tested out, and they are not the same
three as ADR 0016's:

1. **Merging something nobody looked at.** Any rule that could fire on an unapproved pull request,
   a red build, or a human's work is out. This is the whole feature, so it is not a setting.
2. **Merging twice, or merging a commit nobody judged.** A pull request re-appears in every sweep;
   a merge that GitHub refuses stays open; a push while a merge is queued changes what merging
   means.
3. **Becoming a second write path.** ADR 0006 and ADR 0015 both say it: every mutation goes
   through the persisted outbox. A rule that called `GitHubClient.mergePullRequest` directly would
   have no retry, no offline behaviour, no head-commit preflight and no `mutationSent` event —
   which is what webhooks hang off (ADR 0012).

## Decision

### One rule, and its conditions are not checkboxes

`AutoMergeRules` (`ShepherdCore/Automation/`) has exactly three fields: the master switch and two
*narrowings*. Everything the founder's decision named — **CI green + approved + agent pull
request** — is a condition of the feature, enforced by `AutoMergePolicy` and not configurable:

- authored by a recognised coding agent (ADR 0008 provenance),
- the head commit's check rollup is `success` **with at least one check**,
- `reviewDecision == .approved`,
- not a draft,
- `mergeable == .mergeable` — unknown mergeability is a refusal, not a note.

The two optional fields can only ever make that stricter: a repository allow-list (`owner/name`
patterns with `*`/`?`, empty meaning every repository the sweep brings in) and a set of labels the
pull request must all carry (empty meaning none), which is how a team opts single pull requests in
rather than whole repositories.

The asymmetry with ADR 0016 is deliberate. Auto-delegation's conditions are checkboxes because
each one costs an agent run; here a checkbox that let somebody untick "approved" would convert a
feature that *records* a human decision into one that *makes* it. A rule set with no field for
that cannot be misconfigured into it, and a rule set decoded from a newer or corrupt document
cannot either: an unreadable list falls back to empty, which widens the *narrowing* and leaves
every real condition untouched.

Two things this v1 deliberately does **not** have. There is no "only if I am the approver /
only if my review was requested": `PullRequestSummary` carries GitHub's aggregate
`reviewDecision` and the user's own facet relations, not the list of who approved, and inventing
a per-approver check would mean a new GitHub call on the unattended path. And there is no daily
cap, unlike auto-delegation's: a cap exists there because each run costs money and a worktree,
while here every merge is one ordinary outbox row that the drain's batch size and GitHubKit's
`Retry-After` backoff already throttle (ADR 0015's consequence, unchanged), and a cap would leave
half the queue silently unmerged.

### The merge method is the app's one remembered method

`AppSettings.defaultMergeMethod` — what the merge sheet and the bulk-triage dialog already open on,
"the method you merged with last" (ADR 0015). The picker on the Automation tab is literally
`MergeMethodPicker`. A separate preference for the automatic path could only ever disagree with
the one the user sees when they merge by hand, which is the same argument `UpdateController` makes
about Sparkle's own flag.

### The trigger is the rows a sweep wrote, not an event

This is the one structural difference from ADR 0016, and it is forced. Auto-delegation fires on an
edge the engine reports (`checksFailedOnOwnPR`); the transition this feature is entirely about —
the last check turning green — has no such edge, because GitHub does not bump a pull request's
`updatedAt` when a check run finishes, so `SyncEvent.prUpdated` is not emitted for it. The honest
source is the inbox rows the sweep persisted, which are the same rows the menu-bar badge, the
focus session and the morning digest read. `SignedInSession.start` therefore gained an
`onInboxRows` callback beside its `onEvent` one.

The consequence is that a pass is **repeated and idempotent** rather than exact: every inbox write
re-considers every row. Two things make that safe, and they are the answer to failure mode 2:

- **`AutoMergeLedger` — one queued merge per `(prID, headRefOid)`, ever.** Persisted in
  `UserDefaults` (`Automation/AutoMergeStore.swift`), written *before* the outbox row, cleared on
  sign-out, and deliberately not in the settings document (ADR 0014): the rules travel between
  Macs, one machine's "already queued that" does not. A new push is a new head and therefore new
  work — and it is only merged if the rules still pass on that commit.
- **A pull request with any unsent outbox row is skipped.** The parked-conflict case is the
  important one: a merge the drain refused because the head moved waits for the user (ADR 0006),
  and without this check every subsequent sweep would stack another merge behind it.

With the switch off, a pass is one `Bool` read: no ledger, no policy, no outbox query.

**This rule fires on a state, not on an edge, and that is the right way round here.** ADR 0016's
first failure mode — "acting on a state instead of a change" — was about a rule whose condition
stays true for hours and would therefore fire on every sweep and on the whole backlog after a
fresh install. Both halves are answered differently for a merge. Firing repeatedly is handled by
the ledger rather than by an edge, because there is no edge to observe. And acting on the backlog
is not the failure mode: a green, approved, agent-authored pull request that has been waiting since
Friday is *exactly* what the user switched this on for, and a rule that only ever fired on pull
requests that turned green while the app happened to be open would be a rule that quietly did
nothing on most mornings. So switching the toggle on can queue several merges on the next sweep,
the settings card says so in as many words, and the notification names how many.

### The ledger *is* the audit log

One list, not a dedup set plus a log. The entry carries what the deduplication needs (`prID`,
`headRefOid`) and what the user needs to read (`owner/repo#n`, title, author, method, how many
checks were green, which required labels matched, when) — copied in rather than looked up, because
the pull request is merged moments later and the sweep prunes the row. Settings → Automation shows
the last ten with a *Clear* button, capped at a hundred on disk. Nothing is uploaded anywhere;
there is no code path from this folder to a network call.

Clearing the log clears the deduplication with it, and that is a consequence rather than a leak:
the only pull requests it can affect are ones still open and still eligible, which is exactly the
case where queueing the merge again is the right answer — and anything with a write still in the
outbox is refused by the other check.

### The write is the merge sheet's write

`AutoMergeCoordinator` (`@MainActor`, app target) supplies the inputs, records the ledger and then
calls **`PullRequestActions.merge(_:method:)`** — the same function the merge sheet's button
calls, through an injected seam so the coordinator can be tested without a database. So the row is
an ordinary `.merge(method:, expectedHeadOid:)`, pinned to the head the decision was made on; the
drain re-validates it, parks it as conflicted if the head moved, retries with backoff if GitHub is
down, and emits `mutationSent` when it really lands. There is no second write path anywhere in the
feature, and no new GitHub call was added.

### Everything automatic is visible

- **One notification per pass**, not per merge: a Monday-morning sweep can queue a dozen, and a
  dozen banners would be more disruptive than the dozen clicks it replaced. Not gated by any
  notification preference (ADR 0016's rule), and its wording says *queued*, because that is what
  happened — claiming "merged" before the drain has sent it would be the one lie in the feature.
- **A new webhook event, `pr.auto_merge_queued`** (schema in `docs/WEBHOOKS.md`), additive under
  `"v": 1`. It is the single event in ADR 0012's set that fires on an *intent* rather than on a
  success, and the exception is the point: what is worth reporting is that Shepherd decided
  something unattended, which is a fact at the enqueue. The outcome is still reported separately —
  `pr.merged` fires from the drain when the merge reaches GitHub — so an automatic merge produces
  two events and a parked one produces only the first.
- **The skip reason is exhaustive and kept.** `AutoMergeSkipReason` names every path out of the
  policy that is not a merge, and the coordinator keeps the last pass's decision per pull request,
  so "why is this one still sitting here?" is answerable rather than a shrug. A merge that
  silently did not happen looks exactly like a feature that is broken.
- **The settings card carries a warning, not an explanation**: there is no confirmation click, and
  it says so.

## Consequences

- The loop the founder actually has closes: an agent opens a pull request, CI goes green, a human
  approves it, and it is merged — with the approval still being the human's, recorded on GitHub,
  attributable. Nothing about the review path changed.
- **Auto-approve stays a non-goal**, and the wording of ADR 0016's third failure mode is now more
  precise rather than weaker: Shepherd never forms a verdict unattended. This ADR supersedes only
  the "no auto-merge" clause of ADR 0016's failure-mode 3, and only for pull requests a human has
  already approved.
- `AppSettings` gained the rule set, so it travels in `SyncedSettingsDocument.autoMerge` and in
  both directions of `SettingsSyncApplier` (ADR 0014's standing obligation), with a non-default
  fixture in `SettingsSyncTests`. The ledger explicitly does not travel.
- `WebhookEventKind` gained a case, which is additive: a fresh install subscribes to it, an
  existing install's stored event list does not contain it and therefore does not deliver it until
  the user ticks the box. Every exhaustive switch over the enum lives in one file.
- Two Macs with the same rules can both queue a merge for the same pull request, because the
  ledger is machine-local — the same accepted limitation as ADR 0016's, with a smaller
  consequence: the second merge is refused by GitHub (or by the head-commit preflight) and parked,
  rather than duplicating any work.
- The privacy line is unchanged. No new host, no new call, nothing uploaded; the audit log is a
  plist on one Mac.
- Adding a third *narrowing* later is one field plus one check in a documented order. Adding a
  third **condition** that could ever *widen* the rule — merging without an approval, merging a
  human's pull request — needs a new ADR, because "it only ever records a decision somebody
  already made" is the whole reason this one is acceptable.
