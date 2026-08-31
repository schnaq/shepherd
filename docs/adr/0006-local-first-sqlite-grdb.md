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
