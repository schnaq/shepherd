# Usage Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship allow-listed, anonymous usage telemetry that is off in one click, plus a consented second level whose monthly UUID is the only thing that can recognise a Mac twice.

**Architecture:** A new `Shepherd/Telemetry/` directory in the app target, mirroring `Shepherd/Diagnostics/`: five small types (event vocabulary, identity, heartbeat, queue, sender) behind one façade, `UsageTelemetry`. The façade is *constructed* only when a build-time PostHog key exists and the level is not `off` — the same "gate the mechanism, not the output" shape `DiagnosticsReporter` uses for MetricKit. Events are batched to a file and posted once a day to PostHog EU over plain `URLSession`; there is no SDK and therefore no new dependency.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, XCTest, XcodeGen (`project.yml`), mise tasks, PostHog EU ingest (`https://eu.i.posthog.com/batch/`).

**Spec:** [`docs/plans/usage-telemetry.md`](usage-telemetry.md) — read it before Task 1; every design claim below argues from it.

## Global Constraints

- macOS 26 floor, Swift 6, `SWIFT_STRICT_CONCURRENCY: complete` (`project.yml`). New types are `Sendable` or `@MainActor`, never neither.
- **No new dependencies.** No PostHog SDK. `NOTICES.md` must not gain a line, `project.yml`'s `packages:` must not change.
- **`String` never appears as a payload *input*.** Event names and property values come from enums; the only `String` in `TelemetryValue` is produced by `RawRepresentable` conformance inside the type, never passed in by a caller.
- Telemetry code lives in the **app target**, not `Packages/ShepherdKit` — the package must keep building on Linux.
- Every user-visible string goes through `String(localized:)` and must exist in German **and** English in `Shepherd/Resources/Localizable.xcstrings`; `mise run check` enforces this.
- Tests: `mise run test-app` (Xcode, `-testLanguage en`). Package tests `mise run test` are untouched by this plan.
- Levels: `off` / `anonymous` / `reach`. Defaults on a fresh install: `anonymous`, notice **not** acknowledged, and nothing is recorded until it is.
- Ingest host: `https://eu.i.posthog.com/batch/`. PostHog project 277838, EU region.
- Every commit message ends with the two attribution lines used in this repository:

  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01MciDJ6CGeENNeuYGK47qkf
  ```

---

## File Structure

| File | Responsibility |
|---|---|
| `docs/adr/0036-usage-telemetry.md` | The decision, the two levels, the legal bases, the PostHog checklist |
| `docs/adr/0017-local-diagnostics-metrickit.md` | Gains an amendment line pointing at 0036 |
| `Shepherd/Telemetry/TelemetryLevel.swift` | The three-way level, its titles and explanations |
| `Shepherd/Telemetry/TelemetryEvent.swift` | The thirteen events and their typed properties |
| `Shepherd/Telemetry/TelemetryValue.swift` | The only three property shapes: flag, number, choice |
| `Shepherd/Telemetry/TelemetryDay.swift` | UTC day string and day-start timestamp |
| `Shepherd/Telemetry/TelemetryIdentity.swift` | `distinct_id` per level; monthly rotation; `clear()` |
| `Shepherd/Telemetry/TelemetryHeartbeat.swift` | Whether `app_active_day` is due today |
| `Shepherd/Telemetry/TelemetryQueue.swift` | The capped, atomic `queue.json` |
| `Shepherd/Telemetry/TelemetrySender.swift` | The protocol plus `PostHogSender` and its batch body |
| `Shepherd/Telemetry/UsageTelemetry.swift` | The façade: record, flush, level changes, cleanup |
| `Shepherd/Features/Settings/TelemetrySettingsCard.swift` | Picker, payload preview, clear-queue |
| `Shepherd/Features/Settings/TelemetryNoticeSheet.swift` | The first-run notice |
| `Shepherd/Support/AppSettings.swift` | `telemetryLevel`, `telemetryNoticeAcknowledged` |
| `Shepherd/Support/AppConfig.swift` | `postHogProjectKey`, `postHogBatchURL`, `telemetryDirectory` |
| `Shepherd/SettingsSync/SyncedSettingsDocument.swift` | Optional `TelemetryGroup` |
| `Shepherd/SettingsSync/SettingsSyncApplier.swift` | Capture and apply, absent means "do not touch" |
| `Shepherd/App/AppEnvironment.swift` | Owns `telemetry`, `applyTelemetryLevel()` |
| `Shepherd/App/ShepherdApp.swift` | `onChange` route for the level |
| `ShepherdTests/TelemetryTests.swift` | Everything above |
| `project.yml`, `.github/workflows/release.yml`, `docs/RELEASING.md` | Build-time key |
| `README.md`, `CONTRIBUTING.md`, `docs/FEATURES.md`, `docs/PRIVACY.md` | The retired promise |

---

### Task 1: ADR 0036 and the amendment to ADR 0017

**Files:**
- Create: `docs/adr/0036-usage-telemetry.md`
- Modify: `docs/adr/0017-local-diagnostics-metrickit.md` (Consequences section)
- Modify: `docs/adr/README.md` (the ADR index)

**Interfaces:**
- Consumes: the spec at `docs/plans/usage-telemetry.md`.
- Produces: the decision record every later task cites in code comments as "ADR 0036".

- [ ] **Step 1: Read the spec and the ADR you are amending**

Run: `sed -n '1,120p' docs/plans/usage-telemetry.md` and `sed -n '60,90p' docs/adr/0017-local-diagnostics-metrickit.md`

The sentence you must not contradict is ADR 0017's: *"If aggregate crash data is ever wanted, it needs its own ADR, a host in CONTRIBUTING.md and a second, separate opt-in — not a quiet extension of this one."* Task 1 is that ADR for usage data.

- [ ] **Step 2: Write `docs/adr/0036-usage-telemetry.md`**

Follow the house shape exactly — `# ADR 0036: <title>`, `Status: Accepted (v1.2 scope) · Date: 2026-09-18`, then `## Context`, `## Decision`, `## Consequences`. Sections, in order, each argued the way ADR 0017 argues:

1. **Context** — `download_count` is static; the app is developed against guesses about which half is used.
2. **Decision — two levels.** `anonymous` (no identifier, § 25 TDDDG not engaged by any stored identifier, Art. 6(1)(f), default on **after** the notice) and `reach` (monthly UUID, Art. 6(1)(a) + § 25(1), opt-in).
3. **Decision — no SDK.** One `URLSession` `POST`, so `NOTICES.md` and ADR 0009's dependency surface do not move.
4. **Decision — the heartbeat.** `app_active_day`, de-duplicated on the Mac against a stored date, because a launch event under-counts a menu-bar app that stays open for weeks.
5. **Decision — gated at construction.** No key or level `off` ⇒ no `UsageTelemetry`, no queue file, no timer.
6. **Decision — withdrawal erases.** `→ off` deletes queue, heartbeat date and monthly UUID.
7. **Consequences** — the badge changes, the host list grows by `eu.i.posthog.com`, a `phc_` key is public so the numbers are indicators, and the PostHog project checklist (GeoIP off, discard client IP, retention, no session recording/autocapture/surveys) is a manual step nobody can enforce from Swift.

- [ ] **Step 3: Amend ADR 0017**

Append to its Consequences section:

```markdown
**Amendment, 2026-09-18 (ADR 0036).** The second opt-in this section asked for now exists — for
*usage* data, not for crash data. ADR 0036 adds allow-listed usage telemetry with its own host in
CONTRIBUTING.md and its own setting, and CONTRIBUTING.md's "No telemetry, ever" bullet has been
replaced accordingly. Nothing in *this* ADR moves: MetricKit payloads are still written to a folder
on the Mac, there is still no uploader for them, and aggregate crash reporting would still need an
ADR of its own.
```

- [ ] **Step 4: Add ADR 0036 to the index**

Run: `grep -n "0035" docs/adr/README.md` and add the 0036 row in the same format directly below it.

- [ ] **Step 5: Verify no ADR now contradicts another**

Run: `grep -rn "No telemetry, ever\|no telemetry" docs/adr/`
Expected: every remaining hit is either inside ADR 0017's *historical* reasoning or directly followed by the amendment paragraph you just added.

- [ ] **Step 6: Commit**

```bash
git add docs/adr/0036-usage-telemetry.md docs/adr/0017-local-diagnostics-metrickit.md docs/adr/README.md
git commit -m "docs(adr): 0036 decides usage telemetry, and 0017 says so"
```

---

### Task 2: `TelemetryLevel` and the two settings

**Files:**
- Create: `Shepherd/Telemetry/TelemetryLevel.swift`
- Modify: `Shepherd/Support/AppSettings.swift` (init ~line 203, a new section after Diagnostics ~line 908, `Keys` ~line 1003)
- Create: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Produces: `TelemetryLevel` (`.off`, `.anonymous`, `.reach`, `sendsEvents`, `usesStoredIdentity`, `title`, `explanation`), `AppSettings.telemetryLevel`, `AppSettings.telemetryNoticeAcknowledged`.

- [ ] **Step 1: Write the failing test**

Create `ShepherdTests/TelemetryTests.swift`:

```swift
import Foundation
import XCTest

@testable import Shepherd

/// Usage telemetry (ADR 0036): the level, the identity, the heartbeat, the queue, the batch body,
/// and the gate that makes all of it absent rather than merely quiet.
///
/// Every test gets its own `UserDefaults` suite and its own temporary directory — never the real
/// Application Support folder — the same way `DiagnosticsTests` does.
@MainActor
final class TelemetryTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")
    private var createdSuites: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        for name in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "shepherd-telemetry-tests-\(UUID().uuidString)"
        createdSuites.append(name)
        return UserDefaults(suiteName: name) ?? .standard
    }

    // MARK: - The level

    /// The default is the whole privacy story for a fresh install: anonymous *and* unacknowledged,
    /// so the mechanism stays inert until the notice has been seen.
    func testAFreshInstallIsAnonymousAndHasNotSeenTheNotice() {
        let defaults = makeDefaults()
        let fresh = AppSettings(defaults: defaults)

        XCTAssertEqual(fresh.telemetryLevel, .anonymous)
        XCTAssertFalse(fresh.telemetryNoticeAcknowledged)
    }

    func testTheLevelAndTheAcknowledgementSurviveARelaunch() {
        let defaults = makeDefaults()
        let fresh = AppSettings(defaults: defaults)

        fresh.telemetryLevel = .reach
        fresh.telemetryNoticeAcknowledged = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.telemetryLevel, .reach)
        XCTAssertTrue(reloaded.telemetryNoticeAcknowledged)
    }

    func testOnlyReachUsesAStoredIdentity() {
        XCTAssertFalse(TelemetryLevel.off.sendsEvents)
        XCTAssertTrue(TelemetryLevel.anonymous.sendsEvents)
        XCTAssertTrue(TelemetryLevel.reach.sendsEvents)

        XCTAssertFalse(TelemetryLevel.off.usesStoredIdentity)
        XCTAssertFalse(TelemetryLevel.anonymous.usesStoredIdentity)
        XCTAssertTrue(TelemetryLevel.reach.usesStoredIdentity)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: compile failure — `cannot find 'TelemetryLevel' in scope`.

- [ ] **Step 3: Write `Shepherd/Telemetry/TelemetryLevel.swift`**

```swift
import Foundation

