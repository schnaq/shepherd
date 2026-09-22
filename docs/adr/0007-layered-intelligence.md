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
package, behind identical call sites — built on 2026-09-22 as `SessionProvider` with an on-device
and a Claude backend ([ADR 0031](0031-a-model-you-bring.md), amendment; [ADR 0038](0038-macos-27-floor.md)).

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

## Amendment (2026-09-02): streaming and measured budgets

Additive again, and again inside the decision above: the three tiers, the provider protocol, the
"hints, never verdicts" rule and the host list are all unchanged. Two pieces of groundwork
(`docs/plans/apple-intelligence-v2.md` §0.1–0.2), landed before the features that need them:

- **Streaming.** The two drafting calls gained streamed twins that yield **cumulative** text — the
  whole draft so far, never a delta — so the value that reaches a text field is always a complete
  value, and a dropped element cannot leave a hole in a reviewer's comment. On-device this rides
  guided generation's partially-generated snapshots; the two cloud shapes send `stream: true` and
  are accumulated behind one pure server-sent-event parser plus one decoder per shape in
  `ShepherdCore`, which is what makes both wire formats testable on Linux from recorded frames. A
  tier that cannot stream keeps its button: the protocol's default implementation yields the
  finished answer once. The router hands out the *tier together with the stream* and waits for the
  first element before answering, which is what lets the cloud → on-device ladder still step down
  (a tier that failed on the connection has shown nothing yet) while making the caption naming the
  tier correct before the first character appears. The rule that a draft never silently replaces
  typed text is unchanged and is now asked **before the request is made** — so answering *discard*
  means nothing was generated and, for tier 3, nothing was sent.
- **Measured budgets.** The chars-÷-4 estimate stays as the portable floor, but where the OS can
  measure a prompt against the real tokenizer and report the real context window (macOS 26.4+),
  that measurement wins and the ~25 % slack the estimate forced is given back to the prompt. The
  arithmetic stays pure and Linux-tested (`TokenBudget.measured(_:using:)`,
  `limited(toContextSize:reservedForResponse:)`); only a two-line helper in the app target names
  the platform API. Tier 2's ceiling is still a hard error, never a truncation, and every
  on-device call now also caps its *answer*, because prompt and response share one window.
  Guardrail refusals and an exceeded window became two named errors with one sentence each, and
  are never retried automatically: the guardrails over-fire on technical prose, so a retry would
  trip the same guardrail on the same words and spend battery doing it.

Consequence: a new drafting surface now has a streamed twin to implement as well — or it can
inherit the single-element default and be indistinguishable from today's behaviour.

## Amendment (2026-09-03): explaining a selection

Additive, and the smallest of these amendments: the tiers, the provider protocol's place in the
design, the host list and the privacy line are all unchanged. A **third drafting surface** joins the
two above (`docs/plans/apple-intelligence-v2.md` §3.D) — *explain the lines I selected* — and it is
inside this decision rather than beside it because it carries **exactly the context an inline
comment draft carries**: the same `InlineCommentDraftBuilder` window, cut against the same tier
budget, with the anchored lines still the last thing surrendered. Nothing new travels, so nothing
new has to be stated: the sentence in `CONTRIBUTING.md`'s host list about a diff excerpt reaching
the endpoint the user configured covers explanations with one added clause. Tier 2 first and tier 3
allowed, for that reason and no other.

Two things are new, and both are about the reviewer rather than about the data. The instruction asks
for three to six sentences of plain language **in `Locale.current`'s language**, named in the prompt
as a word ("German") rather than as a tag, so a German reviewer reads German whichever tier
answered. And the answer is not a draft: it is prose in a popover, with the tier named on it
(*Explained on-device*), and the single way out of that popover into anything editable is a
**Turn into a comment** button that hands the text to `AIDraftFieldState` — so the replace-or-append
question, the caption and the "it stops being a draft on your first keystroke" rule apply to an
explanation exactly as they do to a draft, without a second implementation of any of them.

**The non-goal is unchanged and, here, has one fewer path to guard:** the popover has no route to
`submitReview`, to the outbox or to a saved draft comment, and the explanation does not become a
comment at all until the reviewer presses the button and then presses *Add comment*.

