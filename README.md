<div align="center">

<img src="docs/assets/icon.png" width="120" height="120" alt="Shepherd app icon">

# Shepherd

**A native macOS review inbox for the age of AI coding agents.**

[![CI](https://img.shields.io/github/actions/workflow/status/schnaq/review/ci.yml?style=flat-square&label=CI)](.github/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/macOS-26%20Tahoe-101116?style=flat-square)](docs/adr/0002-macos-26-apple-silicon.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)](Packages/ShepherdKit/Package.swift)
[![Telemetry: none](https://img.shields.io/badge/telemetry-none-4cc38a?style=flat-square)](CONTRIBUTING.md#rules-of-the-road)

<img src="docs/assets/hero.svg" width="100%" alt="Shepherd's inbox: pull requests from Claude Code, GitHub Copilot and people across every repository, each row with its CI state, review state and diff size">

</div>

## Why

Coding agents open pull requests faster than any human can keep up with — across *all* of your
repositories at once, and in a study of 33,596 agent-authored pull requests, 61% carried no
recorded human review at all ([the numbers](docs/research/research-landscape.md)). Shepherd herds
them into one place: a fast, local-first, keyboard-driven inbox where you triage, review and merge
every pull request from every repository without opening a browser tab. It is open source, your
data stays on your Mac, and "who wrote this — an agent or a person?" is a first-class fact rather
than a guess.

## What it does

<table>
<tr><th colspan="2" align="left">Review</th></tr>
<tr>
<td width="50%">🔍 <b>Real diffs, in the app</b><br>Side-by-side and inline Monaco diffs — the VS Code engine — with syntax highlighting, viewed-state tracking, and files ordered by what deserves attention first.</td>
<td width="50%">💬 <b>Full GitHub review parity</b><br>Inline comments, multi-comment pending reviews, approve / request changes / comment, thread replies and resolves, checks, and merge / squash / rebase.</td>
</tr>
<tr>
<td>⌨️ <b>Focus session</b><br>⇧⌘⏎ walks you through every pull request waiting on you, one at a time, over a queue frozen at start. Twenty agent PRs, twenty keystrokes.</td>
<td>📝 <b>Saved replies &amp; templates</b><br>Reusable snippets in every comment field, plus a per-repo review checklist that prefills a new, empty review — and never touches one you started.</td>
</tr>
<tr><th colspan="2" align="left">Triage</th></tr>
<tr>
<td>🤖 <b>Agent provenance</b><br>Claude Code, Copilot, Codex, Devin, Cursor or a human — detected, chipped, and groupable as a facet next to repository and review state.</td>
<td>✅ <b>Bulk triage</b><br>Tick the green agent PRs, then approve or merge them behind one confirmation that lists what it will skip — red CI, conflicts, drafts, yours — and why.</td>
</tr>
<tr>
<td>☀️ <b>Morning digest</b><br>An opt-in daily summary built from the local database alone: new requests, green PRs one keystroke from done, your red CI, reviews still parked.</td>
<td>📊 <b>Menu-bar quick inbox</b><br>The number of pull requests waiting on your review, and the top ones one click away — off the same local data, so it costs no extra API call.</td>
</tr>
<tr>
<td colspan="2">🔎 <b>Semantic ⌘K search</b><br>Type what a pull request was <i>about</i> — “flaky login test” finds “Retry the auth suite” — over titles, labels, branches, descriptions and the diffs you have opened. On-device embeddings, stored in your own SQLite, never sent to an AI endpoint; <code>owner/repo#128</code> still wins outright.</td>
</tr>
<tr><th colspan="2" align="left">Automate</th></tr>
<tr>
<td>🛠️ <b>Delegate to a local agent</b><br>Hand a PR or a single finding back to Claude Code in an isolated worktree with turn and budget caps. Optionally started for you when CI turns red.</td>
<td>🚦 <b>Auto-merge rules</b><br>Opt in, and an agent PR that is green, approved and mergeable gets its merge queued for you — narrowable by repo and label, never approving anything, every decision in a local audit log.</td>
</tr>
<tr>
<td colspan="2">🔗 <b>Webhooks, deep links, CLI</b><br>Signed outbound events into n8n, <code>shepherd://</code> links, and a <code>shepherd</code> binary that drives the app from a terminal, Raycast or Shortcuts.</td>
</tr>
<tr><th colspan="2" align="left">Intelligence</th></tr>
<tr>
<td>✨ <b>Drafts, not submissions</b><br>Draft a review summary or an inline comment from the diff in front of you. It lands as editable text; nothing is ever submitted for you.</td>
<td>🧠 <b>On-device first</b><br>Heuristics always, Apple Foundation Models where available, your own key optional — Anthropic, any OpenAI-compatible endpoint, Konduit (EU) or Ollama.</td>
</tr>
<tr>
<td>🌐 <b>Translate in place</b><br>A description or comment in a language you don't read gets an on-device translation <i>below</i> the original — never instead of it, never through a cloud endpoint.</td>
<td>✍️ <b>Writing Tools everywhere</b><br>Apple's proofread, rewrite and tone tools in every field you write review text in — summary, inline comment, thread reply, saved reply.</td>
</tr>
<tr><th colspan="2" align="left">Sync &amp; privacy</th></tr>
<tr>
<td>🔐 <b>Sync you host</b><br>Every setting <i>and</i> every secret in one AES-256-GCM object in an S3 bucket you own. A new Mac plus the passphrase is a set-up Mac. No account, no server.</td>
<td>🗄️ <b>Local-first by construction</b><br>SQLite is the source of truth, writes go through a persisted outbox, secrets live in the Keychain, and there is no telemetry anywhere.</td>
</tr>
</table>

The long form — every feature, with the decisions behind it — is in
[docs/FEATURES.md](docs/FEATURES.md).

## How it stays yours

- **Local SQLite is the source of truth.** GitHub is a sync target, not a backend
  ([ADR 0006](docs/adr/0006-local-first-sqlite-grdb.md)).
- **Writes go through an outbox.** Approve offline; it lands when the network does, with retries and
  a staleness check.
- **Secrets live in the Keychain** — never in `UserDefaults`, never in the database.
- **No telemetry, ever.** The complete list of hosts Shepherd may contact is in
  [CONTRIBUTING.md](CONTRIBUTING.md#rules-of-the-road); adding one requires a new ADR.
- **Sync is end-to-end encrypted and self-hosted.** Your bucket, your passphrase, ciphertext on the
  wire ([ADR 0014](docs/adr/0014-encrypted-settings-sync.md)).
- **AI runs only when you ask.** Off by default, on-device where possible, and the unattended
  morning digest may never call an endpoint at all. ⌘K search is the other side of the same rule:
  it runs on every keystroke, so it is on-device *only* and has no code path to a provider
  ([ADR 0019](docs/adr/0019-semantic-search-on-device-embeddings.md)).
- **Crash reports stay on disk.** Opt-in MetricKit JSON in Application Support, no uploader in the
  code path ([ADR 0017](docs/adr/0017-local-diagnostics-metrickit.md)).

## Keyboard

| Keys | Action | | Keys | Action |
| --- | --- | --- | --- | --- |
| `j` `k` | Move down / up the list | | `r a` | Approve |
| `⏎` | Open the selected pull request | | `r x` | Request changes |
| `x` | Tick a row for bulk triage | | `r c` | Comment |
| `g a` `g r` `g s` | Group by agent / repo / review state | | `m` | Merge… |
| `⌘K` | Command palette &amp; pull-request search | | `r f` · `⇧⌘⏎` | Start a focus review session |
| `⌘R` | Sync now | | `d` `n` `esc` | In a session: done & next · next · end |
| `⌘⏎` | Submit the pending review | | | |

Two-keystroke sequences forget an unfinished prefix after 1.5 s, so a stray `r` never swallows the
next key.

## Automation & integrations

```sh
shepherd open schnaq/review#128        # …/review/128 and a github.com PR URL work too
shepherd inbox needs-my-review         # mine · involved · approved-by-me
shepherd inbox --filter agent:claude-code   # humans · bots · agent:<id> · repo:<owner>/<name>
shepherd sync                          # sweep every repository now
shepherd settings automation           # jump to a Settings tab
```

Every command is a URL the app parses, so anything that can open one — Raycast, Shortcuts, a
bookmark, `open(1)`, an n8n *Execute Command* node — can drive Shepherd
([ADR 0013](docs/adr/0013-url-scheme-and-cli.md)):

| URL | Effect |
| --- | --- |
| `shepherd://pr/<owner>/<repo>/<number>` | Open that pull request's review screen |
| `shepherd://inbox` · `shepherd://inbox?filter=<token>` | Inbox, optionally filtered |
| `shepherd://sync` | Run one sweep now |
| `shepherd://settings` · `shepherd://settings/<tab>` | Open Settings, optionally on a tab |

**Outbound webhooks** (Settings → Automation) POST a versioned JSON event to the one URL you type —
`review.submitted`, `pr.merged`, `delegation.finished`, `inbox.new_review_request` — after the
action really reached GitHub, plus `pr.auto_merge_queued` the moment a rule decides something
unattended. With a signing secret each request carries
`X-Shepherd-Signature: sha256=<hex HMAC of the raw body>`, deliberately the same shape as GitHub's
`X-Hub-Signature-256`, so an n8n Crypto node you already have works unchanged. Schema, guarantees
and a three-minute n8n recipe: [docs/WEBHOOKS.md](docs/WEBHOOKS.md).

**AI endpoints** are yours to pick: Anthropic, or any OpenAI-compatible base URL with one-click
presets for **Konduit (EU)** and a local **Ollama**, model discovery and a connection test.

## Install

```sh
brew install --cask schnaq/tap/shepherd     # planned — the tap is not published yet
```

Shepherd will ship as a notarized DMG on GitHub Releases and update itself through Sparkle 2. The
whole pipeline is committed (`Scripts/release.sh`, [`.github/workflows/release.yml`](.github/workflows/release.yml),
[the cask template](Scripts/homebrew/shepherd.rb)) but **there are no published releases yet**: it
waits on the maintainer's Apple Developer ID certificate and Sparkle signing key. Until then, build
it yourself:

```sh
brew install xcodegen
git clone https://github.com/schnaq/review.git shepherd && cd shepherd
cd web/diff-viewer && npm ci && npm run build && cd ../..   # bundle the Monaco diff viewer
xcodegen generate
open Shepherd.xcodeproj
```

Needs macOS 26 (Tahoe) or later on Apple Silicon, Xcode 26+ and Node 22+. Sign in with GitHub via
device flow, or paste a fine-grained personal access token. A source build is unsigned and has its
updater switched off, which Settings → Account states in one line. The `ShepherdKit` package is
platform-independent — `cd Packages/ShepherdKit && swift test` needs no Xcode. The `shepherd` CLI is
its own scheme:

```sh
xcodebuild -project Shepherd.xcodeproj -scheme ShepherdCLI -configuration Release \
  -derivedDataPath .build/cli build
cp .build/cli/Build/Products/Release/shepherd /usr/local/bin/
```

## Status

**Pre-alpha, under active development.** The v1 skeleton exists and builds: the
domain/network/persistence/sync package (tested on macOS *and* Linux), the Monaco diff-viewer
bundle, and the SwiftUI app — inbox, review flow, command palette, settings, on-device and BYOK
intelligence. It has not yet been exercised against real repositories at scale, so expect rough
edges. What is done, next and deliberately out of scope: [docs/ROADMAP.md](docs/ROADMAP.md).

## Architecture

The app target owns all UI and every Apple-only framework; everything else lives in `ShepherdKit`,
an SPM package that imports no AppKit, SwiftUI or WebKit and is tested headlessly on Linux in CI.
The `shepherd` CLI links only the domain module, so it has no client, no database and no Keychain
access — it can reach the app solely through `shepherd://`.

```mermaid
flowchart LR
  CLI["shepherd CLI"] -->|"shepherd://"| App
  App["Shepherd.app<br/>SwiftUI · Monaco in WKWebView"] --> Sync["ShepherdSync"]
  App --> DB["ShepherdPersistence<br/>SQLite · outbox"]
  Sync --> GH["GitHubKit<br/>GraphQL + REST"]
  Sync --> DB
  GH --> Core["ShepherdCore<br/>models · heuristics · agent detection"]
  DB --> Core
  GH --> GitHub[("github.com")]
  App -.->|"a bucket you own"| S3[("S3-compatible storage")]
  App -.->|"only when you ask"| AI[("AI endpoint you chose")]
```

Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); every significant decision has an ADR in
[docs/adr](docs/adr/README.md), grounded in the research reports in [docs/research](docs/research).

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the setup, the module rules and the hard privacy lines (no
telemetry, Keychain-only secrets, local-first). Third-party licences that ship inside the app are
in [NOTICES.md](NOTICES.md).

## License

[MIT](LICENSE) — 🐑
