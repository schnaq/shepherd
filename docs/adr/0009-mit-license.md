# ADR 0009: MIT license

Status: Accepted · Date: 2026-08-31

## Context

The project is open source by founding intent. Candidates: MIT (permissive, de-facto standard
for developer tools, lowest contributor friction), Apache 2.0 (adds explicit patent grant),
AGPL (protects against closed SaaS forks — but Shepherd is a local desktop app with no server
component to protect, and AGPL scares off corporate contributors).

## Decision

**MIT**, single `LICENSE` file at the repo root, copyright "The Shepherd contributors".
Dependencies must be MIT/Apache-2.0/BSD-compatible; Monaco (MIT), GRDB (MIT), Sparkle (MIT)
all qualify.

## Consequences

- Anyone may fork, embed, or commercialize; we accept this deliberately — distribution and
  community are worth more to this project than exclusivity.
- Third-party license attributions ship in the app's About window and `NOTICES.md` as
  dependencies are added.
