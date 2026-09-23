# macOS 27 — raising the target, and what it buys a review tool

Status: superseded by [ADR 0038](../adr/0038-macos-27-floor.md) (the floor decision and programme);
items 1–3 landed 2026-09-22, items 4–5 in progress · Date: 2026-09-03 · Corrected: 2026-09-06 ·
Owner decision: Shepherd targets macOS 27 as soon as the build can be verified against the macOS 27
SDK, and **assumes macOS 27 as the target in every decision** until then (2026-09-06).

This plan grounds that decision in what was verified against Apple's documentation and the WWDC26
sessions on 2026-09-03 (see `docs/research/research-ai.md` for the corrections it caused, and
[ADR 0025](../adr/0025-private-cloud-compute.md) for the one thing macOS 27 does *not* unlock). It
says what changes in the toolchain, which new capabilities Shepherd adopts in which order, and
which it declines — with the ADR each item needs. Everything here obeys
[ADR 0007](../adr/0007-layered-intelligence.md): heuristics first, on-device second, a configured
endpoint only on a click, unattended work never leaves the Mac.

## Corrections, 2026-09-06

Seven things this plan states were re-verified against primary sources on 2026-09-06 — the
`ml-explore/mlx-swift-lm` sources on `main` (README, `MLXLanguageModel.swift`, `Package.swift`,
`LICENSE`), Apple's DocC JSON for FoundationModels, and Apple's releases feed. §4's first risk says
every item re-verifies its API before code is written and the research notes record the correction;
this is that, and the corrections are folded into the sections below rather than left as errata.
[`docs/research/research-ai.md`](../research/research-ai.md) carries them with their sources.

1. **The toolchain has not moved.** Xcode 27 is still beta 6 (27A5252f, 2026-08-24) and no GM SDK
   has shipped; macOS 27 is at developer beta 8 with no announced release date, an Apple event on
   2026-09-09, and a public release still expected mid-September.
2. **`MLXLanguageModel` is not an SDK type.** It ships in the open-source package
   `ml-explore/mlx-swift-lm` (MIT), module `MLXFoundationModels`, and *conforms to*
   `FoundationModels.LanguageModel`, which is the part Apple ships. Adopting it is a **third-party
   SPM dependency decision** — which is what ADR 0031 now decides, rather than "switch on a type
   that is already there".
3. **There is no `MLXLanguageModel(modelID:)`.** The one public init takes a `ModelConfiguration`,
   a declared capability list and three closures; the ergonomic entry is the
   `#huggingFaceLanguageModel(configuration:capabilities:)` macro. **Capabilities are declared at
   construction and never inferred**, and a request beyond them throws
   `LanguageModelError.unsupportedCapability` — so the picker has to say what each model can do
   before it is downloaded, not after.
4. **Where the weights land, and which hosts.** The package's default path resolution is an
   internal `HubCache` following the Hugging Face convention, which is not an app-container path;
   the direct init's `weightsLocation:`/`load:` closures let the app choose, and Shepherd does.
   Downloads start at `huggingface.co` and redirect to CDN hosts under **`hf.co`**, so the host
   list gains **two** suffixes rather than one.
5. **The error deprecation is confirmed, not merely likely.** `LanguageModelSession.GenerationError`
   is deprecated at 27.0 in favour of `LanguageModelError`, whose case list is now known.
6. **Guardrails do not apply to a brought model.** This plan hedged; the hedge was wrong. There is
   no guardrail code in the MLX adapter, and a Hugging Face model runs with no content filter
   unless the app adds one.
7. **`reasoningLevel` is settled.** `ContextOptions.ReasoningLevel` is `.light` / `.moderate` /
   `.deep` / `.custom(_:)` — `.moderate` rather than the betas' `.medium`, plus a fourth case no
   source had.

## 0. What was verified, and what was not

