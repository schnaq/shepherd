# The three accessibility gaps that are projects, not fixes

Written 2026-09-04, after the audit behind [ADR 0033](../adr/0033-accessibility.md). That ADR
records what was fixed the same day: the list rows now say what they show, colour is no longer the
only carrier anywhere, and a few labels and one keyboard default were filled in. What is left does
not fit in a label, and this is what each of the three would actually take.

Ordered by what a person hits first, which is not the order of effort.

## 1. The diff is silent (the big one) — **cheap half done, 2026-09-04**

**What is true today.** The diff pane is `monaco.editor.createDiffEditor` in a `WKWebView`
(ADR 0003), `readOnly: true`, with Monaco's `accessibilitySupport` left at `'auto'`. Monaco's
screen-reader support is real but is tested against Chrome and NVDA far more than against WebKit
and VoiceOver, and the bundle adds exactly one `aria-*` attribute of its own. There is **no
alternative path on the Swift side**: no plain-text rendering of the patch, no "copy the diff"
action, nothing but `DiffUnavailableView`, which is an error state for a pull request GitHub sent
no patch for. So the screen the app exists for is, for a VoiceOver user, somewhere between
partially readable and silent.

**Two ways to fix it, and they are not equivalent.**

*Set `accessibilitySupport: 'on'` and add ARIA to the bundle.* Cheap to try, and it is worth
trying first because it might be most of the answer. It also cannot be verified from this
repository: it needs a Mac, VoiceOver, and somebody listening. The risk is spending the effort and
finding WebKit's accessibility tree does not carry what Monaco puts in it.

*Render the patch natively as a second, accessible view of the same diff.* Shepherd already has
everything this needs and does not know it: `PatchReconstructor` turns a GitHub patch into hunks
and lines, the review screen already owns file selection, and `ReviewModel` already holds the
threads. A `List` of hunks and lines — each line one element, announced as "added, line 42,
`let x = 1`" with its thread count — is ordinary SwiftUI, is testable on Linux for its text, and
would also give the app a keyboard-navigable diff, which is worth having on its own. The price is
a second renderer to keep in step with the first, which is exactly the cost ADR 0003 was written
to avoid.

**Recommendation:** try the first, plan for the second, and treat the native list as the real
answer rather than the fallback — a diff a person can walk with the arrow keys is a better product
for everybody, not an accommodation.

**What was built** (the first, in full). The paragraph above was wrong about one thing worth
correcting: `accessibilitySupport: 'auto'` is not a setting somebody forgot to change, it is a
*detection* — and one that cannot work here, because it is a browser's detection and nothing
inside a `WKWebView` can see VoiceOver reading the window around it. So the option was almost
certainly never turning on, which makes "cheap to try" cheaper than it looked: the app already
knows the answer.

It now says so. SwiftUI's `accessibilityVoiceOverEnabled` goes across the bridge as
`setAccessibility {screenReader}`, which turns `accessibilitySupport` on and raises
`accessibilityPageSize` from 10 lines to 100 while a screen reader is listening — and restates
both when it stops, so the cost is paid only by the person who needs it. And each pane now says
*which* pane it is, through an optional additive `paneLabels` on `loadFile`, filled in natively
because the app is localised and the bundle is not. Monaco's own label is the same sentence on
both sides, which is the one fact a person needs the moment `c` hands them a cursor.

**What is still open, and it is the important half.** None of this can be verified from a Linux
container: whether WebKit's accessibility tree carries what Monaco puts in it needs a Mac,
VoiceOver, and somebody listening. Until somebody has listened, the honest description of the diff
is "possibly readable" rather than "readable". The native rendering above is still the real answer
and is still worth building for its own sake — it now has a plan of its own,
[accessible-diff.md](accessible-diff.md), which works out what has to stay in step between two
renderers and what is free to differ, because that boundary is the whole cost. One thing it turned
up that belongs here: `PatchReconstructor`, the app's fiddliest piece of pure logic, sits in the app
target and so is not exercised on the Linux CI leg at all.

## 2. An inline comment needs a mouse — **done, 2026-09-04**

**What was true until then.** The "+" affordance in the gutter is wired to `editor.onMouseMove` and
`onMouseDown` in `web/diff-viewer/src/viewer/gutter.ts`; nothing in `monacoViewer.ts` registers a
keybinding or a Monaco action, and `ReviewModel`'s `.addComment` case is only ever fed by that
bridge event. `ReviewScreen`'s keyboard handler has `v` for *mark viewed* and no way to open the
inline composer on the line the cursor is on. Every other review action — approve, request
changes, submit, merge, walk the files — is keyboard-driven, which makes this the one hole in an
otherwise deliberate keyboard story.

