# ADR 0031: A model you bring — `MLXLanguageModel` as the second on-device tier

Status: Proposed · Date: 2026-09-06 · Amended 2026-09-22: **§One is built**, with Claude as its
first second backend rather than MLX — see the amendment at the end.

**Proposed, not Accepted, and the reason is mechanical rather than a hesitation about the
decision.** Nothing here can be compiled: `FoundationModels.LanguageModel` is macOS 27.0+, the
macOS 27 SDK is not on the CI runner, and an `#available` check cannot hide a type the compiler has
never seen ([`docs/plans/macos-27.md`](../plans/macos-27.md) §1). The owner decided on 2026-09-06
to assume macOS 27 as the target in every decision until the SDK arrives, and the toolchain commit
is written and rebased onto `main` waiting for the runner. **This ADR becomes Accepted the day that
commit lands**, unchanged if the first build against the GM SDK agrees with what §0 of the plan
records, and amended in the same commit if it does not.

## Context

The 8,192-token ceiling on `SystemLanguageModel` is the one constraint that has shaped every
on-device feature Shepherd has: windowed diffs rather than whole ones, a pre-digested file list
rather than a patch, one claim pass per description, a log reduced on this Mac before a model sees
it, and a hard error rather than a truncation whenever the budget is missed
([ADR 0007](0007-layered-intelligence.md), and its measured-budget amendment). Tier 3 answers the
large-diff case, but only for a reviewer who brings an API key and accepts that their code reaches
an endpoint — which is exactly the trade ADR 0007 makes the user opt into, click by click, and
exactly the trade a great many reviewers will not make.

[ADR 0025](0025-private-cloud-compute.md) was the intended answer and is parked: Apple's no-cost
Private Cloud Compute entitlement is tied to App Store distribution, and Shepherd ships
Developer-ID-signed outside the store ([ADR 0010](0010-distribution-dmg-homebrew.md)). Two of that
ADR's three unparking conditions are still unmet and one of them — the entitlement — is not
Shepherd's to move.

macOS 27 offers a different answer to the same question. `LanguageModelSession` no longer takes
*the* model; it takes *a* model, any conformer of the new `LanguageModel` protocol, and the session,
tool, `@Generable` and streaming code above it does not change. A reviewer with an Apple Silicon
Mac and the disk for it can therefore run a large open-weight coder model, with a context measured
in tens of thousands of tokens, **with nothing leaving the Mac at all** — the capability PCC would
have given, without the entitlement and without the network.

**One correction shapes everything below, and it arrived late.** The plan recorded
`MLXLanguageModel` as an SDK type alongside `PrivateCloudComputeLanguageModel` and
`CoreAILanguageModel`. It is not. Verified on 2026-09-06 against the `ml-explore/mlx-swift-lm`
sources on `main` (see [`docs/research/research-ai.md`](../research/research-ai.md), corrections of
that date): `MLXLanguageModel` ships in that open-source package, in the module
`MLXFoundationModels`, and *conforms to* `FoundationModels.LanguageModel`, which is the part Apple
ships. Adopting it is therefore not "switch on a type that is already in the SDK". It is a
**third-party dependency decision**, and that is why this is an ADR of its own rather than an
amendment to ADR 0007.

## Decision

Build it, in the seven parts below. It stays **tier 2** throughout: the model runs on this Mac, so
ADR 0007's rule that unattended work never leaves the Mac is satisfied by construction, which is
the whole difference between this rung and every cloud rung Shepherd has.

### One: the seam is `any LanguageModel`, and 8,192 stops being the app's number

`OnDeviceProvider` takes `any LanguageModel` where it takes `SystemLanguageModel` today. Everything
above the seam — the session, the three read-only tools of [ADR 0024](0024-tool-calling-ci-diagnosis.md),
guided generation, the streamed cumulative drafts of ADR 0007's streaming amendment — is unchanged,
because a protocol whose whole purpose is a swappable backend is worth adopting exactly to the
extent that nothing above it has to know which backend answered.

The one number that moves is the budget. `preflight` measures against **the chosen model's**
`contextSize` rather than against a constant, and the app stops owning the figure 8,192 at all: it
becomes the system model's value, one of several, read from whichever model the session was built
on. `TokenBudget.limited(toContextSize:reservedForResponse:)` already takes the context size as a
parameter and `IntelligenceDiffWindow` and `LogDigest` already take the measured budget as one, so
the wider window costs no new arithmetic — the windows simply get bigger, and the pre-flight stays
the hard error ADR 0007 makes it rather than becoming a truncation because there is more room.