/// How much Shepherd may count (ADR 0036).
///
/// Three levels rather than a switch, because the two questions behind them have different
/// answers in law: counting *events* needs no consent as long as nothing on the Mac can recognise
/// it again, and counting *people over time* needs exactly that recognition and therefore
/// exactly that consent.
enum TelemetryLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Nothing is collected and nothing is sent. Not "collected and discarded" — the mechanism is
    /// never built (`UsageTelemetry` is `nil`), so there is no queue file and no timer.
    case off
    /// Allow-listed counts with no identifier: the `distinct_id` is minted in memory at launch and
    /// is gone when the queue is flushed. Answers "how many installations were active today",
    /// never "which ones".
    case anonymous
    /// The above plus a random UUID stored for the current UTC month and thrown away when the
    /// month turns. This — and only this — makes monthly active users countable, which is why it
    /// is the only level that is opt-in.
    case reach

    var id: String { rawValue }

    /// Whether any event may be recorded at all.
    var sendsEvents: Bool { self != .off }

    /// Whether the `distinct_id` is stored on the Mac rather than minted in memory.
    var usesStoredIdentity: Bool { self == .reach }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .anonymous: return String(localized: "Anonymous")
        case .reach: return String(localized: "Anonymous + reach")
        }
    }

    /// The one-line explanation shown under each option.
    var explanation: String {
        switch self {
        case .off:
            return String(localized: "Nothing is collected and nothing is sent.")
        case .anonymous:
            return String(localized: "Version, language and which features you use. No identifier, and nothing that could recognise this Mac again.")
        case .reach:
            return String(localized: "Adds a random identifier that is thrown away every month, so we can count how many people use Shepherd. Switching this off deletes it.")
        }
    }
}
```

- [ ] **Step 4: Add the two settings to `AppSettings`**

In `Keys` (after `diagnosticsEnabled`, ~line 1003):

```swift
        static let telemetryLevel = "telemetry.level"
        static let telemetryNoticeAcknowledged = "telemetry.noticeAcknowledged"
```

In `init` (after the `diagnosticsEnabled` line, ~line 203):

```swift
        self.telemetryLevel = Self.read(defaults, Keys.telemetryLevel, default: TelemetryLevel.anonymous)
        self.telemetryNoticeAcknowledged = defaults
            .object(forKey: Keys.telemetryNoticeAcknowledged) as? Bool ?? false
