# Usage telemetry: anonymous by default, reach by consent

Status: done (v1.2.0), see [ADR 0036](../adr/0036-usage-telemetry.md) and
[docs/PRIVACY.md](../PRIVACY.md) — amended 2026-09-22: the anonymous level is now off until asked,
not on by default as this plan's title still reads · Date: 2026-09-18 · Source: maintainer decision
2026-09-18 · Scope: v1.2

Shepherd ships a badge that says `telemetry: none`, a `CONTRIBUTING.md` bullet that says "No
telemetry, ever", and an ADR (0017) that turned down a crash-reporting SDK on the strength of both.
This plan retires that promise on purpose and replaces it with a narrower one that the code can
keep: **anonymous usage counts, off in one click, and a second, consented level that is the only
thing able to recognise a Mac twice.**

The reason is not curiosity. Shepherd is developed against guesses about which half of it is used,
and `download_count` on a GitHub release cannot tell whether an installation launched once or is
somebody's daily inbox. The cost of that guessing is paid in features built for nobody.

Companion documents: [ADR 0017](../adr/0017-local-diagnostics-metrickit.md) (whose reasoning this
plan amends rather than contradicts), [ADR 0012](../adr/0012-outbound-webhooks.md) and
[ADR 0014](../adr/0014-encrypted-settings-sync.md) (the opt-in shape this one copies).

---

## 0. What the maintainer decided

| Question | Answer | Consequence |
|---|---|---|
| Sink | PostHog EU Cloud, project 277838 | Contracts and operations already exist at schnaq; no new backend, no ClickHouse, no Postgres of our own |
| SDK? | No | One `URLSession` `POST`. No entry in `NOTICES.md`, no movement on ADR 0009's dependency surface, no autocapture to switch off |
| Default | Level 1 (anonymous) on, after a first-run sheet; level 2 (reach) opt-in | Variant B of three considered; A was "on, notice only", C was "everything off until asked" |
| Identity | No identifier at level 1. A randomly regenerated monthly UUID at level 2 | No root secret exists, so cross-month linkage is impossible for us as well as for anyone else |
| Counting active installations | One `app_active_day` heartbeat per installation per UTC day, de-duplicated on the Mac against a stored date — not against an identifier | Level 1 yields daily active installations without anything the server could recognise twice; level 2's monthly UUID turns the same heartbeat into MAU |
| Key handling | `POSTHOG_TOKEN` GitHub secret, written into the app bundle's `Info.plist` at release time | Dev builds, test runs and forks have no key and therefore no mechanism |
| Crash data | Unchanged — stays local (ADR 0017) | This plan adds no uploader for MetricKit payloads |

---

## 1. The legal model, and why the two levels exist

The controlling rule is **§ 25 TDDDG**, and it attaches to *storing information on the device*, not
to sending it. Anything Shepherd writes to the Mac in order to recognise it later needs consent,
however anonymous the later analysis is. Write nothing, and § 25 does not apply. What remains is
the transmission itself, which briefly processes an IP address; that is carried by Art. 6(1)(f)
GDPR as long as the address is neither stored nor used for recognition.

That splits cleanly:

**Level 1 — `anonymous`. No consent required, switchable off.**

- `distinct_id` is a UUID created in memory at launch, held only in the queue of unsent events and
  gone once that queue is flushed. It is never stored in `UserDefaults`, never in the Keychain, and
  never survives a restart, so nothing on the server can be tied to anything else.
- What *is* stored on the Mac: the queue of unsent events, the date of the last heartbeat (a date,
  not an identifier — see § 1.1), the chosen level and the acknowledgement flag. The last two are
  the user's own preference, and § 25(2) TDDDG covers storage strictly necessary for the service
  the user asked for — remembering "do not send anything" is precisely that. The first two are
  operational state that identifies nothing; a strict reading of § 25(1) covers any storage at all,
  which is why the notice comes before the first event rather than after it (see § 10).
- The payload carries an allow-listed event name, the app version, the macOS major version and the
  UI language. Nothing else.
- `"$ip": null` on every event, and the project's GeoIP enrichment is off — both, because the
  plugin falls back to the sender's address when the property is *absent*, and `null` is a
  property, not its absence.
- What this measures: **daily active installations** (§ 1.1), version spread, which features are
  switched on, how often each allow-listed action happens, German vs. English. What it cannot
  measure: monthly active users, retention, "x % of users do y" — all three need a Mac to be
  recognisable across days, which level 1 refuses. That limitation is the price of needing no
  consent, and it is not to be worked around.
- The switch exists anyway: Art. 21 gives a right to object to processing based on legitimate
  interest, and a project with this badge owes the switch regardless.

### 1.1 Counting a day without counting a person

