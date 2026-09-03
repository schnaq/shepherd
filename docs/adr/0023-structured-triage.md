# ADR 0023: Structured triage — one on-device verdict per pull request

Status: Accepted (v1.x) · Date: 2026-09-03

## Context

The inbox can say who is waiting on the user, what CI thinks and who wrote a pull request. It
cannot say the thing a reviewer actually sorts by: *what kind of change is this, and how much can
it hurt.* Tier 1 gets halfway there — `FilePrioritizer` already knows that a file touches an auth
path, deletes a test, changes a CI workflow or is a regenerated lockfile — but those signals live
on the review screen, per file, and only for a pull request somebody has already opened. Nothing
turns them into one answer per row that the list can be ordered and filtered by.

The engineering plan's §3.A is the first feature of the Intelligence v2 set, and it is deliberately
the one with the most dangerous shape: a *generated classification*, computed for every pull
request in the inbox, in the background, with nobody watching. Four things about that shape decide
the whole design.

**It is unattended, so tier 3 is not available.** ADR 0007's argument for a BYOK endpoint is that a
human clicked a button, on one pull request, and can see what came back — that is what makes "your
code reaches the endpoint you configured" an informed choice. A pass over two hundred rows during a
sync is none of those things, and it would ship the whole inbox — titles, descriptions, diffs — to
a third party as a side effect of Shepherd being open. This is the same argument ADR 0019 makes
about search, arrived at from the other direction: search has nobody to ask, and a bulk pass has
nobody to inform.

**A classification is not a hint in the way a summary is.** A drafted sentence lands in a text
field a person edits; a *verdict* is a value in a database, keyed by pull request, ready for
anything to read. `BulkTriagePlan`, the auto-merge rules (ADR 0018) and the auto-delegation rules
(ADR 0016) are three engines that decide, unattended, to write to GitHub or to start an agent.
Every one of them would be "improved" by a risk level. That is precisely the improvement that must
not happen: it would turn a 3B-parameter model's guess into an approval, and the promise in
Settings — *Shepherd never submits a review, approves, merges or comments on your behalf* — would
become false without a single line of UI changing.

**The model can be absent, and it will be.** Apple Intelligence is off on a fresh Mac, the tagging
model's assets download separately from the general one, and the feature has a switch of its own.
So the question "what does the inbox look like without a verdict" is not an edge case, it is one of
the three normal states.

**The input is already built.** ADR 0019's `SearchDocument` is composed once per pull request, from
rows the sweep and the review screen already stored, byte-budgeted, with a hash that says when it
changed. A second corpus for classification would be a second thing to invalidate.

## Decision

### One verdict per pull request, from the tagging model, or nothing

`TriageVerdict` — `kind` (feature, fix, chore, dependency bump, docs, refactor), `risk` (low,
medium, high) and a one-sentence `reason` — is produced by `SystemLanguageModel(useCase:
.contentTagging)` and by nothing else. `OnDeviceTriageClassifier` (app target, one of the files
that may import `FoundationModels`) asks for it with `@Generable` enums, so the vocabulary is
enforced by guided decoding rather than by validation, at a low temperature, with a measured
pre-flight and a response cap, and with guardrail refusals and context overflows mapped to the two
`IntelligenceError` cases that already exist. The `Codable` twin lives in `ShepherdCore`, which is
what makes the storage, the facet and the ⌘K filter testable on Linux (ADR 0007's rule for every
generated shape).

**There is no cloud implementation of `TriageClassifying` and there may not be one.** Nothing in
the feature takes an `IntelligenceRouter`, a base URL or a key, so — as in ADR 0019 — this is
structural rather than a default somebody could flip. `CONTRIBUTING.md`'s host list is unchanged.

### It sorts, it does not approve — and a test says so

The rule: **no rules engine reads a verdict.** `BulkTriagePlan.make`, `AutoMergePolicy.decide` and
`AutoDelegationPolicy.decide` take pull-request rows, the user's own rules and their ledgers, and
that list is closed. A verdict reaches exactly three surfaces: a chip on the inbox row, a facet in
the rail, and two ⌘K filter tokens. All three sort or filter a list a human then looks at.

