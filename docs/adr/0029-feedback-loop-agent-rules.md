# ADR 0029: The feedback loop — a recurring finding becomes a drafted agent rule

Status: Accepted (v1.2) · Date: 2026-09-03

Amendment-style, to [ADR 0011](0011-delegate-to-local-agent-cli.md) (delegation) and
[ADR 0016](0016-auto-delegation-rules.md) (auto-delegation rules). Everything those two decide
still holds; this one adds a *source* for a delegation's task text and states, once, why that
source may never reach the unattended path.

## Context

`docs/plans/agent-fleet.md` §2.D comes from one sentence in the maintainer interview: the third
time you write "please add a test for the error path" on the same repository's agent pull requests,
the problem is not that pull request. The problem is the repository's agent instructions file,
which does not say it — and the reviewer keeps paying for that in review comments, several times a
month, on work that is otherwise fine.

Everything needed to notice this is already on the Mac. `review_comments` holds the reviewer's own
comments per pull request (ADR 0006). ADR 0019 put an on-device sentence embedder behind
`EmbeddingProviding`, and `SavedReplySuggester` already ranks short review prose with it. ADR 0011
can hand a task to the user's own agent CLI in a detached worktree. The gap is only that nothing
counts.

Three things about the shape of this feature had to be decided rather than tested:

1. **An unattended pass over review prose.** Detection has to run after every sweep, without
   anybody asking. ADR 0007's rule for unattended work is "on-device only" and ADR 0020's is "a
   colleague's words do not travel" — so what an unattended pass is allowed to read at all is the
   first question, not an implementation detail.
2. **A card that is a suggestion, not a verdict.** "You have said this three times" is a claim
   about the reviewer, in their own words. If it is wrong it is annoying in a way a wrong risk
   badge is not, so the thresholds have to be conservative and the card has to be dismissible.
3. **A rule is a change to a repository.** Shepherd does not commit to repositories. So the only
   honest output is a *pull request opened by the local agent*, reviewed in Shepherd like any
   other — which means the feature ends where every other delegation ends, at a button the
   reviewer presses.

## Decision

### The reviewer's own comments, on this Mac, and nothing else

`DatabaseManager.viewerReviewComments(login:since:)` is the only read the feature has. It matches
the signed-in login case-insensitively, skips comments still pending in an unsent review, and
takes a time floor. **Nobody else's comment is returned at all**, so the pass cannot cluster a
colleague's sentence even by accident — the guarantee is the shape of the query rather than a
filter applied late (ADR 0020's reasoning; ADR 0007's host list is untouched).

Embedding is `EmbeddingProviding`, whose only implementation is the on-device
`NaturalLanguageEmbedder` (ADR 0019). There is no `IntelligenceRouter`, no base URL and no key
anywhere in the detection path, so the unattended half of this feature is structurally incapable
of reaching a cloud endpoint. **No new host, no new outbox action, no GitHub read of any kind.**

### The rule that makes it a *recurring* finding

`RecurringFindingDetector.detect` in `ShepherdCore/Review/RecurringFindings.swift` is pure, and
every threshold is a documented constant with a Linux test around it:

| Constant | Value | Why |
|---|---|---|
| `minimumCount` | 3 | The interview's number: twice is a coincidence |
| `minimumDistinctPullRequests` | 2 | Three comments on one pull request are one argument about one mistake, not a pattern in the repository |
| `defaultWindow` | 30 days | A rule drafted from March's comments describes a habit the agent may have lost. Seconds, not calendar months, so the window cannot grow in March |
| `minimumSimilarity` | 0.6 | Above ADR 0019's search floor (0.35) and above the saved-reply floor (0.45), because this corpus is the narrowest of the three: every candidate is short review prose in one person's voice, so any two of them score high against each other |
| `maximumQuotes` | 3 | The card's sentence is "three times"; eleven quotes would be a thread |

Clustering is **greedy, seeded by the oldest comment in a fixed order** — not k-means and not
average-linkage, both of which need a `k` or a merge order nobody can check by hand. The exemplar
of a cluster is its **shortest** comment, because the reviewer's shortest phrasing of a thing they
have written three times is the one closest to a rule. Cluster order is total (size, then the
newest comment, then the exemplar) and comment order inside a cluster is total (oldest, then id),
so two sweeps over the same comments produce the same card in the same order.

### Drafted, attended, and never a trigger

This is the amendment proper, and it is three sentences:

