# Spike: can a review finding reach a *remote* Claude Code session?

Status: Open · Date: 2026-09-03 · Feature: [`agent-fleet.md` §2.E](agent-fleet.md) · ADR:
[0030](../adr/0030-session-back-channel.md)

The local path of the session back-channel ships (ADR 0030). The remote path is a **question**, and
this page is the question written down: what the repository already knows, what the local path
*assumes*, what nobody here can verify without a network and an installed CLI, the three commands
that settle it, and what changes in the app depending on the answer.

## What is known (recorded, not guessed)

From ADR 0011, which cites `docs.claude.com` / `code.claude.com` as of 2026-09:

- **Headless mode is the documented integration path.** `claude -p … --output-format stream-json`
  emits newline-delimited JSON with a versioned `system/init` capabilities event, and takes
  `--permission-mode`, `--allowedTools`, `--max-turns`, `--max-budget-usd`. Shepherd's
  `AgentStreamEvent` decodes exactly that, tolerantly.
- **Session resume exists** in the CLI's documented surface (ADR 0011's list ends with "session
  resume"). Shepherd's default local command is built on it:
  `claude --resume {sessionID} -p {message}`.
- **No Swift SDK.** Spawning the user's own CLI is the recommended pattern for a native app, which
  is what `AgentCLIRunner` does.
- **Authentication is not Shepherd's.** Whether a run bills a subscription or an API key is decided
  by the user's own installation and Anthropic's terms. Anthropic does not permit third-party
  products to offer claude.ai login as part of the product, so Shepherd collects, stores and
  injects nothing — and this feature must not become the exception.
- **The trailer is already in the data.** Every commit this repository's own sessions make carries
  `Claude-Session: https://claude.ai/code/session_…`; `CommitInfo.trailers` parses it and
  `SessionReference.parse` reads it.

## What the local path assumes

None of these is verified in this repository. Each is an assumption the shipped default rests on,
and each is one command away from being a fact:

1. **`--resume <id> -p "<message>"` continues a session non-interactively** and returns when the
   turn is over, the way `-p` does for a fresh task.
2. **The id in the trailer is the id `--resume` accepts.** The trailer carries
   `session_01Kc…`; the flag may want exactly that, a prefix of it, or something else entirely.
3. **A session can be resumed from a different working directory.** This is the assumption most
   likely to be wrong: Claude Code keeps sessions per project directory, and Shepherd runs the
   command in the pull request's *detached worktree* (ADR 0011's isolation), not in the clone the
   session was created in. If the directory matters, the resume will not find the session — and the
   fix is a decision, not a patch: run in the clone (losing worktree isolation) or keep the
   worktree and accept that only sessions started there can be answered.
4. **The remote path may not exist at all.** A `claude.ai/code` session lives on Anthropic's side;
   the installed CLI may be able to attach to it, may be able to only *list* it, or may not know
   about it. And if it can, the login it would use is the user's own — which is the only kind of
   login this feature is allowed to involve.

Because of 4, `remoteSessionTemplate` ships **empty** and the button on a remote session says
*Open the session* and links to the URL. Nothing about that is a placeholder to be cleaned up
later: it is the correct behaviour while the question is open.

## The three commands that settle it

Run them on a Mac with the CLI installed and logged in, in this repository's clone. The first is
read-only; the second and third start real runs, so they are capped.

```sh
# 1. What does the installed CLI actually offer?
claude --help | grep -i -e resume -e session -e continue -e cloud -e web

# 2. Does the trailer's id resume a session — and does the directory matter?
ID=$(git log -1 --format=%B | sed -n 's#^Claude-Session: https://claude.ai/code/##p')
claude --resume "$ID" --max-turns 1 -p 'Answer with the single word: reachable.'
cd "$HOME/Library/Application Support/Shepherd/Worktrees" && \
  claude --resume "$ID" --max-turns 1 -p 'Answer with the single word: reachable.'

# 3. Does the CLI know about sessions that were started on claude.ai/code?
claude --resume   # the interactive picker: are the remote sessions in the list?
```

Command 2 is two runs on purpose: the first says whether the *id* works, the second whether the
*worktree* does. If run one answers and run two does not, assumption 3 above is false and the
decision is the one named in it.

## The decision rule

| Outcome | What changes |
|---|---|
| 2 works in both directories | Nothing. The shipped default is correct as it is. |
| 2 works only in the clone | Either run session sends in the clone (an ADR 0011 amendment, because it gives up the worktree) or keep the worktree and say in Settings that only sessions started there can be answered. Write down which. |
| 2 fails everywhere | Change the local default: whatever flag command 1 revealed, or clear the field so the local button also becomes a link. |
| 3 lists remote sessions and 2 resumes one | Fill in `remoteSessionTemplate`'s default with the command that worked, note the login it used, and change the remote button from a link to a send. Both templates then behave identically. |
| 3 does not | The remote template stays empty and the link stays. Record the CLI version the answer was true for. |

Whatever the answer, three things do not move: Shepherd holds no Anthropic credentials, the comment
is still posted to GitHub, and a session send resolves nothing and submits nothing (ADR 0030).