Because the failure mode is a *future* change rather than today's code, the rule is enforced by a
test and not only by this paragraph: `StructuredTriageTests.testNoAutomationInputCanSeeAVerdict`
walks the inputs of all three engines reflectively — `PullRequestSummary` included, since all three
take one — and fails if any value reachable from them is a triage type. Adding a `verdict` field to
any of them therefore turns CI red in the same commit that adds it.

The prompt carries the same rule, because a model that believes it is gating a merge writes
differently: it is told that its answer sorts and filters a list, approves nothing and starts
nothing, and that it should describe rather than recommend.

### Storage: beside the vector, invalidated by the same hash

Migration **v4** adds `triage_verdicts`: `prID` (primary key, `REFERENCES pull_requests(id) ON
DELETE CASCADE`), `documentHash`, `kind`, `risk`, `reason`, `modelIdentifier`, `classifiedAt`.
`createV1`, `addV2` and `addV3` are untouched, as `DatabaseManager` requires, and
`DatabaseManagerTests` lists `["v1", "v2", "v3", "v4"]`.

It is `search_index`'s shape on purpose — the two rows answer the same two questions about the same
pull request:

- **The foreign key *is* the pruning.** A pull request that leaves the inbox takes its verdict with
  it, inside the transaction the sweep is already doing.
- **`documentHash` is the re-classify gate**, exactly as it is the re-embed gate: a pull request
  whose *text* did not change keeps the verdict it has, however many sweeps have run. A verdict
  costs a generation, which is expensive in the same way an embedding is.
- **`modelIdentifier` is stored beside the verdict**, because two models' verdicts are not
  interchangeable. Apple ships model updates with the OS; a change of identifier re-classifies the
  inbox instead of presenting an old opinion as the current model's.
- **`kind` and `risk` are the twin's raw values in plain columns**, not JSON, so SQL can be asked
  about them. A row whose vocabulary this version does not know is skipped on read rather than
  failing the fetch — the table is a cache of locally computed opinions, so the honest response is
  no chip and a re-classification.

The table does **not** travel in the encrypted settings document (ADR 0014): it is device state,
rebuildable from local rows, exactly like the search index and the auto-merge ledger. It is dropped
by `eraseAllData()` on sign-out, because it describes the previous account's pull requests in a
model's words.

### The pass is a peer of the search index, not a step inside it

`TriageCoordinator` (`@MainActor @Observable`, the shape of `SearchIndexCoordinator`) runs on the
rows a sweep wrote — the same `onInboxRows` callback automatic merging (ADR 0018), the Spotlight
export (ADR 0021) and the search index (ADR 0019) already share.

It would have been *cheaper* to hang it off the end of an indexing pass, which has already composed
the very documents this needs. It is not, for one decisive reason: with **semantic search** switched
off the index composes its documents from inbox rows alone, so structured triage would quietly
start classifying titles instead of changes because a *different* feature's toggle moved. One
setting silently deciding another feature's quality is worse than one extra `detailFetchTimestamps()`
read and a second `SearchDocument.make` for the rows that changed. The two features share a data
source and nothing else, and neither imports the other.

Everything else about the pass is ADR 0019's discipline re-applied: the cheap `sourceFingerprint`
gate so an unchanged sweep reads one small column and stops, batches of twenty for the source read
(a stored diff has no size ceiling), composition in a detached task because tokenising and
prioritising is real CPU work, `.utility` priority, cancellable, and rows arriving mid-pass merged
by pull request rather than replacing each other — so the review screen announcing one stored diff
cannot discard a whole snapshot waiting beside it. Generations are sequential: one at a time, so a
two-hundred-row inbox stays out of the way of whatever the user asked for and a cancelled pass
throws away at most one verdict.

A failed classification is silent and is retried on the next pass; a guardrail refusal will refuse
again, and a transient failure will not. There is no toast, because nobody started this work.

### Without a model, the facet degrades to tier 1

The heuristic risk level is read straight off `FilePrioritizer`'s existing buckets — any
`reviewFirst` file makes a pull request high, any `standard` file medium, only skimmable or
generated files low — and a pull request with no stored diff has **no** risk at all rather than a
default one. Inventing "low" for a pull request nobody has opened would be a verdict.

