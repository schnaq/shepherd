# Conversation tab, phase A — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The review screen's *Conversation* tab shows GitHub's whole pull-request conversation — description, comments, reviews with their threads, commits, events — and lets the reviewer comment, reply, resolve and quote in place.

**Architecture:** One more GraphQL read (`timelineItems`, newest first, ≤5 pages) on the existing detail fetch, tolerated on failure; the review-threads read gains each comment's review id, reactions and viewer flags. The result is stored as `pull_requests.conversationJSON` plus new `review_comments` columns (migration v11). The app turns it into one stream with the pure `ConversationTimeline.entries(...)` (already written) and draws it with new SwiftUI views; writes reuse the existing outbox actions.

**Tech Stack:** Swift 6, SwiftUI (macOS 27), GRDB, XCTest, GitHub GraphQL + REST, Python 3 checks.

**Spec:** `docs/adr/0043-the-conversation-tab.md`

## Global Constraints

- ShepherdKit has **no user-visible strings** and must build on Linux (Foundation only, no AppKit/SwiftUI).
- Every new `String(localized:)` / SwiftUI string literal gets a **German row** in `Shepherd/Resources/Localizable.xcstrings` in the same commit; a removed string takes its row with it. German: Apple's macOS style, **du**, GitHub's review words stay English (pull request, review, approve, merge, commit, diff, branch, draft, check). Counts through `variations.plural`, never concatenation. `#number` never through an `Int` interpolation (use `Text(verbatim:)` or a `String`).
- New SwiftUI files use **`Theme.type(_:weight:)` / `Theme.mono(_:weight:)` only** (no `.system(size:)`), and are added to `MIGRATED` in `Scripts/check-type-scale.py`.
- Colours are semantic `Theme` tokens only (light/dark).
- Writes go through `PullRequestActions` → the outbox (ADR 0006); nothing calls `GitHubClient` for a mutation.
- Reactions and edit/delete are **shown, not offered** in phase A (phases B and C add the buttons).
- No new host; no comment bodies in webhooks or telemetry.
- `python3 Scripts/check-localization.py` and `python3 Scripts/check-type-scale.py` pass; `swift test` passes in `Packages/ShepherdKit`; `mise run build` builds.

## Review Focus

- A conversation read that fails (rate limit, GraphQL error) must leave the previously stored conversation on screen — not an empty tab. (Task 2 tolerates, Task 3 keeps the column.)
- A sweep upsert of the inbox row must not wipe `conversationJSON`. (Task 3 test.)
- A pull request with more than 500 timeline items shows the **newest** 500 and says "Earlier activity is on GitHub". (Task 2 pagination test, Task 5 banner.)
- Bot comments with `<!-- markers -->` and `<details>` render as text a person can read (done in `MarkdownDocument`; Task 5 uses `TranslatableMarkdownText`, which goes through it).
- A reply/comment typed while offline is queued, the field is emptied only once the row is on disk, and the screen does not show a "refresh failed" banner for it (Task 5: reload only on `.sent`).

---

## Already done (commit d652ad4) — the contract every task uses

- `Packages/ShepherdKit/Sources/ShepherdCore/Models/Conversation.swift`: `ReactionContent` (raw values = GraphQL names), `ReactionGroup`, `ConversationComment`, `ConversationReview` (+ `State`), `ConversationReference`, `ConversationEvent` (enum with values), `ConversationEventItem`, `ConversationItem` (`.comment` / `.review` / `.event`), `PullRequestConversation`.
- `ReviewComment` gained `reviewID`, `reactions`, `viewerCanUpdate`, `viewerCanDelete`, `isEdited`, `url` (tolerant decoding).
- `PullRequestDetail.conversation: PullRequestConversation?` (`nil` = not read / failed).
- `Packages/ShepherdKit/Sources/ShepherdCore/Review/ConversationTimeline.swift`: `ConversationTimeline.entries(conversation:commits:threads:) -> [ConversationEntry]`, `ConversationEntry` (`.comment`, `.review(_, threads:)`, `.thread`, `.commits([CommitInfo])`, `.event`).
- `MarkdownDocument` drops HTML comments, unwraps `<details>`, bolds `<summary>`, breaks on `<br>`.

Read those two files before starting any task.

---

### Task 2: GitHubKit — read the conversation and the richer threads

