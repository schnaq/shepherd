# Roadmap

Scope decisions from the founder interview (2026-08-31). v1 is deliberately full-featured on
the review path — the founder's bar is "never need to open github.com for a routine review".

## v0.x → v1.0 (current work)

**Inbox**
- [ ] GitHub sign-in: device flow + fine-grained PAT fallback (ADR 0004)
- [ ] Cross-repo inbox via GraphQL search sweep; sections & facets: provenance (agent/human),
      repo/org, review-requested / my PRs / involved (ADR 0005, 0008)
- [ ] Agent detection with bundled + user-extensible registry (ADR 0008)
- [ ] CI check rollup, review decision, draft/mergeable badges on rows
- [ ] `j`/`k` navigation, ⌘K command palette, saved filter views
- [ ] macOS notifications: new review requests, checks failed on own PRs (polling, ADR 0005)

**Review**
- [ ] PR detail: description, timeline, commits, checks detail
- [ ] Monaco diff viewer: side-by-side & inline, syntax highlighting, dark/light (ADR 0003)
- [ ] File list ordered by review priority with reasons; viewed-state tracking (ADR 0007 tier 1)
- [ ] Pending review composer: inline comments (incl. multi-line), summary, verdict;
      drafts survive restart/offline; staleness check before submit (ADR 0006)
- [ ] Threads: reply, resolve/unresolve
- [ ] Merge: merge/squash/rebase, delete-branch option, mergeability preflight

**Intelligence (ADR 0007)**
- [ ] Tier 1 heuristics: file prioritization, risk hints — always on
- [ ] Tier 2 on-device PR summaries via Foundation Models (availability-gated)
- [ ] Tier 3 BYOK Anthropic: whole-PR summary & review-focus hints

**Foundation**
- [ ] Local-first SQLite cache + outbox (ADR 0006)
- [ ] Dark/light theme system, Linear-inspired visual language
- [ ] CI: ShepherdKit tests (macOS + Linux), web bundle build+tests, app build on macOS runner

## v1.x

- Authorization Code + PKCE loopback sign-in (nicer than device flow)
- Bulk triage actions (approve/merge a selected set of green agent PRs, one confirm)
- Draft AI-assisted review comments & commit/PR message suggestions (explicit founder wish;
  needs tier 2/3)
- Multiple GitHub accounts; GitHub Enterprise Server base-URL support
- Menu-bar quick inbox
- Signed + notarized releases, Homebrew cask, Sparkle appcast (ADR 0010)

## Later / explorations

- Checkout-and-run integration (open worktree in editor/terminal for local verification)
- Team dashboards (review load, agent PR statistics)
- iPad companion (ShepherdKit is already platform-independent)

## Non-goals

- Windows/Linux builds (ADR 0001), Mac App Store for v1 (ADR 0010), running/hosting coding
  agents (Shepherd reviews their output; it doesn't orchestrate them), auto-submitting
  AI-generated reviews (AI output is always a suggestion a human confirms).
