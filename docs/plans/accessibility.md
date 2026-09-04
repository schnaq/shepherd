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
is "possibly readable" rather than "readable". The native rendering below is still the real answer
and is still worth building for its own sake.

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

## 3. Larger Text does nothing

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

## What is deliberately not on this list

Colour contrast. The palette was not audited against WCAG ratios, because the app has a dark and a
light theme, `Theme` resolves every colour per appearance, and checking that properly means
measuring rendered pairs on a real display rather than reading hex values. It belongs in the same
session as the VoiceOver verification above: one Mac, one afternoon, both.
