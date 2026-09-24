# ADR 0040: Liquid Glass on macOS 27 — system glass for the control layer, opaque content

Status: Accepted · Date: 2026-09-23

## Context

The maintainer asked whether Shepherd follows macOS 27's Liquid Glass. On `main` at 1.5.2 the
answer was "partly, and mostly by accident":

- The inbox and the fleet are `NavigationSplitView`s, and the inbox has a system `.toolbar`, so
  both get the system's glass sidebar and toolbar capsules.
- But the rail's opaque fills sat on top of that glass (37 `.background(Theme.panel)` calls in
  all, most of them rightly on content). The rail's own
  fill (twice: `InboxScreen` and `InboxSidebar`), the content-kind picker, both pinned footer rows
  and the fleet's agent list painted an opaque white (or `#14161D`) slab over the sidebar panel,
  which made the one system-glass surface in the window look like a custom one.
- The review screen had no toolbar at all. Its header was a 52 pt `HStack` of custom buttons on a
  `Theme.panel` band, drawn *under* an empty title bar: two bars' worth of height, and the one
  screen that ignored the system chrome the rest of the window uses.
- No `glassEffect` anywhere, including on the toasts, which are the one surface that genuinely
  floats.

Apple's guidance for Liquid Glass is short and the parts that matter here are unambiguous: glass is
for the **navigation and control layer** that floats above content — toolbars, sidebars, floating
controls — and never for the content itself; let system components provide it rather than drawing
it; do not stack glass on glass; keep content opaque and legible. System glass follows Reduce
Transparency, Increase Contrast and Reduce Motion by itself, which a hand-drawn surface does not.

Every API used below was checked against the macOS 27 SDK's `SwiftUI` and `SwiftUICore`
`.swiftinterface` files on 2026-09-23: `ToolbarItem(placement: .navigation / .primaryAction)`,
`ToolbarSpacer(.fixed, placement:)`, `ToolbarContent.sharedBackgroundVisibility(_:)`,
`navigationSubtitle(_:)`, `.buttonStyle(.glassProminent)`, `View.safeAreaBar(edge:spacing:content:)`,
`glassEffect(_:in:)`, `GlassEffectContainer(spacing:content:)`,
`background(_:ignoresSafeAreaEdges:)`. `ToolbarItemPlacement.title` is unavailable on macOS; the
title is the window's `navigationTitle`.

## Decision

**1. The control layer is the system's, and nothing opaque sits on it.**

- **Review screen → the window's toolbar.** `ReviewHeaderView` is gone; `ReviewToolbar` is a
  `ToolbarContent` attached to the review screen. The back button ("Inbox", chevron) is the
  `.navigation` item. The pull request's title is the window's `navigationTitle` and
  `slug · head → base` its `navigationSubtitle` — verbatim, since it is all identifiers — so macOS
  draws, truncates and hands them to the Window menu itself. Trailing, in three groups separated
  by `ToolbarSpacer(.fixed)`: a facts item (provenance chip, file count and `+/−`, the checks
  summary, the outbox write chip) with its shared capsule hidden; *Retry* as its own item while a
  write has failed; *Delegate…*; and *Review* + *Merge* as one group. The inbox and the review
  screen never coexist — `SignedInRootView` switches on the route — so their toolbars cannot
  duplicate.
- **Sidebars are bare.** No fill behind the inbox rail, the issues rail, the content-kind picker,
  the pinned Fleet and Settings rows, or the fleet's agent list. The pinned rows moved from
  `safeAreaInset` to `safeAreaBar`, because once the fill is gone the rail scrolls under them, and
  a safe-area *bar* is what gets the system's scroll edge effect.
- **Nothing reaches up into the toolbar by accident.** A colour background extends into every
  safe area its view touches. The review screen's file list, file header, update banner and focus
  session bar now paint their own frame only (`ignoresSafeAreaEdges: []`). Left to the default,
  the session bar — a top safe-area inset directly under the toolbar — would be expected to tint
  the toolbar strip `Theme.raised` for as long as a session ran.

**2. Content stays opaque.** Lists, cards, section headers, the detail panels, the review file list
and file header, the diff, the composer, every sheet, the update banner and the focus session bar
keep their `Theme` fills. The diff is a `WKWebView` (Monaco) or the native list; neither has glass
over it or under it, and nothing scrolls under the toolbar on the review screen — a hairline
divider draws that edge instead of a scroll edge effect, which is also what keeps the panel colour
out of the toolbar. The ⌘K palette stays an opaque `Theme.panel` card: it floats, but it is a
search field and a result list, which is content, and results over refracted rows would be the
illegible case the guidance warns about.

**3. Buttons: system styles in the control layer, the app's styles inside content.**

- In a toolbar, an ordinary item uses the toolbar's default style. A toolbar item *is* glass
  already; an explicit `.buttonStyle(.glass)` inside one nests a second capsule in the first.
