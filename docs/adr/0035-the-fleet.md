# ADR 0035: The fleet — an agent gets a screen, and the screen counts rather than ranks

Status: Accepted · Date: 2026-09-05

## Context

ADR 0027 taught Shepherd to read the pull requests a repository has **closed** and to keep what
became of each one: merged, closed unmerged, reverted, how many rounds of requested changes it
took, whether its first push was green. It spends those rows on one thing — a badge beside an inbox
row, scoped to one author in one repository — and it was careful about how little that badge is
allowed to mean: no score, and no path from a history to a lane.

The counting function it introduced, `TrackRecord.compute(outcomes:subject:repo:since:)`, takes
`repo: RepoRef?`, and `nil` is documented in that file as "every repository". Nobody has ever
passed it. So the app has, on disk, the answer to a question a maintainer of thirty agent pull
requests a week actually asks — *how has this agent been doing, everywhere?* — and no surface that
asks it. The badge answers the narrower question well and then stops at the repository boundary,
which is exactly the boundary the work crosses.

[`docs/plans/agent-fleet.md`](../plans/agent-fleet.md) recorded four things as rejected "so they
are not re-proposed without a new reason": a team/roles model, an audit export, cost dashboards,
and **an agent leaderboard**. This ADR reverses one of those four, and the reversal is the reason
it needs to be an ADR rather than a feature note. The plan's reason for the rejection was sound and
is unchanged: a solo maintainer does not need a scoreboard of their agents, and a screen that
ranked them would be a machine for forming a verdict about work nobody has read. What the plan did
not distinguish is the *ledger* from the *ranking*. A list of agents with counts beside them is
one keystroke away from being a leaderboard, and the difference between the two is not a matter of
taste or of restraint later — it is a matter of which affordances exist in the code. That
distinction is what the rest of this document is.

## Decision

### One: a route, not a third kind of inbox content

The fleet is `AppEnvironment.Route.fleet(agentID:)`, a full-window screen beside the inbox and the
review screen, not a third value in the inbox's content-kind picker beside pull requests and
issues.

ADR 0032's argument for making issues a *picker* turned on the thing that made them the same
screen: an issues row and a pull-request row both occupy the inbox's selection, both fill its
detail panel, both are things a reviewer picks one of and works on. The fleet owns no such
selection. It has no detail panel over a pull request, nothing in it enters the focus session, and
its list is a list of agents rather than of work. Putting it in the picker would have made "which
kind of thing am I triaging" answer with something that is not a thing to triage.

### Two: the aggregate is the point, and the breakdown underneath it is mandatory

The agent's page leads with the cross-repository aggregate, and it draws the per-repository grid
directly underneath, always, never collapsed and never behind a disclosure triangle.

This is the one design rule on the screen that is about honesty rather than about layout. A rate
computed over four repositories can hide a single bad one completely: an agent that is green
everywhere and red in one place averages out to "mostly fine", and "mostly fine" is a sentence
about nowhere. So the fleet never shows an average without the rows it was averaged from. The
corollary is enforced one level down, in the notices: **every notice names a repository**, so every
unprompted sentence on the page can be checked against a row of the grid below it.

### Three: not a leaderboard, structurally

Four rules, and each of them is a property of the code rather than a policy somebody has to
remember:

- **No rate is ever a sort key.** `FleetRoster.make` returns the list in one fixed order — open
  pull requests descending, then most recent close, then display name — and the ordering function
  takes no parameter to change it. There is no sort picker and no sortable column header, because
  there is nothing for one to call.
- **No ordinal, no total, no cross-agent table.** The list row and the detail page are the only two
  views. Neither renders a position, a "top", a fleet-wide average or an "N of M agents". An agent
  is never told a number that only means something relative to the others.
- **No colour that implies a grade.** The fleet does not use `TrackRecord.chipColor` or its
  `chipTone` at all — the amber-for-a-revert, green-for-a-settled-record decision that tints an
  inbox row's provenance chip. The fleet prints counts and the agent's own palette colour, which
  identifies rather than judges. A page of numbers with a traffic light on it is a grade whatever
  the numbers say.
- **The one cross-agent statement is a bounded pair.** `FleetNotice.revertShareGap` names exactly
  two agents in exactly one repository, with four counts and no third party, no ordinal and no
  total. It is assembled from that repository's rows and not from the agent whose page asked, so
  the identical sentence renders on both of the two pages it belongs to. A reader sees one
  statement rather than two that might disagree — and "everybody with a rate, arrived at one page
  at a time" is precisely what that construction refuses to become.

