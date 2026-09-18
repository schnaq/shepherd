# ADR 0017: Crash and hang reports stay on the Mac — MetricKit, opt-in, no uploader

Status: Accepted (v1.x scope) · Date: 2026-09-01

## Context

Shepherd is a native app that runs long sessions, drives a WKWebView, spawns subprocesses and
holds unsent review drafts in a local database. It will hang and it will crash, and today the
maintainers learn about neither: a user who loses a review to a crash has an `.ips` file somewhere
in `~/Library/Logs/DiagnosticReports` that they will never find, and no way to say more than "it
quit".

The industry answer is a crash-reporting SDK — Sentry, Crashlytics, Bugsnag. Every one of them is
a third-party binary in the app that phones a vendor. That is not a trade-off we get to make:
CONTRIBUTING.md's "No telemetry, ever" is a hard line with an exhaustive list of hosts Shepherd may
contact, ADR 0009 keeps the dependency surface small, and NOTICES.md exists so that everything
shipping inside the app is named. A crash reporter would violate the first, grow the second and
need a line in the third — and it would do so in the one direction the project has been most
careful about.

But the *diagnostic* half and the *transmission* half are separable, and Apple already separated
them. MetricKit (macOS 12+, so free at ADR 0002's macOS 26 floor) delivers `MXDiagnosticPayload`
objects to the app itself on the next launch after the event: crash, hang, CPU-exception and
disk-write-exception diagnostics, with call stacks, as JSON the app is handed and may do whatever
it likes with — including nothing. No SDK, no vendor, no account, and no network unless the app
adds one.

## Decision

- **MetricKit, no third-party SDK.** One subscriber (`Shepherd/Diagnostics/DiagnosticsReporter`,
  the only file that imports MetricKit) receives `didReceive(_ payloads: [MXDiagnosticPayload])`
  and writes each payload's `jsonRepresentation()` to a file. Zero new dependencies, so no
  NOTICES.md line and nothing new inside the app bundle.
- **Local, and structurally so.** Reports go to
  `~/Library/Application Support/Shepherd/Diagnostics/` as
  `diagnostic-<UTC timestamp>Z.json`, beside the database (ADR 0006) and reached through the same
  `AppConfig` accessor. There is no uploader, no endpoint, no queue and no "send" button — not
  disabled, *absent*. The privacy line in CONTRIBUTING.md does not move: the host list is
  unchanged, because there is no host.
- **Opt-in, off by default, gated at the registration.** `AppSettings.diagnosticsEnabled` is what
  calls `MXMetricManager.shared.add(_:)`; with it false, MetricKit has no subscriber, delivers
  nothing, and there is nothing to filter or discard. Switching it off calls `remove(_:)`. Same
  shape as `webhooksEnabled` (ADR 0012), `settingsSyncEnabled` (ADR 0014) and
  `AutoDelegationRules.isEnabled` (ADR 0016): one flag that gates the mechanism, not the output.
- **Metric payloads are dropped explicitly.** MetricKit's other delivery, `MXMetricPayload`, is
  daily performance telemetry. The subscriber implements the method as a documented no-op rather
  than leaving the behaviour to whether a method happens to be present.
- **The user owns the folder.** Settings → Account shows the count, the path, "Show in Finder"
  (which selects the newest report) and "Delete all". Thirty reports are kept; the oldest are
  deleted as new ones arrive, so the folder cannot grow without bound and nothing needs pruning by
  hand.
- **Placement and the seam.** `DiagnosticsStore` — names, retention, count, deletion — is a
  separate type from the subscriber and takes its directory and `FileManager` by injection, because
  `MXDiagnosticPayload` cannot be constructed and the only testable seam is the one below it:
  `store(jsonRepresentation:receivedAt:)`. The app target, not ShepherdKit: MetricKit is
  Apple-only and `Packages/ShepherdKit` must keep building on Linux.
- **The opt-in travels, the reports do not.** The flag is a setting, so it is carried in
  `SyncedSettingsDocument.DiagnosticsGroup` and in both directions of `SettingsSyncApplier`, as
  CONTRIBUTING.md requires of every setting. A report is machine-local state — one crash, one
  build, one Mac — and belongs with the outbox and the auto-delegation ledger among the things
  deliberately left out of the document.

## Consequences

- A user who wants to help can now attach a real call stack to an issue, from a folder they opened
  themselves, having read the file first. That is a *better* bug report than an SDK would have
  produced, because nothing arrives that the user did not choose to send.
- The maintainers still learn nothing automatically. That is the cost, and it is the point: the
  alternative was a vendor endpoint. If aggregate crash data is ever wanted, it needs its own ADR,
  a host in CONTRIBUTING.md and a second, separate opt-in — not a quiet extension of this one.
- Delivery is on MetricKit's schedule: nothing appears while the app is crashing, and a report
  shows up on the *next* launch. The Settings card says so, because a card that did not would look
  broken at exactly the moment the user goes looking.
- "Sign out & erase local data" leaves the folder alone. A diagnostic report describes a build on a
  Mac, not a GitHub account, and it holds no repository content, no review text and no token —
  "Delete all" is the button that removes it, and the confirmation dialog for sign-out keeps
  promising exactly what it promised before.
- The reports are unencrypted JSON in Application Support, which is the same trust boundary the
  database already sits behind (ADR 0006). They contain Apple's diagnostic data — stack frames,
  binary images, the app's own paths — and no Shepherd content, no bucket credentials and no token,
  because none of those are what MetricKit collects.

**Amendment, 2026-09-18 (ADR 0036).** The second opt-in this section asked for now exists — for
*usage* data, not for crash data. ADR 0036 adds allow-listed usage telemetry with its own host in
CONTRIBUTING.md and its own setting, and CONTRIBUTING.md's "No telemetry, ever" bullet has been
replaced accordingly. Nothing in *this* ADR moves: MetricKit payloads are still written to a folder
on the Mac, there is still no uploader for them, and aggregate crash reporting would still need an
ADR of its own.