Shepherd is a long-session app — the menu-bar inbox stays open for weeks, which is why ADR 0017
worries about hangs at all. An event fired at launch would therefore count the heaviest users
*least*: three weeks of daily use, one launch. The heartbeat fixes this without buying identity.

`app_active_day` is emitted at launch and again whenever a running app crosses the UTC day
boundary, and `TelemetryHeartbeat` suppresses it when the stored `lastHeartbeatDay` already equals
today. Two launches on the same day therefore produce one event, and a Mac left running for three
weeks produces twenty-one. The count of `app_active_day` events per day *is* the number of active
installations that day — derived on the Mac, not from anything the server recognises.

The stored value is a date. It cannot identify a Mac, it is not sent, and it is deleted with the
queue when the level goes to `off`. At level 2 the same heartbeat, carrying the monthly UUID,
yields monthly active users directly.

**Level 2 — `reach`. Consent, and consent only.**

- A random UUID in `UserDefaults` alongside the UTC month it was minted in. On the first event of a
  new month it is thrown away and a new one is minted.
- Legal basis Art. 6(1)(a) GDPR plus § 25(1) TDDDG, both satisfied by the explicit opt-in.
- Withdrawal is the picker: dropping to `anonymous` deletes the stored UUID, dropping to `off`
  deletes the UUID and the queue. Withdrawal therefore *erases*, it does not merely stop.

**Nothing is recorded before the first-run sheet is answered.** A second flag,
`telemetryNoticeAcknowledged`, holds the mechanism back until then. This is the whole practical
difference between the chosen variant and "on by default with a notice somewhere".

The sheet is **notice, not consent**, and its wording has to match the legal basis it rests on.
Level 1 runs on legitimate interest with a right to object, so the sheet states what is sent and
offers an immediate way out — buttons `Verstanden` and `Nutzungsstatistik ausschalten`, plus a
third, quieter `Auch Reichweite messen` that opts into level 2. What it must *not* be is a
symmetrical yes/no question: consent that is pre-selected is not consent (Planet49), and a sheet
shaped like a consent dialog would put the whole of level 1 on a basis it does not have.

Controller is schnaq GmbH, processor is PostHog (EU region). `docs/PRIVACY.md` names both.

---

## 2. The event allow-list

Thirteen events. The design rule that makes the privacy claim structural rather than aspirational:
**`String` does not appear in the payload type.** Event names are an `enum`, properties are `enum`,
`Bool`, or a coarse bucket. Sending a repository name is a compile error, not a review miss. Counts
are bucketed because "37 repositories" identifies better than "21+".

| Event | Properties | Answers |
|---|---|---|
| `app_active_day` | `repo_count`, `inbox_size` (buckets `1-2 / 3-5 / 6-20 / 21+`), `diff_renderer` (`monaco / native`), `intelligence` (`none / on_device / cloud / both`), flags `webhooks`, `settings_sync`, `auto_merge`, `auto_delegation`, `digest`, `menu_bar`, `diagnostics` | Daily active installations (§ 1.1), version spread, **which features are enabled at all** |
| `review_submitted` | `kind` (`approve / request_changes / comment`), `inline_comments` (`0 / 1-3 / 4-10 / 11+`), `used_template`, `used_saved_reply` | Whether reviewing happens or waving-through does |
| `pull_request_merged` | `method` (`merge / squash / rebase`), `source` (`detail / bulk / auto_rule / when_checks_pass / series`) | How merging happens |
| `focus_session_completed` | `queue_size` (bucket), `completed` | Whether the headline feature carries |
| `bulk_triage_performed` | `action` (`approve / merge`), `size` (bucket) | |
| `search_used` | `kind` (`semantic / reference`), `opened_result` | Whether ⌘K earns the embedding work |
| `delegation_started` | `trigger` (`manual / ci_red_rule`) | |
| `delegation_finished` | `outcome` (`applied / discarded / budget_exceeded / failed`) | Whether delegation is abandoned in practice |
| `intelligence_used` | `feature` (`brief / draft_comment / explain / ci_diagnosis / thread_digest / claims`), `tier` (`on_device / pcc / cloud`), `outcome` (`ok / too_large / unavailable / error`) | Which tier carries, how often on-device suffices |
| `auto_merge_rule_fired` | `outcome` (`merged / skipped`) | |
| `issues_inbox_used` | `action` (`viewed / commented / labeled / assigned / closed`) | |
| `fleet_viewed` | `scope` (`all / repo`) | |
| `digest_opened` | `source` (`notification / menu_bar / app`) | |

