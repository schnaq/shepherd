# Look closer — the reviewer that reads the diff (ADR 0038, item 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Status: plan · Date: 2026-09-22

**Goal:** A reviewer clicks *Look closer* on a ✗ or ? line of the claims card, and the on-device
model reads the diff with tools and comes back with **places in the diff**, each one a verbatim
excerpt Shepherd has located itself, plus the record of what the model read.

**Architecture:** A new seam `ClaimChecking` (sibling of `ClaimExtracting`, on-device only, no
router), one production conformer `OnDeviceClaimChecker` that runs a
`LanguageModelSession(profile:)` whose `DynamicProfile` forces the first turn to call a tool
(`.required`), allows a few more, then disallows — the macOS 27 API that makes "check the claim
against the diff" a guarantee rather than a request. The tools are the three the CI diagnosis
already uses (`OnDeviceToolBridge` over `LocalToolExecutor`). The answer goes through a pure
`ShepherdCore` locator that drops every excerpt it cannot find in that file's patch.

**Tech Stack:** Swift 6.4, SwiftUI, FoundationModels (macOS 27: `DynamicProfile`,
`GenerationOptions.ToolCallingMode`, `onToolCall`), XCTest, `swift test` on Linux for ShepherdCore.

**Spec:** [ADR 0038](../adr/0038-macos-27-floor.md) item 2, as corrected by
[ADR 0026's 2026-09-22 amendment](../adr/0026-claims-vs-evidence.md).

## What the spike settled (2026-09-22, this Mac, macOS 27.0 / Xcode 27.0)

- `LanguageModelSession(profile:)` with `Profile { Instructions(…); [tools] }` compiles; tools go
  inside the instructions builder. `.toolCallingMode(.required)` **for the whole session loops
  forever** — the model must call a tool on every turn and never answers. A profile whose body
  reads a hop counter (`.required` at zero, then `.disallowed`) answered in about a second with one
  tool call. `session.usage` reports input and output tokens.
- `PrivateCloudComputeLanguageModel().availability` answers `.available` for a Developer-ID or
  ad-hoc binary, **and the first request fails** with `ModelManagerError 1046`. ADR 0025 stays
  parked; availability is not a usable signal for it. No PCC fallback in this item.
- `SpotlightSearchTool` exists (`_CoreSpotlight_FoundationModels`, `.focused()`), but Shepherd's
  index holds only the title, slug, author, check state and labels of *open* pull requests
  (`SpotlightExport`). "Related pull requests" from that is a title search the app can do without
  a model. Not in this item.

## Global Constraints

- On-device only. `ClaimChecking` takes no router, no base URL and no key; `IntelligenceProvider`
  gains no method. The claim is a colleague's sentence (ADR 0026, ADR 0007's brief rule).
- Attended: one click on one line starts one session. Nothing runs on expansion, sweep or scroll.
- No verdict change. The line's ✓/✗/? stays what `EvidenceChecker` said; the model adds a block
  under it, tagged *Read by the model*. No score, no confidence field in the schema.
- Every excerpt shown is located by `DiffExcerpt.locate` in that file's `patch`; an excerpt that
  is not found is dropped, never repaired.
- Nothing is stored: results live as long as the review screen, like the rest of the card.
- Copy: every new string gets a German row in `Shepherd/Resources/Localizable.xcstrings`; fonts go
  through the same `.system(size:)` sizes the card already uses.

## File structure

- Create `Packages/ShepherdKit/Sources/ShepherdCore/Claims/ClaimCheck.swift` — `ClaimCheck`,
  `ClaimCheck.Note`, `DiffExcerpt.locate(_:inPatch:)`, `ClaimCheck.verified(_:in:)`. Pure.
- Create `Packages/ShepherdKit/Tests/ShepherdCoreTests/ClaimCheckTests.swift`.
- Create `Shepherd/Intelligence/ClaimChecking.swift` — the seam.
- Create `Shepherd/Intelligence/OnDeviceClaimChecker.swift` — profile, `@Generable` twin,
  pre-flight, prompt.
- Modify `Shepherd/Features/Review/ClaimsEvidenceModel.swift` — per-line check state.
- Modify `Shepherd/Features/Review/ClaimsEvidenceCard.swift` — the button and the block.
- Modify `Shepherd/App/AppEnvironment.swift`, `Shepherd/Features/PullRequest/ConversationView.swift`
  — wiring.