- The one recommended action in a bar is `.glassProminent`, tinted with a theme colour: the review
  toolbar's Merge, tinted `Theme.success`, only while nothing blocks the merge **and** CI is green,
  the rule the old green `SuccessButtonStyle` followed. Otherwise Merge is an ordinary item.
  *Superseded the same day: Merge is always the prominent green action (amendment below).*
- A read-out in the toolbar (the review facts, the inbox's sync status) hides its shared capsule
  with `sharedBackgroundVisibility(.hidden)`, because a capsule is how the toolbar says "press me".
- `.glass` alone is for a button that floats on its own, outside a toolbar. There is none today.
- Inside content — cards, sheets, panels, list headers, empty states — buttons keep
  `PrimaryButtonStyle`, `SuccessButtonStyle` and `SecondaryButtonStyle`. Glass on an opaque card
  has nothing behind it to refract. `DesignComponents.swift` carries this rule above the styles.
- `.busy(_:)`'s spinner lives in the app's three styles, so a write button on a system style draws
  `busyLabel(isBusy:tint:)` on its own label. The review toolbar's Merge does, and stays enabled
  while the merge is *being sent* (the press is refused by the same guard `m` meets), because the
  system dims a disabled toolbar item spinner and all. Queued or merged still disables it.

**4. What floats may be glass, and only that.** The toasts are `glassEffect(.regular, in:)` pieces
in a `GlassEffectContainer`, without the fill, stroke and shadow they had: they sit over whatever
the window shows and belong to none of it, and two are often up at once, which is what the
container is for (glass cannot sample glass). The inbox's shortcut bars (pull requests and issues)
do **not** float — each is a full-width strip of key caps pinned to the list's bottom edge, the
list's own status line — so they stay opaque content footers. Glass across the whole width of a
content column would be a glass slab over content, which is the thing the guidance rules out. There is no floating bulk-triage bar; bulk triage is a toolbar menu.

**5. Tokens do not move.** No colour or type token changed. Glass needed none as far as a build can tell: the
rail's text tokens are expected to read on the sidebar material, and the toolbar's contents keep
their fonts. The screenshots are the check (Consequences). The
type-scale gate (`Scripts/check-type-scale.py`) is unchanged and green.

## Consequences

- The review screen is one toolbar tall instead of a title bar plus a header, and it looks like the
  rest of the window. The title is truncated by macOS rather than by a `lineLimit(1)` in an
  `HStack`, which is a behaviour change: at narrow widths the system decides what yields, and the
  facts item may be pushed into the toolbar's overflow before the title shortens.
- `Theme.selection` and the rail rows' hover fill now sit on the sidebar's translucent material
  rather than on white or `#14161D`. They were chosen against the opaque panel; if a screenshot
  shows them too faint on glass, the fix is a token for "selection on glass", not a fill back
  under the rail.
- The window title is the pull request's title while a review is open, and is expected to revert
  when the review screen leaves the hierarchy; a stale title on the inbox after leaving a review
  is one of the screenshot checks.
- The fleet screen's back button is the toolbar's navigation item too (2026-09-24): "‹ Inbox",
  the review toolbar's button, in every state of the screen, with Escape on it. The chevron in
  the agent list's header and its copy over the no-agents state are gone.
- Anything new follows the rules above: a new bar under the toolbar paints its own frame only; a
  new toolbar item uses the default style; a new sheet uses the app's styles.

## Amendment 2026-09-23: the prominent action is Merge, everywhere

After the first screenshots the maintainer settled the one question the rule above left to each
surface: **Merge is the primary action on every surface, always.**

- The review toolbar's Merge is `.glassProminent` tinted `Theme.success` whatever CI says. A
  blocker (draft, conflict), an ended pull request, or a merge already queued or done disables
  it; a red suite no longer repaints it — the checks summary beside it says that in words. The
  spinner while the merge is being sent is unchanged. This supersedes item 3's "only while
  nothing blocks the merge **and** CI is green".
- The inbox detail panel's *Merge…* is the panel's green `SuccessButtonStyle` button; *Approve*
  is a `SecondaryButtonStyle` button with its tick.
- The review screen's composer bar: *Approve… ⌘⏎* is secondary (tick, key cap and ⌘⏎ kept),
  because the toolbar's Merge is the screen's green button.
- Green is Merge's colour and nothing else's. The submit sheet's *Submit*, the delegation
  sheet's *Commit & push*, and the bulk-triage sheet's confirm button when the plan only
  approves are `PrimaryButtonStyle`; the bulk-triage confirm is green when the plan merges, and
  the merge sheet's *Merge* stays green.
- No surface shows two green buttons.

Two small toolbar and rail fixes landed with it: the inbox toolbar's account avatar stands on
its own with no capsule (inside one it joined the Sync group and read as its third button), and
the rail's *Pull requests | Issues* switch is the system segmented control at `.large` size with
flexible segments, spanning the rail's 10 pt inset so its edges line up with the row highlights,
with no hairline under it.

In an inactive window macOS draws a prominent toolbar button without its tint; the review
toolbar's Merge is grey there by the system's rule, not because it is disabled.
