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
3. **BYOK cloud (optional):** a user-supplied API key (Keychain-stored) unlocks whole-PR
   analysis and deeper review assistance. Two provider shapes, selectable in settings:
   - **Anthropic** (first-class default): `claude-haiku-4-5` via the Anthropic API.
   - **Any OpenAI-compatible endpoint** (custom base URL + key + model name): covers
     EU-hosted/GDPR-focused providers (e.g. konduit.eu, EUrouter, DeutschlandGPT, Infercom)
     as well as local servers like Ollama or LM Studio — relevant for users with data-residency
     requirements who still want cloud-grade context windows.
   Requests go directly from the app to the configured endpoint — no proxy, no middleman.

A single `IntelligenceProvider` protocol abstracts tiers 2–3; the UI treats AI output as
*hints* (never auto-submits reviews). The app is fully functional with tiers 2–3 unavailable.

## Amendment (2026-09-01): endpoint presets and model discovery for tier 3b

Additive, inside the decision above — the tier, the protocol and the privacy line are unchanged,
so this is a note rather than a new ADR.

Typing a base URL from memory was the only way into tier 3b, which made the "any
OpenAI-compatible endpoint" escape hatch harder to use than the Anthropic default it exists to
balance. Two small additions:

- **Endpoint presets** (`IntelligenceEndpointPreset`): `Konduit (EU)`
  (`https://api.konduit.eu/v1`, EU-hosted open models, keys from `console.konduit.eu`),
  `Ollama (local)` (`http://localhost:11434/v1`) and `Custom` (the previous behaviour, a
  free-form URL). A preset only *fills in the base URL* the provider already takes — there is no
  per-provider code path, no per-provider request shape, and the router and connection test are
  untouched. The selected preset is remembered in `UserDefaults` (non-secret, like the base URL
  and the model name); keys stay Keychain-only. Editing the URL by hand re-derives the preset, so
  the picker can never contradict the field.
- **Model discovery**: `GET {base}/models` (`{"data":[{"id":…}]}`) turns the model field into a
  picker. It is best-effort and never required — an endpoint without that route, an error, or an
  empty list all fall back to the free-text field, and a model the endpoint did not list stays
  selectable. Parsing lives in `OpenAIModelsResponse`, a pure type with fixture tests.

Consequence: adding a further preset is a case in one enum plus a line in the roadmap. A preset
must not grow endpoint-specific request behaviour; anything that cannot be expressed as "a base
URL for the OpenAI shape" needs its own provider and its own ADR.

## Amendment (2026-09-01): AI-drafted review text, always as a suggestion

Additive, inside the decision above: the tiers, the provider protocol's place in the design and the
privacy line are unchanged. What is new is *which* work tiers 2–3 are used for — the "deeper review
assistance" the tier-3 bullet already names, and the "comment-tone assistance" the tier-2 bullet
already names, made concrete.

Two surfaces, both in the review composer, both driven by an explicit click on a `sparkles` button
that is only rendered when a tier could answer (`IntelligenceRouter.canDraft`):

- **Review summary drafts.** Context: the tier-1 `PullRequestDigest` (title, description excerpt,
  prioritised file list, top hunks — already budgeted) plus the reviewer's own pending inline
  comments, quoted and capped. The digest is built against a budget that has the room for those
  notes reserved (`ReviewSummaryDraftRequest.digestBudget(in:)`), because the two travel in one
  prompt and tier 2's ceiling is a hard error.
- **Inline comment drafts.** Context: the file path, the anchor, and a marked-up window of the
  unified diff around the commented line (`InlineCommentDraftBuilder`) — a fixed number of diff
  lines on either side, then trimmed to a share of the tier's character budget, with the anchored
  lines the last thing to be given up. Not the whole digest: a question about three lines should
  not spend the context window on the other forty files.

The result is written into a text field the reviewer edits, and only into that field:

- a draft never silently replaces text that is already there — the reviewer is asked to *replace*
  or *append*, and until they answer, nothing is written (`AIDraftFieldState`, a pure value so the
  rule is unit-tested);
- while the field holds an unedited draft it carries a caption naming the tier that wrote it, which
  disappears on the reviewer's first keystroke, because after that it is their text;
- failures surface as one line of the tier's own words, through the existing `IntelligenceOutcome`,
  exactly like a missing summary card.

**The non-goal is reaffirmed: nothing auto-submits.** There is no code path from a drafted string to
`submitReview`, to the outbox, or to a saved draft comment; every one of those still needs the
reviewer's own click, and a review Shepherd sends is a review a human read. Requests continue to go
only to the provider the user configured themselves — with drafting, the diff excerpt is part of
what is sent there, which is now stated in `CONTRIBUTING.md`'s host list.

Consequence: a new drafting surface is a new request type plus a case in the same four provider
methods. Anything that would *act* on drafted text without a click needs its own ADR, and would
have to overturn the non-goal above rather than quietly widen this one.

## Consequences

- No feature may hard-depend on an LLM; every AI surface needs a heuristic-only fallback state.
- We do not embed our own weights (MLX/llama.cpp) in v1 — tiers 1–3 cover the need with far
  less engineering; revisit only if offline non-Apple-Intelligence demand materializes.
- Prompting code must budget tokens explicitly (tier 2's 8K ceiling is a hard error, not a
  truncation).