| Claim | State on 2026-09-03, corrected 2026-09-06 where marked |
|---|---|
| macOS 27 release | **Corrected 2026-09-06:** developer beta 8. Still no announced GA date and no Apple press release; an Apple event on 2026-09-09; public release expected mid-September 2026. |
| Xcode 27 | **Corrected 2026-09-06:** still beta 6 (27A5252f, 2026-08-24, Swift 6.4). **No release candidate, and the GM SDK has not shipped.** Host requirement **macOS 26.4+**, Apple Silicon only — a build Mac does not need macOS 27 itself. |
| GitHub-hosted runners | A separate `xcode-27` image is in public preview (arm64). The `macos-26` images carry Xcode 26. |
| `LanguageModel` protocol, `LanguageModelExecutor`, `PrivateCloudComputeLanguageModel`, `CoreAILanguageModel` | Real, all **macOS 27.0+**. `LanguageModelSession(model:)` is the one-line swap. **Corrected 2026-09-06:** `MLXLanguageModel` is *not* in this list — it is not an SDK type. See its own row. |
| On-device context | **Still 8,192 tokens** on `SystemLanguageModel`. Only Private Cloud Compute (32K) or a model you bring raises it. |
| Image input | `Attachment(NSImage/CGImage)` inside `session.respond { }`. Two Vision-backed tools, `OCRTool` and `BarcodeReaderTool`, ship with the framework. |
| `Transcript` | Gains `DynamicProfile`: swap model, tools and instructions mid-session while keeping the history. |
| Errors | **Confirmed 2026-09-06:** it supersedes. `LanguageModelSession.GenerationError` is **deprecated at 27.0** — "Use `LanguageModelError`, `SystemLanguageModel.Error`, or `LanguageModelSession.Error` instead… You must update to Xcode 27 to catch the new error types". `LanguageModelError`'s cases are `.contextSizeExceeded`, `.rateLimited`, `.refusal`, `.timeout`, `.guardrailViolation`, `.unsupportedCapability`, `.unsupportedTranscriptContent`, `.unsupportedGenerationGuide`, `.unsupportedLanguageOrLocale`. `OnDeviceProvider` maps the deprecated type today and moves with §1's commit. |
| `reasoningLevel` names | **Confirmed 2026-09-06:** `ContextOptions.ReasoningLevel` is `.light` / `.moderate` / `.deep` / `.custom(_:)`. `.moderate` is the name — the betas' `.medium` was wrong — and `.custom(_:)` is a fourth case no earlier source carried. |
| Private Cloud Compute entitlement | Still App Store Small Business Program, App Store distribution. **Unchanged; ADR 0025 stays parked** with one of three conditions met. |
| `MLXLanguageModel` | **Corrected 2026-09-06.** Not an SDK type: it lives in `ml-explore/mlx-swift-lm` (MIT), module `MLXFoundationModels`, and conforms to `FoundationModels.LanguageModel`. Gated by `#if canImport(FoundationModels, _version: 2)` and the SwiftPM trait `FoundationModelsIntegration` (on by default); below the 27 SDK the module compiles empty. Dependencies: `ml-explore/mlx-swift` (MIT) and `swiftlang/swift-syntax` (Apache-2.0, compile-time macro) — **no** Hugging Face Swift package, its `HuggingFace`/`Tokenizers` modules are internal targets. **There is no `MLXLanguageModel(modelID:)`**: the one public init is `init(configuration:capabilities:configurationResolver:weightsLocation:load:)`, and the ergonomic entry is the `#huggingFaceLanguageModel(configuration: LLMRegistry.qwen3_0_6b_4bit, capabilities: [.reasoning])` macro. Capabilities are declared at construction and never inferred — `.guidedGeneration` (xgrammar-constrained `@Generable`), `.toolCalling`, `.reasoning`, `.vision` (image `Attachment`, gated), streaming via `respond(to:model:streamingInto:)` — and a request beyond them throws `LanguageModelError.unsupportedCapability`. **Still unverified:** exact on-disk sizes of the larger 4-bit builds, and whether any entitlement beyond `com.apple.security.network.client` (and likely increased memory) is needed. |
| Guardrails on a brought model | **New, 2026-09-06.** They do not apply. Apple: "Guardrails are a safety system tied to a specific model… For any foundation model you use, consider… Does the model have a guardrail system?" There is no guardrail code in the MLX adapter, so a Hugging Face model runs with **no content filter** unless the app adds one. |
| Weights: where they land, and the hosts | **New, 2026-09-06.** Default resolution goes through an internal `HubCache`; the exact default literal path is not verifiable from the sources, but it follows the Hugging Face convention (`~/.cache/huggingface/hub`), which is **not** an app-container path. The host app controls the location entirely through the direct init's `weightsLocation:`/`load:` closures (the README shows a shared-volume example). Downloads start at `huggingface.co` and redirect to CDN hosts under **`hf.co`** (`cdn-lfs.hf.co`, `cdn-lfs-us-1.hf.co`, `cas-server.xethub.hf.co`, historically `cdn-lfs.huggingface.co`); Hugging Face's own allowlisting guidance is the two suffixes `huggingface.co` and `hf.co`. |
| Candidate weights (`mlx-community` 4-bit) | **New, 2026-09-06**, sizes from secondary sources and to be verified on device: Qwen2.5-Coder-7B-Instruct-4bit (~4.3 GB, 32K, tool calling, Apache-2.0); Qwen2.5-Coder-32B-Instruct-4bit (~18–20 GB **estimated**, 128K, Apache-2.0); Qwen3-Coder-Next-4bit (80B MoE / 3B active, ~17.5 GB weights, ~42 GB RAM recommended, 256K, native tool parser, Apache-2.0); DeepSeek-Coder-V2-Lite-Instruct-4bit (16B MoE / 2.4B active, 128K, custom DeepSeek Model License — commercial OK, not OSI); Gemma 3 4B/12B/27B 4-bit (Gemma Terms of Use — prohibited-use policy with flow-down and unilateral restriction rights; higher licence risk). |
| `CoreAILanguageModel` | For weights the app bundles or downloads itself (`CoreAILanguageModel(resourcesAt:)`), Neural-Engine execution. |
| App Intents | App Schemas, an Interaction Donations API, per-app attribution in Spotlight's semantic index. Session summaries only; **unverified** in detail. |
| Writing Tools, NaturalLanguage embeddings, Translation, notarisation, Sparkle, GRDB | **No macOS 27 changes found.** |
| SwiftUI | Toolbar overflow and priority APIs, `confirmationDialog(item:)`, a document-writer protocol suite. Nothing that forces a change. |
| Swift language mode | Xcode 27 ships Swift 6.4. Raising the deployment target does not change the language mode or memory-safety settings by itself. |

