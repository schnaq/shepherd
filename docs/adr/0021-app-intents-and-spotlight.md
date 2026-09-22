# ADR 0021: App Intents for Shortcuts and Siri, and pull requests in Spotlight

Status: Accepted (v1.x) · Date: 2026-09-02

## Context

ADR 0013 gave Shepherd a remote control: `shepherd://` URLs and a CLI that builds them. It works,
and it is the wrong shape for two of the places a Mac user now expects an app to be.

**Shortcuts and Siri want a typed vocabulary, not a URL.** A URL scheme is discoverable only from
documentation. Shortcuts asks the app what actions it has, what parameters they take, and which
values are valid; Siri needs a phrase; Spotlight's *action* results need the same metadata. All of
that is `AppIntents`, and none of it can be inferred from a `CFBundleURLTypes` entry. The
practical consequence is small but real: a user who wants "when I open my work Focus, show me the
pull requests waiting on me" has to know that `shepherd://inbox?filter=needs-my-review` exists and
wrap `open(1)` in a *Run Shell Script* action. That is a worse version of a thing the system does
properly.

**Spotlight wants an index, and it is the search a Mac user reaches for first.** ADR 0019 built a
very good search *inside* the app: ⌘K ranks the inbox semantically and lexically. It answers
nothing at all when Shepherd is not the front app, which is most of the time. ⌘Space is muscle
memory, and a pull request is exactly the kind of small named thing people look for that way.

Two more facts shape the design more than the request does.

**The routing already exists and must not be duplicated.** "Open this pull request" is not a
simple operation in this app. It consults the cache, fetches a single pull request from GitHub when
the cache does not have it, writes it to SQLite so the screen renders from the database (ADR 0006),
queues the whole request when it arrives before there is a session, and toasts by name when it
fails. That behaviour lives in `AppEnvironment.open(_ link: DeepLink)` (ADR 0013). Any surface that
grew its own version would be a second implementation of the awkward parts, and the second one is
always the one that forgets the queue-until-signed-in slot.

**Spotlight's index is not Shepherd's.** It lives outside the app's sandbox and outside its
database: it is system-wide, it is included in backups, it is queryable by other processes through
`CSSearchQuery`, and its default item lifetime is a month whatever the app thinks. Everything the
app puts there stops being governed by ADR 0006 the moment it is written.

Four failure modes have to be designed out rather than tested out:

1. **A verdict formed without a human.** An intent runs with no review screen in front of anybody
   and frequently from a voice request. "Hey Siri, approve schnaq/review#128" is a review submitted
   by somebody who has not read the diff — the exact thing ADR 0016 and ADR 0018 are careful about,
   and CONTRIBUTING.md states as a rule ("Shepherd never forms a verdict unattended").
2. **A second implementation of "open a pull request".** Six intents plus a Spotlight continuation
   is six and a half chances to reimplement the routing badly.
3. **Diffs and review text in the system index.** The whole app is built on "the code stays in the
   local database unless the user clicked". An export that carried a description, a diff hunk or a
   pending review comment into Spotlight would undo that quietly, for every pull request, with no
   click anywhere.
4. **An export that costs more than the feature is worth.** The inbox observation fires on every
   inbox write — a sweep that moved one `updatedAt`, an outbox drain, a detail fetch storing a diff.
   Handing Core Spotlight a few hundred identical items every two minutes, forever, is a genuine
   background-CPU regression on somebody's laptop.

## Decision

### The intents are a typed front for ADR 0013's grammar, and nothing else

Six intents in `Shepherd/Intents/`, app target only:

| Intent | Parameter | Routes to |
| --- | --- | --- |
| `OpenPullRequestIntent` | a `PullRequestEntity` | `DeepLink.pullRequest(repo:number:)` |
| `ShowInboxIntent` | `InboxFilterOption?` | `DeepLink.inbox(filter:)` |
| `SyncNowIntent` | — | `DeepLink.sync` |
| `OpenSettingsIntent` | `SettingsTabOption` | `DeepLink.settings(tab:)` |
| `StartFocusSessionIntent` | — | `AppEnvironment.startReviewSession()` |
| `GetReviewQueueIntent` | — | reads the local inbox; returns entities |