```

After the Diagnostics section (~line 908):

```swift
    // MARK: - Usage telemetry (ADR 0036)

    /// How much Shepherd may count.
    ///
    /// `anonymous` out of the box, but see ``telemetryNoticeAcknowledged``: the level alone does
    /// not start anything. This is the flag that decides whether ``UsageTelemetry`` is constructed
    /// at all — with `off` there is no queue, no timer and no request, the same shape as
    /// ``diagnosticsEnabled`` and the MetricKit subscriber.
    var telemetryLevel: TelemetryLevel {
        didSet { Self.write(defaults, telemetryLevel, Keys.telemetryLevel) }
    }

    /// Whether the first-run notice has been answered.
    ///
    /// False on a fresh install, and nothing is recorded while it is false. This is the difference
    /// between "on by default with a notice somewhere" and "on by default, after you were told" —
    /// the second is the one ADR 0036 decided on.
    var telemetryNoticeAcknowledged: Bool {
        didSet { defaults.set(telemetryNoticeAcknowledged, forKey: Keys.telemetryNoticeAcknowledged) }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Localisation check and commit**

Run: `mise run check`
Expected: no missing translations. If it reports missing German strings, add them to `Shepherd/Resources/Localizable.xcstrings` before committing.

```bash
git add Shepherd/Telemetry/TelemetryLevel.swift Shepherd/Support/AppSettings.swift ShepherdTests/TelemetryTests.swift Shepherd/Resources/Localizable.xcstrings
git commit -m "feat(telemetry): a level that decides whether anything exists"
```

---

### Task 3: `TelemetryValue`, `TelemetryDay` and the event vocabulary

**Files:**
- Create: `Shepherd/Telemetry/TelemetryValue.swift`
- Create: `Shepherd/Telemetry/TelemetryDay.swift`
- Create: `Shepherd/Telemetry/TelemetryEvent.swift`
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: nothing from Task 2.
- Produces: `TelemetryValue` (`.flag(Bool)`, `.number(Int)`, `.choice(String)` plus `init(_:)` over `TelemetryChoice`), `TelemetryChoice` protocol, `TelemetryDay.utcDay(_:) -> String`, `TelemetryDay.dayStartTimestamp(_:) -> String`, `TelemetryEvent` with `name: String` and `properties: [String: TelemetryValue]`, and the property enums (`CountBucket`, `ReviewKind`, `MergeMethod`…).

- [ ] **Step 1: Write the failing tests**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - The vocabulary

    /// Buckets, not counts: "37 repositories" identifies better than "21+".
    func testCountsAreBucketedAndTheBucketsDoNotOverlap() {
        XCTAssertEqual(CountBucket(count: 0), .none)
        XCTAssertEqual(CountBucket(count: 1), .oneToThree)
        XCTAssertEqual(CountBucket(count: 3), .oneToThree)
        XCTAssertEqual(CountBucket(count: 4), .fourToTen)
        XCTAssertEqual(CountBucket(count: 10), .fourToTen)
        XCTAssertEqual(CountBucket(count: 11), .elevenPlus)
        XCTAssertEqual(CountBucket(count: 5_000), .elevenPlus)
    }

    func testTheDayIsUTCAndTheTimestampIsItsMidnight() {
        // 2026-09-18T23:30:00Z — an evening in UTC, already the 19th in Sydney and still the 18th
        // in Berlin. The day must follow UTC and nothing else, or two Macs disagree about "today".
        let evening = Date(timeIntervalSince1970: 1_789_774_200)
        XCTAssertEqual(TelemetryDay.utcDay(evening), "2026-09-18")
        XCTAssertEqual(TelemetryDay.dayStartTimestamp(evening), "2026-09-18T00:00:00Z")
    }

    /// The allow-list, enforced rather than described: every event's name and every choice it can
    /// carry has to come from an enum, so a repository name cannot reach the payload by accident.
    func testEveryChoiceInEveryEventComesFromItsEnum() {
        let allowed = Set(
            CountBucket.allCases.map(\.rawValue)
                + ReviewKind.allCases.map(\.rawValue)
                + MergeMethod.allCases.map(\.rawValue)
                + MergeSource.allCases.map(\.rawValue)
                + DiffRendererChoice.allCases.map(\.rawValue)
                + IntelligenceChoice.allCases.map(\.rawValue)
                + SearchKind.allCases.map(\.rawValue)
                + DelegationTrigger.allCases.map(\.rawValue)
                + DelegationOutcome.allCases.map(\.rawValue)
                + IntelligenceFeature.allCases.map(\.rawValue)
                + IntelligenceTier.allCases.map(\.rawValue)
                + IntelligenceOutcome.allCases.map(\.rawValue)
                + AutoMergeOutcome.allCases.map(\.rawValue)
                + IssuesAction.allCases.map(\.rawValue)
                + FleetScope.allCases.map(\.rawValue)
                + DigestSource.allCases.map(\.rawValue)
                + TriageAction.allCases.map(\.rawValue)
        )

        for event in TelemetryEvent.allExamples {
            XCTAssertFalse(event.name.isEmpty)
            for (key, value) in event.properties {
                if case .choice(let raw) = value {
                    XCTAssertTrue(allowed.contains(raw), "\(event.name).\(key) carried \(raw)")
                }
            }
        }
    }

    func testTheEventNamesAreTheThirteenFromTheADR() {
        XCTAssertEqual(
            Set(TelemetryEvent.allExamples.map(\.name)),
            [
                "app_active_day", "review_submitted", "pull_request_merged",
                "focus_session_completed", "bulk_triage_performed", "search_used",
                "delegation_started", "delegation_finished", "intelligence_used",
                "auto_merge_rule_fired", "issues_inbox_used", "fleet_viewed", "digest_opened",
            ]
        )
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: `cannot find 'CountBucket' in scope`.

- [ ] **Step 3: Write `TelemetryValue.swift`**

```swift
import Foundation

/// A property value that is allowed to leave the Mac (ADR 0036).
///
/// Three shapes and no fourth. There is no `case text(String)`, which is the point: the payload
/// cannot carry a repository name, a branch, a pull-request title or a path, because there is no
/// case that would hold one. The `choice` case does hold a `String`, but it can only be built from
/// a ``TelemetryChoice`` — an enum whose cases are written in this repository and reviewed like
/// any other code.
enum TelemetryValue: Equatable, Sendable {
    case flag(Bool)
    case number(Int)
    /// The raw value of a ``TelemetryChoice``. Build it with ``init(_:)``, never by hand.
    case choice(String)

    /// Wraps an enum case as a property value.
    /// - Parameter choice: The enum case to send.
    init(_ choice: some TelemetryChoice) {
        self = .choice(choice.rawValue)
    }
}

/// An enum whose cases may appear in a payload: a closed vocabulary with a stable raw value.
protocol TelemetryChoice: RawRepresentable<String>, CaseIterable, Sendable {}

extension TelemetryValue: Codable {
    private enum Kind: String, Codable {
        case flag, number, choice
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flag(let flag):
            try container.encode(Kind.flag, forKey: .kind)
            try container.encode(flag, forKey: .value)
        case .number(let number):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(number, forKey: .value)
        case .choice(let raw):
            try container.encode(Kind.choice, forKey: .kind)
            try container.encode(raw, forKey: .value)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .flag: self = .flag(try container.decode(Bool.self, forKey: .value))
        case .number: self = .number(try container.decode(Int.self, forKey: .value))
        case .choice: self = .choice(try container.decode(String.self, forKey: .value))
        }
    }
}
```

- [ ] **Step 4: Write `TelemetryDay.swift`**

```swift
import Foundation

/// The only two date shapes telemetry knows: a UTC day, and that day's midnight (ADR 0036).
///
/// Everything is truncated to the day on purpose. Omitting the timestamp would let PostHog stamp
/// ingestion time, so a week offline would collapse onto one day; sending the full time would
/// describe working hours. The day is also what the heartbeat de-duplicates against, so having one
/// formatter for both keeps "today" from meaning two things.
enum TelemetryDay {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// `2026-09-18` in UTC.
    /// - Parameter date: The moment to describe.
    /// - Returns: The UTC day.
    static func utcDay(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// `2026-09` in UTC — what the reach identity rotates on.
    /// - Parameter date: The moment to describe.
    /// - Returns: The UTC month.
    static func utcMonth(_ date: Date) -> String { monthFormatter.string(from: date) }

    /// `2026-09-18T00:00:00Z`: the day's midnight, which is the only timestamp that is ever sent.
    /// - Parameter date: The moment to describe.
    /// - Returns: The ISO-8601 timestamp of that day's start.
    static func dayStartTimestamp(_ date: Date) -> String { "\(utcDay(date))T00:00:00Z" }
}
```

- [ ] **Step 5: Write `TelemetryEvent.swift`**

```swift
import Foundation

/// The thirteen events Shepherd may send, and nothing else (ADR 0036).
///
/// Adding a case here is the only way to send anything, and every associated value is an enum or a
/// bucket. That is the allow-list made structural: there is no code path from a repository name,
/// a branch, a title or a path to a payload, because no case would hold one.
enum TelemetryEvent: Sendable {
    /// One per installation per UTC day: emitted at launch and again when a running app crosses
    /// midnight, de-duplicated by ``TelemetryHeartbeat``. The count of these per day *is* the
    /// number of active installations that day.
    case appActiveDay(
        repoCount: CountBucket,
        inboxSize: CountBucket,
        diffRenderer: DiffRendererChoice,
        intelligence: IntelligenceChoice,
        webhooks: Bool,
        settingsSync: Bool,
        autoMerge: Bool,
        autoDelegation: Bool,
        digest: Bool,
        menuBar: Bool,
        diagnostics: Bool
    )
    case reviewSubmitted(kind: ReviewKind, inlineComments: CountBucket, usedTemplate: Bool, usedSavedReply: Bool)
    case pullRequestMerged(method: MergeMethod, source: MergeSource)
    case focusSessionCompleted(queueSize: CountBucket, completed: Bool)
    case bulkTriagePerformed(action: TriageAction, size: CountBucket)
    case searchUsed(kind: SearchKind, openedResult: Bool)
    case delegationStarted(trigger: DelegationTrigger)
    case delegationFinished(outcome: DelegationOutcome)
    case intelligenceUsed(feature: IntelligenceFeature, tier: IntelligenceTier, outcome: IntelligenceOutcome)
    case autoMergeRuleFired(outcome: AutoMergeOutcome)
    case issuesInboxUsed(action: IssuesAction)
    case fleetViewed(scope: FleetScope)
    case digestOpened(source: DigestSource)

    /// The event name PostHog stores.
    var name: String {
        switch self {
        case .appActiveDay: return "app_active_day"
        case .reviewSubmitted: return "review_submitted"
        case .pullRequestMerged: return "pull_request_merged"
        case .focusSessionCompleted: return "focus_session_completed"
        case .bulkTriagePerformed: return "bulk_triage_performed"
        case .searchUsed: return "search_used"
        case .delegationStarted: return "delegation_started"
        case .delegationFinished: return "delegation_finished"
        case .intelligenceUsed: return "intelligence_used"
        case .autoMergeRuleFired: return "auto_merge_rule_fired"
        case .issuesInboxUsed: return "issues_inbox_used"
        case .fleetViewed: return "fleet_viewed"
        case .digestOpened: return "digest_opened"
        }
    }

    /// The event's own properties. The four every event carries — app version, macOS major,
    /// language, `distinct_id` — are added by ``PostHogSender``, not here.
    var properties: [String: TelemetryValue] {
        switch self {
        case .appActiveDay(
            let repoCount, let inboxSize, let diffRenderer, let intelligence,
            let webhooks, let settingsSync, let autoMerge, let autoDelegation,
            let digest, let menuBar, let diagnostics
        ):
            return [
                "repo_count": TelemetryValue(repoCount),
                "inbox_size": TelemetryValue(inboxSize),
                "diff_renderer": TelemetryValue(diffRenderer),
                "intelligence": TelemetryValue(intelligence),
                "webhooks": .flag(webhooks),
                "settings_sync": .flag(settingsSync),
                "auto_merge": .flag(autoMerge),
                "auto_delegation": .flag(autoDelegation),
                "digest": .flag(digest),
                "menu_bar": .flag(menuBar),
                "diagnostics": .flag(diagnostics),
            ]
        case .reviewSubmitted(let kind, let inlineComments, let usedTemplate, let usedSavedReply):
            return [
                "kind": TelemetryValue(kind),
                "inline_comments": TelemetryValue(inlineComments),
                "used_template": .flag(usedTemplate),
                "used_saved_reply": .flag(usedSavedReply),
            ]
        case .pullRequestMerged(let method, let source):
            return ["method": TelemetryValue(method), "source": TelemetryValue(source)]
        case .focusSessionCompleted(let queueSize, let completed):
            return ["queue_size": TelemetryValue(queueSize), "completed": .flag(completed)]
        case .bulkTriagePerformed(let action, let size):
            return ["action": TelemetryValue(action), "size": TelemetryValue(size)]
        case .searchUsed(let kind, let openedResult):
            return ["kind": TelemetryValue(kind), "opened_result": .flag(openedResult)]
        case .delegationStarted(let trigger):
            return ["trigger": TelemetryValue(trigger)]
        case .delegationFinished(let outcome):
            return ["outcome": TelemetryValue(outcome)]
        case .intelligenceUsed(let feature, let tier, let outcome):
            return [
                "feature": TelemetryValue(feature),
                "tier": TelemetryValue(tier),
                "outcome": TelemetryValue(outcome),
            ]
        case .autoMergeRuleFired(let outcome):
            return ["outcome": TelemetryValue(outcome)]
        case .issuesInboxUsed(let action):
            return ["action": TelemetryValue(action)]
        case .fleetViewed(let scope):
            return ["scope": TelemetryValue(scope)]
        case .digestOpened(let source):
            return ["source": TelemetryValue(source)]
        }
    }

    /// One example of every case, so a test can walk the whole vocabulary.
    static var allExamples: [TelemetryEvent] {
        [
            .appActiveDay(
                repoCount: .oneToThree, inboxSize: .fourToTen, diffRenderer: .native,
                intelligence: .onDevice, webhooks: false, settingsSync: true, autoMerge: false,
                autoDelegation: false, digest: true, menuBar: true, diagnostics: false
            ),
            .reviewSubmitted(kind: .approve, inlineComments: .oneToThree, usedTemplate: true, usedSavedReply: false),
            .pullRequestMerged(method: .squash, source: .detail),
            .focusSessionCompleted(queueSize: .elevenPlus, completed: true),
            .bulkTriagePerformed(action: .approve, size: .fourToTen),
            .searchUsed(kind: .semantic, openedResult: true),
            .delegationStarted(trigger: .manual),
            .delegationFinished(outcome: .applied),
            .intelligenceUsed(feature: .brief, tier: .onDevice, outcome: .ok),
            .autoMergeRuleFired(outcome: .merged),
            .issuesInboxUsed(action: .viewed),
            .fleetViewed(scope: .all),
            .digestOpened(source: .notification),
        ]
    }
}

/// A count, coarsened until it stops identifying anybody.
enum CountBucket: String, TelemetryChoice {
    case none = "0"
    case oneToThree = "1-3"
    case fourToTen = "4-10"
    case elevenPlus = "11+"

    /// Buckets a count.
    /// - Parameter count: The real number, which never leaves the Mac.
    init(count: Int) {
        switch count {
        case ..<1: self = .none
        case 1...3: self = .oneToThree
        case 4...10: self = .fourToTen
        default: self = .elevenPlus
        }
    }
}

enum ReviewKind: String, TelemetryChoice {
    case approve, requestChanges = "request_changes", comment
}

enum MergeMethod: String, TelemetryChoice {
    case merge, squash, rebase
}

enum MergeSource: String, TelemetryChoice {
    case detail, bulk, autoRule = "auto_rule"
}

enum TriageAction: String, TelemetryChoice {
    case approve, merge
}

enum DiffRendererChoice: String, TelemetryChoice {
    case monaco, native
}

enum IntelligenceChoice: String, TelemetryChoice {
    case none, onDevice = "on_device", cloud, both
}

enum SearchKind: String, TelemetryChoice {
    case semantic, reference
}

enum DelegationTrigger: String, TelemetryChoice {
    case manual, ciRedRule = "ci_red_rule"
}

enum DelegationOutcome: String, TelemetryChoice {
    case applied, discarded, budgetExceeded = "budget_exceeded", failed
}

enum IntelligenceFeature: String, TelemetryChoice {
    case brief, draftComment = "draft_comment", explain
    case ciDiagnosis = "ci_diagnosis", threadDigest = "thread_digest", claims
}

enum IntelligenceTier: String, TelemetryChoice {
    case onDevice = "on_device", pcc, cloud
}

enum IntelligenceOutcome: String, TelemetryChoice {
    case ok, tooLarge = "too_large", unavailable, error
}

enum AutoMergeOutcome: String, TelemetryChoice {
    case merged, skipped
}

enum IssuesAction: String, TelemetryChoice {
    case viewed, commented, labeled, assigned, closed
}

enum FleetScope: String, TelemetryChoice {
    case all, repo
}

enum DigestSource: String, TelemetryChoice {
    case notification, menuBar = "menu_bar", app
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shepherd/Telemetry ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): thirteen events, and no way to send a fourteenth"
```

---

### Task 4: Identity and heartbeat

**Files:**
- Create: `Shepherd/Telemetry/TelemetryIdentity.swift`
- Create: `Shepherd/Telemetry/TelemetryHeartbeat.swift`
- Modify: `Shepherd/Support/AppSettings.swift` (`Keys` only)
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `TelemetryLevel`, `TelemetryDay`.
- Produces: `TelemetryIdentity(defaults:)` with `distinctID(for level: TelemetryLevel, now: Date) -> String` and `clearStoredIdentity()`; `TelemetryHeartbeat(defaults:)` with `isDue(now: Date) -> Bool`, `markSent(now: Date)`, `clear()`.

- [ ] **Step 1: Write the failing tests**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - Identity

    /// Level 1 mints in memory: two identities from two `TelemetryIdentity` instances differ, and
    /// nothing is written, so a relaunch can never produce the same value twice.
    func testAnonymousIdentityIsNeverStored() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_789_774_200)

        let first = TelemetryIdentity(defaults: defaults).distinctID(for: .anonymous, now: now)
        let second = TelemetryIdentity(defaults: defaults).distinctID(for: .anonymous, now: now)

        XCTAssertNotEqual(first, second)
        XCTAssertNil(defaults.string(forKey: "telemetry.monthlyIdentity"))
    }

    /// The same instance answers consistently within a launch, so one launch is one session.
    func testAnonymousIdentityIsStableWithinOneLaunch() {
        let identity = TelemetryIdentity(defaults: makeDefaults())
        let now = Date(timeIntervalSince1970: 1_789_774_200)

        XCTAssertEqual(identity.distinctID(for: .anonymous, now: now), identity.distinctID(for: .anonymous, now: now))
    }

    /// Level 2 stores, survives a relaunch, and rotates when the UTC month turns — with no secret
    /// anywhere that could link September's value to October's.
    func testReachIdentityIsStoredAndRotatesWithTheMonth() {
        let defaults = makeDefaults()
        let september = Date(timeIntervalSince1970: 1_789_774_200)  // 2026-09-18
        let october = Date(timeIntervalSince1970: 1_792_000_000)    // 2026-10-13

        let first = TelemetryIdentity(defaults: defaults).distinctID(for: .reach, now: september)
        let afterRelaunch = TelemetryIdentity(defaults: defaults).distinctID(for: .reach, now: september)
        XCTAssertEqual(first, afterRelaunch)

        let next = TelemetryIdentity(defaults: defaults).distinctID(for: .reach, now: october)
        XCTAssertNotEqual(first, next)
    }

    func testClearingTheIdentityRemovesItFromDisk() {
        let defaults = makeDefaults()
        let identity = TelemetryIdentity(defaults: defaults)
        _ = identity.distinctID(for: .reach, now: Date(timeIntervalSince1970: 1_789_774_200))
        XCTAssertNotNil(defaults.string(forKey: "telemetry.monthlyIdentity"))

        identity.clearStoredIdentity()

        XCTAssertNil(defaults.string(forKey: "telemetry.monthlyIdentity"))
        XCTAssertNil(defaults.string(forKey: "telemetry.monthlyIdentityMonth"))
    }

    // MARK: - Heartbeat

    /// Two launches on one day are one heartbeat; the next UTC day is due again. This is what makes
    /// the event count equal the number of active installations rather than the number of launches.
    func testTheHeartbeatIsDueOncePerUTCDay() {
        let defaults = makeDefaults()
        let morning = Date(timeIntervalSince1970: 1_789_732_800)  // 2026-09-18T12:00:00Z
        let evening = Date(timeIntervalSince1970: 1_789_774_200)  // 2026-09-18T23:30:00Z
        let nextDay = Date(timeIntervalSince1970: 1_789_819_200)  // 2026-09-19T12:00:00Z

        let heartbeat = TelemetryHeartbeat(defaults: defaults)
        XCTAssertTrue(heartbeat.isDue(now: morning))
        heartbeat.markSent(now: morning)

        XCTAssertFalse(heartbeat.isDue(now: evening))
        XCTAssertFalse(TelemetryHeartbeat(defaults: defaults).isDue(now: evening))

        XCTAssertTrue(TelemetryHeartbeat(defaults: defaults).isDue(now: nextDay))
    }

    func testClearingTheHeartbeatForgetsTheDay() {
        let defaults = makeDefaults()
        let heartbeat = TelemetryHeartbeat(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_789_732_800)
        heartbeat.markSent(now: now)

        heartbeat.clear()

        XCTAssertTrue(heartbeat.isDue(now: now))
        XCTAssertNil(defaults.string(forKey: "telemetry.lastHeartbeatDay"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: `cannot find 'TelemetryIdentity' in scope`.

- [ ] **Step 3: Write `TelemetryIdentity.swift`**

```swift
import Foundation

/// What goes in `distinct_id`, and how little of it survives (ADR 0036).
///
/// The two levels differ here and nowhere else. At `anonymous` the value is a UUID created when
/// this object is created — one per launch, never written down, gone when the process ends. At
/// `reach` it is a UUID stored alongside the UTC month it was minted in; when the month turns, the
/// old value is overwritten by a fresh random one. There is deliberately **no** root secret and no
/// hash: a derived identity could be recomputed for a past month, and a random one cannot, so
/// September and October are unlinkable to us as much as to anyone else.
@MainActor
final class TelemetryIdentity {
    /// Where the monthly value lives. `UserDefaults`, not the Keychain: it is not a secret, it is
    /// a value we want *deletable* — and "Sign out & erase local data" must be able to remove it.
    static let identityKey = "telemetry.monthlyIdentity"
    /// The UTC month the stored value was minted in.
    static let monthKey = "telemetry.monthlyIdentityMonth"

    private let defaults: UserDefaults
    private let launchIdentity = UUID().uuidString

    /// Creates the identity source.
    /// - Parameter defaults: The store the monthly value lives in. Injected so tests never touch
    ///   the user's own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The identifier to send.
    /// - Parameters:
    ///   - level: The current level. `off` never reaches here; `anonymous` gets the in-memory
    ///     value, `reach` the stored one.
    ///   - now: The moment the event happened, which decides the month.
    /// - Returns: The `distinct_id`.
    func distinctID(for level: TelemetryLevel, now: Date) -> String {
        guard level.usesStoredIdentity else { return launchIdentity }

        let month = TelemetryDay.utcMonth(now)
        if defaults.string(forKey: Self.monthKey) == month,
           let stored = defaults.string(forKey: Self.identityKey) {
            return stored
        }

        let minted = UUID().uuidString
        defaults.set(minted, forKey: Self.identityKey)
        defaults.set(month, forKey: Self.monthKey)
        return minted
    }

    /// Deletes the stored monthly value. Called when the level leaves `reach` — withdrawal erases,
    /// it does not merely stop.
    func clearStoredIdentity() {
        defaults.removeObject(forKey: Self.identityKey)
        defaults.removeObject(forKey: Self.monthKey)
    }
}
```

- [ ] **Step 4: Write `TelemetryHeartbeat.swift`**

```swift
import Foundation

/// Whether today's `app_active_day` has already been sent (ADR 0036, § 1.1).
///
/// Shepherd stays open for weeks — the menu-bar inbox is the whole point — so an event fired at
/// launch would count the heaviest users least. The heartbeat fires at launch *and* whenever a
/// running app crosses UTC midnight, and this type is what stops two launches on one day from
/// counting twice.
///
/// What it stores is a date, not an identifier: it cannot distinguish this Mac from any other, it
/// is never sent, and it is deleted when telemetry is switched off.
@MainActor
final class TelemetryHeartbeat {
    /// Where the last sent day is remembered.
    static let lastDayKey = "telemetry.lastHeartbeatDay"

    private let defaults: UserDefaults

    /// Creates the heartbeat.
    /// - Parameter defaults: The store the day lives in.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the day-event is due.
    /// - Parameter now: The current moment.
    /// - Returns: `true` when nothing has been sent for this UTC day yet.
    func isDue(now: Date) -> Bool {
        defaults.string(forKey: Self.lastDayKey) != TelemetryDay.utcDay(now)
    }

    /// Records that the day-event has been queued for this UTC day.
    /// - Parameter now: The current moment.
    func markSent(now: Date) {
        defaults.set(TelemetryDay.utcDay(now), forKey: Self.lastDayKey)
    }

    /// Forgets the day, so the next launch counts again. Called when telemetry is switched off.
    func clear() {
        defaults.removeObject(forKey: Self.lastDayKey)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shepherd/Telemetry ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): an identity that forgets, and a day that counts once"
```

---

### Task 5: The queue

**Files:**
- Create: `Shepherd/Telemetry/TelemetryQueue.swift`
- Modify: `Shepherd/Support/AppConfig.swift` (after `diagnosticsDirectory`)
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `TelemetryValue`, `TelemetryDay`.
- Produces: `QueuedEvent` (`name`, `day`, `distinctID`, `properties`), `TelemetryQueue(directory:)` with `append(_:)`, `load() -> [QueuedEvent]`, `remove(_ count: Int)`, `deleteAll()`, `fileURL`, `static let capacity = 500`; `AppConfig.telemetryDirectory`.

- [ ] **Step 1: Write the failing tests**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - The queue

    private func makeQueue() -> TelemetryQueue { TelemetryQueue(directory: directory) }

    private func sampleEvent(_ marker: String) -> QueuedEvent {
        QueuedEvent(
            name: "fleet_viewed",
            day: "2026-09-18",
            distinctID: marker,
            properties: ["scope": TelemetryValue(FleetScope.all)]
        )
    }

    func testAppendedEventsSurviveANewQueueInstance() {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))
        queue.append(sampleEvent("b"))

        let reloaded = makeQueue().load()

        XCTAssertEqual(reloaded.map(\.distinctID), ["a", "b"])
        XCTAssertEqual(reloaded.first?.properties["scope"], TelemetryValue(FleetScope.all))
    }

    /// A Mac that is offline for a month must not grow a queue without bound, and the events worth
    /// keeping are the recent ones.
    func testTheQueueIsCappedAndDropsTheOldest() {
        let queue = makeQueue()
        for index in 0..<(TelemetryQueue.capacity + 10) {
            queue.append(sampleEvent("event-\(index)"))
        }

        let stored = queue.load()

        XCTAssertEqual(stored.count, TelemetryQueue.capacity)
        XCTAssertEqual(stored.first?.distinctID, "event-10")
        XCTAssertEqual(stored.last?.distinctID, "event-\(TelemetryQueue.capacity + 9)")
    }

    /// A successful flush removes exactly what was sent, and leaves anything recorded meanwhile.
    func testRemovingTheSentPrefixLeavesTheRest() {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))
        queue.append(sampleEvent("b"))
        queue.append(sampleEvent("c"))

        queue.remove(2)

        XCTAssertEqual(queue.load().map(\.distinctID), ["c"])
    }

    func testDeletingAllRemovesTheFileItself() {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.fileURL.path))

        queue.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.fileURL.path))
        XCTAssertTrue(queue.load().isEmpty)
    }

    /// The file is meant to be opened and read by the person whose Mac it is — that is what
    /// "Zeigen, was gesendet würde" shows — so it must be pretty-printed JSON, not a blob.
    func testTheQueueFileIsReadableJSON() throws {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))

        let text = try String(contentsOf: queue.fileURL, encoding: .utf8)

        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("fleet_viewed"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: `cannot find 'TelemetryQueue' in scope`.

- [ ] **Step 3: Add the directory to `AppConfig`**

After `diagnosticsDirectory`:

```swift
    /// `~/Library/Application Support/Shepherd/Telemetry` — the queue of usage events not yet sent
    /// (ADR 0036).
    ///
    /// Beside the diagnostics folder and for the same reason: what leaves the Mac should be
    /// readable on it first. Deleted whole when telemetry is switched off.
    static var telemetryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Telemetry", isDirectory: true)
    }

    /// PostHog's EU ingest endpoint for batched events (ADR 0036).
    static var postHogBatchURL: URL {
        URL(string: "https://eu.i.posthog.com/batch/") ?? URL(fileURLWithPath: "/")
    }
```

- [ ] **Step 4: Write `TelemetryQueue.swift`**

```swift
import Foundation

/// One event, as it waits on disk (ADR 0036).
struct QueuedEvent: Codable, Equatable, Sendable {
    /// The allow-listed event name.
    let name: String
    /// The UTC day the event happened on — the only time resolution that is ever sent.
    let day: String
    /// The `distinct_id` in force when it was recorded.
    let distinctID: String
    /// The event's own properties.
    let properties: [String: TelemetryValue]
}

/// The file of events not yet sent (ADR 0036).
///
/// A file rather than the database on purpose: the point of "Zeigen, was gesendet würde" is that a
/// user can open this in TextEdit and read every byte that would leave the Mac, and a SQLite table
/// is not readable like that. It is capped so that an offline month cannot grow it without bound,
/// and it is deleted — not emptied — when telemetry is switched off.
///
/// Not an actor: like ``DiagnosticsStore`` it does blocking file I/O and its only caller is the
/// main actor.
@MainActor
final class TelemetryQueue {
    /// How many events are kept. The oldest are dropped when a new one arrives.
    static let capacity = 500

    /// The folder the queue file lives in.
    let directory: URL

    /// The queue file itself.
    var fileURL: URL { directory.appendingPathComponent("queue.json", isDirectory: false) }

    private let fileManager: FileManager

    /// Creates the queue.
    /// - Parameters:
    ///   - directory: Where `queue.json` lives. Injected so tests never touch Application Support.
    ///   - fileManager: The file manager to use.
    init(directory: URL = AppConfig.telemetryDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Every stored event, oldest first. A missing or unreadable file is an empty queue, never an
    /// error: it is the state of every install that has not recorded anything yet.
    /// - Returns: The queued events.
    func load() -> [QueuedEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([QueuedEvent].self, from: data)) ?? []
    }

    /// Appends an event, dropping the oldest when the cap is reached.
    /// - Parameter event: The event to store.
    func append(_ event: QueuedEvent) {
        var events = load()
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        write(events)
    }

    /// Drops the first `count` events — what a successful flush sent — and keeps whatever was
    /// recorded while the request was in flight.
    /// - Parameter count: How many events to drop.
    func remove(_ count: Int) {
        guard count > 0 else { return }
        var events = load()
        events.removeFirst(min(count, events.count))
        write(events)
    }

    /// Deletes the queue file. Called when the level goes to `off`.
    func deleteAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func write(_ events: [QueuedEvent]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shepherd/Telemetry/TelemetryQueue.swift Shepherd/Support/AppConfig.swift ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): a queue you can open in TextEdit"
```

---

### Task 6: The sender and the batch body

**Files:**
- Create: `Shepherd/Telemetry/TelemetrySender.swift`
- Modify: `Shepherd/Support/AppConfig.swift` (`postHogProjectKey`)
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `QueuedEvent`, `AppConfig.postHogBatchURL`.
- Produces: `protocol TelemetrySender { func send(_ events: [QueuedEvent]) async throws }`, `PostHogSender(apiKey:appVersion:osMajor:language:session:)`, `PostHogBatchBody.make(apiKey:events:appVersion:osMajor:language:) throws -> Data`, `AppConfig.postHogProjectKey -> String?`.

- [ ] **Step 1: Write the failing tests**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - The batch body

    private func decodedBody(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTheBatchBodyCarriesTheKeyAndOneEntryPerEvent() throws {
        let data = try PostHogBatchBody.make(
            apiKey: "phc_test",
            events: [
                QueuedEvent(name: "fleet_viewed", day: "2026-09-18", distinctID: "abc",
                            properties: ["scope": TelemetryValue(FleetScope.all)]),
                QueuedEvent(name: "digest_opened", day: "2026-09-18", distinctID: "abc",
                            properties: ["source": TelemetryValue(DigestSource.app)]),
            ],
            appVersion: "1.2.0",
            osMajor: 26,
            language: "de"
        )

        let body = try decodedBody(data)
        XCTAssertEqual(body["api_key"] as? String, "phc_test")
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.first?["event"] as? String, "fleet_viewed")
        XCTAssertEqual(batch.first?["timestamp"] as? String, "2026-09-18T00:00:00Z")
    }

    /// The four privacy-carrying properties, checked as a unit: they are the reason this is
    /// defensible at all, and any one of them missing changes what PostHog stores.
    func testEveryEventSuppressesProfilesAndIP() throws {
        let data = try PostHogBatchBody.make(
            apiKey: "phc_test",
            events: [QueuedEvent(name: "fleet_viewed", day: "2026-09-18", distinctID: "abc",
                                 properties: ["scope": TelemetryValue(FleetScope.all)])],
            appVersion: "1.2.0",
            osMajor: 26,
            language: "de"
        )

        let body = try decodedBody(data)
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        let properties = try XCTUnwrap(batch.first?["properties"] as? [String: Any])

        XCTAssertEqual(properties["distinct_id"] as? String, "abc")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertTrue(properties["$ip"] is NSNull)
        XCTAssertEqual(properties["$lib"] as? String, "shepherd")
        XCTAssertEqual(properties["app_version"] as? String, "1.2.0")
        XCTAssertEqual(properties["os_major"] as? Int, 26)
        XCTAssertEqual(properties["locale"] as? String, "de")
        XCTAssertEqual(properties["scope"] as? String, "all")
    }

    /// Nothing outside the allow-list may appear, ever — this is the test that would fail if
    /// somebody added a "helpful" hostname or device model later.
    func testNoPropertyOutsideTheAllowListAppears() throws {
        let allowed: Set<String> = [
            "distinct_id", "$process_person_profile", "$ip", "$lib",
            "app_version", "os_major", "locale", "scope",
        ]

        let data = try PostHogBatchBody.make(
            apiKey: "phc_test",
            events: [QueuedEvent(name: "fleet_viewed", day: "2026-09-18", distinctID: "abc",
                                 properties: ["scope": TelemetryValue(FleetScope.all)])],
            appVersion: "1.2.0",
            osMajor: 26,
            language: "de"
        )

        let body = try decodedBody(data)
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        let properties = try XCTUnwrap(batch.first?["properties"] as? [String: Any])

        XCTAssertTrue(Set(properties.keys).isSubset(of: allowed), "unexpected keys: \(Set(properties.keys).subtracting(allowed))")

        let entry = try XCTUnwrap(batch.first)
        XCTAssertEqual(Set(entry.keys), ["event", "properties", "timestamp"])
    }

    func testTheLanguageIsOnlyEverGermanOrEnglish() {
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "de_DE")), "de")
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "de_AT")), "de")
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "en_GB")), "en")
        // A Mac in French runs Shepherd's English UI (ADR 0022), so that is what is reported.
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "fr_FR")), "en")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: `cannot find 'PostHogBatchBody' in scope`.

