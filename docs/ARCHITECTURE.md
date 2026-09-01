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
    Delegation/                #   delegate-to-local-agent model + sheet (ADR 0011)
    Settings/                  #   accounts, agent registry, AI, delegation, appearance
    Onboarding/                #   device-flow sign-in, PAT entry
  Intelligence/                #   IntelligenceProvider impls (FoundationModels, Anthropic)
  Support/                     #   AppConfig, keyboard shortcuts, theming, notifications
    AgentCLI/                  #   agent-CLI engine: config, locator, stream parser, worktrees
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
- `loadFile` `{path, language, original, modified, mode: "sideBySide"|"inline", wrap, commentableLines?}`
  - `commentableLines` is `{left: [Int], right: [Int]}` — the 1-based lines of each document
    that came from the patch. Swift reconstructs both sides from GitHub's unified diff and
    pads the gaps between hunks with blank lines so absolute line numbers still match
    GitHub's; those fillers are indistinguishable from real content in the model, and GitHub
    rejects an *entire* review when one `comments[].line` is not part of the diff. The viewer
    therefore arms the gutter “+” only on the listed lines of the hovered side.
  - The field is **optional and additive** — omitting it means "every line" — so `v` stays 1.
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
  var kind: IntelligenceKind { get }        // .onDevice / .anthropic / .openAICompatible
  var isAvailable: Bool { get async }
  func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary
  func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint]
}
```

Three provider implementations: `OnDeviceProvider` (Foundation Models),
`AnthropicProvider` (BYOK, `claude-haiku-4-5` default), and `OpenAICompatibleProvider`
(user-configured base URL + key + model — chat-completions shape; covers EU-hosted
providers such as konduit.eu and local servers like Ollama). API keys live in the Keychain
alongside GitHub tokens; the non-secret half of the configuration (mode, provider kind,
endpoint preset, base URL, model name) lives in `AppSettings`/`UserDefaults`.

The OpenAI-compatible tier has two conveniences on top of the free-form configuration, both
additive and both without an endpoint-specific code path (ADR 0007 amendment):
`IntelligenceEndpointPreset` (`konduitEU` / `ollamaLocal` / `custom`) only prefills the base URL
and supplies the settings copy — note, key-console link, placeholders — and
`OpenAICompatibleProvider.availableModels()` fetches `GET {base}/models`, parsed by the pure
`OpenAIModelsResponse`, to turn the model field into a picker. Discovery is best-effort: any
failure, an unknown shape or an empty list falls back to the free-text model field, and a model
the endpoint did not list stays selectable. `ModelListing` is the seam the settings tests drive
instead of a network.

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
unavailable. Therefore: `Packages/ShepherdKit` must build and test with plain `swift test` on
**both macOS and Linux**. GRDB has shipped SwiftPM support for Linux since 7.10 (community
supported); the Linux CI job installs `libsqlite3-dev` for GRDB's system-SQLite target, and
the persistence tests use an in-memory `DatabaseQueue` so they behave identically on both
platforms. `web/diff-viewer` builds and tests with Node 22. The app target compiles only on
macOS — CI runs `xcodegen` + `xcodebuild` on a macOS runner as the gate.

## App layer (`Shepherd/`)

The app target owns every Apple-only framework and all UI. Decisions worth knowing:

### State machine and dependency container

`AppEnvironment` (`@MainActor @Observable`) is the container and the top-level state machine:
`launching → signedOut → signedIn(SignedInSession)`. Everything that needs a token, a
database or the network lives in `SignedInSession`, so those things cannot exist in the
signed-out state. `SignedInSession.make(…)` wires the stack in the order
`Packages/ShepherdKit/README.md` prescribes: `DatabaseManager` → `GitHubClient`
(`KeychainTokenStore` behind `RefreshingTokenProvider`, `DatabaseConditionalCache`,
`AgentDetector` seeded with the user's registry overrides) → `SyncEngine`.

Within the signed-in window a second, smaller route drives the screen: `.inbox` or
`.review(prID)`. The review screen is full-window (as in the mockups) rather than a third
navigation column.

### Views render from the database, never from the network

`InboxModel` subscribes to `DatabaseManager.observeInbox()`; `ReviewModel` subscribes to
`observeDraft(prID:)`. Detail fetches read the cached `PullRequestDetail` first and only then
refresh from GitHub, so opening a pull request offline shows the last-known state instead of a
spinner (ADR 0006). Grouping uses `InboxGrouper`; the sort order inside a section is applied by
the app on top of it (`priority` / `recentlyUpdated` / `oldestFirst`), with a deterministic
`InboxModel.priorityScore` so two sweeps of the same data never reshuffle the list.

### All writes go through the outbox

`PullRequestActions` is the single write surface (`submitReview`, `reply`, `setThread`,
`merge`, `markReadyForReview`). Every one of them enqueues an `OutboxItem` and then asks the
sync engine to drain, so a queued approval survives a crash, a quit or an offline period. The
app never calls a `GitHubClient` mutation directly. `SyncEvent.draftConflict` surfaces as an
alert offering to re-open the review rather than submitting against the wrong commit.

Two GitHub capabilities the UI wants are *not* modelled by the outbox, and the app does not
pretend otherwise: deleting the head branch after a merge (the merge sheet shows the toggle
disabled with an explanation), and dismissing an existing review.

### Diff viewer: reconstructing both sides from the patch

`ChangedFile.patch` is a unified diff; Monaco wants two documents. `PatchReconstructor` builds
them from the hunks: context lines go to both sides, `-` lines only to the original, `+` lines
only to the modified, and **the gaps between hunks are padded with empty lines on both sides**.
The padding is what keeps 1-based line numbers identical to GitHub's — review threads and draft
comments are anchored by absolute line number, so an off-by-N would attach comments to the
wrong lines. Because the filler is identical on both sides, the diff editor treats it as
unchanged and never highlights it. When `patch` is `nil` (binary or truncated) the webview is
not created at all; a native `DiffUnavailableView` takes its place.

`MarkdownHTML` is the Swift half of the bridge's `bodyHTML` contract: it escapes everything
first and then emits a fixed, tiny tag set (`p`, `br`, `code`, `pre`, `strong`, `em`, `ul`,
`li`, `blockquote`, `a` with an **https-only** `href`). There is no raw-HTML passthrough. The
PR description, which never leaves the app, is rendered natively with `AttributedString`
instead.

### Intelligence

`IntelligenceRouter` is a `Sendable` value rebuilt from `AppSettings` plus the Keychain
whenever the settings change. It picks the tier, builds the digest with the *provider's* token
budget (`TokenBudget.onDevice` ≈ 6K for Foundation Models, `TokenBudget.cloud` for BYOK) and
degrades cloud → on-device → nothing. Results are returned as an `IntelligenceOutcome`, so the
UI can say *why* a card is missing instead of silently hiding it. All FoundationModels usage is
confined to `Intelligence/OnDeviceProvider.swift`, guarded by
`SystemLanguageModel.default.availability`, and file paths a model invents are dropped before
they reach the UI.

### Keyboard model

`KeySequenceState` is a pure value type implementing the two-keystroke commands (`r a`, `r x`,
`r c`, `g a/r/s`) with a 1.5 s prefix timeout; views feed it characters from
`onKeyPress(phases:)`. Menu commands and the ⌘K palette do not act directly — they raise an
`AppEnvironment.PendingAction`, which the screen that owns the selection consumes. That keeps
one implementation of "approve" for the menu bar, the palette, the shortcut and the button.

### Delegation to a local agent (ADR 0011)

The feature is split in two, and the split is what makes it testable. `Support/AgentCLI/` is the
**engine** and imports no SwiftUI: `AgentCLIConfiguration` (the command shape and the
guardrails — permission mode, `--allowedTools`, `--max-turns`, `--max-budget-usd`; Claude Code
first-class, any other CLI via a `{prompt}`/`{worktree}` template), `AgentCLILocator`,
`AgentStreamEvent` (a tolerant decoder for the newline-delimited JSON — unknown event types,
unknown content blocks and non-JSON lines are skipped, never fatal), `AgentCLIRunner` (spawns
`Process`, a dedicated queue drains stdout line by line into an `AsyncStream`, `cancel()` sends
`SIGTERM` then `SIGKILL`), and `GitWorktree`. `Features/Delegation/` is the **UI**:
`DelegationModel` (the `idle → preparingWorktree → running → finished/failed/cancelled` state
machine), `DelegationCenter` (one delegation per pull request; a second request while one is
running reveals it instead of starting another) and `DelegationSheet`.

Two seams carry the tests. `ProcessRunning` (`run(executable:arguments:currentDirectory:)`) is
the only way `GitWorktree` reaches git, so the unit tests assert the **exact argv** of every
command — fetch, `worktree add --detach`, status, diff-stat, commit, `push origin HEAD:<branch>`,
`worktree remove --force` — without a repository on disk, including the refusal to delete
anything outside `~/Library/Application Support/Shepherd/Worktrees`. `AgentRunning` is the seam
for the CLI, so the state machine is driven by scripted event lists.

Three rules are not negotiable and are enforced in code, not by convention: **no shell, ever** —
the prompt is one element of an argv array and command templates are split by `ShellWords`, so a
prompt cannot become a second command; **Shepherd never touches agent authentication** — the
child inherits the environment verbatim, nothing added, nothing removed, and there is no
credential field anywhere in the Delegation settings tab; **nothing is ever pushed
automatically** — the agent works in a detached worktree and "Commit & push" is a button, using
the user's own git credentials rather than Shepherd's GitHub token.

The **App Sandbox is off** for this build (`Shepherd/Support/Shepherd.entitlements`, with the
reasoning inline): a sandboxed child process cannot usefully be a coding agent — no network, no
access to the user's CLI configuration, every path needing a bookmark. ADR 0010 already rules
the Mac App Store out for v1, so this costs nothing that was on the table; hardened runtime
stays on.

### Test target

`ShepherdTests` (added to `project.yml`, sources in top-level `ShepherdTests/`) covers the
pure parts of the app: the bridge protocol against the **shared fixtures**, which are copied
into the test bundle as a folder reference from `web/diff-viewer/fixtures` so both languages
decode the same bytes; the patch reconstruction; the Markdown sanitiser; the keyboard,
palette and inbox-ordering logic; the intelligence endpoint layer (preset ↔ base-URL matching,
`/models` parsing against fixtures, and the settings-side discovery gate through `ModelListing`);
and the delegation engine (stream-event fixtures, argv
construction, template splitting, git command sequences, state transitions). The web bundle is likewise added to the app target as a
folder reference (`Shepherd/Resources/DiffViewer`) so `index.html` keeps its relative links.
