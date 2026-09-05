# ADR 0027: Track record and trust lanes — the lane gate is CI, size and sensitive paths; history informs it, never decides it

Status: Accepted (v1.2) · Date: 2026-09-03

## Context

The maintainer interview behind [`docs/plans/agent-fleet.md`](../plans/agent-fleet.md) named
*judging how much attention a pull request deserves* as the first of the four costs of a fleet of
coding agents. Ten to forty agent pull requests a week arrive in one inbox and are read in one
order, and most of the reading is spent working out which of them could have been a glance.

The interview also gave the answer, and gave it narrowly. Asked when a pull request may be a
**short look**, the answer was: *only* when CI is green and the diff is small. Asked where a track
record should come from, the answer was: load GitHub's history retroactively, the closed pull
requests of the last ninety days. Those are two different questions, and the temptation is to let
the second one answer the first — "this agent has merged twenty-three things cleanly, so wave this
one through". That is the temptation this ADR exists to design out.

Three facts about the data shape everything below.

**Shepherd's search reads open pull requests only.** `InboxQuery.openPullRequestPrefix` is
`is:pr is:open archived:false`, and every facet of the sweep is built on it. A track record is
made of *closed* pull requests, so this is the first read in the app that looks past the inbox —
and the whole point of a badge that says "23 merged" is that the twenty-three are gone.

**The inbox row cannot answer "is anything sensitive in here".** `PullRequestSummary` carries
counts — `changedFiles`, `additions`, `deletions` — and the check rollup, but no paths. Paths
arrive with a detail fetch and live in `changed_files`. So the sensitive-path exclusion is
knowable for a pull request somebody has opened, or that a sweep has fetched, and *unknowable*
until then.

**Every derived table so far is pruned by a cascade onto `pull_requests`.** `search_index`
(ADR 0019), `triage_verdicts` (ADR 0023) and `review_snapshots` (ADR 0028) are all about a pull
request in the inbox and all disappear with it. An outcome is the opposite: it is written at the
moment the pull request leaves.

## Decision

### Two lanes, and the gate has exactly three conditions

`TrustLane` (`ShepherdCore/Trust/`) has two cases — `shortLook` and `fullReview` — and the inbox
shows them as a facet in the rail, beside Risk. A pull request is a **short look** only when all
three hold:

- the head commit's check rollup is `success` (so `none` — nothing ran — is never green, and
  neither is `pending`),
- the diff is within both thresholds (defaults: **≤ 5 files**, **≤ 120 changed lines**, where
  changed lines are `additions + deletions`),
- and **no sensitive path** is touched: a CI workflow, an auth/secret/credential-shaped path, a
  schema migration, or a **deleted test**.

Everything else is a full review. The asymmetry is deliberate: *short look* is the narrow claim,
so anything unknown lands in the wide lane. That is also the answer to the unknowable case above —
a pull request whose diff Shepherd has never fetched is a full review, because Shepherd cannot
show that nothing dangerous is in a diff it does not have.

The sensitive-path classifications are **`FilePrioritizer`'s own** (`securityPathHints`,
`category(of:)`), not a second opinion about the same paths, so the lane and the file order cannot
come to different conclusions about `Sources/Auth/Token.swift`. Two shapes the prioritiser scores
but does not name — a workflow and a migration — are named in `TrustSensitivePaths`, because the
gate has to be able to state them.

### The rule is a type, not a comment

```swift
public struct TrustLaneInput {
    public var checkState: CheckRollup.State?
    public var changedFiles: Int
    public var changedLines: Int
    public var sensitivePaths: Bool
}

TrustLane.classify(_ input: TrustLaneInput, configuration: TrustLaneConfiguration) -> TrustLane
```

Four values and two thresholds. There is nowhere in that signature for a history to hide, and
`ShepherdCoreTests` asserts it reflectively — the same mechanism ADR 0023 uses for its verdict
rule, for the same reason: the failure mode is a future change, and a rule nobody can see being
broken is not a rule.