Consequence: the protocol gained one requirement (`streamExplanation(_:)`) whose default
implementation **refuses**, unlike the two drafting streams' defaults, because an explanation has no
awaited twin to wrap — and a tier answering without one would be indistinguishable from a tier that
had.
## Amendment (2026-09-03): thread digests are an on-device-only content class

Additive, and this one narrows rather than widens: the three tiers, the provider protocol and the
"hints, never verdicts" rule are unchanged, and the host list gains nothing. What is new is a
*content class* that the ladder above does not apply to
(`docs/plans/apple-intelligence-v2.md` §3.G).

A review thread with six comments or more offers **Summarise**: a card above the conversation with
a state chip (*Agreed* / *Open* / *Blocked*), one paragraph of what was agreed and who is waiting
on whom, the questions nobody has answered as bullets, and the caption *Summarised on-device*.

**Tier 2 only, and by construction rather than by a setting.** The input is *colleagues' comments*.
The tier-3 argument this ADR makes is that a BYOK endpoint is acceptable because the user
configured it themselves and can see the one answer they asked for; the people in a review thread
configured nothing, and there is no version of "your colleague's sentence reached the endpoint you
configured" that is an informed choice by the person who wrote the sentence. That is the argument
ADR 0020 makes about translating a comment, applied to summarising one. So the rule is expressed as
unreachability, the way ADR 0020 expresses its own:

- the feature's only seam is `ThreadDigesting`, whose one production implementation is
  `Intelligence/OnDeviceThreadDigester.swift`;
- `ThreadDigestCoordinator`'s initialiser takes that seam and a `TokenBudget` — there is no
  router, no base URL and no key to hand it, which a test asserts;
- no request type for a thread digest exists on `IntelligenceProvider`, so `IntelligenceRouter`
  and the two cloud providers are untouched by this feature and cannot be reached from it.

Turning that around — summarising a thread through a cloud model, even as an opt-in — needs a new
ADR, because "somebody else's comment never leaves this Mac" is the entire reason this feature is
acceptable without a consent dialog.

**When the model is not there, the button is not there.** No disabled control and no tooltip: the
availability answer (`SystemLanguageModel.availability` for the prose model) is asked once per app
run, and until it says yes nothing is drawn. That is this ADR's own principle — no feature
hard-depends on a tier — with the degraded state being the thread exactly as Shepherd has always
shown it.

**The budget is the hard error it always was, and the card says what it cost.** `ThreadDigestRequest`
(pure, in `ShepherdCore`, Linux-tested) drops the **oldest** comments first until the conversation
fits the tier's character share, caps any single comment so a pasted stack trace cannot push the
human sentences out, and records `coveredCount`/`totalCount`. A partial digest therefore says
*"Covers the last 8 of 23 comments"* rather than presenting a summary of the end of a thread as a
summary of the thread. Newest-last is the eviction order because a digest answers "where does this
stand *now*"; giving up the newest comments would produce a confident answer that is wrong rather
than a partial one that is honest.

**Nothing in it acts, and the guardrail is a sentence in the prompt as well as an absence in the
code.** *Resolve thread* stays the reviewer's own button beside the reply field; the instructions
forbid the model from suggesting that it be pressed, from replying, approving or merging, and there
is no code path from a digest to `setThread(on:threadID:resolved:)`, to a reply or to the outbox.
The digest is not persisted either — no `UserDefaults`, no GRDB table, no field in
`SyncedSettingsDocument` — for ADR 0020's reason: it is a reading aid held in memory for as long as
somebody is reading it, keyed by the thread and its newest comment so that a reply invalidates it.

Consequence: a further on-device-only content class is a new seam plus its own file, not a case in
`IntelligenceProvider`. Anything that would send third-party prose to a configured endpoint has to
overturn the paragraph above rather than quietly widen it.

## Amendment (2026-09-03): served-by headers, sovereignty metadata and an optional policy

Additive, and inside both the original decision and the preset amendment above: the three tiers,
the provider protocol, the host list and the privacy line are unchanged, and **no preset gains a
code path** (`docs/plans/apple-intelligence-v2.md` §3.K). What changes is that tier 3b now *reads*
three optional things an endpoint may volunteer, and *sends* one optional thing the user may set.

