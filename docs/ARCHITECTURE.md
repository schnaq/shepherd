# Shepherd Architecture

This document is the binding contract between Shepherd's modules. If code and this document
disagree, fix one of them in the same PR. Decisions behind this design: [docs/adr](adr).

## Repository layout

```
Shepherd/                      # macOS app target (SwiftUI, macOS 26+)
  App/                         #   @main, DI container (AppEnvironment), shepherd:// routing
  Features/
    Inbox/                     #   inbox list, sections, filters, command palette actions
    Digest/                    #   morning digest: due-check loop, inbox card, wording
    MenuBar/                   #   menu-bar quick inbox: badge label + mini-inbox window
    PullRequest/               #   PR detail: header, timeline, file list, checks
    Review/                    #   review composer, pending review UI, thread views,
                               #   focus review session (frozen queue + session bar)
    DiffViewer/                #   WKWebView host + bridge (Swift side)
    Delegation/                #   delegate-to-local-agent model + sheet (ADR 0011, 0016);
                               #   session back-channel: decisions + confirmation (ADR 0030)
    Search/                    #   ⌘K semantic search: on-device embedder, index coordinator,
                               #   result row (ADR 0019)
    Settings/                  #   accounts (+ updates, local diagnostics), sync (+ encrypted
                               #   cross-Mac sync), replies (saved replies + review templates),
                               #   agents, AI, delegation, automation, theme (+ menu-bar toggle)
    Onboarding/                #   device-flow sign-in, PAT entry
  Intents/                     #   App Intents (Shortcuts/Siri) + Core Spotlight export of the
                               #   inbox — app target only, the sole importers of AppIntents and
                               #   CoreSpotlight; both route through DeepLink (ADR 0021)
  Automation/                  #   outbound webhook payload, signing, dispatcher (ADR 0012);
                               #   auto-delegation coordinator + ledger store (ADR 0016);
                               #   auto-merge coordinator + ledger/audit store (ADR 0018)
  SettingsSync/                #   encrypted settings document, envelope, SigV4, S3 client (ADR 0014)
  Diagnostics/                 #   MetricKit subscriber + local report folder (ADR 0017)
  Intelligence/                #   IntelligenceProvider impls (FoundationModels, Anthropic)
    Translation/               #     on-device translation of PR text: offer rules, cache, view (ADR 0020)
  Support/                     #   AppConfig, keyboard shortcuts, theming, notifications,
                               #   Sparkle updater wrapper (ADR 0010)
    AgentCLI/                  #   agent-CLI engine: config, locator, stream parser, worktrees
  Resources/                   #   Assets.xcassets, DiffViewer/dist (built web bundle),
                               #   Localizable.xcstrings (en keys + de, ADR 0022)
Packages/ShepherdKit/          # SPM package, NO AppKit/SwiftUI imports
  Sources/
    ShepherdCore/              #   domain models, agent detection, heuristics, drafts
      Agents/                  #     provenance detection + registry (ADR 0008); the
                               #     `Claude-Session:` return address and the message a
                               #     finding becomes (ADR 0030)
      Claims/                  #     claims read from the description + evidence over the diff
                               #     and CI, one line per claim, no score (ADR 0026)
      Review/                  #     saved replies, per-repo review templates + matching rule,
                               #     recurring-finding clustering over the reviewer's own
                               #     comments (ADR 0029)
      Routing/                 #     shepherd:// grammar + CLI argument grammar (ADR 0013)
      Triage/                  #     bulk-triage partition + intended writes (ADR 0015)
      Automation/              #     auto-delegation rules, ledger and policy (ADR 0016);
                               #     auto-merge rules, ledger/audit log and policy (ADR 0018)
      Digest/                  #     morning-digest report + delivery schedule
      Search/                  #     search document, lexical ranker, vector value (ADR 0019)
      Intelligence/            #     the tool contract a model may call, the trace of a
                               #     tool-calling turn, and the Codable twins of the
                               #     generated types — Foundation only, no provider
    GitHubKit/                 #   GraphQL+REST client, device flow, rate limiting
    ShepherdPersistence/       #   GRDB schema, DAOs, outbox
    ShepherdSync/              #   sync engine orchestrating GitHubKit ⇄ Persistence
  Tests/                       #   unit tests per target (headless, `swift test`)
ShepherdCLI/                   # `shepherd` command-line tool: argv → shepherd:// URL (ADR 0013)
web/diff-viewer/               # TypeScript Monaco bundle (esbuild) → dist/ (committed)
Tests/Fixtures/eval/           # intelligence evaluation corpus (JSON), copied into the
                               # ShepherdTests bundle as a folder reference
Scripts/                       # release pipeline: release.sh, Homebrew cask template (ADR 0010);
                               # check-localization.py; eval-intelligence/ (harness contract)
docs/                          # this file, ADRs, research, roadmap, RELEASING.md
project.yml                    # XcodeGen spec → Shepherd.xcodeproj (generated, not committed)
```

Dependency rule (arrows = "may import"):

```
Shepherd.app → ShepherdSync → GitHubKit → ShepherdCore
            ↘ ShepherdPersistence ─────↗
shepherd (CLI) ──────────────────────→ ShepherdCore
```

The CLI's short arrow is a decision, not an accident: it links `ShepherdCore` and nothing else,
so it has no client, no database and no Keychain access, and can reach the app only through the
`shepherd://` scheme (ADR 0013).

`ShepherdCore` imports Foundation only. Nothing in `Packages/` imports AppKit, SwiftUI, or
WebKit. The app target owns all UI and all Apple-only frameworks (FoundationModels, NaturalLanguage,
WebKit, UserNotifications, MetricKit, Security/Keychain). Sparkle is on the same side of that line
and only one file imports it: `Support/UpdateController.swift` (ADR 0010); MetricKit likewise has
exactly one importer, `Diagnostics/DiagnosticsReporter.swift` (ADR 0017), and NaturalLanguage one,
`Features/Search/EmbeddingProvider.swift` (ADR 0019). `Packages/ShepherdKit`
must keep building on Linux, so it never gains an update, a diagnostics or an embedding
dependency — which is why the search *ranker* is in `ShepherdCore` and only the thing that
produces a vector is not.

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
  `mergeable: Mergeable?` (`.mergeable/.conflicting/.unknown`), plus `needsMyReview` — the one
  definition of "somebody is waiting on me", read by the inbox rail's *Needs my review*, the
  menu-bar badge, the focus session's queue and the morning digest, so those four cannot drift
  apart
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
- `SavedReply` (`Review/`) — reusable comment text: `id` (UUID), `name`, `body` (Markdown source)
- `ReviewTemplate` (`Review/`) — per-repo summary starter: `id` (UUID), `pattern`
  (`owner/name`, `*`/`?` wildcards), `body`
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
  Reasons are human-readable strings shown in the UI. `category(of:)` and `isLockfile(_:)` are the
  public classifications other features borrow rather than restate (ADR 0026).