## 1. Toolchain — one commit, held until CI can compile it

The change itself is small and is prepared as a single commit on this branch:

- `project.yml`: `deploymentTarget.macOS: "27.0"` and `MACOSX_DEPLOYMENT_TARGET: "27.0"`.
- `Packages/ShepherdKit/Package.swift`: `platforms: [.macOS(.v27)]` for the Apple side; the Linux
  side is unaffected. `swift-tools-version` stays at 6.0 unless `.v27` needs newer — checked on the
  first build.
- The four `if #available(macOS 26.4, *)` measured-token branches in `Shepherd/Intelligence/OnDevice*.swift`
  lose their `else` arms: the estimate fallback was for 26.0–26.3 Macs, which the target no longer
  admits. ADR 0007's amendment about measured budgets gets a one-line note.
- `OnDeviceProvider`'s error mapping moves from the deprecated `LanguageModelSession.GenerationError`
  to `LanguageModelError` — the deprecation is confirmed rather than expected (§0, corrected
  2026-09-06) — and the tool-error unwrap in front of it stays; the `IntelligenceError` cases the
  app shows do not change.
- `README.md`, `docs/ARCHITECTURE.md` and `CONTRIBUTING.md` say macOS 27 where they say 26.

**Decided 2026-09-06.** The owner set the assumption rather than the date: until the SDK is on the
runner, every decision in this plan assumes macOS 27 is the target. The commit above is written and
**rebased onto `main`, and it waits for the runner** rather than for another round of verification.

**The blocker is CI, not code.** The self-hosted runner builds with the macOS 26.5 SDK today.
Two ways out, and the owner chose the first on 2026-09-06:

1. **Install Xcode 27 (beta, later RC) on the runner Mac.** **Chosen; next week.** Its host
   requirement is macOS 26.4+, so the Mac itself need not move to 27. Needs someone at the machine
   once. Free. **No workflow change is part of it:** the runner selects the newest installed Xcode
   automatically, so `.github/workflows/` is untouched and the toolchain commit stays the one
   commit it is.
2. **Move the `App build (macOS)` job to GitHub's hosted `xcode-27` image** until the runner has
   Xcode 27. The repository is private, so hosted macOS minutes are billed at the macOS
   multiplier; a build-and-test run is a few minutes per push. The ShepherdKit jobs stay where
   they are — their `Package.swift` builds against either SDK.

Until one of the two is done the toolchain commit exists but is not pushed to the branch CI
watches. Nothing in §2 can be built before it, because none of the new types exist in the 26.5 SDK
and an `#available` check cannot hide a type the compiler has never seen.

## 2. What to adopt, in order

Ranked by what it does for someone reviewing a herd's pull requests, not by novelty. Each item
names its tier, its guardrail and its ADR.

### A. A local model you bring — `MLXLanguageModel` as the second on-device model (ADR 0031)

