# macOS 27 — raising the target, and what it buys a review tool

Status: plan · Date: 2026-09-03 · Owner decision: Shepherd targets macOS 27 as soon as the build
can be verified against the macOS 27 SDK.

This plan grounds that decision in what was verified against Apple's documentation and the WWDC26
sessions on 2026-09-03 (see `docs/research/research-ai.md` for the corrections it caused, and
[ADR 0025](../adr/0025-private-cloud-compute.md) for the one thing macOS 27 does *not* unlock). It
says what changes in the toolchain, which new capabilities Shepherd adopts in which order, and
which it declines — with the ADR each item needs. Everything here obeys
[ADR 0007](../adr/0007-layered-intelligence.md): heuristics first, on-device second, a configured
endpoint only on a click, unattended work never leaves the Mac.

## 0. What was verified, and what was not

| Claim | State on 2026-09-03 |
|---|---|
| macOS 27 release | Announced at WWDC26; public release expected mid/late September 2026. No Apple press release with a date yet. |
| Xcode 27 | Beta 6 (27A5252f, Swift 6.4). **No release candidate yet.** Host requirement **macOS 26.4+**, Apple Silicon only — a build Mac does not need macOS 27 itself. |
| GitHub-hosted runners | A separate `xcode-27` image is in public preview (arm64). The `macos-26` images carry Xcode 26. |
| `LanguageModel` protocol, `LanguageModelExecutor`, `PrivateCloudComputeLanguageModel`, `CoreAILanguageModel`, `MLXLanguageModel` | Real, all **macOS 27.0+**. `LanguageModelSession(model:)` is the one-line swap. |
| On-device context | **Still 8,192 tokens** on `SystemLanguageModel`. Only Private Cloud Compute (32K) or a model you bring raises it. |
| Image input | `Attachment(NSImage/CGImage)` inside `session.respond { }`. Two Vision-backed tools, `OCRTool` and `BarcodeReaderTool`, ship with the framework. |
| `Transcript` | Gains `DynamicProfile`: swap model, tools and instructions mid-session while keeping the history. |
| Errors | A new executor-facing `LanguageModelError` (`contextSizeExceeded`, `rateLimited`, `refusal`, `guardrailViolation`, `unsupportedCapability`, `unsupportedTranscriptContent`, `timeout`). **Re-verify** against the GM SDK whether it supersedes `LanguageModelSession.GenerationError`, which `OnDeviceProvider` maps today. |
| `reasoningLevel` names | `.light` / `.medium` (or `.moderate` — sources disagree between betas) / `.deep`. Re-verify on GM. |
| Private Cloud Compute entitlement | Still App Store Small Business Program, App Store distribution. **Unchanged; ADR 0025 stays parked** with one of three conditions met. |
| `MLXLanguageModel` | Loads Hugging Face weights by id (`MLXLanguageModel(modelID:)`, a `#huggingFaceLanguageModel` macro). Tool calling, `@Generable` and streaming work through the same session. Documented example: Qwen 3 6B 4-bit. **Unverified:** coder-model list, RAM and disk needs, download location, licence of the loader. |
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
- `OnDeviceProvider`'s error mapping is re-read against the GM SDK (`GenerationError` vs
  `LanguageModelError`) before the commit lands; the `IntelligenceError` cases the app shows do
  not change.
- `README.md`, `docs/ARCHITECTURE.md` and `CONTRIBUTING.md` say macOS 27 where they say 26.

**The blocker is CI, not code.** The self-hosted runner builds with the macOS 26.5 SDK today.
Two ways out, and the owner chooses:

1. **Install Xcode 27 (beta, later RC) on the runner Mac.** Its host requirement is macOS 26.4+,
   so the Mac itself need not move to 27. Needs someone at the machine once. Free.
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
  protocol. `preflight` measures against the chosen model's `contextSize`; the 8K constant becomes
  the system model's value, not the app's.
- **Choosing:** a picker in Settings → Intelligence with two entries: *Apple's model (built in)*
  and *A model from Hugging Face*, the latter with an id field, a curated list of three or four
  known-good instruct models (coder-tuned where one is verified to work), the download size, and a
  one-line memory note. Download is explicit — a button, a progress line, a cancel — never on
  launch, never in a sweep.
- **Host list:** `huggingface.co` (and the CDN it redirects to) joins `CONTRIBUTING.md`, with the
  sentence that says what travels there: the model id, nothing about the user or any pull request.
  This is a **download** host, not a request host, and the contract says so.
- **Guardrails:** Apple's guardrails are a property of the system model. A model you bring has
  the framework's guardrail layer where Apple applies it and otherwise its own training. The
  Settings copy says that in one sentence, and the served-by line names the model. Unattended
  surfaces (triage, digests, the Siri summary) use the brought model only when a second toggle
  says so — a 6B model on battery is a cost the reviewer opts into, not a default.
- **Budget:** `IntelligenceDiffWindow` and `LogDigest` take the measured context as a parameter
  today; they get wider windows for free. The eval fixtures (plan v2 §0.4) run once per model so a
  regression on the brought model is visible.
- **Effort:** L. Depends on §1 and on verifying RAM/disk needs and the loader's licence.

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

- **Betas move.** `reasoningLevel` names, the error type and the donations API differ between
  sources. Every item re-verifies its API against the GM SDK before code is written, and the
  research notes record the correction.
- **A brought model is a bigger attack surface for prompt injection** than Apple's tuned model:
  agent-written descriptions are third-party text. The rules that already hold — no path from
  generated text to the outbox, tools read-only, hop cap — are what contain it, and they are tested
  once per model in the eval set.
- **Disk and memory.** A 4-bit 6B model is several gigabytes and needs a Mac with headroom. The
  picker says so before the download; a model that fails to load falls back to the system model
  with one line in Settings, never silently.
- **Two GitHub Actions bills or one Mac to update.** §1's choice is the owner's.
