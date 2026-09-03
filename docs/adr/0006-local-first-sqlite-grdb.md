# ADR 0006: Local-first — SQLite via GRDB as the app's source of truth

Status: Accepted · Date: 2026-08-31

## Context

The product premise is "everything stored locally": instant cold start from cache, offline
reading, drafts that survive restarts, no backend. This is also the single structural
differentiator against every cloud-first competitor
([research](../research/research-landscape.md)). GRDB.swift is the mature Swift SQLite
toolkit: migrations, typed queries, `DatabasePool`, and `ValueObservation` for reactive UI
updates straight off the cache.

## Decision

- All GitHub state Shepherd has seen (repos, PRs, files/diffs, threads, comments, checks,
  authors) is cached in a **SQLite database (GRDB)** in `~/Library/Application Support/Shepherd/`.
- The UI **always renders from the database** (via `ValueObservation`); the sync engine
  refreshes the database in the background. GitHub is a remote to sync with, not the model.
- **Review drafts live locally first**: pending review state (comments, verdict) is written to
  the DB immediately and pushed to GitHub explicitly, so a draft survives crash/offline.
  Outbound actions go through a persisted **outbox** with retry.
- Tokens are *not* in the database (Keychain only, ADR 0004). A "Sign out & erase" action
  deletes the DB.

## Consequences

- Inbox opens instantly with last-known state, works on the train, and never blocks on the
  network.
- Sync conflicts are possible (e.g. commenting on a PR that just got new commits); the sync
  engine re-validates before submit and surfaces conflicts instead of silently failing.
- Schema migrations are mandatory discipline from v1 (GRDB migrator, append-only).

## Amendment (2026-09-03): the third outbox state, and the first thing a user may do to a row

The original decision names two ways an outbound write can end badly: it is retried, or it is
surfaced as a conflict for the user to decide about. `OutboxState` has always had a third —
`failed`, "it failed in a way retrying cannot fix": a 4xx from GitHub, or a port the app was built
without. Nothing in this ADR said what happens to such a row, and so nothing did. It was neither
counted by `pendingOutboxCount()` nor by `conflictedOutboxCount()`, no `SyncEvent` outlived the
one-off `syncFailed` banner, and the queue never touched it again. A review or a comment the user
believed they had sent could sit there for ever with nothing on screen to say so.

Two things follow, and the second is genuinely new behaviour rather than a missing display:

- **It is a standing count, like the other two.** `failedOutboxCount()` /
  `observeFailedOutboxCount()` sit beside their siblings, `SignedInSession` publishes all three,
  and every surface that describes the outbox says all three: Settings → Sync, the title bar's sync
  indicator, and the morning digest — which was already reporting the parked count and is exactly
  the unattended moment at which "this will never arrive" is worth saying.
- **A failed row gets two buttons, and it is the only row that does.** Settings → Sync lists them
  by target, by what the write would have done, and by the reason already stored in
  `outbox.lastError`, with **Retry** (`retryOutboxItem(id:)` — back to `pending`, `attemptCount`
  and `nextAttemptAt` reset, then an ordinary drain) and **Discard** (`deleteOutboxItem(id:)`).

Retry is not another rung of `OutboxBackoff` and must not become one: `failed` means the queue has
established that time cannot help, so the next attempt only makes sense because a *person* changed
something the queue cannot see — a token, a permission, a branch rule. That is why it is a click
rather than a schedule, and why the row starts from zero instead of resuming a backoff that had
already run out. The write itself still goes out the one way any write does (drain, preflight,
`mutationSent`); nothing here lets a screen reach GitHub.

Parked rows are deliberately left as they were. A conflicted review is re-applied against the new
commit from the pull request it belongs to, where the draft and the diff are — offering to fling it
back at GitHub from a settings window would be the blind submit this ADR exists to prevent. The
`state = 'failed'` guard on `retryOutboxItem(id:)` enforces both halves of that: it cannot touch a
parked row, and it cannot pull a row out from under a drain that is currently sending it.

No schema change: `lastError` and `attemptCount` are columns the outbox has always had.
