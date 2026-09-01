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
- Scheduled for v1.x (after the v1 review core has proven itself in daily use).
