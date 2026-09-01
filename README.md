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
- **Bulk triage for the agent flood.** Tick the pull requests you have looked at (`x`, ⌘-click,
  ⇧-click for a range — or "select all green agent PRs in this view"), then approve, approve &
  merge, or merge them behind **one** confirmation dialog. The dialog lists every pull request
  with its checks and review state and marks the ones it will skip — red CI, conflicts, drafts,
  changes requested, your own — with the reason, so what you selected and what gets written can
  never drift apart. Each pull request is then queued individually, with the same offline, retry
  and staleness handling a single review gets. See
  [ADR 0015](docs/adr/0015-bulk-triage.md).
- **Focus review session.** Press ⇧⌘⏎ (or `r f`) and Shepherd walks you through every pull
  request waiting for your review, one after another, keyboard only: a thin bar shows "3 of 12",
  `d` marks one done and moves on, `n` leaves it for later, `esc` ends the run. Approving,
  requesting changes or merging advances on its own, so a queue of twenty agent PRs is twenty
  keystrokes and no mouse. The queue is frozen the moment you start it — pull requests that land
  while you work wait in the inbox instead of pushing your progress bar backwards — and anything
  that gets merged or closed in the meantime is skipped with a note when you reach it. It finishes
  with "Session complete — 9 reviewed, 3 skipped" and how long it took.
- **Quick inbox in the menu bar.** The menu-bar item carries the number of pull requests waiting
  for your review and opens a short list of them — repository and number, title, who or what wrote
  it, CI state — where one click opens the pull request in the main window. "Sync now" and the full
  inbox are one click away too. It reads the same local database the window does, so it costs no
  extra GitHub call, and it can be switched off in Settings → Appearance.
- **Saved replies and per-repo review templates.** The same three sentences go out twenty times a
  week — "please add a test for this branch", "this is generated, keep it out of the diff" — so save
  them once and drop them into any comment field with one click: inline comments, the review
  summary, thread replies. And a repository (or a whole owner, `schnaq/*`) can carry a summary
  template, so a new review opens with your team's checklist already in it. It only ever fills an
  *empty* review: a pull request you have written anything on is never touched. Both live in
  Settings → Replies and travel with encrypted settings sync.
- **Review-priority file ordering.** Changed files are grouped and ranked by what deserves your
  attention first — deterministic heuristics (source vs. lockfiles vs. generated code, churn,
  path risk), optionally sharpened by on-device AI.
- **Delegate back to a local coding agent (Claude Code first-class)** — runs in an isolated
  worktree with turn/budget caps; you review and push.
- **Optional: let it start itself when CI goes red.** Switch on an auto-delegation rule and the
  moment CI *turns* red on one of your pull requests, Shepherd sends the agent after it and
  notifies you — same worktree isolation, same caps, at most one run per pull request and per
  commit, with a daily budget you set. Off by default, and it still never pushes, approves or
  merges anything: the finished diff waits for you, marked as automatic.
  See [ADR 0016](docs/adr/0016-auto-delegation-rules.md).
- **Outbound webhooks for your own automation.** Point Shepherd at an n8n Webhook node (or any
  JSON endpoint) and get a versioned event when a review is submitted, a pull request is merged,
  a delegation finishes, or a review request lands — signed with your own HMAC secret if you
  want. Events fire only after the action really succeeded, and only to the one URL you typed.
  See [docs/WEBHOOKS.md](docs/WEBHOOKS.md).
- **Drivable from anywhere: `shepherd://` links and a tiny CLI.** `shepherd open owner/repo#123`
  jumps straight to the review screen; `shepherd inbox needs-my-review` and `shepherd sync` do
  what they say. Works from the terminal, Raycast, Shortcuts, a browser bookmark or an n8n
  *Execute Command* node — so an incoming GitHub event can put the right pull request on your
  screen. The CLI only opens URLs: it never talks to GitHub and never sees your token.
- **Encrypted settings sync across your Macs — your bucket, your passphrase.** Point Shepherd at
  an S3-compatible bucket you own (STACKIT Object Storage, MinIO, anything) and it stores one
  object holding *all* of your settings **and** your secrets — GitHub token, AI keys, webhook
  secret — encrypted on your Mac with AES-256-GCM under a passphrase-derived key (PBKDF2, 600 000
  iterations). A new Mac with bucket access and the passphrase is fully set up; the bucket operator
  sees ciphertext and nothing else. No Shepherd account, no server — and no recovery if you lose
  the passphrase, deliberately. See [ADR 0014](docs/adr/0014-encrypted-settings-sync.md).
