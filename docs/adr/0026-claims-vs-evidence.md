# ADR 0026: Claims vs. Evidence — the description beside the diff, with no score

Status: Accepted · Date: 2026-09-03

## Context

The maintainer interview behind [`docs/plans/agent-fleet.md`](../plans/agent-fleet.md) named four
costs of reviewing ten to forty agent pull requests a week. The second one was **checking what the
agent claims**: an agent's description asserts "tests added", "only the parser changed", "no
breaking changes", "fixes #142" — in that order of frequency — and verifying each assertion by hand
means opening the file list, the check list and the diff and holding three answers in your head at
once. The claims are formulaic (an agent writes them the same way every time), and every one of
them is checkable against data Shepherd has already fetched.

Two things could go wrong with a feature like this, and they are opposite:

- it could become a **trust score** — a number, a badge, a "looks safe" — which is the verdict
  [ADR 0007](0007-layered-intelligence.md) forbids for AI output and which would be no better for
  being deterministic. A score invites the reviewer to skip reading;
- it could become a **model feature**, opening a card that costs a model call on every pull request
  the reviewer looks at, unattended, over somebody else's prose.

## Decision

A `ClaimsEvidenceCard` above the description lists what the pull request **says** beside what
Shepherd **found**, one line per claim, each ✓ / ✗ / ? with the evidence named and linked into the
diff.

- **Claims are the pull request's own text.** `ShepherdCore/Claims/` holds `Claim`
  (`testsAdded` · `scopeLimited(module:)` · `noBreakingChanges` · `fixesIssue(number:)`) and
  `ClaimExtractor.extract(from:)`, a deterministic, documented pattern pass over the description.
  It is **sentence-scoped**: a claim's noun and its verb have to be in one sentence, because a
  pattern let loose on a whole body finds "tests" in one bullet and "added" in the next. The quote
  travels with the claim and is what the card shows — Shepherd's category label is only there to
  make four lines scannable.
- **Evidence is the diff and CI, and nothing else.** `EvidenceChecker.check(_:in:)` is a pure
  function of a `PullRequestDetail` Shepherd has already stored: changed paths classified by
  `FilePrioritizer` (test files, lockfiles, generated files, configuration, CI workflows — the same
  classifications the file list ranks by, so the two surfaces cannot disagree), the check rollup
  with its failing checks named, and regular expressions over the hunks for **assertion drift**
  (an `XCTAssert`/`expect(`/`assert`/`t.Fatal` line removed, an `XCTSkip`/`xit(`/`pytest.mark.skip`
  added) and for **removed exported declarations** per language.
- **Every fact is a sentence, and the status is derived from the facts.** Not the other way round:
  a ✗ line always carries the facts that contradict it, so a reviewer who disagrees with Shepherd
  can see where it went wrong. The rules are documented per claim on `EvidenceChecker`, and each
  one has a test.
- **No score, no aggregate, no verdict.** `ClaimsEvidenceReport` has `lines` and nothing else —
  there is no total, no ratio and no "overall" field, and adding one would need a new ADR. The
  card's own footnote says so.
- **Collapsed for people, expanded for agents.** [ADR 0008](0008-agent-provenance-first-class.md)'s
  provenance facet: a recognised coding agent's pull request opens the card, a person's leaves it
  as a header. A bot that is *not* a recognised agent counts as a person here. The reviewer's own
  toggle outranks the default from then on.
- **Nothing in it acts.** ✗ lines get a *Turn into a comment* button that puts the claim and its
  facts into the review summary composer — a plain insertion, asking before it replaces text the
  reviewer already wrote, exactly like `AIDraftFieldState`'s rule but without its tier caption,
  because this text is not generated. There is no path from the card to `submitReview`, to the
  outbox or to a saved draft comment.

### What is deliberately not checked

**Acceptance-bullet matching for `fixes #N` is out of scope, and the card says so.** GitHubKit has
no issue read; adding one for this card would be a new network read on every pull request, and the
plan's §2.A version of this line (matching the issue's checkboxes against the body and the diff)
needs the issue body cached in GRDB first. So the issue line is *always* ? and its two facts are
"Issue #142 of owner/repo is referenced" — with the URL — and "Acceptance criteria not checked —
the issue is not fetched". Reporting a ✓ because a reference exists would be the card claiming
something it did not check.