The thresholds are `TrustLaneConfiguration`, which **clamps** both values on construction
(`1...100` files, `1...5000` lines). A threshold of zero would empty the short lane permanently and
read as a bug rather than as a setting, and a document from a newer build that widened the range
cannot make this build's short lane unreachable.

### The track record is counting, and it is read by two things

Migration **v6** adds one table:

```sql
CREATE TABLE pull_request_outcomes (
    prID TEXT PRIMARY KEY NOT NULL,
    repoFullName TEXT NOT NULL,
    repoOwner TEXT NOT NULL,
    repoName TEXT NOT NULL,
    number INTEGER NOT NULL DEFAULT 0,
    title TEXT NOT NULL DEFAULT '',
    agentName TEXT,
    authorLogin TEXT NOT NULL DEFAULT '',
    openedAt DATETIME NOT NULL,
    closedAt DATETIME NOT NULL,
    merged INTEGER NOT NULL DEFAULT 0,
    mergeCommitOid TEXT,
    revertedByPRID TEXT,
    firstPushCIGreen INTEGER,
    reviewRounds INTEGER NOT NULL DEFAULT 0,
    changedLines INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'sync'
);
CREATE INDEX idx_pull_request_outcomes_repo_agent_closedAt
    ON pull_request_outcomes(repoFullName, agentName, closedAt);
```

Five decisions live in that DDL.

**There is no foreign key and therefore no cascade.** This is the one derived table that is *not*
about a pull request in the inbox, so the pruning every other one relies on would delete exactly
the rows this feature is made of. The repository travels by value for the same reason.

**`prID` is the primary key**, so both writers upsert: a pull request the backfill imported and the
sweep later saw close again is one row, and running the backfill twice changes nothing.

**`firstPushCIGreen` is nullable and that is load-bearing.** "The first push was red" and "nothing
is known about the first push" are different facts. A `0` for the second would put a red push on
somebody's badge, so the rate `TrackRecord.firstPushGreenRate` is `nil` when its denominator is
empty and the badge then leaves the clause out rather than printing "0 %".

**`number`, `title` and `mergeCommitOid` are stored although nothing counts them.** Revert
detection is text — `Revert "…"` in a title, `This reverts commit <sha>` in a body — and a revert
that closes today pointing at a pull request last month's backfill imported can only be linked if
the three things a title or a body can name are still on disk. This is what makes the plan's "or
already stored" work rather than "or in the same page".

**`source` says which writer produced the row**, and a value this build cannot read degrades to
`sync` rather than failing the fetch: nothing counts on it, and losing a repository's history to
one unfamiliar word would be a far worse answer.

`TrackRecord.compute(outcomes:subject:repo:since:)` is the pure counting: merged, closed unmerged,
reverted, the first-push rate and the median number of change-requesting rounds, over one author in
one repository since one date. A **reverted pull request is still counted as merged** — it *was*
merged, and the revert is the second fact rather than a correction of the first.

### Written from two places, read once each

**The sweep.** `SyncEngine.runSweep()` already knows the exact moment: the list of pull requests
the prune actually removed, which is what `SyncEvent.prMerged` is emitted from. For each of those,
one GraphQL read of that pull request by number (`GraphQLDocuments.closedPullRequest`) gives
`merged`, `closedAt`, the change-requesting review count, the first commit's rollup and the text
revert detection needs — everything a row holds, in one request. Deliberately **not**
`pullRequestDetail(repo:number:)`: its six REST reads are five too many for a pull request nobody
is going to open, and none of them carries `merged` or `closedAt` anyway.

