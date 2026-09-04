# A diff you can walk: a native rendering beside the web one

Written 2026-09-04, after the three accessibility projects in
[accessibility.md](accessibility.md) were worked. §1 of that plan closed the cheap half of "the
diff is silent" — the app now tells Monaco a screen reader is listening, and each pane says which
pane it is — and it says twice that the expensive half is the real answer rather than the fallback:

> a diff a person can walk with the arrow keys is a better product for everybody, not an
> accommodation.

This is what that would take. It is written as a plan and not as an ADR on purpose: ADR 0003
decided the *opposite* thing on good grounds, and a second renderer is a decision to make with eyes
open, not a detail to slip in. The ADR gets written when it is built.

## What ADR 0003 actually decided, and what this is not

ADR 0003 chose Monaco in a `WKWebView` because there is no Monaco-equivalent Swift library and
GitHub-quality side-by-side diffs with syntax highlighting and comment gutters are weeks of custom
work. That reasoning has not aged a day. Its last consequence bullet leaves a door open:

> Native rewrite of the diff view remains possible later behind the same view-model boundary — the
> bridge isolates Monaco from the rest of the app.

A **rewrite** — one renderer replacing another. What this plan proposes is a **second** renderer
beside the first, and that is the harder thing, because two renderers can disagree. So the design
question is not "can SwiftUI draw a diff" (it plainly can) but **what exactly has to stay in step,
and what is free to differ.** Getting that boundary wrong is how this becomes the maintenance cost
ADR 0003 was written to avoid.

## The contract: three things must agree, everything else may differ

The lesson is already in the repo, one level down. When `c` gained a keyboard path, the pointer's
line rules and the cursor's line rules were extracted into one function — `cursorHit` in
`web/diff-viewer/src/viewer/gutter.ts` — precisely so *"the two paths cannot come to different
conclusions about which lines may carry a comment."* The same move, one level up:

1. **Which lines may carry a comment.** Today `PatchReconstructor.Reconstruction` carries
   `commentableOriginalLines` / `commentableModifiedLines`, and `ReviewModel.commentableLines(in:)`
   narrows them for the "since my review" round (ADR 0028). Both renderers read *that*, computed
   once. A padding line the reconstruction inserted between hunks must be as unclickable in the
   native list as it is in Monaco, because GitHub rejects a comment on one and rejects the whole
   review with it.
