import ShepherdCore
import SwiftUI

/// Three lines above a long review thread: what was agreed, what is still open, who is waiting on
/// whom (plan §3.G).
///
/// A card and nothing else. Four things about what it draws are decisions:
///
/// - **The state is a chip, not a sentence.** *Agreed* / *Open* / *Blocked* is the one part of a
///   digest a reviewer reads at a glance, and it sits beside the caption where the thread's own
///   *resolved* and *outdated* chips sit, so the vocabulary of the popover stays one vocabulary.
/// - **The coverage line is not optional decoration.** When the thread did not fit the budget the
///   digest is a digest of its *end*, and a card that did not say so would be presenting a
///   summary of eight comments as a summary of twenty-three
///   (``ShepherdCore/ThreadDigestResult/wasTruncated``).
/// - **"Summarised on-device" is a statement about privacy, not a badge.** These are colleagues'
///   comments; the caption is where a reviewer finds out that they did not travel (ADR 0007's
///   amendment, ADR 0020's argument).
/// - **There is no action in it.** No *Resolve*, no *Reply*, no *Try again with the cloud*.
///   Resolving a thread is the reviewer's own button in the bar below, and this card is not
///   allowed to recommend pressing it.
struct ThreadDigestCard: View {
    /// What to draw: a spinner, a digest, or one line saying why there is neither.
    let state: ThreadDigestState

    var body: some View {
        Card(tint: Theme.accent.opacity(0.06)) {
            VStack(alignment: .leading, spacing: 6) {
                header
                switch state {
                case .loading:
                    Text(String(localized: "Reading the thread…"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                case .digest(let result):
                    digestBody(result)
                case .failed(let reason):
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accentText)
            CardTitle(String(localized: "THREAD DIGEST"), tint: Theme.accentText)
            Spacer(minLength: 0)
            if case .digest(let result) = state {
                ChipView(
                    text: ThreadDigestCard.label(for: result.digest.state),
                    color: ThreadDigestCard.colour(for: result.digest.state),
                    size: 10
                )
            }
        }
    }

    @ViewBuilder
    private func digestBody(_ result: ThreadDigestResult) -> some View {
        Text(result.digest.summary)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if !result.digest.openQuestions.isEmpty {
            CardTitle(String(localized: "STILL OPEN"))
                .padding(.top, 2)
            // Walked by index rather than by value: the model's order is the order it thought
            // in, and two questions that came back identically worded would collide on an id of
            // `\.self` and lose one of the bullets.
            ForEach(result.digest.openQuestions.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .foregroundStyle(Theme.pending)
                    Text(result.digest.openQuestions[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Summarised on-device"))
            if result.wasTruncated {
                Text(ThreadDigestCard.coverage(result))
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textMuted)
        .padding(.top, 2)
    }

    /// The chip's word for one state.
    /// - Parameter state: What the thread has arrived at.
    static func label(for state: ThreadDigest.State) -> String {
        switch state {
        case .agreed: return String(localized: "Agreed")
        case .open: return String(localized: "Open")
        case .blocked: return String(localized: "Blocked")
        }
    }

    /// The chip's colour for one state.
    ///
    /// Amber for *blocked* rather than red: somebody waiting on somebody else is the state that
    /// wants attention, and it is not a failure — red in this app means a check that failed or a
    /// review that rejected.
    /// - Parameter state: What the thread has arrived at.
    static func colour(for state: ThreadDigest.State) -> Color {
        switch state {
        case .agreed: return Theme.success
        case .open: return Theme.accentText
        case .blocked: return Theme.pending
        }
    }

    /// The line that says how much of the thread the digest covers.
    /// - Parameter result: The digest and its counts.
    static func coverage(_ result: ThreadDigestResult) -> String {
        String(
            localized: "Covers the last \(result.coveredCount) of \(result.totalCount) comments"
        )
    }
}
