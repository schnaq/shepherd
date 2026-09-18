import SwiftUI

/// The first-run notice (ADR 0036).
///
/// Notice, not consent — and the difference is visible in the buttons. Anonymous counting rests on
/// legitimate interest with a right to object, so this states what is sent and offers an immediate
/// way out; a symmetric "yes / no" would look like a consent dialog for something that is not
/// consent-based, and pre-ticked consent is not consent at all. The one thing here that *is*
/// consent — the reach level — is its own, separate button, and it is the quiet one rather than
/// the default, because a consent that is easier to give than to withhold is not freely given.
///
/// Nothing has been recorded by the time this appears: `telemetryNoticeAcknowledged` is false on a
/// fresh install and ``UsageTelemetry/make(settings:key:queue:sender:)`` refuses to build anything
/// while it is. The sheet is what turns the mechanism on, in whichever of the three directions the
/// reader chooses.
struct TelemetryNoticeSheet: View {
    /// Called with the level the user chose.
    let choose: (TelemetryLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Shepherd counts a little"))
                .font(Theme.type(.title3, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text(String(
                localized: "So we know which half of Shepherd is worth building on, the app sends anonymous counts: the version, the language, and which features you use. No identifier, nothing that could recognise this Mac again, and never a repository, a branch or any of your code."
            ))
            .font(Theme.type(.body))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)

            Text(String(
                localized: "schnaq GmbH is responsible for this data. You can switch it off at any time in Settings → Account."
            ))
            .font(Theme.type(.callout))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                // The consent half, and deliberately the quietest control on the sheet: it is the
                // only choice here that needs consent, and a consent offered more loudly than the
                // refusal beside it is not freely given.
                Button(String(localized: "Also count reach")) { choose(.reach) }
                Spacer()
                Button(String(localized: "Turn usage statistics off")) { choose(.off) }
                Button(String(localized: "Understood")) { choose(.anonymous) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