The three sentences the screen states unprompted are pure functions in `FleetNotices`, each with a
named constant per threshold so the number has one home and a test on both sides of it. The numbers
are all of the same kind — the point below which a count is not evidence of anything — and they are
deliberately conservative, because Shepherd is about to say something about somebody's agent
without being asked:

- **The rework streak** (`minimumReworkStreak` = 3) says that the last *n* pull requests an agent
  closed in one repository all needed at least one round of requested changes. Three, borrowed from
  ADR 0029's `RecurringFindingDetector.minimumCount` and for the same reason: twice is a
  coincidence. The two constants only *agree* — retuning how often a reviewer must repeat
  themselves is not a decision about when an agent's rework is worth a sentence — so the number is
  written out again rather than shared, which would make the two rules one.
- **The first-push gap** (`minimumFirstPushDenominator` = 5, `minimumFirstPushGap` = 0.30) compares
  one repository's first-push-green rate against the same agent's rate across its others. Five is
  the smallest denominator at which one more pull request moves a rate by no more than a fifth —
  and it is the number ADR 0027 already treats as "enough to mean something", where a settled
  record needs five merges before a chip may turn green. Thirty points is large enough that the gap
  survives the next pull request: at the smallest accepted denominator one result moves a rate by
  twenty, so ten points still stand afterwards. A pull request that says nothing about its first
  push is in neither the numerator nor the denominator, on either side.
- **The revert share** (`minimumMergesForRevertShare` = 10, `minimumRevertShareGap` = 0.15,
  `minimumRevertsOnTheHigherSide` = 2) is the pairwise sentence, and it carries the highest bar in
  the file because it is the only one that names two agents. At ten merges a single revert is
  already ten points of share, so below that the arithmetic is about one pull request rather than
  about a pattern and the sentence would be comparing two accidents. Fifteen points cannot be
  reached by one revert on either side — it has to be something two reverts made and one cannot
  unmake. The two-revert floor cannot fire on its own while the other two numbers are what they
  are, and it is written down anyway, because that is only true *while* they are: loosening either
  without it would let a single revert produce a sentence comparing two agents.

None of the three is a verdict and none of them can act. A notice is a sentence; it names no pull
request to fix, and there is no code path from one to a write.

### Four: people are out by construction, in four places rather than by convention

The fleet is a ledger of agents. That is not enforced by a filter somebody could relax:

1. **Membership.** The only test is `outcome.agentName != nil`, and `FleetRoster.make` constructs
   `TrackRecordSubject.agent(name:)` and never `.author(login:)`.
2. **The type cannot carry a person.** Neither `FleetAgent` nor `FleetRepositoryRecord` has a login
   field. This matters more than it sounds: an agent's outcome *does* still carry the login of
   whatever account opened the pull request, frequently the maintainer's own, because a local
   session pushes with their token. `PullRequestOutcome.authorLogin` is read nowhere in the builder
   and discarded, so there is nowhere on the screen for a person's name to appear.
3. **Addressing.** `shepherd://fleet/<agent-id>` validates its one segment through
   `DeepLinkValidation.agentID` and is resolved against the **agent registry** —
   `filter=agent:<id>`'s vocabulary, not GitHub's user namespace. A login is a string, so nothing
   stops somebody typing one; what stops it *meaning* anything is that the registry is the only
   thing the id is looked up in and the fleet has no page for a person to land on. A link naming
   somebody resolves to the list, which is the honest answer, rather than to a page about them.
4. **The way in.** The track-record popover's *See every repository* button is **absent**, not
   disabled, when the badge's author is not an agent (`TrackRecordBadge.fleetAgentID(for:)` answers
   `nil` for a human and for a generic bot). A greyed-out button would still say that such a page
   exists for a colleague, which is the claim this ADR refuses to make.

Any one of the four would probably hold on its own. Four is the right number because the failure
they prevent is not a bug that shows up in review — it is a screen that quietly becomes a
performance record of a person, at which point the damage is done before anybody notices the
diff that did it.

### Five: no migration, no new query, no new GitHub read, no new host

The v6 `pull_request_outcomes` table already has every column this needs. The screen reads
`DatabaseManager.pullRequestOutcomes(since:)` — the *same* read the badges use, deliberately, so
the badge beside an inbox row and the grid on the fleet page cannot come to different conclusions
about the same ninety days — and does the rest in pure functions off the main actor. All counting
goes through `TrackRecord.compute`, which is why there is one definition of merged, reverted,
median rounds and first-push-green in the app rather than two that agree today.