It goes through two ports of its own (`OutcomeRecording`, `ClosedPullRequestReading`, handed over
as one `OutcomeCapture`) so ShepherdSync keeps building and testing on Linux against fakes, and an
engine built without them behaves exactly as it did before. Three properties: the store is asked
first, so a pull request that already has a row costs no request; the reads are sequential, because
a Monday-morning sweep that sees eight merges must not fire eight requests at the secondary rate
limit; and **every failure is swallowed** — not even a `syncFailed` event — because the user did
not ask for this and a badge one pull request behind is worth nothing next to a sweep that reported
itself broken.

**The backfill**, from Settings → Automation → *Load track record*. Per repository the inbox
already knows — no listing call; Shepherd knows which repositories the user reviews in because it
is syncing pull requests from them — it runs
`is:pr is:closed archived:false repo:{owner}/{name} closed:>{90 days ago}` through the *same*
`search(type: ISSUE)` connection the sweep uses, so it inherits the paging, the retry, the
`Retry-After` backoff, the rate-limit snapshot and the request log rather than growing a second
read path. At most **500 pull requests per repository** (five pages of a hundred), at `.utility`
priority, cancellable between pages, with a progress line ("konduit: 120 of about 340") and one
line per failed repository. `TrackRecordBackfill` (`ShepherdSync`) is the pager and nothing else.

**Conditional requests.** A GraphQL request cannot be keyed on its URL — one endpoint, one URL,
every document — so this one read names its own cache key (repository, window, cursor) and the
entry is stored only when GitHub actually sends a validator. A page whose `ETag` comes back
unchanged is answered from the local cache; a page with no validator is simply not cached, which is
a missed optimisation and never a wrong answer.

**Reverts** are linked once per repository rather than once per page, because a `Revert "…"` can
appear in an earlier page than the pull request it undoes — which is exactly the pair a "2
reverted" is made of. Matching is by merge commit, then by `#number`, then by exact title; only
merged pull requests can be reverted, only within one repository, and only by a pull request that
closed after them.

### The badge informs, and there is a test for that

Beside each agent's name, on the provenance chip:
`Claude Code · this repo · 23 merged · 2 reverted · CI green first push 78 %`. The chip carries the
two counts, the popover carries the rest plus the line that answers the three questions a count
like this raises — **"this repo · last 90 days · on this Mac"**. A row whose author has no closed
pull requests in the window gets **no badge at all**, and its provenance chip keeps the agent
palette's own colour.

The record does exactly two things beyond the badge:

- it **colours the provenance chip** — amber when something was reverted, green for a settled
  record (at least five merges *and* most first pushes green), the muted secondary otherwise,
  because three merges are not evidence of anything and a colour that implied they were would be
  the feature quietly becoming a grade;
- it is the **secondary sort key inside a lane**: rows the primary order tied are ordered by merged
  count, descending. It never moves a row across a lane, because the sort does not know about
  lanes.

**It never gates.** `TrustLane.classify`'s input type cannot express a history (asserted
reflectively above), and auto-merge (ADR 0018), bulk triage (ADR 0015) and auto-delegation
(ADR 0016) do not read the table or the types — asserted by the same reflective test that carries
ADR 0023's verdict rule, extended to `TrackRecord`, `PullRequestOutcome`, `ClosedPullRequest` and
`TrustLane`. Merging on a track record would be Shepherd forming a verdict, which is the line
ADR 0018 spent an ADR refusing to cross.

### What travels and what does not

The two **thresholds** travel (ADR 0014): `SyncedSettingsDocument.TrustGroup.laneConfiguration`,
both directions of `SettingsSyncApplier`, a non-default fixture in `SettingsSyncTests`. "Small" is
a claim about the repositories a person works in and belongs on both their Macs.

The **history** does not, for ADR 0019's reason: it is device state rebuilt from a read any Mac can
make, it can be several hundred rows, and a bucket object carrying one Mac's ninety days of closed
pull requests would be absurd. So a second Mac gets the same lanes and its own badges — which is
why the popover says "on this Mac" — and *Clear history* in Settings empties the table on the Mac
it is pressed on.

## Consequences

