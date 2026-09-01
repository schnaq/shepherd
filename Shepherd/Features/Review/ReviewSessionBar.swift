import SwiftUI

/// The thin bar the focus review session puts above the review screen.
///
/// Everything it shows is derived from ``ReviewSession``: where the cursor is, what is under it,
/// and the three ways out. It renders no pull-request data of its own and owns no state — the
/// review screen underneath it is the *same* review screen a single pull request opens in, which
/// is the point: a session is a way of moving through reviews, not a second review UI.
struct ReviewSessionBar: View {
    /// The running session.
    let session: ReviewSession
    /// Passes over the current pull request.
    var onNext: () -> Void
    /// Counts the current pull request as reviewed and moves on.
    var onDoneAndNext: () -> Void
    /// Ends the session.
    var onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                progressLabel
                progressTrack
                title
                Spacer(minLength: 8)
                buttons
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            Divider().overlay(Theme.border)
        }
        .background(Theme.raised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(String(localized: "Review session, \(session.position) of \(session.total)"))
        )
    }

    // MARK: - Progress

    private var progressLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text(String(localized: "\(session.position) of \(session.total)"))
                .font(Theme.mono(12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textStrong)
        }
        .help(sessionHelp)
    }

    /// A four-segment-free, plain fill bar: the numbers carry the meaning, this carries the
    /// feeling of getting somewhere.
    private var progressTrack: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.priorityMuted)
                Capsule(style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: max(0, proxy.size.width * session.progress))
            }
        }
        .frame(width: 84, height: 4)
        .accessibilityHidden(true)
    }

    private var title: some View {
        Group {
            if let current = session.current {
                HStack(spacing: 8) {
                    Text(current.slug)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .layoutPriority(1)
                    Text(current.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(String(localized: "No pull request left in this session."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: onDoneAndNext) {
                HStack(spacing: 6) {
                    Text(String(localized: "Done & next"))
                    KeyCapView(keys: "d")
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
            .disabled(session.isFinished)
            .help(String(
                localized: "Count this pull request as reviewed and move to the next one. Approving, requesting changes or merging does this on its own."
            ))

            Button(action: onNext) {
                HStack(spacing: 6) {
                    Text(String(localized: "Next"))
                    KeyCapView(keys: "n")
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 26))
            .disabled(session.isFinished)
            .help(String(localized: "Leave this one for later and move to the next pull request"))

            Button(action: onEnd) {
                HStack(spacing: 6) {
                    Text(String(localized: "End"))
                    KeyCapView(keys: "esc")
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 26))
            .help(String(localized: "End the session and go back to the inbox"))
        }
    }

    private var sessionHelp: String {
        String(
            localized: "The queue was frozen when the session started, so pull requests arriving now wait in the inbox. \(session.remaining) left."
        )
    }
}
