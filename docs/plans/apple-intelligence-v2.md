# Apple Intelligence in Shepherd — the v2 plan

Status: done (v1.0.0), see ROADMAP's Intelligence v2 section, all items ticked — except §I's
Private Cloud Compute rung, which stays parked (ADR 0025) · Date: 2026-09-02 · Owner: maintainer ·
Scope: after v1.0 ships

This is the engineering plan behind the *Intelligence v2* section of [`docs/ROADMAP.md`](../ROADMAP.md).
The roadmap says **what** was kept from the interview; this document says **in which order, on
which APIs, with which data, behind which guardrails**, and what has to exist before the first
feature can be built. It is grounded in what the code does today (§1), not in what the framework
could do in principle.

The one-sentence pitch, for the README when the first of these ships:

> Shepherd reads the pull request *with* you. On your Mac, with Apple's on-device model, it
> sorts the inbox by risk, tells you why CI is red, explains the lines you point at, and hands a
> finished brief to the coding agent on your machine — and it never presses a button for you.

---

## 0. Ground rules (inherited, not re-decided here)

Everything below is bound by ADR 0007 and the ADRs that followed it. Restated so the plan can be
checked against them line by line:

1. **Tier 2 first.** Every feature is designed for the on-device model (8,192-token combined
   budget, macOS 26.4+). A tier-3 (BYOK cloud) variant exists only where ADR 0007 already lets
   that content travel; a tier-3 variant is never *required* for the feature to be useful.
2. **Unattended means on-device only.** Anything that runs on a timer, in a sync pass, or in an
   intent without a review screen in front of a human uses tier 2 or nothing. No bulk cloud pass,
   ever.
3. **Hints, never verdicts.** No code path from a generated value to `submitReview`, the outbox,
   a merge, or a delegation *start*. Generated text lands in fields the reviewer edits; generated
   classifications sort and filter, they do not approve. Tools the model can call are reads.
4. **The budget is a hard error.** `IntelligenceError.digestTooLarge` before a session exists,
   never a silent truncation. Tier-1 pre-digestion (`ShepherdCore`) decides what fits.
5. **Apple frameworks stay in the app target.** `FoundationModels`, `NaturalLanguage`,
   `Translation`, `Vision`, `AppIntents`, `CoreSpotlight` are imported only under `Shepherd/`.
   `Packages/ShepherdKit` keeps building on Linux, so every schema, budget, trace and ranking
   type has a pure `Codable` twin in `ShepherdCore` with tests that run there.
6. **Every setting syncs, every string localises, every secret is Keychain.** A new setting is
   a `SyncedSettingsDocument` field + both `SettingsSyncApplier` directions + the
   `SettingsSyncTests` fixture (ADR 0014). A new UI string is a catalog row in the same commit
   (`Scripts/check-localization.py`, ADR 0022). Nothing new touches `UserDefaults` that a key
   would.