Every one of the first four builds a `DeepLink` and hands it to `AppEnvironment.open(_:)` — the
same call `onOpenURL` makes for a URL from the terminal, from Raycast or from an n8n *Execute
Command* node. So the cache lookup, the single-pull-request fetch, the queue-until-signed-in slot
and the failure toast have exactly one implementation, and an intent is a *type* over the grammar
rather than a second client of the app. One caveat: `OpenPullRequestIntent` needs the signed-in
session *before* it can form its link, because the entity carries GitHub's node id and only the
inbox rows can turn that into `owner/repo#number`; signed out, it fails with "not signed in" instead
of reaching the queue-until-signed-in slot, which the other three do reach. The two parameter enums mirror `InboxDeepLinkFilter` and
`SettingsDeepLinkTab` **by token**: each case's raw value is the string the URL grammar uses and the
conversion is `init(token:)`, so there is no second table to keep in step, and a test asserts the
two vocabularies are the same set.

`StartFocusSessionIntent` is the one exception and it is deliberate: the focus session has no
`shepherd://` command. The grammar is a public interface whose additions the CLI's argument parser,
its `--help` output and the README's URL table all restate (ADR 0013), so adding a command to it is
its own additive change with its own obligations — not something an App Intent may drag in as a
side effect. What it calls instead *is* the single implementation:
`AppEnvironment.startReviewSession()` is the method the Review menu, `r f`, ⌘K and the inbox
header's button all reach through a `PendingAction`, and it freezes its queue from the session's own
rows, so it does not care which surface asked.

`perform()` is `@MainActor` on every intent, because everything it touches is.

### No write intents. Not now and not as a checkbox

There is no `ApproveIntent`, no `RequestChangesIntent`, no `MergeIntent`, no `SubmitReviewIntent`
and no `DelegateIntent` — and the reason is not "not yet". An intent is performed with no review
screen in front of the user; the Siri path has no screen at all. A verdict formed there is a verdict
formed by somebody who has not looked at the diff, which is the line CONTRIBUTING.md draws and the
line ADR 0018 was careful to stay inside: automatic merging is acceptable *only* because it records
a decision a human already made, and it still goes through the ordinary outbox with the head commit
it judged as a precondition. A Siri phrase has no such decision behind it. Anything that would let
an intent approve, request changes, comment, merge or start a delegation is a new ADR, not a new
file in `Intents/`.

The read-only side is fine and is where the value is. `GetReviewQueueIntent` answers "how many pull
requests need me, and which ones" from the local database — no GitHub call, so it is safe on a
five-minute automation — and returns the *same* ordered queue the menu-bar badge, the focus session
and the morning digest read (`SmartView.needsMyReview` plus `InboxModel.prioritySorted`), because
four surfaces disagreeing about what is waiting would undermine all four.

### `PullRequestEntity` is a handle, and it carries metadata only

