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

### The issues you should be handing out

Shepherd starts at the pull request. Your morning does not — it starts at the issue somebody should
pick up. So the inbox now has two sections, and a segmented control at the top of the rail moves
between them. It is the same window, the same three panes, the same `j`/`k` and the same ⌘K: the
picker changes what is in front of you and nothing else. Switch to *Issues*, work through them,
switch back, and the pull-request side is exactly where you left it — same smart view, same
facets, same row under the cursor.

What lands there is what the sweep finds: issues assigned to you, issues you opened, issues
mentioning you. Three searches beside the five the review inbox already runs, in the same cycle, on
the same host, at the same cadence — and if they fail, the review inbox does not
([ADR 0032](adr/0032-issues-inbox.md)).

The rail asks the five questions a triage pass asks. **Is this still open?** — it is, unless you
say otherwise: *Closed* is there for the fortnight Shepherd holds on to an issue after it closes,
so the one you finished on Tuesday is still somewhere, and the rail says how many rather than
leaving you to wonder. **Has anything been started on this?** — the facet reads whether a machine
already has a pull request open that would close the issue, so *Nothing started yet* is the pile
you are actually looking for. Then **labels**, **age** — bucketed by when the issue was *opened*, because an issue
somebody commented on this morning has not become a new issue — and **repository**. Each row
carries the provenance chip you already know from the review inbox, a small glyph when an agent is
on it, its labels, its comment count, and a *Closed* chip when that is what it is.

Open one and the panel shows the body rendered the way a pull-request description is, the labels,
the state with GitHub's own reason for it, and *Linked pull requests*: the pull requests GitHub says
would close this issue, each with its state and who wrote it. One keystroke opens the one you care
about — the review screen when it is a pull request you already have, its GitHub page when it is
somebody else's. That list costs no extra request: the sweep already saw it.

And you can act on one without leaving the panel. *Comment…* opens a small composer, *Label* offers
the labels Shepherd has already seen in that repository, *Assign to me* adds you without removing
anybody, and *Close* asks the one question GitHub asks: completed, or not planned. A closed issue
offers *Reopen* instead. Every one of those is queued locally first and sent in the background, the
same way an approval is — so it works in a tunnel — and every one of them is checked against the
issue before it goes out: if somebody relabelled, commented on or closed the issue between your
click and the send, Shepherd parks the write and tells you rather than overwriting what they did.
The panel says what is still waiting, what is parked, and what Shepherd gave up on — and so does
the pull-request panel, about the reviews and merges queued against the pull request you are
looking at.

And you can hand the issue to your own assistant without leaving it. *Assign to agent…* opens the
delegation sheet with the issue as the task — title, labels and the description, prefilled and
yours to edit — and Shepherd prepares a worktree on a branch it names after the issue, started
from your default branch, so the work has somewhere to land. Unlike a delegation on a pull
request, this run may finish the job and publish it, with the git and GitHub credentials your own
tool already has; Shepherd still publishes nothing by itself, and the button in the sheet is there
for a run whose environment cannot. The handover is queued as a comment on the issue, so a
colleague looking at it sees that somebody is on it, and if you have webhooks switched on your
automation hears `issue.assigned_to_agent` the moment the run really starts.

And it is drivable from outside like everything else: `shepherd issue schnaq/review#128` opens one,
`shepherd inbox issues` opens the section, and `shepherd://issue/…` does the same from a script or
a Raycast command ([ADR 0013](adr/0013-deep-links-and-cli.md)). An issue a colleague sends you that
is not in your inbox at all is fetched, once, and opened.

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

Your **issues** answer the same ⌘K, under their own heading, ranked the same way over their title,
labels and body. The two sets are merged by how well they match before the list is cut, so the rows
you get are the best of both rather than a fixed share each — and the arrows and ⏎ walk them as one
list, which is the only thing your fingers care about. Picking an issue moves the picker to *Issues*
and puts the cursor on it, even if a facet was hiding it.

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

You do not have to go and find that button. The first time the inbox has finished a sweep and is
showing a pull request an agent wrote, a notice above the list offers the same run in place, with
what it unlocks in one sentence and what it costs — the last ninety days, at most five hundred per
repository — in the next; it shows the same progress line the Settings card shows while it runs,
because it *is* the same run. It is offered once: *Not now* ends it, so does a run that came back,
and it is a note about this Mac rather than a preference, so it does not travel to your other ones.