7. **No new host without an ADR line.** `CONTRIBUTING.md`'s host list is the privacy contract.
   Tier-2 features add no host. A tier-3 variant that sends *new kinds* of content (CI logs,
   colleagues' comments) says so there and in an ADR.
8. **Considered and rejected stays rejected**: Image Playground/Genmoji, speech input, sentiment
   checks on outgoing comments, an AI-written digest. They are not re-proposed below.

---

## 1. Where the code stands (2026-09-02)

What exists, so the plan builds on it instead of beside it.

| Piece | Where | State |
|---|---|---|
| `IntelligenceProvider` protocol, 4 methods (summary, focus hints, review-summary draft, inline draft) | `Shepherd/Intelligence/IntelligenceProvider.swift` | Shipped. Non-streaming, one `LanguageModelSession` per call, no `Tool`, no `GenerationOptions`. |
| `OnDeviceProvider` — the **only** file importing `FoundationModels`; four flat `@Generable` structs of `String`/`[String]` | `Shepherd/Intelligence/OnDeviceProvider.swift` | Shipped. Availability gate switches over `deviceNotEligible` / `appleIntelligenceNotEnabled` / `modelNotReady`. |
| `IntelligenceRouter` — cloud → on-device → unavailable ladder, `canDraft` pre-click check, `IntelligenceTiers` seam for tests | `Shepherd/Intelligence/IntelligenceRouter.swift` | Shipped. A `Sendable` value rebuilt on every settings change. |
| `TokenBudget` (chars ÷ 4; `.onDevice` = 6,000 tokens, `.cloud` = 100,000), `PullRequestDigestBuilder`, `ReviewSummaryDraftRequest`, `InlineCommentDraftBuilder` | `ShepherdCore/Heuristics/PullRequestDigest.swift`, `Shepherd/Intelligence/ReviewDraftRequests.swift` | Shipped. The budgeting pattern every new request type copies. |
| Semantic search: `SearchDocument` (weighted, byte-budgeted) → `NLEmbedding` sentence vectors → `search_index` table (v3) → BM25/cosine blend | `Shepherd/Features/Search/`, `ShepherdCore/Search/` | Shipped, on by default, structurally unable to reach a cloud endpoint. |
| Writing Tools (`.writingToolsBehavior` per field), Translation (`TranslationSession`, below the original, never persisted) | `Support/DesignComponents.swift`, `Shepherd/Intelligence/Translation/` | Shipped as system capabilities, outside the provider by rule (ADR 0020). |
| Six read-only App Intents, four Siri phrases, metadata-only `PullRequestEntity`, Spotlight export of inbox rows | `Shepherd/Intents/` | Shipped. No write intents by design (ADR 0021). |
| Local delegation to a coding-agent CLI in a worktree, `DelegationContext` (focus reasons + finding comments → task text) | `Shepherd/Features/Delegation/`, ADR 0011 | Shipped. The task text is typed or templated; nothing drafts it. |
| Local data a model has never seen: `review_threads` + `review_comments`, `commitsJSON`, `check_runs` (name, conclusion, `detailsURL`, summary), labels, `myRelation`, `mergeable`, timeline | GRDB, `PullRequestDetail` | Present, budgeted out of every prompt so far. |
| GitHubKit reads: check runs per SHA — but **no job-log read** | `GitHubKit/GitHubClient.swift:291` | The one GitHub read "Why is CI red?" has to add. |

Platform capabilities Shepherd has **not** used yet, all in the macOS 26 SDK (see
`docs/research/research-ai.md` §1): `Tool` calling, `@Generable` enums and nested structs,
`streamResponse` with partially-generated snapshots, `GenerationOptions`, `SystemLanguageModel(useCase:)`
(the `.contentTagging` model is tuned for exactly the classification below), `contextSize` /
`tokenCount(for:)` (26.4+), multi-turn sessions with a transcript, the `LanguageModel` protocol
with `PrivateCloudComputeLanguageModel` (32K — both macOS 27, see §I), and Vision text recognition. Custom LoRA adapters
via Apple's adapter toolkit exist too — parked, see §5.

---

## 2. Phase 0 — groundwork every feature needs

Build these once, before the first feature, in the order listed. Each is small; together they
turn "one shot, one string, one spinner" into a platform for the rest of the plan.

### 0.1 Session and budget plumbing (`OnDeviceProvider`)

- **Honest token counting.** When `SystemLanguageModel.default.contextSize` and
  `tokenCount(for:)` are available (26.4+), `preflight` uses them; the chars-÷-4 estimate stays
  as the fallback and as the cloud estimate. `TokenBudget` gains `measured(_:)` so the digest
  builder can accept a closure instead of a constant. Removes the ~25 % slack the estimate
  currently forces us to keep.
- **Use-case models.** `OnDeviceProvider` chooses `SystemLanguageModel(useCase: .contentTagging)`
  for classification requests (§3.A) and the default model for prose. Availability is checked
  per model, since the tagging model can be ready when the general one is not and vice versa.
- **`GenerationOptions` per request type**: low `temperature` for structured verdicts,
  default for drafts, a `maximumResponseTokens` cap on every call so a runaway answer cannot eat
  the shared budget.
- **Guardrail failures become one line, not a retry.** `LanguageModelSession.GenerationError
  .guardrailViolation` and `.exceededContextWindowSize` map to two new `IntelligenceError`
  cases with `String(localized:)` descriptions ("Apple Intelligence declined this content." /
  the existing too-large wording). Never retried automatically; technical content trips the
  guardrails often enough that a retry loop would only burn battery.
- Unit tests: `XCTSkip` when `SystemLanguageModel.default.availability != .available`, because
  the CI Mac may have Apple Intelligence disabled. The pure parts (budget arithmetic, error
  mapping) are tested without a model.

### 0.2 Streaming through the provider (`IntelligenceProvider`)

- The protocol gains streaming twins of the two drafting methods:
  `streamReviewSummaryDraft(_:) -> AsyncThrowingStream<String, Error>` and
  `streamInlineCommentDraft(_:)`. Non-streaming methods stay for callers that want a value.
- On-device: `session.streamResponse(to:generating: OnDeviceReviewDraft.self)` yields
  `PartiallyGenerated` snapshots; the provider forwards `draft ?? ""` so the UI only ever sees
  cumulative text. Anthropic: `stream: true` + `content_block_delta` SSE. OpenAI-compatible:
  `stream: true` + `choices[].delta.content`. One `SSELineParser` in `ShepherdCore`, fixture-tested
  on Linux against recorded frames of both shapes.
- `IntelligenceRouter` exposes `IntelligenceStream` (the stream + the tier that produced it) so
  the caption "Drafted on-device" / "Drafted by <provider>" is known *before* the first token.
- `AIDraftFieldState` learns a `.streaming(partial:)` state: the field shows the growing text
  greyed, the replace/append question is asked **once, before** the first token when the field is
  non-empty, and the tier caption stays until the reviewer's first keystroke. Its existing
  unit tests extend to the new state — the "never silently replace typed text" rule is enforced
  there and nowhere else.

### 0.3 Read-only tools (`Shepherd/Intelligence/Tools/`)

- `IntelligenceToolDescriptor` (name, description, JSON-schema-shaped parameters) and
  `IntelligenceToolCall`/`IntelligenceToolResult` values live in `ShepherdCore`, so the tool
  *contract* and the trace are Linux-testable and provider-neutral.
- Each concrete tool is an `actor` in the app target that owns its data source (a GRDB read, a
  `GitHubClient` read) and produces a **budgeted string** — the tool decides what fits, the model
  never sees a raw log or a raw file.
- `OnDeviceProvider` wraps them in `FoundationModels.Tool` conformances (the only file that
  may); `AnthropicProvider` maps them to `tools` + `tool_use`/`tool_result` blocks;
  `OpenAICompatibleProvider` to `tools` + `tool_calls`. Ollama-class endpoints that reject `tools`
  get a clear `IntelligenceError.toolsUnsupported`.
- **Invariant, enforced by type:** `IntelligenceTool` has no method that returns anything the
  outbox could consume, and the registry is a fixed enum — a tool cannot be added at runtime.
- `IntelligenceTrace` records each hop (tool, arguments, a one-line result summary, duration)
  and is what the UI renders as expandable steps. Stored nowhere; lives with the card.

### 0.4 Generable twins and the evaluation set

- Every `@Generable` type gets a `Codable` twin in `ShepherdCore` (`TriageVerdict`,
  `CIDiagnosis`, `ThreadDigest`, …) plus a one-line `init(_ generated:)` in the app target. Cloud
  providers decode straight into the twin from the JSON contract suffix `IntelligencePrompt`
  already appends; on-device decodes into the `@Generable` and converts. The UI and the database
  only ever see the twin.
- `Scripts/eval-intelligence/` — a small, **manually run** harness (a macOS test target gated by
  `SHEPHERD_EVAL=1`): 20–30 anonymised fixture PRs (`Tests/Fixtures/eval/*.json`) with expected
  verdicts and expected CI diagnoses, printing precision per field. Not in CI; it exists so a
  model update (Apple ships them with the OS) or a prompt change is measured, not felt. Apple's
  Evaluations framework is used if its API is stable when we get here, a plain XCTest loop
  otherwise.

### 0.5 Settings and copy

- One new `IntelligenceGroup` field: `structuredTriageEnabled` (default: follows
  `intelligenceMode != .off`). Everything else in this plan is an explicit click and needs no
  toggle. Sync document + applier + fixture in the same commit.
- The Intelligence tab's "What AI never does" card gains one sentence about tools:
  "When the model looks something up, it can only read — the checks, a log, a file. It cannot
  comment, approve, merge or start an agent."

Effort for Phase 0: **M** (about a week of focused work). It unblocks everything below.

---

## 3. Features, in delivery order

Each feature lists: the story, the tier, the Apple API, the data and its budget, the guardrail,
the UI, the tests, effort (S ≤ 2 days, M ≤ 1 week, L ≤ 2 weeks), and the ADR it needs.

### A. Structured triage — a verdict per pull request

**Story.** The inbox sorts itself by *what kind of change this is and how much it can hurt*.
Chips on each row: `fix · risk high — touches auth middleware and deletes two tests`. A facet in
the sidebar filters by kind and risk; ⌘K understands `risk:high kind:dependency`.

- **Tier:** 2 only. Bulk, unattended (runs in the search-index pass), so no cloud fallback
  exists — when the model is unavailable the facet is simply absent.
- **API:** `SystemLanguageModel(useCase: .contentTagging)`, `@Generable enum Kind { feature,
  fix, chore, dependencyBump, docs, refactor }`, `@Generable enum Risk { low, medium, high }`,
  `@Generable struct TriageVerdict { kind, risk, reason: String (@Guide: one sentence) }`.
  Low temperature.
- **Data & budget:** the ADR 0019 `SearchDocument` (already byte-budgeted, already built per
  row) plus the tier-1 risk hints (`FilePrioritizer` reasons: "touches auth", "deletes tests",
  lockfile-only, generated files). Roughly 1,500 tokens per PR; the tagging model is fast enough
  for a 200-row inbox in the background at `.utility` priority.
- **Storage:** migration **v4**, table `triage_verdicts (prID PK, documentHash, kind, risk,
  reason, modelIdentifier, classifiedAt)`, cascading delete with `pull_requests`, re-classified
  only when `documentHash` changes (same invalidation rule as the vector). `DatabaseManagerTests`
  lists v4.
- **Guardrail:** it sorts, it does not approve. `BulkTriagePlan` and auto-merge rules **do not
  read** this table — that is a rule in the ADR and a unit test asserting the rules engine's
  inputs. The heuristic risk hints remain visible when the model is off, so the facet degrades
  to tier 1 instead of vanishing entirely.
- **UI:** `TriageChip` in the inbox row, a `Risk` facet section in the rail, two ⌘K filter
  tokens, a "why?" popover with the reason. Settings: the `structuredTriageEnabled` toggle
  under Semantic Search with the same "never leaves this Mac" copy.
- **Tests:** twin type + facet filter + ⌘K token parsing on Linux; classifier pass with a fake
  model in `SemanticSearchTests` style; a skip-if-unavailable smoke test on macOS.
- **Effort:** M. **ADR 0023** (structured triage; the "does not approve" rule and the no-cloud
  rule as decisions).

### B. Streaming drafts

**Story.** The ✨ draft appears word by word in the composer, in under a second on-device.

- **Tier:** 2 and 3, same ladder as today. **API:** Phase 0.2. **Data:** unchanged.
- **Guardrail:** the ask-before-replace question moves *in front of* the stream; a cancel
  (Escape, or the reviewer typing) stops the task and keeps what arrived, labelled.
- **UI:** `ComposerTextEditor` renders the partial in the AI caption colour until the stream
  ends; the sparkles button becomes a stop button while streaming.
- **Tests:** `AIDraftFieldState` transitions; SSE parsers on Linux; a streaming fake in
  `IntelligenceTiers`.
- **Effort:** S once Phase 0.2 exists. **ADR:** none — inside the 0007 drafting amendment.

### C. Saved-reply suggestion

**Story.** Start typing a reply and the two saved replies that fit this thread are at the top
of the `text.badge.plus` menu, before the alphabetical list.

- **Tier:** on-device embeddings (ADR 0019's `NaturalLanguageEmbedder`), no language model at
  all. **Data:** the thread's comment bodies (locally cached) and each saved reply's body,
  embedded once and cached per snippet hash in memory.
- **Guardrail:** offered, never inserted. No setting; when embeddings are unavailable the menu
  is the plain list.
- **Tests:** ranking over fixture vectors on Linux (`SearchRanker` reuse); menu ordering in
  `ShepherdTests`.
- **Effort:** S. **ADR:** none.

### D. Explain these lines

**Story.** Select lines in the diff, press ⌥E (or the new item in the gutter popover): a
popover explains what the change does and what it touches, streaming, in your language. One
button turns the explanation into the start of an inline comment — labelled, editable, exactly
like a draft.

- **Tier:** 2 first; tier 3 allowed (a diff excerpt already travels for inline drafts under
  the 0007 amendment). **API:** streaming prose, default model.
- **Data & budget:** `InlineCommentDraftBuilder`'s existing windowed excerpt (path, status, the
  anchored lines last to go) — reused unchanged, with a different instruction. Instructions ask
  for the answer in `Locale.current.language` so German users read German.
- **Bridge:** the Monaco gesture already delivers `addComment {line, startLine, side}`; the
  popover it opens gains an "Explain" action, so no new inbound bridge message. The explanation
  renders natively in a SwiftUI popover anchored to the gutter row, not inside the web view.
- **Guardrail:** the "turn into comment" button writes through `AIDraftFieldState`, so the
  replace/append rule and the caption apply; there is no path from the popover to the outbox.
- **Tests:** request builder budget cases (reuse), popover state machine, an `XCTSkip`-gated
  smoke test.
- **Effort:** M. **ADR:** an amendment to 0007 (a third drafting surface, same contract).

### E. Delegation brief — from finding to agent task

**Story.** In the delegation sheet, a ✨ button drafts the task for the coding agent from what
Shepherd already knows: the focus reasons, the finding comments, and (after F) the CI
diagnosis. The reviewer edits and presses Run. This is the loop developers will show each other:
*Shepherd notices, Apple's model writes the brief on your Mac, Claude Code fixes it in a
worktree, Shepherd shows you the diff.*

- **Tier:** 2 first; tier 3 allowed only for content that already travels (digest, own pending
  comments) — a brief that would include a colleague's comment stays on-device (ADR 0020's
  reasoning).