- [ ] **Step 3: Add the key to `AppConfig`**

After `postHogBatchURL`:

```swift
    /// The PostHog project key, or `nil` when this build has none (ADR 0036).
    ///
    /// Written into the app bundle's `Info.plist` by the release workflow, exactly the way the
    /// Sparkle public key is handled: a development build, a test run and a fork all have an empty
    /// value here, and an empty value means ``UsageTelemetry`` is never constructed — no queue, no
    /// timer, no request. The key itself is a *public* write key: it ships inside every binary and
    /// `strings` will find it, which is why it protects nothing and is not treated as a secret in
    /// the app.
    static var postHogProjectKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SHPostHogProjectKey") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return raw
    }
```

- [ ] **Step 4: Write `TelemetrySender.swift`**

```swift
import Foundation

/// How a batch of events leaves the Mac. One method, so the tests can watch it without a network.
protocol TelemetrySender: Sendable {
    /// Sends events, oldest first.
    /// - Parameter events: The batch to send.
    func send(_ events: [QueuedEvent]) async throws
}

/// The PostHog EU request body (ADR 0036).
///
/// Separate from the sender because the body is the whole privacy claim: the four properties that
/// suppress person profiles and IP handling, the day-resolution timestamp, and nothing else. A
/// test can assert on bytes here without a URL loading system in the way.
enum PostHogBatchBody {
    /// Builds the `/batch/` body.
    /// - Parameters:
    ///   - apiKey: The project's public write key.
    ///   - events: The queued events, oldest first.
    ///   - appVersion: `CFBundleShortVersionString`.
    ///   - osMajor: The macOS major version.
    ///   - language: `de` or `en`.
    /// - Returns: The JSON body.
    /// - Throws: An encoding error, which the caller treats as a failed flush.
    static func make(
        apiKey: String,
        events: [QueuedEvent],
        appVersion: String,
        osMajor: Int,
        language: String
    ) throws -> Data {
        let batch: [[String: Any]] = events.map { event in
            var properties: [String: Any] = [
                "distinct_id": event.distinctID,
                // No person object is created, so nothing accumulates a history. Unique counting
                // still works off `distinct_id` on the events themselves.
                "$process_person_profile": false,
                // Present and null, not absent: PostHog's GeoIP step falls back to the sender's
                // address when the property is missing.
                "$ip": NSNull(),
                "$lib": "shepherd",
                "app_version": appVersion,
                "os_major": osMajor,
                "locale": language,
            ]
            for (key, value) in event.properties {
                switch value {
                case .flag(let flag): properties[key] = flag
                case .number(let number): properties[key] = number
                case .choice(let raw): properties[key] = raw
                }
            }
            return [
                "event": event.name,
                "timestamp": "\(event.day)T00:00:00Z",
                "properties": properties,
            ]
        }

        return try JSONSerialization.data(
            withJSONObject: ["api_key": apiKey, "batch": batch],
            options: [.sortedKeys]
        )
    }
}

/// Posts batches to PostHog's EU ingest endpoint (ADR 0036).
///
/// No SDK: one `POST` with a JSON body, through ``CredentialSafeSession`` like every other request
/// in the app that must not hand anything to a redirect it did not choose.
struct PostHogSender: TelemetrySender {
    private let apiKey: String
    private let appVersion: String
    private let osMajor: Int
    private let language: String
    private let session: URLSession
    private let endpoint: URL

    /// Creates the sender.
    /// - Parameters:
    ///   - apiKey: The public project key.
    ///   - appVersion: The version to report.
    ///   - osMajor: The macOS major version to report.
    ///   - language: `de` or `en`.
    ///   - session: The URL session to use.
    ///   - endpoint: The ingest URL. Injectable for tests.
    init(
        apiKey: String,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        language: String = PostHogSender.language(for: .current),
        session: URLSession = CredentialSafeSession.shared,
        endpoint: URL = AppConfig.postHogBatchURL
    ) {
        self.apiKey = apiKey
        self.appVersion = appVersion
        self.osMajor = osMajor
        self.language = language
        self.session = session
        self.endpoint = endpoint
    }

    /// The reported language: the UI Shepherd is actually showing, which is German or English and
    /// nothing else (ADR 0022).
    /// - Parameter locale: The locale to reduce.
    /// - Returns: `de` or `en`.
    static func language(for locale: Locale) -> String {
        locale.language.languageCode?.identifier == "de" ? "de" : "en"
    }

    func send(_ events: [QueuedEvent]) async throws {
        guard !events.isEmpty else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try PostHogBatchBody.make(
            apiKey: apiKey,
            events: events,
            appVersion: appVersion,
            osMajor: osMajor,
            language: language
        )

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shepherd/Telemetry/TelemetrySender.swift Shepherd/Support/AppConfig.swift ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): a batch body that says what it will not carry"
```

