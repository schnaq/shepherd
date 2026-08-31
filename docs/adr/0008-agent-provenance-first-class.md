# ADR 0008: Agent provenance as a first-class facet (all PRs shown, agents labeled)

Status: Accepted · Date: 2026-08-31

## Context

The founding problem: agents flood repos with PRs and humans lose track — an arXiv study found
61% of agent-authored PRs get no recorded human review
([research](../research/research-landscape.md)). No existing tool treats "who/what authored
this PR" as a triage dimension. At the same time, hard-filtering to agent PRs only would make
Shepherd useless as the *single* review inbox (the founder reviews human PRs too, and team
review requests are in scope).

## Decision

- Shepherd ingests **all open PRs** the user can see/is involved in — human and agent alike.
- Every PR gets a detected **provenance**: `human`, or `agent(<name>)` where the name
  identifies the tool (Claude Code, Copilot, Codex, Devin, Dependabot, Renovate, …).
  Detection combines: author `type == Bot` (authoritative), a maintained, user-extensible
  allowlist of known agent logins/patterns, and branch-name/commit-trailer signals
  (`claude/…` branches, `Co-Authored-By: Claude` trailers) for agent PRs opened via a human's
  token.
- Provenance is a **first-class facet everywhere**: inbox grouping ("by agent"), filters,
  badges on rows, bulk actions scoped to a provenance ("approve all green Dependabot PRs" —
  each still individually confirmed before submit in v1).

## Consequences

- Detection lives in `ShepherdCore` as pure, heavily-tested logic with a bundled default
  agent registry (JSON) that users can extend in settings and the community can PR.
- Misdetection is cosmetic, never destructive: provenance influences sorting/labeling only,
  no automated review behavior.
- Solo-maintainer and team flows share one inbox model: facets (provenance, repo, org,
  review-requested) compose rather than fork the UX.
