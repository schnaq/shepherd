# Managing the herd — reviewing a fleet of coding agents

Status: done (v1.0.0), see ADR 0026–0030 and ROADMAP v1.2, all items ticked · Date: 2026-09-03 ·
Source: maintainer interview 2026-09-03 · Scope: v1.2

Shepherd v1 reviews **one** pull request well. The interview that produced this plan was about
the next problem: a solo maintainer whose pull requests come from **Claude Code sessions, local
and remote**, ten to forty a week across repositories, who loses time on four things — judging how
much attention a pull request deserves, checking what the agent *claims*, re-reading whole pull
requests after every round, and losing the thread between repos. This document turns the
interview's answers into features, in the order they were ranked, on the data Shepherd already
holds.

Companion to [`apple-intelligence-v2.md`](apple-intelligence-v2.md): where a feature below needs a
model, it reuses that plan's plumbing (tier ladder, streaming, structured twins, the on-device
budget) and its rules — hints, never verdicts; unattended means on-device only; every read tool is a
read. Most of this plan, though, is **tier 1**: deterministic, local, testable on Linux.

---

## 0. What the interview decided

| Question | Answer | Consequence for the design |
|---|---|---|
| Where do the pull requests come from? | Claude Code, local and remote sessions | Every head commit carries `Co-Authored-By` and `Claude-Session:` trailers — provenance *and* a return address are already in the data |
| Volume | 10–40 agent pull requests a week | Triage matters; fleet dashboards do not (yet) |
| Biggest costs | Judging trust · checking claims · re-reading after a round · context switching | The four features in §2, in that order |
| Who is this for | A solo maintainer | No roles, no approvals workflow, no audit export in this round |
| First four | Claims vs. Evidence · Trust lanes · Since-my-review diff · Feedback loop to `CLAUDE.md` | §2.A–D; the fifth pick, the session back-channel, is §2.E |
| Claims to check first | "Tests run / added" · "Only X changed" · "No breaking changes" · "Fixes #N" | All four, §2.A |
| Trust history source | Load GitHub history retroactively (closed pull requests, last 90 days) | A one-time backfill plus incremental sync, §2.B |
| When may a pull request be a short look? | **Only** when CI is green and the diff is small | The lane gate is the hard heuristic; history *informs* (badge, sort), it never gates |
| How does the session get a review comment? | Claude Code Remote API, session id from the trailer | §2.E, with the auth constraint of ADR 0011 spelled out |
| How does a `CLAUDE.md` rule arrive? | As a draft in the delegation sheet; the local agent opens the pull request | §2.D reuses ADR 0011's worktree flow; Shepherd never commits to a repo itself |

Rejected for now, recorded so they are not re-proposed without a new reason: a team/roles model,
an audit export, cost dashboards, an agent leaderboard. A solo maintainer needs none of them; the
data model below does not preclude them.

---

## 1. What already exists to build on

| Piece | Where | Used by |
|---|---|---|
| Provenance detection (`human` / `agent(name)`) from bot type, login allowlist, branch names and commit trailers | `ShepherdCore/Agents/AgentDetector.swift`, `AgentRegistry.swift`, ADR 0008 | A, B, E |
| `CommitInfo.trailers` parsed from every head commit | `ShepherdCore/Models/CommitInfo.swift` | E (the `Claude-Session:` return address) |
| `PullRequestDetail`: body, files with `patch`, review threads, timeline, check runs, commits | `ShepherdCore/Models/PullRequest.swift`, GRDB | A, C |
| `FilePrioritizer` risk hints ("touches auth", "deletes tests", lockfile-only, generated) | `ShepherdCore/Heuristics/` | A, B |
| `PatchReconstructor` (unified diff → before/after) and the Monaco bridge | `ShepherdCore/Review/PatchReconstructor.swift`, `Shepherd/Features/DiffViewer/` | C |
| Local delegation to the coding-agent CLI in a worktree, `DelegationContext` | `Shepherd/Features/Delegation/`, ADR 0011 | D, E |
| Saved-reply suggester: on-device sentence embeddings, cosine ranking, per-snippet cache | `ShepherdCore/Review/SavedReplySuggestion.swift`, `Features/Review/SavedReplySuggestionCoordinator.swift` | D (recurring-finding detection) |
| Structured triage verdict per pull request (kind, risk, reason) and the Risk facet | `ShepherdCore/Triage/`, `Features/Triage/`, ADR 0023 | B (a lane input) |
| Outbox for every write; nothing writes outside it | `ShepherdCore/Models/Outbox.swift` | Constraint for all: no feature here adds a write |
| GitHub search prefix `is:pr is:open archived:false` — **open only** | `GitHubKit/GraphQL/GraphQLDocuments.swift:25` | B needs the first read of *closed* pull requests |

