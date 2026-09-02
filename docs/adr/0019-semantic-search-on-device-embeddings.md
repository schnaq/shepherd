# ADR 0019: Semantic ⌘K search over pull requests, on-device only

Status: Accepted (v1.x) · Date: 2026-09-02

## Context

The inbox is good at "which pull requests are waiting on me" and has no answer at all for "where
was that thing about the token refresh". By the time Shepherd is useful it holds a few hundred
open pull requests across every repository the user touches, and finding one of them means either
remembering its number or scrolling a list whose only text filter is the rail's facets. The
founder's request was one sentence: *"PR-Suche nach Inhalt/Diff mit On-Device-Embeddings, lokal in
SQLite."*

Three things about the situation shape the design more than the request does.

**The corpus is small and the data is already here.** Hundreds of rows, not millions — and every
one of them is already in SQLite, because ADR 0006 made the local database the source of truth.
The sweep stores titles, labels, branches, authors and numbers for everything; the review screen
stores the description, the changed files and the unified diffs of anything the user has opened.
Search is therefore an *indexing* problem, not a fetching one, and a search feature that made a
GitHub request would be a regression in the one direction the whole architecture is pointed.

**"Semantic" is worth having and is not sufficient.** A user typing `#128`, `schnaq/review#128`,
`automerge` or `Package.swift` wants a specific row, not the six nearest neighbours of a sentence.
Embeddings are good at the other half — "flaky login test" finding *Retry the auth suite* — and
notoriously bad at exact identifiers. Any design that has only one of the two rankings is worse
than the list it replaces.

**Search runs on every keystroke, over everything.** That single fact settles the privacy question
before it is asked. Shepherd's BYOK tiers (ADR 0007) are acceptable because a human clicked a
button, on one pull request, and can see the result — that is what makes "your code reaches the
endpoint you configured" an informed choice. An embedding call per keystroke, over every pull
request in the inbox, is none of those things: it would ship the whole inbox — titles,
descriptions, diffs — to a third party as a side effect of typing. It is the same argument
`CONTRIBUTING.md` already makes about the unattended morning digest, with the roles reversed: the
digest has nobody to inform, and search has nothing to ask.

Four failure modes have to be designed out rather than tested out:

1. **A search box that is a network client.** Either directly, or by "just" using the configured
   AI provider for embeddings.
2. **A palette that always has an answer.** Every document has a cosine with every query, so a
   naive vector search answers "kubernetes helm chart" with the six least-unrelated pull requests
   in the inbox. A confidently wrong answer is worse than an empty one, and it destroys trust in
   the results that *are* right.
3. **An index that costs more than the feature is worth.** Embedding a megabyte of vendored
   JSON, re-embedding the entire inbox on every sweep or on every launch, reading every stored
   diff out of SQLite every two minutes, or blocking the main actor while doing any of it.
4. **A feature that only works on new hardware.** `NLEmbedding` can be absent. If search stops
   working when the model does, the palette becomes a lottery.

## Decision

### The palette gains a second kind of answer, and the keyboard does not notice

⌘K keeps every command it has, matched by the existing fuzzy filter. Below them — or above them,
see next paragraph — comes a **Pull requests** section with the best matches from the local inbox:
repository and number, title, the provenance chip (ADR 0008), the CI dot, and one line of *why
this matched* where it is cheap to say. ⏎ opens the pull request through
`AppEnvironment.openReview(prID:)`, the same call the inbox row, the menu-bar row and a
`shepherd://` link make, so the focus session's "did the user leave the queue" rule (ADR 0016's
sibling in `docs/ARCHITECTURE.md`) cannot be bypassed by a new surface.

Arrows, ⏎ and Escape work over **one** ordered list (`CommandPaletteView.PaletteRow`), because two
lists would mean two cursors and a rule for crossing between them. The pull requests lead when the
query reads like a search — two or more words, or an explicit `owner/repo#123` — and when no
command matched at all; otherwise the commands stay on top, because a word or two is usually
somebody reaching for a command name and this is still a command palette.

