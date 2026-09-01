# Shepherd 🐑

**A native macOS review inbox for the age of AI coding agents.**

Coding agents (Claude Code, Copilot, Codex, Devin, …) open pull requests faster than any human
can keep up with — across *all* of your repositories at once. Studies show the majority of
agent-authored PRs never receive any recorded human review. Shepherd herds them back into one
place: a fast, local-first, Linear-style inbox where you triage, review, and merge every PR
from every repo — without ever opening a browser tab.

> Status: **pre-alpha, under active development.** The full v1 skeleton exists and builds:
> domain/network/persistence/sync package (tested on macOS + Linux), the Monaco diff-viewer
> bundle (158 tests), and the SwiftUI app (inbox, review flow, command palette, settings,
> on-device + BYOK intelligence). Not yet exercised against real repositories — expect rough
> edges. Decisions live in [docs/adr](docs/adr).

## What it does

- **One inbox for all repos.** Every open PR across your repositories and organizations,
  aggregated by a single GitHub search sweep — not fifty browser tabs.
- **Agent-aware triage.** PRs authored by bots and coding agents are detected, labeled, and
  groupable as a first-class facet: see at a glance what Claude, Copilot, Codex, Devin — or a
  human — sent you.
- **Full code review in-app.** Side-by-side diffs (Monaco, the VS Code diff engine), inline
  comments on lines, multi-comment pending reviews, approve / request changes / comment,
  reply to and resolve review threads, CI check status, and merge (merge / squash / rebase) —
  complete GitHub review parity, natively wrapped.
- **Review-priority file ordering.** Changed files are grouped and ranked by what deserves your
  attention first — deterministic heuristics (source vs. lockfiles vs. generated code, churn,
  path risk), optionally sharpened by on-device AI.
- **Delegate back to a local coding agent (Claude Code first-class)** — runs in an isolated
  worktree with turn/budget caps; you review and push.
- **On-device intelligence, cloud optional.** PR summaries and triage hints run locally via
  Apple's Foundation Models framework when available. Optionally bring your own Anthropic API
  key for deeper whole-PR analysis. The app is fully functional with AI switched off.
- **Local-first.** Everything lives in a SQLite database on your Mac. GitHub is a sync target,
  not a backend. No server, no telemetry, no account other than your GitHub login.
- **Linear-grade feel.** Command palette (⌘K), `j`/`k` navigation, two-keystroke review
  actions, dark & light mode, native performance.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Sign in with GitHub via device flow (or paste a fine-grained personal access token)

## Building from source

```sh
brew install xcodegen
git clone https://github.com/schnaq/review.git shepherd && cd shepherd
cd web/diff-viewer && npm ci && npm run build && cd ../..  # bundle the Monaco diff viewer
xcodegen generate
open Shepherd.xcodeproj
```

Xcode 26+ is required. The `ShepherdKit` Swift package (domain logic, GitHub client, sync
engine) is platform-independent and can be tested headlessly with `swift test`.

## Architecture at a glance

```
┌────────────────────────────── Shepherd.app (SwiftUI, macOS 26) ─────────────────────────────┐
│  Inbox · PR detail · Review composer · Command palette · Settings · Notifications           │
│  Intelligence layer: Foundation Models (on-device) → Anthropic BYOK (optional) → heuristics │
│  Diff viewer: Monaco diff editor in WKWebView, typed JSON bridge                            │
└───────────────┬─────────────────────────────────────────────────────────────────────────────┘
                │ ShepherdKit (SPM)
   ┌────────────┴───────────┐   ┌──────────────────────┐   ┌───────────────────────────┐
   │ ShepherdCore           │   │ GitHubKit            │   │ ShepherdPersistence       │
   │ models · heuristics    │   │ GraphQL+REST client  │   │ GRDB/SQLite cache         │
   │ agent detection        │   │ device flow · ETags  │   │ review drafts · outbox    │
   └────────────────────────┘   └──────────────────────┘   └───────────────────────────┘
```

Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Every significant decision has an
ADR in [docs/adr](docs/adr), grounded in the research reports in
[docs/research](docs/research).

## Why not <existing tool>?

We looked ([full report](docs/research/research-landscape.md)). Desktop Git clients (Tower,
Fork, GitKraken) review PRs but are closed-source, cloud-backed, and single-repo-centric.
Multi-repo inboxes (Graphite, GitKraken Launchpad, Devin Review) are SaaS. `gh-dash` is
open source and keyboard-driven but a TUI without inline review. Nothing today is
**open source + local-first + full review parity + agent-aware**. That's the gap Shepherd fills.

## License

[MIT](LICENSE)