Deliberately absent: navigation, clicks, scrolling, dwell time, error messages (crashes remain
ADR 0017's local files), and anything that would need a free-form string.

---

## 3. The payload

```json
{
  "api_key": "phc_…",
  "batch": [
    {
      "event": "review_submitted",
      "timestamp": "2026-09-18T00:00:00Z",
      "properties": {
        "distinct_id": "9F3C…",
        "$process_person_profile": false,
        "$ip": null,
        "$lib": "shepherd",
        "app_version": "1.1.0",
        "os_major": 26,
        "locale": "de",
        "kind": "approve",
        "inline_comments": "1-3",
        "used_template": true,
        "used_saved_reply": false
      }
    }
  ]
}
```

Three details are decisions rather than defaults:

- **`$process_person_profile: false`** on every event. PostHog then keeps no person object, so
  nothing accumulates a history; unique counting still works off `distinct_id` on the events, which
  is exactly the amount of identity level 2 buys and level 1 does not.
- **`timestamp` truncated to the UTC day.** Omitting it is worse: PostHog would stamp ingestion
  time, so a week offline collapses onto one day. A full timestamp is worse in the other
  direction — it describes working hours. The day is the resolution the dashboards use anyway.
- **`$ip: null`**, paired with GeoIP off in the project. See § 1.

Volume: at 1 000 active installations, roughly 100–200 k events a month.

---

## 4. Client architecture

New directory `Shepherd/Telemetry/` in the app target, mirroring `Shepherd/Diagnostics/`. Five
types, one job each.

| Type | Job | Test seam |
|---|---|---|
| `TelemetryEvent` | The enum from § 2 with associated enum values; renders itself to name + properties | Pure value |
| `TelemetryIdentity` | Supplies `distinct_id`: in-memory UUID at level 1, stored monthly UUID at level 2, `clear()` on downgrade | Clock injected |
| `TelemetryHeartbeat` | Decides whether `app_active_day` is due: compares today's UTC date against the stored `lastHeartbeatDay`, and schedules the day-boundary wake-up for a running app | Clock injected |
| `TelemetryQueue` | `~/Library/Application Support/Shepherd/Telemetry/queue.json`, capped at 500 events, oldest dropped, atomic writes, readable JSON on purpose | Directory injected |
| `TelemetrySender` | Protocol with one method; `PostHogSender` posts to `https://eu.i.posthog.com/batch/` through `CredentialSafeSession` | Fake sender in tests |
| `UsageTelemetry` | The façade: `record(_:)`, flush schedule, level changes | Everything above injected |

Wiring follows the diagnostics precedent exactly: `AppEnvironment.applyTelemetryLevel()` is called
from launch, from the settings picker and from an applied settings-sync document, and is
idempotent — the same three callers `DiagnosticsReporter.setSubscribed(_:)` has.

**The mechanism is constructed, not filtered.** `UsageTelemetry` exists only when
`SHPostHogProjectKey` is non-empty *and* the level is not `off`. Otherwise the reference is `nil`,
`record(_:)` is a no-op, and there is no queue file, no timer and no request — the same shape as a
`DiagnosticsReporter` that never registers with MetricKit, and the same shape as `UpdateController`
refusing to start without a valid Sparkle key.

**Level changes clean up.** `→ off`: timer stopped, `queue.json` deleted, monthly UUID deleted.
`reach → anonymous`: monthly UUID deleted. Withdrawal erases.

**Flush.** Once about 30 seconds after launch, then every 24 hours. Never on the launch path, never
blocking. Three attempts per batch, then the batch is dropped; no retry loop can turn a bad network
into a busy one.

**Settings.** Settings → Account, below the diagnostics block: a three-way picker
(`Aus / Anonym / Anonym + Reichweite`), "Zeigen, was gesendet würde" rendering the real `queue.json`
plus one example event, and "Warteschlange löschen".

**Settings sync.** `SyncedSettingsDocument.TelemetryGroup { level, noticeAcknowledged }`, carried
both ways in `SettingsSyncApplier`. The queue, the heartbeat date and the monthly UUID are
machine-local and stay out of the document, beside the outbox and the delegation ledger.

The group is **optional, and absent means "do not touch"** — not "apply the default". A document
written by a Mac still running 1.1 has no telemetry group, and applying a default of `anonymous`
would silently switch telemetry back on for somebody who had turned it off. `diagnosticsEnabled`
could be careless here because its default is `false`; this one cannot. `schemaVersion` therefore
need not move, and an applied `off` also marks the notice as acknowledged, so the sheet does not
appear on the second Mac to ask a question the first one already answered.

---

## 5. Build-time key injection

- `project.yml` gains an `Info.plist` entry `SHPostHogProjectKey` with an **empty** default and a
  comment in the style of `SUPublicEDKey`'s: empty means the mechanism does not exist.
- `.github/workflows/release.yml` writes the real value **before** code signing, since the signature
  covers `Info.plist`:

  ```yaml
  env:
    POSTHOG_TOKEN: ${{ secrets.POSTHOG_TOKEN }}
  run: plutil -replace SHPostHogProjectKey -string "$POSTHOG_TOKEN" "$APP/Contents/Info.plist"
  ```

- `AppConfig` exposes it and returns `nil` when empty.
- A `phc_` key is a *public* write key: it ships inside the binary and `strings` will find it. The
  secret store buys build hygiene, not confidentiality — and the consequence, that anybody can post
  events to the project, is why the dashboards are indicators rather than bookkeeping. `PRIVACY.md`
  and any public dashboard say so.

---

## 6. PostHog project configuration (not enforceable from the app)

Checklist for `https://eu.posthog.com/project/277838`, to be repeated in ADR 0036:

1. GeoIP plugin **off**.
2. "Discard client IP data" enabled if the project offers it.
3. Retention set explicitly. If the plan does not allow configuring it, `docs/PRIVACY.md` states
   PostHog's actual retention honestly; the storage-limitation argument then rests on the
   anonymity of the data (no profile, no IP, rotating or absent identifier), not on a knob we do
   not have.
4. Session recording, autocapture and surveys off — irrelevant without an SDK, set anyway so a
   future SDK cannot inherit them.

---

## 7. Documentation surface

This is where most of the work is, and almost none of the code.

- **ADR 0036**, new: the decision, the two levels, the legal bases, PostHog EU as processor, why no
  SDK, and the § 6 checklist.
- **ADR 0017**, amendment line: its text calls "no telemetry, ever" a hard line and demands that any
  aggregate reporting get its own ADR, its own host and its own opt-in. That is what happens here,
  and it has to be said there, or two ADRs disagree.
- **`CONTRIBUTING.md`**: the "No telemetry, ever." bullet becomes a statement of what telemetry is
  allowed to be, and `eu.i.posthog.com` joins the exhaustive host list in the existing style —
  when, what, how often, and that level `off` contacts nothing.
- **`README.md`**: badge (line 13) from `telemetry: none` to `telemetry: anonymous, opt-out`, plus
  lines 80, 118 and 245.
- **`docs/FEATURES.md:859`**: the "No server, no telemetry, no account" sentence.
- **`docs/PRIVACY.md`**, new: what is sent (with the real JSON), where it goes, legal basis per
  level, retention, data-subject rights, contact.
- **`docs/RELEASING.md`**: a `POSTHOG_TOKEN` paragraph beside § Sparkle keys.
- **`Shepherd/Resources/Localizable.xcstrings`**: every new string, German and English.

Optional, and the fairest trade for the retired badge: a **public PostHog dashboard** linked from
`PRIVACY.md`, so that what is collected can be read as results, not only as description.

---

## 8. Testing

Following `ShepherdTests/DiagnosticsTests.swift`:

- Fresh install: level is `anonymous`, but nothing is recorded until the notice is acknowledged.
- `app_active_day` fires once per UTC day across two launches, and again after a day boundary is
  crossed by a running app.
- A settings-sync document without a telemetry group leaves the local level untouched.
- `off` deletes the queue file and the monthly UUID; `reach → anonymous` deletes only the UUID.
- A month boundary yields a different UUID, and the two cannot be derived from one another.
- Empty `SHPostHogProjectKey` ⇒ no `UsageTelemetry`, no queue file, sender never called.
- The queue cap drops the oldest events.
- Encoded batch: shape matches `/batch/`, `$ip` is present and null, `$process_person_profile` is
  false, and no key outside the allow-list appears.
- `SettingsSyncApplier` carries the level in both directions.

---

## 9. Out of scope

- Uploading MetricKit payloads. ADR 0017 stands; aggregate crash reporting would be its own ADR.
- Any per-user dashboard, cohort or funnel that needs identity beyond a month.
- Feature flags or A/B testing through PostHog. The key is a write key; nothing is read back.
- Telemetry in `ShepherdKit`. The package must keep building on Linux and has no business knowing
  about this.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| Community reaction to a retired "no telemetry" badge | First-run sheet with equally weighted choices, `PRIVACY.md` with the literal payload, "Zeigen, was gesendet würde" in Settings, optional public dashboard |
| The public write key invites spoofed events | Accepted; numbers are indicators. Stated wherever they are published |
| Level 1 counts launches, not people, and is easy to misread | The dashboards name the metric "launches", not "users" |
| Retention may not be configurable on the current plan | Documented honestly; anonymity carries the argument |
| GeoIP plugin re-enabled later by accident | `$ip: null` on every event is the second line of defence, and § 6 is repeated in ADR 0036 |
| A strict reading of § 25(1) TDDDG covers *any* storage, including the queue and the heartbeat date | Neither identifies a device and neither is transmitted; the notice precedes the first event and the off switch is one click. Final call belongs to the DPO, and the spec says so rather than assuming |