- **API:** streaming prose into the task field (Phase 0.2), `@Generable struct AgentBrief {
  goal: String, constraints: [String], acceptance: [String] }` rendered as Markdown.
- **Data & budget:** `DelegationContext` (slug, head OID, origin, focus reasons, finding
  comments) + the `PullRequestDigest` with the notes' share reserved, like
  `ReviewSummaryDraftRequest`.
- **Guardrail:** the brief is text in a field; **Run is still the reviewer's click**, and the
  auto-delegation rules (ADR 0016) keep using their fixed templates — an unattended rule never
  gets a generated brief.
- **Tests:** builder budget cases on Linux; field state; a fake-tier test that the sheet's Run
  button is untouched by a draft.
- **Effort:** S–M. **ADR:** amendment to 0011 (drafted briefs, attended only).

### F. "Why is CI red?" — tool calling on the review screen

**Story.** A red check gets a "Why?" button. A card fills in step by step — *reading failing
checks · reading the last 200 lines of `App build (macOS)` · reading `LocalizationTests.swift`* —
then answers: **failing test**, **file:line**, **one-line hypothesis**, **confidence**. Each step
expands to show exactly what the model saw. One click hands the diagnosis to feature E.

- **Tier:** 2 first, with tier 3 as an *explicit* per-click fallback when tier 2 reports the
  budget exceeded ("Ask <provider> with the full log?"). Logs are new content for the cloud path:
  `CONTRIBUTING.md`'s host list gets the sentence, and the ADR records it.
