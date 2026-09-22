# Privacy

Shepherd is a macOS app for reviewing pull requests. It is developed in the open under the MIT
licence and published as a product of **schnaq GmbH**, which is also the controller
(*Verantwortlicher*, Art. 4(7) GDPR) for the usage statistics described below.

This document says what Shepherd stores on your Mac, what leaves it, and to whom. It is written to
be checkable: every claim here is either a setting you can look at or a file you can open, and the
code behind each one is named.

The decision this rests on is [ADR 0036](adr/0036-usage-telemetry.md). The complete, exhaustive
list of hosts Shepherd may ever contact — with the rule that adding one requires a new ADR — is in
[CONTRIBUTING.md](../CONTRIBUTING.md#rules-of-the-road).

---

## 1. What Shepherd stores on your Mac

Everything here stays on your Mac unless a later section says otherwise.

| What | Where | Notes |
|---|---|---|
| Pull requests, issues, review threads, your drafts | `~/Library/Application Support/Shepherd/`, SQLite | The source of truth. Deleted by *Sign out & erase local data* |
| Unsent writes (approvals, merges, comments) | the same database, as an outbox | So an approval survives a crash or a tunnel |
| Tokens and API keys | the login Keychain | Never in `UserDefaults`, never in the database |
| Preferences | `UserDefaults` | Including your telemetry level |
| Crash and hang reports | `~/Library/Application Support/Shepherd/Diagnostics/`, JSON | **Opt-in, off by default.** There is no uploader for these at all ([ADR 0017](adr/0017-local-diagnostics-metrickit.md)) |
| Usage events not yet sent | `~/Library/Application Support/Shepherd/Telemetry/queue.json` | Readable JSON, capped at 500. Settings → Account shows it |

Shepherd has no account system of its own. The only identity involved is your GitHub login.

---

## 2. Usage statistics

### The two levels

Shepherd asks once, on first launch, before anything is recorded. Three answers:

| Level | What it means | Legal basis |
|---|---|---|
| **Off** | Nothing is collected and nothing is sent. The mechanism is not built: no queue file, no timer, no request | — |
| **Anonymous** (default, after the notice) | Allow-listed counts with **no identifier**. The `distinct_id` is a random value created in memory at launch and gone when the queue is flushed — never written to disk, never surviving a restart | Art. 6(1)(f) GDPR (legitimate interest in knowing which parts of the app are used), with your right to object under Art. 21 |
| **Anonymous + reach** (opt-in) | The above plus a random UUID stored for the current calendar month in UTC and replaced by a fresh random one when the month turns | Art. 6(1)(a) GDPR + § 25(1) TDDDG — your explicit consent, and nothing else |

There is deliberately **no master secret and no hash** behind the monthly UUID. A derived identifier
could be recomputed for a past month; a random one cannot. September's value and October's are
unlinkable to us as much as to anyone else.

### Why the first-run sheet is a notice and not a yes/no question

Anonymous counting does not rest on consent, so a symmetric consent dialog would misdescribe it —
and pre-selected consent is not consent at all. The sheet therefore states what is sent and offers
an immediate way out (*Nutzungsstatistik ausschalten*). The one choice on it that **is** consent,
the reach level, is a separate and deliberately quieter button, because a consent offered more
loudly than the refusal beside it is not freely given.

Nothing is recorded before that sheet is answered.

### The events

Thirteen, and no fourteenth is possible without a code change: event names are an `enum`, and every
property value is an `enum`, a `Bool` or a coarse bucket. There is no case in the payload type that
could hold free text, so sending a repository name is a compile error rather than a review miss.

| Event | Properties |
|---|---|
| `app_active_day` | repository count and inbox size as buckets (`0` / `1-3` / `4-10` / `11+`), diff renderer, intelligence mode, and on/off flags for webhooks, settings sync, auto-merge, auto-delegation, digest, menu bar, diagnostics |
| `review_submitted` | verdict (`approve` / `request_changes` / `comment`), inline-comment count as a bucket |
| `pull_request_merged` | method (`merge` / `squash` / `rebase`), source (`detail` / `bulk` / `auto_rule` / `when_checks_pass`) |
| `focus_session_completed` | queue size as a bucket, whether it ran to the end |
| `bulk_triage_performed` | action, size as a bucket |
| `search_used` | kind (`semantic` / `reference`), whether a result was opened |
| `delegation_started` | trigger (`manual` / `ci_red_rule`) |
| `delegation_finished` | outcome (`finished` / `cancelled` / `failed`) |
| `auto_merge_rule_fired` | outcome |
| `issues_inbox_used` | action (`viewed` / `commented` / `labeled` / `assigned` / `closed`) |
| `fleet_viewed` | scope (`all` / `agent`) |
| `digest_opened` | source (`notification` / `menu_bar` / `app`) |
| `intelligence_used` | **not currently recorded** — see § 6 |

Counts are bucketed because "37 repositories" identifies better than "11+".

Deliberately absent: navigation, clicks, scrolling, dwell time, error messages, and anything that
would need a free-form string. Crash reports are not part of this at all — they stay in a folder on
your Mac with no uploader ([ADR 0017](adr/0017-local-diagnostics-metrickit.md)).

### What is actually sent

One `POST` to `https://eu.i.posthog.com/batch/`, roughly once a day. This is the literal shape:

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
        "app_version": "1.2.0",
        "os_major": 26,
        "locale": "de",
        "kind": "approve",
        "inline_comments": "1-3"
      }
    }
  ]
}
```

Three details are decisions rather than defaults:

- **`$ip` is sent as `null`,** not omitted. PostHog's GeoIP step falls back to the sender's address
  when the property is *absent*, so `null` is the property and its absence would be the leak. GeoIP
  enrichment is switched off in the project as well, as a belt-and-braces measure — see § 3 for why
  that half is a release gate rather than something the app can enforce.
- **`$process_person_profile` is `false`,** so no person object is created and nothing accumulates a
  history.
- **The timestamp is truncated to the UTC day.** Omitting it would let the server stamp ingestion
  time, so a week offline would collapse onto one day; sending the full time would describe your
  working hours.

You can read exactly what is queued on your own Mac: **Settings → Account → Show what would be
sent** prints the file verbatim, and *Clear queue* throws it away.

### Counting a day without counting a person

`app_active_day` is emitted once per installation per UTC day, suppressed locally against a stored
date. Shepherd is a long-session app, so an event fired at launch would count the heaviest users
least. What is stored for this is **a date** — it cannot identify a Mac, it is never sent, and it is
deleted when you switch telemetry off.

At the `anonymous` level this yields daily active *installations* and nothing more. Monthly active
users, retention and "x % of users do y" are all impossible at that level, because they need a Mac
to be recognisable across days. That limitation is the price of needing no consent, and it is not
worked around.

### Withdrawal erases

- **Reach → Anonymous** deletes the stored monthly UUID.
- **Anything → Off** deletes the monthly UUID, the queue file and the heartbeat date, and stops the
  timer.

Consent that is withdrawn removes what it allowed rather than merely stopping.

### Your rights

Access, rectification, erasure, restriction, portability and objection under Art. 15–21 GDPR, and
withdrawal of consent under Art. 7(3) at any time with no effect on what was lawful before.

There is an honest limit here and it is worth stating plainly: at the `anonymous` level the data
contains nothing that could identify you, so we cannot find "your" records to show or delete — there
is nothing linking them to you in the first place. Art. 11(2) GDPR covers exactly this case. At the
`reach` level the monthly UUID is the only handle, it is held only on your Mac, and switching the
level down deletes it. The switch in Settings is therefore the fastest and most complete exercise of
these rights, and it works without contacting anyone.

Contact: **info@schnaq.com**.

---

## 3. Who processes what

- **Controller:** schnaq GmbH.
- **Processor:** PostHog, in its **EU** region, under Art. 28 GDPR.
- **Project:** PostHog EU project 277838. Before any release build carries the project key, that
  project is configured with GeoIP off, client IP discarded, session recording, autocapture and
  surveys off, and an explicit retention setting. None of this is enforceable from the app, so it is
  a release gate rather than a line of code — [docs/RELEASING.md](RELEASING.md#the-posthog-project-key)
  is where it is checked off, and [ADR 0036](adr/0036-usage-telemetry.md) is where it is argued.

No advertising, no profiling, no automated decision-making, and no sale or sharing of this data with
anyone.

---

## 4. The project key is public

The `phc_…` key in the payload above is a **public write key**. It ships inside every binary and
`strings` will find it. That is how PostHog's ingest works and it is not treated as a secret here.

Two consequences, both stated rather than glossed over:

1. Anybody can post events into the project. The resulting numbers are therefore **indicators**, not
   bookkeeping, and any public dashboard says so.
2. The key protects nothing, so nothing about your privacy depends on it staying hidden. What
   protects your privacy is the shape of the payload, which you can read above and in the queue file
   on your own Mac.

---

## 5. Builds without a key have no telemetry at all

`project.yml` carries an **empty** placeholder. The real key is written into the app bundle only by
the release pipeline, immediately before signing. So:

- a build you make yourself,
- a CI build,
- and **any fork**

have no key — and an absent key means `UsageTelemetry` is never constructed. Not "constructed and
quiet": there is no queue file, no timer and no request, and the first-run notice never appears.
If you build Shepherd yourself, none of § 2 applies to you and schnaq GmbH is not a controller for
anything you do.

---

## 6. What this document does not yet cover

`intelligence_used` is in the allow-list but is **not recorded**. Wiring it would currently reach
only four of the six intelligence features — the other two do not pass through the same code path —
and publishing that would say "nobody uses claims" when the truth is "nobody wired claims". It stays
off until all six can be counted together. Nothing is sent for it in the meantime.

One legal question is open rather than settled: a strict reading of § 25(1) TDDDG covers *any*
storage on the device, which would include the unsent queue and the heartbeat date. Neither
identifies a Mac and neither is transmitted, and the notice precedes the first recorded event rather
than following it — but this is stated here because the alternative is to state it nowhere.

---

*Last updated: 2026-09-18. This document describes Shepherd 1.2 and later; earlier versions sent
nothing at all.*