---

## 2. Features, in the interview's order

Each: the story, the data, the rule, the UI, the tests, effort (S ≤ 2 days, M ≤ 1 week,
L ≤ 2 weeks), and the ADR.

### A. Claims vs. Evidence

**Story.** Above the description, a card lists what the pull request *says* and what Shepherd
*found*: "Tests added — ✓ 2 test files changed, CI green" · "Only the parser changed — ✗ 3 files
outside `Sources/Parser/`, 1 workflow file" · "No breaking changes — ? public API touched in
`GitHubClient.swift`" · "Fixes #142 — ✓ referenced, ✗ 2 of 3 acceptance bullets not mentioned".
Every line is a fact with a link into the diff; the card never says "trust this".

- **Claims (tier 1 first, tier 2 optional).** A deterministic extractor in `ShepherdCore/Claims/`
  finds the four claim shapes in the body with patterns (test/tests/spec, "only"/"just" + a path
  or module, "no breaking"/"backwards compatible", `#N` / `fixes|closes|resolves #N`). When the
  on-device model is available and the reviewer opens the card, an optional `@Generable
  ClaimList { claims: [Claim { kind, quote }] }` pass (tier 2 only, the body already fits the
  budget — it is in the digest) catches phrasings the patterns miss; a claim the model found is
  marked "read by the model" and links to its quote. Never a cloud pass: the body is the
  reviewer's colleague's text, and the card opens unattended on every pull request.
- **Evidence (tier 1, all of it).** Pure functions over `PullRequestDetail`:
  - *tests*: changed paths matching the repo's test conventions (`Tests/`, `*Tests.swift`,
    `__tests__`, `*.spec.*`, `test_*.py`), the check rollup, and **assertion drift** — hunks that
    delete or weaken `XCTAssert`/`expect`/`assert` lines, or add `skip`/`xit`/`@unittest.skip`;
  - *scope*: the set of top-level directories and the named module vs. the changed paths; workflow,
    lockfile, config and generated files flagged separately;
  - *breaking*: `public`/exported symbol removals or signature changes in the diff (language-aware
    for Swift, TypeScript, Go, Python by regex over hunks), migrations, schema files, CI config;
  - *issue*: the referenced issue's body (already fetchable; cached in GRDB) split into acceptance
    bullets/checkboxes, each matched against the pull request body and the diff by keyword overlap
    (the embedding cosine from the saved-reply suggester when available).
- **Rule.** Every line is ✓ / ✗ / ? with the evidence named; there is no overall score, because a
  score would be a verdict. The card is collapsed by default on human pull requests and expanded on
  agent pull requests (ADR 0008 facet).
- **UI.** `ClaimsEvidenceCard` in the review screen above the description; ✗ lines link to the
  file in the diff viewer; a "Turn into a comment" button drafts the finding into the composer
  through `AIDraftFieldState` (labelled, editable; nothing auto-submits).
- **Tests.** Linux: claim extraction fixtures (30 real-shaped agent bodies), each evidence
  function against fixture details, assertion-drift patterns per language. App: card state.
- **Effort:** M. **ADR 0026** (claims are the pull request's text, evidence is the diff and CI;
  no score; tier 2 reads the body only, on-device, never bulk-cloud).

### B. Track record and trust lanes

**Story.** The inbox has two lanes: **Short look** and **Full review**. A pull request is a short
look **only** when CI is green **and** the diff is small (defaults: ≤ 5 files, ≤ 120 changed lines,
no sensitive path — workflows, auth, secrets, migrations, deleted tests — as the one exclusion
the maintainer accepted implicitly by "small"; configurable). Beside each agent's name a track
record badge: `Claude Code · this repo · 23 merged · 2 reverted · CI green first push 78 %`. The
badge sorts within a lane and colours the row's provenance chip; it **never** moves a pull request
between lanes.