- **API:** `Tool` calling (Phase 0.3) with exactly three tools: `FailingChecks()` (from
  `check_runs`, local), `JobLogTail(checkName:)` (new GitHubKit read, see below),
  `FileDiff(path:)` (from `changed_files.patch`, local, windowed). Output `@Generable struct
  CIDiagnosis { failingTest: String?, file: String?, line: Int?, hypothesis: String,
  confidence: Confidence }`.
- **Data & budget:** the on-device budget is the whole design problem here. A tier-1
  `LogDigest` in `ShepherdCore` (Linux-tested against real Xcode, swift-test, npm and pytest log
  fixtures) reduces a log to the failing region: lines matching `error:|FAILED|Test Case .*
  failed|\*\* TEST FAILED|Error:` with 3 lines of context, deduplicated, capped at ~1,200 tokens.
  `FileDiff` uses the inline-draft window around the line the log named. The model gets summaries,
  never raw text.
- **GitHubKit:** `jobLogs(repo:jobID:)` — `GET /repos/{o}/{r}/actions/jobs/{id}/logs` (302 to a
  short-lived blob URL; follow, cap at 2 MB, stream to a temp file, digest, delete). The job id is
  parsed from `CheckRun.detailsURL` (`/actions/runs/{run}/job/{job}`) — for non-Actions checks
  (Buildkite, CircleCI) the tool answers "no log available for this check" and the model works
  from the check's own summary text. ETag-cached like every other read.
