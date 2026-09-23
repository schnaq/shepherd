# ADR 0011: Delegate coding tasks to a local agent CLI (Claude Code first-class)

Status: Accepted (v1.x scope) · Date: 2026-09-01

## Context

Shepherd reviews agent PRs; the natural next loop is sending work *back*: "address this
review finding", "take this issue". The founder wants this to run on the user's own
machine via the locally installed Claude Code — not through a metered cloud API that
Shepherd would have to broker.

Verified facts (docs.claude.com / code.claude.com, 2026-09):
- Claude Code's **headless mode** (`claude -p … --output-format stream-json`) is the
  documented, stable integration path for third-party apps: newline-delimited JSON with a
  versioned `system/init` capabilities event, `--permission-mode`, `--allowedTools`,
  `--max-turns`, `--max-budget-usd`, session resume. No Swift SDK exists (TS/Python only);
  spawning the CLI is the recommended pattern for native apps.
- **Auth policy nuance:** Anthropic does not permit third-party products to offer
  claude.ai login / subscription quotas as part of the product (OAuth in third-party
  tools blocked since April 2026, later partially relaxed under conditions). Whether a
  local CLI run bills a subscription or an API key is determined by the user's own
  Claude Code installation and Anthropic's terms — not by Shepherd.

## Decision

- Shepherd gains a **"Delegate to local agent"** action (PR, review finding, or issue):
  create a `git worktree` for the branch, spawn the agent CLI as a subprocess in it,
  stream progress into a native panel, and on success surface the diff for the user to
  push — Shepherd never auto-pushes agent output.
- **Claude Code is the first-class integration** (stream-json parsing, turn/budget caps,
  permission mode surfaced in the UI). The invocation is a **configurable command
  template**, so other local agent CLIs work too — consistent with ADR 0008's
  agent-neutral stance.
- **Shepherd does not touch agent authentication.** It invokes the user's own installed,
  self-configured CLI and inherits whatever auth that CLI has. Shepherd's UI and docs
  make no claims about subscription coverage and never collect or inject Anthropic
  credentials for this feature.
- Guardrails on by default: `--max-turns`, `--max-budget-usd` (user-configurable),
  allowed-tools preset, worktree isolation, full transcript retained locally.

## Consequences

- The review loop closes without any Shepherd-side cloud dependency, matching the
  local-first thesis (ADR 0006).
- Feature availability depends on the CLI being installed; Shepherd detects it and shows
  a setup hint otherwise.
- Policy risk is contained: if Anthropic's third-party auth rules shift, Shepherd is
  unaffected because it never brokered auth in the first place.
- Pulled into v1 (2026-09-01) at the founder's request.

## Amendment (2026-09-03): drafted briefs, attended only

Additive, and inside the decision above: the worktree, the guardrails, the "Shepherd never pushes"
rule and the configurable command template are unchanged. What is new is where the *task text*
comes from (`docs/plans/apple-intelligence-v2.md` §3.E).

- **Shepherd drafts the brief on request.** A ✨ button beside the delegation sheet's task field
  asks the intelligence layer for the brief the agent is handed, streamed into the field as
  cumulative Markdown in three sections — goal, constraints, acceptance. It is drafted from what
  Shepherd already has: the `DelegationContext` (slug, head commit, origin, the ranking reasons,
  the finding's comments) plus the tier-1 `PullRequestDigest`, with the comments' share of the
  token budget reserved before the digest is built, exactly as a review-summary draft reserves it
  for the reviewer's notes (ADR 0007's budget rule).
- **Run is the human's.** The brief is text in a field. There is no code path from a drafted brief
  to a started agent, to a commit or to a push: the reviewer reads it, edits it, and presses the
  button — and a draft that is arriving, stopped, appended or discarded changes only what a run
  *would* say, never whether one happens. The ADR 0007 amendment's field rules apply unchanged (the
  replace-or-append question comes before the request, a keystroke wins over the stream, what
  arrived stays and stays labelled with the tier that wrote it).
