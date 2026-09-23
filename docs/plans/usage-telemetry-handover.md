# Handover: usage telemetry

Status: done (v1.2.0), see [ADR 0036](../adr/0036-usage-telemetry.md) and
[docs/PRIVACY.md](../PRIVACY.md)

Branch: `feat/usage-telemetry` · Date: 2026-09-18 · Base: `main` at `632125b`

Everything on this branch is **documentation**. No Swift file has been touched, no build setting
has changed, and the app behaves exactly as `main` does. What exists is a decided design and a
task-by-task plan to build it.

## Read in this order

1. [`docs/plans/usage-telemetry.md`](usage-telemetry.md) — the spec. The *why*, the legal model, the
   event allow-list, the payload, the risks. Read this before touching anything; every choice in
   the plan argues from it.
2. [`docs/plans/usage-telemetry-implementation.md`](usage-telemetry-implementation.md) — thirteen
   tasks, each with the failing test first, the real code second, and a commit at the end.

## What is already decided, and should not be re-opened without a reason

| Decision | Value |
|---|---|
| Sink | PostHog **EU** Cloud, project 277838, no SDK — one `URLSession` `POST` to `https://eu.i.posthog.com/batch/` |
| Levels | `off` / `anonymous` (default, no identifier at all) / `reach` (opt-in, random UUID re-minted every UTC month) |
| First run | A **notice**, not a consent dialog: `Verstanden` / `Nutzungsstatistik ausschalten` / `Auch Reichweite messen`. Nothing is recorded before it is answered |
| Counting | `app_active_day`, once per installation per UTC day, de-duplicated locally against a stored date. Not per launch — Shepherd stays open for weeks |
| Allow-list | Thirteen events, every property an enum or a bucket. `String` never appears as a payload input |
| Key | `POSTHOG_TOKEN` GitHub secret → written into `Info.plist` **before signing**. `project.yml` keeps an empty placeholder, so dev builds, test runs and forks have no mechanism at all |
| Withdrawal | Erases: `off` deletes queue, heartbeat date and monthly UUID; leaving `reach` deletes the UUID |

## What is left to do

- **Tasks 1–13 of the implementation plan.** Task 1 (ADR 0036 + the amendment to ADR 0017) is the
  natural first sitting; Task 13 (README badge, `CONTRIBUTING.md` host list, `docs/PRIVACY.md`) is
  deliberately last, because until the code exists those sentences would be promises about nothing.
- **Three greps in Task 9, Step 3.** The plan names settings properties from the spec
  (`autoMergeEnabled`, `autoDelegationEnabled`, `digestEnabled`, …). Verify each against
  `Shepherd/Support/AppSettings.swift` before writing the launch heartbeat; where a flag lives
  inside a rules object instead, read that object's own `isEnabled` rather than inventing a setting.
- **Task 10's call sites.** Twelve one-line `environment.telemetry?.record(…)` calls in feature code
  the plan locates by `grep` rather than by line number. Each goes where the action has *already
  succeeded* — recording an intent would measure clicking, not doing.
- **The PostHog project checklist** (ADR 0036 § Consequences, spec § 6), at
  `https://eu.posthog.com/project/277838`: GeoIP plugin off, "Discard client IP data" on if the plan
  offers it, retention set explicitly, session recording / autocapture / surveys off. None of this
  is enforceable from Swift, and the privacy claim leans on it.
- **A legal read.** The spec states its own weak point in § 10: a strict reading of § 25(1) TDDDG
  covers *any* storage, including the unsent queue and the heartbeat date. Neither identifies a
  device and neither is transmitted, and the notice precedes the first event — but the final call
  belongs to the data-protection officer, not to this branch.

## How to work on it

```bash
git checkout feat/usage-telemetry
mise run gen          # regenerate Shepherd.xcodeproj after project.yml changes
mise run test-app     # the app test suite, in English as CI runs it
mise run check        # localisation + type scale, the two invariants the compiler misses
mise run ci           # everything, in CI's order — run before opening the PR
```

The new test file is `ShepherdTests/TelemetryTests.swift`; it grows with every task and follows
`ShepherdTests/DiagnosticsTests.swift`'s shape (own `UserDefaults` suite and own temporary
directory per test, never the real Application Support folder).

**You will not see telemetry while developing.** A development build has no `SHPostHogProjectKey`,
so `UsageTelemetry.make` answers `nil` and the first-run sheet never appears. That is the design,
not a bug. To exercise it end to end, set the key temporarily in `project.yml`, run, and revert
before committing — never weaken the `nil` check to make the sheet show up.

## One thing that is not in this branch on purpose

Positioning. Telemetry makes schnaq GmbH the *Verantwortlicher* in the GDPR sense, and
`docs/PRIVACY.md` plus the first-run sheet will be the first places a user reads "schnaq" as the
company behind Shepherd rather than as a line in `LICENSE`. That is a marketing and positioning
question — badge language, website, the relationship between the MIT project and the product — and
it deserves its own round rather than being decided inside a telemetry plan.

## Commits on this branch

- `97f1d5b` — the spec
- (this commit) — the implementation plan and this handover
