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

### What kind of change is this, and how much can it hurt

Every pull request in the inbox carries a chip: `fix · risk high`. Click it and a popover gives you
the one sentence behind it — "touches the auth middleware and deletes two tests" — plus the line
that matters most about it: *classified on this Mac, nothing was sent anywhere.* The rail gains a
RISK section that filters the list to what is high, medium or low, and ⌘K understands `risk:high`
and `kind:dependency` as filters beside everything it already searches.

The verdict is Apple's on-device model reading the same local search document ⌘K uses, plus the risk
hints Shepherd works out from the diff by itself. It runs in the background while the inbox syncs,
one pull request at a time, and only for a pull request whose text actually changed since the last
time — so a sweep that changed nothing costs nothing.

**It sorts, it never approves.** No rule engine can read a verdict: bulk triage, automatic merging
and automatic delegation take pull-request rows and your own rules, and there is no path from a
generated classification to a button, a merge or an agent. That is a rule with a test behind it —
adding a verdict to any of those inputs fails CI ([ADR 0023](adr/0023-structured-triage.md)).

Because it runs unattended there is deliberately **no cloud option**, not even with a key
configured: a background pass over every pull request in your inbox is not something to send to a
third party. With Apple Intelligence off — or on a Mac whose tagging model is not there — the chip
and the facet fall back to the risk hints Shepherd computes without any model at all ("touches
auth", "deletes tests", "only a lockfile"), and Settings → Intelligence says so in one line. The
switch is under Semantic Search, on by default, and switching it off deletes every stored verdict.

### Two lanes: what deserves a glance, and what deserves a read

The rail gains a LANES section with two rows. A pull request is a **Short look** only when three
things are true at once: CI is green, the diff is small (five files and a hundred and twenty
changed lines by default, both adjustable), and nothing sensitive is in it — no CI workflow, no
auth or secret path, no schema migration, no deleted test. Everything else is a **Full review**.
Click either row and the list filters to it.

That is the whole gate, and it is deliberately not clever. A pull request whose diff Shepherd has
not fetched yet is a full review, because "short look" is a promise and Shepherd will not make it
about a diff it has never seen.

Beside each agent's name, a track record:
`Claude Code · this repo · 23 merged · 2 reverted · CI green first push 78 %`. It tints the
provenance chip — amber if something had to be taken back out, green for a settled record — and
orders rows inside a lane, so the agent with numbers beside it comes first when everything else is
equal. Click it and a popover gives you the rest: how many closed without merging, the median
number of rounds of changes you asked for, and the line that says where the numbers come from —
*this repo · last 90 days · on this Mac*. A pull request from somebody with no history gets no
badge at all.

**The record never moves a pull request between the lanes.** The lane is CI, size and paths; the
record is a badge and a sort order. That is a rule with a test behind it — the classifier's input
type cannot even express a history, and adding one to the automatic-merge, bulk-triage or
automatic-delegation inputs fails CI, exactly as it does for a triage verdict
([ADR 0027](adr/0027-track-record-and-trust-lanes.md)).

The numbers come from the pull requests your repositories **closed**, which Shepherd otherwise
never looks at. Settings → Automation → *Load track record* reads the last ninety days once per
repository — at most five hundred each, one repository at a time, with a progress line and a Stop
button — and from then on the sync keeps it current by itself: when a pull request disappears from
the inbox, Shepherd reads its final state once. Reverts are found by reading titles and
descriptions (`Revert "…"`, `This reverts commit …`), never by asking GitHub about commits.

The two thresholds travel to your other Macs; the history does not — it is rebuilt by a button
there, which is why the popover says *on this Mac*. *Clear history* empties it, and the lanes carry
on working, because they never read it.

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

When you reach for the menu on a thread — a reply in the conversation panel, or a comment on a line
that already has one — the two replies that fit *that* conversation are repeated at the top under
**Suggested**, before the divider and your full list. It is the same on-device sentence embedding
⌘K search uses ([ADR 0019](adr/0019-semantic-search-on-device-embeddings.md)): no language model,
no setting, no network, and nothing that could reach an API key. A reply body is embedded once and
cached until you edit it; the thread is embedded when you point at the button, never while you
type. And it is a shortlist, not an answer — nothing is inserted until you click a row, a poor
match is left out rather than padded to two, and on a Mac without the embedding model (or with
fewer than three saved replies) the menu is exactly the plain list it has always been.

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

### What it says, and what Shepherd found

Above the description of an agent's pull request, a card puts each claim the description makes next
to the evidence for it, one line each:

- **Tests added or run** — ✓ *2 changed files match a test naming convention. CI is green: 7 of 7
  checks passed.*
- **Only `Sources/Parser` changed** — ✗ *8 of 11 changed files are under "Sources/Parser".
  ".github/workflows/ci.yml" is outside "Sources/Parser".*
- **No breaking changes** — ✗ *"Sources/GitHubKit/GitHubClient.swift" removes or changes an exported
  declaration at line 214.*
- **Fixes issue #142** — ? *Issue #142 “Uploads fail silently” is open and lists 3 acceptance
  bullets. 2 of 3 acceptance bullets are mentioned in the pull request's description, changed paths
  or commit messages.* — with a ✓ or a · in front of each bullet.

Every fact is a sentence and every fact with a file behind it is a link: one click puts you on that
line in the diff. A ✗ line also offers **Turn into a comment**, which drops the claim and the facts
under it into your review summary — and asks first if you have already written something there.
Nothing is submitted; nothing is even sent.

The most useful line is the one that catches a green CI: a hunk that deletes an `XCTAssert` or adds
an `XCTSkip` makes the suite pass, so "tests added" is marked ✗ *with the line* even when every
check is green.

The `fixes #N` line is the one that looks beyond the diff. When you open the card, Shepherd reads
that issue once, finds its acceptance criteria — a `- [ ]` checklist, or the list under a heading
called "Acceptance criteria" or "Definition of done" — and marks each bullet ✓ when the pull
request mentions it and · when it does not, naming the words that matched. The line is ✓ only when
every bullet is mentioned, and it is **never ✗**: matching words can tell you that the pull request
talks about a bullet, and it cannot tell you a bullet was not done, so an unmentioned bullet is a
prompt to open the issue rather than a finding against the author. If the issue cannot be read — it
does not exist, you cannot see it, you are offline — the line says the criteria were not checked
and why. Nothing about the issue is stored: it is read while the card is open and forgotten with
the screen.

**There is no score, and there never will be** — no number, no badge, no "looks safe". The card
lists what the description claims and what the diff and CI show, and the judgement is yours
([ADR 0026](adr/0026-claims-vs-evidence.md)). Apart from that one issue read it runs entirely on
data Shepherd already fetched: nothing stored. On an agent's pull request it opens
expanded; on a person's it is a header you can open
([ADR 0008](adr/0008-agent-provenance-first-class.md)). A description that claims nothing gets no
card at all.

Opening the card also lets Apple's on-device model read that same description once, for the
phrasings the patterns miss. A line it found carries a small **Read by the model** tag and is
checked against the diff and CI exactly like every other line — same glyph, same facts, same links,
still no score. The description never leaves the Mac, nothing is read on a card you have not
opened, and on a Mac without the model there is no tag, no caption and no error: the card is
complete without it.
### Since your review — only what changed in the fix round

The agent pushes a fix round, and the review screen opens on **Since your review** instead of on the
whole pull request again: only the files and hunks that differ from the head you actually reviewed,
in the same risk order the full list uses. The other segment, **All files**, is one click away and
is what a first review still opens on — the control only appears once there is a round to compare
against.

Under it, your findings from that round, each with what became of it: **Addressed** when the lines
your comment hangs on changed, **Unchanged** when neither the lines nor the thread moved, **Moved**
when the file was renamed or the lines around it shifted, **Replied** when somebody answered you.
Click one to jump to the file and line. "Addressed" says the lines changed and nothing more —
Shepherd has not judged the fix, the thread stays open, and resolving it is still your button. The
inbox row carries the short version before you open anything: *"3 rounds · 2 findings unchanged"*.

This works because Shepherd keeps the diff you reviewed. The moment a review of yours reaches
GitHub, the pull request's patches are stored locally as *the head you reviewed*, and the
comparison is computed on your Mac from that snapshot. So a force-push — the normal thing on an
agent branch — cannot take the baseline away, it works offline, and no compare API is called. A
review you submitted on github.com is picked up too, as long as the pull request is still on the
commit you reviewed; after that there is nothing honest to compare, and the control stays away
rather than guessing ([ADR 0028](adr/0028-since-my-review-interdiff.md)).

### You have said this three times

The third time you write essentially the same review comment on one repository's pull requests, a
card appears on the review screen: **"You have said this three times."** — with the three comments
quoted and the pull requests you wrote them on. The problem, at that point, is not the pull request
in front of you. It is that the repository's agent instructions do not say it.

So the card offers **Draft a rule**. It opens the delegation sheet with a task already written: add
one rule to `CLAUDE.md` or `AGENTS.md`, whichever the repository has, that prevents this — with your
three comments quoted underneath and a note to keep it to one paragraph in the file's existing
voice. With a model configured, the ✨ button drafts the wording for you instead, streamed into the
field like every other draft. Then it is an ordinary delegation: your local agent works in a
detached worktree, **Run** is your click, and the instruction-file change comes back as a pull
request you review in Shepherd like any other. Shepherd never commits to a repository.

The counting happens on your Mac, from **your own comments only** — nobody else's review text is
read, and there is no cloud option here even when you have configured a key
([ADR 0020](adr/0020-apple-native-text-intelligence.md)'s line). A finding needs three comments
within thirty days on at least two different pull requests of the same repository before it counts,
because three comments on one pull request are one argument, not a pattern. Nothing is fetched from
GitHub for it and nothing is stored.

An **automatic** delegation never gets this: a recurring finding is a suggestion to you, not an
event, and there is no rule you could arm with it
([ADR 0029](adr/0029-feedback-loop-agent-rules.md)). *Dismiss for this repository* makes the card go
away for good on that Mac; every finding stays listed under **Settings → Replies → Recurring
findings** with a *Show again* beside it.

### Where does this long thread stand?

A review thread with six comments or more gets a **Summarise** button. Press it and three lines
appear above the conversation: a chip saying whether the thread is **Agreed**, **Open** or
**Blocked**, one paragraph of what was settled and who is waiting on whom, and the questions nobody
has answered yet as bullets.

It runs on Apple's on-device model and only there. These are your colleagues' comments, so there is
no cloud option for them even when you have configured an API key — the same line ADR 0020 draws
around translating somebody else's sentence ([ADR 0007](adr/0007-layered-intelligence.md)). On a Mac
without Apple Intelligence the button simply is not there, and the thread reads exactly as it always
did.

Long threads are summarised from their end rather than refused: when the conversation does not fit
the model's context window, the newest comments are kept, the oldest are given up, and the card says
so — *"Covers the last 8 of 23 comments"*. Nothing is stored, nothing is synced, and a new reply
retires the summary rather than leaving a stale one above an answered question.

And it summarises only. **Resolve thread** stays your own button beside the reply field; the digest
is not allowed to suggest pressing it, and there is no path from it to a reply, a resolution or the
outbox.

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

### Deutsch: the whole app in German

Set your Mac to German and Shepherd is in German — every label, every tooltip, every notification,
every error. There is no language setting to find: the app follows `Locale.current`, the way a
macOS app should, and nothing about your language travels in the encrypted settings document.
Apple's German conventions throughout — Einstellungen, Menüleiste, Mitteilungen, Schlüsselbund,
infinitives on buttons, „typographische Anführungszeichen“.

**The review vocabulary stays English**, on purpose: pull request, review, approve, request
changes, merge, draft, commit, diff, CI. github.com is open in your other window and it says
"Approve"; a German Shepherd that said "Genehmigen" would make you translate back before acting. So
you read "Merge für schnaq/review#128 eingereiht." and "übersprungen · changes requested" — German
sentences with GitHub's words in them.

Counts and dates go through the system rather than through string concatenation: relative times are
`RelativeDateTimeFormatter`'s, and where German needs "1 Pull Request" against "2 Pull Requests" the
String Catalog's plural rules say so (and say it correctly for English too, which had a couple of
"1 pull requests" before this). Everything else lives in one file,
`Shepherd/Resources/Localizable.xcstrings`, with a CI check that fails if a single user-visible
string is missing a German row — because a missing translation is otherwise invisible: it silently
shows the English original ([ADR 0022](adr/0022-german-localisation.md)).

The `shepherd` CLI stays English. Its output is read by shell scripts and n8n nodes, and it is a
URL builder with no resource bundle (ADR 0013).

---

## Automation

### Delegate back to a local coding agent

Send a pull request or a single review finding back to the locally installed Claude Code (headless
`claude -p`, `stream-json` output parsed as it arrives) in an isolated detached worktree, with
turn and budget caps. The command template is configurable for other agent CLIs. Shepherd never
touches agent auth and never pushes: you review the result and push it yourself
([ADR 0011](adr/0011-delegate-to-local-agent-cli.md)).

### Let Shepherd write the brief

The delegation sheet has a ✨ button next to the task field. Press it and Shepherd drafts the
brief for the agent out of what it already knows — the pull request's tier-1 digest, the branch and
commit the worktree sits on, the files its heuristics ranked riskiest, and the review comments the
finding is made of — as three Markdown sections: **Goal**, **Constraints**, **Acceptance**. The text
streams into the field word by word with a caption naming the tier that wrote it, and you edit it
like any other text.

**Run is still your click.** Nothing about a draft starts an agent, and a brief that would quote a
colleague's review comment stays on your Mac: that request is never offered to a configured cloud
endpoint, only to the on-device model. Automatic delegation rules keep their own fixed template —
an unattended run never receives a generated brief
([ADR 0011](adr/0011-delegate-to-local-agent-cli.md), [ADR 0007](adr/0007-layered-intelligence.md)).
With no model configured the button is simply absent.

### Answer the session that wrote the code

Claude Code stamps every commit it makes with the session it came from
(`Claude-Session: https://claude.ai/code/session_…`). When a pull request's head commits carry one,
every inline finding and the review summary gain a second button beside *Add comment*: **Send to
the session**. A sheet shows the exact message first — the file and line, your text verbatim, the
pull request link, the review round if there has been one — and Send runs it: your own installed
CLI, `claude --resume <session-id> -p "<message>"` by default, in the pull request's worktree,
streaming into the same delegation panel. A small session glyph on the inbox row marks the pull
requests that have a return address.

**It is not a review action.** The comment is still saved to your pending review exactly as *Add
comment* saves it — the thread stays the record — and sending resolves no thread, approves nothing,
submits nothing and starts no automatic delegation. And it needs no account: Shepherd holds no
Anthropic credentials, no API key and no token, it invokes the CLI you installed with the login
that CLI already has, and it never pushes what the session changes
([ADR 0030](adr/0030-session-back-channel.md), [ADR 0011](adr/0011-delegate-to-local-agent-cli.md)).

For a session that lives on `claude.ai/code`, the button reads **Open the session** and links to
it: whether the installed CLI can address a remote session at all is an open question, written up
with the commands that settle it in
[`docs/plans/session-back-channel-spike.md`](plans/session-back-channel-spike.md). Both commands
are editable in Settings → Delegation.

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

### Shortcuts, Siri and Spotlight

Shepherd's commands are **App Intents**, so they show up in the Shortcuts app with typed
parameters, in Spotlight's actions, and in Siri: *"Open my review queue in Shepherd"*, *"What needs
my review in Shepherd"*, *"Sync Shepherd"*, *"Start a review session in Shepherd"*, *"Summarise my
next review in Shepherd"*. On a German Mac you say them in German — *"Öffne meine Review-Queue in
Shepherd"*, *"Fasse meinen nächsten Review in Shepherd zusammen"* — one German utterance per
English phrase ([ADR 0022](adr/0022-german-localisation.md)). An *Open Pull Request* action takes a
pull request you pick — or search for, using the same on-device ⌘K ranker — and a *Get Pull
Requests Needing Review* action answers with the count and the list from the local database, with
no GitHub call, so it is safe on a five-minute automation.

Ask *"summarise my next review"* and Siri reads out the on-device summary of the pull request at
the top of your queue and shows a card with the title, the slug, the overview and up to three risk
notes. The matching *Summarise Pull Request* action takes a pull request, so *Get Pull Requests
Needing Review → Summarise Pull Request → Show Result* composes into your own morning routine.
It is **on-device only**: an intent runs with no review screen in front of you and Siri has no
screen at all, so a configured API key is deliberately never used here — a Mac without Apple
Intelligence hears "Apple Intelligence is not available on this Mac" rather than having the pull
request sent somewhere. It reads what is already cached, never fetches, and the summary is spoken
and drawn once: nothing is stored on the pull request, put in Spotlight or written to the database.

Every pull request in your inbox is also in **⌘Space**: title, `owner/repo#123 · author · CI
state`, and its labels, repository and agent as keywords. Opening a result opens the review screen
through the same routing a `shepherd://` link uses. Only that metadata is exported — descriptions,
diffs, review comments and your drafts never leave the local database — and one toggle in
Settings → Intelligence deletes every item Shepherd put there.

There are deliberately **no write actions**: nothing here can approve, request changes, comment,
merge or delegate. An intent runs without the review screen in front of you and Siri has no screen
at all, so a verdict formed there would be a verdict formed by somebody who has not read the diff
([ADR 0021](adr/0021-app-intents-and-spotlight.md)).

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

An OpenAI-compatible endpoint may volunteer more than an answer, and where it does, Shepherd shows
it — as an addition, never as a requirement. If the endpoint names the operator that actually ran
the weights, the caption over your draft says so (*AI draft (custom endpoint · scaleway)*); if its
model list publishes where each model runs, the picker carries a small badge per model
(*DE · zero retention · eu-owned*). You can also pin requests to a **country set** and to an
operator that **retains nothing**: two optional fields under the endpoint, sent as part of the
request, honoured by the endpoints that understand them and refused — openly — by the ones that
cannot meet them. Left empty, nothing extra is sent and the request is exactly the request
Shepherd has always made. And a rate-limited endpoint that says *come back in five seconds* is
waited out once and asked once more, never in a loop.

### AI-drafted review text — a suggestion, never a submission

A ✨ button (⇧⌘D) next to the review summary and next to any inline comment drafts the text for
you: the summary from the pull request's digest and the comments you have already written, an
inline comment from the diff around the line you clicked. The draft **arrives word by word** —
in the AI caption colour, under a line naming the tier writing it (*Drafting on-device…*), so you
read it as it lands instead of watching a spinner. It is editable text, labelled as a draft until
you touch it, and it never overwrites what you typed without asking whether to replace or append —
for a streamed draft that question comes *before* the request is made, so answering *discard*
means nothing was generated and nothing was sent anywhere.

While the text arrives, the ✨ button is a stop button. Press it, press Escape, or simply start
typing: your keystroke wins the field, and either way the request ends there — the on-device
session is cancelled with it. Everything that had already arrived stays where it is, still labelled
as a draft, because you asked for text and some text came. A stream that fails half-way is the same
story with one line of the provider's own words under the field.

Nothing is ever submitted for you — Shepherd has no path from generated text to GitHub that does
not go through your click.

### Why is CI red?

A red check gets a **Why?** button, and the card under the checks list answers it: the failing
test, the `file:line` it points at — a link, when that file is in the diff — a one-line hypothesis
and how sure the model says it is, under the caption naming the tier that answered
(*Diagnosed on-device*).

The card shows its work. Every step the model took expands to **exactly what it was given**:
*read the failing checks · read the last lines of a job log · read the diff of one file*, with the
log tail and the diff window verbatim underneath. So the answer is a claim you can check in five
seconds rather than a guess with a confidence label on it.

It only reads. The model gets three tools and there is no fourth: the failing check runs, the tail
of one job log, the diff of one changed file — and it can only ask for a file this pull request
actually changed. Shepherd reduces the log on your Mac first (the error and failure lines with
their context, repeats dropped, capped against the tier's budget), so what a model sees is never a
raw megabyte of `xcodebuild` output. A check that is not a GitHub Actions job — Buildkite,
CircleCI — has no log to read, and the card says so instead of guessing.

The on-device model answers it. When the log does not fit, the card offers **one** button —
*Ask <provider> with the full log?* — and only if you configured a key; that click is the
only way a CI log reaches your endpoint, and without a key the card simply says the log did not fit.
One more button, **Draft an agent brief**, opens the delegation sheet with the finding filled in —
and Run is still your click ([ADR 0024](adr/0024-tool-calling-ci-diagnosis.md)).

### Explain these lines

Select lines in the diff and the comment composer that opens carries an **Explain** action (⌥E)
beside the ✨ button. A popover answers what the change does and what it touches, in three to six
sentences of plain language, **in your own language** — a German reviewer reads German, because the
instruction names the language rather than hoping the model guesses. The sentences arrive as they
are written, under the tier that is writing them, and the finished answer keeps that line
(*Explained on-device*), so "did these lines leave my Mac?" has an answer you can read rather than
one you have to infer.

It sends exactly what an inline draft sends: the same windowed diff excerpt around the lines you
picked, capped against the same token budget, so tier 2 answers it on your Mac and tier 3 only
where you configured a key yourself.

It explains, it does not review. There is one button — **Turn into a comment** — and it writes the
explanation into the inline-comment field through the same rules as any draft: labelled until your
first keystroke, and never over text you had already typed without asking whether to replace or
append. Stop keeps the sentences that arrived; Escape closes the popover and throws them away.
Nothing is saved and nothing is sent until you add the comment yourself.

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
