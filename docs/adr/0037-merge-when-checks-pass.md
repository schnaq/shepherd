# ADR 0037: Merge when checks pass — a per-pull-request decision, fired by the sweep

Status: Accepted · Date: 2026-09-22

## Context

A reviewer reads a pull request, finds it good, presses `m` — and the merge sheet says *Checks are
still running.* The sheet has always let them merge past that warning, and it has always let them
cancel and come back later. What it never offered is the thing GitLab calls *merge when pipeline
succeeds*: the reviewer has made the decision, the build has not finished, and the only work left
is to press the button in twenty minutes. Twenty agent pull requests a morning make that twenty
reminders, and the ones that are forgotten sit green until the evening.

Two things Shepherd already has look like this feature and are not:

- **Auto-merge rules (ADR 0018)** decide *on the user's behalf*, which is why they demand approval,
  agent authorship and a green build before they will look at a pull request, and why the settings
  card says in as many words that nobody confirms anything. Widening a rule to "also anything I
  reviewed" would be a fourth condition the ADR explicitly reserves for a new decision — and it
  would still fire on whichever commit is green at the time, not the one the reviewer read.
- **GitHub's own auto-merge** (`enablePullRequestAutoMerge`) merges when the *required* checks
  pass. It needs the repository to allow auto-merge, and without a branch-protection rule listing
  required checks it merges immediately — exactly the wrong answer to "wait for CI". GitHubKit
  has no such mutation, and adding one would make the feature's behaviour depend on a repository
  setting the reviewer cannot see from the sheet.

So the decision is a third thing, and its shape has to make clear it is neither of the two above.

## Decision

### The arm is the user's verdict on one commit

*Merge when checks pass* is a second button on the merge sheet, offered only while the head
commit's checks are **pending** and nothing else on the sheet is a refusal (a draft, conflicts).
Pressing it records a `MergeWhenGreenRequest` (`ShepherdCore/Automation/`): the pull request, the
**head commit the reviewer is looking at**, the merge method and the delete-branch answer *as the
sheet shows them*, and the time. Everything the write will need is copied in at the click because
the click is the decision; the method the settings hold when the checks finally finish is not what
the user saw.

The button is not offered while a check is failing. A red suite cannot go green without a re-run
or a push; a re-run makes it pending again, which is when the button comes back; a push is a new
commit nobody has judged. It is not offered for a pull request with no checks either — there is
nothing to wait for, and the plain *Merge* is the honest button.

### The sweep fires it, and the policy is pure

`MergeWhenGreenPolicy.decide(request:pullRequest:existingOutbox:)` is a pure function over values,
split from its app-side coordinator the way ADR 0016 and ADR 0018 split theirs. For each armed
pull request it answers one of three things, checked in a fixed order:

- **abandon** — the head moved, the pull request became a draft, GitHub reports conflicts, the
  head has no checks, or a check failed. The arm is dropped and the user is told why, because each
  reason asks for a different next step (re-read the diff, fix the check, rebase). The head goes
  first: once it moved, nothing else about the row is about the commit the user decided on.
- **wait** — checks still running, mergeability not yet computed, or the outbox still holds a
  write for this pull request. Unknown mergeability is a *wait* here where ADR 0018 makes it a
  refusal: GitHub recomputes it in the seconds after the last check finishes, and a reviewer who
  has already decided should not lose the decision to that window.
- **merge** — pinned to the armed head as `expectedHeadOid`.

What the policy does **not** check, deliberately: approval, authorship, the repository, labels.
The human formed the verdict when they pressed the button. This does not cross the line ADR 0016
drew and ADR 0018 named — "Shepherd never forms a verdict unattended" — because nothing here is
formed unattended; the only question left is whether the commit that was judged is still the
commit that would be merged, and whether it went green.