### Two: it is a third-party SPM dependency — the first outside Apple's frameworks besides GRDB and Sparkle

`ml-explore/mlx-swift-lm` (MIT) is added to `project.yml` as a package dependency of the app target.
It pulls `ml-explore/mlx-swift` (MIT) and `swiftlang/swift-syntax` (Apache-2.0, a compile-time macro
dependency only). No Hugging Face Swift package is in that graph: the `HuggingFace` and `Tokenizers`
modules are internal targets of `mlx-swift-lm` itself.

Shepherd links three things it does not write today — GRDB, Sparkle and Monaco — and this is the
fourth, so the dependency policy that [ADR 0009](0009-mit-license.md) and `NOTICES.md` already
express applies without needing a new one, plus three rules this dependency specifically earns:

- **An exact tag, never a range.** A model runtime changes generation behaviour between releases in
  ways a compiler cannot see, so the pin is exact and a bump is a reviewed change with the eval
  fixtures re-run behind it, not a lockfile update.
- **A line in `NOTICES.md` per component, in the same commit.** Three of them: `mlx-swift-lm`,
  `mlx-swift`, `swift-syntax`. `swift-syntax` is Apache-2.0 rather than MIT and reaches the user's
  Mac only as a compile-time macro implementation, which is the same category as the build-time
  tools that file deliberately excludes — so it is listed with that stated, rather than silently
  omitted or silently treated as shipped code.
- **It cannot break the builds that do not have the 27 SDK.** The package gates its Foundation
  Models integration on `#if canImport(FoundationModels, _version: 2)` and on a SwiftPM trait,
  `FoundationModelsIntegration`, which is on by default; below the 27 SDK the module compiles
  empty. The Linux and macOS-26 CI jobs build `Packages/ShepherdKit`, which does not depend on it at
  all, and the app target is the only thing that links it — so this dependency is incapable of
  breaking the two jobs that guarantee ShepherdKit stays headless.

### Three: the download is a user action, and the weights live in Shepherd's own container

**Never on launch, never in a sweep, never as a side effect of opening Settings.** A button, the
size in gigabytes beside it before it is pressed, a progress line while it runs, and a cancel that
actually cancels. This is the same rule ADR 0007 makes for every tier-3 request and
[ADR 0027](0027-track-record-and-trust-lanes.md) makes for the history backfill, and it is here for
the same reason: multi-gigabyte network traffic nobody asked for is not made acceptable by being
useful afterwards.

**The weights go into Shepherd's own Application Support container**, through the direct
initialiser's `weightsLocation:` closure. The package's default resolution goes through an internal
`HubCache` following the Hugging Face convention, which is a shared cache in the user's home
directory and **not** an app-container path; Shepherd does not accept that default. Files this size
belong where the app's other files are — where "delete Shepherd's data" reaches them, where the
Settings row can report their size honestly, and where a second app's cache eviction cannot delete
the model a reviewer is mid-session with.

**The host list gains a pair.** Downloads begin at `huggingface.co` and redirect to CDN hosts under
`hf.co`; Hugging Face's own allowlisting guidance names those two suffixes, so those two suffixes
are what joins `CONTRIBUTING.md`'s list — with the sentence that says what travels there: **what
travels there is the model id and nothing about the user or any pull request.** It is a *download*
host, in the same category as the Sparkle update download and the `*.githubusercontent.com` blob
host, and not a request host: no prompt, no diff, no pull request and no review text is ever sent
to it, and there is no code path that could send one, because the only thing on that side of the
seam is a file transfer.

### Four: capabilities are declared per model, so the picker has to say what each model can do

This is the part of the package's design that most changes the feature, and it was not in the plan
at all. `MLXLanguageModel`'s capabilities — `.guidedGeneration` (xgrammar-constrained `@Generable`),
`.toolCalling`, `.reasoning`, `.vision` — are **declared at construction and never inferred**, and a
request beyond what was declared throws `LanguageModelError.unsupportedCapability`. There is no
probing and no graceful degradation to discover: a session either was built with the capability or
the call fails.

