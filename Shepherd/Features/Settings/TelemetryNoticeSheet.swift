import SwiftUI

/// The first-run question (ADR 0036, 2026-09-22 amendment).
///
/// A question, not a notice: since the amendment nothing is counted until the reader has said yes,
/// so the sheet asks, and it asks the way consent has to be asked — the two answers carry the same
/// weight, neither is pre-selected, and declining is the cancel action so that Escape is the quick
/// way out rather than the quick way in. The one refinement that needs its own decision, counting
/// people across months, is a switch that is off until it is turned on, and it only means anything
/// together with a yes.
///
/// Nothing has been recorded by the time this appears: `telemetryNoticeAcknowledged` is false on a
/// fresh install, `telemetryLevel` is `off`, and ``UsageTelemetry/make(settings:key:queue:sender:)``
/// refuses to build anything while either says no. Answering sets both.
struct TelemetryNoticeSheet: View {
    /// Called with the level the user chose.
    let choose: (TelemetryLevel) -> Void

    @State private var countsReach = false
    @State private var isShowingExample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "chart.bar.xaxis")
                    .font(Theme.type(.title2, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "May Shepherd count, anonymously?"))
                        .font(Theme.type(.title3, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    // Vertically fixed, and rightly so here: the sheet's width is fixed at 500 pt
                    // below, so this measures against a real width — unlike a split-view column,
                    // where ``EmptyStateView`` explains why the same modifier is a bug.
                    Text(String(
                        localized: "Shepherd is built on what gets used. To know that, the app would send us a few numbers about once a day."
                    ))
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                fact(String(localized: "The version, the language, and which features are used"), included: true)
                fact(String(localized: "Only as categories and buckets, never as text"), included: true)
                fact(String(localized: "No identifier, no repository, no branch, not a line of code"), included: false)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(String(
                    localized: "The counts go to PostHog in the EU (eu.i.posthog.com); your IP address is discarded and no profile is kept. schnaq GmbH is responsible for the data."
                ))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button(String(localized: "Show what would be sent")) { isShowingExample = true }
                        .buttonStyle(.link)
                    Link(String(localized: "Privacy statement"), destination: AppConfig.privacyPolicyURL)
                        .help(String(localized: "What Shepherd stores, what leaves your Mac, and to whom"))
                }
                .font(Theme.type(.callout))
            }

            Toggle(isOn: $countsReach) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Also count how many people use Shepherd each month"))
                        .font(Theme.type(.body))
                        .foregroundStyle(Theme.text)
                    Text(String(localized: "A random identifier is stored for this and thrown away every month."))
                        .font(Theme.type(.callout))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 10) {
                Text(String(localized: "You can change this at any time in Settings → Account."))
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                // Same style, same size, neither pre-selected: a yes that is easier to give than
                // the no beside it is not freely given. Escape declines.
                Button(String(localized: "Not now")) { choose(.off) }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Yes, count anonymously")) { choose(countsReach ? .reach : .anonymous) }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 500)
        .sheet(isPresented: $isShowingExample) {
            TelemetryPayloadSheet.example
        }
    }

    private func fact(_ text: String, included: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: included ? "checkmark" : "xmark")
                .font(Theme.type(.caption, weight: .bold))
                .foregroundStyle(included ? Theme.success : Theme.failure)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