- **Guardrail:** three read tools, fixed at compile time; no tool takes free text that reaches
  GitHub except a path that must match a changed file. The answer is a card. Handing it to
  feature E still ends in a human Run click.
- **UI:** `CIDiagnosisCard` under the checks list, `IntelligenceTrace` as a disclosure list,
  a "Draft an agent brief" button, the tier caption. Failure copy from `IntelligenceOutcome` as
  everywhere else.
- **Tests:** `LogDigest` and `detailsURL` parsing on Linux with fixtures; tool registry
  invariants; a fake tier that scripts the hops; the GitHubKit read against recorded responses.
- **Effort:** L. **ADR 0024** (tool calling: read-only registry, the log content rule, the
  explicit cloud fallback).

### G. Thread digest

**Story.** A thread with 15 comments shows "Summarise": three lines — *what was agreed, what is
still open, who is waiting on whom* — above the thread, on-device.

- **Tier:** 2 **only**. Colleagues' comments never go to a BYOK endpoint (ADR 0020's argument,
  applied). When the thread does not fit 8K, the digest offers the last N comments and says so.
- **API:** `@Generable struct ThreadDigest { state: Agreed | Open | Blocked, summary: String,
  openQuestions: [String] }`.
- **Data & budget:** `review_comments` for the thread, newest-last, budgeted by the same
  eviction pattern as pending-comment quotes.
