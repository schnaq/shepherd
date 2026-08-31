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