**Files:**
- Modify: `Packages/ShepherdKit/Sources/GitHubKit/GraphQL/GraphQLDocuments.swift` (add `pullRequestConversation`; extend `reviewThreads`)
- Modify: `Packages/ShepherdKit/Sources/GitHubKit/GraphQL/GraphQLDTOs.swift` (conversation DTOs; extend `ReviewCommentDTO`)
- Modify: `Packages/ShepherdKit/Sources/GitHubKit/Mapping/ResponseMapping.swift` (conversation mapping; thread comment extras)
- Modify: `Packages/ShepherdKit/Sources/GitHubKit/GitHubClient.swift` (`pullRequestConversation(repo:number:)`; tolerated read in `fetchDetail`; update the type's header comment listing the detail reads)
- Create: `Packages/ShepherdKit/Tests/GitHubKitTests/Fixtures/pull-conversation.json`, `pull-conversation-page-newest.json`, `pull-conversation-page-oldest.json`
- Modify: `Packages/ShepherdKit/Tests/GitHubKitTests/Fixtures/review-threads.json` (one comment carries the new fields)
- Create: `Packages/ShepherdKit/Tests/GitHubKitTests/ConversationParsingTests.swift`
- Modify: `Packages/ShepherdKit/Tests/GitHubKitTests/DetailParsingTests.swift`

**Interfaces:**
- Consumes: the ShepherdCore types above; `ResponseMapping.makeActor(from:detector:)`, `GitHubTimestamp.parse`, `graphQL(document:variables:resource:isIdempotent:)`.
- Produces: `public func pullRequestConversation(repo: RepoRef, number: Int) async throws -> PullRequestConversation` on `GitHubClient`; `pullRequestDetail` fills `conversation` (or `nil` on any error of that one read); `reviewThreads` fills every `ReviewComment`'s `reviewID`, `reactions`, `viewerCanUpdate`, `viewerCanDelete`, `isEdited`, `url`.

The document — validated live against GitHub on 2026-10-16 (cost 1 point) — read **backwards**:

```graphql
query ShepherdPullRequestConversation($owner: String!, $name: String!, $number: Int!, $before: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      viewerCanUpdate
      viewerCanReact
      lastEditedAt
      reactionGroups { content viewerHasReacted reactors { totalCount } }
      timelineItems(last: 100, before: $before, itemTypes: [
        ISSUE_COMMENT, PULL_REQUEST_REVIEW, HEAD_REF_FORCE_PUSHED_EVENT, LABELED_EVENT,
        UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, REVIEW_REQUESTED_EVENT,
        REVIEW_REQUEST_REMOVED_EVENT, RENAMED_TITLE_EVENT, READY_FOR_REVIEW_EVENT,
        CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT,
        HEAD_REF_DELETED_EVENT, HEAD_REF_RESTORED_EVENT, BASE_REF_CHANGED_EVENT,
        CROSS_REFERENCED_EVENT, REVIEW_DISMISSED_EVENT, AUTO_MERGE_ENABLED_EVENT,
        AUTO_MERGE_DISABLED_EVENT
      ]) {
        pageInfo { hasPreviousPage startCursor }
        nodes {
          __typename
          ... on IssueComment {
            id databaseId body createdAt lastEditedAt url isMinimized minimizedReason
            author { __typename login avatarUrl }
            viewerCanUpdate viewerCanDelete
            reactionGroups { content viewerHasReacted reactors { totalCount } }
          }
          ... on PullRequestReview {
            id databaseId body state createdAt submittedAt lastEditedAt url
            author { __typename login avatarUrl }
            viewerCanUpdate
            reactionGroups { content viewerHasReacted reactors { totalCount } }
            commit { oid }
          }
          ... on HeadRefForcePushedEvent { id createdAt actor { __typename login avatarUrl } beforeCommit { oid } afterCommit { oid } }
          ... on LabeledEvent { id createdAt actor { __typename login avatarUrl } label { name color } }
          ... on UnlabeledEvent { id createdAt actor { __typename login avatarUrl } label { name color } }
          ... on AssignedEvent { id createdAt actor { __typename login avatarUrl } assignee { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login } } }
          ... on UnassignedEvent { id createdAt actor { __typename login avatarUrl } assignee { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login } } }
          ... on ReviewRequestedEvent { id createdAt actor { __typename login avatarUrl } requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { name } } }
          ... on ReviewRequestRemovedEvent { id createdAt actor { __typename login avatarUrl } requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { name } } }
          ... on RenamedTitleEvent { id createdAt actor { __typename login avatarUrl } previousTitle currentTitle }
          ... on ReadyForReviewEvent { id createdAt actor { __typename login avatarUrl } }
          ... on ConvertToDraftEvent { id createdAt actor { __typename login avatarUrl } }
          ... on MergedEvent { id createdAt actor { __typename login avatarUrl } commit { oid } mergeRefName }
          ... on ClosedEvent { id createdAt actor { __typename login avatarUrl } }
          ... on ReopenedEvent { id createdAt actor { __typename login avatarUrl } }
          ... on HeadRefDeletedEvent { id createdAt actor { __typename login avatarUrl } headRefName }
          ... on HeadRefRestoredEvent { id createdAt actor { __typename login avatarUrl } }
          ... on BaseRefChangedEvent { id createdAt actor { __typename login avatarUrl } previousRefName currentRefName }
          ... on CrossReferencedEvent { id createdAt actor { __typename login avatarUrl } willCloseTarget source { __typename ... on Issue { number title url repository { name owner { login } } } ... on PullRequest { number title url repository { name owner { login } } } } }
          ... on ReviewDismissedEvent { id createdAt actor { __typename login avatarUrl } dismissalMessage }
          ... on AutoMergeEnabledEvent { id createdAt actor { __typename login avatarUrl } }
          ... on AutoMergeDisabledEvent { id createdAt actor { __typename login avatarUrl } }
        }
      }
    }
  }
}
```

Mapping rules (put them in `ResponseMapping`, each a small `static func`):

| `__typename` | becomes |
| --- | --- |
| `IssueComment` | `.comment(ConversationComment)`; `isEdited = lastEditedAt != nil`; `minimizedReason` lowercased; `isMinimized ?? false` |
| `PullRequestReview` | `.review(ConversationReview)`; `createdAt = submittedAt ?? createdAt`; state `APPROVED`→`.approved`, `CHANGES_REQUESTED`→`.changesRequested`, `DISMISSED`→`.dismissed`, `PENDING`→`.pending`, anything else→`.commented`; `commitOid = commit.oid` |
| `LabeledEvent` / `UnlabeledEvent` | `.labeled/.unlabeled(name:color:)`; no label name → item dropped |
| `AssignedEvent` / `UnassignedEvent` | `.assigned/.unassigned(login:)`; no assignee login → dropped |
| `ReviewRequestedEvent` / `ReviewRequestRemovedEvent` | `.reviewRequested/.reviewRequestRemoved(reviewer:)` = `login` or a Team's `name`; neither → dropped |
| `RenamedTitleEvent` | `.renamed(from: previousTitle, to: currentTitle)`; either missing → dropped |
| `ReadyForReviewEvent`, `ConvertToDraftEvent`, `ClosedEvent`, `ReopenedEvent`, `HeadRefRestoredEvent`, `AutoMergeEnabledEvent`, `AutoMergeDisabledEvent` | the matching value-less case |
| `MergedEvent` | `.merged(commitOid: commit.oid, into: mergeRefName)` |
| `HeadRefDeletedEvent` | `.headRefDeleted(branch: headRefName)` |
| `BaseRefChangedEvent` | `.baseRefChanged(from: previousRefName, to: currentRefName)` |
| `HeadRefForcePushedEvent` | `.forcePushed(fromOid: beforeCommit.oid, toOid: afterCommit.oid)` |
| `CrossReferencedEvent` | `.crossReferenced(ConversationReference(repo:, number:, title:, isPullRequest: source.__typename == "PullRequest", url:), willClose: willCloseTarget ?? false)`; source without number/repository → dropped |
| `ReviewDismissedEvent` | `.reviewDismissed(message: dismissalMessage)` |
| anything else, or a node without `id`/`createdAt` | dropped |

- Events: `actor` through `makeActor(from:detector:)`; a `nil` actor stays `nil`.
- `reactionGroups` → `[ReactionGroup]` keeping only `reactors.totalCount > 0`; unknown `content` dropped.
- Pages: request with `before: null`, then `before: startCursor` while `hasPreviousPage` and fewer than **5** pages read. Each page's nodes are oldest-first; the pages arrive newest-first, so `items = pages.reversed().flatMap { $0 }`. `hasEarlierItems = (last page read).hasPreviousPage == true`.
- The description fields come from the **first** page's `pullRequest` object: `descriptionReactions`, `isDescriptionEdited = lastEditedAt != nil`, `viewerCanUpdateDescription = viewerCanUpdate ?? false`, `viewerCanReact = viewerCanReact ?? false`.
- `pullRequest == nil` → throw `GitHubError.notFound(resource:)`, as `headRefOid` does.
- One `DTO` struct for a timeline node with every field optional (the fragments share field names with the same types, which is why the live query validated). Name it `TimelineItemDTO`.

`reviewThreads` comment nodes gain:

```graphql
                nodes {
                  id
                  databaseId
                  body
                  createdAt
                  lastEditedAt
                  url
                  viewerCanUpdate
                  viewerCanDelete
                  pullRequestReview { id }
                  author { __typename login avatarUrl }
                  reactionGroups { content viewerHasReacted reactors { totalCount } }
                }
```

`fetchDetail` adds, beside `closing`:

```swift
        // Tolerated, like the closing issues (ADR 0043): a conversation that could not be read is
        // `nil`, which the store reads as "unknown" and does not write over the copy it has.
        async let conversationRead: PullRequestConversation? = try? pullRequestConversation(
            repo: repo,
            number: number
        )
```

and passes `conversation: await conversationRead` to `PullRequestDetail`.

- [ ] **Step 1: Fixtures.** Hand-write `pull-conversation.json`: `{"data":{"repository":{"pullRequest":{…}}}}` with `viewerCanUpdate: true`, `viewerCanReact: true`, `lastEditedAt` set, description reaction groups (all eight, `THUMBS_UP` 2 with `viewerHasReacted: true`, `HEART` 1, the rest 0), `pageInfo {hasPreviousPage:false}`, and one node of **every** typename in the table plus one `"__typename":"SubscribedEvent"` node that must be dropped. Use schnaq names (`n2o`, `claude[bot]` with `"__typename":"Bot"`, repository `schnaq/review`), never copied third-party text. `pull-conversation-page-newest.json` (two comments, `hasPreviousPage: true`, `startCursor: "CUR1"`) and `pull-conversation-page-oldest.json` (one comment, `hasPreviousPage: false`). Add `lastEditedAt`, `url`, `viewerCanUpdate`, `viewerCanDelete`, `pullRequestReview {id}` and a reaction group to the first comment of `review-threads.json`.
- [ ] **Step 2: Failing tests** in `ConversationParsingTests.swift` (pattern: `DetailParsingTests`, `MockTransport.route("ShepherdPullRequestConversation", …)`, `GitHubClient.makeForTesting(transport:)`):
  - `testMapsEveryItemKindInGitHubsOrder` — count = typenames in the table, order kept, the `SubscribedEvent` gone.
  - `testMapsACommentWithItsFlagsReactionsAndMinimizedState` — `databaseID`, `isEdited`, `url`, `reactions` without zero groups, `viewerCanUpdate/Delete`, `isMinimized`, and `minimizedReason == "off-topic"` for a fixture value of `"OFF-TOPIC"` (GitHub documents lowercase words; the mapping lowercases anyway).
  - `testMapsAReviewDatedBySubmissionWithItsState` — `createdAt == submittedAt`, `.changesRequested`, `commitOid`.
  - `testMapsEventsToValues` — one assert per event case, incl. a Team reviewer's `name` and a Bot actor's provenance (`actor?.kind.agentIdentity != nil` for `claude[bot]`).
  - `testReadsTheDescriptionsReactionsAndPermissions`.
  - `testReadsPagesNewestFirstAndAssemblesThemOldestFirst` — two routed responses in order (newest, oldest); assert the second request's body contains `"before":"CUR1"`, items = oldest + newest, `hasEarlierItems == false`.
  - `testStopsAfterFivePagesAndSaysThereIsMore` — route the newest page (hasPreviousPage true) as the only response (it repeats); assert 5 GraphQL requests and `hasEarlierItems == true`.
  - In `DetailParsingTests`: `testDetailFetchCarriesTheConversation` (route it) and `testAConversationThatCannotBeReadLeavesTheDetailIntact` (no route → 501 → `conversation == nil`, files/threads still there). Extend the threads assertions: first comment's `reviewID`, `isEdited`, `url`, `reactions`, `viewerCanUpdate`.
- [ ] **Step 3: Run** `cd Packages/ShepherdKit && swift test --filter "ConversationParsingTests|DetailParsingTests"` — expect compile failure / FAIL.
- [ ] **Step 4: Implement** the document, DTOs, mapping and client method as specified.
- [ ] **Step 5: Run** the same filter, then the whole `swift test` — expect PASS.
- [ ] **Step 6: Commit** `feat(github): read the conversation timeline and richer review threads (ADR 0043)`.

---

### Task 3: Persistence — migration v11

**Files:**
- Modify: `Packages/ShepherdKit/Sources/ShepherdPersistence/DatabaseManager.swift` (register `"v11"`, `DatabaseSchema.addV11`)
- Modify: `Packages/ShepherdKit/Sources/ShepherdPersistence/Records.swift` (`PullRequestRecord.conversationJSON` carried in `init(summary:existing:)`, `conversation` accessor; `ReviewCommentRecord` new columns both ways)
- Modify: `Packages/ShepherdKit/Sources/ShepherdPersistence/InboxStore.swift` (save: write `conversationJSON` **only when `detail.conversation != nil`**; fetch: `conversation: record.conversation`)
- Create: `Packages/ShepherdKit/Tests/ShepherdPersistenceTests/ConversationStoreTests.swift`
- Modify: `docs/ARCHITECTURE.md` (schema section: v11 columns, one line each)

**Interfaces:**
- Consumes: `PullRequestDetail.conversation`, the `ReviewComment` extras.
- Produces: `fetchPullRequestDetail(id:)` and `observePullRequestDetail(prID:)` return the conversation and the comment extras exactly as saved.

```swift
    /// v11 (ADR 0043): the conversation tab. The timeline is one JSON document beside the other
    /// detail collections; a review comment's review, reactions and the viewer's permissions are
    /// columns, because a thread is rebuilt row by row.
    static func addV11(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE pull_requests ADD COLUMN conversationJSON TEXT")
        try db.execute(sql: "ALTER TABLE review_comments ADD COLUMN reviewID TEXT")
        try db.execute(sql: "ALTER TABLE review_comments ADD COLUMN reactionsJSON TEXT")
        try db.execute(sql: "ALTER TABLE review_comments ADD COLUMN viewerCanUpdate INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE review_comments ADD COLUMN viewerCanDelete INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE review_comments ADD COLUMN isEdited INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE review_comments ADD COLUMN url TEXT")
    }
```

- [ ] **Step 1: Failing tests** (pattern: `PersistenceTestSupport.swift`, `DatabaseManagerTests`):
  - `testADetailRoundTripsItsConversationAndTheCommentExtras` — save a detail with a conversation of one comment, one review, one `.labeled` event and a thread whose comment has `reviewID`, two reactions, both flags, `isEdited`, `url`; fetch; `XCTAssertEqual(fetched.conversation, saved.conversation)` and the comment equal.
  - `testADetailWithoutAConversationKeepsTheStoredOne` — save with a conversation, save again with `conversation: nil`, fetch → still the first.
  - `testASweepUpsertKeepsTheConversation` — save detail with a conversation, then the sweep's summary save for the same row (the call `saveSummaries`/whatever `InboxStore` line 97 belongs to), fetch → conversation intact.
  - `testAnEmptyConversationIsStoredAsEmptyNotAsUnknown` — `PullRequestConversation()` saved over a non-empty one replaces it.
- [ ] **Step 2: Run** `cd Packages/ShepherdKit && swift test --filter ConversationStoreTests` — expect FAIL.
- [ ] **Step 3: Implement** v11 and the record/store changes.
- [ ] **Step 4: Run** the filter, then all of `swift test` — expect PASS (existing migration tests must still pass).
- [ ] **Step 5: Commit** `feat(persistence): store the conversation (migration v11, ADR 0043)`.

---

### Task 5: The app — the tab, the stream, the composer

**Files:**
- Modify: `Shepherd/Features/PullRequest/ConversationView.swift`
- Create: `Shepherd/Features/PullRequest/ConversationStreamViews.swift`
- Create: `Shepherd/Features/PullRequest/ConversationEventText.swift`
- Create: `Shepherd/Features/PullRequest/ConversationComposer.swift`
- Create: `Shepherd/Features/Review/ThreadReplyBar.swift`
- Modify: `Shepherd/Features/Review/ReviewComposer.swift` (ThreadPopover → ThreadReplyBar; ThreadCommentView shows *edited* and reactions)
- Modify: `Shepherd/Features/Review/ReviewModel.swift`
- Modify: `Shepherd/Features/PullRequest/PullRequestActions.swift`, `Shepherd/App/ActionActivity.swift`
- Modify: `Shepherd/Resources/Localizable.xcstrings`, `Scripts/check-type-scale.py`, `Scripts/check-localization.py` (only if a new `Int` interpolation needs `INTEGER_EXPRESSIONS`)
- Modify: `Shepherd/Debug/DemoSeed.swift`, `Shepherd/Support/DesignComponents.swift` (`ComposerTextEditor.focusRequest`)
- Create: `ShepherdTests/ConversationEventTextTests.swift`

**Interfaces:**
- Consumes: `ConversationTimeline.entries(conversation:commits:threads:)`, `ConversationEntry`, `PullRequestDetail.conversation`, `ReviewComment.reactions/isEdited/url`, `ReactionContent.emoji`.
- Produces (inside the app):
  - `ReviewModel.conversationEntries: [ConversationEntry]` — recomputed in `apply(_:)` and `refresh(_:replacing:)` only (never in a getter).
  - `ReviewModel.conversationDraft: String` — the composer's text; read only by `ConversationComposer`, so typing does not redraw the stream. Survives switching tabs.
  - `ReviewModel.quote(_ markdown: String)` — appends `markdown` quoted (`> ` per line, blank line after) to `conversationDraft` and bumps `ReviewModel.composerFocusRequest: Int`.
  - `ActionActivity.Kind.comment` (new case: a comment on the pull request's conversation).
  - `PullRequestActions.comment(on:body:) async -> OutboxWriteOutcome?` (`@discardableResult`; runs under `activity.run(summary.id, .comment)`; `nil` = nothing written), `reply(on:commentDatabaseID:body:) async -> OutboxWriteOutcome?`, `setThread(on:threadID:resolved:) async -> OutboxWriteOutcome?` — same bodies as today plus the return value.
  - `ThreadReplyBar(thread:summary:actions:onDone:)` where `onDone: @MainActor (OutboxWriteOutcome?) -> Void` is called after a reply or a resolve toggle.
  - `ConversationEventText.sentence(for: ConversationEventItem) -> String`, `.symbol(for: ConversationEvent) -> String`, `.tint(for: ConversationEvent) -> Color` — pure, `static`.
- Removes: `ReviewModel.unanchoredThreads` (no caller left), the *Activity*, *Commits* and *Conversations not on the current diff* cards and their strings.

**The tab, top to bottom** (`ConversationView.body`, inside the existing `ScrollView`/`VStack(spacing: 16)`, max width 860, wrapped in a `ScrollViewReader`):
1. unchanged: `claimsCard`, `recurringFinding`, `closingIssues`, `stack`.
2. `DescriptionPostView` — a post (below) for the description: author `summary.author`, date `summary.createdAt`, verb "opened this pull request", body `detail.bodyMarkdown` or the muted "No description.", `isEdited = conversation?.isDescriptionEdited`, reactions `conversation?.descriptionReactions`, link = `AppConfig.pullRequestURL(...)`.
3. When `conversation?.hasEarlierItems == true`: one muted row "Earlier activity is on GitHub" with a link button to the pull request.
4. `ForEach(model.conversationEntries)` → one view per case (below).
5. `checks` (unchanged, including the *Why?* diagnosis card).
6. `ConversationComposer` (id `"composer"`; `.onChange(of: model.composerFocusRequest)` scrolls to it).

**A post** (`ConversationPostView`, used for the description, comments and review bodies): `Card` containing a header `HStack` — `AvatarView(actor:size: 24)`, name (`Theme.type(.callout, weight: .semibold)`, `Theme.textStrong`), agent `ChipView` when `author.kind.agentIdentity != nil`, the verb text muted, `RelativeDateText(date:style: .long)`, "edited" muted when edited, `Spacer`, a `Menu` (ellipsis, borderless, `.menuIndicator(.hidden)`) with **Quote reply** (`model.quote(body)`), **Copy link** (when url; `NSPasteboard`), **Open on GitHub** (when url; `NSWorkspace.shared.open`) — then `TranslatableMarkdownText(markdown:translations:)`, then `ReactionSummaryView` when there are reactions. Accessibility: `.accessibilityElement(children: .contain)`, label "<name>, <verb>, <relative date>".
- A comment with `isMinimized` shows only a muted row "Hidden — <reason>" ("off-topic", "outdated", "resolved", "duplicate", "spam", "abuse" each localized; unknown/nil → "Hidden comment") and a **Show** button revealing the post (per-view `@State`).

**`ReactionSummaryView`** (read-only in A): an `HStack` of capsules `"\(emoji) \(count)"`, `Theme.type(.subheadline)`, background `Theme.chipBackground(Theme.accentText)` when `viewerHasReacted`, else `Theme.control`, `Theme.border` stroke. Spoken label per capsule from a localized name for each `ReactionContent` ("Thumbs up", "Thumbs down", "Laugh", "Hooray", "Confused", "Heart", "Rocket", "Eyes") plus "\(count) reactions" (plural variation) plus ", including yours" when `viewerHasReacted`.

**A review** (`ConversationReviewView`): a header row with `AvatarView` 24, name, the state sentence — approved → "approved these changes" (`Theme.success`, `checkmark.circle.fill`), changesRequested → "requested changes" (`Theme.failure`, `exclamationmark.circle.fill`), commented → "reviewed" (`Theme.accentText`, `eye`), dismissed → "reviewed — dismissed" (`Theme.textMuted`), pending → "has a pending review" (`Theme.pending`) — and the date. When the body is not blank: a post body (the same `ConversationPostView` content without repeating the header — give `ConversationPostView` a `showsHeader` flag). Then each thread as `ConversationThreadView`, indented 16.

**A thread** (`ConversationThreadView`, also used for `.thread(_)` entries): a `Card` with a header: `doc.text` icon, `Text(path)` in `Theme.mono(.subheadline)` truncating at the head, "line \(line)" or "was line \(originalLine)" muted (reuse the existing strings `"line \(line)"` and `"· was line \(original)"` where they fit), chips *outdated* / *resolved* (existing strings), and — when `thread.isAnchoredInCurrentDiff` — a **Show in diff** button calling `model.reveal(path:line:)`. Collapsed by default when resolved or outdated (a chevron toggles; per-view `@State`). Expanded: `ThreadCommentView` for each comment, then `ThreadReplyBar(... onDone: { outcome in if case .sent? = outcome { model.load() } })`.

**`ThreadReplyBar`** — lift `ThreadPopover.replyBar` with its state (`replyText`, saved-reply suggestions, `isReplying`, `isTogglingThread`, `replyTargetID`, `requestSavedReplySuggestions`) into its own view verbatim; `sendReply` and the resolve button call `onDone(outcome)` instead of `onClose()`. `ThreadPopover` uses it with `onDone: { _ in onClose() }`.

**Commits** (`ConversationCommitsView`): a compact row group without a card: header "`<name>` added `n` commits" when every commit has the same `author` (plural variation), else "`n` commits" (plural variation), `circle.fill` muted; then per commit `Text(verbatim: String(oid.prefix(7)))` in `Theme.mono(.subheadline)` `Theme.accentText`, headline `Theme.type(.callout)` line-limited to 2, trailers joined by " · " in `Theme.mono(.footnote)` muted, `RelativeDateText` muted.

**An event** (`ConversationEventRow`): `HStack(alignment: .firstTextBaseline)` — `Image(systemName: ConversationEventText.symbol(...))` tinted, the sentence `Theme.type(.callout)` `Theme.textSecondary`, `RelativeDateText` muted; `.accessibilityElement(children: .combine)`. A cross-reference row is a `Button` (`RowButtonStyle`) opening its url.

**`ConversationEventText.sentence`** — `actor` is `item.actor?.bestName ?? String(localized: "Someone")`:

| event | English source string |
| --- | --- |
| labeled | `"\(actor) added the label \(name)"` |
| unlabeled | `"\(actor) removed the label \(name)"` |
| assigned (login == actor login) | `"\(actor) self-assigned this"` |
| assigned | `"\(actor) assigned \(login)"` |
| unassigned | `"\(actor) unassigned \(login)"` |
| reviewRequested | `"\(actor) requested a review from \(reviewer)"` |
| reviewRequestRemoved | `"\(actor) removed the review request for \(reviewer)"` |
| renamed | `"\(actor) changed the title from „\(from)“ to „\(to)“"` — English source uses straight quotes: `"\(actor) changed the title from \"\(from)\" to \"\(to)\""` |
| readyForReview | `"\(actor) marked this pull request as ready for review"` |
| convertedToDraft | `"\(actor) converted this pull request to a draft"` |
| merged with `into` | `"\(actor) merged commit \(shortOid) into \(into)"`; without → `"\(actor) merged this pull request"` |
| closed | `"\(actor) closed this pull request"` |
| reopened | `"\(actor) reopened this pull request"` |
| headRefDeleted | `"\(actor) deleted the branch \(branch)"`; nil branch → `"\(actor) deleted the head branch"` |
| headRefRestored | `"\(actor) restored the head branch"` |
| baseRefChanged | `"\(actor) changed the base branch from \(from) to \(to)"` (missing side → `"\(actor) changed the base branch"`) |
| forcePushed | `"\(actor) force-pushed from \(short(from)) to \(short(to))"` (either missing → `"\(actor) force-pushed the branch"`) |
| crossReferenced | `"\(actor) mentioned this in \(slug) \(title)"` with `slug = "\(repo.fullName)#\(number)"` built as a `String`, never an `Int` interpolation |
| reviewDismissed | `"\(actor) dismissed a review"` + `": \(message)"` appended outside the localized string when present |
| autoMergeEnabled / Disabled | `"\(actor) enabled auto-merge"` / `"\(actor) disabled auto-merge"` |

Symbols: labeled/unlabeled `tag`, assigned/unassigned `person`, reviewRequested/Removed `eye`, renamed `pencil`, readyForReview `eye`, convertedToDraft `pencil.circle`, merged `arrow.triangle.merge` (`Theme.success`), closed `xmark.circle` (`Theme.failure`), reopened `arrow.clockwise.circle` (`Theme.success`), headRefDeleted/Restored `arrow.branch`, baseRefChanged `arrow.left.arrow.right`, forcePushed `arrow.up.circle`, crossReferenced `link`, reviewDismissed `xmark.circle`, autoMerge `arrow.triangle.merge`. Everything not listed tints `Theme.textMuted`.

**`ConversationComposer`** (`@Bindable var model: ReviewModel`, `actions`, `summary`): a `Card` with `CardTitle(String(localized: "ADD A COMMENT"))`, `ComposerTextEditor(text: $model.conversationDraft, height: 96, imageUpload: ImageUploadTarget(repo: summary.repo, actions: actions), focusRequest: model.composerFocusRequest)` — add that last parameter to `ComposerTextEditor` in `Shepherd/Support/DesignComponents.swift` (`var focusRequest: Int = 0`, and `.onChange(of: focusRequest) { isFocused = true }` on the `TextEditor`; every existing call site keeps its default), a row: `SavedReplyMenu(replies: environment.settings.usableSavedReplies, suggestedIDs: [], onInsert: { model.conversationDraft = SavedReply.inserting($0, into: model.conversationDraft) }, onWillOpen: {}, height: 30)`, `Spacer`, and — only while the pull request is open (not `model.notice == .merged/.closed`) — the secondary close button with the **existing** strings `"Comment and close"` / `"Close without a comment"`, then the primary **existing** `"Post comment"` button with `.keyboardShortcut(.return, modifiers: .command)`, disabled while the text is blank or `PastedImage.containsPendingUpload`, `.busy(actions.activity.isRunning(summary.id, .comment))`. Post: take the text; `let outcome = await actions.comment(on: summary, body: text)`; when `outcome != nil` and not `.failed`, clear the draft if it still equals the text that was sent; when `.sent`, `model.load()`. Close: as the sheet does (`actions.close(summary, comment:)`), clear the draft.

**`ThreadCommentView`** gains: " · edited" muted after the date when `comment.isEdited`, and `ReactionSummaryView(reactions: comment.reactions)` under the body when non-empty.

**DemoSeed**: give the detailed demo pull request a `PullRequestConversation` with a human comment, an agent (`claude[bot]`) comment with a `<!-- marker -->` and a `<details>` block, an approved review with body, a changes-requested review that started one of the existing demo threads (set that thread's first comment `reviewID`), a labeled event, a review-requested event, a force-push, description reactions (👍 2 incl. viewer) — and `reviewID` on the thread comments it already seeds.

- [ ] **Step 1: Failing test** `ShepherdTests/ConversationEventTextTests.swift`: one assertion per event row above (English; the app tests run with `-testLanguage en`), the self-assign case, the nil-actor "Someone" case, a merged event without `into`, and that a cross-reference sentence contains `schnaq/review#1024` (no grouping).
- [ ] **Step 2: Implement** `ConversationEventText`, then `ActionActivity.Kind.comment` and the three `PullRequestActions` return values, then `ReviewModel` (`conversationEntries`, `conversationDraft`, `composerFocusRequest`, `quote(_:)`, remove `unanchoredThreads`), then `ThreadReplyBar` (+ ThreadPopover on it), then the views, then `ConversationView`.
- [ ] **Step 3: Strings.** Add every new string with its German row to `Localizable.xcstrings` (plural variations for the two commit headers and the reaction count); delete the rows of strings no call site produces any more (`ACTIVITY`, `COMMITS · %lld`, `No commits fetched yet.`, `CONVERSATIONS NOT ON THE CURRENT DIFF`, `DESCRIPTION` if unused — let the script tell you). Add the new files to `MIGRATED` in `Scripts/check-type-scale.py`. Run `python3 Scripts/check-localization.py && python3 Scripts/check-type-scale.py` — expect `OK`.
- [ ] **Step 4: Build.** `git add -A` (stage the catalog first), `xcodegen generate`, then `xcodebuild -project Shepherd.xcodeproj -scheme Shepherd -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/app CODE_SIGNING_ALLOWED=NO build` — expect `** BUILD SUCCEEDED **`; then `git checkout -- Shepherd/Resources/Localizable.xcstrings Shepherd/Resources/AppShortcuts.xcstrings` to drop Xcode's catalog rewrite, and re-run the two Python checks. Also build the test bundle: same command with `build-for-testing` — expect success (the app tests themselves run in CI).
- [ ] **Step 5: Commit** `feat(review): the conversation tab shows the whole conversation (ADR 0043)`.

---

### Task 6: Documentation (lead, while Tasks 2, 3 and 5 run)

**Files:** `docs/FEATURES.md` (rewrite the *Conversation* paragraphs under *Review*), `CONTRIBUTING.md` (host list: the conversation read on the detail fetch), `docs/PRIVACY.md` (if it enumerates detail reads), `site/content/docs/**` English and German review pages, `docs/adr/0043` (only if implementation forced a change).

- [ ] Write, run `python3 Scripts/check-localization.py`, commit `docs: the conversation tab (ADR 0043)`.

### Task 7: Integration (lead)

- [ ] Merge the task branches, `swift test`, both Python checks, `mise run build` and `build-for-testing`, demo-mode look at the tab if Screen Recording allows, `/simplify`, Sonnet code review, PR, CI green, merge, release 1.12.0, cask.