- **Data.** Migration **v5**: `pull_request_outcomes (prID PK, repo, agent, author, openedAt,
  closedAt, merged, revertedByPRID?, firstPushCIGreen, reviewRounds, changedLines, source
  ENUM(sync|backfill))`. Written from two places: the sync pass when an open pull request
  disappears (fetch its final state) and a **one-time backfill** the user starts from Settings:
  `is:pr is:closed archived:false repo:{repo} closed:>{90 days}` per repository the inbox knows,
  paged, ETag-cached, at most 500 pull requests per repository, with a visible progress line and a
  cancel. Reverts are detected from titles (`Revert "…"`) and bodies (`This reverts commit …`)
  pointing at a merged pull request's merge commit.
- **Reviews rounds.** From the timeline: count of `CHANGES_REQUESTED` reviews before merge. **First
  push CI green:** the check rollup of the first head SHA in the commit list.
- **Rule.** `TrustLane.classify(summary, verdict?, config) -> Lane` is a pure function whose only
  inputs are CI state, diff size, the sensitive-path exclusion and the configuration. The track
  record is an input to *sorting* and the badge, not to the lane — this is a test, not a comment.
  Auto-merge (ADR 0018) and bulk triage (ADR 0015) do not read either.
- **UI.** Two lane headers in the inbox (a facet, like Risk); the badge on the provenance chip
  with a popover listing the numbers and "in this repo, last 90 days, on this Mac". Settings →
  Automation: the lane thresholds and the backfill button, synced (ADR 0014) except the backfill
  state, which is device-local like the search index.
- **Tests.** Linux: outcome record round trip, revert detection fixtures, lane classification
  cases (every input at the boundary), track-record arithmetic, the "history never gates" test.
  App: backfill pager against recorded pages, cancel mid-way, progress.
- **Effort:** L (the backfill is the bulk of it). **ADR 0027** (the lane gate is CI + size; history
  informs; closed pull requests are read once per repository and then incrementally; no new host).

### C. Since my review — the interdiff

**Story.** After the agent pushes a fix round, the review screen opens on **what changed since
you last reviewed**, not on the whole pull request: a "Since your review" tab in the diff viewer
with only the files and hunks that differ from the head you reviewed, and your findings from that
round listed with a state each — *addressed* (the anchored lines changed), *unchanged*, *moved*
(the file was renamed or the hunk shifted), *replied* (the agent answered in the thread).

- **Data.** Migration v5 also adds `review_snapshots (prID, reviewedHeadOid, reviewedAt,
  filesJSON — the `changed_files` rows incl. `patch` at submit time)`. Written by the outbox drain
  when a `submitReview` succeeds (the one moment Shepherd knows "this is the head I reviewed"),
  and retroactively from the timeline for reviews submitted elsewhere (head SHA from the review
  event, patches from the current detail if the SHA still matches, else marked "unavailable").
- **Interdiff, locally.** `Interdiff.compute(before: [ChangedFile], after: [ChangedFile]) ->
  [InterdiffFile]` in `ShepherdCore/Review/`: per path, reconstruct both "after" texts with
  `PatchReconstructor`'s logic (moved into ShepherdCore behind a pure API, or duplicated as a
  small pure function if the app-target type cannot move) and diff them; files identical across
  rounds disappear. No GitHub compare API is needed, so a force-push cannot lose the baseline —
  the snapshot is local. Finding states come from mapping each thread's anchor (path, line,
  original line) onto the interdiff hunks.
- **Rule.** *Addressed* is a heuristic about lines, never a judgment about correctness — the label
  says "lines changed", and the thread stays open until the reviewer resolves it.
- **UI.** A segmented control on the diff viewer: All files / Since your review (default when a
  snapshot exists and the head moved). Findings list under it with the four states and a jump.
  The inbox row shows "3 rounds · 2 findings unchanged" when applicable.
- **Tests.** Linux: interdiff over fixture pairs (added file, removed file, rename, hunk shift,
  identical), anchor mapping to states. App: snapshot written on outbox success, tab default.
- **Effort:** M. **ADR 0028** (snapshots at submit time; interdiff computed locally; "addressed"
  is about lines).

### D. Feedback loop — from a recurring finding to an agent rule

**Story.** The third time in a month the reviewer writes "please add a test for the error
path" on that repository's agent pull requests, a card appears: **"You have said this three
times."** Its button opens the delegation sheet with a drafted task — *add a rule to `CLAUDE.md`
(or `AGENTS.md`, whichever the repository has) that says …* — the local agent opens the pull
request in a worktree, and the reviewer reviews that pull request like any other.