- **On-device intelligence, cloud optional.** PR summaries and triage hints run locally via
  Apple's Foundation Models framework when available. Optionally bring your own API key for
  deeper whole-PR analysis — Anthropic, or any OpenAI-compatible endpoint, with presets for
  EU-hosted Konduit and a local Ollama. The app is fully functional with AI switched off.
- **AI-drafted review text — a suggestion, never a submission.** A ✨ button next to the review
  summary and next to any inline comment drafts the text for you: the summary from the pull
  request's digest and the comments you have already written, an inline comment from the diff
  around the line you clicked. It lands in the field as editable text, labelled as a draft until
  you touch it, and it never overwrites what you typed without asking whether to replace or
  append. Nothing is ever submitted for you — Shepherd has no path from generated text to GitHub
  that does not go through your click. See [ADR 0007](docs/adr/0007-layered-intelligence.md).
- **Optional crash reports that never leave your Mac.** Switch on local diagnostics and macOS hands
  Shepherd its own crash, hang and CPU-exception reports on the next launch after one happened;
  Shepherd writes them as JSON files in Application Support, keeps the 30 newest, and shows you the
  folder. No crash-reporting SDK, no endpoint, no uploader — if you want to help with a bug, you
  open the folder and attach the file yourself. Off by default.
  See [ADR 0017](docs/adr/0017-local-diagnostics-metrickit.md).
- **Local-first.** Everything lives in a SQLite database on your Mac. GitHub is a sync target,
  not a backend. No server, no telemetry, no account other than your GitHub login — and where
  Shepherd does sync between your own machines, it does it through storage you own, encrypted
  before it leaves the Mac.
- **Linear-grade feel.** Command palette (⌘K), `j`/`k` navigation, two-keystroke review
  actions, a keyboard-only focus session over your review queue, dark & light mode, native
  performance.

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

### Releases

Shepherd ships as a notarized DMG on GitHub Releases, installable with
`brew install --cask schnaq/tap/shepherd`, and updates itself through Sparkle 2 — automatic
checks are on by default and switchable off in Settings → Account
([ADR 0010](docs/adr/0010-distribution-dmg-homebrew.md)). The whole pipeline is one script,
`Scripts/release.sh`, run by `.github/workflows/release.yml` on a `v*` tag; a source build like
the one above is unsigned and has its updater switched off, which the Settings section states.

There are no published releases yet: the pipeline is committed but is waiting on the
maintainer's Apple Developer ID and Sparkle signing key. [docs/RELEASING.md](docs/RELEASING.md)
is the one-time setup and the per-release checklist; third-party licences that ship inside the
app are in [NOTICES.md](NOTICES.md).

## The `shepherd` command line

Shepherd registers the `shepherd://` URL scheme, and the `shepherd` binary is a thin wrapper
around it — it builds a URL and opens it. There is no network code and no token in the CLI: it
can only ask the app to do things the app already lets any process ask for
([ADR 0013](docs/adr/0013-url-scheme-and-cli.md)).

```sh
xcodebuild -project Shepherd.xcodeproj -scheme ShepherdCLI -configuration Release \
  -derivedDataPath .build/cli build
cp .build/cli/Build/Products/Release/shepherd /usr/local/bin/
```

```sh
shepherd open schnaq/review#42                       # …/review/42 and a github.com PR URL work too
shepherd inbox                                       # bring the inbox forward
shepherd inbox needs-my-review                       # mine · involved · approved-by-me
shepherd inbox --filter agent:claude-code            # humans · bots · agent:<id> · repo:<owner>/<name>
shepherd sync                                        # sweep every repository now
shepherd settings automation                         # jump to a Settings tab
shepherd --help
```

The URLs behind those, usable from Raycast, Shortcuts, a bookmark or `open(1)` directly:

| URL | Effect |
| --- | --- |
| `shepherd://pr/<owner>/<repo>/<number>` | Open that pull request's review screen |
| `shepherd://inbox` · `shepherd://inbox?filter=<token>` | Inbox, optionally filtered |
| `shepherd://sync` | Run one sweep now |
| `shepherd://settings` · `shepherd://settings/<tab>` | Open Settings, optionally on a tab |

A pull request that is not in your inbox yet is fetched on demand, so a link from a colleague
works. A link that arrives while you are signed out is remembered and opens right after sign-in.

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