The two thresholds travel to your other Macs; the history does not — it is rebuilt by a button
there, which is why the popover says *on this Mac*. *Clear history* empties it, and the lanes carry
on working, because they never read it.

### The fleet: every agent, and what became of its work

The badge on an inbox row answers *this agent, this repository*. **Fleet** — a row pinned at the
bottom of the rail, in both the pull-request and the issues sections — answers the wider one. It
lists every agent Shepherd has ever seen, each with how much of its work is open in your inbox
right now, how much of that is waiting on you, and what happened to the pull requests it closed in
the last ninety days: merged, closed without merging, reverted, how many repositories it works in,
when it last finished something.

Click an agent and you get its page. The counts across **every** repository first, then — always,
never folded away — the same counting one repository at a time, then the pull requests of its that
are open right now, each one a click from its review screen. A rate over four repositories can hide
a single bad one, which is why the average is never shown without the rows it was averaged from.

Underneath the aggregate, at most three sentences, stated without being asked and only when the
numbers below them say so:

> The last 4 pull requests this agent closed in `konduit/api` all had changes requested at least
> once.

> Its first push is green in 9 of 20 pull requests to `konduit/api`, and in 41 of 50 across the
> other 3 repositories Shepherd has counted.

> In `konduit/api`, 3 of its 24 merges were reverted; 0 of the other agent's 19 were.

Each names a repository, so you can check it against the grid right below it, and each comes with
the counts rather than only the percentage — no number on this page is one nothing else on it adds
up to. The thresholds are deliberately shy: three in a row before a streak is worth mentioning
(twice is a coincidence), five measured pull requests on each side and a thirty-point gap before
two rates are compared, ten merges and two reverts before one agent's revert share is set beside
another's. That last sentence is the only one that names two agents, it names exactly two, and it
renders identically on both of their pages.

**None of it is a grade.** There is no score, no rank, no position, no "top", no fleet-wide average
and no sortable column — the list comes back in one fixed order and there is nothing to re-sort it
by. The chip colours that tint an inbox row are not used here at all; an agent gets its own
identifying colour and its counts, and nothing that looks like a traffic light. And it is a ledger
of **agents**, never of people: an agent's pull requests are often pushed with your own token, and
there is nowhere on this screen — not in the data, not in the deep link, not in the button that
brought you here — for a person's login to appear.

Four ways in, all of them navigation: the rail row, ⌘K → *Show the agent fleet*, `shepherd fleet`
(or `shepherd fleet claude-code`) and the `shepherd://fleet` links behind it, and — the one you
will actually use — **See every repository** at the bottom of the track-record popover, which takes
you straight to that agent's page. On a human's badge that button is not there, because that page
does not exist.

The numbers come from the same ninety days of closed pull requests the badges are counted from, so
the two can never disagree, and they need the same one-time history load (Settings → Automation →
*Load track record*, or the offer the inbox makes you once). Until you have run it the fleet lists
your agents with their open counts and em-dashes on the closed side, and offers the load in place
with the same progress line. A repository with nothing counted in the window shows an em-dash
rather than 0 %, because "nothing was counted" and "none of it was green" are different things —
and a repository whose history outlived your inbox is marked *history only* rather than quietly
reading like a quiet week ([ADR 0035](adr/0035-the-fleet.md)).

### A morning digest, built on your Mac

Switch it on and once a day — nine o'clock by default, weekdays only if you like — Shepherd tells
you what came in since the last one: new review requests, issues somebody assigned to you, green
agent pull requests that only need an approval or a merge, issues an agent's pull request closed
for you overnight, your own pull requests with red CI or a change request, and reviews it could not
send. One notification that opens the inbox, plus the same summary as a dismissible card
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
The merge sheet's *Delete the branch afterwards* box is remembered the way the merge method is, and
the deletion rides along in the same queued write rather than in a second one: it happens only once
the merge has actually landed, it is skipped for a fork's branch and for a repository's default
branch, and a deletion that fails never turns a merge that worked into a merge you are told to try
again ([ADR 0005](adr/0005-api-strategy-graphql-search-rest-writes.md)). Nothing unattended ever
deletes a branch — neither bulk triage nor an automatic merge rule ticks that box.