*Superseded by the amendment below, which grants exactly the read this paragraph withheld and
keeps the sentence it withheld it for: a line that says what it checked.*

### Tiers

**Tier 1 only, and complete at tier 1.** No model is involved: the card opens unattended on every
pull request, and ADR 0007's ladder exists for surfaces a reviewer asks for. The plan's optional
tier-2 pass — an on-device `@Generable ClaimList` over the same body, catching phrasings the
patterns miss — is a later **additive** step: it may add claims, marked as read by the model, and
nothing in the tier-1 path depends on it. It is **on-device only, never a cloud pass and never
bulk**, for the reason [ADR 0020](0020-apple-native-text-intelligence.md) and ADR 0007's
thread-digest amendment give about third-party prose: the description is somebody else's text and
this card is not something the reviewer clicked.

## Consequences

- `ShepherdCore/Claims/` is Foundation only and tested on Linux: a thirty-fixture
  corpus of realistic agent and human descriptions for the extractor, and one case per documented
  evidence rule. Patterns are `NSRegularExpression`, compiled once into statics behind a small
  `ClaimPattern` value, because that is the one engine that behaves identically on a Mac and on the
  Linux runner.
- Evidence facts are **structured values produced in `ShepherdCore`** — `EvidenceFact.Kind`, a
  closed set of sentence templates carrying the counts, paths, issue number, code snippets and
  matched words the sentence is made of — with `englishSentence` as the module's own pure
  rendering of them. The card draws the *app's* rendering,
  `EvidenceFact.localizedSentence(bundle:)`, which is `String(localized:)` with a German row per
  shape, like the card's own chrome — header, labels, buttons, captions
  ([ADR 0022](0022-german-localisation.md)). The English
  rendering stays where it is and is what a test asserts on and what *Turn into a comment* writes,
  because a review comment is written to GitHub. (This bullet said the facts were English
  sentences and that localising them was "a follow-up, not a hole"; the follow-up is the
  amendment below, and the sentence it was withheld for — one rendering, no concatenation — is
  kept.)
- `FilePrioritizer` gained one public function, `isLockfile(_:)`, so "a lockfile changed" can be its
  own fact without a second copy of the lockfile name list.
- The card adds **no network read, no write, no setting and no persistence**. It is recomputed from
  the local rows each time the review screen opens, like the CI diagnosis card and the thread
  digest, and it is rebuilt only when the pull request's data actually changes. (The 2026-09-03
  amendment below adds exactly one read — the referenced issue, once, while the card is open — and
  leaves the other three halves of this sentence standing.)
- The tier-2 half is three files and one property: `ShepherdCore/Claims/ClaimList.swift` (the
  `Codable` twin plus the merge), `Intelligence/ClaimExtracting.swift` (the seam and its
  availability value), `Intelligence/OnDeviceClaimExtractor.swift` (the `@Generable` mirror, the
  `.tagging` model, the measured pre-flight) and `Claim.origin`. A further tier for this card is
  not a case in `IntelligenceProvider`; it is a new ADR.
- Anything that would turn these lines into a number, gate an action on them, or send the
  description to a configured cloud endpoint has to overturn this decision rather than widen it.

## Amendment (2026-09-03): the tier-2 extraction, attended and additive

Additive, and inside the decision above rather than beside it: the four claim shapes, the evidence
rules, the no-score rule and the "on-device only, never a cloud pass" line are all unchanged. What
lands is the optional pass the **Tiers** section above already describes as a later step, and it is
in this ADR rather than in one of its own because it changes nothing about what the card *is* — it
only adds rows to it.

**Attended by the expansion, and by nothing else.** The pass runs when the reviewer opens or
expands the card, once per pull request, and there is no button: a control labelled *read this*
beside a card that is already complete would be asking the reviewer to decide something they have
no way to judge, and the expansion is the click. Nothing calls it from a sweep, from the sync pass
or from bulk triage. That is the whole of the difference between this and the model feature the
Context section refuses: a card that opens unattended on every pull request still costs no model
call, because a *collapsed* card reads nothing and an agent's expanded card is one the reviewer is
looking at.

