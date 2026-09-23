# Shepherd Architecture

This document is the binding contract between Shepherd's modules. If code and this document
disagree, fix one of them in the same PR. Decisions behind this design: [docs/adr](adr).

## Repository layout

```
Shepherd/                      # macOS app target (SwiftUI, macOS 27+)
  App/                         #   @main, DI container (AppEnvironment), shepherd:// routing
  Features/
    Inbox/                     #   inbox list, sections, filters, command palette actions;
                               #   the issues section beside it — content-kind picker, issues
                               #   model, rail, list, detail panel, linked-PR row (ADR 0032)
    Digest/                    #   morning digest: due-check loop, inbox card, wording
    MenuBar/                   #   menu-bar quick inbox: badge label + mini-inbox window
    PullRequest/               #   PR detail: header, timeline, file list, checks
    Review/                    #   review composer, pending review UI, thread views,
                               #   focus review session (frozen queue + session bar)
    DiffViewer/                #   WKWebView host + bridge (Swift side)
    Delegation/                #   delegate-to-local-agent model + sheet (ADR 0011, 0016);
                               #   session back-channel: decisions + confirmation (ADR 0030);
                               #   free-text repository tasks (ADR 0011, 2026-09-23 amendment)
    Editor/                    #   "Open in editor": opener + menu item (ADR 0039)
    Search/                    #   ⌘K semantic search: on-device embedder, index coordinator,
                               #   result row (ADR 0019); the issue result row beside it, fed
                               #   by the coordinator's second pass (ADR 0032)
    Settings/                  #   accounts (+ updates, local diagnostics), sync (+ encrypted
                               #   cross-Mac sync), replies (saved replies + review templates),
                               #   agents, AI, delegation, automation, theme (+ menu-bar toggle)
    Onboarding/                #   device-flow sign-in, PAT entry
  Intents/                     #   App Intents (Shortcuts/Siri) + Core Spotlight export of the
                               #   inbox — app target only, the sole importers of AppIntents and
                               #   CoreSpotlight, except that Support/NotificationManager imports
                               #   AppIntents to name a notification's PullRequestEntity; both
                               #   route through DeepLink (ADR 0021 and its 2026-09-22 amendment)
  Automation/                  #   outbound webhook payload, signing, dispatcher (ADR 0012);
                               #   auto-delegation coordinator + ledger store (ADR 0016);
                               #   auto-merge coordinator + ledger/audit store (ADR 0018);
                               #   merge-when-green coordinator + store (ADR 0037)
  SettingsSync/                #   encrypted settings document, envelope, SigV4, S3 client (ADR 0014)
  Diagnostics/                 #   MetricKit subscriber + local report folder (ADR 0017)
  Intelligence/                #   IntelligenceProvider impls (FoundationModels, Anthropic)
    Translation/               #     on-device translation of PR text: offer rules, cache, view (ADR 0020)
  Support/                     #   AppConfig, keyboard shortcuts, theming, notifications,
                               #   Sparkle updater wrapper (ADR 0010)
    AgentCLI/                  #   agent-CLI engine: config, locator, stream parser, worktrees
    Editor/                    #   editor choice + pure URL/argv construction (ADR 0039)
  Resources/                   #   Assets.xcassets, DiffViewer/dist (built web bundle),
                               #   Localizable.xcstrings (en keys + de, ADR 0022)
Packages/ShepherdKit/          # SPM package, NO AppKit/SwiftUI imports
  Sources/
    ShepherdCore/              #   domain models, agent detection, heuristics, drafts
      Agents/                  #     provenance detection + registry (ADR 0008); the
                               #     `Claude-Session:` return address and the message a
                               #     finding becomes (ADR 0030)
      Claims/                  #     claims read from the description + evidence over the diff
                               #     and CI, one line per claim, no score (ADR 0026); the
                               #     acceptance bullets of a referenced issue and the matcher
                               #     over them (ADR 0026's amendment)
      Review/                  #     saved replies, per-repo review templates + matching rule,
                               #     recurring-finding clustering over the reviewer's own
                               #     comments (ADR 0029)
      Routing/                 #     shepherd:// grammar + CLI argument grammar (ADR 0013)
      Triage/                  #     bulk-triage partition + intended writes (ADR 0015); the
                               #     issues rail's age buckets and its label/age/agent-PR
                               #     facet counting (ADR 0032)
      Automation/              #     auto-delegation rules, ledger and policy (ADR 0016);
                               #     auto-merge rules, ledger/audit log and policy (ADR 0018);
                               #     merge-when-green request, list and policy (ADR 0037)
      Digest/                  #     morning-digest report + delivery schedule
      Search/                  #     search document, lexical ranker, vector value (ADR 0019);
                               #     the issue document and its ranker beside them (ADR 0032)
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
  `checks: [CheckRun]`, `closingIssues: [LinkedIssueReference]`. Its decoding is tolerant of
  every list being absent and of the summary alone being present, which is what lets a record
  encoded before a field existed still decode (ADR 0032's Sprint 3 amendment)
- `LinkedIssueReference` (`Models/Issue.swift`) — an issue a pull request will close: `repo`,
  `number`, `title`, `state: IssueSummary.State`. `LinkedPullRequestReference`'s mirror image and
  deliberately not an `IssueRowSummary` — `closingIssuesReferences` carries four fields, the issue
  may live in another repository, and it may be an issue no facet of the issues sweep returns. No
  author, because a provenance chip is a question about a pull request
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
  assertion drift and for removed exported declarations per language. Every fact is an
  `EvidenceFact.Kind` — a closed set of sentence templates carrying the counts, paths, issue
  number, code snippets and matched words the sentence is made of — plus an optional
  `path`/`line`; `EvidenceFact.englishSentence` renders it here, purely, and the app renders the
  same case into German (below). The status (`ok` / `contradicted` / `unclear`) is *derived from
  the facts* by rules documented per claim. `ClaimsEvidenceReport.build(detail:summary:)` composes
  the lines and has **no aggregate field at all** — a score would be a verdict. `ClaimList` /
  `ExtractedClaim` are the `Codable` twin of the optional on-device pass, and
  `ClaimList.merged(into:)` is what makes that pass *additive*: the pattern claims come out
  unchanged, a model claim repeating one of them is dropped by the same `dedupKey`, and what
  survives is marked `Claim.origin == .model` (ADR 0026's tier-2 amendment).
- `AcceptanceCriteria` / `AcceptanceMatcher` (`Claims/`) — the `fixes #N` half of the card, as
  values (ADR 0026's amendment). `AcceptanceCriteria.bullets(from:) -> [AcceptanceBullet]` reads an
  issue body in three documented passes: `- [ ]`/`- [x]` checkboxes wherever they are, else the
  first list under a heading (or a `…:` label) containing *acceptance* / *criteria* / *done* /
  *todo* / *requirements*, else the first list in the body — capped at 12, decoration stripped,
  duplicates dropped. `AcceptanceMatcher.match(bullets:against:vectors:) -> [AcceptanceMatch]`
  decides *mentioned* or *not mentioned* per bullet: keyword overlap over `SearchText.tokens`
  (≥ 4 characters, minus a small stop list, ≥ 40 % of the bullet's distinctive words present) with
  `SearchVector.cosineSimilarity` ≥ 0.6 as a second pass when the app supplied vectors. The answer
  is an `AcceptanceMatch.Reason` — four cases carrying the matched words, the totals and the
  cosine — with its own `englishSentence`, so the card can say it in German.
  `evidenceText(for:)` is the haystack — description, changed paths, commit messages, clamped to
  20 KB, and deliberately **not** the hunks. `EvidenceChecker.check(_:in:issue:matches:failure:)`
  turns the matches into one fact per bullet (`EvidenceFact.mark`) and derives ✓ only when every
  bullet is mentioned; ✗ is unreachable for this claim, which is a test rather than a comment.
  `IssueLookupFailure` is the four answers a failed read contributes, each with its English
  sentence.
- `IssueSummary` (`Models/`) — number, title, body, state and the `isPullRequest` marker; nothing
  else, and nothing persisted.
- `IssueRowSummary` / `IssueDetail` / `IssueRelation` / `LinkedPullRequestReference`
  (`Models/Issue.swift`) — the *persisted* issue, and deliberately not the type above (ADR 0032).
  The row is the issues inbox's `PullRequestSummary`: node id, repository, number, title, author,
  `createdAt`/`updatedAt`/`closedAt`, `IssueSummary.State` (reused, not re-declared), GitHub's raw
  `stateReason`, labels, the relation set the three facets imply, the comment count, and the pull
  requests GitHub says will close it — each stored by value, repository included, because a linked
  pull request may not be in the local inbox at all. `hasAgentPullRequest` is *derived* from those
  links' own `ActorKind.isMachine`, so the facet, the chip and the denormalised column in `issues`
  cannot disagree. `IssueDetail` is the row plus `bodyMarkdown` and nothing else: the detail panel
  shows title, body, labels and links, so there is no `PullRequestDetail.timeline` twin.
- `IssueAgeBucket` (`Triage/`) — `today`/`thisWeek`/`thisMonth`/`older`, bucketed off `createdAt`
  against a moment the caller states (ADR 0032). Elapsed spans rather than calendar edges, so the
  answer needs no locale and is the same on both of a user's Macs; the rail, `IssueFilter` and the
  test all read this one function.
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
- `MergeWhenGreenPolicy` / `MergeWhenGreenRequest` / `MergeWhenGreenList` (`Automation/`) — a
  merge the user decided on while the checks were running, as a value (ADR 0037).
  `decide(request:pullRequest:existingOutbox:)` returns `.merge(expectedHeadOid:)`,
  `.wait(reason)` or `.abandon(reason)`, in a fixed order with the head commit checked first: the
  request pins the commit, the method and the branch answer the sheet showed, and a push means the
  decision no longer applies. Unlike `AutoMergePolicy` it checks no approval and no authorship —
  the human formed the verdict at the click — and treats unknown mergeability as a wait, not a
  refusal. The list is one entry per pull request, machine-local, never in the settings document.
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
  `DigestReport.make(pullRequests:issues:parkedReviewCount:failedWriteCount:windowStart:now:)` turns
  cached inbox rows, cached issue rows and the two standing outbox counts into ordered sections with a count and up to
  three named rows each; an empty report is the signal for "say nothing at all". The predicates are
  *borrowed*, not restated: `PullRequestSummary.needsMyReview`,
  `BulkTriagePlan.greenAgentPullRequests(in:)` (ADR 0015), `AutoDelegationPolicy.isOwn(_:)`
  (ADR 0016) and `IssueRowSummary.hasAgentPullRequest` (ADR 0032). Two of the seven sections are
  windowed (`DigestSectionKind.isWindowed`) — the review requests and the issues assigned to you,
  both on `updatedAt`, because that is the field GitHub moves when somebody hands you something.
  The other five are standing state, because a green agent PR nobody merged is exactly what a
  morning brief is for and a windowed version would go quiet on the second morning; the same
  argument makes `agentPullRequestsThatClosedAnIssue` a state, and it stops repeating by itself
  because a closed row is kept only for the sweep's retention window (14 days) and pruned after it.
  That the row exists at all is the sweep's outcome capture: the search asks for open issues only,
  so without it a closed issue would vanish before any digest could read it.
  `issues:` defaults to none, so a caller predating the issues inbox gets the report it always got,
  and `Item.prID` carries the issue's node id for an issue row — the generic reuse `OutboxItem`
  makes, with `DigestSectionKind.isAboutIssues` telling a reader which it is holding. `DigestSchedule.window(now:lastDeliveredAt:calendar:)` is the whole
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
- `IssueSearchDocument` / `IssueSearchRanker` (`Search/`) — the same two values for the issues half
  of ⌘K, as **siblings** rather than a generalisation (ADR 0032). Four fields where the pull
  request has eight — `title` (3), `identity` (3), `labels` (2.5), `body` (1), the same weights
  those fields carry there — because an issue has no branch, no paths and no diff, and no author
  field because the rail answers "whose issues" with a facet. The ranker duplicates the BM25 loop,
  the exact-reference override and the similarity floor, and shares `SearchRankingOptions`, the two
  standard constants and `SearchQuery`'s parser, so one query cannot be scored on two curves
  depending on which half of the palette answers it. One divergence: a query that is nothing but a
  `risk:`/`kind:` token returns nothing here, because a triage verdict is a statement about a pull
  request. `SearchDocument` and `SearchRanker` are untouched.
- `Interdiff` / `FindingState` / `ReviewFindings` / `UnifiedPatch` / `PatchReconstructor`
  (`Review/`) — the whole of "since my review" as pure text work (ADR 0028), plus the two documents
  the diff viewer renders. `UnifiedPatch.reconstruct(after:)` rebuilds the *head* side of a unified
  patch as lines, padding the gaps between hunks so a 1-based index is GitHub's own line number;
  `PatchReconstructor` rebuilds *both* sides from the same `hunks(in:)` and keeps the viewer's
  commentable-line sets, which is more than the interdiff needs. It lives here rather than in the
  app target so that the app's fiddliest pure logic is exercised on the Linux leg.
  `Interdiff.compute(before:after:)` pairs the two rounds' `ChangedFile` lists by path (a rename by
  `previousPath`), diffs the reconstructions line by line — common prefix/suffix by scanning, the
  middle by LCS, with a cell cap past which the region becomes one replacing hunk — and returns
  one `InterdiffFile` per file that differs, each carrying its hunks *and* a synthesized unified
  patch in GitHub's own shape, so the Monaco viewer renders a round through the existing
  `loadFile` message. Identical files are omitted; a rename is listed even when its content did not
  change.
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
- `TrustLane` / `TrustLaneInput` / `TrustLaneConfiguration` / `TrustSensitivePaths` (`Trust/`) —
  the whole of "how much attention does this deserve" as pure values (ADR 0027).
  `TrustLane.classify(_:configuration:)` takes a `TrustLaneInput` — check state, changed files,
  changed lines, one `sensitivePaths` flag — and answers `shortLook` or `fullReview`. The *type* is
  the rule: there is nowhere in it for a history, and `ShepherdCoreTests` asserts that reflectively.
  A short look needs all three of a `success` rollup, both thresholds and no sensitive path; the
  flag is `true` when the answer is unknown, so a pull request whose diff has not been fetched is a
  full review. `TrustSensitivePaths` names the exclusion over `FilePrioritizer`'s own
  classifications (its `securityPathHints` and `category(of:)`) plus workflows and migrations, so
  the lane and the file order cannot disagree about a path. `TrustLaneConfiguration` clamps both
  thresholds (`1...100` files, `1...5000` lines) on construction and decodes tolerantly.
- `PullRequestOutcome` / `ClosedPullRequest` / `TrackRecord` / `TrackRecordSubject` /
  `RevertDetector` (`Trust/`) — the track record as pure counting (ADR 0027).
  `TrackRecord.compute(outcomes:subject:repo:since:)` tallies merged, closed-unmerged, reverted, the
  first-push-green rate and the median number of change-requesting rounds, for one author in one
  repository since one date; every optional is `nil` rather than a substituted zero when its
  denominator is empty, because a rate with no denominator would be invented. A reverted pull
  request is still counted as merged. `TrackRecord.windowDays` is the single definition of the
  ninety days three surfaces quote. `RevertDetector.revertedTarget(title:body:)` reads
  `Revert "…"` titles, `This reverts commit <sha>` bodies and `Reverts #n` phrases;
  `links(candidates:known:)` pairs them with the merged pull requests they undo — by merge commit,
  then number, then exact title, only inside one repository and only backwards in time.
  `ClosedPullRequest` is the outcome plus the number, title and merge commit that revert detection
  matches on, which is why those three are stored although nothing counts them.
- `DeepLink` (`Routing/`) — the whole `shepherd://` grammar as a value: `parse(URL) -> DeepLink?`
  and `urlString` in the other direction, round-trip tested. Strict by construction (closed
  vocabularies, GitHub's own character rules, decoding *after* the path split), because a URL is
  untrusted input. `fleet` is the one command whose argument is optional — `shepherd://fleet` is
  the list and `shepherd://fleet/<agent-id>` one agent's page — and its segment is validated as an
  **agent-registry id**, never a login, which is one of the four places ADR 0035 keeps the fleet a
  ledger of agents rather than of people. Companion: `ShepherdCommandLine`, the `shepherd` CLI's argv grammar, kept in
  the same folder so the grammar the CLI writes and the grammar the app reads cannot drift
  (ADR 0013).

## GitHubKit

- `GitHubClient` (actor) — façade over GraphQL + REST with one `URLSession`:
  - `searchOpenPullRequests(queries:) async throws -> [PullRequestSummary]` (GraphQL search,
    ADR 0005)
  - `pullRequestDetail(repo:number:) async throws -> PullRequestDetail`
  - `closingIssues(repo:number:) async throws -> [LinkedIssueReference]` — the issues a pull
    request will close (ADR 0032's Sprint 3 amendment), `closingIssuesReferences(first: 10)`.
    GraphQL-only, for `reviewThreads`' reason: REST carries the description's `closes #123` text
    but not the references GitHub resolved out of it. Called from inside the detail fetch beside
    that one, and it is the single read there whose failure is **tolerated** — the files, commits
    and threads are the review, while the closing issues are a section above the description, so a
    token that cannot see the issues' repository costs the section and not the review. A caller
    that asks on its own still gets the error
  - `searchClosedPullRequests(repo:since:cursor:pageSize:) async throws -> ClosedPullRequestPage`
    and `closedPullRequest(repo:number:) async throws -> ClosedPullRequest?` — the track record's
    two reads (ADR 0027). The first is the *same* `search(type: ISSUE)` connection as the sweep
    with `is:closed` in place of `is:open`, one repository at a time; the second is one GraphQL
    read of one pull request, carrying `merged`, `closedAt`, the change-requesting review count,
    the **first** commit's rollup and the text revert detection needs — so neither is a detail
    fetch. The paged one is conditionally cached under a key the client names itself (repository,
    window, cursor), because a GraphQL request cannot be keyed on its URL; the single one is not
    cached at all, for the reason `/check-runs` is not
  - `searchOpenIssues(queries:) async throws -> [IssueRowSummary]` — the issues sweep (ADR 0032).
    The *same* `search(type: ISSUE)` connection as the inbox sweep with `is:issue` in place of
    `is:pr`, three facets (`assignee`/`author`/`mentions:@me`), the same five-page cap, the same
    merge-by-id — and `closedByPullRequestsReferences(first: 5, includeClosedPrs: true)` selected
    inside the page, so the links are not a second round trip. The `timelineItems`
    (`CROSS_REFERENCED_EVENT`, `CONNECTED_EVENT`) shape is kept as a fixture-tested fallback
    document and mapper that the client does not send, so a schema regression is a one-line switch
  - `issueRow(repo:number:) async throws -> IssueRowSummary?` — the same `... on Issue` field set
    under `repository { issue(number:) }`, so a row it produces cannot be shaped differently from a
    swept one, and it claims no relation. Two callers, both of them "one issue nobody swept": a
    `shepherd://issue/…` link the cache does not have (ADR 0032's Sprint 2 amendment), and the
    sweep's outcome read for an issue that left the search (its 2026-09-03 amendment)
  - `issue(repo:number:) async throws -> IssueSummary` — one REST
    `GET /repos/{o}/{r}/issues/{n}` for the claims card's `fixes #N` line (ADR 0026's amendment).
    REST, not GraphQL, precisely so the conditional-request cache can key on the URL; the URL is
    immutable, so — unlike `/check-runs` — it leaves one row per issue however often it is read.
    The endpoint serves pull requests too, and `IssueSummary.isPullRequest` reports that rather
    than the read refusing
  - `issueState(repo:number:) async throws -> IssueState` — the issue staleness probe (ADR 0032's
    Sprint 4a amendment), `issue(number:) { id updatedAt closed }`. `headRefOid`'s twin for the
    other kind of node, and GraphQL rather than the REST issue read above it precisely because
    that one is ETag-cached on its URL: a probe answerable from a cache is not a probe
  - `addIssueComment/addIssueLabels/addIssueAssignees/setIssueState` — the four issue triage
    writes (ADR 0032's Sprint 4a amendment), all REST on `api.github.com`. The labels and
    assignees endpoints are the **additive** `POST .../labels` and `POST .../assignees` rather
    than the full-replace `PATCH`, so two writes queued a second apart cannot race each other into
    a lost update; `setIssueState` sends `state` and `state_reason` and nothing else, because that
    endpoint would otherwise happily rewrite the title, body, labels and assignees somebody else
    just changed
  - `submitReview(_ draft: ReviewDraft, on:) async throws` — REST
    `POST /pulls/{n}/reviews` with full `comments` array; maps verdict to `event`
  - `replyToComment/resolveThread/unresolveThread/mergePullRequest/markReadyForReview…`
  - `headBranchContext(repo:number:)` / `deleteBranch(repo:name:)` — the two halves of the merge
    sheet's "delete the branch afterwards" (ADR 0005's 2026-09-05 amendment): one small GraphQL
    read of the head branch, the repository it lives in and the base repository's default branch,
    then `DELETE /git/refs/heads/{branch}`. Asked for only by a merge outbox row that carries
    `deletesHeadBranch`, and the drain swallows whatever the deletion says — the merge has already
    happened by then
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
`review_snapshots`, `pull_request_outcomes`, `issues`, `issue_search_index`,
`issue_linked_pull_requests`, `pull_request_closing_issues`).
Append-only migrator — currently `v1` through `v7`. `v3` is the search index (ADR 0019: one
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
`v6` is `pull_request_outcomes` (ADR 0027: one row per **closed** pull request — `prID` is the
primary key, so both writers upsert — holding the repository by value, `openedAt`/`closedAt`,
`merged`, `revertedByPRID`, a **nullable** `firstPushCIGreen` (red and unknown are different
facts), `reviewRounds`, `changedLines`, `source` (`sync` | `backfill`), and the `number`, `title`
and `mergeCommitOid` revert detection matches on. It is the one derived table with **no foreign key
and no cascade**: a row is written exactly when a pull request *leaves* the inbox, so the pruning
the other three rely on would delete every row the feature is made of. One index,
`(repoFullName, agentName, closedAt)`, which is the badge's own query. Read by the badge and by the
inbox's secondary sort, and by nothing else — the automation paths cannot even see the types).
`v7` is the issues inbox (ADR 0032: four tables in one migration). `issues` follows
`pull_requests`' exact column shape for the author, the agent, the relations and the labels — so
`IssueRecord` and `PullRequestRecord` share `ColumnCoding`'s helpers — plus a body and a
`detailFetchedAt` stamp, and two **denormalised** columns, `linkedPullRequestCount` and
`hasAgentLinkedPullRequest`, re-derived from the links on every write because the "has an agent
pull request" facet filters the whole inbox on every click. `issue_linked_pull_requests` holds the
full list for the detail panel and has **no foreign key onto `pull_requests`** (the linked pull
request may be somebody else's, or never fetched, so the row is about what the sweep saw);
`pull_request_closing_issues` is the other direction and *does* cascade with `pull_requests`, like
`changed_files` — it landed with this migration so the linking sprint needed none of its own, and
`savePullRequestDetail` is its writer: the rows are replaced on every detail write, above the
early return that keeps a checkless fetch from nulling the rollup, and read back by both detail
reads. `issue_search_index` copies `search_index` field for field, cascade included.
Because `repos` is now the parent of two cascading tables, the repository prune is shared by both
sweeps (`pruneOrphanedRepos`): a prune that looked only at `pull_requests` would delete a repository
the user has issues but no open pull requests in, and cascade every one of those issues away.
`IssueStore.swift` is `InboxStore`'s twin — `IssueFilter` (the inbox filter's axes plus
`hasLinkedAgentPullRequest`, `ageBucket` and `includeClosed`), `saveIssueSummaries(_:pruneMissing:)`,
`fetchIssues(filter:)`, `fetchIssueSummary(id:)`, `saveIssueDetail(_:)`, `fetchIssueDetail(id:)`,
`observeIssues(filter:)`, `fetchLinkedPullRequests(issueID:)` — and `issuePruneGuardSQL` is the
pull-request guard's `outbox` half and only that half, because an issue has no review to draft.
`fetchPullRequestSummary(repo:number:)` in `InboxStore.swift` is the store's only lookup *without*
a node id, and it exists because a link is written the way GitHub writes it, `owner/name#number`;
`idx_pull_requests_repo_number` is exactly that query's index. `IssueSearchIndexStore.swift` mirrors
`SearchIndexStore` operation for operation and reports through the same `SearchIndexStatistics`.
`DatabaseManager.changedFilePaths(prIDs:)` reads the cached diffs' paths and statuses **without**
their patches, which is all the trust lane's sensitive-path exclusion needs.
`ValueObservation` publishers feed the UI. The **outbox** stores every outbound mutation (submit review, reply,
resolve, merge — and, since ADR 0032's Sprint 4a amendment, comment on / label / assign / close /
reopen an *issue*) as a row with retry/backoff state so writes survive crash/offline. There is no
schema change for the issue actions: `outbox.payload` is an opaque blob of the whole
`OutboxAction`, and `prID`/`repo`/`number` are reused generically as the target's node id,
repository and number — which is the question `issuePruneGuardSQL` was already asking. Three
standing counts read it: `pendingOutboxCount()` (waiting or in flight), `conflictedOutboxCount()`
(parked for the user to decide) and `failedOutboxCount()` (given up on, and therefore in neither of
the other two). All three are observed by `SignedInSession` and shown wherever the outbox is
described — Settings → Sync, the title bar, the morning digest. The failed one is the only one with
rows the user can *act* on, which is why the store also carries `failedOutboxItems()` (the list
Settings → Sync names) and `retryOutboxItem(id:)` (back to `pending`, `attemptCount` and
`nextAttemptAt` reset, guarded on `state = 'failed'` so a row a drain is currently sending cannot be
pulled out from under it); `deleteOutboxItem(id:)` is the discard on the other button.
Beside the three counts, `observeOutboxItems()` streams the *rows* themselves (ADR 0006's
2026-09-04 amendment) — the same `SELECT` as `allOutboxItems()`, shared as
`DatabaseManager.loadOutboxItems(_:)` so the ordering cannot drift between the two. It exists
because a count cannot answer "what is queued for *this* pull request", and it is observed rather
than re-read because a pull-request write is queued from four places (bulk triage, the detail
panel, the review composer, automatic merging) with no single call site that could re-read
afterwards. The issue side re-reads instead, since every issue write goes through one model.

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

The same rule on the other kind of node (ADR 0032's Sprint 4a amendment): every issue action
carries `basedOnUpdatedAt`, and the drain reads `issueState` before it sends anything. A mismatch
parks the row as `conflicted` and emits **no** `draftConflict` — that event promises a draft the
user can re-apply, and an issue write has none, so the standing `conflictedOutboxCount()` and the
panel's per-issue line are the surface. A probe that could not be *made* is a plain failure and
therefore a backoff, because an unreachable network says nothing about the issue. The writes go
through a third port, `IssueWriting`, handed to the engine as its own optional parameter beside
`IssueCapture` — the sweep and the drain are different moments, and a drain that sends a queued
comment needs no sweep.

The sweep has one side effect of its own beyond writing the inbox: the pull requests the prune
actually removed — the same list `SyncEvent.prMerged` is emitted from — are read once each and
stored as track-record outcomes (ADR 0027). It goes through two ports of its own
(`OutcomeRecording` and `ClosedPullRequestReading`, handed over together as `OutcomeCapture` in
`SyncPorts.swift`) so the engine keeps building and testing on Linux against fakes, and an engine
built without them sweeps exactly as it did before. The store is asked before GitHub is, so a pull
request that already has a row costs no request; the reads are sequential; and **every failure is
swallowed**, not even reported as a `syncFailed`, because the user did not ask for this and a badge
one pull request behind is worth less than a sweep that claims to be broken.
The cycle has a **second sweep** of its own: `runIssueSweep()` (ADR 0032), called from
`runSweep()` in the same pass — no second timer and no second cadence setting, because the two
sections are read together. It repeats the delta logic on the other kind of row (cached rows as
"before", the three facet searches as "after", first sightings and departures as the difference,
the prune guarded by `issuePruneGuardSQL`), fetches no details — an issue's body arrives when
somebody opens it — and goes through two ports of its own (`IssueFetching` and `IssueSyncStoring`,
handed over together as `IssueCapture` in `SyncPorts.swift`) so the engine keeps building and
testing on Linux against fakes and an engine built without them sweeps exactly as it did before.
It cannot fail the cycle: the method does not throw, and a failure becomes one
`SyncEvent.syncFailed` on the sweep stage — *reported* rather than swallowed, unlike the track
record's capture, because the user asked for this section. There is no new `SyncEvent` case and no
new setting.

A row the search stopped returning is **not** simply pruned: `captureIssueOutcomes(for:)` (ADR
0032's 2026-09-03 amendment) is the track record's capture applied to issues, and it is what makes
the digest's "an agent's pull request closed one of these" line able to fire at all. One
`GitHubClient.issueRow(repo:number:)` read each — sequential, failures swallowed, capped at
`maxIssueOutcomeReadsPerSweep` (10) a sweep with the rest kept for the next one — and the answer
decides the row's fate: closed writes `state`, `stateReason`, `closedAt`, `updatedAt` and the links
onto the **stored** row (relations untouched: a by-number read claims none) and keeps it; still
open, or no such issue, prunes it exactly as before; a read that failed keeps the row unchanged and
tries again next sweep. The outcome goes onto the row rather than into a table of its own — unlike
`pull_request_outcomes` — because everything that reads a closed issue reads `issues`. A closed row
is then kept for `closedIssueRetention` (14 days from `closedAt`, falling back to `updatedAt`) and
pruned by the sweep once older, which is the table's only reaper: the search only ever asks for open
issues, so nothing else would take it away.

`TrackRecordBackfill` (also in ShepherdSync) is the one-time pager behind Settings → Automation:
one repository at a time, at most 500 pull requests each, cancellable between pages, reporting
progress and one line per repository it could not read.

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

One `SyncEvent` is about no pull request at all: `.sweepCompleted(SweepCompletion)` is yielded by
`performSweep()` once a sweep has run to the end without throwing, including a sweep that found
nothing — every other case reports something the sweep *found*, so a quiet account emitted nothing,
`SignedInSession.lastSyncedAt` stayed `nil` and the title bar said "Not synced yet" indefinitely
while the engine swept every two minutes. It is emitted once per `performSweep()` rather than once
per `runSweep()`, so the coalescing of overlapping requests stays invisible, and it is what
`SignedInSession.hasCompletedFirstSweep` is set from — the flag the inbox and the menu bar use to
tell "no sweep has come back yet" from "nobody is waiting on you", which the local `SELECT`'s
`hasLoaded` cannot do because on a fresh database it is true within a second of signing in.

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
- `loadFile` `{path, language, original, modified, mode: "sideBySide"|"inline", wrap, commentableLines?, paneLabels?}`
  - `commentableLines` is `{left: [Int], right: [Int]}` — the 1-based lines of each document
    that came from the patch. Swift reconstructs both sides from GitHub's unified diff and
    pads the gaps between hunks with blank lines so absolute line numbers still match
    GitHub's; those fillers are indistinguishable from real content in the model, and GitHub
    rejects an *entire* review when one `comments[].line` is not part of the diff. The viewer
    therefore arms the gutter “+” only on the listed lines of the hovered side.
  - The field is **optional and additive** — omitting it means "every line" — so `v` stays 1.
  - `paneLabels` is `{left: String, right: String}` — what a screen reader calls each pane,
    which Monaco's default (the same sentence on both) cannot say. Sent from Swift because the
    app is localised and this bundle is not. Also optional and additive.
- `setTheme` `{theme: "light"|"dark", fontSize}`
- `setThreads` `{threads: [{id, line, side, resolved, outdated, comments:[{author, bodyHTML, createdAt, isAgent}]}]}`
- `setDraftComments` `{comments: [{localID, line, side, body}]}`
- `revealLine` `{line, side}`
- `focusEditor` `{side?}` — hands the keyboard to one pane. Everything a reviewer does to a
  *file* is a key in the native screen, everything they do to a *line* is Monaco's, and `c`
  pressed outside the diff sends this so the next `c` can comment on the cursor's line
  (ADR 0033). `side` is optional and absent means the modified pane, the shape the command had
  before `[` and `]` gave the keyboard a way into the original one — where deleted lines live.
  Swift sends it off a *request token* rather than a value it compares, because focus is an
  event: asking twice must send twice.
- `setAccessibility` `{screenReader}` — turns Monaco's `accessibilitySupport` on and raises its
  `accessibilityPageSize`. Monaco's own `'auto'` detection is a browser's and cannot see that
  VoiceOver is reading the window this web view is embedded in; macOS can, so the app is the
  source of the flag (SwiftUI's `accessibilityVoiceOverEnabled`, straight through).
- `setLocale` `{locale, strings: {resolved, outdated, pending, noComments, unknownAuthor,
  agentBadgeTitle, agentBadgeLabel, addComment, commentCount: {one, other}}}` — the app's
  language and the words the bundle draws itself (thread-card pills, the agent badge, the gutter
  “+” hover), all from the String Catalog, because the app is localised and the bundle is not
  (ADR 0022's diff-viewer amendment). `locale` is a BCP 47 language tag — the language the app's strings
  resolved to (`Bundle.main.preferredLocalizations`), never `Locale.current.identifier`, whose
  `de_DE` `Intl` rejects — and the bundle formats relative times and picks the `commentCount`
  phrase through `Intl` with it; `{count}` in either phrase is replaced there. Every word is
  required and non-empty. Sent once, first; until it arrives the viewer speaks English.
  A new message type rather than a change to an existing one, so `v` stays 1.

Monaco's *own* strings (the "hidden lines" bar, its hovers, its accessibility help) do not cross
the bridge: Monaco reads its message table while its modules evaluate, before `ready`. The build
copies Monaco's German table into `dist/nls/de.js`, and the app injects it as a document-start
`WKUserScript` when it runs in German — the same seam the theme bootstrap uses, nothing fetched.

Web → Swift (`window.webkit.messageHandlers.shepherd.postMessage`):
- `ready` `{}` — bundle booted, safe to send
- `addComment` `{line, side, startLine?}` — user clicked a gutter “+”; Swift opens the native
  comment composer (text entry is native, not in the webview)
- `commentClicked` `{threadID | localID}`
- `viewportChanged` `{firstVisibleLine}` (scroll-state restore)

Rules: no remote loads, no eval of dynamic strings, webview has no access beyond its bundle
directory; comment *text entry* is always native SwiftUI, so the only keystrokes the webview
acts on are navigation, selection, and the single `c` that asks for a composer on the cursor's
line — which it answers with an `addComment` message, exactly as a click on the gutter does.

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

Three providers, two of them one type: `SessionProvider<Backend>` drives a Foundation Models
`LanguageModelSession` on whichever `LanguageModelBackend` it is given — `OnDeviceProvider` is it on
`OnDeviceBackend` (Apple's system model), `ClaudeProvider` is it on `ClaudeBackend` (Anthropic's
`ClaudeForFoundationModels` package, BYOK, `claude-haiku-4-5` default) — and `OpenAICompatibleProvider`
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
`Intelligence/` — the provider, this bridge, the triage classifier, the thread digester, the
claim extractor and checker, and the screenshot reader — plus `LanguageModelBackend.swift` and `ClaudeProvider.swift`) wraps
the three tools in `FoundationModels.Tool` conformances with `@Generable` argument structs, and the framework
drives the calls — so the hop cap lives in the wrappers and the trace is collected by a shared
`ToolTraceRecorder` actor. That is the shape for both session backends, on-device and Claude;
`OpenAICompatibleProvider` keeps `tool_calls` plus one
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

### Claims vs. Evidence (tier 1, plus one optional on-device pass, ADR 0026)

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

**The one network read** is the issue behind a `fixes #N` claim (ADR 0026's amendment). It goes
through the `IssueFetching` seam declared beside the model — `GitHubClient.issue(repo:number:)` is
the single production conformance, and `AppEnvironment.issueFetcher` hands the signed-in session's
client to `ConversationView`'s `task(id: claims.acceptanceLoadKey)`, so a signed-out window passes
`nil` and the line reads exactly as it did before the feature. `ClaimsEvidenceModel` holds the
issues, the failures and the matches in three dictionaries keyed by issue number: they are cleared
when the reviewer moves to another pull request (which also cancels the read in flight) and the
matches alone when the head commit changes, so a fix round is re-matched without a second request.
The embeddings are optional and go through ADR 0019's `EmbeddingProviding`; without them the
matcher is its keyword pass, which is the whole behaviour rather than a degraded one. **Nothing
about the issue is persisted and there is no migration for it** — the body is worth having while
the card is open and stale afterwards, so the client's ETag cache is the only durable half.

Evidence facts are **structured** in `ShepherdCore` (`EvidenceFact.Kind`) and rendered twice:
`englishSentence` there, which is what *Turn into a comment* writes to GitHub and what the tests
assert on, and `EvidenceFact.localizedSentence(bundle:)` in
`Features/Review/EvidenceFactText.swift`, which is the only thing the card draws — one
`String(localized:)` key per shape, each with a German row, plural `variations` where the count is
a sentence's only argument and two keys where it is not (ADR 0022, ADR 0026's third amendment).
`ShepherdCore` neither can nor may call `String(localized:)`: it is Foundation-only and
Linux-tested. The card's own chrome goes through `String(localized:)` the same way.

**The optional tier-2 pass** (ADR 0026's amendment) hangs off the *expansion* and nothing else.
`ClaimExtracting` is the seam and `Intelligence/OnDeviceClaimExtractor.swift` its one
implementation — the `.contentTagging` model, a `@Generable` enum for the four shapes so the
vocabulary is enforced by guided decoding, `""`/`0` for the two payload fields the way
`OnDeviceCIDiagnosis` does it, low temperature, a measured pre-flight over the **body alone**, and
the two `IntelligenceError` cases for a guardrail refusal and a context overflow. **There is
deliberately no cloud implementation and there may not be one:** the description is a colleague's
text, so nothing here takes a router, a base URL or a key, and no request type for it exists on
`IntelligenceProvider`. `AppEnvironment.claimExtractor` is rebuilt beside `intelligence` and is
`nil` while the tiers are off; `ConversationView` hands it to `ClaimsEvidenceModel.refresh(detail:extractor:)`
and drives `readWithModel(detail:)` from a `.task(id:)` whose id is `nil` while the card is
collapsed. The model spends the pass once per `PullRequestDetail` — a failure is not retried
(ADR 0007's rule) — cancels one whose pull request has gone, folds the answer in through
`ClaimList.merged(into:)` and runs `EvidenceChecker` for the *new* lines only, so a pattern line's
verdict is the same value it was. The card's whole visible share of it is a `Read by the model`
chip on those lines and one caption (`Read on-device`, or a spinner while reading). Nothing is
persisted, nothing is reported when the model is absent or declines, and nothing acts.

**Look closer** (ADR 0026's 2026-09-22 amendment, ADR 0038 item 2) is the one *asked-for* model
surface on the card. `ClaimChecking` is `ClaimExtracting`'s sibling and
`Intelligence/OnDeviceClaimChecker.swift` its one implementation: a `LanguageModelSession(profile:)`
whose `ClaimCheckProfile` sets `.toolCallingMode` from a `Mutex`-backed read counter —
`.required` before the first read, `.allowed` below three, `.disallowed` after — over the CI
diagnosis's three tools (`OnDeviceToolBridge`, `LocalToolExecutor`). The `@Generable` answer is
path / excerpt / sentence, and `ShepherdCore`'s `ClaimCheck.verified(_:in:)` keeps only notes
whose excerpt `DiffExcerpt.locate(_:inPatch:)` finds on consecutive lines of that file's patch.
`ClaimsEvidenceModel.check(_:)` runs it for a ✗ or ? line on the click, keeps the result per line
id in `checks` until the detail changes, and `ClaimCheckBlock` draws the notes tagged, with
`CIDiagnosisTraceView` for the reads. `AppEnvironment.claimChecker` is `nil` while the tiers are off.

**Read screenshots** (ADR 0038 item 4, ADR 0007's 2026-09-22 amendment) is the same shape on the
inbox's summary card: `DescriptionScreenshotReading` / `Intelligence/OnDeviceScreenshotReader.swift`
(on-device only, `SystemLanguageModel.capabilities.contains(.vision)`, images attached as
`Attachment(cgImage)`), `ShepherdCore/Markdown/DescriptionImages.swift` for which uploads a
description has and which signed `body_html` link belongs to each, and
`Features/Inbox/ScreenshotReadingModel.swift`, which scans the Markdown on selection and fetches —
`GitHubClient.pullRequestBodyHTML(repo:number:)`, then at most two
`descriptionImage(at:)` without the token — only on the click.

### The issues a pull request closes, and the state of the pull requests an issue has (ADR 0032)

`Features/PullRequest/ClosingIssuesCard.swift` is the **"Closes" section**, above the description
in `ConversationView` and below the claims card: one row per `LinkedIssueReference` with the
number, the title, a state glyph and — when the reference points somewhere else, which GitHub
resolves for `closes owner/repo#1` — a repository chip. The rows come off the cached
`PullRequestDetail`, so the section costs no request of its own, and `isHidden(for:)` is the named
rule that it draws nothing when there are none (`ClaimsEvidenceCardState.isHidden`'s shape, for
the same reason: it is the one thing about the section a test can assert without a window).

Activating a row calls `onOpen`, which `ConversationView` points at
`ClosingIssuesCard.openOnGitHub(_:)`; the first row also carries ⇧⌘I, as a
`KeyboardShortcut?` on the same view rather than a second layout. There is no `DeepLink.issue`
case in this build — that grammar arrives with the issues inbox — so the default action is
github.com, and this is the one call site that becomes `AppEnvironment.openIssue` afterwards. The
URL is built in that file rather than in `AppConfig`, deliberately: the issues inbox is landing in
parallel and wants an issue URL of its own, and one duplicated four-line builder for one release
is cheaper than two declarations of the same helper on one type.

`Features/Inbox/LinkedPullRequestStatus.swift` is the other direction, and the whole of what
"CI state by local join" means. `LinkedPullRequestStatus` is the two fields worth showing
(`checkRollup`, `reviewDecision`) plus `isEmpty`; `LinkedPullRequestStatusLoader` is a `@MainActor`
helper whose one function reads `DatabaseManager.fetchPullRequestSummary(repo:number:)`; and
`LinkedPullRequestStatusBadge` resolves itself in a `task(id:)` and draws the inbox row's own
`CheckDotView` and review-decision chip — so a linked pull request and the same pull request in the
inbox cannot look different. Three blanks are one blank: not signed in, not in the local inbox, and
cached but with neither a rollup nor a decision all draw nothing, because `nil` there means
*unknown* and a grey dot would claim "no checks". Nothing in the file fetches, takes a client or
takes a router.

## UI conventions

- Linear-inspired: left rail (views/facets), center list, right detail; ⌘K command palette
  exposes every action *and* searches the pull requests in the inbox by content (ADR 0019);
  `j`/`k` row navigation; two-keystroke review actions
  (`r a` approve, `r c` comment, `r x` request changes, `r f` focus review session, `m` merge
  dialog); in a review `c` asks for an inline comment — the diff's own keyboard below — and `[`
  and `]` name its two panes; `x` ticks a row for bulk triage (⌘-click / ⇧-click do the same with the mouse,
  ADR 0015); undo toast instead of confirm dialogs wherever the action is reversible — the merge
  sheet, the bulk-triage sheet and "end a session with pull requests still in it" are the three
  exceptions, because none of them is undoable.
- Inside a focus review session two more single keys are live, and only there: `n` next,
  `d` done & next (below).
- The diff has a keyboard of its own, and the boundary is deliberate: the native screen owns the
  keys that act on a *file*, Monaco owns the keys that act on a *line*, and three keys cross it.
  `c` outside the diff hands the keyboard over, `c` inside comments on the cursor's line, and
  `[` / `]` move between the original and the modified pane — which is what makes a comment on a
  *deleted* line reachable, since a deletion exists only in the original pane. Brackets rather
  than letters on purpose: a letter must be free both as a bare key here and as the second half
  of `r …` / `g …`, and the editor cannot see that a prefix is armed on this side. Every one of
  these keys is swallowed only once it has done something, so an unhandled key still travels.
- The diff has **two** renderers: Monaco, as above, and a native SwiftUI list
  (`DiffListView`/`DiffRowText`) that draws the same file as one row per line, walkable with `j`/`k`
  and announced to VoiceOver one row at a time. `DiffRenderer` (`automatic` / `web` / `native`)
  picks between them — `automatic` follows `accessibilityVoiceOverEnabled` live, so the renderer
  can swap mid-review. Only three things have to agree between them: which lines may carry a
  comment (`ReviewModel.commentableLineSets(in:)`), what a comment means
  (`handle(.addComment(line:side:))`), and which round is showing (`roundView`); syntax
  highlighting, word-level diffs, side-by-side layout, folding and the minimap are free to differ,
  and stay Monaco-only (ADR 0034).
- Dark & light mode from day one: semantic color tokens only (`Color.shepherd*` asset
  catalog), theme piped into Monaco via `setTheme`.
- Text sizes go through `Theme.type(_:weight:)` (or `Theme.mono(_:weight:)`), which name a
  `Font.TextStyle` and therefore grow with macOS's Larger Text setting; `Font.system(size:)` is a
  fixed measurement that ignores it. The migration off the fixed sizes is partial on purpose — a
  surface moves only when every size in it maps exactly onto a style, so the change is invisible
  at the default size — and `Scripts/check-type-scale.py` lists what has moved and fails CI on a
  fixed size reappearing there (ADR 0033, `docs/plans/accessibility.md` §3).
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
`AgentDetector` seeded with the user's registry overrides) → `SyncEngine`. The detector is also
*kept* — `SignedInSession.agentDetector` — rather than let go of after the client is built: it is
the only thing in the app that can turn an agent-registry id back into a display name, which is
what `shepherd://fleet/<agent-id>` needs, since a stored outcome remembers the name and not the id
(ADR 0035). It is a value type snapshotted once per session, and editing the registry in Settings
restarts the session, so there is no staleness to manage.

Within the signed-in window a second, smaller route drives the screen: `.inbox`, `.review(prID)`
or `.fleet(agentID:)` (ADR 0035). The review screen and the fleet are both full-window (as in the
mockups) rather than a third navigation column; the fleet is a route rather than a third value in
the inbox's content-kind picker because, unlike issues, it owns no pull-request selection and
nothing in it is a thing to triage.

`ShepherdApp` has three scenes: the one `WindowGroup`, the standard `Settings` window, and the
menu-bar quick inbox (below).

### Views render from the database, never from the network

The inbox carries **two** selections and they are not the same thing (ADR 0015): `selectedID` is
the keyboard cursor that `j`/`k` moves and the detail panel follows, and `marks`
(`InboxMarkSelection`, a pure value like `KeySequenceState`) is the set ticked for a bulk action.
Marks are pruned to the visible rows on every list change, so a bulk action can only ever act on
rows the user can see.

`InboxModel` subscribes to `DatabaseManager.observeInbox()` and to `observeOutboxItems()`, the
second one so the detail panel can say what the queue is holding for the selected pull request;
`ReviewModel` subscribes to `observeDraft(prID:)`, `observePullRequestDetail(prID:)` and
`observePullRequestOutcome(prID:)`. The second of those is what keeps an *open* review screen
current: the sweep re-fetches a detail whenever `updatedAt` or the head commit moved and stores it,
and the observation is how the screen hears about it. What it then does is decided by the head
commit alone (`ReviewModel.change(shown:fresh:)`, pure and unit-tested) — the same head means a
byte-identical diff, so the checks, the review decision, the mergeable state and the threads are
folded in through `refresh(_:)`, which touches no navigation state; a different head is *held back*
in a banner, because every inline comment in the pending review is anchored to a line number of the
head on screen. The third observation exists because the two halves of "it ended" arrive apart: the
prune removes the inbox row first and the outcome (ADR 0027) is read from GitHub after it, and only
the pair means the pull request was merged or closed — a row that leaves the inbox while still open
changes nothing on the screen. Detail fetches read the cached
`PullRequestDetail` first and only then refresh from GitHub, so opening a pull request offline
shows the last-known state instead of a spinner (ADR 0006). Grouping uses `InboxGrouper`; the sort
order inside a section is applied by the app on top of it (`priority` / `recentlyUpdated` /
`oldestFirst`), with a deterministic `InboxModel.priorityScore` so two sweeps of the same data
never reshuffle the list.

### Menu-bar quick inbox

`MenuBarExtra(isInserted:)` in `ShepherdApp`, bound straight to `AppSettings.showsMenuBarExtra`
(Settings → Appearance, on by default), with `.menuBarExtraStyle(.window)` because the content is
rows with chips rather than commands. `Features/MenuBar/` is two files: `MenuBarQuickInbox`, a pure
value, and the two views.

The data flow is the point, and it is deliberately not a new one:

- The rows come from **`SignedInSession.inboxRows`**, one more `ValueObservation` beside the three
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

### The issues section (ADR 0032)

One `InboxScreen`, two sections. `ContentKind` is a segmented control at the top of the rail;
`InboxScreen` holds `InboxModel` *and* `IssueInboxModel` for its own lifetime and switches which
one drives the rail, the list and the panel. Not a second route: `j`/`k`, ⌘K, the focus session
and the menu-bar item already address the model that owns the selection, so a route would
duplicate the toolbar, the digest card, the Settings sheet and the palette overlay.

- **Switching the section disturbs nothing.** Both lists raise the same
  `ShortcutAction.selectNext`/`selectPrevious`; `InboxScreen.perform` routes it to whichever
  section is showing, and the pull-request model keeps its smart view, facets, cursor, ticks and
  half-typed key sequence because nothing tells it anything happened. Every other command is a
  pull-request verb and is refused with one line while the issues section is up — the exceptions
  are the focus session (its queue comes from the session's observation, not a screen's list) and
  the grouping commands.
- **The chosen kind lives in `@SceneStorage`**, the app's first per-window UI state. `@State`
  would snap back to *Pull requests* after every trip to the review screen, since the screen is
  rebuilt on a route change; `AppSettings` would put it in the synced document, and which section
  a window shows is not a preference (ADR 0014).
- **`IssueInboxModel`** is `InboxModel`'s twin — `observeIssues(filter:)`, selection with pruning,
  five facets — built from a `DatabaseManager` and the existing `IssueFetching` seam rather than
  from a `SignedInSession`, which is what makes it testable without a Keychain. The observation is
  as wide as the section and the facets narrow it in Swift, which is also how `IssueFilter.now` is
  settled: the filter is the observation's key, so the model states one moment and no predicate
  reads the clock. Since ADR 0032's 2026-09-04 amendment the observation is `includeClosed: true`
  — the same wide read `SignedInSession` makes for the digest and ⌘K — and the STATE facet, which
  defaults to open, is what keeps the list the list it was. That is what makes a ⌘K hit or a
  `shepherd://issue/…` link land on a closed issue instead of parking the ask forever:
  `reveal(issueID:)` selects the row and `clearFacets()` widens the state facet along with the
  other four.
- **The facets are pure** (`ShepherdCore/Triage/IssueFacet.swift`): labels sorted by count then
  name and capped with the overflow counted beside the rows, age over `IssueAgeBucket`, the two
  agent-pull-request halves drawn only when both are populated, and the two `IssueStateFilter`
  halves drawn as soon as either is — that one starts selected, so its row is what says what the
  list is leaving out. Clicking a facet does not change the numbers: the first four are counted
  over `stateScopedRows`, so the default selection reproduces every count the rail printed before
  closed rows were observed and *Closed* describes the closed ones, while `stateFacets` is counted
  over the whole section, being its own axis.
- **`IssueDetailPanel`** shows provenance, state with GitHub's raw reason, age, labels and the
  body through the same `AttributedString` renderer the pull-request description uses, plus
  "Linked pull requests" from `IssueRowSummary.linkedPullRequests` at zero extra GitHub calls. A
  row opens the review when the pull request is in the local inbox and github.com when it is not.
  `IssueLinkedPullRequestRow` carries a `badge` slot the CI/review badge is passed into from its
  own file.
- **The panel writes, through the ordinary outbox** (ADR 0032's Sprint 4a amendment): an actions
  row with a comment composer sheet (`IssueCommentSheet`), a label picker, *Assign to me*, close as
  completed / not planned, and reopen. Each one calls an `IssueInboxModel` method that enqueues an
  `OutboxItem` and asks the engine to drain — nothing in `Features/Inbox/` calls `GitHubClient` for
  a mutation, which is the same rule `PullRequestActions` states below. The label picker is fed by
  the labels the section has already seen in that repository (a `GET /repos/…/labels` would be a
  new request on every panel for a list the sweep already wrote), and the panel shows all three
  outbox states — waiting to be sent, parked, and given up on — about this one issue, the third
  counted by `failedWriteCount(for:)` and drawn in the failure colour. An issue row fails
  non-retriably whenever the engine was built without an `IssueWriting` port, and a 4xx from
  GitHub ends the same way; such a row is neither pending nor conflicted, so without that line the
  click looked as though it had worked. This panel had the line first: the account-wide surfaces
  (Settings → Sync, the title bar, the digest) caught up next, and the pull-request panel got the
  same three indicators in ADR 0006's 2026-09-04 amendment. No new global shortcuts: the issues
  section already refuses `r a`, `m` and `x`.

### Morning digest (opt-in, local, no scheduler)

Once a day, at a time the user picks, Shepherd says what came in: new review requests, issues
assigned to you, green agent pull requests that only need an approval or a merge, issues an agent's
pull request closed as completed, the user's own pull requests with red CI or a change request,
reviews the outbox parked, and writes it gave up on entirely. It arrives as a macOS notification and as a
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
app never calls a `GitHubClient` mutation directly. The issue triage writes (ADR 0032's Sprint 4a
amendment) are the same rule on the other kind of node, through `IssueInboxModel`'s own
`comment`/`addLabel`/`assignToMe`/`close`/`reopen` — a second surface rather than a widened
`PullRequestActions` because that type is built from a `SignedInSession` and the issues model
deliberately is not. `SyncEvent.draftConflict` surfaces as an
alert offering to re-open the review rather than submitting against the wrong commit — one alert
per parked review, queued in `DraftConflictQueue` so a drain that parks several shows all of them,
with `conflictedOutboxCount()` behind the standing count in Settings → Sync and the title bar.
A row the drain **gave up on** raises no alert at all — there is no draft to re-apply and retrying
cannot help — so what says so is standing rather than momentary: `failedOutboxCount()` in the title
bar and the digest, `InboxDetailPanel.queueStatus(_:)` on the pull request the row belongs to
(ADR 0006's 2026-09-04 amendment), and Settings → Sync's OUTBOX card, which is the only one of the
three where a row can be retried or discarded.

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

`ChangedFile.patch` is a unified diff; Monaco wants two documents. `PatchReconstructor`
(`ShepherdCore/Review/`, so its tests run on both CI legs) builds them from the hunks: context
lines go to both sides, `-` lines only to the original, `+` lines only to the modified, and **the
gaps between hunks are padded with empty lines on both sides**. The padding is what keeps 1-based
line numbers identical to GitHub's — review threads and draft comments are anchored by absolute
line number, so an off-by-N would attach comments to the wrong lines. Because the filler is
identical on both sides, the diff editor treats it as unchanged and never highlights it — and,
since it is unchanged, Monaco folds it away behind its `hideUnchangedRegions` bar rather than
drawing hundreds of blank rows between two hunks. Expanding one of those bars still shows blank
rows, because the app never received that text; the native renderer (ADR 0034) sidesteps the
question by walking `Reconstruction.rows`, which carries a hunk header and no padding at all.
When `patch` is `nil` (binary or truncated) the webview is not created at all; a native
`DiffUnavailableView` takes its place.

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
platform reported, so `OnDeviceProvider` pre-flights the real prompt against the real window
(minus room for the answer); the chars-÷-4 estimate is only the seed the request carries until
that measurement is taken, since the floor is macOS 27 (ADR 0038). Both helpers are pure and live
in `ShepherdCore`. Per-request choices also live in that
file: `OnDeviceUseCase` picks the general or the content-tagging model (availability is checked per
model, since the assets download per model) and `OnDeviceGeneration` holds every temperature and
`maximumResponseTokens` cap. A guardrail refusal and an exceeded context window map to
`IntelligenceError.guardrailDeclined` / `.contextExceeded` and are **never** retried. Results are returned as an `IntelligenceOutcome`, so the
UI can say *why* a card is missing instead of silently hiding it. `IntelligenceTiers` is the seam
the ladder is tested through — a stub cloud tier that fails, a stub on-device tier that answers, an
on-device tier that reports itself unavailable — so the degradation is verified without a key, a
network or Apple Intelligence. All FoundationModels usage is
confined to the `OnDevice*.swift` files, `LanguageModelBackend.swift` and `ClaudeProvider.swift` in
`Intelligence/`, guarded by each backend's availability check, and file paths a model invents are
dropped before they reach the UI.

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
already exist: `.pullRequest` → `openReview(prID:)`, `.issue` → `openIssue(issueID:)`,
`.fleet` → `openFleet(agentID:)` (ADR 0035), `.sync` → `syncNow()`, `.inbox`/`.settings` → `route`
plus a pending request the inbox screen consumes — the same "raise it, let the screen that owns the
state run it" mechanism as `PendingAction`. `.fleet` goes through the method rather than assigning
`route` here for the reason `.pullRequest` does: `openFleet(agentID:)` also ends a running focus
session, and a link that navigated without ending it would leave the session's bar naming a pull
request the window no longer shows. `InboxRailSelection` is the pure value that maps a filter token onto rail state,
so the mapping is testable without a session; its smart view is **optional**, and the one token
that answers `nil` is `filter=issues`, which names the inbox *section* rather than a rail state
(ADR 0032).

Two behaviours are worth knowing because they are the robust rather than the obvious choice:

- **A link that arrives before there is a session is queued**, in one slot, and replayed at the
  end of `startSession`. Opening the app is how a link launches it, so the first deep link of a
  session usually *does* arrive during `launching`; dropping it would look broken. Signing out
  clears the slot.
- **A pull request that is not in the local cache is fetched individually** and stored, then
  opened. The sweep searches `involves:@me`, so a link from a colleague is routinely absent from
  the inbox — a sweep would be slow *and* still miss it. `shepherd://issue/…` follows the same
  rule through `GitHubClient.issueRow(repo:number:)`, written with `pruneMissing: false` because
  a link is not a sweep and must not be treated as the complete set (ADR 0032).

`shepherd` (`ShepherdCLI/`, target `ShepherdCLI`, product name `shepherd`) is a thin URL builder:
`ShepherdCommandLine.parse` → `DeepLink` → `NSWorkspace.shared.open`. Its verbs are `open`,
`issue`, `inbox`, `fleet`, `sync` and `settings`; `open` and `issue` share one reference reader,
parameterised on the github.com path segment, so the two cannot drift into accepting different
spellings. It links `ShepherdCore`
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
machine), `DelegationCenter` (one delegation per target; a second request while one is
running reveals it instead of starting another) and `DelegationSheet`.

Two seams carry the tests. `ProcessRunning` (`run(executable:arguments:currentDirectory:)`) is
the only way `GitWorktree` reaches git, so the unit tests assert the **exact argv** of every
command — fetch, `worktree add --detach`, status, diff-stat, commit, `push origin HEAD:<branch>`,
`worktree remove --force` — without a repository on disk, including the refusal to delete
anything outside `~/Library/Application Support/Shepherd/Worktrees`. Since ADR 0011's 2026-09-04
amendment there is a second entry point for a delegation started from an *issue*:
`addForNewWork(branch:)` fetches, asks git which branch `origin/HEAD` points at, and adds a
worktree on a branch Shepherd named (`agent/issue-{number}`) at that branch's tip — resuming the
branch when it already exists, so handing the same issue over twice does not throw away the first
run's commits. Which branch is the default is asked of git rather than of GitHub, so this stays a
local operation and adds no host. `AgentRunning` is the seam
for the CLI, so the state machine is driven by scripted event lists.

Three rules are not negotiable and are enforced in code, not by convention: **no shell, ever** —
the prompt is one element of an argv array and command templates are split by `ShellWords`, so a
prompt cannot become a second command; **Shepherd never touches agent authentication** — the
child inherits the environment verbatim, nothing added, nothing removed, and there is no
credential field anywhere in the Delegation settings tab; **nothing is ever pushed
automatically** — Shepherd's own code has no step that transmits, and "Commit & push" is a
button, using the user's own git credentials rather than Shepherd's GitHub token.

That third rule is about **Shepherd**, and ADR 0011's 2026-09-04 amendment is where the
distinction had to be stated. A delegation started from a pull request works in a *detached*
worktree and its preamble forbids a branch, a push and a pull request, because the diff is the
reviewer's to publish. One started from an issue has nothing to review yet: it works on Shepherd's
own branch and its preamble says the run may finish the job with the credentials its own tool
already has — which is this ADR's standing rule that the child inherits that tool's
authentication, stated rather than changed. `DelegationPrompt` selects the preamble by
`DelegationContext.Origin`, and no code path Shepherd added pushes or opens a pull request.

#### Local repositories and free-text tasks (ADR 0011's 2026-09-23 amendment)

**"Add a local repository…"** (the rail's `+` menu, ⌘K, the menu bar, Settings → Delegation) starts
from a folder: `LocalRepositoryDraft.choose()` runs the open panel, then
`Support/AgentCLI/LocalRepositoryProbe` asks git two things through the same `ProcessRunning` seam —
`rev-parse --show-toplevel` (not a work tree → refused; otherwise the clone's root, which is what is
linked even when a subfolder was picked) and `remote get-url origin` in that root. What the URL means
is `ShepherdCore/Models/GitRemote.read(_:)`'s decision, pure and Linux-tested: a github.com
`owner/name` (https, `ssh://`, scp-like, `.git`), a GitHub Enterprise-looking host (refused — Shepherd
only talks to github.com), another host or no `origin` (the sheet asks for the name). The
confirmation (`Features/Inbox/AddLocalRepositorySheet`) links the checkout through
`AppSettings.setLocalCheckout` and watches through `watchRepository(named:)` in one
`AppSettings.addLocalRepository(_:folder:link:watch:)`, idempotent by `ShepherdCore/LocalRepositoryLink`
(case-insensitive on both maps); the sweep refresh is the `onChange(of: watchedRepositories)` in
`ShepherdApp` every writer of the watch list already goes through. `localCheckoutURL(for:)` falls back
to a case-insensitive key, and `setLocalCheckout` replaces an other-case key, so a clone linked as
`Schnaq/Shepherd` serves rows spelled `schnaq/shepherd`.

**"Start an agent…"** (the context menu of a watched rail row with a linked checkout — the row shows
a laptop glyph — and one ⌘K command per `AppSettings.linkedRepositories`) opens
`AppEnvironment.startRepositoryDelegation(_:)`: a **new** `DelegationContext.repository(repo)` every
time (origin `.repository`, identity `repository:owner/name#<uuid>` — one per task, so several run in
one repository at once — no number, no commit, and no branch until the run starts).
`DelegationModel.start()` then picks the branch from the task's first line —
`GitWorktree.takenTaskSlugs()` fetches and reads `refs/heads/agent/` and `refs/remotes/origin/agent/`
with one `for-each-ref`; then, on the main actor and with no `await` before the claim is recorded,
`freeTaskSlug(for:repo:taken:suffix:)` uniques the `ShepherdCore/RepositoryTaskBranch` slug against
those, the managed directories and the slugs the repository's other tasks have claimed
(`DelegationCenter.claimedTaskSlugs(in:excluding:)`, read from each model's `taskSlug`) — re-aims the
handle at `owner-repo-task-<slug>` (`GitWorktree.relocated(to:)`; until then it names the managed
root, which `remove()` refuses) and adds the worktree through the issue path's own
`addForNewWork(branch:)`. The prompt is built after that step, because the third preamble names the
branch. *Run again* continues in the same worktree. A repository's tasks worth going back to —
running, or with a worktree on disk — are `DelegationCenter.repositoryTasks(for:)`, oldest first; the
rail row's *Agent tasks* submenu and one ⌘K command per task (`repositoryTasks`) list them with
`DelegationModel.phase`, and `AppEnvironment.reopenRepositoryTask(_:)` re-presents that model
(`DelegationCenter.present(_:)`). *Discard worktree* clears that task's branch, which drops its claim
and its list entry and touches no other task; a sheet opened and never run is forgotten when it
leaves the screen (`DelegationCenter.show(_:)`, the one place `presented` changes). The submenu shows
whether or not the clone is still linked; only *New task…* needs it. The slug's fetch is the task's
only one (`addForNewWork(branch:fetch: false)`), and a cancel during preparation stays cancelled:
checks after the fetch and after `worktree add`, and `fail(with:)` never overwrites `.cancelled`.
The sheet's "Choose folder…" rebuild passes its own context back in, so it replaces that
sheet instead of adding a task. A failed `addForNewWork` releases the claim (branch cleared, handle
back at the managed root) and the task stays listed as failed with git's error, *Try again* and
*Dismiss task* (`DelegationCenter.dismissTask(_:)`, only with nothing on disk). `GitWorktree.remove()`
skips `worktree remove` when the directory has gone and still prunes; a repository task's discard
then deletes its branch via `deleteLocalBranchIfUnused(_:since:)` when it exists and has no commits
past its base.
`startAutomatically` refuses the origin outright, and the run sends no `delegation.finished` webhook
(its envelope is a pull request's identity).

New-work runs — issues and repository tasks — diff from the merge base of their starting ref
(`GitWorktree.diffStat(since:)`) rather than from `HEAD`, since their preamble lets them commit; the
push button then pushes committed work without trying an empty commit.

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

### Open in editor (ADR 0039)

The same split as the delegation engine. `Support/Editor/EditorConfiguration.swift` is pure:
`EditorConfiguration` (the choice — system default, VS Code, IntelliJ IDEA, Cursor, or a custom
`{file}`/`{line}` command — stored as one JSON blob under `editor.configuration` and carried by
settings sync in its own `EditorGroup`), `EditorLauncher` (the `vscode://file/…`, `cursor://file/…`
and `idea://open?…` URLs, and the custom command's argv — `ShellWords` first, placeholders after,
no shell, a bare program name refused) and `EditorFileTarget` (a repository-relative path against
the clone in `AppSettings.localCheckouts`, delegation's own map: no checkout, the file, or the
folder when the file is missing — and never a path that climbs out of it). `EditorLauncherTests`
pins every URL and argv. `Features/Editor/EditorOpener.swift` is the `@MainActor` half that hands
the plan to `NSWorkspace` or `Process`, links a clone through `FolderPicker` when there is none,
and says in a toast when the clone lacks the file (another branch). The review file list's context
menu, the file header's icon and the claims/*Look closer*/CI-diagnosis `path:line` links offer it
through one `EditorContext`; the diff bridge is untouched, so the header opens the file without a
line.

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

### Merge when checks pass (ADR 0037)

The third way a merge is queued, beside the click and the rule, and the merge sheet is the only
place it starts: while the head commit's checks are pending, the sheet offers *Merge when checks
pass* next to *Merge*. `ShepherdCore/Automation/MergeWhenGreenPolicy.swift` holds the decision
(above); `Automation/MergeWhenGreenCoordinator.swift` and `MergeWhenGreenStore.swift` are the app
half. The store is `UserDefaults`, machine-local, cleared on sign-out and never in the settings
document — the arm records what *this* user looked at on *this* Mac.

- **It is the user's verdict, so the policy checks none of the rule's conditions.** No approval, no
  authorship, no repository: the request pins the head commit, the method and the delete-branch
  answer as the sheet showed them, and the pass asks only whether that commit is still the one
  that would be merged and whether it went green. A push, a red check, a conflict or a draft drops
  the arm with a notification naming the reason; a row missing from the sweep is a wait, not a
  drop, for seven days.
- **It runs in the auto-merge pass, after the rules,** in `AppEnvironment.considerAutoMerge(rows:)`:
  one `Task` reads the outbox once, runs the rules, adds what they queued to the in-flight set and
  then runs the arms against it. A pull request that satisfies the rules *and* carries an arm gets
  one merge.
- **The write is the sheet's write**, `PullRequestActions.merge(_:method:deletesHeadBranch:)`
  through a seam one argument wider than `AutoMergeWriting`, so the row is an ordinary `.merge`
  pinned to the armed head, `pr.merged` fires from the drain, and there is no new webhook event:
  the intent was a click. Telemetry gains one value, `pull_request_merged.source =
  when_checks_pass`. Arming advances a focus session and leaves the review screen exactly as
  *Merge* does.

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
- **A second corpus, one slice** (ADR 0032). The coordinator runs a second pass over
  `issue_search_index`, triggered by the session's own `issues` observation (`onIssueRows`) —
  the only announcement the issues sweep makes, since it emits no `SyncEvent`. The pass is the
  first one's twin down to the two hashes, with `detailFetchedAt` in the fingerprint so that
  opening an issue grows its document on the very next pass; *Rebuild index* clears both tables
  and the Settings line adds `issueSearchIndexStatistics()` to the one byte count. The palette's
  `PaletteRow` gained a third case: both ranked sets are computed to the same limit and then
  merged by score and **sliced once**, so the rows it has room for are the best of both kinds and
  a quota per kind cannot push a strong pull request out. Ties break towards the pull request,
  then on node id, so the order is total. A row opens through `AppEnvironment.openIssue(issueID:)`
  — one route, because selecting an issue has to switch the section *and* reveal a row a facet may
  be hiding. A query that is nothing but a `risk:`/`kind:` token answers with no issues at all and
  spends no embedding finding out.
- Device state versus setting, once more: the switch travels in the encrypted settings document
  (`search` group, both applier directions), neither index does — both are rebuildable from local
  rows, and they are dropped with the rest of the local data on sign-out.

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
construction, template splitting, git command sequences, state transitions — and, in
`RepositoryTaskTests`, the repository task's argv from slug to `worktree add -b`, *Run again*
staying in place, two tasks in one repository with their own identity, branch and worktree, the same
first line started back to back getting two branches, a discard that leaves the other task running
and listed, a refused `worktree add` releasing its claim and failing with git's error, retry and
dismiss, a discard whose directory is gone (prune only; unused branch deleted, one with commits kept), the rail's and ⌘K's lists and reopening the task named, the merge-base diff, a rule's refusal with a CLI present, the folder probe's
findings and "Add a local repository…"'s idempotency; the remote grammar, the slug and the link
state are `ShepherdCoreTests/LocalRepositoryTests`, on Linux) and the app half of
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
the card's issue read (ADR 0026's amendment: a collapsed card, a description with no `#N` and a
signed-out window each costing zero reads, one open being one read and a second open none, a 404
keeping the "not checked" fact and adding why, a pull-request reference producing no bullets, a new
head re-matching without a second read, and moving to another pull request cancelling the read in
flight — the bullet extraction, the matcher's thresholds and the status derivation are tested in
`ShepherdCoreTests` and the read itself in `GitHubKitTests`, so those run on the Linux runner);
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
token → rail state, and a `shepherd://fleet/<agent-id>` link keeping the registry's lower-cased id
all the way onto `Route.fleet(agentID:)`). The `shepherd://` grammar itself is tested in
`ShepherdCoreTests` instead, so it runs on the Linux runner too. The web
bundle is likewise added to the app target as a
folder reference (`Shepherd/Resources/DiffViewer`) so `index.html` keeps its relative links.