Shepherd needs two of them for the surfaces this tier is for — `.guidedGeneration` for the triage
verdict ([ADR 0023](0023-structured-triage.md)) and the claims pass
([ADR 0026](0026-claims-vs-evidence.md)), `.toolCalling` for the CI diagnosis (ADR 0024) — so a
model in the list that cannot honestly do both is a model whose entry has to say which surfaces it
will not answer, rather than one that fails at the moment a reviewer presses a button.

That is why the list is **curated** rather than an id field with a download button. Each entry
carries its declared capabilities, its download size, a memory note, its context length and its
licence, and the picker shows all of that **before** the download rather than after it. The id field
stays, for the reviewer who knows what they want (part six says what they see when they use it), but
it is the escape hatch and not the path.

**A model that fails to load falls back to the system model, with one line in Settings, never
silently.** A brought model that cannot be loaded — missing files, not enough memory, a build the
adapter does not understand — leaves the reviewer on Apple's model with a sentence saying so, and
the served-by line every AI surface already carries (ADR 0007's served-by amendment) names which
model actually answered. A tier that quietly demotes itself is worse than one that fails, because
the reviewer keeps reading answers and attributing them to a model that never ran.

### Five: a brought model has no guardrails, and the app says so out loud

Apple's guardrails are a property of Apple's model. Apple's own guidance is explicit — *"Guardrails
are a safety system tied to a specific model… For any foundation model you use, consider… Does the
model have a guardrail system?"* — and there is no guardrail code in the MLX adapter. **A Hugging
Face model runs with no content filter unless the app adds one.** The plan hedged this ("the
framework's guardrail layer where Apple applies it and otherwise its own training"); the hedge was
wrong and this replaces it.

Shepherd does not add one, and states the absence rather than implying a protection it does not
provide. Two things make that acceptable, and both are already in force:

- **The containment is structural and predates this ADR.** Nothing the model writes can act. There
  is no code path from generated text to `submitReview`, to the outbox or to a saved draft comment
  (ADR 0007's drafting amendment); the tools are three compile-time read cases with a hop cap of
  six and a path check that refuses a file the pull request did not change (ADR 0024); rules
  engines do not read model output. A model with worse judgement than Apple's therefore has the
  same *reach* as Apple's, which is none — it can produce a worse sentence in a field a human is
  reading, and nothing else. That is the guarantee that matters when the input is agent-written
  prose from a third party, which is what a pull request description is.
- **The unattended surfaces need a second toggle.** Triage, the morning digest and the Siri summary
  run with nobody watching, and ADR 0007's rule for them is that they stay on-device — which a
  brought model satisfies. But "on-device" was never the only reason those surfaces were safe to
  leave running; "tuned by Apple, with a guardrail system" was part of it. So a brought model
  answers an unattended surface **only behind a second explicit toggle**, off by default, distinct
  from the toggle that chooses the model at all. The attended surfaces need no second toggle: a
  reviewer pressed a button and is reading the result.

**The Settings copy states the absence in one sentence**, beside the model's name, in the same place
the tier-3 copy states that a request leaves the Mac. Not a warning triangle and not a dialog — one
sentence of fact, the way ADR 0025's design states that a PCC request leaves the Mac.

### Six: the curated list is a licence gate

Only weights under **Apache-2.0 or MIT** are listed by default. On 2026-09-06 that is the Qwen
family, in `mlx-community`'s 4-bit builds:

| Model | Params | Context | Licence | Disk | Memory |
|---|---|---|---|---|---|
| Qwen2.5-Coder-7B-Instruct-4bit | 7B dense | 32K | Apache-2.0 | ~4.3 GB | the entry-level choice |
| Qwen2.5-Coder-32B-Instruct-4bit | 32B dense | 128K | Apache-2.0 | ~18–20 GB, **estimated** | a large-memory Mac |
| Qwen3-Coder-Next-4bit | 80B MoE, 3B active | 256K | Apache-2.0 | ~17.5 GB weights | ~42 GB recommended |

Two families are deliberately **not** listed: DeepSeek-Coder-V2-Lite-Instruct-4bit ships under the
custom DeepSeek Model License — commercial use is permitted, but it is not an OSI licence — and the
Gemma 3 builds ship under the Gemma Terms of Use, which carry a prohibited-use policy that flows
down to anyone the weights are passed to and reserve the right to restrict use unilaterally. Neither
is a judgement about the models. It is that a curated entry is Shepherd *recommending* a download,
and recommending one under terms whose obligations flow through to the reviewer is a thing to do
knowingly or not at all.

**A reviewer who types an arbitrary id gets it, and sees the licence they are accepting.** The id
field resolves the model card's licence and prints it, with its name and its link, next to the
download button — so an unlisted model is a choice the reviewer makes with the terms in front of
them rather than a door that is closed. That is the same shape as ADR 0007's "any
OpenAI-compatible endpoint" beside its two presets: a curated path and an open one, with the
difference stated rather than the open one removed.

### Seven: the errors move to `LanguageModelError`, and nothing a reviewer reads changes

Confirmed on 2026-09-06 in Apple's DocC JSON: `LanguageModelSession.GenerationError` is
**deprecated at 27.0** — *"Use `LanguageModelError`, `SystemLanguageModel.Error`, or
`LanguageModelSession.Error` instead… You must update to Xcode 27 to catch the new error types"* —
and `LanguageModelError` carries `.contextSizeExceeded`, `.rateLimited`, `.refusal`, `.timeout`,
`.guardrailViolation`, `.unsupportedCapability`, `.unsupportedTranscriptContent`,
`.unsupportedGenerationGuide` and `.unsupportedLanguageOrLocale`.

`OnDeviceProvider.mapped(_:)` maps the deprecated type today — `.guardrailViolation` to
`IntelligenceError.guardrailDeclined`, `.exceededContextWindowSize` to
`IntelligenceError.contextExceeded`, everything else through untouched — and it moves to the new
type in the toolchain commit, keeping the tool-error unwrap in front of it. **The `IntelligenceError`
cases the app shows do not change**, and neither does the rule that a guardrail refusal is never
retried automatically. Two of the new cases earn a mapping this tier makes reachable for the first
time: `.unsupportedCapability` is a Shepherd bug rather than a user-facing failure if part four is
implemented correctly, so it maps to a sentence naming the model and the surface rather than to a
generic failure; `.refusal` is the brought model's own decline, which is not the same event as
`.guardrailViolation` and should not borrow its sentence.

## Consequences

- **Shepherd's privacy story gains a download host pair and a per-model caveat, and both have to be
  said in the same breath as the feature.** `CONTRIBUTING.md`'s list is a hard line, and this is the
  first addition to it that is not a host the user typed in themselves. The mitigation is that the
  addition is narrow and stated: two suffixes, a file transfer, a model id, and no path from any
  pull-request content to either. The caveat is sharper — for the first time, what a Shepherd
  feature will and will not say depends on weights the project did not choose and cannot audit, and
  the honest form of that is the sentence in part five rather than silence.
- **The eval fixtures run once per model, and "the eval set passes" stops being one sentence.**
  `Tests/Fixtures/eval/` was written against one model whose behaviour Apple controls. It now
  answers a different question per curated entry, and a regression is per-model: a prompt that
  survives Apple's 3B and fails a 32B coder model is a real finding about a real configuration, not
  a flake. Adding a model to the curated list means running them, and that cost is what keeps the
  list at three or four rather than at twenty.
- **Disk and RAM become a Settings concern for the first time.** Shepherd's footprint has been a
  SQLite file and a Monaco bundle. A tier that puts 4 to 20 GB in Application Support needs the
  Settings row to report the size, offer the delete, and say what a delete costs — and needs the
  picker to be honest before the download about a Mac that cannot hold the model, because the
  failure mode of finding out afterwards is a wasted 18 GB download on a metered connection.
- **The first non-Apple runtime dependency in the intelligence layer, and the one place the layer's
  behaviour is not the project's to fix.** GRDB and Sparkle are dependencies whose failures are
  reproducible and whose fixes are pull requests. A model runtime's failures include "this build
  generates worse text than that one", which is neither. The exact pin and the per-model eval run
  are the whole of the mitigation, and they are worth stating as a cost rather than presenting as a
  process.

## What this does not settle

**`CoreAILanguageModel`.** The plan declines it for a good reason — bundling weights multiplies the
DMG by the model — but declining "bundle the weights" is not the same as declining "Neural-Engine
execution of weights the app fetched". If a curated model turns out to have no MLX build, or if
Neural-Engine execution proves materially better on battery than MLX's Metal path, that is a
separate decision with the same download machinery underneath it. Nothing here forecloses it.

**Private Cloud Compute.** ADR 0025 stays parked on its own three conditions, and this ADR does not
meet or move any of them. What it does do is make the *rung* less urgent: the reviewer who wanted
32K without a key now has a path to far more than 32K. If the entitlement never opens, that ADR
should be dropped rather than parked again — which is what it already says it will decide when
macOS 27 ships.

**Which models beyond the curated three.** The list is a starting point chosen on one day against
one licence rule and secondary size figures, and the sizes for the 32B build in particular are
estimates that have to be checked on a real download before they are printed in a picker. Whether a
non-coder general model belongs in the list at all, and whether a fourth entry is worth its eval
run, is a question for the first reviewer who uses this on real pull requests.

**The macro versus the direct initialiser.** `#huggingFaceLanguageModel(configuration:capabilities:)`
is the ergonomic entry and wires the Hugging Face download and tokenizer loading for you; the direct
init takes `configuration:`, `capabilities:`, `configurationResolver:`, `weightsLocation:` and
`load:`. This leans **direct init**, and the reason is part three: the macro's convenience is
precisely the default download location, and that default is the one thing this ADR refuses. Taking
the macro and then overriding where the files land would be taking a convenience for its ergonomics
and discarding the only part of it that is not also two lines of our own. But the macro also carries
the tokenizer wiring, and whether reproducing that against the direct init is two lines or two
hundred is not knowable from the sources alone — it is knowable on the first build, and the
toolchain commit's week is when this gets decided rather than guessed.

**Whether an entitlement beyond `com.apple.security.network.client` is needed.** The download needs
the client entitlement Shepherd already has; a resident multi-gigabyte model very likely wants the
increased-memory entitlement as well, and neither that nor the JIT question is verifiable from the
package sources. It is a first-build question, and it is written down here so it is asked rather
than discovered by a crash on a reviewer's Mac.

## Amendment (2026-09-22): the seam is built, and Claude went through it first

The macOS 27 SDK arrived ([ADR 0038](0038-macos-27-floor.md)), and §One is now code:
`OnDeviceProvider` became `SessionProvider<Backend: LanguageModelBackend>`, a struct that drives one
`LanguageModelSession` per request on whichever model its backend hands it. Everything above the
seam is written once — the `@Generable` shapes, the three read-only tools, the streamed cumulative
drafts, the pre-flight — and the backend answers the five questions that differ: which tier, which
digest budget, which model for a use case, why it is unavailable, and how the prompt is measured.
`OnDeviceBackend` is Apple's system model, measured against the real tokenizer;
`OnDeviceProvider` is a typealias and its call sites did not move.

**The first second backend is not MLX.** It is `ClaudeBackend`, on Anthropic's
`ClaudeForFoundationModels` package, and it replaces the hand-written HTTP `AnthropicProvider`
entirely: the tool loop, the SSE decoder and the JSON envelope for drafts are gone, and tier 3 on
Claude now uses guided generation and framework-driven tool calling exactly as tier 2 does. The
reason for the order is ADR 0038's programme, and the reason it fits this ADR is that it is the same
seam — a `LanguageModel` conformer that is not Apple's — with the opposite privacy story: **Claude
is tier 3, not tier 2.** ADR 0007's rules for the cloud rung apply unchanged: the reviewer's own key,
opt-in click by click, the router never *offers* the request to this rung when a colleague's comment
would travel, and the badge says "Anthropic". The seam does not know or care about that; the router
does, keyed off `IntelligenceKind`, which is why the two backends can share every line above it.

What this changes about §Two's dependency rules: they apply now, to a package one generation
earlier than planned. `ClaudeForFoundationModels` 0.2.1 is pinned exactly in `project.yml`, listed
in `NOTICES.md` with its Apache-2.0 notice, linked by the app target only, and a bump is a reviewed
change. The MLX rung (§§Two–Seven) is unchanged as a plan and becomes a third backend when it is
built; the curated-list and download rules there are its own.

Three things measured, not assumed: the package builds against the GA SDK (Xcode 27.0, 5 s);
`AuthMode.apiKey` is the documented mode for a key that is not bundled with the app, and App
Attest, the mode the package recommends for shipped apps, would bill every request to the
developer's workspace, which ADR 0011 and this ADR rule out; and the package refuses redirects that
leave `api.anthropic.com`, so the reviewer's key is sent nowhere else — the promise
`CredentialSafeSession` makes for the requests Shepherd builds itself.

