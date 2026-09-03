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

### Tiers

**Tier 1 only, and complete at tier 1.** No model is involved: the card opens unattended on every
pull request, and ADR 0007's ladder exists for surfaces a reviewer asks for. The plan's optional
tier-2 pass — an on-device `@Generable ClaimList` over the same body, catching phrasings the
patterns miss — is a later **additive** step: it may add claims, marked as read by the model, and
nothing in the tier-1 path depends on it. It is **on-device only, never a cloud pass and never
bulk**, for the reason [ADR 0020](0020-apple-native-text-intelligence.md) and ADR 0007's
thread-digest amendment give about third-party prose: the description is somebody else's text and
this card is not something the reviewer clicked.

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

## Consequences

- `ShepherdCore/Claims/` is Foundation only and tested on Linux: a thirty-fixture
  corpus of realistic agent and human descriptions for the extractor, and one case per documented
  evidence rule. Patterns are `NSRegularExpression`, compiled once into statics behind a small
  `ClaimPattern` value, because that is the one engine that behaves identically on a Mac and on the
  Linux runner.
- Evidence facts are **English sentences produced in `ShepherdCore`**, like `FilePrioritizer`'s
  review reasons and for the same reason: they are assembled from paths, counts and code snippets,
  and a catalog key per shape would be a key per sentence template. The card's own chrome — header,
  labels, buttons, captions — goes through `String(localized:)` with a German row
  ([ADR 0022](0022-german-localisation.md)). Localising the facts is a follow-up, not a hole.
- `FilePrioritizer` gained one public function, `isLockfile(_:)`, so "a lockfile changed" can be its
  own fact without a second copy of the lockfile name list.
- The card adds **no network read, no write, no setting and no persistence**. It is recomputed from
  the local rows each time the review screen opens, like the CI diagnosis card and the thread
  digest, and it is rebuilt only when the pull request's data actually changes.
- The tier-2 half is three files and one property: `ShepherdCore/Claims/ClaimList.swift` (the
  `Codable` twin plus the merge), `Intelligence/ClaimExtracting.swift` (the seam and its
  availability value), `Intelligence/OnDeviceClaimExtractor.swift` (the `@Generable` mirror, the
  `.tagging` model, the measured pre-flight) and `Claim.origin`. A further tier for this card is
  not a case in `IntelligenceProvider`; it is a new ADR.
- Anything that would turn these lines into a number, gate an action on them, or send the
  description to a configured cloud endpoint has to overturn this decision rather than widen it.