---

### Task 7: `UsageTelemetry`, the façade and the gate

**Files:**
- Create: `Shepherd/Telemetry/UsageTelemetry.swift`
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–6.
- Produces: `UsageTelemetry(level:identity:heartbeat:queue:sender:now:)`, `record(_ event: TelemetryEvent)`, `recordHeartbeatIfDue(_ makeEvent: () -> TelemetryEvent)`, `flush() async`, `apply(level:)`, `reset()`, `static func make(settings:queue:sender:) -> UsageTelemetry?`.

- [ ] **Step 1: Write the failing tests**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
/// A sender that records what it was handed and can be told to fail.
private final class RecordingSender: TelemetrySender, @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[QueuedEvent]] = []
    var shouldFail = false

    var batches: [[QueuedEvent]] {
        lock.lock(); defer { lock.unlock() }
        return _batches
    }

    func send(_ events: [QueuedEvent]) async throws {
        lock.lock()
        _batches.append(events)
        let fail = shouldFail
        lock.unlock()
        if fail { throw URLError(.notConnectedToInternet) }
    }
}

extension TelemetryTests {
    // MARK: - The façade

    private func makeTelemetry(
        level: TelemetryLevel,
        defaults: UserDefaults,
        sender: RecordingSender,
        now: Date = Date(timeIntervalSince1970: 1_789_732_800)
    ) -> UsageTelemetry {
        UsageTelemetry(
            level: level,
            identity: TelemetryIdentity(defaults: defaults),
            heartbeat: TelemetryHeartbeat(defaults: defaults),
            queue: TelemetryQueue(directory: directory),
            sender: sender,
            now: { now }
        )
    }

    /// The gate, in the only two forms it takes: no key, or a level of `off`. Both mean the
    /// mechanism is absent rather than quiet.
    func testNoInstanceExistsWithoutAKeyOrWithTelemetryOff() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.telemetryNoticeAcknowledged = true

        settings.telemetryLevel = .off
        XCTAssertNil(UsageTelemetry.make(settings: settings, key: "phc_test", queue: TelemetryQueue(directory: directory), sender: RecordingSender()))

        settings.telemetryLevel = .anonymous
        XCTAssertNil(UsageTelemetry.make(settings: settings, key: nil, queue: TelemetryQueue(directory: directory), sender: RecordingSender()))

