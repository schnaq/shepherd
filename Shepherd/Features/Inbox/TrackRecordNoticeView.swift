import ShepherdCore
import SwiftUI

/// The inbox's one-time offer to load the track record (ADR 0027's 2026-09-05 amendment).
///
/// The backfill stays manual, and the reasoning in ADR 0027 is unchanged: it reads up to five
/// hundred closed pull requests per repository, and the user did not ask for that. What the ADR
/// did not settle is how anybody is supposed to find out that the button exists. It lives on the
/// second card of the Automation tab of a Settings sheet, so for a reviewer who never opened that
/// sheet the badge, the LANES rail and the whole "Shepherd knows this agent" promise were not
/// switched off — they were invisible, which is worse, because there is nothing to switch back on.
///
/// So the offer is made once, in the place the badges would appear, and it is answered once. It
/// runs the *same* backfill the Settings button runs
/// (``AppEnvironment/startTrackRecordBackfill()``) and reads the *same* progress off the
/// coordinator that owns the run, so the two surfaces cannot disagree about whether something is
/// happening or about how far it has got — pressing *Load track record* here and then opening
/// Settings shows one run, not two.
///
/// It sits where ``DigestCardView`` sits, as a top safe-area inset above the list, and it goes for
/// good in three ways: *Not now*, a run that came back, and a history on disk that makes the offer
/// pointless — the five conditions are
/// ``InboxModel/showsTrackRecordNotice(hasCompletedFirstSweep:rows:hasReadStoredCount:storedOutcomeCount:isDismissed:)``.
struct TrackRecordNoticeView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Records that the offer has been answered, whichever way it was.
    var onAnswer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "TRACK RECORD"), tint: Theme.accentText)
                    Text(String(
                        localized: "See how each agent's pull requests have fared in your repositories — rounds, merges, reverts."
                    ))
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    // The cost, in the notice rather than only in a tooltip. This is the one
                    // thing on screen that spends several hundred GitHub requests on a press,
                    // and a reviewer deciding whether to press it is owed the number before
                    // rather than a progress line afterwards.
                    Text(String(
                        localized: "It reads the pull requests your repositories closed in the last 90 days, at most 500 per repository, and the sync keeps it current from then on."
                    ))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    controls
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(Theme.background)
        // A run that has stopped running has answered the offer, however it stopped: it finished,
        // or somebody pressed *Stop*. Without this the one case the stored count cannot cover
        // would bring the notice back on the next launch — a run over repositories whose last
        // ninety days hold nothing to store leaves the count at zero, and re-offering a button
        // the user has already pressed is exactly the nagging a one-time notice must not do.
        .onChange(of: environment.trackRecord.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            onAnswer()
        }
        // One element with its actions, rather than four elements a screen-reader user walks
        // through (ADR 0033). A banner is read as a whole — the sentence, its price, and what can
        // be done about it — and `children: .ignore` is what makes the two buttons *actions of
        // this element* instead of two more stops in the rotor. The label is built from the same
        // strings the card draws, for the row rule's reason: two spellings of one sentence would
        // drift, and the spoken one is the one nobody notices drifting.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenNotice))
        .accessibilityActions {
            if environment.trackRecord.isRunning {
                Button(String(localized: "Stop")) { environment.trackRecord.cancel() }
            } else {
                Button(String(localized: "Load track record")) { load() }
                Button(String(localized: "Not now")) { onAnswer() }
            }
        }
    }

    // MARK: - Pieces

    /// The buttons, or the progress line and a way out of it while a run is in flight.
    @ViewBuilder
    private var controls: some View {
        if environment.trackRecord.isRunning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if let progressLine {
                    Text(progressLine)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(String(localized: "Stop")) { environment.trackRecord.cancel() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
            }
        } else {
            HStack(spacing: 8) {
                Button(String(localized: "Load track record")) { load() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(environment.trackRecordBackfillRepositories.isEmpty)
                Button(String(localized: "Not now")) { onAnswer() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer(minLength: 0)
            }
        }
    }

    /// The same line the Settings card shows, from the same coordinator (ADR 0027).
    private var progressLine: String? {
        environment.trackRecord.progress.map { TrackRecordProgressLine.text(for: $0) }
    }

    /// The whole notice as one sentence, for the element that replaces its children.
    private var spokenNotice: String {
        SpokenRow.sentence([
            String(
                localized: "See how each agent's pull requests have fared in your repositories — rounds, merges, reverts."
            ),
            String(
                localized: "It reads the pull requests your repositories closed in the last 90 days, at most 500 per repository, and the sync keeps it current from then on."
            ),
            environment.trackRecord.isRunning ? progressLine : nil,
        ])
    }

    private func load() {
        environment.startTrackRecordBackfill()
    }
}