So the three states are:

| State | Chip | Rail | ⌘K tokens |
| --- | --- | --- | --- |
| Verdict | `fix · risk high`, popover with the model's sentence and "Classified on this Mac" | counted, marked as the model's | filter |
| No verdict, tier-1 hints | `risk high`, popover with the `FilePrioritizer` sentences | counted, and the tooltip says the count is heuristic | no match |
| Neither | nothing | not counted | no match |

The ⌘K tokens deliberately match only real verdicts: a rail row is a count, and `kind:dependency`
is a claim about what the model said. The same tier-1 hints also go *into* the prompt, so the model
starts from facts about the diff instead of inferring them — and it is told they are facts.

### ⌘K learns two tokens, in the pure parser

`SearchQuery` recognises `risk:low|medium|high` and `kind:feature|fix|chore|dependency|docs|refactor`
(plus `deps`/`dependencies`/`dependency-bump`), removes them from the text before anything is
tokenised, ranked or embedded, and hands them over as a `TriageFilter`. Within an axis the values
are OR'd, across axes AND'd. A token that names nothing — `risk:urgent` — stays an ordinary search
word, because a filter nobody asked for that empties the palette is indistinguishable from a broken
search box.

A query that is *only* tokens is not empty: it is a listing. `SearchRanker` returns the filtered
candidates in a total order (repository ascending, number descending) rather than pretending to
rank them, because the query asked for a set and not for an order. The narrowing itself happens in
the palette's call, which reads the verdicts from `TriageCoordinator` and passes them into
`SearchIndexCoordinator.results(for:limit:verdicts:)` — so `Features/Search/` stays unaware that
triage exists.

### The switch is the one that already shipped, and off means off

`AppSettings.structuredTriageEnabled` (ADR 0014's document, both applier directions, on by default
like the search index and the Spotlight export) gains its consumer and a status line. Switching it
off cancels the pass, forgets the verdicts and **empties the table**, for the reason ADR 0019 gives:
a switch named after something that left its rows on disk would be lying. Re-enabling costs one
local pass. There is no *Rebuild* button beside the search index's, because a verdict is
invalidated by the document hash exactly as a vector is — the only reason to want one rebuilt is to
want them all rebuilt, which the toggle already does in two clicks.

With `intelligenceMode == .off` the switch is inert and says so in the model's own words. That is a
separate condition on purpose: the flag is stored rather than derived, so switching the tiers on
does not silently re-enable a classifier the user turned off.

## Consequences

- The inbox gains the ordering it could not compute: a chip per row, a RISK facet in the rail, and
  two ⌘K tokens — all of it from data Shepherd already downloaded, on the user's own Mac, with no
  new host in `CONTRIBUTING.md`.
- **A generated value now lives in the database, and exactly three surfaces may read it.** The
  "sorts, never approves" rule is the load-bearing part of this ADR, and it is enforced by a test
  over the automation inputs rather than by review discipline.
- The schema gained migration **v4**, and `DatabaseSchema.allTables` gained a table, so "Sign out &
  erase" empties it with everything else.
- Two coordinators now consume `onInboxRows` for content rather than for state, and a sweep that
  changed nothing still costs each of them one small column read. That is the price of their
  independence, and it is paid in a `.utility` task.
- **Verdict quality is now a thing that can regress**, and it will change under us: Apple ships
  model updates with the OS. `Scripts/eval-intelligence/` (plan §0.4) is where that is measured
  rather than felt, and `modelIdentifier` is what makes an update a re-classification instead of a
  silent mixture.
- A Mac without the tagging model gets the tier-1 half of the feature, permanently and quietly,
  with one line in Settings saying so — the same shape of degraded mode ADR 0019 has for search.
- Adding a `kind` or a risk level is a case in the twin, a case in the `@Generable` mirror, a token
  spelling and a catalog row. Adding a *reader* that is not a sort or a filter needs a new ADR, and
  it would have to overturn this one's central claim rather than quietly widen it.