**Corrected 2026-09-06 throughout, and the correction changes what this item *is*:**
`MLXLanguageModel` is not an SDK type but a conformer shipped in `ml-explore/mlx-swift-lm` (MIT), so
this is a **third-party SPM dependency decision** as much as a feature. ADR 0031 is written and
Proposed; it becomes Accepted the day §1's commit lands.

**Story.** The 8K ceiling is the one thing that has shaped every on-device feature: windowed
diffs, digests instead of logs, one claim pass per description. A reviewer with an M-series Mac
and the disk for it chooses a bigger open-weight model once, in Settings → Intelligence, and every
tier-2 surface — drafts, explanations, the CI diagnosis, the brief, the triage verdict — runs
against it with a context measured in tens of thousands of tokens, **with nothing leaving the
Mac**. This is the answer to "big agent PRs" that Private Cloud Compute would have been, without
the entitlement and without the network.

- **Tier:** still tier 2. The model runs on this Mac; ADR 0007's "unattended work stays on-device"
  is satisfied by construction, which is what makes this different from every cloud rung.
- **Seam:** `OnDeviceProvider` takes `any LanguageModel` instead of `SystemLanguageModel`. The
  session, tool, `@Generable` and streaming code is unchanged — that is the whole point of Apple's
  protocol, and the protocol is Apple's even though this conformer is not. `preflight` measures
  against the chosen model's `contextSize`; the 8,192 constant becomes the system model's value,
  not the app's.
- **Dependency:** `ml-explore/mlx-swift-lm` (MIT), pulling `ml-explore/mlx-swift` (MIT) and
  `swiftlang/swift-syntax` (Apache-2.0, compile-time macro only) — the first runtime dependency
  outside Apple's frameworks besides GRDB and Sparkle. Pinned to an exact tag, three lines in
  `NOTICES.md`, and it cannot break the Linux or macOS-26 jobs: the module compiles empty below the
  27 SDK and `Packages/ShepherdKit` does not link it at all.
- **Choosing:** a picker in Settings → Intelligence with two entries: *Apple's model (built in)*
  and *A model from Hugging Face*, the latter with an id field and a curated list of three or four
  known-good coder instruct models. Each curated entry shows its **declared capabilities**, its
  download size, a memory note, its context length and its licence — all of it **before** the
  download, because capabilities are declared at construction and never inferred (§0): a request
  beyond what the model was built with throws `unsupportedCapability` rather than degrading, so
  "what will this model answer?" is a fact the picker owes the reviewer up front. Only Apache-2.0
  and MIT weights are curated by default (the Qwen family); a reviewer who types an arbitrary id
  gets it, with the licence they are accepting printed beside the download button. Download is
  explicit — a button, the size, a progress line, a cancel — never on launch, never in a sweep.
- **Where the weights land:** in Shepherd's own Application Support container, through the direct
  init's `weightsLocation:` closure. The package's default resolution follows the Hugging Face
  convention in the user's home directory, which is **not** an app-container path; Shepherd does not
  accept that default, so "delete Shepherd's data" reaches the weights, the Settings row can report
  their size honestly, and another app's cache eviction cannot remove a model mid-session.
- **Host list:** **two** suffixes, not one — `huggingface.co` **and** `hf.co`, which is where the
  download redirects (`cdn-lfs.hf.co`, `cdn-lfs-us-1.hf.co`, `cas-server.xethub.hf.co`) and which
  is what Hugging Face's own allowlisting guidance names. They join `CONTRIBUTING.md` with the
  sentence that says what travels there: **the model id and nothing about the user or any pull
  request**. This is a **download** host pair, not a request host — a file transfer, in the same
  category as the Sparkle update download — and the contract says so.
- **Guardrails: there are none.** Corrected 2026-09-06, and this is a statement of fact rather than
  the hedge this bullet used to carry. Apple's guardrails are tied to a specific model, there is no
  guardrail code in the MLX adapter, and **a Hugging Face model runs with no content filter unless
  the app adds one**. Shepherd does not add one; it says so. The containment is structural and
  already in force: no path from generated text to the outbox (ADR 0007), three compile-time
  read-only tools with a hop cap (ADR 0024), and rules engines that do not read model output — so a
  model with worse judgement than Apple's has the same reach as Apple's, which is none. The Settings
  copy states the absence in one sentence and the served-by line names the model. Unattended
  surfaces (triage, digests, the Siri summary) use the brought model only behind a **second explicit
  toggle**, off by default: "on-device" was never the only reason those surfaces were safe to leave
  running, and a large model on battery is a cost the reviewer opts into rather than a default.
