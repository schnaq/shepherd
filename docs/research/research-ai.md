# On-device AI for a PR-review desktop app — research (Aug 2026)

Scope: file ranking/grouping by review importance, diff summarization, and drafting
commit/review messages, for an **open-source desktop app that reviews AI-agent-generated
GitHub PRs**. Comparing Apple Foundation Models (native Swift) vs. embedded local models
(MLX/llama.cpp/Ollama) vs. BYOK cloud (Anthropic Haiku 4.5).

---

## 1. Apple Foundation Models framework

### What it is / when it shipped
- Announced WWDC25 (June 2025) as a public API to Apple Intelligence's on-device LLM.
  Substantially reworked at **WWDC26** (June 2026) — the version relevant "as of today"
  (Aug 2026).
- **OS/tooling requirement:** macOS 26 "Tahoe" + Xcode 26 (initial release); the newest
  APIs below (context-size introspection, image input, `LanguageModel` protocol,
  Private Cloud Compute) need **macOS 26.4+**. Apple Silicon only — Apple Intelligence
  is not available on Intel Macs, and only newer iPhone/iPad hardware qualifies on those
  platforms.

### On-device model
- ~**3B parameters**, 2-bit quantized, tuned for short, focused tasks (summarization,
  extraction, classification, tagging, dialog) rather than open-ended generation.
- **Context window — the headline risk for this project:**
  | Era | Combined input+output budget |
  |---|---|
  | 2025 (initial release) | **4,096 tokens** (~3,000 words) — hard ceiling shared across instructions + prompt + response for the whole session |
  | 2026 update (WWDC26, macOS 26.4+) | **8,192 tokens** — doubled, plus a new `model.contextSize` / `tokenCount(for:)` API to check usage before you blow the budget |
  | New: Private Cloud Compute (macOS 26.4+) | **32,000 tokens**, plus a `reasoningLevel` (`.light`/`.moderate`/`.deep`) — bigger model, but it's a **network call to Apple's servers**, not local inference, even though Apple markets it with the same privacy guarantees as on-device |

  Even 32K is modest against real PR diffs: a moderately sized AI-agent-generated PR
  touching 10-20 files easily runs 20K-100K+ tokens of raw diff. **Neither on-device
  tier fits a whole-PR diff in one shot**; only careful chunking (per-file or per-hunk)
  makes the on-device tiers usable at all, and PCC still caps out well below what a
  large PR needs for single-pass summarization.

### Structured output, tool calling, availability
- **Guided generation:** annotate a Swift struct/enum with `@Generable` and the model is
  constrained (constrained decoding) to emit that exact shape — no manual JSON parsing,
  no malformed-output handling. This is genuinely strong for a "rank/group files" style
  output if you can fit the input.
- **Tool calling:** conform to a simple `Tool` protocol; the framework handles
  parallel/serial call graphs automatically.
- **Availability check:** `SystemLanguageModel.default.availability` /
  `.isAvailable` returns `.available` or `.unavailable(reason)` where reason is
  `.appleIntelligenceNotEnabled`, `.deviceNotEligible`, or `.modelNotReady` — lets an
  app degrade gracefully per-user rather than at compile time.