**Additive, and provably so.** `ClaimList.merged(into:)` (pure, in `ShepherdCore`, Linux-tested)
takes the deterministic claims and returns them **unchanged** — same kinds, same quotes, same
verdicts once the report is recomposed — with the model's additions in the card's own order. A
model claim whose `Kind.dedupKey` matches a pattern claim is dropped, so the card never asks the
reviewer to read one piece of evidence twice, and what survives is marked `Claim.origin == .model`,
which is what puts a *Read by the model* tag beside that line's label. `Claim.origin` defaults to
`.pattern`, so every call site and every test written before this amendment says nothing about
origin and means what it always meant. A Mac with the model therefore shows a **superset** of the
same card, and that is a test rather than a comment.

**A quote is a quote.** The instructions ask for the sentence word for word, and
`ClaimList.quoted(in:)` (pure, in `ShepherdCore`, Linux-tested) is the check behind the request:
the extractor drops any claim whose quote does not occur in the description, whitespace folded and
case ignored, before the list leaves it. A paraphrase or an invented sentence beside a diff would be
an accusation Shepherd wrote itself and attributed to the author, and there is no way to repair
one — so it is dropped, never corrected.

**The evidence is not amended.** A model claim goes through `EvidenceChecker.check(_:in:)` — the
same function, the same rules, the same facts with the same links into the diff. "Evidence is the
diff and CI" was never a statement about where the claim came from. There is still no score, still
no aggregate field, and the tag is not a confidence: the on-device schema carries no confidence
field at all, because a number beside a claim would be the first number on this card.

**One tier, and no way to reach a second.** The seam is `ClaimExtracting`, whose one production
implementation is `Intelligence/OnDeviceClaimExtractor.swift`; `ClaimsEvidenceModel` takes that
seam and nothing else — no router, no base URL, no key — and no request type for claim extraction
exists on `IntelligenceProvider`, so the two cloud providers are untouched by this and cannot be
reached from it. This is the unreachability form ADR 0007's thread-digest amendment and ADR 0020
both use, and the reason is the same one the Tiers section gives: the description is a colleague's
text, and there is no version of "your colleague's sentence reached the endpoint you configured"
that is an informed choice by the person who wrote the sentence.

**When the model is not there, nothing is there.** No disabled control, no tooltip and no error
line: the availability answer is asked once per screen, and until it says yes the card is the
tier-1 card exactly as it has always been. A pass that *fails* — a guardrail refusal, a description
that outgrew the window — is not retried and not reported, for the same reason: the reviewer did
not ask a question, so there is nothing to answer. The budget stays the hard error it always was;
the body alone is what travels, and the only description that cannot fit is one that is a pasted
log.

**Nothing new is stored and nothing new acts.** The merged report lives exactly as long as the
review screen, like the tier-1 one — no `UserDefaults`, no GRDB table, no field in
`SyncedSettingsDocument` — and the added rows have the same single exit the others do: *Turn into a
comment*, into a field the reviewer edits.

Turning this into a bulk pass, into a cloud pass, or into anything that lets tier 2 *correct* a
tier-1 claim has to overturn the paragraphs above rather than widen them.

## Amendment (2026-09-03): the issue read — one GET, ETag-cached, only while the card is open

The paragraph above refused the `fixes #N` line an issue read for two reasons, and one of them was
wrong. It was right that a read on **every** pull request is not affordable; it was wrong that the
body has to be in GRDB first. So the read exists now, and it is bounded by *when* rather than by a
table.

- **`GitHubClient.issue(repo:number:)`**, one `GET /repos/{o}/{r}/issues/{n}`, REST for the reason
  ADR 0005 gives for `/pulls/{n}` and `/check-runs`: GraphQL earns its keep on the inbox *sweep*,
  a single resource by number is one request either way, and the REST URL is what makes the
  conditional-request cache work at all, since `cacheKey(for:)` keys on the URL and every GraphQL
  document shares one. The URL is immutable, so — unlike `/check-runs` — it leaves exactly one
  cache row behind however often it is read, and the second open of the same card pays a `304`.
- **Only while the card is open, and only for a line that references an issue.** A collapsed card
  costs nothing, a description with no `#N` in it costs nothing, and a signed-out window costs
  nothing. The read is per *pull request*, cancelled when the reviewer moves to another one, and
  never made by the sweep — nothing about the inbox touches this.
