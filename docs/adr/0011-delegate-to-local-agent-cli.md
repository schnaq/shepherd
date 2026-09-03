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
