import SwiftUI

/// Settings → Account → Usage statistics: the level, what is queued, and a way to throw it away
/// (ADR 0036).
///
/// It sits directly below the diagnostics section because the two answer the same question from
/// opposite ends — what this Mac keeps about itself, and what it says about itself — and because
/// a user looking for either will look in the same place.
///
/// The three levels are a radio group, every option on screen at once and none louder than the
/// others: since the 2026-09-22 amendment the anonymous level rests on consent, and this switch is
/// how that consent is withdrawn. Where the counts go and who is responsible for them is one click
/// away in the header's ⓘ, and the exact bytes one more click away in the payload sheet.
struct TelemetrySettingsCard: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingPayload = false

    var body: some View {
        Section {
            Picker(String(localized: "Level"), selection: levelBinding) {
                ForEach(TelemetryLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.radioGroup)

            LabeledContent {
                HStack(spacing: 8) {
                    Button(String(localized: "Show what would be sent")) { isShowingPayload = true }
                    Button(String(localized: "Clear queue")) { environment.telemetry?.clearQueue() }
                        .disabled(environment.telemetry == nil)
                }
            } label: {
                Text(String(localized: "Queue"))
                if let telemetry = environment.telemetry {
                    Text(verbatim: telemetry.queueFileURL.path)
                        .font(Theme.mono(.caption))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Link(String(localized: "Privacy statement"), destination: AppConfig.privacyPolicyURL)
                .help(String(localized: "What Shepherd stores, what leaves your Mac, and to whom"))
        } header: {
            HStack(spacing: 4) {
                Text(String(localized: "Usage statistics"))
                InfoButton(String(
                    localized: "Counts leave this Mac about once a day, to eu.i.posthog.com. Your IP address is discarded and no profile is kept. schnaq GmbH is responsible for the data."
                ))
            }
        } footer: {
            SettingsNote(environment.settings.telemetryLevel.explanation)
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
    /// The sheet's heading.
    var title: String = String(localized: "Waiting to be sent")
    /// The events to print, or `nil` to print ``exampleJSON`` — the first-run question shows what
    /// *would* be sent before anything has been recorded, and a promise about bytes is best kept
    /// by showing the bytes.
    var events: [QueuedEvent]?

    @Environment(\.dismiss) private var dismiss

    init(events: [QueuedEvent]) {
        self.events = events
    }

    private init(title: String) {
        self.title = title
        self.events = nil
    }

    /// The sheet the first-run question opens: one representative event, in the exact shape
    /// `docs/PRIVACY.md` documents.
    static var example: TelemetryPayloadSheet {
        TelemetryPayloadSheet(title: String(localized: "An example of what is sent"))
    }

    /// One `review_submitted` event as it leaves the Mac. Kept in step with `docs/PRIVACY.md` § 2.
    static let exampleJSON = """
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
            "app_version": "1.3.0",
            "os_major": 27,
            "locale": "de",
            "kind": "approve",
            "inline_comments": "1-3"
          }
        }
      ]
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.type(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)
            ScrollView {
                Text(json)
                    .font(Theme.mono(.subheadline))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    private var json: String {
        guard let events else { return Self.exampleJSON }
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
