# ADR 0028: Since my review — a local snapshot at submit time, the interdiff computed on the Mac

Status: Accepted (v1.2) · Date: 2026-09-03

## Context

Shepherd v1 reviews one pull request well, once. The maintainer interview behind
[`docs/plans/agent-fleet.md`](../plans/agent-fleet.md) named re-reading as one of the four costs of
a fleet of coding agents: the agent pushes a fix round, and the review screen opens on the whole
pull request again — every file, every hunk, including the twenty the agent did not touch — while
the only interesting question is *what changed since I last looked, and what became of what I
asked for*.

Four facts about the data decide the design.

**GitHub cannot be asked "what did this pull request look like when I reviewed it".** The compare
API can diff two commits, but the commit the review was written against is routinely gone: agent
branches are force-pushed, and a squash or a rebase replaces the history the review hung on. A
feature that needs the old side of the comparison has to have kept it.

**Shepherd already knows the exact moment.** Every write goes through the outbox (ADR 0006), and
the drain re-validates a review against the current head before submitting it (`basedOnHeadOid`).
The instant a `submitReview` mutation is acknowledged is the one instant in the system where "this
is the head I reviewed" is a fact rather than a guess.

**The diff is already local, patches included.** `changed_files` holds GitHub's unified patch per
file, and the app reconstructs both sides of it for the Monaco viewer (ADR 0003). So an interdiff
is a *text* problem over data already on disk, and no new host, endpoint or API call is involved.

**"Addressed" is a dangerous word.** Anchored lines changing is not the same as a finding being
fixed. Shepherd must not appear to have judged the fix, because it cannot.

## Decision

### The baseline is a local snapshot, written when the review is sent

Migration **v5** adds one table:

```sql
CREATE TABLE review_snapshots (
    prID TEXT NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
    reviewedHeadOid TEXT NOT NULL,
    reviewedAt DATETIME NOT NULL,
    filesJSON BLOB NOT NULL,
    PRIMARY KEY (prID, reviewedHeadOid)
)
```

`filesJSON` is the pull request's `changed_files` rows — path, previous path, status, additions,
deletions **and patch** — encoded as one blob. Not a snapshot-shaped copy of `changed_files`:
nothing queries inside a snapshot, the interdiff reads the whole value at once, and the point of
keeping it is precisely that the patches become unfetchable after a force-push. `ON DELETE CASCADE`
*is* the pruning, as in `search_index` (ADR 0019) and `triage_verdicts` (ADR 0023). The primary key
is `(prID, reviewedHeadOid)`, so a second review of the same head overwrites its own row and
`COUNT(*)` is the number of rounds the inbox row reports.

**The plan's shared `v5` is split.** `docs/plans/agent-fleet.md` sketched one migration for two
features ("outcomes, snapshots") so the schema would move once. A migration is an identifier in
`grdb_migrations`, so two features sharing one means neither can ship before the other. This
migration is **v5 — review snapshots**; the track-record tables of that plan's feature B become
**v6**. Nothing else about either feature changes.

### Written by the outbox drain, and retroactively by a detail fetch

The drain hook is one call in `SyncEngine.execute(_:)`, after `submitReview` succeeded and through
a port of its own (`ReviewSnapshotWriting`) so ShepherdSync keeps building and testing on Linux
against a fake. The head is the draft's own `basedOnHeadOid` — the commit the staleness check just
re-validated. A draft that carries none (a summary-only review queued before any detail fetch)
falls back to the head read at drain time; that leaves a small window in which a push between
writing the review and draining the outbox would label the *new* head as reviewed, which is why the
fallback is second and not first. A failure to write the baseline never fails the sent review: the
mutation has already reached GitHub, and the cost of losing the snapshot is that the tab is not
offered.

A review submitted on github.com, or by a Shepherd on another Mac, leaves a timeline event carrying
the commit it was submitted against (`TimelineEvent.commitOid`, additive and optional). When a
detail fetch sees such a review **by the viewer**, on a head the pull request is **still** on, and
no baseline for that head exists yet, the snapshot is written from the current files — the diff
Shepherd holds *is* the diff that was reviewed, so this is exact rather than a guess. The moment the
head moves, the chance is gone and nothing is written: that is the plan's "unavailable" case, and
the review screen then shows no segmented control at all rather than a tab built on a guess.

### The interdiff is pure, local and rendered through the existing viewer

