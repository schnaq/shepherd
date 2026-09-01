# ADR 0016: Opt-in auto-delegation rules (red CI on your own pull request)

Status: Accepted (v1.x) · Date: 2026-09-01

## Context

ADR 0011 gave Shepherd a way to send work *back* to a local agent CLI: a button on a pull
request or a review finding creates a detached worktree, runs the user's own Claude Code in it
with turn and budget caps, and waits for the user to review and push the diff.

The founder's own loop after that is mechanical and repeats several times a day: an agent opens a
pull request, CI goes red, and the next action is always the same — "go fix your CI". Pressing the
button is not the work; noticing is. The sweep already notices: since ADR 0012 the sync engine
emits an event stream, and `checksFailedOnOwnPR` fires exactly on the green-to-red edge of a pull
request the user owns. The gap between "Shepherd knows" and "the agent is working on it" is one
click that carries no judgement.

This is also the first feature where Shepherd would act **without a human in the loop**, which is
the reason for the size of this ADR relative to the size of the diff. Three failure modes have to
be designed out rather than tested out:

1. **Acting on a state instead of a change.** "CI is red" is true of a pull request for hours. A
   rule that fires on the state fires on every sweep, and the *first* sweep after a fresh install
   or a sign-in finds every long-broken pull request in the account at once — forty agent runs
   from one launch.
2. **Acting twice on the same work.** A rebuild, a second failing check, a reopened pull request,
   an app restart: each of them can present the same situation again. Two runs for one pull
   request would also fight over one worktree directory.
3. **Scope creep into the non-goals.** The roadmap's non-goals are explicit: Shepherd does not
   auto-submit reviews and does not orchestrate agents. An automatic *delegation* is on the right
   side of that line only as long as it stays a delegation: no auto-push, no auto-approve, no
   auto-merge, no automatic review submission.

## Decision

### A rule is a condition plus one action, and the action is always "delegate"

- **Opt-in, off on a fresh install.** `AutoDelegationRules.isEnabled` is the master switch, the
  same shape as `webhooksEnabled` (ADR 0012) and `settingsSyncEnabled` (ADR 0014): with it false,
  no locator runs, no ledger is read, and an event costs one `Bool`.
- **v1 conditions, both transitions on a pull request the user owns:** CI turned red
  (armed by default once the switch is on), and — a second opt-in on top — a reviewer requested
  changes.
- **v1 action, the only action:** start a delegation through the existing engine, with a task text
  rendered from a user-editable template. Everything ADR 0011 guarantees applies unchanged,
  because it is the same code: detached worktree, `--max-turns`, `--max-budget-usd`, the
  allowed-tools preset, the full transcript, and **Shepherd never pushes**. The result waits in the
  Delegation Center exactly like a run the user started by hand.

### "Own" is defined once, and narrowly

`AutoDelegationPolicy.isOwn` is the single definition, used by the rules *and* by the sweep's two
events, so a notification and a rule can never disagree about whose work it is:

- the signed-in user opened it (`author:@me`), **or**
- a recognised coding agent opened it (ADR 0008 provenance) **and** it is assigned to the user
  (`assignee:@me`) — the agent-on-my-behalf case, which is the normal shape of delegated work
  coming back.

`mentions:@me` and the `involves:@me` catch-all deliberately do not qualify. Being copied in on
somebody else's pull request must never start an agent on it, and *assignee* alone does not either
when a human wrote it: "please look at this" is not "this is yours to rewrite".

### The trigger is an edge, and the event carries the proof

`SyncEvent.checksFailedOnOwnPR` now carries a `ChecksFailure` value (summary, the rolled-up state
the previous sweep saw, and whether the previous sweep had the pull request at all) instead of a
bare summary; `changesRequestedOnOwnPR` is a new event with the same shape for the review
decision. The engine's emit conditions are unchanged in spirit — they always compared against the
previous sweep — but the comparison is now *part of the payload*, so a consumer can tell "Shepherd
watched this turn red" from "Shepherd saw this red for the first time". Notifications keep firing
on both (the pull request *is* red); rules fire only on the transition. Failure mode 1, closed by
construction.

### One start per (pull request, head commit), persisted

`AutoDelegationLedger` holds two things: the day's counter and the set of `(prID, headRefOid)`
pairs a rule already fired for. The dedup key is deliberately **trigger-blind**: once the agent
has been sent to a commit, a second condition on that same commit is not new work. New commits are
new work, so pushing a fix and breaking CI again does trigger again.

It lives in `UserDefaults` (`AutoDelegationStore`), not in SQLite, and not in the settings
document:

- it must survive a relaunch, or a restart re-delegates work the agent already has;
- the database is *erased* on sign-out, which is exactly when the ledger should also go — so it is
  cleared explicitly there instead;