- **Unattended rules never get one.** An automatic delegation (ADR 0016) keeps its own fixed,
  user-editable template. The entry point that starts one takes no drafter at all, so this is a
  missing argument rather than a check: nothing generated can reach a run nobody pressed a button
  for.
- **A colleague's comment does not travel.** A brief that quotes a review comment somebody else
  wrote is refused the cloud rung and answered on-device only — the ladder skips the rung rather
  than asking a provider not to look. The reviewer's own words and the digest already travel under
  the ADR 0007 amendment; a comment whose author never chose this Mac's endpoint does not (ADR
  0020's reasoning). No new host.

Consequence: the delegation feature gains one request type, one provider method with a default
implementation that declines, and one router call. A tier without a brief-shaped call says so in
one line under the field instead of answering out of a different prompt.

## Amendment (2026-09-04): a second preamble, for work that does not exist yet

Everything above was written about an **existing pull request**: the worktree is detached at that
pull request's head commit, the preamble forbids creating or switching a branch and forbids
opening a pull request, and the reviewer reads the diff and publishes it with the button. Handing
an *issue* to an assistant (ADR 0032's 2026-09-04 amendment) is the opposite situation. There is
nothing to review yet, so a run that may not start a branch can only leave its work in a detached
head nobody can push, and a preamble telling it not to open a pull request forbids the one outcome
the handover exists for.

So `DelegationPrompt` has two preambles, selected by `DelegationContext.Origin`:

- `.pullRequest` and `.reviewFinding` keep the text above, word for word.
- `.issue` gets one that says three new things. The worktree starts at the **tip of the
  repository's default branch** rather than at a commit, on a branch **Shepherd** named
  (`agent/issue-{number}`, from `GitWorktree.branchName(issueNumber:)`), and the run **may finish
  the job**: commit it, publish the branch, open a pull request, using the git and GitHub
  credentials its own tool already has.

That last sentence changes no rule in this ADR; it states one. The decision above already says
Shepherd runs the user's CLI and *inherits whatever authentication that CLI has*, and that
Shepherd's token is for the API and is never handed to git. An assistant that can publish could
always publish — what the old preamble did was ask it not to, because on a pull request that
belonged to the reviewer. On an issue it does not.

**What has not changed: Shepherd itself transmits nothing.** No code path added by that amendment
calls `git push` or asks GitHub to open a pull request. The only push in the app is still
`GitWorktree.push(toBranch:)` behind the button a person presses, and it is still the fallback for
a run whose own environment cannot publish — which the new preamble tells the assistant to say so
about, in its final message, rather than failing silently. The branch being Shepherd's is what
makes that fallback work: the app knows the name, so the button has something to push.

Two smaller consequences of the same amendment. `GitWorktree` gained `addForNewWork(branch:)`
beside `prepare(branch:headOid:)`, and it asks **git** which branch is the default —
`origin/HEAD`, refreshed with `git remote set-head --auto` — rather than asking GitHub, so this
stays a local operation on a Mac that already has the repository and adds no host to
CONTRIBUTING.md's list. And a worktree for an issue is named `owner-repo-issue128` rather than
`owner-repo-pr128`, because issue 128 and pull request 128 are two different pieces of work whose
runs must not delete each other's.

Handing the same issue over twice **resumes** its branch rather than resetting it. The first run's
commits are the user's work; a second worktree that quietly threw them away would be the worst
available reading of "assign this again".

That covers committed work, because a commit is on the branch and the branch is what the second
worktree is checked out from. Work the first run left **uncommitted** is not on the branch, and
`git worktree remove --force` would take it away without asking — so a leftover worktree that is
*dirty* is refused rather than cleared, with a message naming the directory and pointing at the
sheet where the changes can be committed or discarded. A clean leftover is cleared out as before.
The asymmetry with `prepare(branch:headOid:)`, which does clear a dirty worktree, is deliberate:
there the reviewer pressed Run again in the sheet that shows the diff, and here they pressed a
button on an issue that says nothing about a previous run.

## Amendment (2026-09-22): the turn cap can be switched off

Settings → Delegation's *Max turns* gains a **No limit** checkbox. It stores `maxTurns = 0`, which
`AgentCLIConfiguration` already read as "pass no `--max-turns`" — so this is a control for an
existing state, not a new one. The default stays 25, switching the box off restores 25, and the
delegation sheet's guardrail line says "no turn limit" rather than "0 turns max". The spend cap is
untouched and still applies, which is why the box's help says so: a run without a turn limit is a
run the budget has to stop.

The local-checkouts map this ADR introduced has a second reader since ADR 0039: *Open in editor*
resolves a pull request's paths against the same clones.

## Amendment (2026-09-23): a repository and a sentence, with no pull request or issue behind it

The maintainer's question was whether he could add one of his own repositories to Shepherd, start
agents in it directly, and watch every pull request that comes out of it. Everything needed was
already there in pieces — the clone map this ADR introduced, the watch list (ADR 0005's 2026-09-16
amendment), and the new-work worktree of the 2026-09-04 amendment above — but only a pull request or
an issue could start a run, and linking a clone meant typing its `owner/repo` by hand. Two additions,
both inside the decision above.

**"Add a local repository…" starts from the folder.** The user picks a clone; Shepherd runs
`git rev-parse --show-toplevel` in it (no work tree → refused; a picked subfolder links the clone's
root) and `git remote get-url origin` in the root, through the same `ProcessRunning` seam and
`/usr/bin/git` delegation uses — no shell, no request of Shepherd's own. `ShepherdCore/GitRemote`
reads the URL: a github.com `owner/name` in any form git writes (https, `ssh://`, scp-like, `.git`);
a GitHub Enterprise-looking host, **refused**, because Shepherd talks to github.com and nothing else
(`AppConfig` has no configurable host, and CONTRIBUTING.md's host list is the reason); another host,
an unreadable URL or no `origin`, for which the sheet says so and asks for the name. One confirmation
then links the checkout — the same `AppSettings.localCheckouts` map, so *Open in editor* (ADR 0039)
works for it too — and watches the repository through `watchRepository(named:)`, its cap and its
"already watched" rule unchanged; the sweep's immediate refresh is the one every writer of the watch
list gets. Both halves are ticked by default, either can be unticked, and a half already done shows as
done (`ShepherdCore/LocalRepositoryLink`), so adding the same clone twice changes nothing. Checkout
lookups became case-insensitive on the way, because a remote's casing and a row's casing need not
agree.

**A fourth origin, `.repository`: the task text is the prompt.** "Start an agent…" on a watched rail
row with a linked checkout, or ⌘K's *Start an agent on owner/repo…*, opens the delegation sheet with
an empty task field. It is new work in exactly the issue amendment's sense, so it takes that
amendment's shape and a third preamble with its ground rules word for word: a branch **Shepherd**
names, started from the tip of the default branch (the same `addForNewWork(branch:)`, the same
`origin/HEAD` lookup and its "git could not tell which branch" message), which the run may commit to
and publish with its own tool's credentials. What the preamble says instead of an issue number is the
repository and the branch.

- **The branch is named after the task**, because a sentence has no number: `agent/<slug>` from the
  first line (lowercase ASCII, dashes, at most 40 characters, `ShepherdCore/RepositoryTaskBranch`).
  Unlike an issue, a second task is never "the same work again", so where the issue path *resumes*
  an existing branch this one **uniques** the name with a four-hex suffix — against local
  `agent/*` branches, `origin/agent/*` after a fetch, and the managed directories — before git is
  asked to create anything. The worktree is `owner-repo-task-<slug>`. Because the name comes from the
  text, it is chosen when the run starts, not when the sheet opens, and the prompt is built after that
  step.
- **Several tasks per repository, side by side.** The identity is the task, not the repository —
  `repository:owner/name#<uuid>`, minted when the sheet opens, because the slug only exists once the
  text does — so "Start an agent…" always starts a **new** task, each with its own model, branch and
  worktree, and a second never waits for, reveals or replaces the first. The two names are uniqued
  against the other tasks too: picking a slug is split into the part that waits (the fetch and
  `for-each-ref`, `GitWorktree.takenTaskSlugs()`) and the part that does not
  (`freeTaskSlug(for:repo:taken:suffix:)`), and the model makes the pick and records it as its claim
  on the main actor with no suspension in between, against the slugs its siblings have claimed
  (`DelegationCenter.claimedTaskSlugs(in:excluding:)`). Two tasks with the same first line started
  back to back therefore get `agent/<slug>` and `agent/<slug>-<hex>`, even though neither has created
  a branch or a directory when the second one picks. The way back to a task is a list rather than
  the entry point: the rail row's **Agent tasks** submenu names each one with where it is (running,
  finished, failed, stopped) beside **New task…**, and ⌘K has *Show agent task "…" on owner/repo* per
  task; reopening one shows that run — its transcript, diff and push button — rather than a fresh
  sheet that would orphan its worktree. *Run again* in a task's sheet continues in its worktree on its
  branch. *Discard worktree* frees that task only: its claim goes, it leaves the lists, and the
  repository's other tasks carry on. A sheet opened and never run is not listed, and is forgotten
  the moment it leaves the screen. The task list shows under the rail row whether or not the clone
  is still linked — unlinking stops nothing — and only *New task…* needs the link. A new task costs
  one fetch: the slug's, which fails before anything is claimed on an offline Mac, and
  `addForNewWork(branch:fetch:)` skips its own. Stopping a task while its worktree is prepared
  stays *stopped*: a cancellation check after the fetch means nothing is claimed, one after `worktree
  add` keeps the worktree that now exists (and says so in the transcript) without starting the
  agent, and a git error on the way out no longer overwrites the stopped state.
- **When git refuses, the task holds nothing.** A claim is made before `worktree add` runs, so a
  failure there (or in its fetch) releases it again: the branch name is free for the next task and
  for *Try again*, which picks afresh, and the handle goes back to the managed root. The task stays
  listed as *failed*, its sheet showing git's error, *Try again* and **Dismiss task** (only for a
  task with nothing on disk; one with a worktree is discarded instead). *Discard worktree* no longer
  fails on a directory that has gone — half-created, or deleted in Finder: `GitWorktree.remove()`
  skips `git worktree remove` and still runs `git worktree prune`, and for a repository task the
  local branch is then deleted when it exists and `rev-list --count <base>..<branch>` says it holds
  no commit of its own. A branch with commits is kept: Shepherd does not throw work away. There was no cap on attended delegations before and
  there is none now; ADR 0016's cap counts only rule-started runs, which this origin never is.