- **Budget:** `IntelligenceDiffWindow` and `LogDigest` take the measured context as a parameter
  today; they get wider windows for free. The eval fixtures (plan v2 §0.4) run once per model so a
  regression on the brought model is visible.
- **Effort:** L. Depends on §1. The loader's licence is settled (MIT, §0); what is still open is
  the on-disk size of the larger builds, whether an entitlement beyond
  `com.apple.security.network.client` is needed, and whether the `#huggingFaceLanguageModel` macro
  can be used at all given the container path — ADR 0031 leans direct init and says why.

### B. Screenshots in the description — image input for the attended surfaces (ADR amendment 0020)

Agents paste screenshots of failing tests and terminal output into descriptions. Today they are
opaque. With `Attachment(NSImage)` the on-device pass can read one when the reviewer asks:
"explain this screenshot" on a pasted image opens the same explanation stream as "explain these
lines", and the CI diagnosis may attach the one image the description carries. Images are fetched
from GitHub's user-content host, which the sync already reaches for avatars; nothing is OCR'd
unattended and nothing from an image enters the search index (the parked Vision item in plan v2 §5
is superseded by this, not revived). Attended only, tier 2 only, no cloud variant.

### C. `DynamicProfile` for the CI diagnosis (ADR 0024 amendment)

The diagnosis runs three tools in one session with a hop cap. `DynamicProfile` lets the session
drop the log tool after the log is read and swap in the diff tool with a narrower instruction,
keeping the transcript — fewer tokens per hop, and a trace that says which profile answered.
Small, and it stays inside ADR 0024's read-only contract. Do after A, because the profile has to
work for both models.

### D. Interaction donations and App Schemas — Siri knows what is on screen (ADR 0021 amendment)

Donate the open pull request as an interaction so "summarise this" needs no phrase with a number
in it. Opt-in, under the same toggle as the Spotlight export, because a donation is a write into
the system's semantic index. Verify the API surface on the GM SDK first; the sessions describe it,
the reference pages do not yet.

### E. `ClaudeForFoundationModels` as the Anthropic provider — when it is 1.0 (plan v2 §J)

The evaluation stands: not before 1.0, and only for the Anthropic tier; the OpenAI-compatible
provider (konduit and every other endpoint) keeps its hand-written code because no conformance
exists. When adopted it removes streaming, tool and structured-output plumbing for one provider
and changes nothing a user sees.

### Declined on macOS 27

- **Private Cloud Compute** — parked in ADR 0025; the entitlement condition is unchanged.
- **`CoreAILanguageModel`** — bundling weights in a DMG multiplies its size by the model; a
  Hugging Face download (A) gives the same capability without shipping gigabytes. Reconsider if a
  model has no MLX build.
- **Writing Tools, Translation, embeddings** — nothing new to adopt.
- **SwiftUI document protocols** — Shepherd has no document model.

## 3. Sequence

```
§1 toolchain (needs: Xcode 27 on the runner, or the hosted image)   one commit
 ├─ A local model            ADR 0031                                ~2 weeks
 ├─ B image input            ADR 0020 amendment                      ~1 week, parallel to A
 ├─ C dynamic profile        ADR 0024 amendment                      ~3 days, after A
 ├─ D donations              ADR 0021 amendment                      ~1 week, after GM verification
 └─ E Anthropic package      when 1.0                                ~1 week
```

## 4. Risks

- **Betas move.** `reasoningLevel` names, the error type and the donations API differed between
  sources. Every item re-verifies its API before code is written, and the research notes record the
  correction — done once on 2026-09-06 for items A and §1 (see *Corrections* above), and to be done
  once more against the GM SDK, which had not shipped on that date. Item D's donations API is still
  unverified.
- **A brought model is a bigger attack surface for prompt injection** than Apple's tuned model:
  agent-written descriptions are third-party text. The rules that already hold — no path from
  generated text to the outbox, tools read-only, hop cap — are what contain it, and they are tested
  once per model in the eval set.
- **Disk and memory.** A 4-bit coder model is roughly 4 GB at the small end and 18–20 GB at the
  large one, and the 80B MoE build wants ~42 GB of RAM (§0, sizes to verify on device). It needs a
  Mac with headroom. The
  picker says so before the download; a model that fails to load falls back to the system model
  with one line in Settings, never silently.
- **Two GitHub Actions bills or one Mac to update.** §1's choice is the owner's.
