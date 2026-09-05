# ADR 0034: A native diff renderer beside Monaco, held to a three-point contract

Status: Accepted · Date: 2026-09-05

## Context

ADR 0033's audit found the diff pane silent for a VoiceOver user in the worst case: Monaco's own
screen-reader support is real but tested against Chrome and NVDA far more than WebKit and
VoiceOver, and there was no alternative path on the Swift side at all — no plain-text rendering,
no "copy the diff" action, nothing. Two of that ADR's amendments closed the cheap half: the app now
tells Monaco a screen reader is listening (`setAccessibility`), and each pane says which one it is.
Neither can be verified from a Linux container, and both amendments say so.

[`docs/plans/accessible-diff.md`](../plans/accessible-diff.md) worked out the expensive half — a
second, native rendering of the same diff — and said explicitly why it was a plan and not an ADR:

> It is written as a plan and not as an ADR on purpose: ADR 0003 decided the *opposite* thing on
> good grounds, and a second renderer is a decision to make with eyes open, not a detail to slip
> in. The ADR gets written when it is built.

It is built. This ADR records the decision the plan worked out and the shape it shipped in.

**This is not ADR 0003 reconsidered.** ADR 0003 chose Monaco in a `WKWebView` because there is no
Monaco-equivalent Swift library and GitHub-quality side-by-side diffs with syntax highlighting and
comment gutters are weeks of custom work — reasoning that has not aged. Its last consequence bullet
left a door open for a **native rewrite** "behind the same view-model boundary," one renderer
replacing another. What shipped here is not that. It is a **second** renderer beside the first, and
that is the harder thing, because two renderers can disagree about a fact — which lines take a
comment, what a comment means — in a way one renderer never can. Pretending the two are the same
kind of change would be the mistake; the rest of this ADR is the boundary that keeps them from
becoming one.

## Decision

### Three things must agree; everything else is free to differ

This is the whole of what bounds the cost, and it is enforced as call sites rather than as an
intention documented once and trusted to hold:

1. **Which lines may carry a comment.** `ReviewModel.commentableLineSets(in:)` is the one function
   that answers this, and it carries the "since my review" narrowing from ADR 0028: in that round
   the base side offers no anchors at all, and the head side is narrowed to lines the pull
   request's *own* patch also contains. Both renderers read it — the Monaco bridge through its
   sorted-array spelling (`commentableLines(in:)`, for the JSON payload), the native list through
   the sets directly (`DiffListContent.commentableLeft`/`commentableRight`) — and neither computes
   its own answer. A padding line the reconstruction inserted between hunks is exactly as
   unclickable in the list as it is in Monaco, because GitHub refuses a comment on a line outside
   the diff **along with the whole review**, not just the one comment.
2. **What a comment means.** The list raises a comment through `ReviewModel.handle(_:)`'s
   `.addComment(line:side:)` case, `requestCommentOnSelectedRow()`'s only job — the same entry
   point the bridge event lands on when the mouse or Monaco's own keyboard path fires it. The list
   does not grow a second composer, a second draft model, or a second idea of what "add a comment"
   does.
3. **Which round is showing.** The list reads `roundView`; it does not decide it. A file selected
   under "Since your review" draws the narrowed round in both renderers, because both read the same
   model property rather than each tracking their own idea of which diff is on screen.

Explicitly and permanently free to differ: syntax highlighting, word-level intra-line diffs, the
side-by-side layout, folding, the minimap. **Feature parity is not the goal.** The native list is a
different product — a linear, walkable, announced sequence of lines — and it earns its place by
being better at the one thing Monaco is worst at, not by catching up to everything Monaco already
does. Pretending otherwise, and trying to make the list match Monaco feature-for-feature, is
exactly what would turn a second renderer into the maintenance cost ADR 0003 was written to avoid:
every one of those features would need its own agreement between two implementations, and most of
them have nothing to do with why the list exists.

### Three states, because `automatic` is a runtime condition and not a fixed choice

`DiffRenderer` is `automatic` / `web` / `native`, not a boolean. `automatic` means "the native list
while VoiceOver is running, Monaco otherwise" — a rule evaluated live against
`accessibilityVoiceOverEnabled`, which changes while the review screen is open. A boolean can say
"use the list" or "don't"; it cannot say "decide this every time VoiceOver's state changes," because
that is a condition, not a value. And a boolean forecloses the case that matters more: a
screen-reader user who *prefers* Monaco — because they already know its shortcuts, or because the
list is still catching up on wording — has to be able to say so and have it stick. Two rules
(`automatic-only` versus `always-native`) would make the automatic behaviour a lock on that user's
choice; the third state makes it a default instead. In a setting that exists for accessibility, the
difference between a default and a lock is not cosmetic — it is the difference between offering
something and imposing it.