`PullRequestEntity` is `id` (the GraphQL node id, Shepherd's key everywhere) plus five exposed
properties: slug, title, author, CI state, provenance label. `PullRequestEntityQuery` resolves ids
against the cached inbox rows, suggests the current review queue, and — as an `EntityStringQuery` —
searches through `SearchIndexCoordinator.results(for:limit:)`, the ⌘K ranker, so Shortcuts' own
search field is the app's search field and is on-device for the reason ADR 0019 gives.

Two properties of the type are decisions:

- **It is a handle, not a snapshot.** A shortcut stores the id and asks for the entity again next
  week; the query re-reads today's row. `OpenPullRequestIntent` therefore takes the repository and
  number from the row it just resolved, and a shortcut built against a pull request that has since
  been merged says so rather than opening whatever now holds that number.
- **It carries nothing written in confidence.** No description, no diff, no review comment, no
  draft. The entity leaves the app: Shortcuts can drop it into any other action, including a *Get
  Contents of URL* the user built. "A shortcut that mails my pull-request diffs somewhere" must not
  be assemblable out of Shepherd's own actions, and the way to guarantee that is for the fields not
  to exist.

`ShepherdShortcuts` (`AppShortcutsProvider`) offers four phrases out of the box — the review queue,
the count, a sweep, the focus session. Navigation and reads, again: a Siri phrase that could approve
a pull request is precisely the failure mode above.

Nothing is needed in `project.yml`. XcodeGen globs `Shepherd/` into the app target and `ShepherdCLI/`
into the CLI, so `Shepherd/Intents/` lands in the app and only in the app; App Intents metadata
extraction needs no Info.plist key and no build setting, and `ShepherdKit` stays free of
`AppIntents` — which matters, because it has to keep compiling on Linux.

### Spotlight gets titles and metadata, and that is structural

Every pull request in the inbox becomes one `CSSearchableItem`: unique id = the node id, domain =
`pullRequests`, `title` = the pull-request title, `contentDescription` =
`owner/repo#123 · author · CI state`, keywords = labels + the agent's name + owner + repository
name. That is the complete list, and it is the same metadata GitHub shows to anybody who can see
the pull request.

What may be exported is a **type**, not a rule: `SpotlightItemFields` has four fields and no way to
express a body, a diff or a comment, so "no diffs in Spotlight" is not a convention somebody has to
remember when adding a field. It is also the seam that makes the mapping testable —
`CSSearchableItemAttributeSet` is an `NSObject` that is awkward to assert against and impossible to
build on a Linux runner.

Two details are load-bearing:

- `contentType: .content`, not a document or URL type: a pull request has no path, and claiming a
  file type would invite Spotlight to offer "Reveal in Finder".
- `expirationDate = .distantFuture`. Core Spotlight expires items after a month by default, which
  is right for a mail client and wrong here — Shepherd knows exactly when a pull request stops
  being interesting (it leaves the inbox) and deletes it then. The default would mean long-lived
  pull requests silently vanishing from ⌘Space while still sitting in the inbox.

### One export path, driven by the rows a sweep wrote, diffed so a quiet sweep is free

`SpotlightIndexer` runs on the same `onInboxRows` callback automatic merging (ADR 0018) and the
search index (ADR 0019) run on: that observation is the one place a change to the *content* of the
inbox is reported. It holds the fields it last wrote and diffs against them
(`SpotlightExportPlan`), which is what makes the common case free — the callback fires on every
inbox write, and almost none of those writes change a title, an author, a label or a CI state, so
an unchanged sweep costs one dictionary comparison and **no framework call at all**. What is left
is a low-priority `Task` handing `Sendable` values to a `nonisolated` seam in batches of fifty,
yielding between them; no `CSSearchableItem` ever crosses an isolation boundary, which is also what
keeps it compiling under Swift 6 strict concurrency.

The baseline is advanced only for a batch Spotlight accepted. An optimistic update would turn one
transient failure into a permanently missing item, because nothing would ever mark it as needing an
export again.

The baseline is deliberately **not persisted**. The first pass after a launch therefore re-writes
every item — one batched, idempotent call, once. The alternative is an on-disk record of what is in
an on-disk index, and the failure mode it buys is the worse one: a stored map that disagreed with
Spotlight (a restore from backup, a reindexed volume) would leave items missing with nothing to
trigger a repair.

A pull request that leaves the inbox is deleted. Signing out and switching the toggle off delete
the **whole domain** in one call, which is why there is one domain: the previous account's pull
requests, in a system-wide index the app does not own, are not something a switch may leave behind.

### Opening a Spotlight result is the deep-link path

`onContinueUserActivity(CSSearchableItemActionType)` sits beside `onOpenURL` in `ShepherdApp` — the
same kind of arrival, something outside the app naming a pull request — and ends in the same
`DeepLink.pullRequest`. Spotlight hands back only the identifier, so the repository and number are
resolved out of the cached rows through one pure function (`PullRequestIdentifierLookup`), the
mirror image of the lookup a `shepherd://pr/...` link uses. An item whose pull request has left the
inbox is a stale item rather than a bug, and it gets a sentence.

`IndexedEntity` — the macOS 15 integration that lets an `AppEntity` be donated to Spotlight
directly — is deliberately not used. It would couple the export to the entity's shape and to
Shortcuts' own indexing schedule, and the export needs to be driven by the inbox observation and
diffed against what it wrote. Plain `CSSearchableIndex` is the smaller, more predictable thing.

### One synced toggle, on by default, in Settings → Intelligence

"Show pull requests in Spotlight", next to the search-index card, **on** on a fresh install. The
argument is ADR 0019's: the things that are off by default (ADR 0007) are off because they send
something somewhere or cost money, and this does neither — it is built from rows the sweep already
wrote and it makes no request. A user who presses ⌘Space and types a pull-request title expects to
find it.

It is a *separate* switch rather than a mode of the search index, because the two answer different
questions: that one is about work done inside the app's own database, this one is the only thing on
the tab that puts pull-request data outside it. The card says exactly that, in the UI and not only
here, because "what of mine ends up in the system index" is a question a user is entitled to have
answered where they are standing.

It travels in `SyncedSettingsDocument.search` beside the index switch, in both directions of
`SettingsSyncApplier`, with a non-default fixture in `SettingsSyncTests` (ADR 0014). The items
themselves cannot travel and do not: Spotlight's index belongs to the Mac it is on, and each Mac
rebuilds its own from local rows.

## Consequences

- Shepherd becomes scriptable in the two ways macOS users actually script: a Shortcuts action with
  typed parameters, and ⌘Space. Together with ADR 0012 and ADR 0013 the automation story is now
  complete in both directions without Shepherd listening on a port.
- **The intent identifiers are a public interface**, exactly as the URL grammar is. A user's
  shortcut stores the intent's type name and its parameters, so renaming `ShowInboxIntent` or
  dropping a case from `InboxFilterOption` breaks somebody's automation silently. Additions are
  free; removals need a decision.
- App Intents run in the app's process, so an intent needs the app. Every UI intent sets
  `openAppWhenRun = true`, and so does `SyncNowIntent` — a sweep needs a session, and a
  background-launched process has read no Keychain, so the alternative was a shortcut that reported
  success having done nothing. `GetReviewQueueIntent` is the only intent that does not open the app,
  which is the point of it; the cost is stated rather than papered over, and when Shepherd is not
  running it says so instead of answering a reassuring zero.
- The dependency hand-off is a weak static (`IntentBridge`), because the system creates intents and
  there is no initialiser to pass a container through. It throws rather than force-unwrapping: the
  state where there is no container is reachable, and a crash there is one the user cannot connect
  to anything they did.
- Spotlight results exist for pull requests the user can no longer open without a fetch. A row that
  the sweep pruned is deleted from the index, but a result clicked in the second between the prune
  and the next pass resolves to nothing and gets a toast. Acceptable, and better than teaching the
  export about rows the inbox no longer has.
- `Shepherd/Intents/` is the second folder that owns an Apple-only framework exclusively
  (`AppIntents`, `CoreSpotlight`), joining `UpdateController` (Sparkle), `DiagnosticsReporter`
  (MetricKit) and `EmbeddingProvider` (NaturalLanguage). `ShepherdKit` gains nothing and still
  builds on Linux, which is why the two testable halves — the export mapping and the diff — are
  plain structs in the app target rather than framework subclasses.
- The Spotlight export is the first thing Shepherd writes **outside** its own database that is not a
  request the user made. It is metadata only, it is deletable in one call, and the toggle deletes
  it — but it does mean `CONTRIBUTING.md`'s privacy rules gained a line, because "the code stays
  local" now has a neighbour: "and the titles stay local unless this switch is on".

## Amendment (2026-09-03): a read intent that runs the on-device model

Additive, and nothing above it changes: still six navigation-and-read intents plus this seventh,
still no write intent, still `PullRequestEntity` as a metadata-only handle, still one Spotlight
export driven by `onInboxRows`, still one toggle. What is new is that an intent may now run a
*model* (`docs/plans/apple-intelligence-v2.md` §3.H): `SummarizePullRequestIntent` takes a
`PullRequestEntity` — or nothing, in which case it resolves to the first row of the review queue —
and answers with `ProvidesDialog` for Siri to speak and `ShowsSnippetView` for the card, plus three
English phrases in `ShepherdShortcuts` (both spellings of *summarise*, because Siri matches a
phrase literally).

**Tier 2 is the ceiling, and it is the ladder that says so.** The failure mode this addition has to
be designed against is not a verdict — it summarises, and a summary approves nothing — it is
*where the pull request goes*. An intent runs with no review screen in front of anybody and, from
Siri, no screen at all, which is exactly the situation ADR 0007 answers with "unattended means
on-device only". So `IntelligenceRouter.summary(for:onDeviceOnly:)` gained a parameter whose `true`
makes the ladder **skip the cloud rung entirely**, the same mechanism and the same reasoning as the
delegation brief's rule about a colleague's comment: a request that may not travel is never
*offered* to a provider, rather than being asked nicely not to look. A user with an API key
configured — the one configuration where this could go wrong quietly — gets the on-device answer or
one sentence, *"Apple Intelligence is not available on this Mac."*, and a test asserts the cloud
tier was not called at all rather than merely that its answer was not used.

**The summary is a result, not a property.** It is spoken once and drawn once. It is not stored on
the entity, which keeps exactly the five exposed properties this ADR gave it; it is not exported to
Spotlight, whose `SpotlightItemFields` still has nowhere to put it; and it is not written to the
database. So the guarantee this ADR made about the entity — that "a shortcut that mails my
pull-request diffs somewhere" is not assemblable out of Shepherd's own actions — is unaffected,
because the thing a shortcut can pass on is still the handle and not the prose.

**It reads, and it never fetches.** Two consequences follow from that being a rule rather than a
preference. The digest is built from the cached pull request, so the intent is as safe on a
five-minute automation as `GetReviewQueueIntent` is. And a row whose *detail* has never been
fetched — a sweep writes an inbox row with no body, no diff and no checks — is not summarised at
all: `detailFetchedAt` is the one column a detail fetch sets and a sweep does not, so it is the
honest answer to "has this been opened once", and the intent says *"Shepherd has not fetched this
pull request yet — open it once in the app."* rather than producing two confident sentences about a
title. A digest built from nothing would be the worst kind of answer here: it would sound exactly
like a real one.

Consequences, beyond the ones already stated:

- **The intent identifier is a public interface**, as every identifier here is:
  `SummarizePullRequestIntent` and its `pullRequest` parameter are what a user's shortcut stores.
- `IntentBridge` gained one accessor (`requireSummarizer()`) beside `requireEnvironment()` and
  `requireSession()`, and it hands over a `Sendable` seam — the router snapshot plus a read closure
  over the database — rather than the container, so nothing the system runs the intent on reaches
  back into `AppEnvironment`. The seam is also what makes the whole answer testable without Siri,
  a window or a Mac with Apple Intelligence switched on.
- The German phrases are still the `AppShortcuts.xcstrings` follow-up ADR 0022 lists in the
  roadmap. Until then the English phrases work on a German Mac, because Siri matches them by the
  app's name; the intent's *title*, its short title and its four new spoken sentences are ordinary
  catalog rows and are translated in this commit (its parameter title and its fifth sentence,
  *"Nothing needs your review."*, are rows the existing intents already produced).
- Five of the six spoken sentences a run can produce are fixed copy and one is the router's own
  formatted failure. There is deliberately no "and here is why" path to Settings: a voice answer
  has no screen to link to, and the card beside the toggle already carries the three-way
  Apple Intelligence reason for the reader who is looking at it.

## Amendment (2026-09-22): Siri and Apple Intelligence can point at a pull request — still nothing writes

[ADR 0038](0038-macos-27-floor.md)'s item 3 proposed relaxing "No write intents" behind an
off-by-default setting. The founder decided against it on 2026-09-22: **the section above stands
unchanged**, and what lands is the read half, which needs no new intent at all.

- **Notifications name their pull requests.** `NotificationPayload.pullRequestIDs` carries the
  node ids of the pull requests a notification is about, and `NotificationManager.present(_:)`
  sets them as `UNMutableNotificationContent.appEntityIdentifiers` (the
  `_UserNotifications_AppIntents` overlay, macOS 27). Every notification that concerns a pull
  request carries it — review requested, checks failed, a draft conflict, an automatic delegation
  or its cap, an automatic merge, merge-when-green queued or dropped; the digest is about no single
  one and carries none. The system can then hand "this" to the intents that already exist —
  *Open*, *Summarize* — with no screen scraping and no new vocabulary.
- **Spotlight results are the same entity.** Each exported `CSSearchableItem` sets
  `relatedAppEntityIdentifier` to its `PullRequestEntity` (the unique identifier already is the
  node id), so a Spotlight result and a Shortcuts parameter are one thing.
- **The system can ask for its index back.** `PullRequestEntity` conforms to `IndexedEntity` with
  `hideInSpotlight == true` — the exporter's items are the Spotlight representation, and a second
  one would duplicate every result — and `PullRequestEntityQuery` to `IndexedEntityQuery`. Its two
  re-index hooks call `SpotlightIndexer.reindex(_:rows:)`, which forgets those ids and runs the
  ordinary plan over today's rows: the same diff, batching and failure handling as a sweep, nothing
  written while the export is off, and an id that has left the inbox not written back.

Not adopted, with the reason: `OwnershipProvidingEntity` is not a confirmation mechanism (ADR 0038
guessed it was) but a classification — `unknown` / `shared` / `public` — and Shepherd's rows do
not carry a repository's visibility, so any answer but the default would be a guess about somebody
else's repository. It becomes worth adopting when the inbox query fetches `isPrivate`.
