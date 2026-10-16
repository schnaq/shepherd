# Conversation tab, phase B — reactions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** React like on GitHub — the eight emojis on the description, comments, reviews and inline review comments, visible at once, queued offline.

**Architecture:** One new outbox action `react(subjectID:content:adding:)` drained through GitHub's GraphQL `addReaction`/`removeReaction` mutations (the ADR 0005 exception ADR 0043 records). The app shows GitHub's stored state plus a per-screen optimistic overlay that is cleared when a fetched detail agrees with it; the existing central re-read after a sent write (AppEnvironment) brings that detail.

**Tech Stack:** Swift 6, SwiftUI (macOS 27), GRDB, XCTest, GitHub GraphQL.

**Spec:** `docs/adr/0043-the-conversation-tab.md` ("B: reactions are the second GraphQL write").

## Global Constraints

- ShepherdKit: no user-visible strings, Linux-buildable, Foundation only.
- The outbox payload coding is hand-written (`Outbox.swift`): a new case gets its CodingKeys entry, its payload keys, encode and decode arms, `kind`, `basedOnIssueUpdatedAt` (`nil`), and an old row must keep decoding.
- Every write goes through `PullRequestActions` → the outbox; nothing calls `GitHubClient` for a mutation.
- Every new user-visible string: German row in `Shepherd/Resources/Localizable.xcstrings`; text sizes via `Theme.type`/`Theme.mono` in the conversation files; colours `Theme` tokens; spoken labels say what a control shows and does (ADR 0033).
- No new host; reactions carry no text, but nothing about them goes to webhooks or telemetry either.
- Reacting is offered only where `PullRequestConversation.viewerCanReact` is true (a locked conversation or an archived repository says false); with no conversation read yet, it is not offered.

## Review Focus

- A double click on a reaction (add, then remove) must end with the reaction removed on GitHub and on screen — rows drain in order and the overlay follows the last click.
- An offline click stays visible while the screen is open and is sent later; a refused write takes the overlay back and toasts.
- The re-read that follows a send must not flicker the reaction off and on again (the overlay stays until a detail agrees).
- A reaction GitHub already has (added elsewhere) is not added twice; removing one that is already gone does not leave a failed row behind.
- VoiceOver: each capsule says the emoji's name, the count, whether it includes yours, and that pressing it adds or removes yours.

---

### Task 1: ShepherdKit — the outbox action, the mutations, the drain

**Files:**
- Modify: `Packages/ShepherdKit/Sources/ShepherdCore/Models/Outbox.swift` (case `react(subjectID: String, content: ReactionContent, adding: Bool)`; kind `"react"`; hand-written coding with payload keys `subjectID`, `content`, `adding`)
- Modify: `Packages/ShepherdKit/Sources/ShepherdSync/SyncEvent.swift` (`SentMutation.Kind.reactionChanged`)
- Modify: `Packages/ShepherdKit/Sources/GitHubKit/GraphQL/GraphQLDocuments.swift` (`addReaction`, `removeReaction` mutations), `GraphQLDTOs.swift` (payload DTO), `GitHubClient.swift` (`public func setReaction(subjectID: String, content: ReactionContent, adding: Bool) async throws`)
- Modify: `Packages/ShepherdKit/Sources/ShepherdSync/SyncPorts.swift` (`PullRequestFetching.setReaction(subjectID:content:adding:)`), `SyncEngine.swift` (`execute` arm, `sentKind`)
- Modify tests: `Tests/ShepherdCoreTests/SupportTypeTests.swift` (round trip + an encoded literal decodes), `Tests/GitHubKitTests/WriteRequestTests.swift` (request body: operation name, `subjectId`, `content` raw value), `Tests/ShepherdSyncTests/SyncTestSupport.swift` (`MockGitHub.setReaction` records calls), `Tests/ShepherdSyncTests/OutboxDrainTests.swift` (a queued react row is sent through the port, settles as `.reactionChanged`; two rows add→remove are sent in order)

Documents:

