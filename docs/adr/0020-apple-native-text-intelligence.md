# ADR 0020: Apple-native text intelligence — Writing Tools in every composer, on-device translation of pull-request text

Status: Accepted (v1.x) · Date: 2026-09-02

## Context

ADR 0007 built a ladder for *generating* text: heuristics, then the on-device Foundation Model, then
a key the user brought themselves. Everything on that ladder answers the same kind of question —
"what should I write?" — and every rung above the first is optional, availability-gated and, on the
top rung, a network call the user consented to.

Two complaints from the founder interview are about text as well, and neither of them is that
question:

1. **Reviewing is writing.** A review is prose: a summary, a dozen inline comments, thread replies,
   a saved reply reused fifty times. It is written quickly, in a second language for most of this
   app's users, and it is published under the reviewer's name on somebody else's repository. What
   is wanted there is a proofreader and a tone check — not a ghostwriter.
2. **Not every pull request is in your language.** Agents write English; colleagues do not. A
   description in Portuguese, a review comment in German on an English-speaking team's repository,
   a Japanese thread on a vendored dependency — a reviewer either reads it or guesses at it, and
   "open github.com and paste it into a translator" is exactly the trip out of the app that ADR
   0001's whole premise is against.

macOS answers both with frameworks that are already on the machine and are not on ADR 0007's
ladder: **Writing Tools** (proofread, rewrite, tone, summarize — system UI, on-device with Apple
Intelligence, presented by the text control itself) and the **Translation framework**
(`TranslationSession`, on-device, macOS 15+, with language packs the OS downloads and manages).
Both are *system* capabilities, which is the important structural fact: they arrive as a modifier
on a text view and a task on a view, not as a provider, a request type, a prompt, a token budget or
a key.

Routing either of them through `IntelligenceProvider` would be the obvious-looking mistake. That
protocol's implementations include two cloud providers, so a `translate(_:)` method on it would be a
method every provider implements — and the very first thing it would send to a configured endpoint
is the body of somebody else's comment, sent because a reviewer wanted to *read* it. That is the
same shape of change the roadmap already refuses for the morning digest's on-device sentence, for
the same reason.

Three failure modes have to be designed out rather than tested out:

1. **A translation standing in for the original.** A reviewer approves, rejects and quotes what was
   *written*. A machine translation that replaced the author's words — even briefly, even in a
   collapsed state — would make the artefact a reviewer acts on something nobody wrote.
2. **A cloud round trip for something the OS does locally.** Comment text is not the tier-1 digest.
   It has an author who did not choose Shepherd's settings, and there is no version of "your
   colleague's sentence reached the endpoint you configured" that is an informed choice by the
   person who wrote the sentence.
3. **Writing Tools becoming a submit path.** Writing Tools *replaces the text in the field*. If any
   field in the app had a path to GitHub that did not go through a human's click, a rewrite would
   be a review nobody read.

## Decision

Use Apple's own frameworks, directly, at the two places they belong: the modifier on every field
where review prose is typed, and one view that draws a translation *under* text somebody else
wrote.

### A. Writing Tools in every composer, graded by what the field holds

`.writingToolsBehavior(_:)` is set explicitly on every text control in the app; nothing is left to
`.automatic`, because "what this field contains" is a decision and not a default.

- **`.complete`** — the full panel, including rewriting and tone:
  - `ComposerTextEditor` (`Support/DesignComponents.swift`), which *is* the review summary editor,
    the inline comment composer, the saved-reply body and the review-template body. One line covers
    four fields, and the next Markdown field in the app inherits it rather than needing to remember
    it. That the four are already one control is what makes this cheap.
  - the thread reply field (`ReviewComposer.ThreadPopover`) — a `TextField(…, axis: .vertical)` that
    grows to four lines, so the panel has somewhere to put its result.
  - the delegation task field (`Features/Delegation/DelegationSheet`), where the user writes
    instructions for a local agent under time pressure (ADR 0011).
- **`.limited`** — proofreading, no rewrite panel: the saved-reply **name** (one line, read in a
  menu) and the auto-delegation **prompt template** (ADR 0016), which contains `{{…}}` placeholders
  that `AutoDelegationPrompt` substitutes — a rewrite that improved a placeholder away would break
  an unattended run silently.
- **`.disabled`** — the review-template repository pattern (`owner/name` with `*`/`?`). It is not
  language, and a proofreader "correcting" it would change which template a repository gets.
- **Nothing in the diff viewer.** ADR 0003's rule is unchanged: the webview never handles user
  keystrokes, all text entry is native SwiftUI, and Monaco is not touched by this ADR.

