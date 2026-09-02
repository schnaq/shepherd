# Features in detail

The [README](../README.md) is the overview; this is the long form. Everything here describes
behaviour that is implemented or specified in an ADR — where a decision explains *why* something
works the way it does, the ADR is linked. Status of the whole thing: pre-alpha, see
[ROADMAP.md](ROADMAP.md).

---

## Inbox

### One inbox for all repos

Every open pull request across your repositories and organizations, aggregated by a single GitHub
search sweep — not fifty browser tabs. Reads go through GraphQL search with ETag polling, writes
through REST ([ADR 0005](adr/0005-api-strategy-graphql-search-rest-writes.md)).

Smart views on the rail: **Needs my review**, **My pull requests**, **Involved**,
**Approved by me**. "Approved by me" is honest about being an approximation — GitHub's search
facets do not expose "I approved this", so it shows pull requests you were asked to review that
now carry an approval, and the rail says so in its tooltip.

### Agent-aware triage

Pull requests authored by bots and coding agents are detected, labelled, and groupable as a
first-class facet ([ADR 0008](adr/0008-agent-provenance-first-class.md)): see at a glance what
Claude Code, GitHub Copilot, OpenAI Codex, Devin, Cursor — or a human — sent you. Detection uses a
bundled registry (login patterns, branch prefixes, commit trailers) that you can extend or
override per entry, and each agent keeps one stable colour everywhere in the app.

Grouping (`g a` / `g r` / `g s`) switches the sections between provenance, repository and GitHub's
aggregate review decision. Sections and row order inside them are fully deterministic: the inbox
must not reshuffle itself between two sweeps that returned the same data.

### Menu-bar quick inbox

The menu-bar item carries the number of pull requests waiting for your review and opens a short
list of them — repository and number, title, who or what wrote it, CI state — where one click
opens the pull request in the main window. "Sync now" and the full inbox are one click away too.
It reads the same local database the window does, so it costs no extra GitHub call, and it can be
switched off in Settings → Appearance.

### Find a pull request by what it is about

⌘K has always been the command palette. It is now also the search box: type two or three words and
the pull requests in your inbox that are *about* that come up beside the commands — repository and
number, title, who wrote it, CI state, and one line saying why it matched (the label, the changed
file, the line of the diff). ⏎ opens it, exactly as ⏎ on an inbox row does.

It matches meaning, not just words: *flaky login test* finds "Retry the auth suite" even though
they share no word. And it is still precise where precision is what you want — `schnaq/review#128`
or `#128` puts that pull request first whatever else is open, and a query that matches nothing
comes back empty instead of offering you the six least-unrelated pull requests in the inbox.

What is searched is the title, the repository and number, the labels, the branch and the author for
**every** pull request, plus the description, the changed-file paths and the added lines of the diff
for anything you have opened for review. Nothing extra is downloaded to build that: it is the same
rows the inbox and the review screen already store ([ADR 0006](adr/0006-local-first-sqlite-grdb.md)).

**The ranking happens on your Mac and cannot happen anywhere else.** The embeddings are Apple's
on-device model, stored in the local SQLite database; a configured AI endpoint is never used for
search, even when you have one, because search runs on every keystroke over every pull request and
that is not a thing to send to a third party
([ADR 0019](adr/0019-semantic-search-on-device-embeddings.md)). On a Mac without the on-device model
⌘K keeps working on words alone, and Settings says so in one line.

The index is on by default — it is built from data you already have and costs nothing but a little
CPU — and Settings → Intelligence shows what it holds, with a *Rebuild index* button and a switch.
Switching it off empties it.

### A morning digest, built on your Mac

Switch it on and once a day — nine o'clock by default, weekdays only if you like — Shepherd tells
you what came in since the last one: new review requests, green agent pull requests that only need
an approval or a merge, your own pull requests with red CI or a change request, and reviews it
could not send. One notification that opens the inbox, plus the same summary as a dismissible card
above the list, where each line has a *Show* that takes you to it. Off by default.

It is assembled entirely from the local database — no GitHub call, no AI, nothing sent anywhere,
because it runs while you are not watching — and there is no launch agent or background daemon
behind it: the app checks the time while it is open, so if your Mac was asleep at nine the digest
arrives when it wakes, once, on the same day. A quiet night produces nothing at all.

---

## Review

### Full code review in-app

Side-by-side and inline diffs (Monaco, the VS Code diff engine, in a WKWebView with a typed JSON
bridge — [ADR 0003](adr/0003-monaco-diff-viewer-in-wkwebview.md)), inline comments on lines,
multi-comment pending reviews, approve / request changes / comment, reply to and resolve review
threads, CI check status, and merge (merge / squash / rebase) — complete GitHub review parity,
natively wrapped. Drafts survive restart and offline; a staleness check runs before a submit.

### Review-priority file ordering

Changed files are grouped and ranked by what deserves your attention first — deterministic
heuristics (source vs. lockfiles vs. generated code, churn, path risk), optionally sharpened by
on-device AI ([ADR 0007](adr/0007-layered-intelligence.md)). Viewed state is tracked per file.