The preset amendment's rule was "a preset only fills in the base URL". That rule stands, with one
sentence added to it: **a preset may also describe an optional extension, in copy.** The extension
itself is generic — every OpenAI-compatible endpoint is offered it, reads of it are `nil`-tolerant,
and writes of it happen only when the user asked for them — so the difference between the
`Konduit (EU)` preset and a hand-typed URL remains a base URL, a note and a key link.

**Read: who actually ran the model.** A gateway in front of several operators can answer two
questions a single-operator API cannot — which operator ran the weights, and which exact
deployment. Two optional response headers carry that, parsed by one pure function into a
`ServedBy` value (operator, plus a deployment id kept for the code that may later pin it). It
reaches the caption over a reviewer's draft as a suffix and nothing more: *AI draft (custom
endpoint · scaleway)*. An endpoint that sends neither header produces `nil`, and the caption is
byte-for-byte the line it was — which is what makes this a hook rather than a branch. It is read
from the initial response, before the first server-sent event, so the caption is correct **before
the reviewer sees a character**, the same ordering the streaming amendment established for the
tier's own name. On-device and Anthropic keep a no-op default: there is no operator to name where
there is no gateway.

**Read: sovereignty and pricing per model.** `GET {base}/models` may carry, after OpenAI's four
fields, a `sovereignty` block (hosting country, ownership, zero retention, tier, certifications,
note) and a `pricing` block. `OpenAIModelsResponse` keeps both — every field optional, a malformed
extra costing only that extra rather than the list — and the model picker shows one short badge per
row (*DE · zero retention · eu-owned*). The reason it is in the picker and not in a details pane is
that this is the tier people are on *for* data residency: "where does this model run" is the
question they are choosing by. A plain OpenAI endpoint publishes none of it and the picker is
exactly what it was.

**Read: the endpoint's own token count.** Streamed requests now send
`stream_options: {"include_usage": true}` and keep the final usage chunk's counts. It is the cloud
twin of the measured on-device budget: the estimate Shepherd cuts a prompt against is arithmetic,
and this is what the endpoint actually billed. Nothing renders it — a number under a reviewer's
draft would be noise — and the chunk cannot disturb a draft, because it carries an empty `choices`
array, which the delta decoder already reads as "no text in this frame", and `[DONE]` still ends
the stream.

**Write: one optional sovereignty policy, and only when set.** Two new synced settings on the
OpenAI-compatible endpoint — a list of ISO 3166-1 alpha-2 countries, and a zero-retention flag —
travel in the **request body** as `provider: {countries, zero_retention}`. They are generic
request-body content, not a per-endpoint feature: an endpoint that understands the fields honours
them, and one that does not refuses the request in its own words, which is the honest outcome for
a constraint the user asked for and the endpoint cannot meet. Both ship empty/off, and in that
state the object is **not sent at all** — an empty `provider: {}` would break every endpoint that
has never heard of the field, so "only when set" is a correctness rule and not a nicety. They are
`SyncedSettingsDocument` fields with both `SettingsSyncApplier` directions and a fixture value
(ADR 0014), because they are part of *what the request is*: two Macs that disagreed about them
would send a prompt to a country their owner asked it to stay out of.

**One retry, on one status, from the endpoint's own instruction.** A `429` carrying a
`Retry-After` a person will sit through — integer seconds up to 30, or an HTTP-date inside the
same ceiling — is waited out **once** and the request made once more. Never a loop: there is one
call site rather than a counter, anything else surfaces as today's `IntelligenceError.http`, and a
cancellation during the wait aborts instead of resuming. The `IntelligenceTransport` seam grew a
headers-bearing round trip for this and for the served-by parse, with a default implementation that
forwards to the old one, so the retry decision is asserted against a scripted transport rather than
against a rate-limited key on a user's Mac.

**Nothing new travels.** Every read above is the endpoint talking about its own answer; the one
write is two values the user typed into Settings. The content Shepherd sends is unchanged, so
`CONTRIBUTING.md`'s host list gains one clause about the policy fields being part of the request
when set, and nothing else.

Consequence: a further optional extension of this kind is a `nil`-tolerant read plus, at most, a
sentence of preset copy. Anything that needs the *provider* to behave differently per endpoint —
a second request shape, a capability probe, a branch on a base URL — still needs its own provider
and its own ADR, exactly as the preset amendment says.

