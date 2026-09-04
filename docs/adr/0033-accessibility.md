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

## Amendment (2026-09-04): the app tells the diff a screen reader is listening

The second gap the plan named — that the diff is silent — has a cheap half and an expensive one,
and this is the cheap half in full. It is not the whole answer and is deliberately not claimed as
one.

Monaco does have screen-reader support, gated behind `accessibilitySupport`, whose default is
`'auto'`: **detect a screen reader and turn on if there is one.** In a browser that is reasonable.
In a `WKWebView` it is a guess made with the wrong information — the detection is a browser's, and
nothing inside the web view can see that VoiceOver is reading the window around it. So the option
that exists to make the diff readable was, in this app, almost certainly never turning on.

macOS knows. SwiftUI publishes it as `accessibilityVoiceOverEnabled`, and the review screen now
passes it across the bridge as `setAccessibility {screenReader}`, which sets
`accessibilitySupport` to `'on'` or back to `'auto'` and raises `accessibilityPageSize` from
Monaco's default of 10 lines to 100. The page size is the reason this is a flag rather than a
constant: a hundred lines held in the DOM costs something, and only the reviewer who needs them
should pay it. Turning it off restates both options rather than leaving them raised, because an
option that is only ever raised stays raised for the rest of the session.

The panes also say which pane they are. Monaco's default aria label is one sentence about editor
content, identical on both sides of a side-by-side diff, which is precisely the fact a person
needs at the moment `c` has just handed them a cursor. `loadFile` gained an optional additive
`paneLabels {left, right}`, filled in natively — the app is localised and this bundle is not, so a
German build must not announce its diff in English. The label carries the file's *name*, not its
path: VoiceOver reads the whole thing every time the cursor enters a pane, and the path is already
on screen in the header.

**What this does not settle.** Whether WebKit's accessibility tree actually carries what Monaco
puts into it is not knowable from this repository — it needs a Mac, VoiceOver, and somebody
listening. Both changes are the kind that can be verified only that way, which is why the plan
keeps recommending the native, keyboard-walkable rendering of the patch as the real answer rather
than the fallback: a diff a person can walk with the arrow keys is a better product for everybody.
This amendment buys the possibility that the cheap half is most of the answer, at the price of two
messages on a bridge that already had five.

## Amendment (2026-09-04): `[` and `]` reach a deleted line

The keyboard path to an inline comment left one line out of reach, and the test that proved `c`
works in the original pane is the same test that showed why: `c` comments wherever the cursor is,
but nothing put the cursor in the original pane. `focusEditor` always landed in the modified one —
the pane a reviewer reads — and a *deleted* line exists nowhere else. So the one thing left needing
a mouse was a comment on a deletion, which is a large share of what review comments are about.

`[` is the original pane and `]` the modified one, where they sit on the keyboard and on the
screen. They work on both sides of the boundary, which is the point: inside the editor Monaco takes
them, and on the native screen they raise the same focus request `c` raises, so a reviewer coming
from the file list does not have to land in the wrong pane first and cross over. `focusEditor`
gained an optional additive `side` for that — absent still means the modified pane, so the message
means today what it meant yesterday.

**Brackets rather than a letter, and that is the decision here.** Every free letter had the same
defect: a letter must be free as a bare key in the review screen *and* as the second half of
`r …` and `g …`, because the editor needs the same key and cannot see that a prefix is armed on
the native side. It would swallow the second key of `g s` exactly as the first version of `c`
swallowed the second key of `r c`. `[` and `]` are in no sequence at all, so the collision cannot
arise; on the native side they still defer to an armed prefix, which rejects them and disarms.

Two smaller decisions came with it. Crossing panes puts the cursor on the target pane's first
visible line, but only if the cursor is not already on screen: the panes scroll together, so an
untouched pane's cursor sits on line 1 while the reviewer reads line 400, and the first arrow key
would drag the whole diff back to the top — while a reviewer crossing *back* should find the line
they left. And in inline mode there is no second pane to cross to, so the key is left alone and
travels on rather than being swallowed for nothing.

**What this does not settle.** The same thing the amendments above do not settle: whether VoiceOver
actually reads any of it. This closes a keyboard gap, which is a different gap from the one that
needs a Mac and somebody listening.