- **Recurrence (tier 1 + embeddings).** The reviewer's *own* review comments per repository, from
  `review_comments`, embedded with the saved-reply suggester's on-device embedder and clustered
  by cosine (threshold documented, ≥ 0.6, reusing `SavedReplySuggester.rank`'s primitives); a
  cluster of ≥ 3 comments within 30 days on ≥ 2 different pull requests is a recurring finding.
  Runs after sync, on-device, at `.utility`. Never a model call, never a cloud call — these are the
  reviewer's own words but the pass is unattended.
- **The rule draft (tier 2, attended).** The button assembles the cluster's comments and the
  repository's existing instruction file (fetched read-only through GitHubKit, cached) and drafts
  the rule text through the Intelligence plan's brief drafting (feature E there), streaming into
  the delegation sheet's task field with the tier caption; the reviewer edits; **Run** is theirs.
  Without a model, the sheet opens with the three quoted comments and a template sentence.
- **Rule.** Shepherd never commits to a repository. The instruction-file change is a pull request
  by the local agent, reviewed in Shepherd, subject to the same claims/evidence card. The
  auto-delegation rules (ADR 0016) do not get this trigger — a recurring finding is a suggestion
  to the human, not an event.
- **UI.** `RecurringFindingCard` on the review screen and a list under Settings → Replies
  ("Recurring findings", with "dismiss for this repository").
- **Tests.** Linux: clustering over fixture comment sets, thresholds, the 30-day / 2-PR rule.
  App: card → delegation sheet prefill, dismissal persistence.
- **Effort:** M. **ADR 0029** (amendment to 0011 and 0016: drafted, attended, never a trigger).

### E. The session back-channel — a finding goes to the session that wrote the code

**Story.** On an agent pull request whose head commits carry `Claude-Session: https://claude.ai/code/session_…`,
every inline finding and the review summary gain a second button beside "Add comment": **"Send to
the session"**. The finding (file, line, the reviewer's text, the pull request link) goes to that
Claude Code session; it fixes and pushes; Shepherd's sync sees the new head and opens *Since your
review* (§C). The GitHub comment is still posted — the thread stays the record.

- **Return address.** `CommitInfo.trailers` already carries the line. A pure `SessionReference.parse`
  in `ShepherdCore/Agents/` extracts the id and the host; a pull request with more than one distinct
  session on its head commits offers the most recent.
- **Transport — the constraint first.** ADR 0011 rules that Shepherd never touches agent
  authentication and never collects Anthropic credentials. So the transport is **the user's own
  installed Claude Code CLI**, invoked like delegation already invokes it, in both cases:
  - local session: `claude --resume <session-id> -p "<message>"` in the pull request's worktree
    (the flow ADR 0011 already runs), streaming the run into the same delegation panel;
  - remote session (`claude.ai/code/…`): whatever the installed CLI exposes for addressing a
    remote session. **This is a spike before it is a feature**: the first task is to verify, against
    the installed CLI's documented surface, whether a message can be sent to a remote session from
    the CLI, and under which login. If it can, the same command-template mechanism carries it. If
    it cannot, the feature ships for local sessions only and the remote button says "Open the
    session" (a link) — still one click less than copying a comment.
  - Shepherd does not call the Remote API with its own credentials, does not proxy, and stores no
    token. The message body is exactly what the reviewer typed plus the location; it is shown before
    sending.
- **Rule.** Sending a finding is *not* a review action: it does not resolve the thread, does not
  approve, does not start an auto-delegation run. It is the ADR 0011 "delegate a review finding"
  flow with the target session pre-selected, so every guardrail there (turn and budget caps, worktree
  isolation, transcript kept locally, no auto-push) applies unchanged.
- **UI.** The button, a confirmation sheet showing the exact message, the run panel; on the inbox
  row a small "session" glyph for pull requests that have a return address. Settings → Delegation:
  the command templates for both cases.
- **Tests.** Linux: trailer parsing fixtures (one session, several, none, malformed), message
  assembly. App: button visibility by provenance, confirmation before send, no thread resolution.
- **Effort:** S for the local path, plus the spike; M if the remote path exists. **ADR 0030**
  (amendment to 0011: a review finding may be addressed to the session that produced the code, via
  the user's own CLI, never via Shepherd-held credentials).

---

## 3. Sequence

```
Sprint A  — C Since-my-review (snapshots, interdiff)  ·  A Claims vs. Evidence (tier 1 first)
            → the two features that remove re-reading; no new host, one migration (v5)     ~3 weeks
Sprint B  — B Track record backfill + lanes                                                  ~2 weeks
Sprint C  — E Session back-channel (spike, then local path)  ·  D Feedback loop
            → the loop closes: finding → session → fix → interdiff → rule                    ~2 weeks
Later     — A's tier-2 claim extraction once the on-device plumbing from the Intelligence plan
            has shipped; B's badge gains the triage verdict as a sort key
```

Both migrations of this plan share **v5** (outcomes, snapshots) so the schema moves once.

---

## 4. Parked, with the reason

- **Conflict radar** (which open agent pull requests collide): useful at 150+ pull requests a week,
  not at 40; needs the base-branch tree per repository. Revisit with volume.
- **Local shadow CI** (run the repo's checks in the worktree before the runner does): valuable, but
  it is a delegation-panel feature, not a review feature; belongs to ADR 0011's next amendment.
- **Kill switch and daily caps**: auto-delegation and auto-merge already have per-rule switches;
  a global pause is one toggle and can ship any time the maintainer asks.
- **Pull request clusters** (review one, compare the rest): the embedding index makes it cheap, but
  the interview ranked it below the four above; the "since my review" interdiff machinery is the
  building block it would reuse.
- **Audit export, roles, cost ledger**: a team's needs; out of scope for a solo maintainer.

---

## 5. Definition of done, per feature

- Works with no model at all (tier 1 shows everything it can; tier-2 extras are additive).
- No new outbox action; the rules-engine-input test still passes (nothing here gates a merge).
- Migration listed in `DatabaseManagerTests`; records round-trip on Linux.
- New GitHub reads ETag-cached and named in `CONTRIBUTING.md`'s host list (they are all
  `api.github.com`); no new host.
- Strings in the catalog, checker green; new settings in the sync document with fixtures.
- ADR written and linked from `docs/adr/README.md`; `docs/FEATURES.md` paragraph; roadmap ticked.

---

## Amendment (2026-09-05): the leaderboard rejection is reversed, and what was built is not one

§0 lists four things "recorded so they are not re-proposed without a new reason": a team/roles
model, an audit export, cost dashboards, and **an agent leaderboard**. The fourth is now built and
shipped as **the fleet** — a screen per agent with counts on it — and this is the record of that
reversal. The other three stand exactly as written.

The reason the rejection was right and is now spent is one distinction §0 did not draw. It rejected
a *ranking*; what was missing was a *ledger*. The interview's own numbers are what forced the
difference into view: ten to forty agent pull requests a week **across repositories**, and §2.B's
badge — the thing built to answer "how has this author done" — is scoped to one author in one
repository and stops at exactly the boundary the work crosses. The aggregate that answers the wider
question was already in the code and had never been called:
`TrackRecord.compute(outcomes:subject:repo:since:)` takes `repo: RepoRef?` with `nil` documented as
"every repository". So the thing that was actually missing was a caller, not a scoreboard.

A list of agents with rates beside them is one keystroke away from being a leaderboard, so the
difference is not left to restraint. Four rules make it a property of the code:

1. **No rate is ever a sort key.** `FleetRoster.make` answers in one fixed order — open pull
   requests descending, then most recent close, then name — and the ordering function takes no
   parameter. There is no sort picker and no sortable column, because there is nothing for one to
   call.
2. **No ordinal, no total, no cross-agent table.** The list row and the detail page are the only
   two views, and neither renders a position, a "top", a fleet-wide average or an "N of M agents".
3. **No colour that implies a grade.** The fleet does not use `TrackRecord.chipColor` / `chipTone`
   at all. It prints counts and the agent's identifying palette colour, and nothing else.
4. **The one cross-agent statement is a bounded pair.** `FleetNotice.revertShareGap` names two
   agents in one repository with four counts, no third party and no ordinal, and renders the
   identical sentence on both of the two pages it belongs to.

And the fleet is a ledger of *agents*, not of people, in four places rather than by convention:
membership is `outcome.agentName != nil`; neither `FleetAgent` nor `FleetRepositoryRecord` has a
login field, so `PullRequestOutcome.authorLogin` is discarded by the builder; `shepherd://fleet/<id>`
resolves registry ids and never logins; and the track-record popover's way in is *absent* rather
than disabled when the badge's author is a human or a generic bot.

Recorded in full, with the three notice rules and their thresholds, in
[ADR 0035](../adr/0035-the-fleet.md). Nothing in §2.B changes: the lane gate is still CI, size and
sensitive paths, and a history still never moves a pull request between lanes.