- **One new read, no new host.** The closed-pull-request search and the single-pull-request read
  are `api.github.com`, the host Shepherd already talks to, through the same client. No outbox
  action, no webhook event, no telemetry, and nothing about this is a write.
- **The lane is honest about what it does not know.** A pull request whose diff has not been
  fetched is a full review, so a freshly synced inbox starts with everything in the wide lane and
  rows move into the short one as their diffs arrive. That is the right way round: the alternative
  is promising a glance at something nobody has looked at.
- **The badge is retrospective and says so.** Ninety days, one repository, one Mac. It cannot see
  a revert whose text names nothing, it cannot see work in a repository that is not in the inbox,
  and after *Clear history* it says nothing at all until the next backfill.
- **The outcome table outlives its pull requests, and therefore has to be swept by hand.** There is
  no cascade; what bounds it is the ninety-day window every read applies and the 500-per-repository
  cap on the backfill. Rows older than the window stay on disk until *Clear history* or
  "Sign out & erase" — a few tens of kilobytes, and the price of being able to count at all.
- **`prID` as the primary key means the two writers can disagree, and the later one wins.** The
  sweep's own read of a pull request it watched close is the more complete of the two, and it
  overwrites the backfill's. The one field that survives a re-import is `revertedByPRID`, because
  the link is discovered separately and a second backfill must not un-revert anything.
- **Adding a fourth lane condition is one field in `TrustLaneInput` plus one check.** Adding a
  condition that could *widen* the short lane — history, an author allow-list, a label — needs a
  new ADR, because "the gate is CI, size and sensitive paths, and nothing else" is the whole reason
  this one is acceptable.

## Amendment (2026-09-05): the backfill stays manual, and the inbox offers it once

The decision above is unchanged: the backfill reads up to five hundred closed pull requests per
repository, the user did not ask for it, and it therefore runs only when somebody presses a
button. What this ADR did not settle is how anybody finds out that the button is there. It is on
the second card of the Automation tab of a Settings sheet, so for a reviewer who never opened that
sheet the badge, the LANES rail and the whole feature were not switched off — they were invisible,
which is worse, because there is nothing visible to switch back on.

So the inbox makes the offer, once, in the place the badges would appear: a notice above the list
with one sentence about what it unlocks and one about what it costs, a *Load track record* that
starts the run and a *Not now* that ends the offer. It is shown under exactly four conditions —
the first sweep has come back, at least one row in the inbox was written by a detected agent,
nothing is stored yet, and the offer has not already been answered — and those four are a pure
function with a test per branch (`InboxModel.showsTrackRecordNotice`) rather than a chain of `if`s
inside a view, because three of the four are states that are awkward to reach by hand in a window.
A run that is *in flight* is deliberately not one of the conditions: it stores nothing until it
finishes, so the notice stays up by itself and can carry the progress line rather than vanishing
under the press that started it.

**One run, not two.** The repositories to read, the reader and the store moved out of the Settings
tab and onto `AppEnvironment.startTrackRecordBackfill()`, which both surfaces call, and the
progress both of them show is `TrackRecordCoordinator`'s — the coordinator that owns the run. So
starting a backfill from the inbox and then opening Settings shows one run at one position, which
is the property a second copy of "which repositories, read by what, stored where" could not have
kept.

**The dismissal does not travel**, and that is not an exception to ADR 0014's obligation but the
category `digestLastDeliveredAt` and `settingsSyncLastUploadAt` are already in: device state that
lives in `AppSettings` because it is one flag with no rules attached. Nothing about it is a
preference — it records that a hint has been read on this Mac. The second half of the argument is
this ADR's own: the thing the hint offers is the history, which is kept off the wire here as
device state a second Mac rebuilds by pressing the same button there, so a dismissal that
travelled would switch the offer off on exactly the Mac that still has no track record and no
other way of learning it could have one. It is stored beside the two thresholds in `AppSettings`
and deliberately nowhere in `SyncedSettingsDocument`.