- **No metered rate limits** (it's on-device compute, not a hosted API), but you do get
  hard errors for `context window exceeded` and `guardrail violation` — the safety
  guardrails are known to over-fire on some legitimate technical content and were
  explicitly called out as "refined to reduce false positives" in the WWDC26 update.

### Code / diff handling — the critical caveat
- **Apple explicitly recommends against using the on-device model for code generation,
  math, or factual Q&A.** It's positioned for lightweight natural-language tasks
  (tagging, short summarization, routing), not for reasoning over source code or diffs.
  Developer write-ups from 2025 ("WWDC 2025: Apple's On-Device Foundation Model Is
  Here.. But Is It Any Good?") echo this: quality on technical/code content is
  inconsistent, and the 4K (now 8K) ceiling was the most common developer complaint.
- This is a direct hit against use case (b) diff summarization and, more mildly,
  against (c) drafting commit/review messages that need to reference code specifics.

### 2026 changes that materially change the calculus
This is the most important finding of this research and should drive the architecture:
- **Framework is being open-sourced** (announced WWDC26, rolling out through 2026),
  explicitly to make it usable "everywhere Swift runs, including Linux servers." An
  `fm` CLI (macOS 27) and a **Python SDK** (`apple-fm-sdk` / `apple-fm-cli` on PyPI,
  requires an Apple Silicon Mac + Xcode) also shipped.
- **New `LanguageModel` protocol** — a swappable-backend abstraction Apple itself now
  ships. Conforming implementations announced/available:
  - `SystemLanguageModel` (on-device, 8K)
  - `PrivateCloudComputeLanguageModel` (32K, cloud, reasoning levels)
  - `CoreAILanguageModel` (bring-your-own model, point it at your own weights)
  - `MLXLanguageModel` (pass a Hugging Face model id, framework handles MLX loading —
    open-weight models like Qwen2.5-Coder become a one-line swap)
  - Community packages, and **Anthropic and Google are shipping native Swift packages
    conforming to the same protocol** — meaning `claude-haiku-4-5` could sit behind the
    exact same `LanguageModelSession` call sites as the on-device model, with the
    provider chosen by a Swift Package Manager dependency swap rather than an app-level
    rewrite.
- Also new: image/vision input on-device, `BarcodeReaderTool`/`OCRTool`/Spotlight-RAG
  system tools, an Evaluations framework, and per-response `usage` token accounting.

**Net effect:** the "4096 tokens is a dealbreaker" verdict that was true in 2025 is now
better framed as "the on-device tier alone is a dealbreaker for whole-diff
summarization, but Apple has since built the exact provider-abstraction this project
would otherwise have to invent itself" — which changes the recommended architecture
(§4) more than it changes the viability of on-device-only.

---

## 2. Alternatives: embedded local models

| Runtime | Platform | Swift integration | Notes |
|---|---|---|---|
| **MLX (mlx-swift / mlx-swift-lm)** | **Apple Silicon macOS only** (M1+, unified memory) | Native Swift bindings, no Python needed at runtime | Fastest/most idiomatic on Mac; zero-copy unified memory; now also reachable through Apple's own `MLXLanguageModel` (§1) |
| **llama.cpp** | Cross-platform (macOS/Windows/Linux), CPU + Metal/CUDA/Vulkan | Community Swift wrappers exist (`llama-cpp-swift`, `LocalLLMClient`) wrapping the C/C++ core | The only path here that's genuinely cross-platform; GGUF quantized models widely available |
| **Ollama** | Cross-platform, runs as a separate local daemon/app | Talk to it over `localhost:11434` HTTP — not embedded, an external dependency the user must install (or you must bundle/manage) | Best developer ergonomics (`ollama pull`), but adds an install-time dependency most "embedded" open-source apps try to avoid; used as one of several optional backends in apps like AnythingLLM rather than a hard requirement |

**AnyLanguageModel** (huggingface/AnyLanguageModel, Apache 2.0, ~900 stars) is worth
flagging separately: a drop-in Swift replacement for Apple's own Foundation Models API
that additionally backs onto Core ML, MLX, llama.cpp (GGUF), Ollama, OpenAI, Anthropic,
and Gemini behind one `import` swap. It's Apple/Swift-ecosystem-scoped (not a solution
for a non-Swift cross-platform app), community-maintained rather than 1.0-stable, but is
effectively a pre-built version of the abstraction layer this project would want if built
in Swift — and now overlaps significantly with Apple's own `LanguageModel` protocol.

### Small code-capable models (candidates if embedding your own weights)
| Model | License | Context | Quantized footprint (GGUF) |
|---|---|---|---|
| Qwen2.5-Coder-1.5B-Instruct | Apache 2.0 | 32K | Q4_K_M ≈ 1.2 GB, Q8_0 ≈ 2.0 GB |
| Qwen2.5-Coder-3B-Instruct | Apache 2.0 | 32K | Q4 ≈ 2.7 GB, FP16 ≈ 7.4 GB |
| Gemma (current gen, "Gemma 4") | Apache 2.0 (earlier Gemma 3 used a restrictive custom ToU capping commercial use above 1B MAU — now relaxed) | varies | — |
| Phi-4-mini | MIT | 128K | ~3.8B params |

All four are redistribution-safe for an OSS project. Practical cost of embedding any of
them yourself (vs. using Apple's or Anthropic's hosted paths): a bundled llama.cpp/MLX
runtime (tens of MB) **plus** a 1-7 GB model download that you can't reasonably ship
inside a normal installer — it has to be a first-run/on-demand download — plus 2-4+ GB
of RAM headroom while resident, plus you own prompt templates, quantization tuning, and
model updates yourself indefinitely. Qwen2.5-Coder's native 32K context is a real
advantage over on-device Foundation Models' 8K, but it doesn't remove the need for
chunking on large multi-file diffs either.

---

## 3. Cloud fallback: Anthropic API BYOK

- **Claude Haiku 4.5** (`claude-haiku-4-5`): **200K token context window**, $1/$5 per
  MTok input/output. This comfortably fits a full PR diff (even large ones) in a single
  request without chunking — the one option in this comparison that doesn't fight the
  context-window problem at all.
- **BYOK pattern in open-source desktop tools** is well-established (Warp, Raycast,
  JetBrains AI Assistant, Zed, Continue.dev, and Rust-based OSS tools like
  `kuse_cowork`): user pastes their own API key in Settings; the app talks directly to
  `api.anthropic.com` (no proxy, no app-vendor billing); the key is stored in the OS's
  native credential store — **macOS Keychain, Windows Credential Manager/DPAPI, Linux
  Secret Service** — never in a plaintext prefs/JSON file. Cross-platform libraries exist
  for this (`keyring-rs`, `cross-keychain`; Electron ships `safeStorage` for the same
  purpose). This is the pattern to copy.
- If the app is built in Swift, Apple's new `LanguageModel` protocol (§1) means an
  Anthropic-conforming Swift package could genuinely be swapped in behind the same
  session/call code used for the on-device model — reducing the BYOK integration to
  "another provider conforming to the same interface" rather than a parallel code path.

---

## 4. Verdict and recommended architecture

**Is Foundation Models alone sufficient for "rank/group files by review priority +
summarize diffs"? No — for two independent reasons:**
1. **Context window.** Even the 2026-upgraded 8K on-device / 32K PCC ceilings don't fit
   a full PR diff in one call for anything beyond a small PR; you're forced into
   per-file or per-hunk chunking + map-reduce summarization regardless of which tier you
   use, and Apple's own guidance is silent on how well the model holds up doing that
   repeatedly.
2. **Task fit.** Apple explicitly steers developers away from code generation / code
   reasoning on the on-device model — the exact category diff summarization and
   commit-message drafting fall into. Real-world developer reports from the 2025 launch
   echo mixed quality on technical content.

It's also an ecosystem bet: Apple Silicon macOS 26+ only, which is a hard platform
restriction for an "open-source desktop app" unless the project is deliberately
macOS-only.

**File ranking/grouping doesn't need an LLM at all.** Treat that as a rules/heuristics
engine — path patterns (`test/`, `vendor/`, generated/lockfiles vs. core `src/`),
diff size, churn, CODEOWNERS, file-type risk weighting — computed instantly, with zero
tokens spent and zero dependency on any AI backend being available. Reserve the LLM
budget entirely for (b) and (c), where nuance actually pays off.

**Recommended architecture — a provider abstraction with three tiers, not a single
choice** (this mirrors the shape Apple itself just standardized on with `LanguageModel`,
so if the app is Swift-native this can literally be built on Apple's own protocol):

1. **Foundation Models (on-device)** — default when available (`SystemLanguageModel`
   `.available`, Apple Silicon Mac, macOS 26+): free, private, offline, zero setup.
   Use it for small, bounded jobs that fit comfortably under the 8K ceiling — single-file
   or single-hunk summaries, short commit-message drafts — with `@Generable` for
   structured output and `tokenCount(for:)` checked before every call so you fail over
   cleanly instead of hitting `context window exceeded`.
2. **BYOK cloud (Claude Haiku 4.5, 200K context)** — the tier that actually handles
   whole-PR synthesis: cross-file summaries, full review-message drafting, anything that
   doesn't fit tier 1's budget or where quality matters more than being free. Store the
   key in the OS keychain, call the API directly from the client, no app-vendor proxy.
   This is also the tier that gives Windows/Linux users AI features at all, since tier 1
   doesn't exist for them.
3. **None** — the app must be fully usable with no AI configured at all (this is
   effectively free given tier 0's heuristic ranking already works without any model).

**Skip embedding your own MLX/llama.cpp model and weights** unless offline capability on
non-Apple-Silicon hardware is a hard product requirement. It adds a genuinely large
maintenance surface — multi-GB on-demand downloads, per-model prompt templates,
quantization/RAM tuning, your own update channel — for coverage that tiers 1+2 already
give you with far less engineering: Foundation Models covers the "free, private,
offline, Apple Silicon" case, and Haiku 4.5 BYOK covers "large diff, best quality,
any platform" case. If cross-platform offline ever becomes a real requirement, GGUF
Qwen2.5-Coder-3B via llama.cpp (Apache 2.0, 32K context) is the strongest candidate
model to add as a fourth tier, precisely because its native context window is 4x the
on-device Foundation Models ceiling.

---

## Sources

- [FoundationModel, context length](https://developer.apple.com/forums/thread/806542)
- [Tracking token usage in Foundation Models](https://artemnovichkov.com/blog/tracking-token-usage-in-foundation-models)
- [What's new in the Foundation Models framework — WWDC26](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Apple introduces Foundation Models framework to run a 3B model](https://medium.com/just-ai-things/apple-introduces-foundation-models-framework-to-let-you-run-a-3b-model-on-your-phone-89194d00cc18)
- [Meet the Foundation Models framework — WWDC25](https://developer.apple.com/videos/play/wwdc2025/286/)
- [Abilities & Limitations of Apple Foundation Models](https://www.kodeco.com/ios/paths/new-ios26/48744203-apple-foundation-models/02-using-apple-foundation-models/02)
- [Introduction to Apple's FoundationModels: Limitations, Capabilities](https://www.natashatherobot.com/p/apple-foundation-models)
- [WWDC 2025: Apple's On-Device Foundation Model Is Here.. But Is It Any Good?](https://ronnierocha.dev/blog/wwdc-2025-apples-on-device-foundation-model-is-here-but-is-it-any-good/)
- [Apple Open-Sources Its Foundation Models Framework, Adds Claude and Gemini](https://rits.shanghai.nyu.edu/ai/apple-open-sources-its-foundation-models-framework-adds-claude-and-gemini/)
- [Build AI-powered scripts with the fm CLI and Python SDK — WWDC26](https://developer.apple.com/videos/play/wwdc2026/334/)
- [GitHub - apple/python-apple-fm-sdk](https://github.com/apple/python-apple-fm-sdk)
- [Bring an LLM provider to the Foundation Models framework — WWDC26](https://developer.apple.com/videos/play/wwdc2026/339/)
- [WWDC 2026 - Apple's new server LLM on Private Cloud Compute](https://dev.to/arshtechpro/wwdc-2026-apples-new-server-llm-on-private-cloud-compute-whats-in-it-for-developers-2edd)
- [WWDC 2026 - Apple Just Opened the Foundation Models Framework to Any LLM Provider](https://dev.to/arshtechpro/wwdc-2026-apple-just-opened-the-foundation-models-framework-to-any-llm-provider-5ejn)
- [Apple's LanguageModel Protocol Lets iOS Apps Swap Between Claude, Gemini](https://pulse.adyog.com/insights/apple-languagemodel-protocol-claude-gemini-swap)
- [GitHub - huggingface/AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)
- [Introducing AnyLanguageModel: One API for Local and Remote LLMs](https://huggingface.co/blog/anylanguagemodel)
- [Choosing an On-Device LLM Runtime on Apple Silicon](https://medium.com/@michael.hannecke/choosing-an-on-device-llm-runtime-on-apple-silicon-a-decision-framework-beyond-benchmarks-2449067b8b67)
- [GitHub - srgtuszy/llama-cpp-swift](https://github.com/srgtuszy/llama-cpp-swift)
- [MLX vs llama.cpp on Apple Silicon](https://groundy.com/articles/mlx-vs-llamacpp-on-apple-silicon-which-runtime-to-use-for-local-llm-inference/)
- [Qwen2.5-Coder Series: Powerful, Diverse, Practical](https://qwenlm.github.io/blog/qwen2.5-coder-family/)
- [Qwen 2.5 Coder 1.5B: Lightweight Local Coding Model Review](https://localaimaster.com/models/qwen-2-5-coder-1-5b)
- [Qwen/Qwen2.5-Coder-3B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF)
- [Qwen/Qwen2.5-Coder-32B-Instruct LICENSE](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct/blob/main/LICENSE)
- [What Is the Gemma 4 Apache 2.0 License?](https://www.mindstudio.ai/blog/what-is-gemma-4-apache-2-license-commercial-ai-deployment)
- [Phi-4 Mini vs Gemma 3 vs Llama 3.2](https://tech-insider.org/phi-4-mini-vs-gemma-3-vs-llama-3-2-2026/)
- [GitHub - kuse-ai/kuse_cowork](https://github.com/kuse-ai/kuse_cowork)
- [Bring Your Own Key (BYOK) Is Now Live in JetBrains IDEs](https://blog.jetbrains.com/ai/2025/12/bring-your-own-key-byok-is-now-live-in-jetbrains-ides/)
- [Electron safeStorage](https://www.electronjs.org/docs/latest/api/safe-storage)
- [GitHub - open-source-cooperative/keyring-rs](https://github.com/open-source-cooperative/keyring-rs)
- Anthropic model reference (claude-api skill, cached 2026-06-24): Claude Haiku 4.5 (`claude-haiku-4-5`) — 200K context, $1.00/$5.00 per MTok input/output.