**What it looked like it would take** (kept as written, because one line of it turned out to be
wrong — see below). Monaco already knows where the cursor is, so this is a bridge addition rather
than a redesign: a Monaco action registered with `editor.addAction` and a keybinding, which emits
the same `addComment` event the mouse path emits, for the cursor's line instead of the hovered
one. Then one entry in `ReviewScreen`'s key handler for the case where focus is in the app rather
than in the web view. Both halves are small; the fixture corpus in `web/diff-viewer/fixtures/`
already covers the event shape, so the contract does not move.

**One decision to make:** which key. `c` is free in the review screen's vocabulary and is what
GitHub's own keyboard shortcuts use for a comment.

**What was built.** `c` it is, and there are two halves because the keyboard has a boundary the
mouse does not. Inside the editor Monaco takes the key and comments on the cursor's line, through
`cursorHit` — the same line rules the pointer's path uses, extracted so the two cannot disagree
about which lines may carry a comment. Outside it, the same key hands the focus over, through a
new payload-less `focusEditor` command on the bridge (with fixtures on both sides, as every
message has). So: `c` to get a cursor, `c` to comment on it, arrows to move between.

`onKeyDown` rather than `addAction`, because `addAction` and `addCommand` belong to
`IStandaloneCodeEditor` and a diff editor's two panes are plain `ICodeEditor`s — worth writing
down, since the obvious API is the one that does not exist here. The key is only swallowed once a
commentable line has been found, so an unhandled `c` still reaches the native screen.

**What it left open, and then closed: a deleted line.** `c` works in *either* pane — the original
pane's handler posts `side: "left"`, and there is a test for it — but `focusEditor` always landed
in the modified pane, which is the one a reviewer is reading. So a comment on a deletion was still
mouse-only, because nothing crossed from one pane to the other without a pointer.

`[` is the original pane now and `]` the modified one, on both sides of the boundary: Monaco takes
them inside the editor, and on the native screen they raise the same focus request `c` raises,
through a new optional `side` on `focusEditor`. Brackets and not a letter, because every free
letter had the same defect — it must be free as a bare key *and* as the second half of `r …` and
`g …`, and the editor cannot see that a prefix is armed on the native side, so it would swallow
the second key of `g s` exactly as `c` first swallowed the second key of `r c`. `[` and `]` are in
no sequence, so the collision cannot arise. Crossing puts the cursor on the target pane's first
visible line unless it is already on screen, because the panes scroll together and an untouched
pane's cursor is on line 1. Inline mode has one pane carrying both sides, so there the key travels
on. Recorded in ADR 0033's third amendment.

## 3. Larger Text does nothing — **the mechanism is in, the migration is a third open**

**What is true today.** 419 call sites use `Font.system(size:)` — a fixed point size — against two
semantic text styles in the whole app. `Font.system(size:)` does not participate in macOS's
Larger Text setting, so a low-vision user's system preference has **no effect anywhere in
Shepherd**. That is worse than clipping: the standard remedy silently does nothing. Screen Zoom
still works, because that is OS compositing rather than app text metrics.

**Why it was not fixed with the rest.** It is not a bug to patch but a design decision to revisit.
The app's density is deliberate — 46-point rows carrying nine facts, 28-point rail rows, a 52-point
review header — and semantic text styles would make those rows grow. The surfaces that would break
first are exactly the ones that pack a fixed height around `lineLimit(1)`: the two list rows, the
rail, and the review header and composer bars. Making them grow means letting the row height
follow the text, which changes how the lists look for everybody.

**The honest options.**

*Adopt `.font(.body)` and friends throughout, and let the rows breathe.* The right answer for a
Mac app, and a real visual redesign of the dense surfaces.

*Adopt them only where the layout can already take it* — panels, cards, sheets, Settings, the
digest — and leave the fixed-height lists alone, documented. Partial, honest, and much cheaper.

*Offer a Shepherd-level text-size setting* that scales its own type scale, independent of the OS.
Tempting because it is easy, and wrong: it is a second control for something the OS already has a
control for, and a user who has already set Larger Text should not have to find ours.

**Recommendation:** the second, with `Theme` growing a type scale that reads the current size
category so the choice is made in one place rather than at 419 call sites, and the first as the
direction of travel.

**What was built, 2026-09-04.** The recommendation above was right about the shape and wrong about
the mechanism, in a way worth writing down: a type scale does *not* need to read the size category,
because `Theme` is a case-less namespace of statics with no environment to read one from. macOS's
text styles already scale themselves. So `Theme.type(_:weight:)` and a monospaced sibling name a
`Font.TextStyle` instead of a point size, and that is the whole mechanism — no `@ScaledMetric`, no
environment plumbing, nothing threaded through several hundred call sites.