### Saved replies and per-repo review templates

The same three sentences go out twenty times a week — "please add a test for this branch", "this is
generated, keep it out of the diff" — so save them once and drop them into any comment field with
one click: inline comments, the review summary, thread replies.

And a repository (or a whole owner, `schnaq/*`) can carry a summary template, so a new review opens
with your team's checklist already in it. Matching is exact-beats-wildcard, longer wildcard beats
shorter, then list order. It only ever fills an *empty* review: a pull request you have written
anything on is never touched. Both live in Settings → Replies and travel with encrypted settings
sync.

### Focus review session

Press ⇧⌘⏎ (or `r f`) and Shepherd walks you through every pull request waiting for your review, one
after another, keyboard only, on the ordinary review screen — there is no second review UI. A thin
bar shows "3 of 12", `d` marks one done and moves on, `n` leaves it for later, `esc` ends the run.
Approving, requesting changes or merging advances on its own, so a queue of twenty agent pull
requests is twenty keystrokes and no mouse.

The queue is frozen the moment you start it — pull requests that land while you work wait in the
inbox instead of pushing your progress bar backwards — and anything that gets merged or closed in
the meantime is skipped with a note when you reach it. It finishes with "Session complete — 9
reviewed, 3 skipped" and how long it took. Nothing is persisted: a session is a sitting.

### Bulk triage for the agent flood