Nothing here talks to GitHub. `CONTRIBUTING.md`'s host list is untouched, and the ways in are
navigation: a rail row in both sidebars, a ⌘K command, `shepherd fleet [<agent-id>]`,
`shepherd://fleet` and `shepherd://fleet/<agent-id>`, and a `ShowFleetIntent` with no parameters.
The grammar is additive-only (ADR 0013), so `fleet` is a new command word beside the existing ones
and the CLI's `--help` gained its line in the same change — the usage text is where the URL scheme
is discoverable without the docs, and a verb missing from it is a verb nobody finds.

## Consequences

- **The screen is only as good as a backfill nobody is obliged to run, and it is now the second
  surface that has to say so.** ADR 0027 keeps the history load manual because it reads up to five
  hundred closed pull requests per repository and the user did not ask for that; its 2026-09-05
  amendment added a one-time offer in the inbox because a button nobody finds is not a choice. The
  fleet inherits the whole problem in a sharper form: an inbox with no history still shows pull
  requests, while a fleet with no history is a screen of em-dashes. So the empty state carries the
  same offer, the same sentence about what it costs, and the same live progress line off the same
  coordinator — and a repository whose window holds nothing prints an em-dash rather than a zero
  percent, because "nothing was counted" and "none of it was green" are opposite claims.
- **Shepherd now states an unprompted claim about somebody's agent, which it has not done before.**
  Every other proactive surface either describes the pull request in front of the reader (ADR 0026,
  ADR 0023) or quotes the reader back to themselves (ADR 0029). A notice is a statement about a
  third party's work, made on a page nobody was reading a moment ago. The guardrail is that every
  notice is *derivable from the grid printed underneath it* — same rows, same window, same counting
  function — so a reader who doubts the sentence can count it themselves, and a notice that stopped
  matching its grid would be a bug with a visible symptom rather than a silent drift. Each rule has
  a Linux test on both sides of every threshold it names, which is the only reason a number like
  "thirty points" is allowed to be load-bearing.
- **The aggregate outlives the inbox, and the page has to say which parts of it did.** ADR 0027
  gives the outcome table no cascade, on purpose: a repository the sweep stops syncing keeps its
  history. On the badge that is invisible, because a badge only exists beside a live row. On the
  fleet it is a whole grid row for a repository with nothing open, and one that would read as a
  quiet week rather than as a departure. So `FleetRepositoryRecord.isHistoryOnly` is a separate
  question from "open count is zero" — it asks whether the inbox carries *any* open pull request
  from that repository, from anyone — and the page footnotes it. Getting that distinction wrong
  would print a wrong statement about a live repository, which is worse than printing nothing.
- **The track-record popover is now a navigation surface as well as a readout.** It was a leaf; it
  has a button that replaces the window. That is where the fleet is actually discovered — the
  reviewer who wants the cross-repository numbers is precisely the one who has just opened the
  popover and thought "and elsewhere?" — and it costs the popover an `AppEnvironment` dependency and
  a rule about closing itself before the screen underneath it changes.
- **`SignedInSession` keeps its `AgentDetector`.** It was constructed, handed to `GitHubClient` and
  dropped. The fleet needs it because a link addresses an agent by *registry id* while a stored
  outcome remembers only the display name, so something has to map one to the other; the detector's
  registry is the only thing in the app that can. It is a value type seeded once at sign-in, and
  editing the registry in Settings restarts the session, which is what makes one snapshot per
  session correct rather than stale.
- **Two rails now share a pinned footer of two rows.** The fleet row sits above Settings in both
  the pull-request rail and the issues rail, extracted into `RailFleetRow` from the start for the
  reason `RailSettingsRow` was extracted when the issues rail arrived. It is titled *Fleet* rather
  than *Agents* because the pull-request rail already has an AGENTS facet a few rows up whose every
  row narrows the list to one agent — the same word on a row that leaves the inbox entirely would
  promise one thing and do another.

## What this does not settle

Whether a page of counts is read as a grade anyway. Every rule above governs what the screen
*renders*; none of them governs what a reader does with two numbers next to each other, and a
maintainer who wants a ranking can build one in their head from a fixed-order list as easily as
from a sorted one. The four rules are worth having because they keep Shepherd from making the
claim, and because an affordance that does not exist cannot be reached for on a bad day — but they
are not evidence that the screen reads as a ledger. That is a question about a person using it for
a month, not about this repository.

Nor does it settle what the fleet looks like with fifty agents in it. The single fixed order, the
"no total, no ordinal" rule and the always-expanded per-repository grid are all comfortable
decisions at the handful of agents a solo maintainer's inbox actually contains, and each of them is
the sort of decision that gets harder rather than merely longer at ten times the size. The plan's
other three rejections — team/roles, audit export, cost dashboards — are still rejected, and they
are the direction that scale would push from. If the fleet ever needs to answer at that size, the
thing to re-read first is not this section but rule three.
