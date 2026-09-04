# ADR 0033: A list row says what it shows, and the gaps are written down rather than implied

Status: Accepted · Date: 2026-09-04

## Context

Accessibility appeared nowhere in this repository — not as a goal, not as a non-goal, not as a
known gap. That absence was itself a decision, made by never making it, and an audit of the app
before its first signed release turned it into three separate facts:

1. **Several components were already exemplary.** `CheckDotView`, `DiffCountsView`, `ProvenanceChip`,
   `TrackRecordBadge`, `TriageChip`, the ✨ buttons and the digest's dismiss button all carried
   correct labels, and every Settings surface is built from native controls that are labelled for
   free. Whoever wrote those knew what they were doing.
2. **Every list row threw that away.** Each of them called
   `.accessibilityElement(children: .combine)` — correct — and then
   `.accessibilityLabel(Text(shortString))`, which **replaces** the combined label instead of
   adding to it. So a row that drew the CI state, the author, the track record, the triage
   verdict, the draft flag, the round count, the status chip, the diff size and the age was
   announced as `owner/repo #12: title` and nothing else. Nine facts on screen, one spoken. The
   same pattern was in the inbox, the issues section, both ⌘K result rows and the menu-bar list.
3. **Two things the app exists for are unreachable.** The diff is a Monaco editor in a
   `WKWebView` with no ARIA structure and no native fallback, and leaving an inline comment is
   wired exclusively to the mouse — in an app whose keyboard vocabulary is otherwise deliberate
   and thorough.

## Decision

**A row's spoken label says what the row shows.** Not a summary of it: the same facts, in the
same order, taken from the same values the view draws, assembled by `SpokenRow.sentence(_:)` so
that five lists cannot punctuate them five ways. Where a component already computes the sentence
for its own tooltip — "All checks passed", "Detected as Example Agent (matched by login)" — the
row asks that component for it (`CheckDotView.spokenState(_:)`, `ProvenanceChip.spokenProvenance(of:)`,
`TriageChip.spokenTitle(for:)`, `TrackRecordBadge.sentence(authorName:record:)`) rather than
writing a second phrase that means the same thing. Two definitions of one fact would drift, and
the spoken one would be the one nobody notices drifting.

**Colour is never the only carrier.** A tinted dot or chip must have a word beside it, in the row
or in the label. The one place that failed this — the review-priority card, whose bucket was a
coloured dot with no name anywhere on the row, unlike the review screen's file list which prints
`REVIEW FIRST · 3` as a header — now names the bucket in both its tooltip and its label.

**A sheet's primary action is the default one.** Every sheet in the app already made Return
submit; the delegation sheet was the exception, so a keyboard-only reviewer had to tab-hunt for
*Start*. Return inside the task editor still inserts a line, because a `TextEditor` consumes it
first.

**The gaps are written down.** [`docs/plans/accessibility.md`](../plans/accessibility.md) holds
the three that are projects rather than fixes — the diff viewer, the keyboard path to an inline
comment, and Dynamic Type — with what each would take. An honest gap in a plan is worth more than
a silent one in a codebase, and this ADR is deliberately not claiming the app is accessible: it
claims that the lists now say what they show, and that what remains is named.

## Consequences

- `SpokenRow` is one pure function with tests, so the label assembly is asserted rather than
  listened to. The components' spoken forms are `static` and internal for the same reason.
- The rule for anyone adding a list row: after `.accessibilityElement(children: .combine)`, either
  leave the automatic label alone or build the replacement from every fact the row draws.
  CONTRIBUTING.md states it where the localisation rule is stated, because it is the same kind of
  rule — something that is easy to forget and invisible when forgotten.
- `Font.system(size:)` is still used everywhere, so the OS's Larger Text setting still does
  nothing in this app. That is the largest remaining gap and it is not fixed here; the plan says
  what fixing it means.
- No behaviour changes for a user who is not using a screen reader, except that Return now starts
  a delegation from the sheet that offers one.

## Amendment (2026-09-04): the keyboard reaches a line

The gap this ADR named first among the projects is closed. Leaving a comment on a line was the one
review action with no key at all: approve, request changes, submit, merge and walking the files are
all keys, and the gutter's "+" was wired to `onMouseMove`/`onMouseDown` and nothing else.

`c` does it, which is the letter GitHub's own diff uses, and there are **two halves** because the
keyboard has a boundary the mouse does not. Inside the editor Monaco takes the key and comments on
the cursor's line. Outside it — in the file list, the header, anywhere the native screen has
focus — the same key hands the focus over, and the second press comments. One key, two steps, and
the arrow keys move between them.

Three decisions inside that are worth keeping:

**The line rules have one definition.** A comment may only be left on a line that is in range and
is genuinely part of the diff rather than one of the blank lines the reconstruction pads the gaps
between hunks with — GitHub refuses a comment on one of those, and refuses the whole review with
it. That guard lived in `gutterHit`, mixed together with the mouse's own question of whether the
pointer was over the gutter at all. It is now `cursorHit`, which asks only about the line, and
`gutterHit` is that plus the pointer question. The keyboard cannot become the way around a guard
the mouse respects.

**`onKeyDown`, not `addAction`.** The obvious API is the one that does not exist here:
`addAction` and `addCommand` belong to `IStandaloneCodeEditor`, and a diff editor's two panes are
plain `ICodeEditor`s. The key is swallowed only once a commentable line has been found, so an
unhandled `c` keeps travelling and a key the native screen owns still reaches it.

**`focusEditor` is a command with no payload.** The bridge gained one inbound message whose type
is the whole message, with fixtures on both sides like every other. It is sent off a *request
token* rather than a value the view compares, because handing over focus is an event: asking twice
has to send twice. Its invalid fixture is a version mismatch, which is the only way a message with
no payload can be wrong — the same shape `ready.invalid.json` has on the way out, and the fixture
test now names both rather than one.