An agent's pull request opens on **Conversation** rather than on the diff whenever its description
actually claims something — tests added, only one module touched, nothing breaking, fixes #142 —
so the first thing you see is those claims beside what Shepherd found, rather than a file list you
would have had to leave to reach them. Everything else opens on Files as it always did, the choice
is made once when the pull request opens and never afterwards, `t` switches between the two tabs,
and Settings → Appearance → Review screen turns the whole thing off if you would rather always
start in the diff.

The screen stays current while you are on it. Whatever the background sweep learns about the pull
request lands in the review you have open: CI turning green, a colleague answering a thread, an
approval, the mergeable state the merge dialog warns from. All of that is applied silently, exactly
where you are — the file you picked, the line your cursor is on and the text in the composer do not
move. A **new push** is the one thing that is not applied silently: it replaces the head commit
every comment in your pending review is anchored to, so the screen says *"Updated on GitHub — 2 new
commits"* in a strip above the diff and waits for you to press **Reload** (or `u`). And if the pull
request is merged or closed while you are reading it, the same strip says so and the approve,
request-changes and merge buttons go dark, rather than letting you queue a verdict that has nowhere
to land.

And an inline comment does not need the mouse. Press `c` and the keyboard moves into the diff;
press it again and the composer opens on the line the cursor is on. Inside the diff the arrow keys
walk the file, and `[` and `]` move between the original and the modified pane — which is how you
comment on a *deleted* line, since a deletion exists only on the original side. So picking a file,
reading it, commenting on any line of it and submitting are all keys
([ADR 0033](adr/0033-accessibility.md)). The bracket pair wants the side-by-side diff: turn inline
diffs on and there is a single pane carrying both sides, with no other side to cross to, so the
keys deliberately do nothing there. A line the diff does not actually contain, one of the
blank ones that pad the gaps between hunks, is refused exactly as it is for a click, because GitHub
refuses a comment on it and the review with it.

### A diff you can walk, line by line

Settings → Appearance → Diff renderer offers three choices: **Automatic**, **Rich viewer**, and
**Line list**. Rich viewer is Monaco, described above. Line list is a second, native rendering of
the same diff — hunk headers and lines in one column, each line its own row, walkable with `j`/`k`
and the arrow keys, and announced to VoiceOver one row at a time rather than as an undifferentiated
block of text. Automatic, the default, switches to the line list the moment VoiceOver starts
running and back to Monaco when it stops; Rich viewer and Line list pin one or the other regardless,
for a screen-reader user who prefers Monaco's shortcuts as much as for a sighted keyboard user who
simply likes the list better. Font size and line wrapping follow whichever is showing; the
side-by-side/inline switch has nothing to draw in a single column, so the list ignores it
([ADR 0034](adr/0034-native-diff-renderer.md)).

Commenting works the same way it does in Monaco — `j`/`k` to the line, `c` to open the composer —
but there is no pane to cross: a deleted line is simply a row in the list, so reaching it needs no
bracket at all. With a mouse, double-click a row to comment on it. A line that already carries a
conversation says so, and ⏎ opens it — or a click on the bubble. Where a line carries more than
one, ⏎ opens the first one still unresolved, and the rest stay reachable in the rich viewer. The
list does not attempt syntax highlighting, word-level diffs, side-by-side
layout, folding, or a minimap; those stay Monaco's, on purpose, so the two renderers stay in step
only on what a comment needs and differ freely on everything else. One gap, named rather than
hidden: a `file:line` link — from the "Why is CI red?" card, the claims card, or a "Since your
review" finding — opens the right file in the line list exactly as it does in the rich viewer, but
does not yet scroll to the line inside it.

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
the meantime is skipped with a note when you reach it. It finishes on the inbox with a small
summary — what you reviewed, what you skipped, what was merged or closed underneath you, and how
long it took — that Return or Escape closes. Nothing is persisted: a session is a sitting.

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
line in the diff (in the rich viewer — see "A diff you can walk" below for the line list). On a
German Mac the facts are German too, down to the plurals — the paths, the
issue numbers and the quoted lines of code are of course left exactly as they are. A ✗ line also
offers **Turn into a comment**, which drops the claim and the facts under it into your review
summary — in **English**, because that comment goes to GitHub, where the author reads it — and
asks first if you have already written something there. Nothing is submitted; nothing is even
sent.

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
card at all — and, for the same reason, does not move the pull request off the diff: an agent's
pull request opens on this card only when there is one.