The migration is the part that is a third done, and the stopping point is not effort. The mapping
is the *identity at the default size* — on macOS `.body` is 13pt, `.callout` 12, `.subheadline` 11,
`.footnote` 10, `.title3` 15, `.title` 22 — so a surface whose sizes are all on that list moves
without changing a pixel until somebody turns the setting up. **64 call sites across six surfaces**
were on it exactly and have moved: the automation and replies settings tabs, the merge, bulk-triage
and issue-comment sheets, and the closing-issues card. `Scripts/check-type-scale.py` lists them and
fails CI on a fixed size reappearing in one, because a boundary nobody checks erodes.

**Why the rest stopped, and what the decision is.** The remaining surfaces are not on that list.
They are built on half points and on 8 and 9 — `ClaimsEvidenceCard` alone uses 8, 9, 10.5 and 11.5
— and macOS has no text style at any of those. Rounding them onto the scale is not a migration but
a *redesign*: 8, 9 and 10.5 all round to the same 10pt style, so four deliberate sizes in one card
collapse into two and the card's hierarchy flattens. Migrating only the exact sizes in such a file
is worse still — the 11pt heading would grow while the 10.5pt body under it stayed put.

So the open question is a visual one and needs a display: **may the dense surfaces move onto the OS
scale, accepting up to a point of movement and a flatter hierarchy where two of their sizes meet?**
The alternative is to keep them fixed and leave Larger Text working in Settings, the sheets and the
panels but not in the cards and the lists, which is defensible and is where the app stands now.

**And one thing this cannot verify.** Whether macOS's Text Size setting reaches SwiftUI's text
styles at all is not knowable from a Linux container. It is the only mechanism there is, so the
migration is the precondition either way — but the six surfaces above are now the cheap way to
*check*: turn Larger Text up on a Mac, open Settings → Automation, and either the labels grow or
the answer is no. Same afternoon as the VoiceOver and contrast checks below.

## What is deliberately not on this list

Colour contrast. The palette was not audited against WCAG ratios, because the app has a dark and a
light theme, `Theme` resolves every colour per appearance, and checking that properly means
measuring rendered pairs on a real display rather than reading hex values. It belongs in the same
session as the VoiceOver verification above: one Mac, one afternoon, both.

## What to check on a Mac, in one place

Four things in this plan and in [accessible-diff.md](accessible-diff.md) cannot be settled from a
Linux container, and they were scattered across three documents. They are one afternoon, in this
order, because each one's answer changes what the next is worth.

**1. Does macOS's text-size setting reach SwiftUI at all?** (§3, 15 minutes, do it first.) System
Settings → Appearance → Text Size, turn it up. Open Shepherd → Settings → Automation. Those labels
go through `Theme.type(_:weight:)`, which names a text style rather than a point size.

- *They grow* → the mechanism works, and the open question is only how far the migration should go
  (the decision at the end of §3).
- *They do not* → `Font.system(_ style:)` does not participate on macOS either, the migration is
  worth nothing as it stands, and the answer is `@ScaledMetric` per view or a Shepherd-level
  setting after all. Say so and the six migrated surfaces get reverted rather than extended.

Same trip, second window: the Merge sheet, the bulk-triage sheet and the closing-issues card are
the other migrated surfaces. Everything else is still fixed by design, so a screen where nothing
grows is not necessarily a bug — check it against the list in `Scripts/check-type-scale.py`.

**2. Does VoiceOver read the diff?** (§1, the one this whole plan turns on.) ⌘F5, open any pull
request, pick a file. The app now tells Monaco a screen reader is listening, and each pane says
which pane it is.

- Does VO announce entering the editor, and does it say *which side* — "Original, ReviewModel.swift"
  or "Geändert, ReviewModel.swift"?
- Do the arrow keys move it line by line, and does it read the line?
- Does `c` open the composer on the line VO is on? Does `[` cross to the original pane and read
  from there?

*It reads* → the cheap half was most of the answer and the native list becomes a nice-to-have.
*It does not, or only in fragments* → that is the answer the native list exists for, and
[accessible-diff.md](accessible-diff.md) is what it would take. Either way this is the fact
nothing in the repository can supply.

**3. Contrast.** Deliberately not audited from here, because two themes resolved per appearance
means measuring rendered pairs rather than reading hex values. Digital Color Meter on the pairs
that carry meaning: the triage chips, the CI dots, the priority dots, muted text on card
backgrounds — in both appearances. WCAG AA is 4.5:1 for text, 3:1 for a graphical object that
carries information. Colour is nowhere the only carrier any more (ADR 0033), so a failure here is
a legibility bug rather than a comprehension one.

**4. How the announcements actually sound.** Only once (2) says something is being read. A sentence
that reads well in a document can be exhausting at forty lines a minute — that is a judgement about
wording, and wording is cheap to change once somebody has listened.

What to bring back: for (1) a yes or no, for (2) roughly where it breaks down, for (3) the pairs
that fail. Nothing needs to be measured precisely; every one of these is a decision about what to
build next, not a metric.
