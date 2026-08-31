# Shepherd Architecture

This document is the binding contract between Shepherd's modules. If code and this document
disagree, fix one of them in the same PR. Decisions behind this design: [docs/adr](adr).

## Repository layout

```
Shepherd/                      # macOS app target (SwiftUI, macOS 26+)
  App/                         #   @main, AppDelegate glue, DI container (AppEnvironment)
  Features/
    Inbox/                     #   inbox list, sections, filters, command palette actions
    PullRequest/               #   PR detail: header, timeline, file list, checks
    Review/                    #   review composer, pending review UI, thread views
    DiffViewer/                #   WKWebView host + bridge (Swift side)
    Settings/                  #   accounts, agent registry, AI, appearance
    Onboarding/                #   device-flow sign-in, PAT entry
  Intelligence/                #   IntelligenceProvider impls (FoundationModels, Anthropic)
  Support/                     #   AppConfig, keyboard shortcuts, theming, notifications
  Resources/                   #   Assets.xcassets, DiffViewer/dist (built web bundle)
Packages/ShepherdKit/          # SPM package, NO AppKit/SwiftUI imports
  Sources/
    ShepherdCore/              #   domain models, agent detection, heuristics, drafts
    GitHubKit/                 #   GraphQL+REST client, device flow, rate limiting
    ShepherdPersistence/       #   GRDB schema, DAOs, outbox
    ShepherdSync/              #   sync engine orchestrating GitHubKit ⇄ Persistence
  Tests/                       #   unit tests per target (headless, `swift test`)
web/diff-viewer/               # TypeScript Monaco bundle (esbuild) → dist/ (committed)
docs/                          # this file, ADRs, research, roadmap
project.yml                    # XcodeGen spec → Shepherd.xcodeproj (generated, not committed)
```

Dependency rule (arrows = "may import"):

```
Shepherd.app → ShepherdSync → GitHubKit → ShepherdCore
            ↘ ShepherdPersistence ─────↗
```

`ShepherdCore` imports Foundation only. Nothing in `Packages/` imports AppKit, SwiftUI, or
WebKit. The app target owns all UI and all Apple-only frameworks (FoundationModels, WebKit,
UserNotifications, Security/Keychain).

## Core domain models (`ShepherdCore`)

Names are normative; fields listed are the required minimum.

- `Account` — `login`, `avatarURL`, `authKind` (`.deviceFlow` / `.pat`)
- `RepoRef` — `owner`, `name` (Hashable, `fullName`)
- `Actor` — `login`, `displayName?`, `avatarURL?`, `kind: ActorKind`
- `ActorKind` — `.human` | `.bot` | `.agent(AgentIdentity)`
- `AgentIdentity` — `id` (e.g. `"claude-code"`), `displayName`, matched-by signal
- `PullRequestSummary` — inbox row: `id` (GraphQL node id), `repo: RepoRef`, `number`,
  `title`, `author: Actor`, `updatedAt`, `createdAt`, `isDraft`, `additions`, `deletions`,
  `changedFiles`, `headRefName`, `headRefOid`, `baseRefName`, `reviewDecision?`
  (`.approved/.changesRequested/.reviewRequired`), `checkRollup: CheckRollup?`
  (`.success/.failure/.pending/.none` + counts), `myRelation: Set<Relation>`
  (`.reviewRequested/.author/.mentioned/.assigned`), `labels: [String]`,
  `mergeable: Mergeable?` (`.mergeable/.conflicting/.unknown`)
- `PullRequestDetail` — summary + `bodyMarkdown`, `commits: [CommitInfo]`,
  `files: [ChangedFile]`, `threads: [ReviewThread]`, `timeline: [TimelineEvent]`,
  `checks: [CheckRun]`
- `ChangedFile` — `path`, `previousPath?`, `status` (`.added/.modified/.removed/.renamed`),
  `additions`, `deletions`, `patch?` (unified diff hunk text; nil for binary/huge),
  `isViewed: Bool` (local state)
- `ReviewThread` — `id`, `path?`, `line?`, `side` (`.left/.right`), `isResolved`,
  `isOutdated`, `comments: [ReviewComment]`
- `ReviewComment` — `id`, `author: Actor`, `bodyMarkdown`, `createdAt`, `pendingLocalID?`
- `ReviewDraft` — local pending review: `prID`, `verdict?` (`.approve/.requestChanges/.comment`),
  `summaryBody`, `comments: [DraftComment]`, `basedOnHeadOid` (staleness check)
- `DraftComment` — `localID` (UUID), `path`, `line`, `side`, `startLine?`, `body`
- `FilePriority` — `file: ChangedFile`, `score: Double`, `bucket: PriorityBucket`, `reasons: [String]`
- `PriorityBucket` — `.reviewFirst` | `.standard` | `.skim` | `.generated`

Pure logic in `ShepherdCore` (all unit-tested):

- `AgentDetector.detect(author:, branchName:, commitTrailers:) -> ActorKind` — uses the
  bundled `agent-registry.json` (id, displayName, loginPatterns, branchPrefixes, trailers) +
  user extensions. `type == Bot` from the API is authoritative for `.bot`; registry promotes
  to `.agent`.
- `FilePrioritizer.prioritize([ChangedFile], context:) -> [FilePriority]` — deterministic
  scoring: source > tests > config > docs > lockfiles/generated; boosts for security-sensitive
  paths (auth, crypto, CI workflows, Dockerfiles), large single-file churn, deleted tests;
  demotes vendored/generated (linguist-style patterns, `dist/`, `*.lock`, snapshots).
  Reasons are human-readable strings shown in the UI.
- `InboxGrouper` — sections by facet (provenance / repo / review state) + sorting.