### The anchor rule, and why it is structural rather than a precaution

A row's spoken line number and the line a comment on it would be anchored to are read off one
switch, `DiffListContent.lineIdentity(of:)`: an added or context row is a head-side line, a removed
row a base-side line, and the *other* side's number on that row is never consulted. This is not a
belt-and-suspenders check added out of caution. `PatchRow` fills an added row's `baseLine` with the
base-side line the addition sits in front of — a real number, just one that names a different line,
often inter-hunk padding rather than diff content — and if anything ever asked that number whether
it may carry a comment, the answer would depend on what happens to be at that coordinate rather than
on what the row actually is. Consulting only the row's own side makes the wrong number
**unreachable** rather than merely unlikely to be reached. The cost of getting this wrong is not a
cosmetic glitch: GitHub rejects an entire review — the summary and every other valid comment in it
— when a single `comments[].line` is not part of the diff. An anchor bug here does not lose one
comment; it loses the whole review a reviewer is trying to submit.

### Two asymmetries a later reader will be tempted to "fix"

**`j`/`k` land on hunk headers; they do not skip them.** Skipping would save a keystroke for a
reviewer who can see, at a glance, where one hunk ends and the next begins. Landing on the header is
the only way a reviewer who cannot see that is ever told the file just jumped from line 41 to line
214 — and Monaco tells a screen-reader user that nowhere at all, because its gap between hunks is
just visual whitespace with no announcement of its own. This list exists for the reader who needs
that told to them, so the extra keystroke per hunk is the cheaper of the two costs, not an oversight
to streamline later.

**Context rows do not announce their kind.** `DiffRowText.spokenSentence` says "Added" or "Removed"
for those rows and says nothing for a context row. Saying "Context. Line 41." two hundred times on
an ordinary file is what makes a screen reader exhausting to use; unchanged is the default state of
a line, and only added and removed carry information worth spending a word on. A later change that
"completes" the announcement by adding a kind word to every row would make the list worse, not more
consistent.

## Consequences

- **A second renderer to keep in step with the first — bounded by the contract above, and no
  wider.** Everything the contract does not name is free to diverge, and it already has: the list
  has no syntax highlighting, no word-level diff, no minimap, and does not attempt side-by-side
  layout. If the contract's boundary is ever widened past these three things, this becomes the
  maintenance cost ADR 0003 was written to avoid; holding it is now this ADR's job, not the
  plan's.
- **`revealLine` reaches only Monaco.** The CI diagnosis card's `file:line` link
  (`ReviewModel.reveal(path:line:)`, ADR 0024) opens the right file in either renderer, but scrolls
  to the named line only in the Monaco branch — the native list has no line-to-row map and no
  consume rule for a value nothing currently clears. This is a named gap, not a hidden one: in
  native mode the reviewer lands on the file and has to find the line themselves.
- **The reconstruction is parsed more often.** The native list asks `PatchReconstructor.reconstruct`
  for the file's rows on every keystroke that moves the cursor, where Monaco's document is built
  once per file selection. Caching it would change how `ReviewModel` holds state and is left alone
  for now.
- **A localisation surface of the same order as `EvidenceFactText`.** Every spoken sentence — the
  hunk header, "Added"/"Removed", the line-number phrasing, the thread and draft counts, the "no
  comment can be left here" line — is a catalog key with a German row, checked by
  `Scripts/check-localization.py`, which also gained two new interpolated-`Int` entries
  (`originalStart`, `modifiedStart`) for the hunk header.
- **One setting, with the sync obligation CONTRIBUTING.md states.** `DiffRenderer` travels through
  `SyncedSettingsDocument` and both directions of `SettingsSyncApplier`, exercised by
  `SettingsSyncTests` with the field non-default, so the choice follows a reviewer to their other
  Macs rather than resetting to `automatic` on each one.
- **No behaviour change for a reviewer who never touches the setting and never runs VoiceOver.**
  `automatic` resolves to Monaco exactly as before until a screen reader is actually running.

## What this does not settle

Whether the list's announcements are any *good* read aloud. A sentence that reads correctly on the
page can still be exhausting at forty lines a minute, and that is not a fact this repository can
supply — it needs a Mac, VoiceOver, and somebody listening. That is check 2 of the four in
[`docs/plans/accessibility.md`](../plans/accessibility.md) § "What to check on a Mac", and it now
decides something sharper than it used to: not whether the native list is worth building — it is
built — but how much of its wording has to change before it is worth using.