### What is indexed: the row always, the change when it is there

One "search document" per pull request, composed by `SearchDocument.make(source:budget:)` in
`ShepherdCore`, out of exactly this, in this order:

| Field | Source | Weight |
| --- | --- | --- |
| title | `pull_requests.title` | 3 |
| identity — owner, name, number, `owner/name#n` | the row | 3 |
| labels | `pull_requests.labels` | 2.5 |
| author login, plus the detected agent's display name | the row (ADR 0008) | 2 |
| head branch name | the row | 2 |
| description, first 2 000 bytes | `pull_requests.bodyMarkdown` | 1 |
| changed-file paths, first 1 000 bytes | `changed_files.path` | 1.5 |
| **added** diff lines, first 3 000 bytes, each cut at 200 characters | `changed_files.patch` | 0.6 |

Six decisions are in that table.

- **Nothing is fetched for indexing, ever.** Every column above is one the sweep or the review
  screen already wrote. A pull request nobody has opened has no body, no paths and no diff, and it
  is indexed on the other five fields — which is not a degraded state, it is everything Shepherd
  knows about it. Opening it later fills the rest in by itself (below).
- **Added lines only.** What a change is *about* is what it introduces; indexing removed lines
  would rank a deletion of `login` as highly for "login" as an addition of it. Hunk headers, file
  markers and context lines carry no new words.
- **An explicit byte budget** (`SearchDocumentBudget`), because the input has no upper bound — one
  generated client is a megabyte of diff. ~6 KB of text per pull request means a four-hundred-row
  inbox is a couple of megabytes of corpus, which is the size of one screenshot. Without it the
  corpus would grow with the largest pull request in the inbox rather than with their number, and
  the lexical ranker's term counts would be dominated by whichever pull request is biggest.
- **Whole entries, never a partial one**: half a file path is not a file path, and half an added
  line tokenises into a word that is not in the diff.
- **Field weights instead of BM25F.** The weight multiplies the term frequency of the field a term
  was found in, so "a word in the title" outranks "a word somewhere in a diff" without the ranker
  needing to know that fields exist. The order of the weights is the order of how deliberately a
  human chose the words: a title and a label are written to be read, a diff line is not.
- **The composition rules carry a version** (`SearchDocument.schemaVersion`), which is part of
  both hashes — so changing what goes into a document invalidates every stored vector by
  construction rather than leaving an index two different Shepherds built.

### Embeddings are on-device, and that is a rule rather than a setting

`EmbeddingProviding` (app target) has exactly one production implementation:
`NaturalLanguageEmbedder`, an `actor` wrapping `NLEmbedding.sentenceEmbedding(for: .english)` —
the only importer of `NaturalLanguage` in Shepherd. An `actor` because `NLEmbedding` is a
reference type Apple does not declare `Sendable`, and because the per-keystroke query embedding
then happens off the main actor.

**There is no cloud implementation of that protocol and there may not be one.** No type in
`Features/Search/` takes an `IntelligenceRouter`, a base URL or a key, so this is not a toggle
somebody could flip: the BYOK endpoint is unreachable from here. `CONTRIBUTING.md`'s host list is
therefore unchanged, and it stays unchanged when a user configures Anthropic or an
OpenAI-compatible endpoint for the tiers that *do* use them (ADR 0007). Failure mode 1, closed by
construction.

`NLContextualEmbedding` (macOS 14+) was considered and rejected for v1: it is stronger on long
text, but its models are *assets* — the app must check `hasAvailableAssets`, request a
multi-megabyte download and wait for it before `load()` succeeds. A search box that quietly starts
a download is not something Shepherd may do. The sentence embedding is part of the OS, is `nil`
when it is not, and answers in well under a millisecond, which is what ranking on every keystroke
needs. Revisiting it is a roadmap item, and it costs one new `modelIdentifier` — which invalidates
the index by itself.