- it carries no secret and no content, only node ids, SHAs, a date and a counter;
- it does **not** travel between Macs (ADR 0014): a day counter and a per-machine "already done
  this" set are one machine's automation state, and sharing them would let one Mac silently cap
  the other. The *rules* do travel, in `SyncedSettingsDocument.delegation`.

The ledger is written **before** the delegation is launched. A crash in between costs one
automatic run; the other order would risk re-running on every relaunch.

### Caps, and a notification when a cap bites

Two limits, both user-visible and both settable: at most *n* automatic delegations running at once
(default 1) and at most *n* per calendar day (default 5). The daily counter is keyed to a
`yyyy-MM-dd` stamp in the local time zone, so it resets at midnight rather than 24 hours after the
last start. `ADR 0011`'s one-run-per-pull-request rule is enforced by `DelegationCenter` and is
simply reused — an automatic start is the last thing allowed to bend it, and the concurrency cap
counts only automatic runs, so three hand-started delegations do not eat the automation's budget.

When a cap stops a rule that would otherwise have fired, Shepherd **notifies instead of starting**.
The other skip reasons (not a transition, already handled, not configured, not mine) are silent:
they happen dozens of times an hour and are not news.

### Everything automatic is visible

- Every automatic start posts a macOS notification — *"Auto-delegated schnaq/review#42 to Claude
  Code — CI failed"* — and that one is **not** gated by a notification preference. Something the
  app did unattended must always be visible; the way to switch it off is to switch the rule off.
- The delegation is marked automatic wherever it appears: `DelegationModel.isAutomatic` drives an
  "Automatic" badge in the sheet header, and `DelegationOutcome.wasAutomatic` becomes
  `details.automatic` in the `delegation.finished` webhook — an additive field under `"v": 1`
  (ADR 0012's rule for new payload fields), documented in `docs/WEBHOOKS.md`.
- An automatic start does **not** present the sheet. An unexpected modal in front of whatever the
  user is doing would be worse than the notification; the run is there to open when they want it.

### The decision is a pure function

`AutoDelegationPolicy.decide(_:context:)` in `ShepherdCore/Automation/` takes *(signal, rules,
readiness, what is running, ledger, clock)* and returns `.start(plan)` or `.skip(reason)`. It
touches no CLI, no database, no sweep and no `Process`. The checks run in a fixed, documented
order — switched off → condition not armed → not mine → not a transition → not configured →
already handled → already delegating → concurrency cap → daily cap — so the reason never depends
on evaluation order. The whole product risk of this feature is "did Shepherd run an agent I did
not ask it to run", and that question is answered by a unit-tested function rather than by a
coordinator, exactly as ADR 0015 did for "which pull requests does bulk triage touch".

The app layer is deliberately dumb: `AutoDelegationCoordinator` maps events onto signals, supplies
the inputs, records the ledger, posts the notice, and hands the plan to `AppEnvironment`, which
starts it through the same `startDelegation` a button press goes through.

### A readiness check before the slot is spent

A rule only fires for a repository that could actually run one: an agent CLI was found and a local
clone is configured. Without that guard an automatic start would produce a delegation parked on
"no local checkout" while consuming a dedup slot and a day of budget — the user would be told an
agent is working when nothing is.

## Consequences

- The common loop closes without a click: agent opens a pull request → CI goes red → an agent is
  already fixing it → a notification says so → the user reviews a diff. The reviewing and the
  pushing stay human, which is the part that was never the bottleneck.
- **Non-goals are unaffected.** Nothing here approves, merges, pushes or submits a review, and no
  new path to GitHub was added: an automatic delegation performs exactly the writes a manual one
  does, which is none.
- `SyncEvent` gained a case and one payload type changed shape, so every exhaustive switch over it
  had to be revisited (`NotificationManager`, `WebhookCoordinator`, `SignedInSession`). That is
  the intended cost of making the transition information part of the contract rather than
  something each consumer re-derives.
- The sweep's `checksFailedOnOwnPR` (and the new `changesRequestedOnOwnPR`) now use the shared
  `isOwn` definition, so an agent's pull request assigned to the user also notifies about red CI.
  That is a small behaviour change to notifications, and the honest one: it is the user's work.
- `AppSettings` gained the rule set, which therefore travels in `SyncedSettingsDocument` and in
  both directions of `SettingsSyncApplier` (ADR 0014's standing obligation). The ledger explicitly
  does not, and `SettingsSyncTests` covers the rules half.
- A second Mac with the same rules can start its own automatic delegation for the same pull
  request, because the ledger is machine-local. Both would then be told "one delegation per pull
  request" only within their own app. This is accepted for v1: the alternative is a shared ledger,
  which means shared mutable state in a document ADR 0014 deliberately syncs manually.
- Adding a third condition later is one case in `AutoDelegationTrigger`, one emit in the sweep and
  one checkbox — the policy, the ledger, the caps and the UI do not change. Adding a third
  *action* would need a new ADR, because "the action is always a delegation" is what keeps this
  inside ADR 0011's guarantees.