There is **no setting**. Writing Tools is a system capability: it appears where macOS offers it and
is absent where the Mac or the user's System Settings say so. A Shepherd toggle could only ever be a
second, disagreeing answer to a question the OS already answers — the argument `UpdateController`
makes about Sparkle's own flag (`CONTRIBUTING.md`).

**Writing Tools complements the ✨ AI draft (ADR 0007 amendment) rather than competing with it:** the
draft *lands in the field as editable text*, and Writing Tools is what refines it there — a
generated first sentence, then the reviewer's own proofread or tone pass, both ending in the same
field, which still needs the same click to become a review.

**And nothing auto-submits, for a structural reason rather than a careful one.** There is no code
path from any of these fields to `submitReview`, to the outbox or to a saved draft comment that does
not pass through a button the reviewer presses; Writing Tools writes into the field and the field is
the same field it always was. This is the identical argument ADR 0007's amendment makes about
drafting, and it holds here without a new mechanism.

### B. Translation is added below the original, never instead of it

**Surfaces.** The pull-request description (`Features/PullRequest/ConversationView`) and every
review or thread comment body (`ReviewComposer.ThreadCommentView`, which is what both the thread
popover and the conversation tab's unanchored threads render). Both go through one new view,
`Intelligence/Translation/TranslatableMarkdownText`, which wraps the existing `MarkdownText`.

The **activity list is deliberately not translatable**, and not by omission: a `TimelineEvent`
carries either one of Shepherd's own fixed words ("Approved", "Requested changes", "Commented") or
a commit message headline, because `ResponseMapping.timeline(commits:reviews:detector:)` condenses
the timeline out of commits and reviews rather than mirroring GitHub's timeline API. There is no
third-party prose there to translate; the comment bodies are translated where they are actually
rendered.

**The invariant.** The original is drawn first, by the same view that draws it everywhere else, and
it stays on screen — while the translation is fetched, while it is shown, and after it is
collapsed. The translation appears **below** it in a subtly tinted block captioned *TRANSLATED ON
THIS MAC*, with a *Hide translation* / *Show translation* toggle. There is deliberately no "show
original" control: nothing ever took the original away, and a button that claimed to bring it back
would imply that something had.

**On-device, as a fixed rule rather than a setting.** Translation goes through
`TranslationSession`, obtained from SwiftUI's `.translationTask(_:action:)` with a
`TranslationSession.Configuration(source: nil, target: Locale.current.language)` — source `nil`
meaning "detect it", target being the system's language and never a preference of Shepherd's own.
A configured BYOK provider (ADR 0007 tier 3) is **not** consulted, and the rule is expressed as
unreachability rather than as an `if`: nothing in `Intelligence/Translation/` can reach
`IntelligenceRouter`, and no request type for translation exists on `IntelligenceProvider`. Turning
that around — translating through a cloud model, even as an opt-in — needs a new ADR, because
"somebody else's sentence never leaves this Mac" is the entire reason this feature is acceptable
without a consent dialog.

**Availability, and never a pointless button.** Two on-device checks run before any button is
drawn, both in `TranslationOffer`:

- `NLLanguageRecognizer` (NaturalLanguage) establishes the source language on prose only — fenced
  and indented code, inline code spans, links and `@mentions` are stripped first, at least ~24
  characters have to survive, and a low confidence in the recogniser's own top hypothesis is
  rejected. A comment that is a stack trace, or is "LGTM", gets no button rather than a confident
  translation of Latin.
- `LanguageAvailability().status(from:to:)` decides whether the pair is possible.
  `.installed` and `.supported` both count as yes — `.supported` means the language pack is not
  downloaded, and the first translation then makes **macOS** present its own download sheet.

That produces exactly three affordances: a **button** when the pair works, a **disabled button with
a tooltip naming the pair** when this Mac cannot translate it, and **no button at all** when the
text is already in the reviewer's language or when no language could be established. The
"already in the target language" case compares ISO-639 language codes only, so `en-GB` text is never
offered a translation into `en-US`, and `pt-BR` is never offered into `pt-PT`.

`LanguageAvailability` also has a `status(for:to:)` overload that detects the source itself, which
looks like the shorter path and is not taken: it returns a status and never the language it
detected, and the rule that matters most here — never offer to translate text already in the
reader's language — is a statement about that language. One detector, one answer, no way for the
two checks to disagree.

**The cache is a reading aid, not a record.** `TranslationCoordinator` (`@MainActor`,
`@Observable`) holds translations in memory, keyed by the **text and the target language**, for the
lifetime of the screen that owns it — the conversation tab has one, each thread popover has one.
Nothing is persisted: no `UserDefaults`, no GRDB table, no field in `SyncedSettingsDocument`, so
ADR 0014's standing obligation does not apply because this is not a setting. Two details are
deliberate: the key is the text itself rather than a hash of it, since a collision would put
somebody else's sentence under a reviewer's comment and the string is one the model already holds;
and the cache is bounded (oldest request evicted first), so scrolling a 300-comment conversation
with the button pressed cannot become the app's memory story. Keying on the text is also what makes
the cache survive a sync sweep replacing `model.detail`, a `ForEach` rebuilding its rows, or a trip
to the Files tab and back — all of which discard `@State` and none of which should discard the
translation somebody is reading.

**Strict concurrency.** `TranslationSession` is not `Sendable` and never leaves the
`.translationTask` closure. The closure captures two `Sendable` locals — the cache key and the
`@MainActor` coordinator — instead of the view, and the only value that crosses back is the
translated `String`, through an explicit `MainActor.run`. Failures, including Apple's
`TranslationError` (an unsupported pairing, a refused or cancelled language-pack download), are
surfaced in the framework's own localized words next to a *Try again* button, the same way every
other error in the app is surfaced — and never printed.

### The host list is unchanged, and that is an argument rather than an omission

`CONTRIBUTING.md` enumerates "the complete list of hosts Shepherd may contact". This feature adds
no request to that list because it adds no request: there is no `URLSession` in
`Intelligence/Translation/`, no endpoint, no payload, and nothing to configure. A language pack is
downloaded by **macOS**, on the OS's own initiative, through the OS's own sheet, from Apple's own
asset infrastructure — the same category of thing as the system dictionary, the emoji picker's data
or a font. It carries neither the text being translated nor anything about the user, and it happens
identically whether the request came from Shepherd, TextEdit or Safari.

Distinguishing the two cases matters more than being maximally conservative: a rule that counted
every OS-initiated asset fetch as one of Shepherd's hosts would make the list meaningless, and a
meaningless list is one nobody audits. `CONTRIBUTING.md` gains one bullet saying exactly this, so
that a reader who sees Apple traffic on their network while translating a comment finds the answer
where they will look for it.

## Consequences

- **No new host, no new setting, no new dependency, no new key.** The privacy line is unchanged in
  substance and clarified in wording.
- `Translation` and `NaturalLanguage` are imported by exactly two files
  (`Intelligence/Translation/TranslationOffer.swift`, `TranslatableMarkdownText.swift`), both in the
  app target. `Packages/ShepherdKit` gains nothing and keeps building on Linux — the same
  containment rule that already holds for FoundationModels (ADR 0007), WebKit (ADR 0003), Sparkle
  (ADR 0010) and MetricKit (ADR 0017). `project.yml` needs no change: XcodeGen globs `Shepherd/`,
  so the new folder is picked up, and Swift auto-links system frameworks.
- **Availability guards are not needed.** Both frameworks predate the app's macOS 26 floor (ADR
  0002), so there is no `if #available` anywhere in the feature — only the runtime *capability*
  checks, which are a different thing and are the ones that matter.
