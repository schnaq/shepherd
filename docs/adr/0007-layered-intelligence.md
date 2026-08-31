# ADR 0007: Layered intelligence — heuristics always, on-device when available, BYOK cloud optional

Status: Accepted · Date: 2026-08-31

## Context

Findings ([research](../research/research-ai.md)): Apple's on-device Foundation Model
(~3B params, 8,192-token context since WWDC26) is good at short summarization/tagging but
explicitly not recommended for code reasoning, and even the 32K Private Cloud Compute tier
cannot fit large multi-file diffs. Claude Haiku (200K context, BYOK) fits whole PRs. File
prioritization does not need an LLM at all — deterministic signals (path patterns, churn,
lockfile/generated-file detection, test-to-source ratio) are free, instant, and predictable.
Apple's new `LanguageModel` protocol allows swappable backends, including Anthropic's Swift
package, behind identical call sites.

## Decision

Three tiers, strictly layered; each tier degrades gracefully to the one below:

1. **Heuristics (always on, no AI):** file grouping & review-priority ranking, agent
   detection, risk hints (e.g. "touches auth code", "deletes tests"). Pure functions in
   `ShepherdCore`, unit-tested, deterministic.
2. **On-device (Foundation Models, when available):** short PR summaries, comment-tone
   assistance, labeling — bounded prompts that fit 8K tokens; diff content is pre-digested by
   tier 1 (per-file stats, top hunks) rather than fed raw.
3. **BYOK cloud (optional):** user-supplied Anthropic API key (Keychain-stored) unlocks
   whole-PR analysis and deeper review assistance via `claude-haiku-4-5`. Requests go directly
   from the app to the API — no proxy, no middleman.

A single `IntelligenceProvider` protocol abstracts tiers 2–3; the UI treats AI output as
*hints* (never auto-submits reviews). The app is fully functional with tiers 2–3 unavailable.

## Consequences

- No feature may hard-depend on an LLM; every AI surface needs a heuristic-only fallback state.
- We do not embed our own weights (MLX/llama.cpp) in v1 — tiers 1–3 cover the need with far
  less engineering; revisit only if offline non-Apple-Intelligence demand materializes.
- Prompting code must budget tokens explicitly (tier 2's 8K ceiling is a hard error, not a
  truncation).