## Amendment (2026-09-22): screenshots are an on-device-only content class, read on a click

[ADR 0038](0038-macos-27-floor.md)'s item 4 asked for images in the prompt "so the on-device digest
can say what changed visually". Additive, and narrower than that sentence: the tiers, the provider
protocol and the text summary are unchanged, and `PRSummary` gains no field. What is new is a
second content class under the thread-digest amendment's rule — *a further on-device-only content
class is a new seam plus its own file, not a case in `IntelligenceProvider`*.

**Why on-device only.** A screenshot in a description is a colleague's content, and less
predictable than their prose: it shows whatever was on their screen — a customer record, a token
in a terminal, a Slack window behind the simulator. The thread-digest argument applies word for
word (the person who took it configured no endpoint), and more strongly, so it is expressed as
unreachability: `Intelligence/ScreenshotReading.swift` declares `DescriptionScreenshotReading`,
whose one conformer `OnDeviceScreenshotReader` takes no router, base URL or key;
`IntelligenceProvider` has no image request; the cloud tiers keep receiving the description as
text, as they always have. Sending screenshots to a BYOK endpoint, even as an opt-in, needs a new
ADR.

**Why a click, and not the summary.** The inbox's summary runs whenever a row is selected — `j`/`k`
through thirty rows asks thirty times — so "the summary is already a click" is not true of this
app, and folding images into it would download every colleague's screenshots as the reviewer
scrolls. The summary card instead offers *Read the 2 screenshots* when the description attaches
GitHub-hosted uploads **and** `SystemLanguageModel.default.capabilities.contains(.vision)`; with
either missing, there is no button. Selecting a row costs a Markdown scan
(`ShepherdCore/Markdown/DescriptionImages.swift`) of a description already in the database, and
nothing else.

**What the click fetches.** GitHub's HTML rendering of the description (`Accept:
application/vnd.github.html+json` on the `/pulls/{n}` read the detail already makes), which carries
a short-lived signed `private-user-images.githubusercontent.com` link for each upload; then at most
two of those links, with no token, at most 8 MB each, refused for any other host. Not the
`github.com/user-attachments` URL the Markdown spells — it redirects to an S3 bucket that is not on
CONTRIBUTING.md's host list — and never an image hosted anywhere else. Checked on 2026-09-22 against
a public and a private repository: in both, the signed link answered `200 image/png` directly, with
no redirect and no token, and its file name carried the upload's UUID, which is how each Markdown
attachment is matched to its link. Nothing is cached or stored: the bytes and the answer live as
long as the selection.

**What the model is asked, and what it may say.** The title and each image's label — position, and
the author's alt text when it is more than an upload's default — and not the description, because
the description is where the claims are, and a model told "this makes the button blue" beside a
screenshot writes that the button is blue. The `@Generable` answer is a list of sentences with no
status and no confidence field (ADR 0026's rule); the instructions say what is visible and forbid
judging the change or advising the reviewer. The block is tagged *2 screenshots, read on this Mac*
(*1 of 3* when fewer were read than attached), under whichever tier wrote the text summary.

**The budget.** `tokenCount(for:)` throws for a prompt with an attachment on macOS 27.0
(`ModelManagerError 1001`), so the images cannot be measured. The text is measured as every other
request is, and each image is charged 256 tokens — the spike on 2026-09-22 read
`session.usage.input.totalTokenCount` at 35–165 tokens an image from 256 to 2,048 pixels, flat past
about 1,024 because the framework scales images itself. Images are decoded at most 1,024 pixels on
their long side. Two images, the instructions and the schema came to 586 input tokens on a real
pull request.

A known limit, recorded rather than engineered around: shown two near-identical screenshots, the
model can report a difference that is a pixel or two ("slightly larger"). The tag and the help text
say it is what the model on this Mac saw; nothing downstream reads the sentences, and there is no
path from them to a comment, a review or the composer.

## Consequences

- No feature may hard-depend on an LLM; every AI surface needs a heuristic-only fallback state.
- We do not embed our own weights (MLX/llama.cpp) in v1 — tiers 1–3 cover the need with far
  less engineering; revisit only if offline non-Apple-Intelligence demand materializes.
- Prompting code must budget tokens explicitly (tier 2's 8K ceiling is a hard error, not a
  truncation).