## GitHubKit

- `GitHubClient` (actor) — façade over GraphQL + REST with one `URLSession`:
  - `searchOpenPullRequests(queries:) async throws -> [PullRequestSummary]` (GraphQL search,
    ADR 0005)
  - `pullRequestDetail(repo:number:) async throws -> PullRequestDetail`
  - `submitReview(_ draft: ReviewDraft, on:) async throws` — REST
    `POST /pulls/{n}/reviews` with full `comments` array; maps verdict to `event`
  - `replyToComment/resolveThread/unresolveThread/mergePullRequest/markReadyForReview…`
  - `notifications(since:) async throws -> (items, pollInterval)` — honors `X-Poll-Interval`
- `DeviceFlowAuthenticator` — device-code request, user-code presentation callback, poll loop
  with `interval`/`slow_down` handling, returns `TokenSet`; `TokenRefresher` for GitHub App
  refresh tokens.
- `TokenStore` protocol (Keychain impl lives in the app target; tests use in-memory) —
  GitHubKit never touches the Keychain directly.
- Transport policy: ETag/`If-Modified-Since` cache (SQLite-backed via a `ConditionalCache`
  protocol), automatic secondary-rate-limit backoff (`Retry-After`), max 5 concurrent detail
  fetches, request logging hook.

## ShepherdPersistence (GRDB)

Tables mirror core models (`repos`, `pull_requests`, `changed_files`, `review_threads`,
`review_comments`, `review_drafts`, `draft_comments`, `check_runs`, `sync_state`, `outbox`,
`etags`, `viewed_files`, `agent_registry_overrides`). Append-only migrator. `ValueObservation`
publishers feed the UI. The **outbox** stores every outbound mutation (submit review, reply,
resolve, merge) as a row with retry/backoff state so writes survive crash/offline.

## ShepherdSync

`SyncEngine` (actor) runs two loops (ADR 0005): notifications loop (server-governed interval)
and inbox sweep (default 120 s, user-configurable). Delta logic: a PR is re-fetched in detail
only when `updatedAt`/`headRefOid` changed or the user opens it. Emits `SyncEvent`s
(`.newReviewRequest`, `.checksFailedOnOwnPR`, `.prMerged`, …) that the app maps to macOS
notifications. Also drains the outbox with staleness re-validation (draft's `basedOnHeadOid`
vs current head → surface conflict instead of blind submit).

## Diff viewer bridge (Swift ⇄ Monaco)

The web bundle is static, offline, loaded via `WKWebView.loadFileURL`. All messages are JSON,
versioned with `"v": 1`, defined in `web/diff-viewer/src/bridge/protocol.ts` (TypeScript) and
`Shepherd/Features/DiffViewer/BridgeProtocol.swift` (Codable) — **field-for-field identical**;
both sides have decode tests over shared fixture JSON in `web/diff-viewer/fixtures/`.

Swift → web (`postMessage` via `evaluateJavaScript("shepherd.receive(…)")`):
- `loadFile` `{path, language, original, modified, mode: "sideBySide"|"inline", wrap}`
- `setTheme` `{theme: "light"|"dark", fontSize}`
- `setThreads` `{threads: [{id, line, side, resolved, outdated, comments:[{author, bodyHTML, createdAt, isAgent}]}]}`
- `setDraftComments` `{comments: [{localID, line, side, body}]}`
- `revealLine` `{line, side}`

Web → Swift (`window.webkit.messageHandlers.shepherd.postMessage`):
- `ready` `{}` — bundle booted, safe to send
- `addComment` `{line, side, startLine?}` — user clicked a gutter “+”; Swift opens the native
  comment composer (text entry is native, not in the webview)
- `commentClicked` `{threadID | localID}`
- `viewportChanged` `{firstVisibleLine}` (scroll-state restore)

Rules: no remote loads, no eval of dynamic strings, webview has no access beyond its bundle
directory; comment *text entry* is always native SwiftUI so the webview never handles user
keystrokes beyond scrolling/selection.

## Intelligence layer (app target, ADR 0007)

```swift
protocol IntelligenceProvider: Sendable {
  var kind: IntelligenceKind { get }        // .onDevice / .anthropic
  var isAvailable: Bool { get async }
  func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary
  func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint]
}
```

`PullRequestDigest` is built by tier-1 heuristics in `ShepherdCore` (per-file stats, top
hunks, title/body) with an explicit token budget parameter — the on-device provider requests
a small digest (≤ ~6K tokens), the Anthropic provider a large one. Providers are selected in
settings: *Off / On-device / On-device + API key*. AI output is rendered as dismissible hints,
never auto-applied.

## UI conventions

- Linear-inspired: left rail (views/facets), center list, right detail; ⌘K command palette
  exposes every action; `j`/`k` row navigation; two-keystroke review actions
  (`r a` approve, `r c` comment, `r x` request changes, `m` merge dialog); undo toast instead
  of confirm dialogs wherever the action is reversible.
- Dark & light mode from day one: semantic color tokens only (`Color.shepherd*` asset
  catalog), theme piped into Monaco via `setTheme`.
- All strings user-visible in English for v1; localization-ready (`String(localized:)`).

## Verification reality check

Development of this repo happens partly in Linux CI/agent environments where Xcode is
unavailable. Therefore: `Packages/ShepherdKit` must build and test with plain `swift test`
(it may use GRDB — persistence tests are skipped off-macOS via `#if canImport(GRDB)` guards
when needed); `web/diff-viewer` builds and tests with Node 22. The app target compiles only
on macOS — CI runs `xcodegen` + `xcodebuild` on a macOS runner as the gate.