- `InboxGrouper` — sections by facet (provenance / repo / review state) + sorting.
- `Claim` / `ClaimExtractor` / `EvidenceChecker` / `ClaimsEvidenceReport` (`Claims/`) — the whole
  of "what it says beside what Shepherd found" as values (ADR 0026).
  `ClaimExtractor.extract(from:) -> [Claim]` reads four claim shapes (`testsAdded`,
  `scopeLimited(module:)`, `noBreakingChanges`, `fixesIssue(number:)`) out of the description with
  documented `NSRegularExpression` patterns, **sentence-scoped** (`ClaimText`) so a noun in one
  bullet cannot borrow a verb from the next, deduplicated by `Kind.dedupKey` and totally ordered.
  `EvidenceChecker.check(_:in:)` is a pure function of a `PullRequestDetail`: changed paths through
  `FilePrioritizer`'s classifications, the check rollup with its failing checks named, and hunk
  walks (`PatchWalker`, `IntelligenceDiffWindow`'s arithmetic in a second, smaller walker) for
  assertion drift and for removed exported declarations per language. Every fact is a sentence with
  an optional `path`/`line`; the status (`ok` / `contradicted` / `unclear`) is *derived from the
  facts* by rules documented per claim. `ClaimsEvidenceReport.build(detail:summary:)` composes the
  lines and has **no aggregate field at all** — a score would be a verdict.
- `BulkTriagePlan` (`Triage/`) — the whole of bulk triage's judgement as a value (ADR 0015):
  `make(action:pullRequests:) -> BulkTriagePlan` partitions a selection into entries carrying
  either the `steps` to write (`.approve` / `.merge`, in send order) or a `skipReason`, plus
  `caveats` for an entry that goes ahead with a note. Preconditions are evaluated in a fixed
  order so the reason shown is deterministic. `writes(mergeMethod:existingDrafts:now:)` turns the
  plan into `BulkTriageWrite` values — an `OutboxItem` plus the `ReviewDraft` to persist beside
  it — timestamped so an approval sorts ahead of the merge queued behind it.
  `greenAgentPullRequests(in:)` is the "select all green agent PRs" preselect, deliberately
  stricter than the plan (a pull request with no checks is not preselected but may still be
  picked by hand).
- `AutoMergePolicy` / `AutoMergeRules` / `AutoMergeLedger` (`Automation/`) — the whole of "may
  Shepherd merge this by itself" as a value (ADR 0018).
  `decide(pullRequest:rules:ledger:existingOutbox:)` returns `.merge(expectedHeadOid:)` or
  `.skip(reason)` with an exhaustive `AutoMergeSkipReason`, evaluated in a fixed order so the
  reason shown is deterministic. The conditions the founder named — agent-authored, rollup
  `success` with at least one check, `approved`, not a draft, `mergeable` — are *not* fields: the
  rule set carries only the master switch and two narrowings (a repository allow-list matched with
  `GlobPattern`, and labels that must all be present), so no setting and no corrupt document can
  widen it. `AutoMergeLedger` is the deduplication key set *and* the audit log in one list — one
  queued merge per `(prID, headRefOid)`, ever — which is why the two cannot drift apart.
- `SavedReply.inserting(_:into:)` (`Review/`) — how a saved reply reaches a comment field:
  appended after exactly one blank line, never at a caret. `TextEditor`/`TextField` expose no
  selection, so an at-cursor insert would mean replacing every review text field with an
  `NSTextView` wrapper; appending is lossless and predictable instead.
- `ReviewTemplate.matching(_:repo:)` / `.prefill(templates:repo:draft:summaryText:)` (`Review/`) —
  which template a repository gets and whether it may be used. Matching: exact pattern beats
  wildcard, then more literal characters (`specificity`) beats fewer, then the user's list order,
  first wins; all case-insensitive, like every other `RepoRef` comparison. Prefilling requires
  *all three* of: a blank summary field, no draft or an entirely empty one (`ReviewDraft.isEmpty`),
  and a matching template with a body — so a template can only ever fill a new review and can
  never overwrite review work (ADR 0006).
- `DigestReport` / `DigestSchedule` (`Digest/`) — the morning digest, as two pure values.
  `DigestReport.make(pullRequests:parkedReviewCount:windowStart:now:)` turns cached inbox rows plus
  the parked-outbox count into ordered sections with a count and up to three named pull requests
  each; an empty report is the signal for "say nothing at all". The predicates are *borrowed*, not
  restated: `PullRequestSummary.needsMyReview`, `BulkTriagePlan.greenAgentPullRequests(in:)`
  (ADR 0015) and `AutoDelegationPolicy.isOwn(_:)` (ADR 0016). Only the review-request section is
  windowed (`DigestSectionKind.isWindowed`) — the other two are standing state, because a green
  agent PR nobody merged is exactly what a morning brief is for and a windowed version would go
  quiet on the second morning. `DigestSchedule.window(now:lastDeliveredAt:calendar:)` is the whole
  due rule — off/not-yet/weekend/already-delivered, in that fixed order — and returns the span to
  report on: the previous delivery, a 16 h look-back on the first run, capped at seven days.
- `SearchDocument` / `SearchRanker` / `SearchVector` (`Search/`) — the whole of ⌘K search's
  judgement as three pure values (ADR 0019). `SearchDocument.make(source:budget:)` composes one
  pull request's searchable text out of what the sweep and the review screen already stored —
  title, identity, labels, author, branch, then description, changed-file paths and the *added*
  diff lines, each against an explicit byte budget — and carries its own weighted term counts plus
  two staleness hashes (`documentHash`, the persisted re-embed gate; `sourceFingerprint`, the
  in-memory "does the diff have to be read at all" gate, both FNV-1a so they survive a relaunch).
  `SearchRanker.rank(query:documents:vectors:)` is BM25 over those counts blended half-and-half
  with a cosine, with an exact `owner/repo#n` or `#n` always first, a similarity floor so a query
  that matches nothing returns nothing, and a total order. `SearchVector` is the `Float32` value —
  cosine, mean-pooling, alignment-safe BLOB coding — and the *only* embedding-shaped thing in the
  package: what produces one is Apple-only and therefore lives in the app target.
- `Interdiff` / `FindingState` / `ReviewFindings` / `UnifiedPatch` (`Review/`) — the whole of
  "since my review" as pure text work (ADR 0028). `UnifiedPatch.reconstruct(after:)` rebuilds the
  *head* side of a unified patch as lines, padding the gaps between hunks so a 1-based index is
  GitHub's own line number; the app-target `PatchReconstructor` stays where it is, because it also
  produces the viewer's commentable-line sets. `Interdiff.compute(before:after:)` pairs the two
  rounds' `ChangedFile` lists by path (a rename by `previousPath`), diffs the reconstructions line
  by line — common prefix/suffix by scanning, the middle by LCS, with a cell cap past which the
  region becomes one replacing hunk — and returns one `InterdiffFile` per file that differs, each
  carrying its hunks *and* a synthesized unified patch in GitHub's own shape, so the Monaco viewer
  renders a round through the existing `loadFile` message. Identical files are omitted; a rename is
  listed even when its content did not change.
  `FindingState.classify(thread:interdiff:viewerLogin:)` maps one thread's anchor — `line` on the
  current side, `originalLine` on the reviewed side for an outdated thread, never backfilled from
  one another — onto those hunks and answers `addressed` / `moved` / `replied` / `unchanged` in
  that fixed precedence. Every state is a claim about lines and comments, never about correctness.
- `RecurringFinding` / `RecurringFindingDetector` / `ViewerReviewComment` (`Review/`) — the whole
  judgement of the feedback loop (ADR 0029). `detect(repo:comments:now:window:…)` takes one
  embedding per comment of the reviewer's own and clusters greedily by cosine — seeded by the
  oldest comment in a fixed order, so the answer never depends on the order SQLite returned the
  rows in. Five documented constants carry the rule: `minimumCount` 3, `minimumDistinctPullRequests`
  2, `defaultWindow` 30 days, `minimumSimilarity` **0.6** (above ADR 0019's 0.35 and the saved
  reply's 0.45, because a corpus of one person's short review prose scores high against itself),
  `maximumQuotes` 3. A cluster's `exemplar` is its *shortest* comment — the phrasing closest to a
  rule — and `dismissalKey` hashes the repository plus that exemplar, so a fourth comment joining
  the cluster cannot resurrect a card the reviewer dismissed. Both orders are total: clusters by
  size then newest then exemplar, comments by date then id.
- `ReviewSnapshot` (`Review/`) — the diff a review was written against: `prID`,
  `reviewedHeadOid`, `reviewedAt`, `files: [ChangedFile]` (patches included). The interdiff's
  baseline, kept locally because GitHub cannot be asked for a force-pushed head's patches.
- `DeepLink` (`Routing/`) — the whole `shepherd://` grammar as a value: `parse(URL) -> DeepLink?`
  and `urlString` in the other direction, round-trip tested. Strict by construction (closed
  vocabularies, GitHub's own character rules, decoding *after* the path split), because a URL is
  untrusted input. Companion: `ShepherdCommandLine`, the `shepherd` CLI's argv grammar, kept in
  the same folder so the grammar the CLI writes and the grammar the app reads cannot drift
  (ADR 0013).

## GitHubKit

- `GitHubClient` (actor) — façade over GraphQL + REST with one `URLSession`:
  - `searchOpenPullRequests(queries:) async throws -> [PullRequestSummary]` (GraphQL search,
    ADR 0005)
  - `pullRequestDetail(repo:number:) async throws -> PullRequestDetail`
  - `submitReview(_ draft: ReviewDraft, on:) async throws` — REST
    `POST /pulls/{n}/reviews` with full `comments` array; maps verdict to `event`
  - `replyToComment/resolveThread/unresolveThread/mergePullRequest/markReadyForReview…`
  - `notifications(since:) async throws -> (items, pollInterval)` — honors `X-Poll-Interval`
  - `jobLog(repo:jobID:) async throws -> String` — `GET /actions/jobs/{id}/logs` for "why is CI
    red?" (ADR 0024). GitHub answers `302` to a short-lived, self-signed blob URL on its own
    storage host: the redirect is followed **once**, the bearer token is *not* sent to the blob
    host (a transport that follows redirects itself is answered from the body it already has), the
    body is capped at `maximumJobLogBytes` (2 MB) with `GitHubError.responseTooLarge` beyond it,
    and it is decoded UTF-8 lossily. Deliberately **not** ETag-cached — the URL is keyed by an
    immutable job id, so every entry would be an unreachable row holding a megabyte, which is why
    `cacheKey(for:)` refuses `/check-runs` too.
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
`etags`, `viewed_files`, `agent_registry_overrides`, `search_index`, `triage_verdicts`,
`review_snapshots`).
Append-only migrator — currently `v1`, `v2`, `v3`, `v4` and `v5`. `v3` is the search index (ADR 0019: one
row per pull request holding the document hash, the model identifier and a `Float32` vector, pruned
by an `ON DELETE CASCADE` onto `pull_requests` rather than by a sweep of its own); `v4` is
`triage_verdicts` (ADR 0023: one row per pull request holding `kind`, `risk`, the one-sentence
`reason`, the same `documentHash` gate, the model identifier and `classifiedAt`, pruned by the same
cascade — deliberately the search index's shape, because the two rows answer the same two questions
about the same pull request). `v5` is `review_snapshots` (ADR 0028: one row per *reviewed head* —
`(prID, reviewedHeadOid)` is the primary key, so `COUNT(*)` is the number of rounds the inbox row
reports — holding `reviewedAt` and the pull request's `changed_files` rows, patches included, as
one `filesJSON` blob, pruned by the same cascade. Written by the outbox drain when a
`submitReview` succeeds, read by the interdiff, and never queried *into*: the whole value is read
at once, and keeping the patches is the point, because a force-push makes them unfetchable).
`ValueObservation` publishers feed the UI. The **outbox** stores every outbound mutation (submit review, reply,
resolve, merge) as a row with retry/backoff state so writes survive crash/offline.

One read crosses tables rather than serving a screen: `viewerReviewComments(login:since:)` joins
`review_comments → review_threads → pull_requests` and returns the signed-in user's own posted
comments since a date, with the repository and pull request number each belongs to (ADR 0029). It
is the *only* input the feedback loop has, which is why the login match and the "posted, not
pending" condition live in the SQL rather than in a caller: nobody else's comment can be read at
all, let alone clustered.

## ShepherdSync

`SyncEngine` (actor) runs two loops (ADR 0005): notifications loop (server-governed interval)
and inbox sweep (default 120 s, user-configurable). Delta logic: a PR is re-fetched in detail
only when `updatedAt`/`headRefOid` changed or the user opens it. Emits `SyncEvent`s
(`.newReviewRequest`, `.checksFailedOnOwnPR`, `.prMerged`, …) that the app maps to macOS
notifications. Also drains the outbox with staleness re-validation (draft's `basedOnHeadOid`
vs current head → surface conflict instead of blind submit).

The drain has exactly one side effect that is not a GitHub write: when a `submitReview` mutation
is acknowledged, the pull request's current `changed_files` rows are snapshotted as the head the
review was written against (ADR 0028). The head is the draft's own `basedOnHeadOid` — the commit
the staleness check just re-validated — with the head at drain time as a documented fallback for a
draft that carries none. It goes through a port of its own (`ReviewSnapshotWriting`, beside
`SyncStoring` in `SyncPorts.swift`) so the engine keeps building and testing on Linux against a
fake, and a failure to write it never fails the sent review: the mutation has already reached
GitHub, and the cost is that the review screen offers no "Since your review" tab. The same port
carries the retroactive case — a detail fetch that sees a review *by the viewer*
(`SyncConfiguration.viewerLogin`) on a head the pull request is still on, with no baseline for that
head yet, writes one from the files it just stored.

One `SyncEvent` is not about telling the user anything: `.mutationSent(SentMutation)` is yielded
by the drain **after** a row is recorded as sent, and it is the only place in the system where
"this write really reached GitHub" is observable. Anything that must not fire on a mere intent —
outbound webhooks (ADR 0012) — hangs off it rather than off the enqueue. Like `SyncFailure` and
`DraftConflict` it is flattened to values (pull-request identity plus what was sent), because
the engine does not spend a fetch to describe an event; a consumer that wants the title reads
the row from the database it is already reading from.

Two events are about *the user's own* pull requests — `.checksFailedOnOwnPR(ChecksFailure)` and
`.changesRequestedOnOwnPR(ChangesRequested)` — and both carry the state the previous sweep saw
alongside the new one. The engine has always emitted them on a change rather than on a state; what
the payload adds is the ability for a consumer to tell a *watched* change from a first sighting,
which is what makes an automatic action safe (ADR 0016). "Own" comes from one shared definition,
`AutoDelegationPolicy.isOwn`: the user authored it, or a recognised agent authored it and it is
assigned to them — never `mentions:`/`involves:` alone.

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
  func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String
  func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String
  // Streamed twins of the two drafting calls. Every element is the whole draft so far —
  // cumulative, never a delta — so a text field can be written with it directly. A tier that
  // cannot stream inherits a default implementation that yields the finished answer once.
  func streamReviewSummaryDraft(_: ReviewSummaryDraftRequest) -> AsyncThrowingStream<String, Error>
  func streamInlineCommentDraft(_: InlineCommentDraftRequest) -> AsyncThrowingStream<String, Error>
  // The third drafting surface (plan §3.D): the same windowed excerpt as an inline draft, a
  // different instruction, and an answer in `Locale.current`'s language. Streamed only — there is
  // no awaited twin — so the protocol's default implementation *refuses* rather than wrapping one.
  func streamExplanation(_: ExplainSelectionRequest) -> AsyncThrowingStream<String, Error>
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

Four further things about that tier are **optional on both sides** and add no endpoint-specific
code path (ADR 0007's 2026-09-03 amendment, plan §3.K). Reads: two response headers become a
`ServedBy` value (operator plus deployment id) through one pure parse, recorded into a per-request
`IntelligenceEndpointReport` the router hands the tier and reads back once the tier has committed —
which puts the operator in the draft caption as a suffix before the first character arrives;
`OpenAIModelsResponse` keeps the `sovereignty` and `pricing` blocks a gateway may publish per model,
so the picker can show a badge; and a streamed request sends
`stream_options: {"include_usage": true}` and keeps the final usage chunk's counts through
`OpenAICompatibleStreamDecoder.usage(in:)` (pure, Linux-tested, and harmless to the delta decoder
because that chunk's `choices` array is empty). Write: `provider: {countries, zero_retention}` goes
into the request body when — and only when — the user set the two synced
`openAICompatibleSovereigntyCountries` / `openAICompatibleZeroRetention` settings, because the
gateways that read the field reject an empty object and the ones that do not reject the field.
`IntelligenceTransport` gained a headers-bearing `send(url:headers:body:)` (default implementation
forwards to `post`) so the served-by parse and the single `Retry-After` retry — one wait, one
resend, `IntelligenceRetryAfter`'s pure clamp deciding whether there is one at all — are driven by
a scripted transport in tests rather than by a live key.

`PullRequestDigest` is built by tier-1 heuristics in `ShepherdCore` (per-file stats, top
hunks, title/body) with an explicit token budget parameter — the on-device provider requests
a small digest (≤ ~6K tokens), the Anthropic provider a large one. Providers are selected in
settings: *Off / On-device / On-device + API key*. AI output is rendered as dismissible hints,
never auto-applied.

The two `draft…` methods are the review-composer surface (ADR 0007 amendment). Their request types
budget themselves the same way the digest does: `ReviewSummaryDraftRequest.build(detail:…)`
reserves room for the reviewer's quoted pending comments *before* building the digest, and
`InlineCommentDraftBuilder` cuts a marked-up window out of the unified diff — `contextLines` on
either side of the anchored line, then trimmed to `excerptShare` of the tier's characters, with the
anchored lines the last thing surrendered. Both return plain text, parsed leniently
(`IntelligenceJSON.draft(from:)`) so a model that ignores the `{"draft": …}` contract is still
usable. The text goes into a `TextEditor` and nowhere else; `AIDraftFieldState` — a pure value —
owns the rules around it (ask before overwriting typed text, label an unedited draft, drop the
label on the first keystroke).

### The tool contract, the trace and the generated twins (`ShepherdCore/Intelligence/`)

Groundwork for the features that call a tool or return a structure
(`docs/plans/apple-intelligence-v2.md` §0.3/§0.4). It is all in `ShepherdCore` and imports
Foundation only, so the contract, its validation and both wire encodings are tested on Linux;
the concrete tools and the `@Generable` mirrors stay in the app target, where the Apple
frameworks are.

- **The registry is a fixed enum.** `IntelligenceToolName` has exactly three cases —
  `failingChecks`, `jobLogTail`, `fileDiff` — and `IntelligenceToolRegistry.descriptor(for:)`
  is static data, so a tool cannot be added at runtime and every tool is a *read*.
  `IntelligenceToolDescriptor` + `IntelligenceToolParameter` are the JSON-schema-shaped
  description; `IntelligenceToolCall` carries the tool name as a raw `String` because it comes
  from a model, and `IntelligenceToolResult` carries a **budgeted** string, a one-line summary
  and `wasTruncated`, so the model never sees a raw log or a raw file.
- **`IntelligenceToolRegistry.validate(_:)` is the guardrail**, pure and total: unknown tool,
  missing required argument, wrong argument type, an argument the tool never declared, and — the
  invariant the plan names — a `fileDiff` path that is not one of the pull request's own changed
  files, which is why the registry is a value holding `changedFilePaths` rather than a namespace.
  No free text a model wrote can reach GitHub through a tool call. Arguments are checked in
  sorted name order, so the refusal a reviewer sees for a given call is always the same one.
- **Two wire shapes, one schema.** `IntelligenceToolJSONSchema` is the object both providers
  send; `AnthropicToolSchema` (`name`/`description`/`input_schema`) and `OpenAIToolSchema`
  (`type: "function"` + nested `function`) are the envelopes. Both are pinned byte for byte by
  fixture tests, because a schema an endpoint dislikes fails on the user's Mac otherwise.
- **`IntelligenceTrace`/`IntelligenceTraceStep`** are what the review screen renders as
  expandable steps: tool, arguments rendered for display (sorted by name, so a row reads the same
  every time), the tool's summary line, duration, ordering — and `resultContent`, the **budgeted**
  text the model was handed, which is what makes an expanded step show what the model saw rather
  than a re-description of it (ADR 0024). Appending assigns the order, and the
  `append(tool:call:result:duration:)` overload every tier's loop uses is the one place the content
  enters. Stored nowhere: the trace lives with the card and is thrown away with it.
- **The twins** are the `Codable` values the UI and the database see: `TriageVerdict`
  (`Kind`/`Risk` + one-sentence reason), `CIDiagnosis` (`failingTest?`, `file?`, `line?`,
  hypothesis, `Confidence`) and `ThreadDigest` (`State`, summary, open questions). Their coding
  keys *are* the JSON contract the cloud prompt asks for, so renaming one is a prompt change.
  Decoding is tolerant where a model's spelling varies and strict where it matters: an enum case
  is matched ignoring case, spaces, hyphens and underscores, a quoted line number is still a line
  number, an absent confidence reads as `low` — but a kind nobody declared is a decoding error
  rather than a default presented as the model's verdict.
- **`LogDigest`** (`ShepherdCore/Heuristics/`) is the tier-1 reduction the `jobLogTail` tool
  answers with (ADR 0024): it cleans each line (ANSI escapes, GitHub Actions' per-line `2026-…Z `
  timestamps, trailing whitespace), keeps the lines that name a failure — `error:`/`Error:`,
  `FAILED`, `FAIL `, `Test Case … failed`, `npm ERR!`, `AssertionError`, `Traceback`, `panic:`,
  `✘`/`✗` — with `contextLines` (3) lines *that carry something* on either side, drops repeats and
  blank lines, and cuts to `characterLimit(for:)` — a fifth of the tier's characters, ≈1,200 tokens
  on-device — by giving up the **front**, because a build that failed twice usually failed last for
  the reason worth reading. With nothing matching at all it answers the last 40 lines and reports
  `matchedLines == 0`. `Result` carries `text`, `lineCount`, `matchedLines`, `totalLines` and
  `wasTruncated`, so the tool's summary line ("last 42 of 1,320 lines of App build (macOS)") is
  built from counts rather than guessed. Linux-tested against the four real log tails in
  `Tests/Fixtures/eval/ci-*.json`.
- **`CheckRun.actionsJobID`** parses the job id out of a check's `detailsURL`
  (`/actions/runs/{run}/job/{job}`) and is `nil` for everything else — a Buildkite or CircleCI
  check, or a check run an app created — which is how the log tool knows there is no log to read.
- **The evaluation corpus** lives in `Tests/Fixtures/eval/` (twelve anonymised pull requests with
  an expected kind and risk, four CI log tails with an expected diagnosis: `xcodebuild`,
  `swift test`, npm and pytest shapes). `ShepherdTests/IntelligenceEvalTests.swift` is the
  runner and is **skipped unless `SHEPHERD_EVAL=1`** — it measures a model, not the code, so a
  new OS model must not be able to turn a build red. `Scripts/eval-intelligence/README.md` is
  the harness contract: fixture shapes, how to run it, and why it is not in CI.

Both drafting surfaces prefer the **streamed** path. `IntelligenceRouter.streamReviewSummaryDraft`
/ `streamInlineCommentDraft` — and `streamExplanation`, which runs the same ladder because it sends
the same excerpt — return an `IntelligenceStream` — the tier plus the stream — inside an
`IntelligenceStreamOutcome` whose three failure shapes convert back into the ordinary
`IntelligenceOutcome`, so the field has one way of saying "no draft, and here is why". The router
awaits the tier's *first* element before answering: that is what keeps the cloud → on-device
ladder working (a tier that fails on the connection has not shown anything yet) and what makes the
caption correct before the first character lands. On-device streaming rides guided generation's
partially-generated snapshots; the cloud tiers ask for `stream: true` and accumulate
`content_block_delta` / `choices[].delta.content` through one pure `ServerSentEventParser` plus
one decoder per shape in `ShepherdCore` — fixture-tested on Linux against recorded frames of both
providers. Streamed cloud calls swap the `{"draft": …}` contract for a plain-text one, because
half a JSON object is not text a reviewer can read. `AIDraftFieldState` gains `.streaming`: the
replace/append question is asked **once, before the request is made**, the growing text is written
cumulatively, the caption is up before the first token and stays until the reviewer's first
keystroke, a keystroke during a stream takes the field away from it, and a cancelled stream keeps
what arrived (still labelled).

`ExplainSelectionState` (`Features/Review/ExplainSelectionPopover.swift`) is the same idea for the
explain-a-selection popover and deliberately *not* a mode of `AIDraftFieldState`: an explanation is
prose in a read-only popover, so it can keep a partial answer **and** the reason a stream failed
side by side, where a field holding editable text can only sensibly show one of them. Its stop keeps
what arrived, its Escape does not (a dismissed popover is a withdrawn question), and the one thing
it produces is a string — `InlineCommentComposer` hands that to `AIDraftFieldState.finish(_:existingText:)`
as the outcome a draft would have produced, which is what makes "Turn into a comment" obey the
replace/append rule and the caption without a second copy of either.

### The tool loop (app target)

`IntelligenceProvider.diagnoseFailingChecks(_:tools:)` is the first method where the model decides
what to read. `CIDiagnosisRequest` orients it — slug, title, the red checks with their
conclusions, the changed-file paths, the tier's budget — and `IntelligenceToolExecuting` is the
seam behind which the reads happen; `LocalToolExecutor` is the one implementation, an `actor` over
a `PullRequestDetail` **snapshot** so a turn cannot see the pull request change underneath it. It
validates every call through the registry first, cuts every answer to the tier's budget
(`checksShare`/`diffShare`, per-check summary caps, `IntelligenceDiffWindow` for a diff window
around the line the model named — pure and Linux-tested in `ShepherdCore`), and turns a call the
model got wrong into a **refusal result** rather than an error: the model reads why and corrects
itself, and the reviewer sees the hop. `jobLogTail` resolves the check by name, takes its
`CheckRun.actionsJobID`, fetches the log through the injected `JobLogFetching` seam
(`GitHubClient` in production, a fake in tests) and reduces it with `LogDigest` — and answers
*there is no log, work from the summary and the diff* in four cases, each naming which one it was:
no reader, not an Actions job, the fetch failed, the log was empty. Model-facing tool content is
English like every prompt here; the one-line summaries beside it are the reviewer's and are
localised.

Each tier drives the loop in its own shape and they agree on everything that matters:
`OnDeviceToolBridge` (`FoundationModels` is imported only by the `OnDevice*.swift` files in
`Intelligence/` — the provider, this bridge, the triage classifier and the thread digester) wraps
the three tools in `FoundationModels.Tool` conformances with `@Generable` argument structs, and the framework
drives the calls — so the hop cap lives in the wrappers and the trace is collected by a shared
`ToolTraceRecorder` actor; `AnthropicProvider` keeps a `tool_use`/`tool_result` transcript, echoing
the assistant's content verbatim; `OpenAICompatibleProvider` keeps `tool_calls` plus one
`role: "tool"` message per call, non-streaming, and parses the `arguments` JSON *string*. All three
stop at `IntelligenceToolLoop.maximumHops` (6) with `IntelligenceError.toolLoopExceeded` rather
than answering from a turn that was cut off, and both cloud tiers map a `400` mentioning
tools/functions to `IntelligenceError.toolsUnsupported` — an Ollama-class endpoint with no tool
head. A tier that does not implement the method inherits a default that throws the same thing, so
a new tier can never answer a diagnosis *without having read anything*. The answer comes back as
`IntelligenceToolRun<CIDiagnosis>` — value plus `IntelligenceTrace` — because a diagnosis nobody
can check is a guess with a confidence label on it. `IntelligenceTransport` is the POST seam the
loops are tested through (`ShepherdTests/IntelligenceToolLoopTests.swift` scripts recorded
answers); the streamed drafting paths keep going straight to `URLSession`, since they need bytes.

`IntelligenceRouter.diagnoseFailingChecks(for:summary:preferCloud:jobLog:)` runs the ladder **the
other way round**: tier 2 first, and tier 3 only when tier 2 failed with `contextExceeded` /
`digestTooLarge` *and* `preferCloud` is `true`. Any other tier-2 failure is reported as it
happened — a cloud provider is not a retry — and an unavailable on-device model is not a budget
failure either. `preferCloud` defaults to `false`: the card asks the reviewer before passing
`true`, so no caller can send a pull request's contents — log included — to a configured endpoint by
leaving an argument out. The executor is rebuilt per tier, because the budget is what the tools cut
to, which is also what lets the rung a reviewer explicitly asked for see more of the log than the
on-device tier did. `attemptDiagnosis(…)` is the same call returning `CIDiagnosisAttempt` — the
outcome plus `didExceedBudget` — because the card has one decision to make about a failure (offer
the cloud rung) and recovering that from a failure *sentence* would mean string-matching an error
message.

**The card** (`Features/Review/CIDiagnosisCard.swift`, `CIDiagnosisTraceView.swift`,
`CIDiagnosisModel.swift`; the **Why?** button and the card itself hang off the checks list in
`Features/PullRequest/ConversationView.swift`). `CIDiagnosisModel` is a `@MainActor @Observable`
per review screen holding one `CIDiagnosisState` — `asking` / `diagnosed` / `tooLargeForDevice` /
`failed` — created inert, taking the router and the log reader *per call* so a settings change
cannot leave it asking a tier the user switched off. It renders the twin's fields, omitting the
ones the log did not name; the `file:line` links into the diff viewer (`ReviewModel.reveal(path:line:)`
→ the viewer's existing `revealLine`) only when the file is in the diff; each trace step expands to
the tool's own `resultContent`; the cloud question appears only for a budget failure and only when
`hasCloudTier`; and *Draft an agent brief* builds a `DelegationContext` (origin
`.reviewFinding(path:line:)` when the log named a file, one finding comment *"CI: test —
hypothesis"*, no author because the sentence is Shepherd's) and opens the delegation sheet, where
Run stays the reviewer's click. Nothing is persisted.

### Claims vs. Evidence (tier 1 only, ADR 0026)

`Features/Review/ClaimsEvidenceModel.swift` and `ClaimsEvidenceCard.swift`; the card hangs above
the description in `Features/PullRequest/ConversationView.swift`.

`ClaimsEvidenceCardState` is a pure value holding the report plus three rules that are therefore
unit-tested rather than eyeballed: an empty report draws **no card** (`isHidden`), an agent's pull
request opens expanded and a person's collapsed (ADR 0008's facet; a bot that is not a recognised
agent counts as a person), and the reviewer's own toggle outranks that default from then on
(`didChooseExpansion`). `ClaimsEvidenceModel` is the `@MainActor @Observable` per review screen
around it, and it exists for one reason: building the report walks every hunk of every file, so it
is rebuilt only when the `PullRequestDetail` actually changes and cached in between — never in a
SwiftUI `body`. Nothing is persisted.

Two things leave the card. A fact with a path becomes a link through `ReviewModel.reveal(path:line:)`
— the same seam the CI diagnosis card uses. And *Turn into a comment*, on a contradicted line only,
assembles `"<quote> — <facts>"` and writes it into `ReviewModel.summaryText`, the field the submit
sheet edits. That write is a **plain insertion, not a draft**: it does not go through
`AIDraftFieldState`, because there is no tier to name and no "AI draft" caption to earn, but it
borrows that type's rule — a non-empty field is never overwritten silently, so the card asks
*replace / append / discard* first and appends through
`ShepherdCore/SavedReply.inserting(_:into:)`. There is no path from the card to `submitReview`, to
the outbox or to a saved draft comment.

Evidence facts are English sentences built in `ShepherdCore`, like `FilePrioritizer`'s reasons; the
card's own chrome goes through `String(localized:)` with a German row (ADR 0022).

## UI conventions

- Linear-inspired: left rail (views/facets), center list, right detail; ⌘K command palette
  exposes every action *and* searches the pull requests in the inbox by content (ADR 0019);
  `j`/`k` row navigation; two-keystroke review actions
  (`r a` approve, `r c` comment, `r x` request changes, `r f` focus review session, `m` merge
  dialog); `x` ticks a row for bulk triage (⌘-click / ⇧-click do the same with the mouse,
  ADR 0015); undo toast instead of confirm dialogs wherever the action is reversible — the merge
  sheet, the bulk-triage sheet and "end a session with pull requests still in it" are the three
  exceptions, because none of them is undoable.
- Inside a focus review session two more single keys are live, and only there: `n` next,
  `d` done & next (below).
- Dark & light mode from day one: semantic color tokens only (`Color.shepherd*` asset
  catalog), theme piped into Monaco via `setTheme`.
- Every user-visible string goes through `String(localized:)` — or, for a SwiftUI literal title,
  through `LocalizedStringKey`, which is the same table — with English as the key language and
  German shipped in `Shepherd/Resources/Localizable.xcstrings` (ADR 0022). The language follows
  `Locale.current`; there is no setting. `Scripts/check-localization.py` re-derives every key from
  the source and fails CI on one that the catalog is missing, because the build does not:
  an untranslated key resolves to itself, which is the English sentence.

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

`ShepherdApp` has three scenes: the one `WindowGroup`, the standard `Settings` window, and the
menu-bar quick inbox (below).

### Views render from the database, never from the network

The inbox carries **two** selections and they are not the same thing (ADR 0015): `selectedID` is
the keyboard cursor that `j`/`k` moves and the detail panel follows, and `marks`
(`InboxMarkSelection`, a pure value like `KeySequenceState`) is the set ticked for a bulk action.
Marks are pruned to the visible rows on every list change, so a bulk action can only ever act on
rows the user can see.

`InboxModel` subscribes to `DatabaseManager.observeInbox()`; `ReviewModel` subscribes to
`observeDraft(prID:)`. Detail fetches read the cached `PullRequestDetail` first and only then
refresh from GitHub, so opening a pull request offline shows the last-known state instead of a
spinner (ADR 0006). Grouping uses `InboxGrouper`; the sort order inside a section is applied by
the app on top of it (`priority` / `recentlyUpdated` / `oldestFirst`), with a deterministic
`InboxModel.priorityScore` so two sweeps of the same data never reshuffle the list.

### Menu-bar quick inbox

`MenuBarExtra(isInserted:)` in `ShepherdApp`, bound straight to `AppSettings.showsMenuBarExtra`
(Settings → Appearance, on by default), with `.menuBarExtraStyle(.window)` because the content is
rows with chips rather than commands. `Features/MenuBar/` is two files: `MenuBarQuickInbox`, a pure
value, and the two views.

The data flow is the point, and it is deliberately not a new one:

- The rows come from **`SignedInSession.inboxRows`**, a third `ValueObservation` beside the two
  outbox counts. It is on the session rather than in the inbox because `InboxModel` is owned by
  `InboxScreen` and stops observing when that screen goes away (the review screen replaces it),
  while the badge has to stay true with no window open at all. Same source, same table, no fetch
  and no sweep of its own; the cost is one extra local `SELECT` per inbox write.
- The **filter, the order and the count** are the inbox's: `SmartView.needsMyReview.matches` and
  `InboxModel.prioritySorted` (split out of the priority sort for exactly this), so the menu's
  eight rows are the top eight of the list the window shows. `MenuBarQuickInbox` owns only the two
  decisions that are its own — cut at `rowLimit` with an `overflow` count, and a badge that is
  blank at zero and `"99+"` above 99 — which is what makes them unit-testable.
- Every **action** is a call into `AppEnvironment`: a row is `openReview(prID:)`, "n more…" runs
  the `DeepLink.inbox(filter: .needsMyReview)` route the way `shepherd://` does — the link *value*
  as internal navigation API, no URL built — and "Sync now" is `syncNow()`.
- **Getting the window back** is `AppEnvironment.activateMainWindow()`: AppKit, because asking a
  `WindowGroup` to open means asking for a *second* window. It skips the extra's own `NSPanel`
  (never main) and the Settings window (excluded by SwiftUI's identifier), and returns `false`
  when there is nothing left to front — the one case where the view falls back to
  `openWindow(id: ShepherdScene.mainWindow)`, which is the only reason the window group has an id.

Signed out the menu shows one line and a button that brings the sign-in window forward — the item
stays in the menu bar, because disappearing chrome reads as a bug.

### Morning digest (opt-in, local, no scheduler)

Once a day, at a time the user picks, Shepherd says what came in: new review requests, green agent
pull requests that only need an approval or a merge, the user's own pull requests with red CI or a
change request, and reviews the outbox could not send. It arrives as a macOS notification and as a
dismissible card above the inbox list. **Off by default** (Settings → Sync).

`Features/Digest/` is three files and holds no judgement: `DigestCoordinator` (the loop and the
delivery), `DigestCardView` (the card) and `DigestPresentation` (the words, shared by the card and
the notification so their numbers cannot disagree). Everything that decides anything is the pure
`ShepherdCore/Digest/` pair above.

Four decisions are worth knowing:

- **No launch agent, no daemon, no `BGTaskScheduler`.** A `Task` on `AppEnvironment.digest` checks
  the pure due rule once a minute while Shepherd runs, starting at launch and never stopping — the
  check's *source* answers `nil` while signed out, so sign-in and sign-out do not have to remember
  to restart a timer. With the digest off, a tick is one `Bool` read. A digest that needed a login
  item would be a much larger promise than the feature is worth, and one the app could not keep
  after a sign-out.
- **A missed nine o'clock is caught up, once, the same day.** Entirely `DigestSchedule`'s rule:
  the comparison is "is it past today's delivery time and has today had one", not a timer that was
  asleep. A Friday digest missed over a weekend is *not* replayed on Monday — Monday delivers
  Monday's digest, whose window reaches back to Friday's, so nothing is lost and there is still
  exactly one a day.
- **The delivery is recorded even when the report is empty**, and that is what stops a quiet Mac
  re-checking every minute until midnight. An empty report posts nothing and shows nothing:
  `DigestReport.isEmpty` is the decision, made in the pure type rather than in a view.
- **Nothing leaves the Mac.** The digest is built from rows the sweep already wrote to SQLite, and
  it fires unattended — so it may not call GitHub and it may not call an AI endpoint. There is no
  code path from here to either. An on-device sentence on top of the deterministic lines is the only
  intelligence tier this path could ever use and is deliberately not wired up yet
  (`docs/ROADMAP.md`, v1.x).

Device state versus setting is the usual split: the *schedule* travels in the encrypted settings
document (`digest` group, both directions of `SettingsSyncApplier`), while
`AppSettings.digestLastDeliveredAt` deliberately does not — two Macs sharing an "already delivered
today" would let the first one awake silence the other, exactly the argument
`AutoDelegationLedger` makes (ADR 0016). The card is not persisted at all: the notification is the
announcement, the card is the digest's presence while the day lasts, and it clears itself when the
calendar day rolls over.

The card's *Show* routes through surfaces that already exist rather than adding a fifth way to
filter a list (`InboxScreen.show(_:)`): the rail mapping a `shepherd://inbox?filter=…` link uses,
the bulk-triage preselect for the green-agent line, and Settings → Sync for parked reviews. A click
on the **notification** goes through `NotificationRouter` — the app's only
`UNUserNotificationCenterDelegate`, installed in `AppEnvironment.init` because a click that
launched the app is delivered moments later — and lands on `openInboxFromNotification()`, which sets
the same pending-filter slot a deep link does. The digest is the only notification that routes
anywhere: a review-request banner that yanked the window to another screen mid-review would be
hostile, so every other one keeps macOS's default of simply bringing the app forward.

### Focus review session (the queue over pending reviews)

"Start review session" (⇧⌘⏎, `r f`, ⌘K, the Review menu, and a button in the inbox header while
anything is waiting) walks the user through every pull request that needs their review, one after
another, on the **existing** review screen. There is no second review UI, and that is the whole
design: a session is a way of *moving between* reviews.

`Features/Review/ReviewSession.swift` is a pure value and holds every decision:

- The queue is **frozen at start** and never grows. A session whose list absorbed each sweep's
  imports would turn "3 of 12" into a number that rises while you work; pull requests that arrive
  during a session wait in the inbox. Its contents are
  `SmartView.needsMyReview.matches` + `InboxModel.prioritySorted` over
  `SignedInSession.inboxRows` — the same filter, order and observation the menu-bar quick inbox
  uses, so the session and the window can never disagree about what is waiting or in which order.
  The rail's *facet* filters are deliberately ignored: "start a session" means everything waiting
  for you, and the header button therefore promises the rail count, not the filtered count.
- The queue entry copies the slug and title in, so the bar can still name a pull request that has
  since left the inbox.
- Every cursor move is a transition returning a `ReviewSession.Advance`: what was walked past and
  what is now current. An entry that left the local inbox between freezing and being reached is
  walked past **when it is reached**, with a toast, and counted apart from the ones the user
  skipped on purpose — "3 skipped" means "you moved on", not "GitHub moved on".
- An empty queue produces **no** session (failable initializer); the caller says "nothing needs
  your review right now" instead of putting up a bar reading "0 of 0".
- Session state is **not persisted**: no `AppSettings` key, nothing in the encrypted settings
  document (ADR 0014). A session is a sitting, not a document — restoring one would mean restoring
  a snapshot of an inbox that has moved on.

The app half is three touch points:

- **State**: one optional on `AppEnvironment` (`reviewSession`). It is there rather than on a
  screen because changing `route` is exactly how the session moves on, so it outlives every
  review screen it walks through. `closeReview()` ends a running session, and `openReview(prID:)`
  ends one when the id is *not* the entry under the cursor (a parked-review alert's "Re-review", a
  menu-bar row, a `shepherd://` link), so no route into or out of the review screen can leave a
  bar on screen that names a different pull request than the screen below it.
- **Chrome**: `ReviewSessionBar` as a `safeAreaInset(edge: .top)` on `ReviewScreen` — progress
  "n of m" with a fill track, the pull request's slug and title, and *Done & next* (`d`),
  *Next* (`n`), *End* (`esc`). Escape asks before throwing a queue away; ending reports
  "Session complete — 9 reviewed, 3 skipped · 4 m 12 s" as a toast and returns to the inbox.
- **Auto-advance**: `PullRequestActions.onDidQueueVerdict`, called beside the success toast the
  moment a verdict or a merge is written to the outbox, and wired up only by `ReviewScreen`. So
  `r a` / `r x` / `r c` / `m` move the queue on their own. The hook is at the **enqueue**, not at
  the drain: a session that waited for GitHub would stall on a slow network, and one driven by
  `mutationSent` would move again on every retry — including hours later, when the app comes back
  online and nobody is reviewing anything (ADR 0006). `AppEnvironment` checks the id, so a review
  submitted for anything but the pull request under the cursor cannot move the queue, and the
  route change is deferred by one main-actor turn so the next pull request is never pushed in
  under the submit sheet that is still closing.

### Saved replies and review templates

Two settings-shaped features on the review path, both edited in Settings → Replies
(`Features/Settings/RepliesSettingsTab.swift`, with an editor sheet each) and both stored as one
JSON blob in `AppSettings` (`review.savedReplies`, `review.templates`) and carried in the
document's `composer` group. All the judgement is pure and lives in `ShepherdCore/Review/`; the app
layer is only placement.

- **Insertion is per-field, not global.** `SavedReplyMenu` (`Features/Review/`) is a
  `text.badge.plus` `Menu` attached to each of the three comment fields — the inline comment
  composer, the review summary in the submit sheet, and the thread-reply bar — and it writes into
  *that* field's binding through `SavedReply.inserting(_:into:)`. It is deliberately **not** a ⌘K
  command: the palette is a focus-stealing overlay with its own search field, so a palette row
  would have to guess which composer to insert into, and the composers are sheets and popovers the
  palette does not sit above. The menu cannot pick the wrong field, and it is visible while typing.
- **Templates fill only new drafts.** `ReviewModel.applyReviewTemplateIfNeeded()` is called from the
  two places that complete the picture — the draft `ValueObservation` and the arrival of the
  pull-request detail (which is where `RepoRef` comes from) — because either can win the race. It
  waits for the draft observation to have spoken once (`hasObservedDraft`): writing a template into
  `summaryText` while "is there a draft?" is still unknown would also block the arriving draft's own
  summary, which the observation only writes into an empty field. It then asks once per opened
  review (`hasOfferedTemplate`), so a background refresh cannot put a checklist back that the user
  deleted.

### All writes go through the outbox

`PullRequestActions` is the single write surface (`submitReview`, `reply`, `setThread`,
`merge`, `markReadyForReview`). Every one of them enqueues an `OutboxItem` and then asks the
sync engine to drain, so a queued approval survives a crash, a quit or an offline period. The
app never calls a `GitHubClient` mutation directly. `SyncEvent.draftConflict` surfaces as an
alert offering to re-open the review rather than submitting against the wrong commit — one alert
per parked review, queued in `DraftConflictQueue` so a drain that parks several shows all of them,
with `conflictedOutboxCount()` behind the standing count in Settings → Sync and the title bar.

Bulk triage (ADR 0015) is the same surface used *n* times, on purpose. `PullRequestActions.queue(_:method:)`
takes a confirmed `BulkTriagePlan`, persists each draft and enqueues each row exactly as the
single-pull-request path does, and then drains **once** for the whole batch. There is no bulk
GitHub call anywhere in the app: the batch is n rows, so offline, retry, the merge preflight and
`mutationSent` (and therefore webhooks, ADR 0012) all behave per pull request. The rate limit
needs no special handling either — the drain's batch size and GitHubKit's `Retry-After` backoff
already throttle it.

Automatic merging (ADR 0018) is the same surface again, called by a rule instead of a button:
`AutoMergeCoordinator` reaches `PullRequestActions.merge(_:method:)` through a seam, so an
unattended merge is one ordinary outbox row with the ordinary preflight, retry and `mutationSent`
behaviour. Nothing in `Automation/` can reach `GitHubClient`.

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
degrades cloud → on-device → nothing. The chars-÷-4 estimate is the floor rather than the law:
`TokenBudget.measured(_:using:)` takes a measurement closure and
`limited(toContextSize:reservedForResponse:)` re-derives the budget from a context window the
platform reported, so on macOS 26.4+ `OnDeviceProvider` pre-flights the real prompt against the
real window (minus room for the answer) and only falls back to the estimate where the OS cannot
measure. Both helpers are pure and live in `ShepherdCore`. Per-request choices also live in that
file: `OnDeviceUseCase` picks the general or the content-tagging model (availability is checked per
model, since the assets download per model) and `OnDeviceGeneration` holds every temperature and
`maximumResponseTokens` cap. A guardrail refusal and an exceeded context window map to
`IntelligenceError.guardrailDeclined` / `.contextExceeded` and are **never** retried. Results are returned as an `IntelligenceOutcome`, so the
UI can say *why* a card is missing instead of silently hiding it. `IntelligenceTiers` is the seam
the ladder is tested through — a stub cloud tier that fails, a stub on-device tier that answers, an
on-device tier that reports itself unavailable — so the degradation is verified without a key, a
network or Apple Intelligence. All FoundationModels usage is
confined to the `OnDevice*.swift` files in `Intelligence/`, guarded by
`SystemLanguageModel.default.availability`, and file paths a model invents are dropped before
they reach the UI.

### Outbound webhooks (app target, ADR 0012)

`Automation/` is one URL the user typed and nothing else: no listener, no port, no inbound half
(ADR 0005's exclusion is unchanged). It splits the way the delegation feature does — pure value
types plus one seam:

- `WebhookEvent` / `WebhookPullRequest` / `WebhookEventDetails` are the wire contract, encoded by
  a single `canonicalEncoder()` (`sortedKeys`, `withoutEscapingSlashes`) so the bytes are a pure
  function of the value — which is what lets tests pin the schema and lets the signature be
  computed over exactly what is sent. Optionals are written with `encode` rather than
  `encodeIfPresent`, so an absent value is an explicit `null` (the same choice
  `AgentCLIConfiguration` makes). Schema: [docs/WEBHOOKS.md](WEBHOOKS.md).
- `WebhookSignature` is HMAC-SHA256 over the body via CryptoKit, emitted as
  `X-Shepherd-Signature: sha256=<hex>` — GitHub's `X-Hub-Signature-256` shape on purpose. The
  secret is Keychain-only. **CryptoKit is why the whole feature lives in the app target rather
  than ShepherdKit**, which must keep building on Linux.
- `WebhookDispatcher` (`@MainActor @Observable`) owns the policy: two attempts, one two-second
  backoff, ten-second timeout, retries only for 408/429/5xx and transport errors, and a body that
  is built once so the retry carries the same bytes, signature and delivery id. `deliver` cannot
  throw — its caller is the sync engine's event loop — and the only trace of a failure is
  `lastDelivery`, rendered as one line in Settings. `WebhookPosting` is the transport seam, the
  same pattern as `ModelListing` and `AgentRunning`.
- `WebhookCoordinator` holds the one interesting decision as a pure function:
  `plan(for:) -> WebhookPlan?`. `review.submitted`/`pr.merged` map from `.mutationSent`;
  `delegation.finished` from `DelegationModel`'s terminal state (via `DelegationOutcome`, once per
  run); `inbox.new_review_request` from the sweep's discovery. `SyncEvent.prMerged` maps to
  *nothing* — an open-PR sweep cannot tell a merge from a close.

### Encrypted settings sync (app target, ADR 0014)

`SettingsSync/` is the second feature that talks to a host the user typed, and the first that
sends anything the user would mind losing. It splits the same way `Automation/` does — pure values
plus one transport seam — and for the same reason: CryptoKit and CommonCrypto are why it is in the
app target rather than ShepherdKit.

- `SyncedSettingsDocument` is the plaintext: a versioned JSON document with one explicit group per
  settings area plus `secrets` (GitHub token, the two AI keys, the webhook secret). Decoding is
  tolerant by construction — unknown fields ignored, absent fields defaulted — so a document
  written by a newer Shepherd costs an older one only the fields it never had. `v` is the single
  field that is *not* tolerated. The `composer` group is the one carrying *authored* content —
  the saved replies and review templates, as arrays, so their order (which is also the template
  tie-breaker) travels with them; an unreadable list falls back to empty and costs nothing else.
- `SettingsEnvelope` is what is uploaded: `{v, kdf{algo,salt,iterations}, cipher{algo,nonce},
  createdAt, deviceName, payload}`. Its `authenticatedData` is a fixed, hand-specified
  newline-separated byte string over every field **except** the payload, fed to the AEAD as AAD —
  so editing the iteration count or the device name in the bucket breaks decryption rather than
  weakening it. Hand-specified rather than `JSONEncoder` output on purpose: the bytes must be
  reproducible by a third-party script and across OS versions.
- `SettingsSyncCrypto` is the whole cryptographic surface: PBKDF2-HMAC-SHA256 (600 000 iterations,
  32-byte salt) via `CCKeyDerivationPBKDF`, AES-256-GCM via CryptoKit, fresh nonce per upload.
  Every authentication failure — wrong passphrase, edited metadata, one flipped bit — is the same
  error, and no plaintext is produced in any of them.
- `SigV4Signer` is AWS Signature Version 4 as a pure value: it takes a request description and
  returns strings. It is pinned to the official `aws-sig-v4-test-suite` vectors, which is the
  point — canonicalisation is where SigV4 goes wrong, and every mistake produces a well-formed
  signature the server rejects with no explanation.
- `S3ObjectClient` is `GET`/`PUT`/`HEAD` on **one** object and nothing else: no list, no delete, no
  multipart. `S3Transporting` is the transport seam (the `WebhookPosting` pattern), so the three
  requests' signatures are asserted byte for byte without a bucket. `S3ObjectLocation` validates
  endpoint/bucket/region/prefix into a host and a path; path-style is the default and `https` is
  the only scheme, with no localhost exception because the object carries the GitHub token.
- `SettingsSyncApplier` holds capture and apply as deliberate mirror images, so a field that is
  captured but never applied is visible in review. Applying replaces rather than merges, except
  that an **absent** secret leaves this Mac's alone. `SettingsSyncContext` gathers the four places
  the feature reaches into (`UserDefaults`, the secret Keychain items, the GitHub credential, the
  agent-registry table) so all of it is drivable from tests; the registry half is optional because
  it only exists while an account is signed in.
- `SettingsSyncModel` (`@MainActor @Observable`) is the four user-initiated actions and a status
  line. There is no timer anywhere in the folder: v1 is manual, and a download decrypts *first*
  and then asks for confirmation, naming the source Mac and the number of secrets. A GitHub token
  for a login other than the signed-in one is stored but not activated — Settings says a sign-in
  restart is needed rather than half-swapping the session.

### Deep links and the `shepherd` CLI (ADR 0013)

`onOpenURL` in `ShepherdApp` is the only entry point, and it hands the URL straight to
`AppEnvironment.open(deepLinkURL:)` (`App/DeepLinkRouter.swift`). Everything interesting about the
parsing is in `ShepherdCore`; the app layer only routes, and it routes through the surfaces that
already exist: `.pullRequest` → `openReview(prID:)`, `.sync` → `syncNow()`, `.inbox`/`.settings`
→ `route` plus a pending request the inbox screen consumes — the same "raise it, let the screen
that owns the state run it" mechanism as `PendingAction`. `InboxRailSelection` is the pure value
that maps a filter token onto rail state, so the mapping is testable without a session.

Two behaviours are worth knowing because they are the robust rather than the obvious choice:

- **A link that arrives before there is a session is queued**, in one slot, and replayed at the
  end of `startSession`. Opening the app is how a link launches it, so the first deep link of a
  session usually *does* arrive during `launching`; dropping it would look broken. Signing out
  clears the slot.
- **A pull request that is not in the local cache is fetched individually** and stored, then
  opened. The sweep searches `involves:@me`, so a link from a colleague is routinely absent from
  the inbox — a sweep would be slow *and* still miss it.

`shepherd` (`ShepherdCLI/`, target `ShepherdCLI`, product name `shepherd`) is a thin URL builder:
`ShepherdCommandLine.parse` → `DeepLink` → `NSWorkspace.shared.open`. It links `ShepherdCore`
only. That is deliberate and is the security boundary — no token, no database, no network, so it
grants nothing the app does not already expose to every process on the Mac. It has its own
scheme (`xcodebuild -scheme ShepherdCLI`) so the app scheme's Run action stays the app.

### Keyboard model

`KeySequenceState` is a pure value type implementing the two-keystroke commands (`r a`, `r x`,
`r c`, `r f`, `g a/r/s`) with a 1.5 s prefix timeout; views feed it characters from
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

#### The session back-channel (ADR 0030)

The same engine again, addressed at a *conversation* instead of a task. The pure half is
`ShepherdCore/Agents/SessionReference.swift` (`parse(trailers:)` over `Claude-Session:` lines →
id, URL, host, `local`/`remote`; `mostRecent(in:)` = the last commit's, because a second fix round
may come from a second session) and `SessionMessage.compose` (one template: location, the
reviewer's text verbatim, the pull request link, the round). Both are Linux-tested; the message is
deliberately unlocalised, because it is a prompt shown verbatim before sending and not chrome.

The app half is three small pieces. `Features/Delegation/SessionBackChannel.swift` decides
everything the two composers render: `action(session:configuration:)` returns `.send` when a
command is configured for that kind of session, `.open` when only the trailer's URL is available,
and `nil` when there is nothing to offer; `plan(…)` builds the message **once** and the
`DelegationContext` that carries it, so the confirmation sheet
(`Features/Delegation/SessionSendSheet.swift`) and the run receive the same string.
`AgentCLIConfiguration.sessionInvocation(message:session:worktree:executable:)` builds the argv
from the second template (`{message}`, `{sessionID}`, `{sessionURL}`, `{worktree}`), split by
`ShellWords` first and substituted after, so the message is one argv element.

Two seams already there carry it: `DelegationContext.session` (a field, not a fourth `Origin` case
— the origin of a session send *is* a review finding) makes `AgentCLIRunner` pick the session
template, and makes `DelegationPrompt.full` send the confirmed message with no preamble in front
of it. `AppEnvironment.sendToSession` opens the run through the same `DelegationCenter` a button
press uses — not automatic, no brief drafter — so the one-run-per-pull-request rule, the worktree,
the transcript and "never pushes" are literally the same code. What a send is *not* is enforced by
what it does not call: no `PullRequestActions.setThread`, no `submit`, no
`AutoDelegationCoordinator`. The inbox glyph comes from `SessionReturnAddressLoader`, a capped
local read over the cached details of machine-authored rows only — never a fetch.

#### Automatic delegation (ADR 0016)

The same engine, started by a rule instead of a button, and the split is the same one as
everywhere else: the *decision* is a pure function in `ShepherdCore/Automation/`
(`AutoDelegationPolicy.decide(signal, context) -> .start(plan) | .skip(reason)`), and the app layer
only supplies the inputs and performs the start.

- The trigger is an **edge, not a state**. `SyncEvent.checksFailedOnOwnPR` carries a
  `ChecksFailure` (and the new `changesRequestedOnOwnPR` a `ChangesRequested`) with the state the
  *previous* sweep saw, so a rule can distinguish "Shepherd watched this turn red" from "Shepherd
  saw this red for the first time" — the second one is a notification but never a run, or a fresh
  install would delegate the whole backlog at once.
- `AutoDelegationLedger` (`UserDefaults`, via `Automation/AutoDelegationStore.swift`) is the
  persistence: one start per `(prID, headRefOid)` for ever, plus a `yyyy-MM-dd` day counter for the
  daily cap. It is written *before* the run starts, cleared on sign-out, and deliberately **not**
  part of the settings document — the rules travel between Macs, the machine's automation state
  does not (ADR 0014).
- `AutoDelegationCoordinator` (`@MainActor`) maps events onto signals, records the ledger, posts the
  notification through an injected closure (which is what lets the tests assert notices without a
  notification centre) and returns the plan. `AppEnvironment` starts it through the *same*
  `startDelegation` a button press uses, so `DelegationCenter`'s one-run-per-pull-request rule, the
  worktree isolation and "never push" are literally the same code. `DelegationCenter.startAutomatically`
  differs from `open` in exactly two ways: no sheet is presented, and the model is marked
  `isAutomatic` — which drives the badge and `details.automatic` in the `delegation.finished`
  webhook.

The **App Sandbox is off** for this build (`Shepherd/Support/Shepherd.entitlements`, with the
reasoning inline): a sandboxed child process cannot usefully be a coding agent — no network, no
access to the user's CLI configuration, every path needing a bookmark. ADR 0010 already rules
the Mac App Store out for v1, so this costs nothing that was on the table; hardened runtime
stays on.

### The feedback loop: a recurring finding to an agent rule (ADR 0029)

Three files in the app, one in the package, one additive database read, and nothing else.

**Detection** is `Features/Review/RecurringFindingCoordinator.swift`, an `@MainActor @Observable`
built to `SavedReplySuggestionCoordinator`'s shape: every decision is
`ShepherdCore/RecurringFindingDetector`, and the coordinator supplies inputs, spends embeddings and
holds the caches. It hangs off `SignedInSession`'s `onInboxRows` as a *peer* of the search index and
the triage pass — same rows, same moment — but reads none of them: it takes the sweep as a clock and
reads `DatabaseManager.viewerReviewComments(login:since:)` instead. That query is the privacy
guarantee, not a filter: it matches the signed-in login (`COLLATE NOCASE`), skips comments still
pending in an unsent review, takes the thirty-day floor as SQL, and returns nobody else's rows at
all. The embedder is `EmbeddingProviding` — the on-device actor of ADR 0019 — and there is no
`IntelligenceRouter`, base URL or key anywhere in this path, which is what makes an *unattended*
pass over review prose acceptable (ADR 0007's rule; ADR 0020's line).

Two caches and one ceiling bound the cost. One vector per comment **body**, keyed by the body itself
(four identical sentences on four pull requests cost one embedding, and the bodies are already in
memory so a hash key would only add a collision to reason about); a `count|first-id|last-id`
fingerprint so an unchanged sweep costs one string comparison; and `maximumComments` = 200 newest
comments per repository, which bounds both the embeddings and the *n*² cosines. Nothing is
persisted — no table, no vector on disk.

**The card** is `Features/Review/RecurringFindingCard.swift`, drawn under the claims card in
`Features/PullRequest/ConversationView.swift`. It quotes the reviewer, names the *other* pull
requests the comments were written on, and has two buttons. Neither writes anything: *Dismiss for
this repository* flips a `Bool`, and *Draft a rule* hands the finding back to
`AppEnvironment.startRuleDelegation(finding:pullRequest:)`.

**The rule** is `Features/Delegation/RuleBriefDrafter.swift`, and it is text only.
`RecurringFindingRule.context(…)` builds an ordinary `DelegationContext` with origin
`.pullRequest` (a rule is not anchored to a file or a line) whose `findingComments` are the three
quotes and whose `findingCommentAuthors` are the reviewer's own login — stated, so
`AgentBriefRequest.requiresOnDevice` decides the cloud rung from matching data rather than from an
omitted author. `RecurringFindingRule.template(for:)` is the tier-1 task the sheet opens with: both
candidate filenames, the three quotes, one sentence about length and voice. `RuleBriefDrafter.live`
is the ✨ button — the same `AgentBriefDrafter` value, the same digest at the same on-device budget,
the same ladder — steered by `IntelligencePrompt.agentRuleBriefInstruction` prepended to the quoted
comments, because an agent-brief request has no instruction field. That is the one compromise, it is
argued at the call site, the sentence names itself so it cannot be read as a review comment, and it
is kept under the per-comment character cap so nothing of it is truncated.

**Dismissals** are a `Set<String>` of `RecurringFinding.dismissalKey` in `UserDefaults`, beside the
auto-delegation ledger and for the same three reasons: it must survive a relaunch, it carries no
content, and it is *not* a setting — it does not travel in `SyncedSettingsDocument` (ADR 0014),
because a second Mac that has never shown the card has nothing to suppress. Cleared explicitly in
`signOutAndErase`. The list under Settings → Replies is the only way back: `Hide` / `Show again`.

`AutoDelegationTrigger` gained **no case**, and the test that says so
(`RecurringFindingTests.testTheAutoDelegationRulesCarryNoRecurringFindingTrigger`) asserts the
whole enum rather than one absence, mirroring `AgentBriefTests`' rules-carry-no-drafted-text test.
A recurring finding is a state, not an edge — which is failure mode 1 of ADR 0016 — and nothing in
the detection path emits a `SyncEvent` for one to be built from.

### Automatic merging (opt-in, ADR 0018)

Auto-delegation's sibling, and the only automation that *writes to GitHub*: when a pull request an
agent opened is green, approved, not a draft and mergeable, Shepherd queues the merge itself. Off by
default, edited in Settings → Automation. `ShepherdCore/Automation/AutoMergePolicy.swift` holds
every decision (above); `Automation/AutoMergeCoordinator.swift` and `AutoMergeStore.swift` are the
app half and hold none.

Four things about it are decisions rather than mechanics:

- **It runs on the rows a sweep wrote, not on a `SyncEvent`.** GitHub does not bump a pull
  request's `updatedAt` when a check run finishes, so `prUpdated` is never emitted for the one
  transition this feature is about — the last check turning green. `SignedInSession.start`
  therefore takes an `onInboxRows` callback beside `onEvent`, fed by the same `observeInbox()`
  observation the menu-bar badge and the focus session read. A pass is consequently *repeated and
  idempotent*: the ledger's `(prID, headRefOid)` key and "skip anything with an unsent outbox row"
  are what make that safe, and with the switch off a pass is one `Bool` read. It therefore fires
  on a **state**, where auto-delegation deliberately fires only on an edge — the pull requests
  already waiting are exactly what the user switched it on for, so the first pass after the toggle
  can queue several merges, and the notification says how many.
- **The write is the merge sheet's write.** The coordinator calls
  `PullRequestActions.merge(_:method:)` through an injected seam (`AutoMergeWriting`, the
  `WebhookPosting` pattern), so the row is an ordinary `.merge(method:, expectedHeadOid:)` pinned
  to the head the decision was made on. Retry, offline, the drain's head-commit preflight and
  `mutationSent` therefore behave exactly as they do for a merge somebody pressed a button for —
  there is no second write path and no new GitHub call (ADR 0006, ADR 0015).
- **The method is the app's one remembered merge method** (`AppSettings.defaultMergeMethod`, via
  `autoMergeMethod`), shared with the merge sheet and the bulk-triage dialog and edited with the
  same `MergeMethodPicker`. A second copy could only ever disagree with the one the user sees.
- **Everything it does is visible**: one notification per *pass* (not per merge, and worded
  "queued" because the outbox has not sent anything yet), an audit log in Settings → Automation
  with a *Clear* button, and a `pr.auto_merge_queued` webhook event — the single event in ADR 0012's
  set that fires on an intent, because the fact being reported is that Shepherd decided something
  unattended. `pr.merged` still reports the send.

Device state versus setting is the usual split: the rules travel in the encrypted settings document
(`autoMerge` group, both directions of `SettingsSyncApplier`), the ledger deliberately does not —
the argument `AutoDelegationLedger` makes, unchanged — and it is cleared in `signOutAndErase`
because an audit log naming the previous account's pull requests has no business staying on screen.

### Semantic ⌘K search (on-device, ADR 0019)

⌘K answers a second kind of question: not "which command" but "which pull request was about the
token refresh". Everything about it is local — `Features/Search/` holds no client, no URL and no
key — and everything it decides is the pure `ShepherdCore/Search/` trio above.

- **`EmbeddingProviding`** is the seam, and `NaturalLanguageEmbedder` is its one production
  implementation: an `actor` (because `NLEmbedding` is not `Sendable`, and because the
  per-keystroke query embedding then happens off the main actor) wrapping
  `NLEmbedding.sentenceEmbedding(for: .english)`, chunking long documents at word boundaries and
  mean-pooling the chunks. **There is deliberately no cloud implementation and there may not be
  one**: search runs on every keystroke over every pull request, so a provider-backed embedding
  would ship the whole inbox to a third party as a side effect of typing. The BYOK endpoint is not
  merely unused here, it is unreachable — nothing in the folder takes an `IntelligenceRouter`.
- **`SearchIndexCoordinator`** (`@MainActor`) holds the corpus and runs the passes. Its trigger is
  the same `onInboxRows` callback automatic merging uses, because the inbox observation is the one
  place that reports a change to the *content* of the inbox — including the one nothing else
  announces, a detail fetch storing a diff, which arrives as a moved `detailFetchedAt`. A pass is
  low-priority, batched at twenty pull requests, composes documents in a detached task and yields
  between batches; the two hashes mean an unchanged sweep reads one small column and stops, and a
  changed row costs an embedding only when its *text* changed. `ReviewModel.onDidLoadDetail` is a
  promptness hook on top, not a correctness one.
- **The palette** keeps one ordered list (`CommandPaletteView.PaletteRow`, a command or a pull
  request), so arrows, ⏎ and Escape are unchanged; a `.task(id: query)` is the debounce, because
  cancelling a local ranking is free. Pull requests lead when the query reads like a search — two
  or more words, or an explicit `owner/repo#123` — or when no command matched; otherwise the
  commands stay on top. A row opens through `AppEnvironment.openReview(prID:)`, the same call the
  inbox row and the menu-bar row make.
- **Settings → Intelligence** carries the toggle, the size/last-indexed line and *Rebuild index*.
  It is **on by default** — like the Spotlight export beside it and the structured-triage switch
  under it, and unlike the tiers above them, because the reasons for off-by-default (something is
  sent somewhere; it costs money) apply to none of the three — see ADR 0019.
  Switching it off empties the table and leaves the lexical ranker answering.
- Device state versus setting, once more: the switch travels in the encrypted settings document
  (`search` group, both applier directions), the index does not — it is rebuildable from local
  rows, and it is dropped with the rest of the local data on sign-out.

### Structured triage (on-device, ADR 0023)

Every pull request in the inbox gets one generated verdict — `kind`, `risk`, one sentence — and
three surfaces may read it: the chip on the inbox row, the RISK facet in the rail, and ⌘K's
`risk:`/`kind:` tokens. All three sort or filter a list a human then looks at, which is the whole of
what a verdict is allowed to do.

- **`TriageClassifying`** is the seam and `OnDeviceTriageClassifier` is its one implementation: the
  `.contentTagging` system model, `@Generable` enums so the vocabulary is enforced by guided
  decoding, low temperature, a measured pre-flight, and the two `IntelligenceError` cases for a
  guardrail refusal and a context overflow. **There is deliberately no cloud implementation and
  there may not be one** — the pass is unattended, and ADR 0007's tier-3 argument (a human clicked,
  on one pull request, and can see the answer) covers none of it. The `Codable` twin
  (`ShepherdCore/Intelligence/IntelligenceOutputs.swift`) is what the UI and the database see.
- **`TriageCoordinator`** (`@MainActor`, `Features/Triage/`) runs the passes on the same
  `onInboxRows` callback automatic merging, the Spotlight export and the search index use. It is a
  *peer* of `SearchIndexCoordinator`, not a step inside it: chaining it to the end of an indexing
  pass would have been cheaper, but with semantic search switched off that pass composes documents
  from inbox rows alone, so triage would quietly start classifying titles because a different
  feature's toggle moved. Both staleness gates are ADR 0019's — the in-memory `sourceFingerprint`
  decides whether a diff is read out of SQLite at all, the persisted `documentHash` decides whether
  a *generation* is spent — and the pass is batched at twenty for the read, sequential for the
  generations, `.utility` priority, cancellable, with mid-pass rows merged per pull request.
- **The tier-1 half needs no model and is what the feature degrades to.**
  `ShepherdCore/Triage/TriageInput.swift` turns `FilePrioritizer`'s reasons into the hint sentences
  that go *into* the prompt and into a heuristic risk level read straight off its buckets. A pull
  request with no stored diff has no risk at all rather than a default one. So the rail keeps a RISK
  section with Apple Intelligence off, and its tooltip says how much of a count is the model's.
- **Nothing else may read a verdict**, and that is a test rather than a comment:
  `StructuredTriageTests.testNoAutomationInputCanSeeAVerdict` walks the inputs of `BulkTriagePlan`,
  `AutoMergePolicy` and `AutoDelegationPolicy` reflectively and fails when any value reachable from
  them is a triage type.
- Device state versus setting, once more: the switch travels in the encrypted settings document
  (`intelligence.structuredTriageEnabled`, both applier directions), the verdicts do not — they are
  rebuildable from local rows, they are emptied when the switch goes off, and they go with the rest
  of the local data on sign-out.

### In-app updates (ADR 0010)

`Support/UpdateController.swift` is the only file that imports Sparkle. It owns a
`SPUStandardUpdaterController`, is created by `AppEnvironment` at launch, and is reached from
exactly two places: the "Check for Updates…" item under "About Shepherd" in the app menu
(`ShepherdCommands`) and the UPDATES card on the Account settings tab.

The one non-obvious thing it does is **refuse to start**. The controller is built with
`startingUpdater: false`, the `Info.plist` configuration is validated first (`UpdateConfiguration`:
`SUFeedURL` must be an absolute web URL, `SUPublicEDKey` must base64-decode to exactly 32 bytes),
and only then is the updater started through the throwing `SPUUpdater.startUpdater()`. The reason
is that `SPUStandardUpdaterController.startUpdater()` answers a misconfigured plist by logging and
then showing the user an alert telling them to contact the developer — correct for a shipped app
whose feed broke, and exactly wrong for a source build or a fork with no signing key, which is
every build until the maintainer has run `generate_keys` once. A build without keys therefore gets
a disabled menu item and one line in Settings; it never gets an alert, and the failure is a value
(`UpdateProblem`) rather than a log line.

The automatic-check toggle is the app's one preference that deliberately does *not* live in
`AppSettings`: Sparkle persists `automaticallyChecksForUpdates` in the host's user defaults
itself, so `UpdateController.checksAutomatically` mirrors that property and a second stored copy
could only ever disagree with the one the updater reads. Sparkle may find an update in the
background but never installs one silently (`SUAllowsAutomaticUpdates: false`) — unsent review
drafts live in the database, and an app that replaces itself mid-review would lose them.

The release side of this — feed URL, signing, notarization, appcast — is `Scripts/release.sh` and
[docs/RELEASING.md](RELEASING.md).

### Local diagnostics (ADR 0017)

`Diagnostics/DiagnosticsReporter.swift` is the only file that imports MetricKit. It is an
`NSObject` conforming to `MXMetricManagerSubscriber`, created inert by `AppEnvironment`, and it
subscribes to `MXMetricManager` only while `AppSettings.diagnosticsEnabled` is on. That flag is the
whole gate: with it off, `add(_:)` was never called, so macOS delivers nothing and there is no
filtering step to get wrong. `didReceive(_ payloads: [MXDiagnosticPayload])` writes each payload's
`jsonRepresentation()` — verbatim, no re-encoding — into
`~/Library/Application Support/Shepherd/Diagnostics/`. The other delivery,
`didReceive(_ payloads: [MXMetricPayload])`, is an explicit no-op: daily performance metrics are
precisely what this app does not keep.

Three details are load-bearing:

- **The split.** `MXDiagnosticPayload` has no initialiser, so the seam is one level down:
  `DiagnosticsStore.store(jsonRepresentation:receivedAt:)`. The store owns the file name (a
  fixed-width UTC stamp built from `DateComponents`, not a `DateFormatter`, so the name is a pure
  function of the date), the 30-file retention trim, the count, and a "delete all" that only ever
  removes files matching `diagnostic-*.json`. All of that is tested over a temporary directory; the
  subscriber above it has nothing left to test.
- **Isolation.** MetricKit does not promise a queue, so the reporter is *not* `@MainActor`: both
  callbacks are `nonisolated` and the subscription flag is behind an `NSLock`, which also closes the
  race between "toggle switched off" and a batch already in flight. `setSubscribed(_:)` and
  `revealInFinder()` are `@MainActor` because `MXMetricManager` and `NSWorkspace` are reached from
  there.
- **One route to the subscriber.** The flag changes from the Settings toggle *or* from an applied
  settings-sync document (ADR 0014), so both go through `AppEnvironment.applyDiagnosticsSetting()` —
  the toggle calls it directly and `ShepherdApp` re-applies it on change, exactly as the appearance
  preference does. `setSubscribed(_:)` is idempotent for that reason.

No network code exists in this path, and none may be added without a new ADR: see the
"Diagnostics stay local" rule in CONTRIBUTING.md.

### Apple-native text intelligence (ADR 0020)

Two system frameworks, deliberately *not* on ADR 0007's ladder — they need no provider, no key, no
prompt and no token budget, so routing them through `IntelligenceProvider` would only give the two
cloud providers a method that could send somebody else's comment to an endpoint.

**Writing Tools** is a modifier, set explicitly on every text control rather than left to
`.automatic`: `.complete` on `ComposerTextEditor` (which is the review summary, the inline comment
composer, the saved-reply body and the review-template body — one line, four fields), on the thread
reply field and on the delegation task field; `.limited` on the saved-reply name and on the
auto-delegation prompt template, whose `{{…}}` placeholders a rewrite would eat; `.disabled` on the
review-template repository pattern, which is a glob and not language. Nothing in the webview
(ADR 0003's rule that all text entry is native is unchanged), and no setting — it is the system's
capability, and it complements the ✨ draft: the draft lands in the field, Writing Tools refines it
there, and neither has a path to GitHub that skips the reviewer's click.

**Translation** lives in `Intelligence/Translation/` and is the only place in the app that imports
`Translation` or `NaturalLanguage`; `Packages/ShepherdKit` gains neither, so it keeps building on
Linux. Three pieces:

- `TranslationOffer` — the offer rules. `decide(source:target:isPairSupported:)` is pure and
  therefore tested; the async shell asks `NLLanguageRecognizer` for the source language (over prose
  only: fences, inline code, links and `@mentions` stripped, a length floor and a confidence floor)
  and `LanguageAvailability().status(from:to:)` for the pair. `.installed` and `.supported` both
  count as available — `.supported` means macOS will offer its own language-pack download on the
  first call. Result: a button, a disabled button naming the pair, or no button at all when the text
  is already in the reader's language (compared on the ISO-639 code, so `en-GB` → `en-US` is never
  offered).
- `TranslationCoordinator` — a `@MainActor @Observable` in-memory cache keyed by `(text, target
  language)`, owned by the screen (the conversation tab; each thread popover). Bounded, oldest
  first. Nothing persisted, nothing synced, so it is not a setting and ADR 0014's obligation does
  not reach it. Keying on the text rather than a hash is what makes it survive a sweep replacing
  `model.detail` or a `ForEach` rebuild — and what makes a collision impossible.
- `TranslatableMarkdownText` — wraps `MarkdownText` and draws the translation in a tinted block
  *below* the original, with a *Hide translation* toggle and no "show original", because the
  original is never taken away. `TranslationSession` is obtained from `.translationTask(_:action:)`
  and never leaves that closure (it is not `Sendable`): the closure captures the key and the
  coordinator, and only the translated `String` crosses back, through `MainActor.run`.

The condensed activity list is not translatable on purpose: a `TimelineEvent.summary` is a fixed
Shepherd word or a commit headline, never a comment body (see `ResponseMapping.timeline`).

### Test target

`ShepherdTests` (added to `project.yml`, sources in top-level `ShepherdTests/`) covers the
pure parts of the app: the bridge protocol against the **shared fixtures**, which are copied
into the test bundle as a folder reference from `web/diff-viewer/fixtures` so both languages
decode the same bytes; the patch reconstruction; the Markdown sanitiser; the keyboard,
palette and inbox-ordering logic (including the bulk-triage tick selection and every
bulk-triage label, ADR 0015; the full key-assignment table, so a new sequence cannot quietly take
a key another command owns); the menu-bar quick inbox's pure half (which rows count as waiting,
the cut at eight rows with its "n more…" count, the deterministic order, and the badge — blank at
zero, `"99+"` above 99); the focus review session (the frozen queue's contents and order, that a
pull request arriving mid-session does not join it, every cursor transition including skipping the
last entry and completing the last entry, an entry that left the inbox being walked past when it
is reached, an empty queue producing no session at all, and both shapes of the closing summary); the intelligence endpoint layer (preset ↔ base-URL matching,
`/models` parsing against fixtures, and the settings-side discovery gate through `ModelListing`);
AI drafting (the diff excerpt's window and character cap against a long-diff fixture, the
per-tier budget accounting for a digest plus quoted comments, the draft prompts and both cloud
shapes' encoded request bodies, the answer parser against JSON/fenced/prose answers, the router's
degradation ladder through `IntelligenceTiers`, the streaming ladder through its two streaming
closures — first element, mid-stream failure, an empty answer stepping down a tier — and
`AIDraftFieldState`'s replace/append/label rules for both a value and a stream);
the delegation engine (stream-event fixtures, argv
construction, template splitting, git command sequences, state transitions) and the app half of
auto-delegation (event → signal mapping, ledger persistence across a relaunch, cap notices —
ADR 0016; the decision itself is tested in `ShepherdCoreTests`); the app half of auto-merge
(one write request per eligible row and none for the others, the audit entry's contents, a second
pass over the same commit asking for nothing, a new head asking again, the ledger surviving a
relaunch, one banner for a batch, and the webhook plan — ADR 0018; the decision itself, again, in
`ShepherdCoreTests`); the webhook
layer (payload schema against decoded JSON, the HMAC against the RFC 4231 vector, URL
validation, the retry policy through the `WebhookPosting` seam, and the event mapping); the
encrypted settings sync (envelope round trip, wrong passphrase and AAD tampering as one defined
error, KDF parameters — a low iteration count in the tests, the production constant asserted
separately — SigV4 against the official AWS vectors, the three signed requests byte for byte, the
document codec with unknown fields, and capture/apply over in-memory secret and token stores);
the morning digest's delivery half
(a switched-off digest posting nothing and recording nothing, a due one posting exactly one
notification with the day in its identifier, a quiet night recording the delivery *without* a
banner, five checks in five minutes still producing one digest, the card surviving until the day
rolls over and going with a dismissal or with the toggle, a tick before the inbox observation has
spoken leaving the day open, and the notification body's wording — the due rule and the report
itself are tested in `ShepherdCoreTests`);
the saved-reply and review-template store (order surviving a relaunch, editing in place, the
reorder clamped at both ends, and which replies the insert menu is allowed to offer — the matching
and prefill rules themselves are tested in `ShepherdCoreTests`);
the update configuration (ADR 0010: the placeholder key, a truncated key, a
relative or non-web feed URL and an empty `Info.plist` must each end as "updates off, with a
reason" rather than as a Sparkle alert); the local diagnostics folder (ADR 0017: the UTC file name
as a pure function of the date, two reports in one second, the 30-file retention trim, "delete all"
leaving a foreign file alone, and the opt-in — off on a fresh install, and switching it off really
calling `remove(_:)`, asserted through the subscription seam so the test host never registers with
the real MetricKit);
the app half of semantic search
(ADR 0019: one embedding per pull request and none for a second pass over unchanged rows, a new
title costing exactly one, a row that only moved its `updatedAt` keeping its vector, a pruned pull
request leaving both the corpus and the table, a diff stored for review becoming searchable, the
exact-slug shortcut, an embedding finding a pull request the words do not, the two degraded states —
no model, and the toggle off — both still answering, and the chunker's boundaries; the document
composition and the ranker are tested in `ShepherdCoreTests`, the table in
`ShepherdPersistenceTests`, so both run on the Linux runner);
"why is CI red?" (ADR 0024: the log tool with a fake `JobLogFetching` — the digest reaching the
model, the read going to the right job once, and the four ways to have no log; the card's state
machine through scripted tiers — the trace and the tier kept, the cloud rung offered for a budget
failure *and only when a key is configured*, `preferCloud` reaching the cloud tier only from the
button, a cloud failure not offering itself again, every other failure as one line, nothing red
asking no tier at all; what the brief is handed; and the card's copy. `LogDigest`, the job-id
parser and the read itself are tested in `ShepherdCoreTests`/`GitHubKitTests`, so they run on the
Linux runner);
the claims-vs-evidence card's state (ADR 0026: an empty report drawing nothing, expanded for a
recognised agent and collapsed for a person *and* for an unrecognised bot, the reviewer's toggle
surviving a background refresh, the comment text's assembly, and the replace/append/discard
question over a summary that already has text in it — the extractor, the evidence rules and the
report are tested in `ShepherdCoreTests`, so they run on the Linux runner);
the feedback loop's app half (ADR 0029: the third comment producing a card, a colleague's comment
never being *read* even though its vector would have joined the cluster, a comment outside the
window costing not one embedding, a repeated body costing none, an unchanged sweep costing none, no
embedder meaning no card and no complaint, a dismissal surviving a relaunch while staying listed in
Settings, sign-out forgetting both, what the delegation context and the template carry, that the
steering sentence leads the quoted comments and survives into the request uncut, and that
`AutoDelegationTrigger` has no case a recurring finding could be armed with — the clustering,
the thresholds and both total orders are tested in `ShepherdCoreTests`, so they run on the Linux
runner);
the translation offer rules and cache (ADR 0020: the pure decide-to-offer function including
`en-GB` → `en-US`, the prose strip and both detection floors, and the cache's keying, collapse and
eviction — `TranslationSession` itself is not mocked);
the German catalog's *wiring* (ADR 0022: three keys, one of them interpolated, resolved out of
`Bundle.main` against an explicit `de` locale, plus the English round trip — the exhaustive
key-by-key coverage is `Scripts/check-localization.py`, which needs no Xcode and therefore runs on
the Linux job; what only a built bundle can prove is that the catalog reached the resources phase,
that `xcstringstool` compiled a German table, and that a lookup goes through it — three steps that
all fail silently);
the intelligence evaluation corpus (plan §0.4: every fixture decodes, every expected kind, risk
and file status is a case the domain has, every CI fixture is a 30–60 line tail that names
something to measure — and the whole class skips itself unless `SHEPHERD_EVAL=1`, because it
measures a model rather than the code);
and the app-side half of deep linking (resolving `owner/repo#number` against cached rows, filter
token → rail state). The `shepherd://` grammar itself is tested in `ShepherdCoreTests` instead, so it
runs on the Linux runner too. The web
bundle is likewise added to the app target as a
folder reference (`Shepherd/Resources/DiffViewer`) so `index.html` keeps its relative links.