        XCTAssertNotNil(UsageTelemetry.make(settings: settings, key: "phc_test", queue: TelemetryQueue(directory: directory), sender: RecordingSender()))
    }

    /// Nothing is recorded before the notice is answered — the difference between "on by default"
    /// and "on by default, after you were told".
    func testNothingExistsBeforeTheNoticeIsAcknowledged() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.telemetryLevel = .anonymous
        settings.telemetryNoticeAcknowledged = false

        XCTAssertNil(UsageTelemetry.make(settings: settings, key: "phc_test", queue: TelemetryQueue(directory: directory), sender: RecordingSender()))
    }

    func testRecordingQueuesTheEventWithTodaysDayAndTheCurrentIdentity() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .anonymous, defaults: defaults, sender: RecordingSender())

        telemetry.record(.fleetViewed(scope: .all))

        let stored = TelemetryQueue(directory: directory).load()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.name, "fleet_viewed")
        XCTAssertEqual(stored.first?.day, "2026-09-18")
        XCTAssertFalse(stored.first?.distinctID.isEmpty ?? true)
    }

    func testFlushSendsTheQueueAndEmptiesItOnSuccess() async {
        let sender = RecordingSender()
        let telemetry = makeTelemetry(level: .anonymous, defaults: makeDefaults(), sender: sender)
        telemetry.record(.fleetViewed(scope: .all))
        telemetry.record(.digestOpened(source: .app))

        await telemetry.flush()

        XCTAssertEqual(sender.batches.count, 1)
        XCTAssertEqual(sender.batches.first?.count, 2)
        XCTAssertTrue(TelemetryQueue(directory: directory).load().isEmpty)
    }

    /// A failed flush keeps the events: the next flush tries again, and nothing is lost because
    /// the network was down.
    func testAFailedFlushKeepsTheQueue() async {
        let sender = RecordingSender()
        sender.shouldFail = true
        let telemetry = makeTelemetry(level: .anonymous, defaults: makeDefaults(), sender: sender)
        telemetry.record(.fleetViewed(scope: .all))

        await telemetry.flush()

        XCTAssertEqual(TelemetryQueue(directory: directory).load().count, 1)
    }

    /// Switching off erases rather than merely stopping — the queue, the heartbeat day and the
    /// monthly identity all go.
    func testSwitchingOffDeletesTheQueueTheDayAndTheIdentity() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .reach, defaults: defaults, sender: RecordingSender())
        telemetry.record(.fleetViewed(scope: .all))
        telemetry.recordHeartbeatIfDue { .digestOpened(source: .app) }
        XCTAssertNotNil(defaults.string(forKey: TelemetryIdentity.identityKey))

        telemetry.apply(level: .off)

        XCTAssertTrue(TelemetryQueue(directory: directory).load().isEmpty)
        XCTAssertNil(defaults.string(forKey: TelemetryIdentity.identityKey))
        XCTAssertNil(defaults.string(forKey: TelemetryHeartbeat.lastDayKey))
    }

    /// Dropping from reach to anonymous deletes only the stored identity: the counts stay, the
    /// recognisability goes.
    func testDroppingFromReachToAnonymousDeletesOnlyTheIdentity() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .reach, defaults: defaults, sender: RecordingSender())
        telemetry.record(.fleetViewed(scope: .all))

        telemetry.apply(level: .anonymous)

        XCTAssertNil(defaults.string(forKey: TelemetryIdentity.identityKey))
        XCTAssertEqual(TelemetryQueue(directory: directory).load().count, 1)
    }

    func testTheHeartbeatIsRecordedOncePerDayThroughTheFacade() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .anonymous, defaults: defaults, sender: RecordingSender())

        telemetry.recordHeartbeatIfDue { .digestOpened(source: .app) }
        telemetry.recordHeartbeatIfDue { .digestOpened(source: .app) }

        XCTAssertEqual(TelemetryQueue(directory: directory).load().count, 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: `cannot find 'UsageTelemetry' in scope`.

- [ ] **Step 3: Write `UsageTelemetry.swift`**

```swift
import Foundation

/// Usage telemetry, whole (ADR 0036).
///
/// The type exists *only* when telemetry may happen: ``make(settings:key:queue:sender:)`` answers
/// `nil` when this build has no PostHog key, when the level is `off`, or when the first-run notice
/// has not been answered yet. That is the same shape ``DiagnosticsReporter`` uses for MetricKit —
/// gate the mechanism, not the output — and it is why there is nothing here that filters events:
/// an event that must not be sent was never recorded, because this object did not exist.
@MainActor
final class UsageTelemetry {
    private(set) var level: TelemetryLevel
    private let identity: TelemetryIdentity
    private let heartbeat: TelemetryHeartbeat
    private let queue: TelemetryQueue
    private let sender: any TelemetrySender
    private let now: () -> Date
    private var flushTimer: Timer?

    /// How long after launch the first flush happens: late enough to stay off the launch path,
    /// early enough that a short session still reports.
    static let firstFlushDelay: TimeInterval = 30
    /// How often a running app flushes afterwards.
    static let flushInterval: TimeInterval = 24 * 60 * 60

    /// Creates the façade. Prefer ``make(settings:key:queue:sender:)``, which applies the gate.
    /// - Parameters:
    ///   - level: The level in force.
    ///   - identity: The `distinct_id` source.
    ///   - heartbeat: The once-a-day gate for `app_active_day`.
    ///   - queue: Where events wait.
    ///   - sender: How they leave.
    ///   - now: The clock, injected for tests.
    init(
        level: TelemetryLevel,
        identity: TelemetryIdentity,
        heartbeat: TelemetryHeartbeat,
        queue: TelemetryQueue,
        sender: any TelemetrySender,
        now: @escaping () -> Date = Date.init
    ) {
        self.level = level
        self.identity = identity
        self.heartbeat = heartbeat
        self.queue = queue
        self.sender = sender
        self.now = now
    }

    /// Builds the façade when — and only when — telemetry may happen.
    /// - Parameters:
    ///   - settings: The level and the acknowledgement flag.
    ///   - key: The build's PostHog key, `nil` in development builds and forks.
    ///   - queue: Where events wait.
    ///   - sender: How they leave. `nil` builds a ``PostHogSender`` for `key`.
    /// - Returns: The façade, or `nil` when nothing may be collected.
    static func make(
        settings: AppSettings,
        key: String? = AppConfig.postHogProjectKey,
        queue: TelemetryQueue = TelemetryQueue(),
        sender: (any TelemetrySender)? = nil
    ) -> UsageTelemetry? {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.telemetryLevel.sendsEvents, settings.telemetryNoticeAcknowledged
        else { return nil }
        return UsageTelemetry(
            level: settings.telemetryLevel,
            identity: TelemetryIdentity(),
            heartbeat: TelemetryHeartbeat(),
            queue: queue,
            sender: sender ?? PostHogSender(apiKey: key)
        )
    }

    // MARK: - Recording

    /// Queues one event.
    /// - Parameter event: What happened, from the allow-list and nowhere else.
    func record(_ event: TelemetryEvent) {
        guard level.sendsEvents else { return }
        let moment = now()
        queue.append(
            QueuedEvent(
                name: event.name,
                day: TelemetryDay.utcDay(moment),
                distinctID: identity.distinctID(for: level, now: moment),
                properties: event.properties
            )
        )
    }

    /// Queues the day-event unless this UTC day already has one.
    ///
    /// The closure is only called when the event is actually due, so counting repositories and
    /// reading feature flags costs nothing on the launches that will not report.
    /// - Parameter makeEvent: Builds the `app_active_day` event.
    func recordHeartbeatIfDue(_ makeEvent: () -> TelemetryEvent) {
        guard level.sendsEvents else { return }
        let moment = now()
        guard heartbeat.isDue(now: moment) else { return }
        heartbeat.markSent(now: moment)
        record(makeEvent())
    }

    // MARK: - Sending

    /// Starts the flush schedule: once shortly after launch, then once a day.
    func startFlushing() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstFlushDelay))
            await self?.flush()
        }
    }

    /// Sends what is queued and drops exactly what was sent. A failure keeps everything for the
    /// next flush; there is no retry loop, because a bad network must not become a busy one.
    func flush() async {
        let pending = queue.load()
        guard !pending.isEmpty else { return }
        do {
            try await sender.send(pending)
            queue.remove(pending.count)
        } catch {
            // Deliberately silent: a failed flush is not a thing to tell the user about, and the
            // events stay queued until the cap pushes the oldest out.
        }
    }

    // MARK: - Level changes

    /// Applies a new level, erasing whatever the new level may no longer hold.
    ///
    /// Withdrawal deletes: `off` takes the queue, the heartbeat day and the monthly identity with
    /// it, and leaving `reach` takes the identity. Consent that is withdrawn has to remove what it
    /// allowed, not merely stop adding to it.
    /// - Parameter newLevel: The level the user chose, or a settings document carried over.
    func apply(level newLevel: TelemetryLevel) {
        if !newLevel.usesStoredIdentity {
            identity.clearStoredIdentity()
        }
        if !newLevel.sendsEvents {
            queue.deleteAll()
            heartbeat.clear()
            flushTimer?.invalidate()
            flushTimer = nil
        }
        level = newLevel
    }

    /// Empties the queue on request — the "Warteschlange löschen" button.
    func clearQueue() {
        queue.deleteAll()
    }

    /// What is waiting to be sent, for the payload preview in Settings.
    var pendingEvents: [QueuedEvent] { queue.load() }

    /// Where the queue file is, for the path line in Settings.
    var queueFileURL: URL { queue.fileURL }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shepherd/Telemetry/UsageTelemetry.swift ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): a facade that does not exist when it may not collect"
```

---

### Task 8: Settings sync — absent means "do not touch"

**Files:**
- Modify: `Shepherd/SettingsSync/SyncedSettingsDocument.swift` (`DiagnosticsGroup` neighbourhood ~line 616, `CodingKeys` ~line 795, `init(from:)` ~line 805, the stored properties ~line 750 and the memberwise `init` ~line 757)
- Modify: `Shepherd/SettingsSync/SettingsSyncApplier.swift` (capture ~line 135, apply ~line 284)
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `TelemetryLevel`, `AppSettings.telemetryLevel`, `AppSettings.telemetryNoticeAcknowledged`.
- Produces: `SyncedSettingsDocument.TelemetryGroup(level:noticeAcknowledged:)` and the **optional** property `var telemetry: TelemetryGroup?`.

- [ ] **Step 1: Write the failing tests**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - Settings sync

    /// The one that matters: a document from a Mac that predates telemetry has no group, and an
    /// absent group must leave the local choice alone. A default of `anonymous` here would switch
    /// telemetry back on for somebody who had turned it off.
    func testADocumentWithoutATelemetryGroupLeavesTheLevelAlone() throws {
        let json = Data(#"{"v":1,"telemetry":null}"#.utf8)
        let document = try JSONDecoder().decode(SyncedSettingsDocument.self, from: json)

        XCTAssertNil(document.telemetry)
    }

    func testTheGroupRoundTripsThroughJSON() throws {
        var document = SyncedSettingsDocument()
        document.telemetry = SyncedSettingsDocument.TelemetryGroup(level: .reach, noticeAcknowledged: true)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SyncedSettingsDocument.self, from: data)

        XCTAssertEqual(decoded.telemetry?.level, .reach)
        XCTAssertEqual(decoded.telemetry?.noticeAcknowledged, true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: `value of type 'SyncedSettingsDocument' has no member 'telemetry'`.

- [ ] **Step 3: Add the group to the document**

Next to `DiagnosticsGroup`:

```swift
    /// Usage telemetry (ADR 0036): the level, and whether the first-run notice has been answered.
    ///
    /// The queue, the heartbeat day and the monthly identity are deliberately **not** here. They
    /// are machine-local state — one Mac, one month, one set of unsent events — and belong with the
    /// outbox and the auto-delegation ledger among the things this document leaves out.
    struct TelemetryGroup: Codable, Sendable, Equatable {
        /// How much this account's Macs may count.
        var level: TelemetryLevel
        /// Whether the notice has been answered, so a second Mac does not ask again.
        var noticeAcknowledged: Bool

        /// Creates the group.
        /// - Parameters:
        ///   - level: The level to carry.
        ///   - noticeAcknowledged: Whether the notice has been answered.
        init(level: TelemetryLevel = .anonymous, noticeAcknowledged: Bool = false) {
            self.level = level
            self.noticeAcknowledged = noticeAcknowledged
        }

        private enum CodingKeys: String, CodingKey {
            case level, noticeAcknowledged
        }
    }
```

Add `case telemetry` to `CodingKeys`, add the stored property beside `diagnostics`:

```swift
    /// Usage telemetry, or `nil` when the document was written by a build that had none.
    ///
    /// Optional, unlike every other group, and that is the point: `nil` means *do not touch the
    /// local setting*. Applying a default here would turn telemetry back on for somebody who had
    /// switched it off on this Mac and then synced from an older one.
    var telemetry: TelemetryGroup?
```

Add `telemetry: TelemetryGroup? = nil` to the memberwise `init` and `self.telemetry = telemetry` in its body, and in `init(from:)`:

```swift
        telemetry = container.syncedOptional(.telemetry, as: TelemetryGroup.self)
```

- [ ] **Step 4: Capture and apply it in `SettingsSyncApplier`**

In the capture function, after the `document.diagnostics` assignment:

```swift
        document.telemetry = SyncedSettingsDocument.TelemetryGroup(
            level: settings.telemetryLevel,
            noticeAcknowledged: settings.telemetryNoticeAcknowledged
        )
```

In the apply function, after the `settings.diagnosticsEnabled` line:

```swift
        // Absent means "leave it alone", not "apply the default": a document written before
        // ADR 0036 has no telemetry group, and defaulting to `anonymous` would switch telemetry
        // back on for somebody who had switched it off. Only the flags are applied here — building
        // or tearing down the mechanism is the window's job, driven by
        // `onChange(of: settings.telemetryLevel)` in `ShepherdApp`, exactly like the MetricKit
        // subscriber.
        if let telemetry = document.telemetry {
            settings.telemetryLevel = telemetry.level
            // An applied `off` also answers the notice: the question has been settled for this
            // account, and asking again on the second Mac would be asking twice.
            settings.telemetryNoticeAcknowledged = telemetry.noticeAcknowledged || telemetry.level == .off
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS, and `SettingsSyncTests` still green.

- [ ] **Step 6: Commit**

```bash
git add Shepherd/SettingsSync ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): sync the choice, and never invent one"
```

---

### Task 9: Wiring — environment, app, heartbeat at launch

**Files:**
- Modify: `Shepherd/App/AppEnvironment.swift` (`let diagnostics` ~line 123; `applyDiagnosticsSetting()` ~line 1007; `bootstrap()`)
- Modify: `Shepherd/App/ShepherdApp.swift` (~line 40)
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `UsageTelemetry.make(settings:key:queue:sender:)`, `AppSettings`.
- Produces: `AppEnvironment.telemetry: UsageTelemetry?`, `AppEnvironment.applyTelemetryLevel()`, `AppEnvironment.recordLaunchHeartbeat()`.

- [ ] **Step 1: Write the failing test**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - The launch heartbeat

    /// The day-event carries the feature flags, which is how "which functions are used at all" is
    /// answered without an event per feature.
    func testTheLaunchHeartbeatCarriesTheFeatureFlags() {
        let event = TelemetryEvent.appActiveDay(
            repoCount: CountBucket(count: 7),
            inboxSize: CountBucket(count: 2),
            diffRenderer: .native,
            intelligence: .onDevice,
            webhooks: true,
            settingsSync: false,
            autoMerge: true,
            autoDelegation: false,
            digest: true,
            menuBar: true,
            diagnostics: false
        )

        XCTAssertEqual(event.name, "app_active_day")
        XCTAssertEqual(event.properties["repo_count"], TelemetryValue(CountBucket.fourToTen))
        XCTAssertEqual(event.properties["inbox_size"], TelemetryValue(CountBucket.oneToThree))
        XCTAssertEqual(event.properties["webhooks"], .flag(true))
        XCTAssertEqual(event.properties["settings_sync"], .flag(false))
    }
}
```

- [ ] **Step 2: Run to verify it passes already**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS — the event vocabulary was built in Task 3. This test exists to pin the property names the wiring below must produce; if it fails, fix the wiring, not the test.

- [ ] **Step 3: Add the property and the two methods to `AppEnvironment`**

Beside `let diagnostics = DiagnosticsReporter()`:

```swift
    /// Usage telemetry (ADR 0036), or `nil` when this build has no key, the level is `off`, or the
    /// first-run notice has not been answered. `nil` is the normal state of a development build.
    private(set) var telemetry: UsageTelemetry?
```

Beside `applyDiagnosticsSetting()`:

```swift
    /// Builds or tears down usage telemetry to match the level (ADR 0036).
    ///
    /// Called at launch, from the picker in Settings, and when an applied settings document
    /// carried a level from another Mac — the same three callers ``applyDiagnosticsSetting()`` has,
    /// and idempotent for the same reason.
    func applyTelemetryLevel() {
        if let telemetry {
            telemetry.apply(level: settings.telemetryLevel)
            if !settings.telemetryLevel.sendsEvents {
                self.telemetry = nil
            }
            return
        }
        telemetry = UsageTelemetry.make(settings: settings)
        telemetry?.startFlushing()
    }

    /// Records `app_active_day` when this UTC day has not been counted yet (ADR 0036, § 1.1).
    ///
    /// Every value it sends is a bucket or a flag read from settings — never a repository name, a
    /// count, or anything the allow-list does not already contain.
    func recordLaunchHeartbeat() {
        telemetry?.recordHeartbeatIfDue { [settings, session] in
            .appActiveDay(
                repoCount: CountBucket(count: session?.repositoryCount ?? 0),
                inboxSize: CountBucket(count: session?.inboxRows.count ?? 0),
                diffRenderer: settings.diffRenderer == .native ? .native : .monaco,
                intelligence: Self.intelligenceChoice(for: settings),
                webhooks: settings.webhooksEnabled,
                settingsSync: settings.settingsSyncEnabled,
                autoMerge: settings.autoMergeEnabled,
                autoDelegation: settings.autoDelegationEnabled,
                digest: settings.digestEnabled,
                menuBar: settings.showsMenuBarExtra,
                diagnostics: settings.diagnosticsEnabled
            )
        }
    }

    /// Reduces the intelligence settings to the four values the allow-list knows.
    /// - Parameter settings: The settings to read.
    /// - Returns: The reported choice.
    private static func intelligenceChoice(for settings: AppSettings) -> IntelligenceChoice {
        switch settings.intelligenceMode {
        case .off: return .none
        case .onDevice: return .onDevice
        case .onDeviceAndCloud: return .both
        }
    }
```

**Before writing this, check the real property names** — the plan names them from the spec, and the codebase is the authority:

Run: `grep -n "var autoMergeEnabled\|var autoDelegationEnabled\|var digestEnabled\|var webhooksEnabled\|var showsMenuBarExtra\|var diffRenderer\|var intelligenceMode" Shepherd/Support/AppSettings.swift`
Run: `grep -n "repositoryCount\|var inboxRows" Shepherd/App/SignedInSession.swift`

Use the names that exist. Where a flag has no equivalent (for example if auto-delegation is stored inside a rules object rather than as a `Bool`), read the rules object's own `isEnabled` — ADR 0016's `AutoDelegationRules.isEnabled` — rather than inventing a setting.

- [ ] **Step 4: Call both from `bootstrap()`**

Run: `grep -n "func bootstrap" -A 25 Shepherd/App/AppEnvironment.swift`

At the end of `bootstrap()`, after the existing `applyDiagnosticsSetting()`-style calls:

```swift
        applyTelemetryLevel()
        recordLaunchHeartbeat()
```

- [ ] **Step 5: Add the `onChange` route in `ShepherdApp`**

After the `diagnosticsEnabled` block (~line 40):

```swift
                // And once more for usage telemetry (ADR 0036): the picker in Settings and an
                // applied settings document both land here, so there is one route from "the level
                // changed" to "the mechanism exists or does not".
                .onChange(of: environment.settings.telemetryLevel) { _, _ in
                    environment.applyTelemetryLevel()
                }
```

- [ ] **Step 6: Run the tests and build**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shepherd/App ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): one route from the level to the mechanism"
```

---

### Task 10: The twelve call sites

**Files:**
- Modify: the feature files found by the greps below
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `AppEnvironment.telemetry`, `TelemetryEvent`.
- Produces: no new API — only `environment.telemetry?.record(…)` calls.

Every call is one line, in the place where the action has **already succeeded**. Recording an intent rather than an outcome would make every number a measure of clicking, not of doing.

- [ ] **Step 1: Review submitted**

Run: `grep -rn "func submitReview\|submitPendingReview\|case approve" Shepherd/Features/PullRequest/PullRequestActions.swift | head -20`

In the success branch after the review write is enqueued:

```swift
        environment.telemetry?.record(
            .reviewSubmitted(
                kind: reviewKind,          // .approve / .requestChanges / .comment, mapped from the local event enum
                inlineComments: CountBucket(count: pendingComments.count),
                usedTemplate: usedTemplate,
                usedSavedReply: usedSavedReply
            )
        )
```

- [ ] **Step 2: Pull request merged**

Run: `grep -rn "func merge\|mergeMethod" Shepherd/Features/PullRequest/PullRequestActions.swift | head -20`

After the merge is enqueued, with `source: .detail` here, `.bulk` in the bulk-triage path and `.autoRule` in the auto-merge path:

```swift
        environment.telemetry?.record(.pullRequestMerged(method: telemetryMergeMethod, source: .detail))
```

- [ ] **Step 3: Focus session**

Run: `grep -rln "FocusSession" Shepherd/Features`

Where the session ends — both when the queue is exhausted and when the user leaves early:

```swift
        environment.telemetry?.record(
            .focusSessionCompleted(queueSize: CountBucket(count: startingQueueCount), completed: reachedTheEnd)
        )
```

- [ ] **Step 4: Bulk triage**

Run: `grep -rln "BulkTriage\|bulkApprove" Shepherd/Features`

After the confirmation sheet's action runs:

```swift
        environment.telemetry?.record(.bulkTriagePerformed(action: .approve, size: CountBucket(count: selected.count)))
```

- [ ] **Step 5: Search**

Run: `grep -rln "SearchRanker\|func search(" Shepherd/Features/Search`

Once per submitted search, with `openedResult` recorded when a result is opened from that search:

```swift
        environment.telemetry?.record(.searchUsed(kind: wasReferenceMatch ? .reference : .semantic, openedResult: openedResult))
```

- [ ] **Step 6: Delegation start and finish**

Run: `grep -n "func start\|func finish\|DelegationOutcome\|enum Outcome" Shepherd/Features/Delegation/DelegationCenter.swift | head -20`

```swift
        environment.telemetry?.record(.delegationStarted(trigger: startedByRule ? .ciRedRule : .manual))
```

and, where a delegation ends:

```swift
        environment.telemetry?.record(.delegationFinished(outcome: telemetryOutcome))
```

- [ ] **Step 7: Intelligence**

Run: `grep -n "func route\|enum Tier\|case onDevice" Shepherd/Intelligence/IntelligenceRouter.swift | head -20`

One call in the router, where the tier and the outcome are both already known — that is the single place all six features pass through:

```swift
        telemetry?.record(.intelligenceUsed(feature: feature, tier: tier, outcome: outcome))
```

If `IntelligenceRouter` has no access to the environment, pass an optional `UsageTelemetry` into its initialiser rather than reaching for a singleton.

- [ ] **Step 8: Auto-merge, issues, fleet, digest**

```swift
        environment.telemetry?.record(.autoMergeRuleFired(outcome: merged ? .merged : .skipped))
        environment.telemetry?.record(.issuesInboxUsed(action: .commented))
        environment.telemetry?.record(.fleetViewed(scope: repositoryScoped ? .repo : .all))
        environment.telemetry?.record(.digestOpened(source: .notification))
```

Run: `grep -rln "AutoMerge" Shepherd/Automation`, `grep -rln "IssuesInbox\|issueRows" Shepherd/Features`, `grep -rln "Fleet" Shepherd/Features`, `grep -rln "DigestCoordinator" Shepherd/Features/Digest`

- [ ] **Step 9: Prove the call sites are wired with one test per family**

Append to `ShepherdTests/TelemetryTests.swift` a test that records one of each event through a real `UsageTelemetry` and asserts the queue holds thirteen distinct names:

```swift
extension TelemetryTests {
    func testEveryEventInTheVocabularyCanBeRecordedAndQueued() {
        let telemetry = makeTelemetry(level: .anonymous, defaults: makeDefaults(), sender: RecordingSender())

        for event in TelemetryEvent.allExamples {
            telemetry.record(event)
        }

        XCTAssertEqual(Set(TelemetryQueue(directory: directory).load().map(\.name)).count, 13)
    }
}
```

- [ ] **Step 10: Run the tests**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add Shepherd ShepherdTests/TelemetryTests.swift
git commit -m "feat(telemetry): record the thirteen, where they actually happen"
```

---

### Task 11: The notice sheet and the settings card

**Files:**
- Create: `Shepherd/Features/Settings/TelemetryNoticeSheet.swift`
- Create: `Shepherd/Features/Settings/TelemetrySettingsCard.swift`
- Modify: `Shepherd/Features/Settings/SettingsView.swift` (Account tab, after the diagnostics section ~line 370)
- Modify: `Shepherd/App/ShepherdApp.swift` or `RootView` (presenting the sheet)
- Modify: `Shepherd/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AppSettings.telemetryLevel`, `AppSettings.telemetryNoticeAcknowledged`, `AppEnvironment.applyTelemetryLevel()`, `UsageTelemetry.pendingEvents`, `UsageTelemetry.clearQueue()`.
- Produces: `TelemetryNoticeSheet`, `TelemetrySettingsCard`.

- [ ] **Step 1: Write `TelemetryNoticeSheet.swift`**

The wording carries the legal basis, so it is not a yes/no question: level 1 rests on legitimate interest with a right to object, and a symmetric consent dialog would put it on a basis it does not have.

```swift
import SwiftUI

/// The first-run notice (ADR 0036).
///
/// Notice, not consent — and the difference is visible in the buttons. Anonymous counting rests on
/// legitimate interest with a right to object, so this states what is sent and offers an immediate
/// way out; a symmetric "yes / no" would look like a consent dialog for something that is not
/// consent-based, and pre-ticked consent is not consent at all. The one thing here that *is*
/// consent — the reach level — is its own, separate button.
struct TelemetryNoticeSheet: View {
    /// Called with the level the user chose.
    let choose: (TelemetryLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shepherd counts a little")
                .font(.system(size: 17, weight: .semibold))

            Text("So we know which half of Shepherd is worth building on, the app sends anonymous counts: the version, the language, and which features you use. No identifier, nothing that could recognise this Mac again, and never a repository, a branch or any of your code.")
                .fixedSize(horizontal: false, vertical: true)

            Text("You can switch this off at any time in Settings → Account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Also count reach") { choose(.reach) }
                Spacer()
                Button("Turn usage statistics off") { choose(.off) }
                Button("Understood") { choose(.anonymous) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
```

- [ ] **Step 2: Write `TelemetrySettingsCard.swift`**

```swift
import SwiftUI

/// Settings → Account: the level, what is queued, and a way to throw it away (ADR 0036).
struct TelemetrySettingsCard: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingPayload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Usage statistics", selection: levelBinding) {
                ForEach(TelemetryLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.radioGroup)

            Text(environment.settings.telemetryLevel.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Show what would be sent") { isShowingPayload = true }
                Button("Clear queue") { environment.telemetry?.clearQueue() }
                    .disabled(environment.telemetry == nil)
            }
        }
        .sheet(isPresented: $isShowingPayload) {
            TelemetryPayloadSheet(events: environment.telemetry?.pendingEvents ?? [])
        }
    }

    private var levelBinding: Binding<TelemetryLevel> {
        Binding(
            get: { environment.settings.telemetryLevel },
            set: {
                environment.settings.telemetryLevel = $0
                // Builds or tears the mechanism down right away, the way the diagnostics toggle
                // registers and removes the MetricKit subscriber right away.
                environment.applyTelemetryLevel()
            }
        )
    }
}

/// The literal JSON that is waiting to be sent.
///
/// Not a summary and not a description: the bytes. This is the card's whole argument — a promise
/// about what leaves the Mac is only worth as much as the ability to check it.
struct TelemetryPayloadSheet: View {
    let events: [QueuedEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting to be sent")
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    private var json: String {
        guard !events.isEmpty else {
            return String(localized: "Nothing is waiting to be sent.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events), let text = String(data: data, encoding: .utf8) else {
            return String(localized: "The queue could not be read.")
        }
        return text
    }
}
```

- [ ] **Step 3: Place the card in Settings**

Run: `grep -n "diagnosticsBinding\|Diagnostics" Shepherd/Features/Settings/SettingsView.swift | head`

Add `TelemetrySettingsCard()` to the Account tab directly below the diagnostics section, inside the same container the diagnostics block uses.

- [ ] **Step 4: Present the sheet on first run**

In the view that owns the main window, present `TelemetryNoticeSheet` when `!environment.settings.telemetryNoticeAcknowledged` and a PostHog key exists:

```swift
                .sheet(isPresented: .constant(AppConfig.postHogProjectKey != nil && !environment.settings.telemetryNoticeAcknowledged)) {
                    TelemetryNoticeSheet { level in
                        environment.settings.telemetryLevel = level
                        environment.settings.telemetryNoticeAcknowledged = true
                        environment.applyTelemetryLevel()
                        environment.recordLaunchHeartbeat()
                    }
                }
```

A development build has no key, so the sheet never appears while working on Shepherd — which is also why it must be tested by temporarily setting `SHPostHogProjectKey` in `project.yml`, never by weakening the condition.

- [ ] **Step 5: Localise every new string**

Run: `mise run check`
Expected: it names any string missing its German translation. Add each one to `Shepherd/Resources/Localizable.xcstrings`:

| English | German |
|---|---|
| Shepherd counts a little | Shepherd zählt ein wenig mit |
| Understood | Verstanden |
| Turn usage statistics off | Nutzungsstatistik ausschalten |
| Also count reach | Auch Reichweite messen |
| Usage statistics | Nutzungsstatistik |
| Show what would be sent | Zeigen, was gesendet würde |
| Clear queue | Warteschlange löschen |
| Waiting to be sent | Wartet auf den Versand |
| Nothing is waiting to be sent. | Es wartet nichts auf den Versand. |
| The queue could not be read. | Die Warteschlange konnte nicht gelesen werden. |
| Off | Aus |
| Anonymous | Anonym |
| Anonymous + reach | Anonym + Reichweite |

Translate the three `explanation` strings and the sheet's two paragraphs in the same pass; keep them as plain, literal German as the table above.

- [ ] **Step 6: Run the build, the tests and the checks**

Run: `mise run check && mise run test-app 2>&1 | tail -20`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add Shepherd/Features/Settings Shepherd/App Shepherd/Resources/Localizable.xcstrings
git commit -m "feat(telemetry): a notice that is a notice, and a card that shows the bytes"
```

---

### Task 12: The build-time key

**Files:**
- Modify: `project.yml` (the `info.properties` block, after the Sparkle keys ~line 155)
- Modify: `.github/workflows/release.yml` (before the signing step)
- Modify: `docs/RELEASING.md`
- Modify: `ShepherdTests/TelemetryTests.swift`

**Interfaces:**
- Consumes: `AppConfig.postHogProjectKey`.
- Produces: the `SHPostHogProjectKey` Info.plist entry and the release step that fills it.

- [ ] **Step 1: Write the failing test**

Append to `ShepherdTests/TelemetryTests.swift`:

```swift
extension TelemetryTests {
    // MARK: - The build-time key

    /// The test host is built without a key, and that is the assertion: development builds, test
    /// runs and forks have no mechanism at all, because `UsageTelemetry.make` refuses to build one.
    func testATestBuildHasNoPostHogKeyAndThereforeNoTelemetry() {
        XCTAssertNil(AppConfig.postHogProjectKey)

        let settings = AppSettings(defaults: makeDefaults())
        settings.telemetryLevel = .anonymous
        settings.telemetryNoticeAcknowledged = true

        XCTAssertNil(UsageTelemetry.make(settings: settings))
    }

    /// An empty or absent key must read the same way — as "no mechanism" — so that a build whose
    /// injection step failed is inert rather than half-configured.
    func testAnEmptyKeyReadsAsNoKey() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.telemetryLevel = .anonymous
        settings.telemetryNoticeAcknowledged = true

        XCTAssertNil(UsageTelemetry.make(settings: settings, key: nil))
        XCTAssertNil(UsageTelemetry.make(settings: settings, key: ""))
        XCTAssertNil(UsageTelemetry.make(settings: settings, key: "   "))
    }
}
```

- [ ] **Step 2: Run to verify the first test fails**

Run: `mise run test-app 2>&1 | tail -30`
Expected: FAIL — `AppConfig.postHogProjectKey` is not `nil` only if a key leaked into the project file; if it passes immediately, confirm with `grep -n SHPostHogProjectKey project.yml` that no value is committed.

- [ ] **Step 3: Add the empty entry to `project.yml`**

In the app target's `info.properties`, after the Sparkle block:

```yaml
        # ── Usage telemetry (ADR 0036) ──────────────────────────────────────────────────────
        # PLACEHOLDER, and it stays a placeholder in the repository. The real value is the
        # PostHog EU project's *public* write key, written into the built bundle's Info.plist by
        # .github/workflows/release.yml from the POSTHOG_TOKEN secret, before code signing —
        # after signing it could not be written, because the signature covers this file. Empty
        # here means `AppConfig.postHogProjectKey` answers nil, `UsageTelemetry` is never
        # constructed, and a development build, a test run and a fork therefore have no queue,
        # no timer and no request at all. The key is public by design: it ships in every binary
        # and `strings` will find it, which is why it is not a secret in the app and why the
        # numbers it produces are indicators rather than bookkeeping.
        SHPostHogProjectKey: ""
