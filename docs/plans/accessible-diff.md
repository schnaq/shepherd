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

**It is built, 2026-09-05.** The decision this plan worked out, and the shape it shipped in, are
recorded in [ADR 0034](../adr/0034-native-diff-renderer.md) rather than repeated here. What follows
is kept as the path that led there — the reasoning that decided the contract, and the two things
this plan got wrong along the way and corrected — with what shipped marked in place.

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
   `commentableOriginalLines` / `commentableModifiedLines`, and a narrowing for the "since my
   review" round (ADR 0028) applies on top of them. Both renderers must read *that*, computed once.
   A padding line the reconstruction inserted between hunks must be as unclickable in the
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

**Built exactly this way.** `ReviewModel.commentableLineSets(in:)` is the one function that answers
item 1, with `commentableLines(in:)` as only its sorted-array spelling for the bridge; the native
list's `requestCommentOnSelectedRow()` is item 2, ending at the same `handle(_:)`'s `.addComment`
the bridge event reaches; and the list reads `roundView` for item 3 exactly as recommended, never
setting it. ADR 0034 records the contract as shipped.

## The prerequisite: the model throws away exactly what a list needs

`PatchReconstructor` (`ShepherdCore/Review/PatchReconstructor.swift`) produces two padded
`String` documents plus two `Set<Int>`. That is the right shape for Monaco, which wants two
documents and computes the diff itself. It is the wrong shape for a list, and not by a little: the
per-line facts a list must announce — **is this line added, deleted or context; what is its number
on each side** — are computed during the walk and then thrown away.

So step one looked like a richer `Reconstruction`: a `[PatchLine]` alongside the two documents,
each line carrying its kind, its original and modified numbers, and its text.

**It already exists, and finding that out is the most useful thing in this plan.** `PatchWalker`
in `Claims/ClaimPattern.swift` walks a patch into `PatchRow { kind, text, baseLine, headLine }` —
added, removed or context, the text with its marker stripped, and *both* sides' numbers. It is in
`ShepherdCore`, it is tested on Linux, and it was written for the claims feature (ADR 0026). The
native list's line model is therefore not work to be done; it is a type to be reused, or at most
extended. What it does not carry is whether a line may take a comment, which stays where it is —
that is the first item of the contract above and belongs to the reconstruction, not to the walk.

One rule in it is worth knowing before reusing it: a *removed* row's `headLine` is the head line
the deletion sits **in front of**, because a deleted line has no head-side number of its own. That
is exactly the fact the list has to announce, so it is the right rule — but it is a rule, not an
accident, and a second implementation would have to make the same choice deliberately.

Which brings up the thing this plan first got wrong. "A second parser is a second truth" was
written as a warning about a hypothetical. There were **already two**, deliberately:
`UnifiedPatch` in `ShepherdCore` (ADR 0028's interdiff — the head side of a patch, plus hunk and
header reading/writing, Linux-tested) and `PatchReconstructor` in the app target (both sides plus
the commentable sets, macOS-tested). The reason on record in ADR 0028 was that the second type
also produces the viewer's commentable-line sets and is tested against the bridge — a reasonable
call for two consumers with different needs. There are still two, and both are in
`ShepherdCore/Review/` now; the move is the step below and it is done.

The duplication is not abstract. `header(_:)` is the same twenty lines in both files, and
`hunks(in:)` was the same walk with **one behavioural difference**: `UnifiedPatch` drops the empty
component a terminating newline leaves behind, and `PatchReconstructor` did not. Two functions of
the same name and contract disagreeing about the end of a file is not a style question — the empty
component reads as an unchanged empty line, so it would have been appended to both documents *and*
inserted into both commentable sets, and a comment on a line that is not in the diff is one GitHub
refuses along with the whole review. It was not a live bug, and that was checked rather than
assumed: GitHub's `files[].patch` ends without a newline (read off a real API response) and the
interdiff's synthesized patch is `joined(separator: "\n")`. It was a trap set for the third
producer, and `git diff` is one. The guard and its test are now in both.

