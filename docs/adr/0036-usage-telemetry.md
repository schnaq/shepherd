# ADR 0036: Usage telemetry — anonymous by default, reach by consent, absent without a key

Status: Accepted (v1.2 scope) · Date: 2026-09-18 · Amended 2026-09-22: **off until asked** — see
the amendment at the end, which replaces "anonymous by default" in the title and in the Decision
below with an opt-in.

## Context

Shepherd is developed against guesses. `download_count` on a GitHub release says how many people
fetched a `.dmg`; it does not say whether an installation launched once and was dragged to the
Trash, or whether it is somebody's inbox every morning. It says nothing about which half of the app
carries: whether the focus session is used or skipped, whether ⌘K earns the embedding work behind
it, whether delegation is abandoned the first time an agent writes something wrong. Every feature
built on those guesses is paid for by the features that were not built instead.

The project has been unusually loud about not measuring. The README carries a `telemetry: none`
badge, CONTRIBUTING.md's "No telemetry, ever" heads an exhaustive list of hosts the app may
contact, and [ADR 0017](0017-local-diagnostics-metrickit.md) turned down a crash-reporting SDK on
the strength of both — keeping MetricKit payloads in a folder on the Mac with no uploader at all.
That ADR closed with the condition under which the question could be reopened: *"If aggregate crash
data is ever wanted, it needs its own ADR, a host in CONTRIBUTING.md and a second, separate opt-in —
not a quiet extension of this one."*

This is that ADR, for *usage* data rather than crash data. It retires the "ever" on purpose, and
replaces it with a narrower promise the code can actually keep. The full argument, the event table
and the payload live in [`docs/plans/usage-telemetry.md`](../plans/usage-telemetry.md); what
follows is the decision.

The controlling rule is **§ 25 TDDDG**, and it attaches to *storing information on the device*, not
to sending it. Anything written to the Mac in order to recognise it later needs consent, however
anonymous the later analysis is. Write nothing, and § 25 does not apply; what remains is the
transmission, which briefly processes an IP address, and that is carried by Art. 6(1)(f) GDPR as
long as the address is neither stored nor used for recognition. That rule splits the problem in
two, and the two levels below are that split.

## Decision

**Two levels, because the two questions behind them have different answers in law.**

`anonymous` is the default and needs no consent. The `distinct_id` is a UUID minted in memory at
launch, held only in the queue of unsent events, and gone when that queue is flushed — never in
`UserDefaults`, never in the Keychain, never surviving a restart. Nothing on the server can be tied
to anything else. It rests on Art. 6(1)(f) GDPR, and because Art. 21 gives a right to object to
exactly that basis, the switch exists anyway. What it measures: daily active installations, version
spread, which features are switched on, how often each allow-listed action happens, German versus
English. What it cannot measure: monthly active users, retention, "x % of users do y" — all three
need a Mac to be recognisable across days. That limitation is the price of needing no consent, and
it is not to be worked around.

`reach` adds a random UUID stored in `UserDefaults` alongside the UTC month it was minted in; on the
first event of a new month the old value is overwritten by a fresh random one. Legal basis
Art. 6(1)(a) GDPR plus § 25(1) TDDDG, both satisfied by an explicit opt-in and nothing less. There
is deliberately **no root secret and no hash**: a derived identity could be recomputed for a past
month, and a random one cannot, so September and October are unlinkable to us as much as to anyone
else.

**Nothing is recorded before the first-run notice is answered.** A second flag,
`telemetryNoticeAcknowledged`, holds the mechanism back until then — this is the practical
difference between "on by default" and "on by default, after you were told". The notice is a
*notice*, not a consent dialog, and the buttons say so: `Verstanden`,
`Nutzungsstatistik ausschalten`, and a third, quieter `Auch Reichweite messen`. A symmetrical
yes/no question would shape level 1 like consent when it does not rest on consent, and pre-selected
consent is not consent (Planet49).

**No SDK.** One `URLSession` `POST` to `https://eu.i.posthog.com/batch/`, through
`CredentialSafeSession` like every other request that must not hand anything to a redirect it did
not choose. `NOTICES.md` gains no line, ADR 0009's dependency surface does not move, and there is no
autocapture to switch off because there is nothing that could capture. The sink is PostHog EU Cloud,
project 277838: schnaq already has the contracts and the operations, so this adds no backend of our
own.

**A heartbeat, not a launch event.** Shepherd is a long-session app — the menu-bar inbox stays open
for weeks, which is why ADR 0017 worries about hangs at all — so an event fired at launch would
count the heaviest users *least*: three weeks of daily use, one launch. `app_active_day` is emitted
at launch and again when a running app crosses UTC midnight, and it is suppressed when the stored
`lastHeartbeatDay` already equals today. Two launches on one day are one event; three weeks running
are twenty-one. The count of these events per day *is* the number of active installations that day,
derived on the Mac rather than from anything the server recognises. What is stored for it is a
date — it cannot identify a Mac, it is never sent, and it is deleted when telemetry goes off.

**An allow-list that is structural rather than aspirational.** Thirteen events, and `String` does
not appear as a payload *input*: event names are an `enum`, property values are an `enum`, a `Bool`
or a coarse bucket. Sending a repository name is a compile error, not a review miss. Counts are
bucketed because "37 repositories" identifies better than "21+". Deliberately absent: navigation,
clicks, scrolling, dwell time, error messages, and anything that would need a free-form string.