```

- [ ] **Step 4: Verify the placeholder is what is committed**

Run: `grep -n "SHPostHogProjectKey" project.yml`
Expected: exactly one hit, with an empty string value. If a real `phc_…` value appears here, remove it — it belongs in the secret store only.

- [ ] **Step 5: Add the release step**

Run: `grep -n "codesign\|sign" .github/workflows/release.yml | head -20`

Immediately **before** the first signing step:

```yaml
      # The PostHog project key (ADR 0036). Written before signing, because the signature covers
      # Info.plist; a release built without the secret ships an empty value, and an empty value
      # means the app has no telemetry mechanism at all rather than a broken one.
      - name: Inject the PostHog project key
        env:
          POSTHOG_TOKEN: ${{ secrets.POSTHOG_TOKEN }}
        run: |
          if [ -z "$POSTHOG_TOKEN" ]; then
            echo "::warning::POSTHOG_TOKEN is not set; this build ships without usage telemetry."
            exit 0
          fi
          plutil -replace SHPostHogProjectKey -string "$POSTHOG_TOKEN" "$APP_PATH/Contents/Info.plist"
          plutil -p "$APP_PATH/Contents/Info.plist" | grep -q SHPostHogProjectKey
```

Use the workflow's own variable for the built app rather than `$APP_PATH` if it is called something else — check with `grep -n "\.app" .github/workflows/release.yml | head`.

- [ ] **Step 6: Document it in `docs/RELEASING.md`**

Beside the Sparkle keys section:

```markdown
## The PostHog project key