- **No table, and that is the decision this amendment makes.** An issue body is worth having while
  the reviewer is reading the card and worthless afterwards: a row would be stale the next time it
  was read, and would bring a "delete on sign out" obligation with it. So the cache is a dictionary
  on `ClaimsEvidenceModel` plus the client's own ETag cache — the same shape the CI diagnosis and
  the thread digest already have, and the reason migration **v7** is not part of this feature. The
  §2.A plan said "cached in GRDB"; this overrules that sentence and nothing else in it.
- **The reference is always repository-local.** `#N` is resolved against the pull request's own
  repository and `owner/repo#N` is not resolved at all, so the read can never reach a repository
  the reviewer did not open.

What the line then says is decided by `AcceptanceCriteria` and `AcceptanceMatcher`, both pure and
both tested on Linux. Bullets come from the issue body in three documented passes — checkboxes
wherever they are, else the first list under a heading naming acceptance criteria, else the first
list at all — and each is matched against the pull request's description, changed paths and commit
messages by keyword overlap (≥ 40 % of the bullet's distinctive words, ≥ 4 characters, minus a
small stop list), with the on-device embedding cosine (≥ 0.6, ADR 0019's embedder reused once
more) as a second pass for a bullet the words miss. The hunks are deliberately **not** in the
evidence text: a diff's identifiers are not the words a requirement is written in, and feeding
them in would mark every bullet as mentioned.

**An unmentioned bullet is never a contradiction.** The line is ✓ when every bullet is mentioned,
? when some or none are, and ✗ is unreachable — asserted by a test, not just written here. The
reason is the third bullet-extraction pass: with no checkbox and no heading, Shepherd is *guessing*
which list is the criteria, and a ✗ over a guess would show Shepherd's mistake as the author's.
Matching words says the pull request talks about the same thing as the bullet; it cannot say the
work was not done. A ✓ here therefore means less than the other three lines' ✓ — every bullet is
mentioned, not the issue is resolved — which is why the facts, one per bullet with the matched
words in them, are what the card actually shows.

When the issue cannot be read — a `404`, a token that cannot see it, an offline Mac — the old two
facts stay exactly as they were and a third names the reason. A window with no session at all never
asks, so its line keeps the two facts and nothing more: "not fetched" is already the truth there.
That is the paragraph above's rule kept: the line still says what it checked and what it did not.

Everything else in this decision is untouched. There is still no score and no aggregate, still no
model in this card, still no write, no setting and no persistence, and still no new host: the
issue read is `api.github.com`, the endpoint already on `CONTRIBUTING.md`'s list.

## Amendment (2026-09-03): the facts are data, and their German lives in the app

The follow-up the Consequences bullet above parked — *"localising the facts is a follow-up, not a
hole"* — is done, and it is the only thing that changed: the four claim shapes, the evidence
rules, the status derivation, the no-score rule and the single exit are all untouched, and so is
every sentence a reviewer reading English sees.

**The fact stopped being a string.** `EvidenceFact.text` is now `EvidenceFact.kind`, an
`EvidenceFact.Kind` with an associated value per thing the sentence names: a count, a path, an
issue number, a repository, a `+`/`−` pair, the head-side line, a snippet of somebody's code, the
bullet's own text, the matcher's reason. `AcceptanceMatch.reason` went the same way and is now an
`AcceptanceMatch.Reason` of four cases. Nothing about a fact's identity, its `path`/`line` link
into the diff, its `url` or its `mark` moved, and facts are still not persisted anywhere — the
`Codable` conformance is there because the type has always had it, and no stored row, no
`UserDefaults` key and no synced field holds one, so this is not a migration.

**Two renderings, and they answer different questions.**

- `EvidenceFact.englishSentence` — and `IssueLookupFailure.sentence`, and
  `AcceptanceMatch.Reason.englishSentence` — stay in `ShepherdCore`: pure, Linux-tested,
  unchanged word for word. They are what a test
  asserts on and what *Turn into a comment* puts in the review summary — that text is written to
  **GitHub**, where the author and every later reader of the thread reads English, which is
  [ADR 0022](0022-german-localisation.md)'s "the review vocabulary stays English" taken to its
  end. A German reviewer's comment does not become German because their Mac is.