- **Drafted.** The card's *Draft a rule* button opens the delegation sheet with a task text: the
  three quotes, both candidate filenames, and one sentence about length and voice. With a model
  configured, the sheet's ✨ button drafts the wording instead, through the same
  `AgentBriefDrafter` seam feature E added to ADR 0011 — the same request, the same budget
  arithmetic (the comments' share reserved before the digest), the same ladder, the same tier
  caption in the field. Only the steering differs
  (`IntelligencePrompt.agentRuleBriefInstruction`): write one rule for the instructions file, do
  not change this pull request's code.
- **Attended.** Run is the reviewer's click, unchanged. There is no code path from a recurring
  finding to a started agent, to a commit or to a push — and Shepherd still never commits to a
  repository, so the instruction-file change arrives as a pull request the local agent opens and
  the reviewer reviews in Shepherd, subject to the same claims/evidence card as any other
  (ADR 0026).
- **Never a trigger.** ADR 0016's `AutoDelegationTrigger` does **not** gain a case, and this is
  the deliberate part rather than an omission we got around to. A recurring finding is not an
  *edge*: it is true of a repository for weeks, which is exactly the failure mode ADR 0016 designed
  out ("acting on a state instead of a change"). And an unattended rule that rewrote a repository's
  agent instructions on its own would be the first thing Shepherd did that changes how *future*
  agents behave — a suggestion to the human is the only correct shape. The rules engine has no
  input a finding could enter through: nothing in the detection path emits a `SyncEvent`, and
  `DelegationCenter.startAutomatically` still takes no brief drafter at all.

### Dismissal is device-local, and it is not a setting

A dismissed finding is remembered as one hash per finding — `RecurringFinding.dismissalKey`, an
FNV-1a of the repository and the exemplar — in `UserDefaults`, beside the auto-delegation ledger
(ADR 0016's argument, applied again):

- it must survive a relaunch, or a card the reviewer has decided about comes back on the next
  sweep;
- it carries no secret and no content — a repository name and a sentence, both already in the
  inbox, reduced to a hex string;
- it is cleared explicitly on "Sign out & erase local data", because it names findings the leaving
  account wrote;
- and it deliberately **does not travel** in the encrypted settings document (ADR 0014). "I do not
  want this card" is a judgement about one screen in front of one person on one Mac. A second Mac
  that has never shown the card has nothing to suppress, and syncing the set would let one Mac
  silently hide a suggestion the other has never offered — the same reason the auto-delegation
  ledger stays home. `SyncedSettingsDocument` is unchanged and `SettingsSyncTests` needs no new
  fixture.

The key is the repository plus the *exemplar*, not the whole cluster, so a fourth comment joining
the cluster cannot resurrect a card the reviewer has dismissed — while a genuinely different
finding is a different exemplar and therefore a card they have never seen.

### Where it appears

- **The review screen**, under the claims card and above the description
  (`Features/Review/RecurringFindingCard.swift`): the sentence, three quotes with the pull request
  numbers they were written on, *Draft a rule* and *Dismiss for this repository*. It draws nothing
  when the repository has no undismissed finding, which is the ordinary case.
- **Settings → Replies**, a read-only "Recurring findings" list with *Hide* / *Show again*. It
  belongs there because that tab is the one about the reviewer's own review text, and it is a list
  rather than a setting: there is nothing to configure, and the thresholds are constants in
  `ShepherdCore` with tests on them.

## Consequences

- The loop the plan set out to close is closed on the reviewer's own machine: finding → noticed →
  a drafted rule → a pull request from the local agent → reviewed in Shepherd. No new host, no new
  write, no migration.
- **One additive read** in `ShepherdPersistence` and one additive constant at the end of
  `IntelligencePrompt`. The intelligence layer gained no request type: the rule brief *is* an
  agent brief, steered by a sentence that travels at the head of the quoted comments because an
  agent-brief request has no instruction field. That is the one compromise in this ADR, it is
  documented at the call site (`Features/Delegation/RuleBriefDrafter.swift`), and the sentence
  names itself so it cannot be read as a review comment. A second steered brief is the moment to
  make the hook real.
- The feature works with **no model at all**: the template is the whole of it, and the ✨ button is
  simply absent (ADR 0007 — no feature hard-depends on a model). With no *embedder* on this Mac
  there is no card either, and nothing anywhere says so: a suggestion nobody asked for is not news
  when it cannot be made.
- The pass costs one embedding per distinct comment body per launch, cached in memory and keyed by
  the body, plus *n*² cosines bounded by a 200-comment ceiling per repository. Nothing is persisted
  — no table, no vector on disk. Re-computing after a relaunch is cheaper than a migration and
  cannot go stale.
- A second Mac computes its own findings from its own copy of the same comments and reaches the
  same answer, because the detector is deterministic. Only the dismissals differ, by design.
- Adding a fourth threshold later is one constant and one test. Adding an *action* — anything that
  wrote a file, pushed a branch or armed a rule — would need a new ADR, because "the output is text
  in a field the reviewer runs themselves" is what keeps this inside ADR 0011's guarantees.
