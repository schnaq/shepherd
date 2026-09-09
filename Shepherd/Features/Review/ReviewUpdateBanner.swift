import SwiftUI

/// The strip that says what GitHub did to this pull request while the review was open.
///
/// It is a *notice*, never a swap, and that is the whole reason it exists. A push replaces the
/// head commit every inline comment in the pending review is anchored against, so the screen
/// cannot quietly show the new diff instead: it says a new one is there and waits to be asked.
/// Merged and closed share the slot because they are the same kind of fact — something happened
/// elsewhere that this screen cannot absorb by itself — and they carry no Reload, because there
/// is nothing left to reload into. A refresh that failed shares it for the opposite reason: the
/// diff on screen is fine and stays, and the only thing to say is that Shepherd could not check
/// whether it is still current. That one carries a Try again rather than a Reload — there is
/// nothing held back, only a request to make again.
///
/// Colour is never the only carrier (ADR 0033): the sentence says what happened, the symbol
/// repeats it in a shape, and the tint is the third telling rather than the first.
struct ReviewUpdateBanner: View {
    /// What happened.
    let notice: ReviewModel.Notice
    /// Applies the held-back detail. Only reachable while the notice is a push.
    var onReload: () -> Void
    /// Asks GitHub again. Only reachable while the notice is a failed refresh.
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(Theme.type(.footnote))
                    .foregroundStyle(tint)
                    // The shape repeats the sentence beside it, so announcing it as well would
                    // say the same thing twice.
                    .accessibilityHidden(true)
                Text(message)
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if notice.offersReload {
                    Button(action: onReload) {
                        HStack(spacing: 6) {
                            Text(String(localized: "Reload"))
                            KeyCapView(keys: "u")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
                    .help(String(localized: "Show the new commits (u)"))
                }
                if notice.offersRetry {
                    Button(String(localized: "Try again"), action: onRetry)
                        .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            Divider().overlay(Theme.border)
        }
        .background(Theme.raised)
        // `.contain` rather than `.combine`: the Reload button has to stay its own element so the
        // keyboard and VoiceOver can reach it, and the label names the group they are in rather
        // than replacing what they say (CONTRIBUTING, ADR 0033).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(message))
        // A heading, so the banner is reachable by VoiceOver's own heading navigation rather than
        // only by walking the whole window: it appears while somebody is already deep in a diff,
        // which is exactly where walking back to the top is expensive (ADR 0033).
        .accessibilityAddTraits(.isHeader)
    }

    /// The sentence the banner is for, and the one its accessibility label repeats.
    private var message: String {
        switch notice {
        case .newCommits(let count):
            guard let count else {
                return String(localized: "Updated on GitHub — new commits.")
            }
            return String(localized: "Updated on GitHub — \(count) new commits.")
        case .merged:
            return String(localized: "Merged on GitHub.")
        case .closed:
            return String(localized: "Closed on GitHub.")
        case .refreshFailed(let message):
            return String(localized: "Could not refresh: \(message)")
        }
    }

    private var symbol: String {
        switch notice {
        case .newCommits: return "arrow.triangle.branch"
        case .merged: return "arrow.triangle.pull"
        case .closed: return "xmark.octagon"
        case .refreshFailed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice {
        case .newCommits: return Theme.accent
        case .merged: return Theme.success
        case .closed: return Theme.textMuted
        case .refreshFailed: return Theme.failure
        }
    }
}