Opening the card also lets Apple's on-device model read that same description once, for the
phrasings the patterns miss. A line it found carries a small **Read by the model** tag and is
checked against the diff and CI exactly like every other line — same glyph, same facts, same links,
still no score. The description never leaves the Mac, nothing is read on a card you have not
opened, and on a Mac without the model there is no tag, no caption and no error: the card is
complete without it.

### What this pull request closes

Above the description sits a short **Closes** section: one row per issue GitHub resolved out of the
description's `closes #123`, with the issue's number, its title and whether it is still open — and
a repository beside it when the reference points at another one, which `closes owner/repo#1` does.
One keystroke (⇧⌘I) or a click opens the issue. A pull request that closes nothing has no section
at all.

It is the same read as the rest of the screen and not a new one: the closing references arrive with
the pull request's own detail fetch, on the host Shepherd already talks to. The other direction is
the same link seen from the issue — an issue in the issues inbox lists the pull requests that will
close it, each with the CI dot and review decision Shepherd already has for it *from your inbox*.
Where a fix comes from somebody whose pull request has never been in your inbox, that row simply
carries no dot: Shepherd shows the state it has rather than fetching one pull request at a time
([ADR 0032](adr/0032-issues-inbox.md)).

### Since your review — only what changed in the fix round

The agent pushes a fix round, and the review screen opens on **Since your review** instead of on the
whole pull request again: only the files and hunks that differ from the head you actually reviewed,
in the same risk order the full list uses. The other segment, **All files**, is one click away and
is what a first review still opens on — the control only appears once there is a round to compare
against.

Under it, your findings from that round, each with what became of it: **Addressed** when the lines
your comment hangs on changed, **Unchanged** when neither the lines nor the thread moved, **Moved**
when the file was renamed or the lines around it shifted, **Replied** when somebody answered you.
Click one to jump to the file and line, the same reach the claims card's links have above.
"Addressed" says the lines changed and nothing more —
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

The claims card's evidence is German as well — "„Tests/UploadTests.swift“ entfernt eine
Assertion in Zeile 12: …" — while the text *Turn into a comment* hands your review summary stays
English, because that one is written to GitHub rather than to you.

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

### Merge when the checks pass

You have read the diff, it is good, and the sheet says *Checks are still running.* You can merge
past that warning, as before — or press **Merge when checks pass** (⇧⌘⏎) and walk away. Shepherd
remembers the commit you looked at, the merge method and the delete-branch answer as the sheet
showed them, and queues that merge on the first sweep that finds every check green on **that
commit**. A new push, a failing check, a conflict or a draft cancels it, with a notification saying
which. Unknown mergeability waits rather than cancels, because GitHub recomputes it in the
seconds after the last check ends — and so does a pull request the sweep momentarily cannot see;
one that stays gone for a week, because somebody else merged or closed it, is forgotten quietly.

The button is only there while checks are running: a red suite cannot go green without a re-run,
and a re-run brings the button back. The sheet shows the waiting state and offers *Stop waiting*;
the inbox detail panel says *Merges when the checks pass* next to the queue status. Arming counts
as finishing with the pull request — a focus session moves on, the review screen goes back to the
inbox. It fires while Shepherd is running, on the next sweep, through the same outbox row a click
produces. This is your decision on one commit, not a rule, so it asks for no approval and no agent
author, and it never travels to another Mac ([ADR 0037](adr/0037-merge-when-checks-pass.md)).

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
approved nothing until it lands. The toast says which of the two happened: *"Approved
schnaq/review#182."* only once the row really reached GitHub, *"Approval queued for …"* while it is
still on this Mac, and *"Review held back — … changed since you started"* when the pull request
moved on and the review was parked instead of sent. A merge says *"Merged …"* when it lands,
whenever the drain got to it. Settings → Sync is where the queue is accounted for: how many
writes are waiting, how many were parked because the pull request moved on, and — named one by one,
with the reason and a Retry or Discard button — the ones GitHub refused outright, which are the
only ones that will never leave the queue on their own. No server, no account other than your GitHub login, and telemetry that is anonymous and off in one click;
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