It runs where auto-merge runs, on the rows a sweep wrote (`onInboxRows`), for the reason ADR 0018
gave: the transition this is about — the last check finishing — bumps nothing GitHub reports as a
change, so the persisted rows are the only honest trigger. With nothing armed a pass is one
`isEmpty` read. A pull request that is **missing from the rows** is a wait, not a drop: the rows
come from GitHub's search, which is occasionally one sweep behind, and a decision the user is
counting on must not be thrown away by a hiccup. Only an arm that has been waiting seven days with
nothing to look at is forgotten, quietly — by then the pull request was merged or closed by
somebody else, which is not Shepherd's news. A row that comes back at the armed head is still the
commit the user judged; at any other head the next pass drops the arm with a notice, as for a push.

### One write path, spent before the write

The fired merge is `PullRequestActions.merge(_:method:deletesHeadBranch:)` — the function the
sheet's *Merge* button calls — through the same kind of injected seam ADR 0018 uses. The row is an
ordinary `.merge` pinned to the armed head; the drain re-validates it, parks it if the head moved
in the seconds between, retries if GitHub is down, and emits `mutationSent` so `pr.merged` fires.
No new GitHub call, no new webhook event: the intent was the user's own click, and a click is not
something Shepherd reports as an automation.

The arm is removed from the store *before* the `await` on the write, on the auto-merge ledger's
argument: a second pass that starts while the first is writing sees nothing armed. Merging by
hand from the sheet also disarms first, so the arm cannot fire behind a merge the user just
queued. The outbox's "one write in flight" check covers whatever is left — and the one case it
would not, two passes in the same sweep each reading the outbox before the other wrote, is closed
by running this pass *after* the auto-merge rules in the same `Task`, with the rules' queued ids
added to its view of the outbox. A pull request that is an agent's, approved, and armed by the
reviewer on top gets one merge, the rule's, and the arm waits behind it.

### Machine-local, and stronger about it than the ledger

The list lives in `UserDefaults` (`Automation/MergeWhenGreenStore.swift`), survives a relaunch — a
reviewer who armed a merge and went home expects it done in the morning — and is cleared on
sign-out. It does **not** travel in the settings document (ADR 0014), and the reason is stronger
than the ledger's "one machine's automation state": the arm records that *this user, on this Mac,
looked at this commit*. A second Mac cannot know that, so it must not merge on the first one's
behalf.

### Everything it does is visible

- The sheet shows the waiting state in place of the warning, names the method the arm was recorded
  with, and offers *Stop waiting*. The inbox detail panel carries one line beside the queue status.
- One notification per pass for the merges that fired (wording: *queued*, for ADR 0018's reason),
  one per arm that was dropped, naming the reason. Neither is gated by a notification preference:
  the user is counting on this merge.
- Arming counts as finishing with the pull request: a focus session advances and the review screen
  goes back to the inbox, exactly as after *Merge*.
- Telemetry (ADR 0036) gains one value on an existing field — `pull_request_merged.source =
  when_checks_pass` — and nothing else. An arm that is dropped is not counted.

## Consequences

- The gap between "I have decided" and "the build agrees" no longer needs a reminder. The reviewer
  decides once, on the commit they read, and the merge lands on the sweep that sees it green.
- The limitation is stated wherever the feature is: it fires **while Shepherd is running**, on the
  next sweep. A Mac that is asleep merges nothing until it wakes, which is the same limitation
  ADR 0018 accepts and a smaller one than GitHub's auto-merge silently depending on branch
  protection.
- The reflective test that keeps triage verdicts and track records out of every automation input
  (`StructuredTriageTests.testNoAutomationInputCanSeeAVerdict`, ADR 0023 and ADR 0027) covers
  `MergeWhenGreenList` too, so the arm can never quietly grow a field that lets a generated
  classification decide a merge.
- A third kind of merge exists beside the click and the rule, and the sheet is the only place it
  is created. Offering the button anywhere a reviewer has not just seen the diff, the method and
  the branch box — the inbox row, ⌘K, bulk triage — needs a new decision, because the argument
  above rests on the click being made with all three in view.