**The mechanism is constructed, not filtered.** `UsageTelemetry` exists only when
`SHPostHogProjectKey` is non-empty, the level is not `off`, and the notice has been answered.
Otherwise the reference is `nil` — no queue file, no timer, no request. That is the same shape as a
`DiagnosticsReporter` that never registers with MetricKit and an `UpdateController` that refuses to
start without a valid Sparkle key: gate the mechanism, not the output. A development build, a test
run and a fork have no key and therefore no telemetry at all, which is also why the first-run sheet
never appears while working on Shepherd.

**Withdrawal erases.** Dropping to `anonymous` deletes the stored monthly UUID. Dropping to `off`
deletes the UUID, the queue file and the heartbeat date, and stops the timer. Consent that is
withdrawn has to remove what it allowed, not merely stop adding to it.

**The choice syncs; the state does not.** `SyncedSettingsDocument.TelemetryGroup` carries the level
and the acknowledgement flag in both directions. The group is **optional, and absent means "do not
touch"** — not "apply the default". A document written by a Mac still running 1.1 has no telemetry
group, and applying a default of `anonymous` would silently switch telemetry back on for somebody
who had turned it off. `diagnosticsEnabled` could be careless here because its default is `false`;
this one cannot. The queue, the heartbeat date and the monthly UUID stay out of the document
entirely — they are machine-local state, beside the outbox and the auto-delegation ledger.

## Consequences

- **The badge changes and the promise narrows.** `telemetry: none` becomes
  `telemetry: anonymous · opt-out`, CONTRIBUTING.md's "No telemetry, ever" bullet is replaced rather
  than quietly reworded, and `docs/PRIVACY.md` is written to say in plain words what the code does.
  A project that made this much of not measuring does not get to start measuring in a footnote.
- **The host list grows by one:** `eu.i.posthog.com`, contacted roughly once a day, and only while
  telemetry is on. With the level `off` nothing is queued, no timer runs and the host is never
  contacted at all.
- **The project key is public.** A `phc_` key is a write key that ships inside every binary, and
  `strings` will find it. The GitHub secret buys build hygiene, not confidentiality. The consequence
  — anybody can post events into the project — is why the resulting numbers are *indicators* rather
  than bookkeeping, and `docs/PRIVACY.md` and any public dashboard have to say so.
- **The PostHog project checklist is a manual step nobody can enforce from Swift.** At
  `https://eu.posthog.com/project/277838`: GeoIP plugin **off** (it falls back to the sender's
  address when `$ip` is *absent*, which is why the payload sends `$ip` as `null` rather than
  omitting it); "Discard client IP data" enabled if the project offers it; retention set explicitly,
  and where it cannot be, `docs/PRIVACY.md` states PostHog's actual retention honestly and the
  storage-limitation argument rests on the anonymity of the data instead; session recording,
  autocapture and surveys off — irrelevant without an SDK, set anyway so that a future SDK cannot
  inherit them. None of this is visible in a diff, and the privacy claim leans on all of it.
- **schnaq GmbH becomes the *Verantwortlicher*.** PostHog is the processor, in the EU region. Until
  now the MIT project and the company were only related by a line in `LICENSE`; `docs/PRIVACY.md`
  and the first-run notice are the first places a user reads otherwise. What that means for
  positioning is a question this ADR deliberately does not answer.
- **Level 1 cannot be upgraded by analysis.** No amount of dashboard work turns daily active
  installations into monthly active users, because the identity that would be needed was never
  written down. Anyone who wants MAU has to ask for consent, which is what level 2 is.
- **Crash data is unchanged.** ADR 0017 stands as written: MetricKit payloads are still files in a
  folder on the Mac, there is still no uploader, and aggregate crash reporting would still need an
  ADR of its own.
- **A strict reading of § 25(1) remains open.** It covers *any* storage on the device, including the
  unsent queue and the heartbeat date. Neither identifies a Mac and neither is transmitted, and the
  notice precedes the first event rather than following it — but the final call belongs to the
  data-protection officer, not to this record. `docs/plans/usage-telemetry.md` § 10 states the same
  weak point in the same words.

## Amendment (2026-09-22): a question, not a notice

The founder's decision, on the day the product page went up: usage statistics are **opt-in**. A
fresh install has `telemetryLevel = off` as well as `telemetryNoticeAcknowledged = false`, and the
first-run sheet asks rather than informs. Two answers of the same weight — *Nicht jetzt* and *Ja,
anonym zählen* — neither pre-selected, Escape declines, and the reach level is a switch on the same
sheet that is off until turned on and only means anything together with a yes. The sheet shows the
exact bytes on request (*Zeigen, was gesendet würde*, one representative event) before anything has
been recorded.

What changes in law: the `anonymous` level now rests on **Art. 6(1)(a) GDPR** — consent, given
on that sheet — rather than on Art. 6(1)(f), and withdrawal under Art. 7(3) is the switch in
Settings → Account, as before. What does not change: the technical anonymity of the level (no
identifier survives the flush), the allow-list, the single host, the daily timestamp, the absence of
an SDK, and the second latch — a level synced from another Mac still waits for this Mac's own
answer. The Planet49 reasoning that shaped the *notice* still shapes the *question*: the yes is not
louder than the no.

Why the change: not a legal necessity — the legitimate-interest construction was sound — but the
product's own promise. Shepherd sells the sentence "your data stays on your Mac", and a default that
sends anything before being asked reads against it, however anonymous the payload. Asking costs
some statistical coverage; the amendment accepts that price. The cost is measured honestly:
`app_active_day` now counts installations whose owners said yes, and every rate the fleet of
counters produces is a rate among consenting installations.

Consequences: the README badge says *opt-in*; `docs/PRIVACY.md` § 2 describes the question and the
new legal basis; the product page's privacy table says "off until you say yes"; the test that pinned
the fresh-install default now pins `off`.

