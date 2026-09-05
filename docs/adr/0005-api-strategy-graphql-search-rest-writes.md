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