2. **What a comment means.** A line number plus a side, through the same `ReviewModel` entry point
   the bridge event lands on today (`handle(_:)`'s `.addComment`, then `composerRequest`). The
   native list raises the same request; it does not grow a second composer.
3. **Which round is showing.** `roundView` and the interdiff filter already live on the model. The
   native list reads them; it does not decide them.

Free to differ, explicitly and permanently: syntax highlighting, word-level intra-line diffs,
side-by-side layout, folding, the minimap. **Feature parity is not the goal and pretending
otherwise is what would make this expensive.** The native view is a different product — a linear,
walkable, announced list of hunks — and it earns its place by being better at the thing Monaco is
worst at, not by catching up.

## The prerequisite: the model throws away exactly what a list needs

`PatchReconstructor` (`Shepherd/Features/DiffViewer/PatchReconstructor.swift`) produces two padded
`String` documents plus two `Set<Int>`. That is the right shape for Monaco, which wants two
documents and computes the diff itself. It is the wrong shape for a list, and not by a little: the
per-line facts a list must announce — **is this line added, deleted or context; what is its number
on each side** — are computed during the walk and then thrown away.

So step one is a richer `Reconstruction`: a `[PatchLine]` alongside the two documents, each line
carrying its kind, its original and modified numbers where they exist, and its text. **Derived in
the same single walk that builds the strings**, so the two shapes cannot describe different files.
That is the whole reason to do it inside `PatchReconstructor` rather than in a new parser next to
it: a second parser is a second truth.

And step one-and-a-half, which is worth doing on its own account: **move `PatchReconstructor` into
`Packages/ShepherdKit`.** It imports nothing but `Foundation` and `ShepherdCore` today, and both
types it needs — `ChangedFile` and `DiffSide` — are already in `ShepherdCore`. But it sits in the
app target, so `PatchReconstructorTests` runs only under `xcodebuild` on the macOS runner. The
patch parser is the most fiddly pure logic in the app (twelve tests, and they cover a deleted SQL
comment that looks like a `---` header) and it is *not exercised on the Linux leg at all*. That is
backwards, and it makes the claim "this new view's text is testable on Linux" false until it moves.

## The view

A `ScrollViewReader` + `LazyVStack` of hunk headers and line rows — **the same construction the
inbox list uses**, not a SwiftUI `List`, because that is the house pattern for keyboard navigation
(`.focusable()`, `.focusEffectDisabled()`, `.focused($…)`, `.onKeyPress(phases: .down)`, selection
as a model property rather than a `List(selection:)` binding). Following it buys the app's whole
keyboard vocabulary for free: `j`/`k` and the arrows walk lines, `c` opens the composer on the
selected line, `[`/`]` are meaningless here and travel on. One keyboard, two renderers.

Each row is one accessibility element, labelled through `SpokenRow.sentence`, which is what every
list row in the app already does. The sentence is built from structured data by an app-side
extension in the shape of `EvidenceFactText` — because `ShepherdCore` must never call
`String(localized:)` and the line kinds therefore stay plain enum values in the model, turning into
prose in exactly one place. Roughly:

> "Added. Line 42. `let x = 1`. Two comments."

with the kind, the number, the code and the thread count each contributed only when it applies —
`SpokenRow.sentence` already drops the blanks. Code read aloud is its own problem (VoiceOver says
"let x equals one" for that line and something unhelpful for a line of punctuation), and the
honest answer is that this cannot be tuned from here; the sentence structure is what this plan
fixes, and the wording is a note for the Mac session.

The rows carry their thread and draft-comment counts from `threadsForSelectedFile` and
`draft?.comments` **directly** — not through `bridgeThreads` / `bridgeDraftComments`. Those two
exist to render Markdown into sanitised HTML for a web view; a native row wants `bodyMarkdown` and
SwiftUI's own Markdown. That is one less HTML rendering path in the app, which is a security
simplification as well as a simpler view.

## Where it plugs in

One branch. `ReviewScreen.diffOrPlaceholder`'s `else if let content = model.selectedContent`
currently builds `DiffViewerView(…)`; the switch chooses between that and the new view. Everything
around it — the file header, the round switch, `SinceReviewFindingsView`, the composer bar, the
thread popover — keys off `model` rather than off which renderer is drawing, so none of it moves.

**Which renderer, and who decides.** The recommendation is two rules rather than a three-way
control: the native list is used when VoiceOver is running, *and* a setting in the existing DIFF
VIEWER card can ask for it always. Automatic-on-VoiceOver because the Monaco path's screen-reader
behaviour is still unverified and this one is built for it; a setting as well because the plan's own
argument is that a walkable diff is a better product for everybody, and a sighted keyboard user
should be able to choose it. A new `AppSettings` boolean carries the second obligation
`CONTRIBUTING.md` states: `SyncedSettingsDocument`, both directions of `SettingsSyncApplier`, and a
`SettingsSyncTests` round-trip, or it silently stops travelling between a user's Macs.

Open question worth naming rather than deciding here: whether a VoiceOver user who *prefers* Monaco
can get it back. Two rules cannot express that; a three-state enum can (`automatic` / `web` /
`native`), which is what `Tab` and `RoundView` already are. It costs one enum and one picker, and
it is the difference between a default and a lock.

## What it costs, honestly

- A second renderer to keep in step with the first — bounded by the three-point contract above, and
  no wider. If that boundary is not held, this becomes the thing ADR 0003 avoided.
- `PatchReconstructor` gains a per-line model and moves target. The move touches `project.yml` and
  the imports of everything that uses it; the gain is that the app's most fiddly pure logic finally
  runs on both CI legs.
- A localisation surface of the same order as `EvidenceFactText` — a sentence per line kind, plus
  the counts. The gate (`Scripts/check-localization.py`) will name every key that is missing, and
  an interpolated `Int` also needs its line in that script's hand-checked type table.
- One setting, with the sync obligation.

## What this does not settle

Whether the announcements are *good*. A sentence that reads correctly in a plan can still be
exhausting at forty lines a minute, and the only way to know is a Mac, VoiceOver, and somebody
listening — the same session that owes an answer on §1's `setAccessibility`, on §3's Larger Text,
and on the contrast pass. This plan makes that session worth having: today there is nothing to
listen to but Monaco.