- Create `ShepherdTests/ClaimCheckingTests.swift` — model behaviour with a fake checker.
- Modify `docs/adr/0026-claims-vs-evidence.md`, `docs/adr/0038-macos-27-floor.md`,
  `docs/ARCHITECTURE.md` — the amendment and the corrections.

### Task 1: The locator and the result type (ShepherdCore)

**Interfaces — Produces:**
`public struct ClaimCheck { var notes: [Note]; var trace: IntelligenceTrace }`,
`public struct ClaimCheck.Note { path: String; excerpt: String; sentence: String; line: Int? }`,
`public enum DiffExcerpt { static func locate(_ excerpt: String, inPatch patch: String) -> Location? }`
with `Location { line: Int?; isRemoval: Bool }`,
`ClaimCheck.verified(_ notes: [Note], in files: [ChangedFile]) -> [Note]`.

Rules: excerpt lines are compared with the diff marker stripped, whitespace folded, case kept;
all non-empty excerpt lines must occur **consecutively** in one hunk; the returned line is the
head-side line of the first excerpt line, `nil` with `isRemoval` when that line was deleted;
duplicates (same path and line) are dropped; at most `ClaimCheck.maximumNotes` (4) survive.

- [ ] Write failing tests: single added line found with its head line; context line found; removed
  line found with `line == nil`; two consecutive lines found; two non-consecutive lines not found;
  excerpt with `+`/`-` markers still found; whitespace differences folded; path not in the pull
  request dropped; excerpt absent dropped; duplicates dropped; cap at four.
- [ ] `swift test --filter ClaimCheckTests` fails (types missing).
- [ ] Implement over `UnifiedPatch.hunks(in:)`.
- [ ] `swift test` passes; commit.

### Task 2: The seam and the on-device checker

**Interfaces — Consumes:** Task 1. **Produces:**
`protocol ClaimChecking: Sendable { func availability() async -> OnDeviceAvailability; func check(_ line: ClaimsEvidenceReport.Line, in detail: PullRequestDetail) async throws -> ClaimCheck }`,
`struct OnDeviceClaimChecker: ClaimChecking`.

- Profile: `ClaimCheckProfile: LanguageModelSession.DynamicProfile` with a `HopGate`
  (`Mutex<Int>`, incremented in `onToolCall`): `.required` at 0 hops, `.allowed` below
  `maximumHops` (3), `.disallowed` from then on, so the session always ends in an answer.
- Tools: `OnDeviceToolBridge.tools(executor: LocalToolExecutor(detail:budget:), recorder:)`.
- Prompt: claim label, the quote, Shepherd's own facts (`englishSentence`), changed paths
  (`CIDiagnosisRequest.changedPaths(in:)`). Measured with `tokenCount(for:)` against
  `OnDeviceProvider.budget.limited(toContextSize:reservedForResponse:)`; too large throws
  `IntelligenceError.digestTooLarge`.
- Answer: `@Generable OnDeviceClaimCheck { notes: [OnDeviceClaimNote] }` → `ClaimCheck.verified`.
- [ ] Build (`mise run build`) — the SDK is the test of the profile's spelling; commit.

### Task 3: Per-line state in the model, the card, the wiring

**Produces:** `enum ClaimCheckState { case checking, done(ClaimCheck), failed(String) }`,
`ClaimsEvidenceModel.checks: [String: ClaimCheckState]`,
`ClaimsEvidenceModel.canCheck(_ line:) -> Bool`, `func check(_ line:) async`,
`refresh(detail:extractor:checker:)`.

- `canCheck` is true for ✗ and ? lines once the checker said `.available`. A second click while
  checking does nothing; a new detail cancels the task and forgets every result.
- Card: *Look closer* (`sparkle.magnifyingglass`) beside *Turn into a comment*; the block shows
  each note as the excerpt (mono), its sentence and an *Open in diff* link, the tag *Read by the
  model on this Mac*, and `CIDiagnosisTraceView(trace:)`. No note survived → "The model read N
  files and pointed at nothing Shepherd could find in the diff." Failure → its sentence.
- [ ] Tests with a fake checker: unavailable → no button; check → state `.done`; a `human`
  kind's line checks too; ✓ line cannot be checked; refresh with a new head clears results and
  cancels; failure keeps its sentence; second call while checking does not call again.
- [ ] Build, run `ClaimCheckingTests`, `mise run check`; commit.

### Task 4: Documents

- [ ] ADR 0026 amendment (2026-09-22), ADR 0038 item 2 corrected (PCC, Spotlight), ARCHITECTURE
  line, German rows; `mise run check`; commit; PR; review; merge.