- A Mac without Apple Intelligence simply has no Writing Tools in its text fields, and a Mac
  without a language pair shows a disabled button with the reason. Both are the ADR 0007 principle
  applied to system features: no feature hard-depends on an intelligence tier, and a missing one is
  *explained* rather than hidden.
- A Writing Tools rewrite of a Markdown body can reflow the Markdown. The mitigation is the
  existing one: the result appears in the field, in front of the reviewer, and reaches GitHub only
  through their click.
- Adding a translation surface later is one view: wrap the text in `TranslatableMarkdownText` and
  hand it the screen's coordinator. Adding a translation *provider* is a new ADR.
- **Non-goals.** No automatic translation on appear, scroll or sync — the language check is
  automatic, the translation never is. No translation of the diff or of code (Monaco is untouched,
  and code is not prose). No translation of Shepherd's own interface: the app's UI is English via
  `String(localized:)` and that rule is unchanged. And no translation of *outgoing* review text —
  a comment the reviewer cannot read is a comment they cannot stand behind, so what they get for
  their own prose is Writing Tools, in the language they chose to write in.
- What is tested is what can be wrong invisibly: the offer rules as a pure function over
  `(source, target, isPairSupported)`, the prose strip and the detection guards, and the cache's
  keying, collapse behaviour and eviction. `TranslationSession` itself is not mocked — a stub
  translator would assert nothing about Apple's translator.