- **Guardrail:** text in a card; "Resolve thread" stays its own button, and the digest never
  suggests pressing it.
- **Effort:** M. **ADR:** amendment to 0007 (on-device-only content class).

### H. Siri and Shortcuts: "Summarise this pull request"

**Story.** "Hey Siri, summarise my next review in Shepherd" — Siri reads the on-device summary
and shows a snippet. In Shortcuts, `Get Review Queue` → `Summarise Pull Request` → `Show Result`
composes with Apple's own *Use Model* action, so developers script their own morning routine.

- **Tier:** 2 only — an intent has no review screen to fall back to a human, so cloud is off
  the table and the intent says "Apple Intelligence is not available" in `IntentDialog` when the
  model is not.
- **API:** `SummarizePullRequestIntent: AppIntent` with a `PullRequestEntity` parameter,
  `ProvidesDialog` + `ShowsSnippetView`; the summary via the existing `IntelligenceRouter
  .summary(for:)` forced to the on-device tier. `AppShortcutsProvider` gains the phrase (English;
  German phrases land with the `AppShortcuts.xcstrings` follow-up in the roadmap).
- **Guardrail:** the entity stays metadata-only (ADR 0021); the summary is the *result* of a
  user-invoked intent, shown once, not stored on the entity and not exported to Spotlight.
- **Effort:** S–M. **ADR:** amendment to 0021.

### I. Private Cloud Compute as tier 2½ — verified 2026-09-03, parked (ADR 0025)

**Story.** Users who will not bring an API key but trust Apple's stated guarantees get a 32K
context for the same requests, selectable as `On-device + Private Cloud Compute`.

**What the verification found.** `PrivateCloudComputeLanguageModel` and the `LanguageModel`
protocol are real, with the 32K context and the three `reasoningLevel`s as described — but both
are **macOS 27.0+ (beta)**, not 26.4, and the no-cost entitlement Apple documents is for App Store
Small Business Program members with apps **distributed on the App Store**. Shepherd targets
macOS 26.0 and ships Developer-ID-signed outside the store. The hosts the framework contacts are
not documented, so the privacy contract could not name them.

**Decision.** Parked in [ADR 0025](../adr/0025-private-cloud-compute.md), which also records the
design for the day it can be built: a rung between tiers 2 and 3, attended surfaces only (drafts,
explain, brief, CI diagnosis — never triage, digests or the Siri summary), reported in the
served-by line, `.light`/`.moderate` reasoning counted against the budget, quota shown as a
state. Unparked when all three hold: deployment target macOS 27+, an entitlement path for direct
distribution (or an App Store decision of its own), documented hosts.

### J. Collapse the providers onto Apple's `LanguageModel` protocol — evaluated 2026-09-03, not adopted