`POSTHOG_TOKEN` is a GitHub Actions secret (synced from Infisical) holding the *public* write key
of the PostHog EU project behind ADR 0036. The release workflow writes it into the built bundle's
`Info.plist` before signing; `project.yml` keeps an empty placeholder, so every build that is not a
release — yours, CI's, a fork's — has no key and therefore no telemetry mechanism at all.

It is not a confidential value: it ships inside every binary. Rotating it is a PostHog project
setting plus a new secret, and old builds simply stop reporting.
```

- [ ] **Step 7: Run the tests and commit**

Run: `mise run test-app 2>&1 | tail -20`
Expected: PASS.

```bash
git add project.yml .github/workflows/release.yml docs/RELEASING.md ShepherdTests/TelemetryTests.swift
git commit -m "build(telemetry): the key exists only in a release"
```

---

### Task 13: The retired promise

**Files:**
- Modify: `README.md` (lines 13, 80, 118, 245)
- Modify: `CONTRIBUTING.md` (line 149 and the host list)
- Modify: `docs/FEATURES.md` (line 859)
- Create: `docs/PRIVACY.md`

**Interfaces:**
- Consumes: ADR 0036 from Task 1, the shipped behaviour from Tasks 2–12.
- Produces: documentation that matches the code. This task goes **last** on purpose: until the feature exists, every sentence here would be a promise about something that does not.

- [ ] **Step 1: Rewrite the `CONTRIBUTING.md` bullet**

Run: `sed -n '145,152p' CONTRIBUTING.md`

Replace `- No telemetry, ever. The complete list of hosts Shepherd may contact:` with:

```markdown
- Telemetry is anonymous, switchable off in one click, and named here. Shepherd counts allow-listed
  events — thirteen of them, every property an enum or a bucket — and never a repository, a branch,
  a title, a path or a line of code (ADR 0036). Level `anonymous` stores no identifier at all;
  level `reach` is opt-in and stores a random UUID that is thrown away every month. The complete
  list of hosts Shepherd may contact:
```

- [ ] **Step 2: Add the host to the list**

In the same style as the neighbouring entries, add a bullet after the settings-sync one:

```markdown
  - only while usage telemetry is on: **eu.i.posthog.com** (ADR 0036). One `POST` to `/batch/`,
    roughly once a day, carrying allow-listed event names, the app version, the macOS major
    version, the UI language and — at the `reach` level only — a UUID that is re-minted every
    month. `$ip` is sent as `null` and no person profile is created. With the level `off` nothing
    is queued, no timer runs and this host is never contacted; a build without the release key has
    no telemetry mechanism at all;
```

- [ ] **Step 3: Update the README**

- Line 13, the badge:

  ```markdown
  [![Telemetry: anonymous, opt-out](https://img.shields.io/badge/telemetry-anonymous%20%C2%B7%20opt--out-4cc38a?style=flat-square)](docs/PRIVACY.md)
  ```

- Line 80: replace "there is no telemetry anywhere" with "usage telemetry is anonymous, allow-listed and off in one click".
- Line 118: replace the "**No telemetry, ever.**" bullet with "**Anonymous telemetry, off in one click.**" and point at `docs/PRIVACY.md` beside `CONTRIBUTING.md`.
- Line 245: adjust the trailing summary in the same words.

Run: `grep -n "telemetry" README.md`
Expected: four hits, none of them claiming there is none.

- [ ] **Step 4: Update `docs/FEATURES.md:859`**

Run: `sed -n '855,862p' docs/FEATURES.md`

Replace "No server, no telemetry, no account other than your GitHub login" with "No server, no account other than your GitHub login, and telemetry that is anonymous and off in one click".

- [ ] **Step 5: Write `docs/PRIVACY.md`**

Sections, in this order: what Shepherd stores on your Mac (database, drafts, diagnostics folder, telemetry queue); what leaves your Mac and to which host (the CONTRIBUTING list, summarised); the telemetry section proper — the two levels, the thirteen events as a table, the **literal JSON body**, the legal bases (Art. 6(1)(f) for `anonymous` with the Art. 21 objection right, Art. 6(1)(a) plus § 25(1) TDDDG for `reach`), what withdrawal deletes, retention, that schnaq GmbH is the controller and PostHog the processor in the EU region, and a contact address.

State plainly that the project key is public and the numbers are therefore indicators. If a public dashboard is published, link it here.

- [ ] **Step 6: Verify nothing still claims the old promise**

Run: `grep -rn "No telemetry, ever\|no telemetry" README.md CONTRIBUTING.md docs/ | grep -v "docs/adr/0017"`
Expected: no hits.

- [ ] **Step 7: Commit**

```bash
git add README.md CONTRIBUTING.md docs/FEATURES.md docs/PRIVACY.md
git commit -m "docs(telemetry): retire a promise, and say exactly what replaced it"
```

---

## Verification before the branch is finished

- [ ] `mise run ci` is clean (this runs `check`, the package tests, the app tests and the build in the order CI runs them).
- [ ] `grep -rn "phc_" --include="*.yml" --include="*.swift" .` finds nothing — the key lives in the secret store, never in the repository.
- [ ] The PostHog project checklist in ADR 0036 § Consequences has been carried out in `https://eu.posthog.com/project/277838`: GeoIP off, client IP discarded, retention set, session recording / autocapture / surveys off.
- [ ] A release build made with the secret reports one `app_active_day` per day, and a second launch on the same day does not add a second one.
