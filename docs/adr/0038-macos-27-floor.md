# ADR 0038: macOS 27 (Golden Gate) as the floor, and what it buys

Status: Accepted · Date: 2026-09-22 · Supersedes [ADR 0002](0002-macos-26-apple-silicon.md)'s
minimum version; its Apple-Silicon-only half stands.

## Context

ADR 0002 set the floor at macOS 26 for one reason: Apple Foundation Models and the rest of the
on-device intelligence block live there and nowhere below. That reasoning has a successor. macOS 27
shipped on 2026-09-14, the maintainer's build machine runs it with Xcode 27, and the 27 SDK carries
the APIs that turn Shepherd's intelligence from *one call per question* into something that can
read, look things up and check — which is the product's whole thesis about agent pull requests.

The founder's decision, 2026-09-22: **make the move, all of it**, rather than gate every new
capability behind `#available(macOS 27, *)` and carry two code paths for a floor that is a year
old by the time most of this ships. Tahoe users keep 1.3.x through Sparkle; the appcast's
`minimumSystemVersion` says so per item.

Every API named below was checked against the installed SDK's `.swiftinterface` files on
2026-09-22, not against session summaries. Three things the summaries got wrong and the SDK
settled: `ToolbarOverflowMenu` is unavailable on macOS; there is no `preferredImageVisibility`
on `NSMenuItem`; `IntentValueQuery` is a 26 API, not 27.

## Decision

**Minimum deployment target is macOS 27.0, Apple Silicon only.** `project.yml`, the cask
(`depends_on macos: :golden_gate`), README and CONTRIBUTING say so. Sparkle moves to 2.10.0, the
release that fixes delta updates on Golden Gate. `ShepherdKit` stays platform-independent — its
floor is a SwiftPM concern and it keeps `swift test` green on Linux.

**The programme this floor is for**, in the order it is built, each item its own plan:

1. **Claude as a `LanguageModel`.** Anthropic ships
   [`ClaudeForFoundationModels`](https://github.com/anthropics/ClaudeForFoundationModels), a
   package whose `ClaudeLanguageModel` conforms to Apple's new `LanguageModel` protocol. Shepherd's
   own Anthropic provider becomes a thin adapter around one `LanguageModelSession` that takes
   whichever model is chosen — `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`,
   `ClaudeLanguageModel` — and ADR 0031's "a model you bring" becomes a three-entry picker. Token
   usage comes from `session.usage`; context fits are decided by `contextSize` and
   `tokenCount(for:)` rather than guessed. ADR 0009's dependency surface grows by exactly this
   package, pinned to an exact version like Sparkle.

2. **The reviewer that reads the diff.** ADR 0026's claims-versus-evidence becomes a session with a
   `DynamicProfile`: tools for the diff excerpt, the checks and — through `SpotlightSearchTool`
   from the `_CoreSpotlight_FoundationModels` overlay, configured `.focused()` — the related pull
   requests in this Mac's own index. `ToolCallingMode.required` where a claim must be checked,
   `onToolCall` for the audit line, and `PrivateCloudComputeLanguageModel` with
   `ContextOptions(reasoningLevel:)` when the diff exceeds the on-device window. Everything ADR 0007
   says about tiers, budgets and drafts-not-submissions holds unchanged.
   *Landed 2026-09-22 narrower than written, as [ADR 0026](0026-claims-vs-evidence.md)'s
   amendment of that date records:* *Look closer* on one ✗ or ? line, on-device only, answering
   with excerpts Shepherd locates in the patch rather than a check. No PCC — availability says yes
   and the first request fails without the App Store entitlement — and no Spotlight tool, because
   the index holds only open pull requests' titles and labels.

3. **Siri acts on Shepherd's notifications.** `appEntityIdentifiers` on the check-and-review
   notifications (the `_UserNotifications_AppIntents` overlay), `IndexedEntityQuery` so Siri's
   index can ask the app to re-donate, and `OwnershipProvidingEntity` so a merge is confirmed
   before it happens. ADR 0021's rule that nothing writes from a phrase is *relaxed*, not dropped:
   a write intent exists only behind a setting that is off by default, and it confirms.
   *Landed 2026-09-22 read-only, by the founder's decision, as [ADR 0021](0021-app-intents-and-spotlight.md)'s
   amendment of that date records:* notifications and Spotlight items name their
   `PullRequestEntity`, the query answers the system's re-index requests, and there is no write
   intent. `OwnershipProvidingEntity` turned out to classify ownership rather than confirm
   anything, and is not adopted until rows carry a repository's visibility.

4. **Images in the prompt.** `Attachment(ImageAttachmentContent(...))` for the screenshots agents
   put in their descriptions, so the on-device digest can say what changed visually.

5. **The list that moves.** `reorderable()` for a manual order in the inbox, `swipeActionsContainer()`
   for approve and merge under a trackpad swipe, both inside the toolbar-and-motion work already
   planned for the review screen.

## Consequences

- Users on macOS 26 stop receiving updates past 1.3.x. The appcast keeps the 1.3.0 item for as
  long as it is among the ten newest (`Scripts/release.sh` prunes beyond `MAX_ITEMS`); after that
  a Tahoe Mac is offered nothing, which is the same as today for a Mac below 26. The product page
  and the cask state the floor.
- CI's "select the newest Xcode" step already prefers an Xcode 27 when one exists at
  `/Applications/Xcode-27*.app`; on a runner whose default Xcode *is* 27 the step is a no-op and
  the default builds. The ShepherdKit job is unaffected.
- The programme above adds one remote package and touches three ADRs by amendment (0007, 0021,
  0026, 0031); each item records its own amendment when it lands, so this ADR stays a floor
  decision and a table of contents rather than a design.
- Two SDK facts constrain the design and are recorded here so nobody plans against them again:
  `BGContinuedProcessingTaskRequest` is iOS-only, so there is no background Neural Engine path on
  the Mac; and `ToolbarOverflowMenu` is not for macOS.