- **Guardrails unchanged:** turn cap or *No limit*, spend cap, permission mode, allowed tools,
  transcript. **Shepherd pushes nothing** — still only the button, still the user's git credentials.
- **Never automatic.** `DelegationCenter.startAutomatically` refuses the origin outright. No rule of
  ADR 0016 has a condition that could stand for somebody's typed sentence, and the coordinator only
  ever builds a pull-request context, so this is a line of code making that structural rather than a
  property of today's callers.
- **No `delegation.finished` webhook** for it. ADR 0012's envelope identifies a pull request by node
  id, repository and number, and a task has no number; sending `0` would be a payload that lies. The
  enum-only telemetry count (ADR 0036) still records the run. No ✨ brief either, for the issue path's
  reason: the drafter reads a pull request's detail.

**A behaviour change on the issue path, named as such.** A new-work run is allowed to commit, and the
result card compared against `HEAD` — so an issue run that committed everything read as "changed
nothing", and its push button stayed disabled. Both new-work origins now diff from the merge base of
the ref they started from (`GitWorktree.diffStat(since:)`; the merge base rather than the ref, since
the run may have fetched and moved it), count committed work as something to push, and push without
attempting an empty commit. The pull-request origins are untouched.

No host is added: the only network traffic is the user's own git talking to the remote it already
fetches from. No setting is added either — the checkout map and the watch list both existed — so ADR
0014's sync obligation does not change.