Tick the pull requests you have looked at (`x`, ⌘-click, ⇧-click for a range — or "select all green
agent PRs in this view"), then approve, approve & merge, or merge them behind **one** confirmation
dialog.

The dialog lists every pull request with its checks and review state and marks the ones it will
skip — red CI, conflicts, drafts, changes requested, your own — with the reason, so what you
selected and what gets written can never drift apart. Each pull request is then queued
individually, with the same offline, retry, rate-limit and staleness handling a single review gets
([ADR 0015](adr/0015-bulk-triage.md)).

### Writing Tools and on-device translation

Every field you write review text in — the summary, an inline comment, a thread reply, a saved
reply, the instructions you hand a local agent — offers Apple's **Writing Tools**: proofread,
rewrite, change the tone, all on-device where the Mac supports it. Where the ✨ AI-draft button
already sits, the two work together: the draft lands in the field as editable text, and Writing
Tools is what you refine it with. Single-line fields get proofreading only, and the fields that are
not language at all — a repository pattern like `schnaq/*` — get nothing, so nothing can helpfully
"correct" a glob.

And when a description or a comment is in a language you do not read, a **Translate** button puts an
on-device translation in a tinted block *below* the original — never in place of it, so what you
approve is always what was actually written, with *Hide translation* to collapse it again. It uses
Apple's Translation framework: nothing is sent anywhere, not even when you have configured an API
key, and nothing is stored or synced. Shepherd checks first whether the pair works on your Mac and
whether the text is already in your language, so you never get a button that cannot do anything —
and the first translation of a new language may let macOS offer you its own language-pack download
([ADR 0020](adr/0020-apple-native-text-intelligence.md)).

---

## Automation

### Delegate back to a local coding agent

Send a pull request or a single review finding back to the locally installed Claude Code (headless
`claude -p`, `stream-json` output parsed as it arrives) in an isolated detached worktree, with
turn and budget caps. The command template is configurable for other agent CLIs. Shepherd never
touches agent auth and never pushes: you review the result and push it yourself
([ADR 0011](adr/0011-delegate-to-local-agent-cli.md)).

### Optional: let it start itself when CI goes red

Switch on an auto-delegation rule and the moment CI *turns* red on one of your pull requests — or,
as a second opt-in, when a reviewer requests changes — Shepherd sends the agent after it and
notifies you: same worktree isolation, same caps, at most one run per pull request and per head
commit (deduplicated across restarts), with caps for simultaneous and daily runs.

Off by default, and it still never pushes, approves or merges anything: the finished diff waits for
you in the Delegation Center, marked as automatic
([ADR 0016](adr/0016-auto-delegation-rules.md)).

### Optional: merge what a human already approved

An agent opens a dependency bump, CI goes green, you approve it — and then it sits there until
somebody remembers to press merge. Switch on auto-merge and Shepherd queues that merge for you the
next time a sweep sees an agent-authored pull request that is **green, approved, mergeable and not a
draft**. Those conditions are the feature, not checkboxes: the only knobs are narrowings — a
repository allow-list and a set of labels the pull request must carry — so no configuration can
turn a rule that *records* a human's decision into one that *makes* it. Shepherd never approves.

Each merge is one ordinary outbox row, pinned to the head commit the decision was made on and
merged with the method you last merged with by hand, so it gets the same offline, retry and
staleness handling as a click. One queued merge per pull request and head, ever, kept in a local
audit log (Settings → Automation, last ten shown) that explains every skip as well as every merge.
One notification per sweep says how many were queued, and a `pr.auto_merge_queued` webhook fires
for each. Off by default ([ADR 0018](adr/0018-auto-merge-rules.md)).

### Outbound webhooks for your own automation

Point Shepherd at an n8n Webhook node (or any JSON endpoint) and get a versioned event when a
review is submitted, a pull request is merged, a delegation finishes, a review request lands, or an
auto-merge rule queues a merge — signed with your own HMAC secret if you want. Events fire only after the action really succeeded,
and only to the one URL you typed. The payload says what happened, never what was written: no
review text, no comment bodies, no diffs, no agent output. Full schema, guarantees and an n8n
walkthrough: [WEBHOOKS.md](WEBHOOKS.md), decision: [ADR 0012](adr/0012-outbound-webhooks.md).

### Drivable from anywhere: `shepherd://` links and a tiny CLI

`shepherd open owner/repo#123` jumps straight to the review screen; `shepherd inbox
needs-my-review` and `shepherd sync` do what they say. Works from the terminal, Raycast,
Shortcuts, a browser bookmark or an n8n *Execute Command* node — so an incoming GitHub event can
put the right pull request on your screen.

The CLI only opens URLs: it links `ShepherdCore` and nothing else, so it never talks to GitHub and
never sees your token ([ADR 0013](adr/0013-url-scheme-and-cli.md)). A pull request that is not in
your inbox yet is fetched on demand, so a link from a colleague works; a link that arrives while
you are signed out is remembered and opens right after sign-in.

---

## Intelligence

### On-device first, cloud optional

Three tiers ([ADR 0007](adr/0007-layered-intelligence.md)):

1. **Heuristics**, always on and always local: file prioritisation, risk hints, the pull-request
   digest.
2. **On-device**: pull-request summaries and triage hints via Apple's Foundation Models framework
   where the machine supports it.
3. **Your own key**: deeper whole-pull-request analysis through Anthropic, or any
   OpenAI-compatible endpoint — with presets for **Konduit (EU)** (EU-hosted open models, with a
   link to the console for the key) and a local **Ollama**, model discovery via
   `GET {base}/models`, a free-text model field as the fallback, and a connection test.

The app is fully functional with AI switched off, and what reaches a configured endpoint is capped
against an explicit token budget before it is sent.

### AI-drafted review text — a suggestion, never a submission

A ✨ button next to the review summary and next to any inline comment drafts the text for you: the
summary from the pull request's digest and the comments you have already written, an inline comment
from the diff around the line you clicked. It lands in the field as editable text, labelled as a
draft until you touch it, and it never overwrites what you typed without asking whether to replace
or append.

Nothing is ever submitted for you — Shepherd has no path from generated text to GitHub that does
not go through your click.

---

## Sync & privacy

### Encrypted settings sync across your Macs — your bucket, your passphrase

Point Shepherd at an S3-compatible bucket you own (STACKIT Object Storage, MinIO, anything) and it
stores one object holding *all* of your settings **and** your secrets — GitHub token, AI keys,
webhook secret — encrypted on your Mac with AES-256-GCM under a passphrase-derived key
(PBKDF2-HMAC-SHA256, 600 000 iterations, envelope metadata as AAD). Requests are SigV4-signed by
hand for `GET`/`PUT`/`HEAD` on that one object; there is no AWS SDK.

A new Mac with bucket access and the passphrase is fully set up. The bucket operator sees ciphertext
and nothing else. No Shepherd account, no server — upload and download are manual in v1, and there
is no recovery if you lose the passphrase, deliberately
([ADR 0014](adr/0014-encrypted-settings-sync.md)).

### Optional crash reports that never leave your Mac

Switch on local diagnostics and macOS hands Shepherd its own crash, hang and CPU-exception reports
on the next launch after one happened; Shepherd writes them as JSON files in Application Support,
keeps the 30 newest, and shows you the folder. No crash-reporting SDK, no endpoint, no uploader —
if you want to help with a bug, you open the folder and attach the file yourself. Off by default
([ADR 0017](adr/0017-local-diagnostics-metrickit.md)).

### Local-first

Everything lives in a SQLite database on your Mac ([ADR 0006](adr/0006-local-first-sqlite-grdb.md)).
GitHub is a sync target, not a backend. Writes go through a persisted outbox, so an approval you
pressed offline is still an approval when the network comes back — and a queued approval has
approved nothing until it lands. No server, no telemetry, no account other than your GitHub login;
where Shepherd does sync between your own machines, it does it through storage you own, encrypted
before it leaves the Mac. The complete list of hosts Shepherd may ever contact — and the rule that
adding one needs a new ADR — is in [CONTRIBUTING.md](../CONTRIBUTING.md).

---

## Why not an existing tool?

We looked ([full report](research/research-landscape.md)). Desktop Git clients (Tower, Fork,
GitKraken) review pull requests but are closed-source, cloud-backed and single-repo-centric.
Multi-repo inboxes (Graphite, GitKraken Launchpad, Devin Review) are SaaS. `gh-dash` is open source
and keyboard-driven but a TUI without inline review. Nothing today is **open source + local-first +
full review parity + agent-aware**. That is the gap Shepherd fills.