A document longer than a sentence is **chunked at word boundaries (~600 characters, at most 8
chunks) and mean-pooled**, then normalised. Mean rather than max: a mean keeps a long document
*about* its contents, while a max makes it about its most extreme dimension per axis, so two
unrelated pull requests that each contain one alarming word become neighbours. The chunk ceiling is
the second bound on one enormous pull request, after the byte budget.

### The lexical ranker is in ShepherdCore, is always on, and is the fallback

`SearchRanker.rank(query:documents:vectors:)` is a pure function with no Apple dependency, so it
is unit-tested by `swift test` on the Linux runner (`docs/ARCHITECTURE.md`'s module rule). It is
BM25 (`k1` 1.2, `b` 0.75) over the weighted term frequencies above, with document frequency taken
over the candidate set — the inbox *is* the corpus, so no global IDF table is needed or wanted.

- **An exact reference always wins.** `owner/repo#123` and `#123` are recognised by `SearchQuery`
  and put that pull request first regardless of every score, because it is not a ranking question.
  A bare number is deliberately *not* a reference: `2026` and `500` are ordinary search words far
  more often than they are pull-request numbers.
- **The blend is half and half**: `0.5 × normalised BM25 + 0.5 × max(0, cosine)`, with the lexical
  half normalised against the best score in the candidate set so the two halves are on one scale.
  Even weights are the point — a blend is only worth having if the semantic half can lift a
  document the lexical half scored zero on, and if a literal match can still win against a
  stronger neighbour. Negative cosines are clamped: "pointing the other way" and "unrelated" are
  the same answer for ranking.
- **A document with no vector is ranked on its words alone**, scoring up to 0.5. That is the state
  during a first index pass and the permanent state on a Mac with no model, and it needs no second
  code path anywhere. Failure mode 4, closed.
- **A cut-off, and it is not a score threshold.** A result is kept only if it is an exact
  reference, *or* has a literal match, *or* has a cosine of at least 0.35. Without that last
  clause every query would return six rows. Failure mode 2, closed.
- **The order is total**: score descending, then node id ascending. Two sweeps of the same data
  cannot reshuffle the palette — the promise `InboxModel.priorityScore` makes about the list.

### Storage: one table, brute force, two gates

Migration **v3** adds `search_index`: `prID` (primary key, `REFERENCES pull_requests(id) ON DELETE
CASCADE`), `documentHash`, `modelIdentifier`, `dimensions`, `vector` (`Float32` BLOB, nullable),
`indexedAt`. `createV1` and `addV2` are untouched, as `DatabaseManager` requires.

- **The foreign key *is* the pruning.** A pull request that leaves the inbox takes its index row
  with it, inside the transaction the sweep is already doing. No second sweep, nothing to
  remember, and nothing that can leak an orphan.
- **Similarity is brute force in Swift.** A few hundred cosines over 512 dimensions is microseconds;
  a vector extension would be a build-system dependency, a migration story and a second query
  language bought for nothing. Revisit at tens of thousands of rows, which this inbox does not
  have.
- **`Float32`, host byte order**, because the bytes never leave the Mac that wrote them — the index
  is device state, it is not in the encrypted settings document, and it is dropped with the rest of
  the local data on sign-out. Read back with an alignment-safe copy, never by binding `Data`'s
  bytes to `Float` in place.
- **Two staleness gates, each with exactly one reader.** `documentHash` is persisted and decides
  whether an **embedding** has to be spent — a document whose hash matches keeps its stored vector
  however many sweeps have run. `sourceFingerprint` lives only in the in-memory corpus and decides
  whether the body and the diff have to be **read out of SQLite at all**; it covers the cheap
  fields plus the head commit, `updatedAt` and `detailFetchedAt`. Without the second gate every
  inbox write — every two minutes — would read every stored diff back to discover that nothing had
  changed. It is deliberately not persisted: it guards a corpus that is rebuilt at launch anyway,
  so a stored copy would have no reader.
- **The hashes are FNV-1a, not `Hasher`.** `Hasher` is seeded per process, so a stored hash would
  differ after every relaunch and every launch would re-embed the whole inbox. Nothing here is a
  security boundary; the property being bought is *change detection*.
- **The model identifier is stored beside every vector**, because vectors from two models are not
  comparable. A model change invalidates the index instead of silently ranking against a mixture.

### Indexing is opportunistic, batched and invisible

`SearchIndexCoordinator` (`@MainActor`, app target) holds the corpus and runs the passes. It is the
third coordinator of this shape, and the division of labour is `AutoMergeCoordinator`'s: every
decision is a pure value in `ShepherdCore`, the coordinator supplies inputs and performs effects.

- **The trigger is the rows a sweep wrote** — the same `onInboxRows` callback automatic merging
  uses (ADR 0018), for a related reason: the inbox observation is the one place that reports a
  change to what is *in* the inbox, including the change nothing else announces, a detail fetch
  storing a diff (it arrives as a moved `detailFetchedAt`).
- **A pass is low-priority, batched (20 pull requests) and yields between batches.** The
  composition — tokenising and hashing, real CPU work over as much as a few hundred kilobytes —
  runs in a detached task, off the main actor. The palette ranks whatever the corpus holds at that
  moment: a half-built index answers with the half it has rather than with a spinner. Failure
  mode 3, closed.
- **The review screen also announces a stored diff** (`ReviewModel.onDidLoadDetail`), which is a
  *promptness* measure and nothing more: the moved timestamp means the next ordinary pass would
  find it anyway. A feature that only worked because a screen remembered to announce something
  would quietly rot.
- **Cancelled and dropped on sign-out.** `search.reset()` drops the corpus in
  `signOutAndErase()`; the table goes with `eraseAllData()`, because the index is local cache in
  exactly the sense ADR 0006 means — and because it names the previous account's pull requests,
  which is the argument the auto-merge audit log makes.

### The setting is on by default, and the only intelligence-shaped one that is

Settings → Intelligence gains one card: a **Semantic search index** toggle, a line with what the
index holds (rows, bytes, when it was last updated — or why the model is unavailable, in the
model's own words), and a **Rebuild index** button.

Default-on is a deliberate break with ADR 0007's "off by default", and the argument is that the
reasons for off-by-default do not apply. The other tiers are off because they *send something
somewhere* or cost money. This one sends nothing, cannot send anything, costs some CPU in a
low-priority task and a few hundred kilobytes of SQLite, and is built from data the app already
downloaded. A user who has to discover a setting before ⌘K can find a pull request by its content
would mostly never discover it, and the feature would be paid for and not used.

Switching it off **empties the table** and leaves ⌘K searching titles, labels, repositories,
branches and authors on the lexical ranker — a switch named after an index that left a megabyte of
vectors on disk would be lying about the one thing it is named after. Re-enabling costs one local
pass.

The **switch** travels in `SyncedSettingsDocument.search` and in both directions of
`SettingsSyncApplier`, with a non-default fixture in `SettingsSyncTests` (ADR 0014's standing
obligation). It is a group of its own rather than a field of `intelligence`, because that group
carries a mode, a provider kind, an endpoint and a model — none of which this switch has or may
ever have. The **index** does not travel, for the reason the auto-merge ledger does not: device
state, rebuildable from local rows in seconds, and a bucket object carrying a megabyte of
embeddings per Mac would be absurd.

### Deliberately not in v1: `shepherd://inbox?q=…`

A `q=` parameter would not be an additive URL change: `DeepLink.inbox(filter:)` would gain a
payload, which touches the grammar, `urlString`, the round-trip tests, the CLI's argument grammar,
the README's URL table and ADR 0013's contract — for a feature whose value is *interactive*
ranking as you type. `shepherd inbox --search "…"` has the same problem and one more: the CLI
cannot show results (ADR 0013 deferred anything that must *return* data to a future XPC or
AppleScript decision). Both are roadmap items, and both stay out until there is a reason beyond
symmetry.

## Consequences

- The inbox gains the one question it could not answer, and the answer is instant, offline and
  private: everything ⌘K does happens between SQLite and the CPU on the user's own Mac.
- **The host list in `CONTRIBUTING.md` is unchanged.** This is the first feature that could
  plausibly have used the BYOK endpoint and does not; the impossibility is structural (no router,
  no URL, no key in `Features/Search/`), so it is a rule of the design rather than a default.
- `AppSettings` gained a setting, so it travels in `SyncedSettingsDocument` and in both directions
  of `SettingsSyncApplier` with a non-default fixture in `SettingsSyncTests` (ADR 0014). It is the
  second field in that document whose default is `true` — the menu-bar item is the other — so a
  document written by an older Shepherd must decode as "on", and does.
- The schema gained migration **v3**. `DatabaseSchema.allTables` gained a table, so
  "Sign out & erase" empties it with everything else.
- The palette's row model became an enum over two cases. Every exhaustive switch over it lives in
  one file, and the keyboard behaviour is unchanged because there is still exactly one ordered
  list.
- **Search quality is now a thing that can regress.** The corpus is the inbox, so a query's
  results depend on what else is open — which is correct for a review inbox and surprising if you
  expect a static index. The ranker is a pure function with unit tests over a fixed corpus, which
  is where a regression is caught.
- A Mac with no `NLEmbedding` gets a lexical inbox search, permanently and silently, with one line
  in Settings saying so. That is the whole of the degraded mode, and it is the same code path.
- Adding a field to the search document is one row in the table above plus a bump of
  `SearchDocument.schemaVersion`, which re-embeds the inbox by itself. Adding a *provider* for
  embeddings that is not on-device needs a new ADR, and it would have to overturn this one's
  central claim rather than quietly widen it.

## Amendment (2026-09-02): saved-reply suggestion reuses the embedder

The insert menu on a thread reply or an inline comment (`text.badge.plus`) now repeats the two
saved replies nearest to the thread's conversation at the top, under a **Suggested** header and a
divider, before the user's own full list. It is the first feature outside `Features/Search/` to
spend an embedding, and it is deliberately a *reuse* rather than a second system: the same
`EmbeddingProviding` seam, the same `NaturalLanguageEmbedder` actor, the same
`SearchVector.cosineSimilarity`. No language model, no `IntelligenceRouter`, no setting, no
migration — the vectors live in memory for the life of the app, keyed by a hash of the reply
*body* (the `id` is stable across edits on purpose, so keying on it would keep ranking an edited
reply as the text it used to be). This document's structural rule holds unchanged: no type in the
feature takes a base URL or a key, so the host list in `CONTRIBUTING.md` is untouched.

Three of the decisions above are re-applied at different numbers. The **cut-off** is the "never
confidently wrong" rule at 0.45 rather than the palette's 0.35, because the candidates are a
handful of short review-prose snippets in one voice instead of hundreds of mixed-register
documents, so their cosines sit higher and closer together and a relative "best two" would always
have an answer; below three saved replies no shortlist is offered at all, since "Suggested" would
be the whole list with a header on it. The **byte budget** is `SearchDocument`'s discipline
pointed the other way — `SavedReplyThreadBudget` caps a thread at ~2 KB with a per-comment cut and
fills it from the *newest* comment backwards, because what a reviewer is answering is the end of a
conversation. The **degraded state** is one code path once more: no model, no thread, too few
replies or nothing above the floor all produce an empty list, and an empty list means the plain
menu Shepherd already shipped. Nothing is inserted either — the only output is an ordering, and
the click on a menu row is still the reviewer's.
