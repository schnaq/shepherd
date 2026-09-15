# ADR 0005: GraphQL search for reads, REST for writes, ETag-aware polling

Status: Accepted · Date: 2026-08-31

## Context

Naively polling `GET /repos/{o}/{r}/pulls` per repo burns ~1,500 requests/hour for 50 repos at
a 2-minute cadence — 30% of the REST budget before fetching a single diff. Full analysis and
rate-limit math: [research](../research/research-github-stack.md#2-api-surface-for-the-review-flow).
Two operations (thread resolve/unresolve, cheap CI rollup in list views) are GraphQL-only or
GraphQL-cheapest; multi-comment review creation is a single REST POST.

## Decision

- **Inbox listing: one GraphQL search sweep** per poll cycle across *all* repos
  (`is:pr is:open involves:@me` + facet queries for `review-requested:@me` / `author:@me`),
  selecting exactly the list-view fields incl. `statusCheckRollup` and `reviewDecision`.
- **Detail fetches are delta-driven**: compare `updatedAt`/`headRefOid` against the local
  cache; fetch files/threads/checks only for changed PRs, staggered (max ~5 concurrent) to
  respect secondary rate limits.
- **Writes via REST**: `POST …/pulls/{n}/reviews` (creates a pending review with the full
  inline `comments` array in one call, or submits directly), `POST …/comments/{id}/replies`,
  `PUT …/merge`. **Exception:** `resolveReviewThread`/`unresolveReviewThread` — GraphQL-only.
- **Two polling loops**: `GET /notifications` honoring `X-Poll-Interval` (fast wake-up signal,
  free 304s via `If-Modified-Since`) + the ~2-minute search sweep as source of truth.
  Conditional requests (ETag) everywhere they're honored.

## Consequences

- Steady-state API usage stays at ~5–20% of the REST core budget and single-digit % of the
  search bucket even with 50+ repos — headroom for bursts and future features.
- The client speaks both GraphQL and REST; `GitHubKit` hides this behind one façade.
- No webhooks by design (local-first, no server); polling latency (~seconds to ~2 min) is the
  accepted trade-off, softened by the notifications loop.

## Amendment (2026-09-05): the merge row carries the branch deletion

The merge sheet has always had a "Delete the branch afterwards" box, and it has always been
`.disabled(true)` with a footnote admitting the outbox did not model it. Honest, and a dead control
on the one action in the app that cannot be undone. It is wired up now, and four decisions are
worth writing down because none of them is the obvious one.

**It is a field of the merge, not a second outbox row.** `OutboxAction.merge` gained
`deletesHeadBranch: Bool`. A merge and the tidying-up that follows it are one intent, and two rows
would be two intents: the drain claims a batch at a time, two Macs share an account, and a branch
deleted by a machine whose merge row was still queued would be a deletion of something that had not
been merged. One row also means one thing to park, one thing to retry and one `mutationSent` — the
toast still says *"Merged …"* and nothing more, because "merged" is the fact the user is waiting
for and the deletion is bookkeeping behind it.

**The payload's coding is now written out by hand**, in exactly the shape the compiler synthesised.
Synthesised decoding of an enum payload is strict — every associated value is a required key — so
adding a third one would have made every merge row queued by an older build fail to decode, and
`claimReadyOutboxItems(now:limit:)` skips a row whose payload no longer decodes. A merge queued on
the train and an update installed before landing would have quietly lost the merge. The new field
is therefore read the way `AutoDelegationRules` reads a field an older document does not carry:
absent means `false`, and "the user did not ask for a deletion" is the only honest reading of a row
that never mentioned one. `outbox.payload` is still an opaque blob and there is still no migration.

**A failed deletion never fails the merge.** The drain deletes *after* `PUT …/merge` has come back
and before the row is marked succeeded, and every way out of that path is silent. By then the pull
request is merged on GitHub: a row that reported failure for a thing that had succeeded would be
retried into a merge GitHub refuses, or — worse — re-queued by a user who was told their merge did
not land. What a failure leaves behind is the ordinary request-log entry GitHubKit writes for every
request. The commonest one is a `422 Reference does not exist`, which is a repository with
"automatically delete head branches" switched on having already done this for us, and is not a
problem at all.

**Two guards, in the engine.** A branch is only deleted when GitHub says the head repository *is*
the base repository — a fork's branch is not ours, and `DELETE` on our own refs could otherwise hit
a same-named branch belonging to somebody's work in progress — and when the head ref is not the
repository's default branch, because a pull request from `main` into a release branch is an
ordinary thing to open. Neither fact is in `PullRequestSummary`, in `PullRequestDetail` or in the
merge response, and neither is in the outbox row: the drain reads them, with the branch name, from
one small GraphQL query (`headBranchContext`) on the endpoint the sweep already uses, made only
when a merge row asked for a deletion. That is one more request per opted-in merge and no new host.
An unanswerable guard — a probe that failed, a fork GitHub no longer has — is a refusal rather than
permission, so the deletion is skipped and the merge still succeeds. Putting the guards in the
sheet instead would have been checking facts that can change between the click and the drain, in
one of the several places a merge is queued from.

**Nothing unattended deletes anything.** Bulk triage (ADR 0015) has no such box and the automatic
rules (ADR 0018) never tick one: both queue merges with `deletesHeadBranch` at its default of
`false`. ADR 0018 is explicit that a rule may only record a decision a human already made, and
nobody approving a pull request approved a branch deletion.

The write itself is `DELETE /repos/{o}/{r}/git/refs/heads/{branch}` — REST, like every other write
in this ADR. The branch name goes into the path unencoded so `URLComponents` percent-encodes what a
path segment may not carry while leaving `/` a separator: `feature/thing` is one ref, not two.

## Amendment (2026-09-05, after the above): the deletion moves behind the mark

The amendment above says the drain deletes the head branch "after `PUT …/merge` has come back and
before the row is marked succeeded". That ordering is wrong, and this replaces it: the deletion now
runs **after** `markOutboxItemSucceeded(id:)`, as a follow-up step the drain keys on the action.
Everything else about it is unchanged — same two calls, same two guards, same silence on failure,
same single `mutationSent`.

The reason is the crash window. A row is only removed from the outbox once `execute` has returned,
and `OutboxStore` resets any row still in `sending` to `pending` on the next launch (ADR 0006). The
branch deletion is two network round-trips, so performing it before the mark made that window two
round-trips wide for the one action in the app that must not be sent twice: a second `PUT …/merge`
on a merged pull request is a `405`, `405` is not retryable, and the drain would park the row as
failed with "cannot be merged" — for a merge that had landed. After the mark the window is gone. A
crash in the follow-up costs a branch that stays behind, which the repository's own "automatically
delete head branches" setting or a click on GitHub clears up, and the next launch finds a row that
is already gone.

**A merge GitHub says has already landed is a success, not a failure.** The window can never be
closed completely — a crash between GitHub committing the merge and the response arriving is outside
anybody's reach — so the re-sent merge is handled rather than merely made unlikely. When
`PUT …/merge` comes back `405`, the drain asks one question before believing it:
`GET /repos/{o}/{r}/pulls/{n}/merge`, which answers `204` when the pull request is merged and `404`
when it is not. A `204` means the queued merge did land, on some earlier attempt, and the row is
completed exactly as a merge GitHub accepted would be — same `mutationSent(.merged)`, same
follow-up, same removal. A `404` means the pull request genuinely cannot be merged and the row is
parked as before. It is a read, it is made only on the refusal, and it is on `api.github.com` —
the host this ADR has always used and no new one.

## Amendment (2026-09-14): the conversation — commenting on and closing a pull request

Shepherd could submit a review with a `COMMENT` verdict and it could merge, and between those two
there was nothing: no way to say something about a pull request without filing a verdict on it, and
no way to close one that is not going to land. Both are on GitHub's own pull-request page, one next
to the other, and their absence sent people to the browser for the errand Shepherd exists to keep
them out of.

Two new outbox actions, and no new endpoint: `addPullRequestComment(body:)` and
`closePullRequest(comment:)` go through `POST /repos/{o}/{r}/issues/{n}/comments` and
`PATCH /repos/{o}/{r}/issues/{n}` — the same two calls the issue writes already make. GitHub draws
issues and pull requests from one number sequence and one comment collection, so the issue
endpoints *are* the pull request's conversation; only the review endpoints are its diff.

Three decisions worth keeping:

- **A comment is not a review.** `POST …/comments` writes the thing GitHub's *Comment* button
  writes. A `COMMENT` review is the other thing — a verdict-free review that belongs to the diff —
  and the toast says which one went out, because a user who wrote three sentences on the
  conversation must not be told a review was submitted.
- **"Comment and close" is one row, not two.** For the same reason the branch deletion is a field
  of the merge above: two rows could be drained by two Macs, or in two sweeps, and a pull request
  closed by the machine whose comment row was still queued is a close with its reason missing.
- **The drain closes first and comments second.** The reverse reads better on the timeline and is
  worse where it counts: a retryable failure between the two halves would re-post the comment every
  time. Closing twice is a no-op GitHub accepts, so this order sends the comment exactly once.

Neither action carries an `updatedAt` precondition, which is why `basedOnIssueUpdatedAt` answers
`nil` for both: the issue writes are pinned to it because a label or an assignment is an edit that
can collide, while a comment says what it says however the pull request has moved since, and a
close is not made wrong by one.

`state_reason` is left out of the close. It is GitHub's issue vocabulary — "completed" or "not
planned" — and a pull request is closed or merged, never not planned.