`ShepherdCore/Review/Interdiff.swift` compares the two rounds' `ChangedFile` lists. Per path it
reconstructs the *head side* of each round's patch with `UnifiedPatch.reconstruct(after:)` — a
small pure reader in ShepherdCore; the app-target `PatchReconstructor` stays where it is, because
it also produces the viewer's commentable-line sets and is tested against the bridge — and diffs
the two documents line by line (common prefix and suffix by scanning, the middle by LCS, with a
cell cap beyond which the region is reported as one replacing hunk). Files identical across the
rounds are omitted; a rename is listed even when its content is unchanged.

**Line numbers are absolute on both sides.** Both reconstructions pad the gaps between hunks, the
way the app-side reconstructor does, so a 1-based line in either document is the line number GitHub
uses — which is what lets a review thread's anchor be looked up in the interdiff without a second
mapping. The consequence to know: a region neither round patched is padding on both sides, so it
compares equal; a region *one* round patched and the other did not compares content against
padding, and shows up as changed. That is honest — something did change there — but it is a diff of
two patches, not of two working trees.

Each `InterdiffFile` carries a **synthesized unified patch** in GitHub's own `files[].patch` shape.
The review screen hands the viewer a `ChangedFile` whose `patch` is that string, so "Since your
review" renders through the existing `loadFile` message with no new bridge protocol version and no
second rendering path. Because the synthesized diff's right-hand side shares the current head's
numbering, the gutter can still be armed there — but only on lines the pull request's *own* patch
also contains, because GitHub rejects an entire review when one `comments[].line` is not part of the
diff. The left-hand side is the head that was reviewed and offers no anchors at all.

### The four finding states are about lines and comments, never about correctness

`FindingState.classify(thread:interdiff:viewerLogin:)` maps one thread's anchor onto the interdiff:

| State | Rule |
|---|---|
| `addressed` | the anchored lines changed in the new round |
| `moved` | the file was renamed, or the lines above the anchor shifted |
| `replied` | somebody other than the viewer wrote in the thread after the viewer did |
| `unchanged` | none of the above |

The order is the rule: a rename and a changed anchor are facts about the code and outrank a reply;
a reply outranks "unchanged". A thread GitHub still maps onto the current diff is looked up by
`line` on the current side, an outdated one by `originalLine` on the reviewed side — never
backfilled from one another, because they are numbers in different documents (ADR 0006's rule for
`review_threads.originalLine`).

**`addressed` says "the lines changed" and nothing more.** The label, its tooltip and this ADR say
so; the thread stays open until the reviewer resolves it, and no automation reads these states.
The findings list is the reviewer's *own* unresolved threads from that round, so a reply of theirs
inside somebody else's thread is a conversation, not a finding.

### UI

A segmented control on the diff viewer — **All files** / **Since your review** — offered only when
a baseline exists *and* the head has moved past it, and defaulting to "Since your review" in
exactly that case; a first review looks precisely as it always has. The file list filters to the
interdiff's files, run through the same `FilePrioritizer` as the full list so the order the
reviewer knows is the order they get. Under the control, the findings list: state glyph, what they
wrote, and a jump to the file and line (a finding whose anchor is gone opens the conversation
instead, which is where a thread that lost its anchor belongs). The inbox row shows
"3 rounds · 2 findings unchanged" when there is a baseline — computed from the same local data, one
grouped query for the counts and a capped number of interdiffs per refresh, because the list has to
stay instant.

## Consequences

- **No new host, no new API call, no new outbox action.** The feature is a table, a pure diff and a
  segmented control; it works offline and survives a force-push, which the compare API would not.
- **The baseline is per Mac.** A review submitted from another machine only becomes a baseline
  through the retroactive path, and only while the head has not moved. "3 rounds" therefore means
  "three rounds *you reviewed on this Mac*", and the row's tooltip says so.
- **A snapshot costs disk.** One encoded copy of the pull request's patches per reviewed head,
  pruned by the cascade when the pull request leaves the inbox. That is the price of being able to
  answer the question at all.
- **The interdiff is a diff of two patches.** It cannot see the parts of the file GitHub never sent,
  and it therefore reports a hunk one round dropped as a change against padding. Documented above,
  visible in the viewer, and preferable to fetching two blobs per file per round.
- **"Addressed" remains a heuristic.** It is a reading aid for a reviewer walking a fix round; it
  never resolves a thread, never approves anything and is not readable by the auto-merge (ADR 0018)
  or auto-delegation (ADR 0016) rules.
