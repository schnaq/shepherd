# ADR 0030: The session back-channel — a finding may be addressed to the session that wrote the code

Status: Accepted (v1.2) · Date: 2026-09-03 · Amends: [0011](0011-delegate-to-local-agent-cli.md) ·
Builds on: [0008](0008-agent-provenance-first-class.md) ·
Plan: [`agent-fleet.md` §2.E](../plans/agent-fleet.md)

## Context

Every pull request Claude Code opens carries its own return address: each head commit has a
`Claude-Session: https://claude.ai/code/session_…` trailer, and `CommitInfo.trailers` has parsed
trailers since ADR 0008. The reviewer's finding, meanwhile, goes to GitHub and waits for somebody
— or something — to read it. The maintainer interview behind the plan asked for the shorter path:
the finding goes back to the conversation that produced the code, which fixes it and pushes, and
the next sync opens *Since your review* (ADR 0028).

The obvious transport is the Claude Code Remote API with the session id from the trailer. ADR 0011
rules that out in its own words: **Shepherd does not touch agent authentication** and never
collects or injects Anthropic credentials. A Shepherd that called a Remote API on the user's behalf
would need a token, would have to store it, and would make the app a party to a login Anthropic
does not permit third-party products to offer.

## Decision

A review finding — an inline one, or the review summary — **may be addressed to the session named
in the pull request's head commits, through the user's own installed CLI, and never through
credentials Shepherd holds.**

- **The return address is read, not fetched.** `SessionReference.parse(trailers:)` in
  `ShepherdCore/Agents/` extracts id, URL, host and kind (`local` / `remote`) from
  `Claude-Session:` lines; `mostRecent(in:)` takes the last commit's, because a fix round pushed
  from a second session must be answered at that one. A malformed value yields no reference at all.
  No new read, no new host, nothing stored.
- **The transport is ADR 0011's, unchanged.** The message is carried by a **second command
  template** beside the existing one — `claude --resume {sessionID} -p {message}` by default —
  split by `ShellWords` and substituted *after* splitting, so the message is exactly one argv
  element and no shell is ever involved. It runs in the pull request's detached worktree, streams
  into the same delegation panel, keeps the same local transcript, and nothing is ever pushed for
  it. The environment is inherited verbatim: the CLI brings its own login, and Shepherd neither
  adds nor strips a variable.
- **The remote path is a question, and says so.** The remote template is **empty by default**, and
  a remote session's button then reads *Open the session* and links to the URL. Whether the
  installed CLI can address a `claude.ai/code` session at all, and under which login, is written
  up with the three commands that settle it in
  [`session-back-channel-spike.md`](../plans/session-back-channel-spike.md). Filling that default
  in is a settings change, not a credential change.
- **The message is the reviewer's, shown before it is sent.** `SessionMessage.compose` produces
  one template — the location, the reviewer's text verbatim, the pull request link, and the review
  round when Shepherd knows it — and a confirmation sheet shows *that string* before anything
  runs. What was shown is what is sent, because there is one composition, not two.
- **Sending is not a review action.** It does not resolve the thread, does not approve, does not
  submit a review and does not consult or record an automatic-delegation rule (ADR 0016 is not
  involved). The GitHub comment is still written the way it always was — from the inline composer,
  Send saves the comment to the pending review exactly as *Add comment* does, and a comment that
  could not be saved sends nothing. **The thread stays the record.**
- **The reviewer's own words only.** The context a session send builds carries the reviewer's text
  with no author attached, which is what "the reviewer's own" means everywhere else in the app; a
  colleague's comment does not travel here, for ADR 0011's amendment's reason. No brief drafter is
  attached to a session delegation either: the text is already confirmed, so there is nothing for
  a model to write into.
- **On the inbox row**, a small session glyph marks the pull requests that have a return address,
  read from the details already in the local database — machine-authored rows only, capped, never
  a fetch.

## Consequences

- One new pure type in `ShepherdCore` (`SessionReference`), one pure composer (`SessionMessage`),
  two settings, one confirmation sheet, one glyph, and no new host, outbox action or migration.
  *Open the session* hands the trailer's URL to the browser and Shepherd itself requests nothing —
  the same category as the CLI's documentation link, so `CONTRIBUTING.md`'s list of hosts Shepherd
  may contact is unchanged.
- The two templates travel with `agentCLI` in the settings-sync document (ADR 0014), for the reason
  the existing command template does: they are part of how the CLI is invoked, and they are
  commands rather than credentials. A document written before they existed decodes to their
  defaults, so an older Mac cannot silently switch the feature off on a newer one.
- Guardrails: worktree isolation, the local transcript and "Shepherd never pushes" apply
  unchanged. The turn and spend caps live *in the template*, exactly as they do for any other
  custom command — Shepherd does not know that a command the user configured accepts Claude
  Code's flags, and the Settings copy says which flags to add.
- If Anthropic's third-party auth rules move again, this feature moves with ADR 0011 and not
  separately, because it brokers nothing.
- What was rejected: a Shepherd-side Remote API call (needs a credential), a proxy (needs a host),
  and auto-resolving the thread on send (the thread is the record, and the reviewer decides when a
  finding is answered).