```graphql
mutation ShepherdAddReaction($subjectId: ID!, $content: ReactionContent!) {
  addReaction(input: { subjectId: $subjectId, content: $content }) { reaction { content } }
}
mutation ShepherdRemoveReaction($subjectId: ID!, $content: ReactionContent!) {
  removeReaction(input: { subjectId: $subjectId, content: $content }) { reaction { content } }
}
```

- `content` is `ReactionContent.rawValue` (the GraphQL enum name). Not idempotent at the transport (`isIdempotent: false`), like `resolveThread`.
- GitHub answers an `addReaction` for a reaction the viewer already has with that reaction — no error. A `removeReaction` for one the viewer no longer has: treat a GraphQL error whose message says the reaction was not found as sent (the state is what was asked for); every other error goes the usual way. Check GitHub's documented behaviour; if it answers success instead, no special case is needed — say which in the report.

- [ ] Failing tests → implement → `cd Packages/ShepherdKit && swift test` green → commit `feat(kit): react through the outbox (ADR 0043)`.

### Task 2: The app — reacting on every post

**Files:**
- Modify: `Shepherd/Features/PullRequest/PullRequestActions.swift` — `func react(on summary: PullRequestSummary, subjectID: String, content: ReactionContent, adding: Bool) async -> OutboxWriteOutcome?` (written in the background like `close`: no toast for sent or queued, the failure toast only; `WriteKind.reaction`)
- Modify: `Shepherd/Features/Review/ReviewModel.swift` — `reactionOverlay: [ReactionKey: Bool]` (`ReactionKey` = subject id + content; `true` = the viewer's reaction is wanted on), `func toggleReaction(subjectID:content:currentlyReacted:actions:)`, and in `rebuildConversationEntries`/`apply`/`refresh`: drop overlay keys the new detail agrees with. A pure `static func displayed(_ groups: [ReactionGroup], subjectID:, overlay:) -> [ReactionGroup]` (count ±1, `viewerHasReacted` from the overlay, groups that reach zero disappear, a new group appears in GitHub's emoji order) — unit-tested.
- Modify: `Shepherd/Features/PullRequest/ConversationStreamViews.swift` — `ReactionSummaryView` becomes a `ReactionBar(subjectID:groups:canReact:onToggle:)`: each capsule is a button toggling the viewer's reaction; a trailing smiley-plus button opens a small popover/menu of the eight emojis (each a button, with its spoken name); not drawn at all when `canReact` is false (then the capsules are read-only as today). Used for the description (subject = the pull request's node id `summary.id`), comments, review bodies (also for a review with reactions but no body), and thread comments.
- Modify: `Shepherd/Features/Review/ReviewComposer.swift` (`ThreadCommentView` uses the bar; in the diff popover the bar is read-only unless the popover can reach the model — keep it read-only there if not)
- Modify: `Shepherd/App/AppEnvironment.swift` — `.reactionChanged` joins the kinds that trigger the coalesced re-read
- Modify: `Shepherd/Features/Settings/SyncSettingsTab.swift` (outbox label "React"), `Shepherd/Automation/WebhookCoordinator.swift` and `Shepherd/Automation/MergeSeriesCoordinator.swift` (exhaustive switches: ignore), any other exhaustive switch the compiler names
- Modify: `Shepherd/Resources/Localizable.xcstrings` (German rows), `Scripts/check-type-scale.py` if a new file
- Test: `ShepherdTests/ConversationReactionTests.swift` — `ReviewModel.displayed` cases (add to an existing group, add a new group, remove the viewer's only reaction → group gone, overlay agreeing with server → unchanged) and the overlay-clearing rule as a pure function
- Docs: `docs/FEATURES.md`, user guide `site/content/docs/review.mdx` + `.de.mdx` (one paragraph), ADR 0043 only if the implementation forced a change, CONTRIBUTING host list (the two GraphQL mutations on api.github.com)

- [ ] Implement → both Python checks OK → `build` and `build-for-testing` OK → commit `feat(review): react to any post (ADR 0043)`.