**Premise.** When Swift packages conforming to `LanguageModel` are stable, the Anthropic and
OpenAI-compatible providers shrink to configuration and the streaming, tool and `@Generable`
plumbing becomes one code path. No user-visible change.

**What the evaluation found.** Anthropic ships `ClaudeForFoundationModels` (v0.1.0, beta,
Apache-2.0, macOS 27 beta), conforming to `LanguageModel` with streaming, tools and `@Generable`.
Google's conformance lives inside the Firebase SDK, which Shepherd will not take on for one
provider. There is **no OpenAI-compatible conformance** to Apple's protocol — `AnyLanguageModel`
is a separate abstraction of its own, not a `LanguageModel`, so konduit and every other
OpenAI-compatible endpoint (§K) would keep the hand-written provider regardless. Apple's own
protocol requires macOS 27.

**Decision.** Not adopted. The collapse would remove one of the two cloud providers, not both, at
the cost of a beta dependency and a deployment-target jump the app is not making. Re-evaluate when
the deployment target is macOS 27 *and* the Anthropic package is at 1.0 *and* either an
OpenAI-compatible conformance exists or §K has been dropped — until then the single
`IntelligenceProvider` protocol (Phase 0.2) is the seam that keeps the three providers behaving
alike, and it is tested on the Linux runner, which Apple's framework is not yet.

### K. konduit as the EU tier-3 endpoint, first-class but still one code path

**Story.** A user on the `Konduit (EU)` preset sees, per answer, *who actually ran the model and
where*, can pin the request to a country set with zero retention, and picks models from a list
that shows sovereignty beside the name. Nothing else in Shepherd changes: konduit stays the
OpenAI-compatible provider it already is (ADR 0007 amendment: a preset only fills in a base URL).

What the konduit gateway offers today (`schnaq/konduit`, `docs/openapi/gateway.yaml`, read-only
reference — Shepherd never depends on konduit's code, only on its public API):

- `POST /v1/chat/completions` with `stream: true` (SSE) and `tools`/`response_format` relayed
  unchanged to the upstream — so Phase 0.2 streaming and Phase 0.3 tools work against konduit
  without a konduit-specific request shape. A model that cannot do tools surfaces as the
  gateway's `upstream_invalid_request`, which maps to `IntelligenceError.toolsUnsupported`.
- `stream_options.include_usage: true` for a final usage chunk — the cloud twin of 0.1's
  measured token count; the OpenAI-compatible provider should send it and read it.
- An optional `provider` object in the body — the sovereignty policy: `countries: [DE, FR]`,
  `zero_retention: true`, `require: [certifications]`, `order: [operators]`. Unknown fields are
  rejected, so it is only ever sent when the user set it.
- Response headers `Konduit-Provider` (the operator that ran the weights) and
  `Konduit-Deployment` (the exact deployment id, pinnable by sending it back as `model`).
- `GET /v1/models` extended with `pricing` and a `sovereignty` block (`hosting_country`,
  `ownership`, `zero_retention`, `tier`, `certifications`, `note`) after OpenAI's four fields —
  `OpenAIModelsResponse` already ignores the extras; a tolerant decode can keep them.
- `Authorization: Bearer kdt-…`; OpenAI's error envelope with konduit codes
  (`upstream_rate_limited`, `upstream_unavailable`, `no deployment matches your sovereignty
  policy`) and `Retry-After` on every 429.

**Design, kept inside the existing rules:**

- The OpenAI-compatible provider reads two *optional* response headers into the outcome's tier
  caption ("Drafted by konduit · scaleway, DE") — a generic "served-by" hook that any endpoint
  may fill, not a konduit branch. Unknown headers: caption unchanged.
- Model discovery keeps konduit's `sovereignty` block when present and the picker shows a
  small badge (country · zero-retention). Pure decoding in `OpenAIModelsResponse`, fixture-tested.
- One optional setting per OpenAI-compatible endpoint, `sovereigntyPolicy` (countries, zero
  retention) — in the sync document like the base URL, sent only when non-empty, and the preset
  picker explains it only for konduit. This is the single place a preset may show extra UI, and
  it still does not add a request shape: the field is part of OpenAI's open `extra_body`.
- `Retry-After` honoured once on 429 for drafting requests (never a loop).

**Tier:** 3b. **Effort:** S–M. **ADR:** amendment to 0007's preset amendment (headers and
policy are optional extensions a preset may *describe*; still no per-preset code path).

