# Conversation tab, phase C — edit and delete — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edit your own comments, review summaries and pull-request description, and delete your own comments, in the Conversation tab — like on GitHub.

**Architecture:** Two outbox actions, `editComment(ConversationTarget, body:)` and `deleteComment(ConversationTarget)`, drained through REST (ADR 0005's rule; ADR 0043's section C names the endpoints). Offered only where GitHub's `viewerCanUpdate` / `viewerCanDelete` say so (already fetched and stored since phase A). The app shows an optimistic overlay (edited body, hidden deleted post) until a fetched detail agrees; the central coalesced re-read after a sent write brings that detail.

**Tech Stack:** Swift 6, SwiftUI (macOS 27), GRDB, XCTest, GitHub REST.

**Spec:** `docs/adr/0043-the-conversation-tab.md` ("C: edits and deletes are REST, gated by GitHub's own flags").

## Global Constraints

- ShepherdKit: no user-visible strings, Linux-buildable, Foundation only. Hand-written outbox coding: CodingKeys, payload keys, encode/decode arms, `kind`, `basedOnIssueUpdatedAt` (`nil`); old rows keep decoding.
- Every write goes through `PullRequestActions` → the outbox.
- German row for every string; `Theme.type`/`Theme.mono`; `Theme` colours; ADR 0033 spoken labels.
- A delete always asks first (destructive confirmation). A submitted review can be edited, never deleted. The description can be edited only when `viewerCanUpdateDescription`.
- No new host; edits and deletes carry text to api.github.com only, through the existing token.

## Review Focus

- A delete re-sent after a crash comes back `404`: it is completed as sent, never a failed row.
- An edit typed offline survives the screen being left and is sent later; the post shows the edited text meanwhile on this screen.
- Edit then delete of the same comment while both are queued: the delete wins; nothing is sent for the edit if it is still pending (cancel it with `cancelPendingOutboxItem`).
- An edit whose comment was deleted on GitHub meanwhile (`404`) fails visibly with GitHub's words and drops the overlay.
- VoiceOver reaches Edit and Delete from each post's menu, and the inline editor's buttons say what they do.

---

### Task 1: ShepherdKit — targets, actions, REST calls, the drain

**Files:**
- Create: `Packages/ShepherdKit/Sources/ShepherdCore/Models/ConversationTarget.swift` — `public enum ConversationTarget: Sendable, Codable, Hashable { case description; case issueComment(databaseID: Int); case reviewComment(databaseID: Int); case review(databaseID: Int) }` with `var isDeletable: Bool` (only the two comment kinds)
- Modify: `Outbox.swift` — `editComment(ConversationTarget, body: String)` (kind `"editComment"`), `deleteComment(ConversationTarget)` (kind `"deleteComment"`)
- Modify: `SyncEvent.swift` — `SentMutation.Kind.commentEdited`, `.commentDeleted`
- Modify: `GitHubClient.swift` — `public func editConversationText(_ target: ConversationTarget, body: String, repo: RepoRef, number: Int) async throws` (`PATCH /repos/{o}/{r}/issues/comments/{id}` · `PATCH …/pulls/comments/{id}` · `PUT …/pulls/{n}/reviews/{id}` · `PATCH …/pulls/{n}`, body `{"body": …}`); `public func deleteConversationComment(_ target: ConversationTarget, repo: RepoRef) async throws` (`DELETE …/issues/comments/{id}` · `DELETE …/pulls/comments/{id}`; precondition: `isDeletable`)
- Modify: `SyncPorts.swift` (`PullRequestFetching` gains both), `SyncEngine.swift` (`execute` arms; `sentKind`). The client only translates errors; the drain decides that a delete answered `notFound` is `.sent` (the pattern of `isAlreadyMerged` and phase B's refused-removal read). Verify each endpoint's real answer with `gh` on a throwaway comment the lead creates and deletes on a pull request of schnaq/shepherd before relying on it, and record it in ADR 0043 C.
- Tests: SupportTypeTests (round trip both actions, every target; an encoded literal decodes), WriteRequestTests (method, path and body per target), OutboxDrainTests (sent kinds; delete 404 → sent; edit 404 → failed), MockGitHub

- [ ] Failing tests → implement → full `swift test` → commit `feat(kit): edit and delete through the outbox (ADR 0043)`.

### Task 2: The app — Edit and Delete on posts

**Files:**
- Modify: `PullRequestActions.swift` — `edit(on:target:body:)` and `delete(on:target:)` built like phase B's `react`: persist the row at once (serialised per screen with the reaction chain), return the settle task (drain, read back, announce). Toasts: **silent on sent and queued** (the post already shows the new text or is gone — and a cancelled edit's row reads as `.sent`, so a success toast could lie), failure toast with GitHub's words, parked like the others; `WriteKind.edit` / `.delete`, added to `WriteOutcomeToastTests.everyWrite` with the queued exemption
- Modify: `ReviewModel.swift` — fold the phase-B reaction overlay and the two new ones into one value type `ConversationOverlay` (reaction clicks, `editedBodies: [String: String]` by post node id, `deletedPosts: Set<String>`; `settled(against: detail)`, `drop(_:ifStill:)`, the display helpers) held as one stored property and reconciled behind one `!=` in `syncReactionState`'s successor; keys clear when an applied detail agrees (body equal / post gone), a refused write drops its key. Pure and unit-tested without `ReviewModel`. Edit then delete of the same post while the edit is still pending cancels the edit (`cancelPendingOutboxItem`) and queues the delete.
- Modify: `ConversationStreamViews.swift` — each post's ⋯ menu gains **Edit** (when the flag allows) and **Delete…** (when allowed, destructive, confirmation alert naming the author/time); **Edit** swaps the body for an inline editor (`ComposerTextEditor` seeded with the current Markdown, **Cancel** and **Update comment**, ⌘⏎ while focused like the composer — reuse the focus flag pattern), keeping the draft in the model across a tab trip like thread replies. Description: edit only. Review body: edit only. Thread comments in the stream: both (popover stays as it is).
- Modify: `AppEnvironment.swift` — `.commentEdited`, `.commentDeleted` join the re-read kinds
- Modify: `SyncSettingsTab.swift` (labels "Edit a comment", "Delete a comment"), `WebhookCoordinator.swift`, `MergeSeriesCoordinator.swift`, `OutboxSurfacesTests.swift` (every action named once)
- Modify: catalog (German), `Scripts/check-type-scale.py` if a new file
- Test: `ShepherdTests/ConversationEditTests.swift` — the display and settle helpers, the edit-then-delete cancel decision
- Docs: FEATURES.md, user guide en/de (one paragraph), CONTRIBUTING host list (the five REST calls), ADR 0043 only if forced

- [ ] Implement → both Python checks OK → `build` + `build-for-testing` OK → commit `feat(review): edit and delete your own posts (ADR 0043)`.
