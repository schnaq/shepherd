import ShepherdCore
import SwiftUI

// MARK: - Containers

/// The raised, bordered card used throughout the detail panel and onboarding.
struct Card<Content: View>: View {
    /// Extra tint behind the card, used by the AI hint card.
    var tint: Color?
    /// The card's contents.
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                tint ?? Theme.raised,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint == nil ? Theme.border : Theme.accent.opacity(0.22), lineWidth: 1)
            )
    }
}

/// The tiny, letter-spaced, uppercase caption at the top of a card.
struct CardTitle: View {
    private let text: String
    private let tint: Color?

    /// Creates a caption.
    /// - Parameters:
    ///   - text: The caption, already uppercased by the caller.
    ///   - tint: An optional colour override.
    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(tint ?? Theme.textMuted)
    }
}

/// The empty state every list needs.
struct EmptyStateView: View {
    /// An SF Symbol name.
    var systemImage: String
    /// The headline.
    var title: String
    /// An optional second line.
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 320)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Buttons

/// The filled accent button.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

/// The filled green button used for Approve / Merge / Submit.
struct SuccessButtonStyle: ButtonStyle {
    /// The control height.
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textOnFilled)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                Theme.success.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

/// The bordered neutral button.
struct SecondaryButtonStyle: ButtonStyle {
    /// The control height.
    var height: CGFloat = 32
    /// An optional label tint (used for the red "Request changes").
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint ?? Theme.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                Theme.control.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.controlBorder, lineWidth: 1)
            )
    }
}

// MARK: - Chips and dots

/// A rounded pill: agent names, review states, reason tags.
struct ChipView: View {
    /// The chip text.
    let text: String
    /// The foreground colour; the background is the same colour at 13 %.
    var color: Color = Theme.accentText
    /// The font size.
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Theme.chipBackground(color),
                in: Capsule(style: .continuous)
            )
    }
}

/// The CI status dot in front of every inbox row.
struct CheckDotView: View {
    /// The rolled-up state, or `nil` when the pull request has no checks.
    let state: CheckRollup.State?
    /// The dot's diameter.
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .help(helpText)
            .accessibilityLabel(Text(helpText))
    }

    private var color: Color {
        switch state {
        case .some(.success): return Theme.success
        case .some(.failure): return Theme.failure
        case .some(.pending): return Theme.pending
        case .some(.none), nil: return Theme.priorityMuted
        }
    }

    private var helpText: String {
        switch state {
        case .some(.success): return String(localized: "All checks passed")
        case .some(.failure): return String(localized: "Checks failing")
        case .some(.pending): return String(localized: "Checks running")
        case .some(.none), nil: return String(localized: "No checks")
        }
    }
}

/// The `+412 −96` monospaced pair.
struct DiffCountsView: View {
    /// Added lines.
    let additions: Int
    /// Deleted lines.
    let deletions: Int
    /// The font size.
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)")
                .foregroundStyle(Theme.success)
            Text("−\(deletions)")
                .foregroundStyle(Theme.failure)
        }
        .font(Theme.mono(size))
        .monospacedDigit()
        .accessibilityLabel(Text(String(localized: "\(additions) added, \(deletions) deleted")))
    }
}

/// The agent / bot / human chip used on inbox rows and the review header.
struct ProvenanceChip: View {
    /// The author.
    let actor: ShepherdCore.Actor
    /// The font size.
    var size: CGFloat = 11

    var body: some View {
        ChipView(text: label, color: AgentPalette.color(for: actor.kind), size: size)
            .help(helpText)
    }

    private var label: String {
        actor.login
    }

    private var helpText: String {
        switch actor.kind {
        case .human:
            return String(localized: "Opened by a person")
        case .bot:
            return String(localized: "Opened by a bot account")
        case .agent(let identity):
            return String(localized: "Detected as \(identity.displayName) (matched by \(identity.matchedBy.rawValue))")
        }
    }
}

/// The section header used by the inbox list and the left rail.
struct RailSectionHeader: View {
    /// The caption text.
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.7)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }
}

// MARK: - Small helpers

extension ReviewDecision {
    /// The chip text for a review decision.
    var chipTitle: String {
        switch self {
        case .approved: return String(localized: "Approved")
        case .changesRequested: return String(localized: "Changes requested")
        case .reviewRequired: return String(localized: "Review required")
        }
    }

    /// The chip colour.
    var chipColor: Color {
        switch self {
        case .approved: return Theme.success
        case .changesRequested: return Theme.failure
        case .reviewRequired: return Theme.accentText
        }
    }
}

extension PriorityBucket {
    /// The colour of this bucket's header and dots.
    var tint: Color {
        switch self {
        case .reviewFirst: return Theme.priority
        case .standard: return Theme.textSecondary
        case .skim: return Theme.textMuted
        case .generated: return Theme.priorityMuted
        }
    }

    /// The localized section title.
    var localizedTitle: String {
        switch self {
        case .reviewFirst: return String(localized: "Review first")
        case .standard: return String(localized: "Standard")
        case .skim: return String(localized: "Skim")
        case .generated: return String(localized: "Generated")
        }
    }
}