---

## 4. Sequence and milestones

```
Phase 0 ── groundwork (0.1 → 0.5)                                    ~1 week
   │
   ├─ Sprint 1: A Structured triage · B Streaming drafts · C Saved-reply suggestion
   │            → "the inbox sorts itself, drafts stream"             ~2 weeks
   │
   ├─ Sprint 2: D Explain these lines · E Delegation brief · G Thread digest
   │            → "point at anything, get a plain-language answer"   ~2 weeks
   │
   ├─ Sprint 3: F Why is CI red? (needs 0.3, E)                      ~2 weeks
   │            → the demo: red check → diagnosis → agent brief → fixed in a worktree
   │
   └─ Sprint 4: H Siri summary · K konduit extras · I PCC rung (verified → parked) · J evaluated
```

Ship after each sprint behind the release train in `docs/RELEASING.md`; each feature is
independently removable because every one lives behind `IntelligenceRouter` + a card, and none
changes the outbox.

**Dependencies:** B needs 0.2 · A needs 0.1 + 0.4 + migration v4 · D needs 0.2 · E needs 0.2
(and F for the diagnosis hand-off, optional) · F needs 0.3 + 0.4 + the GitHubKit log read ·
G needs 0.4 · H needs nothing new beyond an intent · I needs the SDK verification.

---

## 5. Parked, with the reason

- **Custom adapters** (Apple's adapter training toolkit, LoRA on the on-device model). Tempting
  for a review-comment style, but adapters are tied to a specific model version, must be retrained
  when Apple updates the OS model, and would make Shepherd's output quality depend on a training
  pipeline the project has no way to run in CI. Revisit only if the eval set (0.4) shows the base
  model failing at something adapters demonstrably fix.
- **Vision: text in screenshots pasted into PR bodies** (`RecognizeTextRequest`). Agents do
  paste error screenshots, and OCR'd text would make them searchable. Needs image downloads from
  GitHub's user-content host during indexing and a decision about where OCR text may go (search
  index yes, Spotlight metadata no). Worth an ADR of its own once the issues inbox (v1.1) makes
  screenshots more common.
- **Spotlight-RAG / system tools** offered by Foundation Models. A review tool's answers must
  come from the pull request, not the user's Mail; declining these keeps the "the model saw
  exactly this" trace truthful.
- **Private Cloud Compute rung (§I) and the `LanguageModel` collapse (§J)** — both verified on
  2026-09-03 and both macOS 27: parked in ADR 0025 and in §J above, with the conditions that
  reopen them.
- **Session reuse across requests** (one multi-turn session per review screen). Cheaper, but the
  transcript would silently carry earlier hunks into later prompts and defeat the per-request
  budget audit. Reconsider if 0.1's measured counting shows real headroom.

---

## 6. Risks and how each is handled

| Risk | Handling |
|---|---|
| Apple Intelligence disabled on the CI Mac | Every model-touching test `XCTSkip`s on unavailability; pure twins/budgets/parsers are tested on Linux; the eval set is manual. |
| Guardrails over-fire on technical content | Mapped to one localised line; no automatic retry; the trace shows what was sent so the reviewer can judge. |
| 8K budget too small for real logs/threads | Tier-1 digests (`LogDigest`, comment eviction) are the design, the hard error is the backstop, the explicit cloud/PCC ask is the escape hatch — never a silent truncation. |
| Model quality on code | Outputs are short, structured, and labelled; nothing acts on them; the eval set measures drift when Apple updates the model. |
| Scope creep into "AI reviews for you" | Every feature above ends in a card or an editable field; ADR 0023/0024 write the non-goal down again with a test that asserts the rules engines do not read model output. |
| German output | Instructions carry the user's language; the catalog covers every fixed string; generated text is the user's language by instruction, and falls back to English gracefully. |

---

## 7. Definition of done, per feature

- Works with the model unavailable (tier-1 fallback state visible, no dead buttons).
- Budget path has a test that hits `digestTooLarge` deliberately.
- New `@Generable` has a `ShepherdCore` twin with Linux tests.
- No new outbox path; the rules-engine-input test still passes.
- Strings in the catalog, checker green; any new setting in the sync document with fixture.
- Host list and ADR updated if anything new travels; `docs/FEATURES.md` gets its paragraph.
- Trace visible for anything that called a tool.