And there are not two walks over this grammar. There are **four**: `UnifiedPatch` (hunks, headers,
the head side — now also serving the reconstructor), `PatchReconstructor` (the two documents and
the commentable sets), `PatchWalker` (the rows above), and `IntelligenceDiffWindow.rows(in:)`
(rows again, for the CI-diagnosis window, whose doc comment says its arithmetic is the
reconstructor's "deliberately"). Each of the last two re-does the `@@` split, the CRLF
normalisation, the trailing-newline guard and the base/head arithmetic.

Collapsing those two is the obvious next simplification and it is **not** mechanical, which is why
it is named here rather than done: they differ where their jobs differ. `PatchRow` fixes a
removed row's `headLine` to the line the deletion precedes, for links; `IntelligenceDiffWindow`'s
row carries `isHeader`, because a window may start mid-hunk and has to synthesize a header for it.
One walk could serve both, and deciding what it yields is a design step, not a find-and-replace.

A third consumer is what changes the calculus. Two parsers for two shapes was a trade; four
walks where three want structured lines is a reason to have **one**, from which the two documents,
the commentable sets, the interdiff's head-side array and the rows are all derived. That is step
one properly stated, and it subsumes step one-and-a-half:
**`PatchReconstructor` moves into `Packages/ShepherdKit`**, beside `UnifiedPatch`. It imported
nothing but `Foundation` and `ShepherdCore`, and both types it needs — `ChangedFile` and
`DiffSide` — were already there. While it sat in the app target its twelve tests (they cover a
deleted SQL comment that serialises as a `---` header) ran only under `xcodebuild` on the macOS
runner: the app's fiddliest pure logic was *not exercised on the Linux leg at all*, which also made
the claim "this new view's text is testable on Linux" false until it moved.

**That half is done, 2026-09-05**, as a pure move and nothing else: the type is
`ShepherdCore/Review/PatchReconstructor.swift` with its members `public`, and its twelve tests are
`ShepherdCoreTests/PatchReconstructorTests.swift`.

**The per-line model is done too, the same day.** Not as a new type — `PatchRow` moved out of
`Claims/ClaimPattern.swift` into `Review/`, exactly as this section predicted a page ago, because a
patch line is a patch line whoever walked it. `Reconstruction` gained `rows: [DiffRow]`, an enum of
a hunk header or a `PatchRow`, filled in during the same walk that builds the two documents and
the commentable sets — so a row's line number and the number that walk put in a commentable set are
the same variable, not two counters that could drift. This is not the "one walk" that would also
collapse `PatchWalker` and `IntelligenceDiffWindow.rows(in:)`; that collapse is still not done, and
still not mechanical, for the reason the paragraphs above it give.

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

**Built as described.** `DiffListView` is the `ScrollViewReader` + `LazyVStack`, `DiffRowText` is
the app-side extension that turns a row into one sentence, and the counts come from
`threadsForSelectedFile` / `draft?.comments` exactly as planned. Two differences from the sketch
above, both narrower than it: a context row's kind is not spoken at all, not merely de-emphasised —
"Context." two hundred times turned out to be worse than saying nothing — and `j`/`k` land on a
hunk header rather than skipping it, so a reader who cannot see the gap between hunks is told about
it instead of having it skipped past. ADR 0034 records both as decisions, not omissions.

## Where it plugs in

One branch. `ReviewScreen.diffOrPlaceholder`'s `else if let content = model.selectedContent`
currently builds `DiffViewerView(…)`; the switch chooses between that and the new view. Everything
around it — the file header, the round switch, `SinceReviewFindingsView`, the composer bar, the
thread popover — keys off `model` rather than off which renderer is drawing, so none of it moves.

**Built this way**, with the open question below decided rather than left open. `usesNativeList` in
`ReviewScreen` is the one branch, and it reads `model.settings.diffRenderer`.

Open question, decided rather than merely named: whether a VoiceOver user who *prefers* Monaco can
get it back. Two rules — automatic on VoiceOver, plus a setting that forces the list on — cannot
express that, because "automatic" would still be a lock the moment VoiceOver is running. `DiffRenderer`
is a three-state enum instead (`automatic` / `web` / `native`), the shape `Tab` and `RoundView`
already use, so Monaco stays reachable for a screen-reader user who wants it. It carries the sync
obligation `CONTRIBUTING.md` states — `SyncedSettingsDocument`, both directions of
`SettingsSyncApplier`, a `SettingsSyncTests` round-trip — same as any other setting. ADR 0034
records why three states rather than two rules.

## What it cost, honestly

- A second renderer to keep in step with the first — bounded by the three-point contract above, and
  no wider. That boundary is now something to hold, not just a design intent; ADR 0034 is where it
  is written down as a decision rather than a hope.
- `PatchReconstructor` gained a per-line model, reusing `PatchRow` rather than inventing one — the
  move to ShepherdCore it needed first cost less than this bullet expected (no `project.yml` change,
  no import change at any call site), and paid for itself again here.
- A localisation surface of the same order as `EvidenceFactText`, delivered: a sentence per line
  kind, the line-number phrasing, the counts, and two new entries
  (`originalStart`, `modifiedStart`) in `Scripts/check-localization.py`'s hand-checked `Int` table
  for the hunk header.
- One setting, with the sync obligation paid: `SyncedSettingsDocument`, both directions of
  `SettingsSyncApplier`, a `SettingsSyncTests` round-trip.
- Two costs this plan did not anticipate in this much detail, named honestly in ADR 0034 instead of
  here: the CI-diagnosis card's `file:line` link reaches Monaco but not the native list yet, and the
  reconstruction is now parsed once per keystroke in the list rather than once per file selection.

## What this does not settle

Whether the announcements are *good*. A sentence that reads correctly in a plan can still be
exhausting at forty lines a minute, and the only way to know is a Mac, VoiceOver, and somebody
listening — the same session that owes an answer on §1's `setAccessibility`, on §3's Larger Text,
and on the contrast pass. Those four checks are written out in order in
[accessibility.md](accessibility.md) § "What to check on a Mac", and check 2 there now has
something to listen to besides Monaco.

That check no longer decides whether this plan was worth carrying out — it was, and it is built —
but it still decides how much of the wording above needs to change before the list is worth
choosing over Monaco day to day.