- `EvidenceFact.localizedSentence(bundle:)` in the app target
  (`Shepherd/Features/Review/EvidenceFactText.swift`) is one `switch` over the same cases into
  `String(localized:)`, and it is the only thing the card draws. Sixty-six new keys in
  `Shepherd/Resources/Localizable.xcstrings`, every one with a German row and
  `python3 Scripts/check-localization.py` green.

**A key per shape was the cost this ADR named, and it is the cost that was paid.** Sixty-six rather
than the twenty-odd cases, because grammar is not a formatting detail: where the count is a
sentence's only argument the entry carries `variations.plural` with a German *and* an English
`one`/`other` pair (ADR 0022's plural rule), and where the count shares the sentence with a path,
a token or a title — which a top-level variation cannot express — the renderer picks between two
keys on `count == 1` instead, the shape `DigestPresentation.line(for:)` already uses. The
`fixes #N` line's own sentence is twelve keys for that reason: three states, a titled and an
untitled form, singular and plural.

**Paths, repository names, issue numbers, quoted words and code snippets are interpolated
verbatim** and are never in a translation. The quotation marks, on the other hand, belong to the
sentence: every key carries its own `“…”` so the German row can write „…“, which is why there
is one key in the catalog that is nothing but quotation marks — the one place a *list* of
quoted paths is assembled.

**What keeps it honest.** `Scripts/check-localization.py` proves every key the renderer writes has
a German row with matching specifiers; it cannot prove that every case the checker *produces*
reaches a key, because that is a fact about a `switch`. So
`ShepherdTests/EvidenceFactTextTests.swift` walks one sample per case *and per branch* and
asserts each renders to a sentence and that its
German differs from its English — the only way from inside the app to say "there is a German row
and it was used" — with a `default`-less `switch` beside the sample list that stops compiling when
a case is added. The `ShepherdCore` tests assert the structured kind and the English sentence
side by side, so a change to either is a change somebody meant.

## Amendment (2026-09-05): the card is what an agent's pull request opens on

Nothing about the card changes: same four claim shapes, same evidence rules, same no-score rule,
same single exit, same tiers. What changes is *where the reviewer is standing when it is drawn*.

The card lived on the Conversation tab and every pull request opened on Files, so the one surface
in Shepherd that knows something github.com does not was one click away — on every pull request,
every time, for the whole life of the app. An audit of what a first session can actually reach
rated that the most buried differentiator in the product, and it is a fair verdict: a feature you
have to know about before you can find it is a feature most people never find.

**So an agent-authored pull request whose description yields at least one claim opens on
Conversation, and everything else opens on Files as before.** The rule is
`ReviewModel.defaultTab(for:opensAgentPullRequestsOnConversation:)` — pure, `static` and tested,
the treatment `defaultRoundView(for:)` already gets.

- **"An agent wrote it"** is `ActorKind.agentIdentity != nil`, the same test this ADR's
  *Collapsed for people, expanded for agents* rule uses, and the same one `AutoMergePolicy` and
  the bulk-triage plan gate on. A bot that is not a recognised agent is a person here too, exactly
  as it is for the expansion. There is no second definition of "this is an agent" in the app and
  this does not add one.
- **"It claims something"** is `ClaimExtractor.extract(from:)` — the deterministic tier-1 pass,
  compiled `NSRegularExpression`s over the description and nothing else. It is emphatically *not*
  the on-device pass: the tab has to be decided in the same turn the detail arrives, and a default
  that waited for a model would move the reviewer's screen under them after the fact and would
  land on a different tab on a Mac without the model. It is also what makes the tab and the card
  agree by construction, since an empty extraction is precisely the case that yields an empty
  report and draws no card — this can never open the Conversation tab onto nothing.
- **Only at open, and never again.** `hasChosenTab` mirrors `hasChosenRoundView`: the default is
  spent on the first detail to arrive, so the fresh fetch behind the cached row does not re-decide
  it, a live refresh does not, and Reload after a push does not. The flag is also set by every
  path that moves the tab afterwards, so a reviewer who reached for the picker while the fetch was
  still in flight keeps the tab they chose. A default that could reassert itself is not a default,
  it is a rule.
- **One switch.** `AppSettings.opensAgentPullRequestsOnConversation`, on by default, in
  Settings → Appearance → Review screen, and in the synced document like every other preference
  (ADR 0014) — "I want the diff first" is a fact about the reviewer, not about the Mac. With it
  off the function answers Files for everything, which is exactly what the app did before this
  amendment.
- **`t` switches the tabs.** The review screen had a key for every action but this one, and
  opening somewhere new without a key back would have traded one buried surface for another. It
  is a bare key in `ReviewScreen.handleKey` beside `u`, `c`, `[` and `]`, guarded by
  `isAwaitingSecondKey` for the reason they are: `r` and `g` are the only prefixes and neither
  claims `t`.

What this does **not** do is act, rank or judge. No verdict is formed, nothing is submitted,
nothing is fetched that was not fetched before, and the card the reviewer lands on is the same
card with the same absent score. The only thing that moved is which half of the screen is in
front of them when the pull request opens.

## Amendment (2026-09-22): *Look closer* — the model reads the diff for one line, and points

[ADR 0038](0038-macos-27-floor.md)'s item 2 asked for "the reviewer that reads the diff": a
session with tools that checks a claim. Read against this ADR, most of that sentence is
forbidden and should stay so — a model **checking** a claim is a model issuing a verdict, and a
verdict beside a claim is the trust score the Context section refuses. What survives, and what
landed, is narrower and inside the decision above:

- **One click on one line.** A ✗ or ? line gets a *Look closer* button once the on-device model
  says it is there; a ✓ line does not, because it already carries the facts that support it. The
  click starts one session for that line and detail; nothing starts one on expansion, sweep or
  scroll. This is the first surface of the card that is *asked for*, which is what lets a failure
  be said out loud — the tier-2 extraction above stays silent because nobody asked it anything.
- **Pointers, not a verdict.** The session answers with at most four places in the diff: a file,
  one to three lines copied from it, and one sentence. `ShepherdCore/Claims/ClaimCheck.swift`'s
  `DiffExcerpt.locate(_:inPatch:)` looks for every excerpt on consecutive lines of that file's
  patch — markers ignored, whitespace folded, case kept — and `ClaimCheck.verified(_:in:)` drops
  every note it cannot find, exactly as `ClaimList.quoted(in:)` drops a quote the author did not
  write. The line's ✓ / ✗ / ? is still `EvidenceChecker`'s; the block under it is tagged *Read by
  the model on this Mac*; the schema has no status and no confidence field.
- **The reads are shown.** The tools are the three the CI diagnosis already uses, over the same
  `LocalToolExecutor`, and the block renders the same `CIDiagnosisTraceView`: every read, verbatim.
- **On-device only, as unreachability.** `Intelligence/ClaimChecking.swift` is
  `ClaimExtracting`'s sibling: its one conformer, `OnDeviceClaimChecker`, takes no router, base
  URL or key, and `IntelligenceProvider` gains no request. The claim is a colleague's sentence, for
  the reason the Tiers section gives. A claim and its context that do not fit the window are a
  sentence on the card, not a cloud rung.
- **What macOS 27 adds.** The session is built from a `LanguageModelSession.DynamicProfile` whose
  tool-calling mode is a function of the reads so far: `.required` before the first, `.allowed`
  below three, `.disallowed` after. The first turn therefore always makes a read — a guarantee,
  not a request in the instructions — and the instructions ask for that read to be a file's diff;
  `failingChecks` stays in the set because "tests were run" is a claim CI answers. `.required` for the whole session never ends; the spike on
  2026-09-22 showed the model calling the tool on every turn.
- **Nothing is stored and nothing acts.** Results live as long as the review screen and the
  detail they were read from; a new head forgets them. The block has one link per note, into the
  diff, and no path into the summary composer — *Turn into a comment* still writes only
  Shepherd's own facts.

Two things ADR 0038's item 2 named are **not** part of this, for reasons found the same day:
Private Cloud Compute answers `availability == .available` to a Developer-ID build and then
fails the first request (`ModelManagerError 1046`), so [ADR 0025](0025-private-cloud-compute.md)
stays parked on its entitlement condition; and `SpotlightSearchTool` over Shepherd's own index
would search titles, labels and authors of open pull requests only (`SpotlightExport`), which
the app can do without a model.
