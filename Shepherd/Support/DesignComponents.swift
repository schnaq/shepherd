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

/// The bordered, control-coloured `TextEditor` every Markdown field in the app uses.
///
/// Extracted because the review summary, the inline comment composer and the two Settings editors
/// for saved replies and templates are the same control, and a comment field that looks different
/// depending on which sheet it is in reads as two different features.
///
/// It is also where Apple's Writing Tools are switched on for the whole app (ADR 0020). Every
/// field that holds *review prose* is this control, so `.writingToolsBehavior(.complete)` here
/// means proofreading, rewriting and tone changes are available in all of them and cannot be
/// forgotten in the next one — while single-line fields, which are not prose, opt in one by one at
/// their call site instead of inheriting a full rewrite panel they have no room for.
struct ComposerTextEditor: View {
    /// The edited text.
    let text: Binding<String>
    /// The field's fixed height.
    var height: CGFloat = 130
    /// The font size.
    var size: CGFloat = 12
    /// The colour the text is drawn in.
    ///
    /// A parameter rather than a second control, because the one field that needs another colour
    /// needs it for a second and a half: while an AI draft *streams* into it, the growing text is
    /// drawn in the caption colour (plan §3.B), which is the same signal the caption under the
    /// field carries and is readable while the reviewer is looking at the words rather than at
    /// the line below them.
    ///
    /// The whole field takes the colour, not only the part the model wrote. Styling a *range*
    /// would mean an attributed-text editor, and appending a draft under the reviewer's own
    /// paragraph is the only case where the two differ — for the second the stream runs, and
    /// never afterwards, because the tint goes as soon as the stream ends.
    var textColor: Color = Theme.text

    var body: some View {
        TextEditor(text: text)
            .font(.system(size: size))
            .foregroundStyle(textColor)
            .writingToolsBehavior(.complete)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.controlBorder, lineWidth: 1)
            )
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

    private var helpText: String { CheckDotView.spokenState(state) }

    /// What the dot's colour means, in words.
    ///
    /// `internal` and `static` because a coloured dot inside a list row is announced by the row
    /// rather than on its own: the row's spoken label has to be able to say the same sentence
    /// this view says in its tooltip, and one definition is the only way the two cannot drift.
    /// - Parameter state: The rollup state, or `nil` when there is none.
    static func spokenState(_ state: CheckRollup.State?) -> String {
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
        .accessibilityLabel(Text(DiffCountsView.spokenCounts(additions: additions, deletions: deletions)))
    }

    /// The pair in words, for a row that announces itself as one element.
    /// - Parameters:
    ///   - additions: Added lines.
    ///   - deletions: Deleted lines.
    static func spokenCounts(additions: Int, deletions: Int) -> String {
        String(localized: "\(additions) added, \(deletions) deleted")
    }
}

/// The agent / bot / human chip used on inbox rows and the review header.
struct ProvenanceChip: View {
    /// The author.
    let actor: ShepherdCore.Actor
    /// The font size.
    var size: CGFloat = 11
    /// A colour that replaces the agent palette's, when the caller has something to say about
    /// this author (ADR 0027: the track record *colours* the provenance chip).
    ///
    /// `nil` — the default — is the palette colour, which is what every existing caller gets and
    /// what a row with no history keeps.
    var tint: Color?

    var body: some View {
        ChipView(text: label, color: tint ?? AgentPalette.color(for: actor.kind), size: size)
            .help(helpText)
    }

    private var label: String {
        actor.login
    }

    private var helpText: String { ProvenanceChip.spokenProvenance(of: actor) }

    /// Who opened it and how Shepherd knows, in words — see ``CheckDotView/spokenState(_:)``
    /// for why a row needs this as a function rather than as a tooltip.
    /// - Parameter actor: The author.
    static func spokenProvenance(of actor: ShepherdCore.Actor) -> String {
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

// MARK: - Action status

/// The one line a finished ``AsyncActionState`` shows: green with a tick, or red with a warning.
///
/// ``AsyncActionState/idle`` and ``AsyncActionState/running`` show nothing at all — the spinner
/// belongs beside the button that started the run, not underneath it — which is what lets a
/// caller drop this in unconditionally.
struct AsyncActionStatusLine: View {
    /// The state to describe.
    let state: AsyncActionState

    var body: some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .success(let message):
            line(message, systemImage: "checkmark.circle", tint: Theme.success)
        case .failure(let message):
            line(message, systemImage: "exclamationmark.triangle", tint: Theme.failure)
        }
    }

    private func line(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            // Wraps instead of truncating: these lines are a remote server's own words, and a
            // failure the user cannot read in full is worth nothing.
            .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Queued writes

/// Which kind of node a ``QueueStatusLine`` is describing (ADR 0006).
///
/// The outbox holds writes against pull requests and against issues, and the line's one
/// target-specific sentence is why this exists: a reviewer looking at a pull request must not be
/// told that an *issue* moved on underneath their write.
enum QueueStatusTarget {
    /// A pull request, as ``InboxDetailPanel`` shows it.
    case pullRequest
    /// An issue, as ``IssueDetailPanel`` shows it.
    case issue

    /// The parked indicator's sentence.
    /// - Parameter parked: How many writes the drain parked.
    func parkedMessage(_ parked: Int) -> String {
        switch self {
        case .pullRequest:
            return String(localized: "\(parked) parked — the pull request moved on")
        case .issue:
            return String(localized: "\(parked) parked — the issue moved on")
        }
    }

    /// The tooltip the whole line carries.
    var help: String {
        switch self {
        case .pullRequest:
            return String(
                localized: "Shepherd writes every change to a local queue first and sends it in the background. A parked write is one the pull request changed underneath; a failed one was given up on and will not be retried. Settings → Sync lists them."
            )
        case .issue:
            return String(
                localized: "Shepherd writes every change to a local queue first and sends it in the background. A parked write is one the issue changed underneath; a failed one was given up on and will not be retried. Settings → Sync lists them."
            )
        }
    }
}

/// What the outbox is holding for one pull request or one issue, in one line (ADR 0006).
///
/// The three states a queued write can end in: waiting to be sent, parked because the target
/// moved on underneath the write, and given up on. Three counts of zero draw nothing at all,
/// which is what lets a panel drop this in unconditionally — ``AsyncActionStatusLine``'s
/// arrangement, for the same reason.
///
/// One view rather than the same `HStack` in both detail panels: the two lines are the same three
/// symbols, the same three colours and two of the same three sentences (ADR 0006's 2026-09-04
/// amendment), and a queue that looked like two different features depending on which panel it
/// was under would be the only lasting effect of writing it twice. What differs travels with the
/// target — ``QueueStatusTarget`` carries the sentence that names it — and each panel keeps its
/// own reason for showing the line where it shows it.
///
/// The standing counts in Settings → Sync, the title bar and the morning digest are unchanged and
/// remain account-wide; this line is what makes them findable from where the write was queued.
/// It deliberately carries no Retry or Discard button on either side: those belong to
/// Settings → Sync, which the failed indicator names, because they exist for somebody who has
/// just changed a token or a branch rule and wants to see the whole queue.
struct QueueStatusLine: View {
    /// How many writes are queued or in flight.
    let queued: Int
    /// How many the drain parked because the target moved on.
    let parked: Int
    /// How many the drain gave up on.
    let failed: Int
    /// Which kind of node the three counts are about.
    let target: QueueStatusTarget

    var body: some View {
        if queued > 0 || parked > 0 || failed > 0 {
            HStack(spacing: 6) {
                if queued > 0 {
                    indicator(
                        String(localized: "\(queued) waiting to be sent"),
                        systemImage: "tray.full",
                        symbolTint: Theme.pending,
                        textTint: Theme.textSecondary
                    )
                }
                if parked > 0 {
                    indicator(
                        target.parkedMessage(parked),
                        systemImage: "exclamationmark.triangle",
                        symbolTint: Theme.failure,
                        textTint: Theme.textSecondary
                    )
                }
                if failed > 0 {
                    indicator(
                        String(localized: "\(failed) failed — see Settings → Sync"),
                        systemImage: "xmark.octagon",
                        symbolTint: Theme.failure,
                        textTint: Theme.failure
                    )
                }
                Spacer(minLength: 0)
            }
            .help(target.help)
        }
    }

    /// One indicator: its symbol and its sentence, handed to the line as two siblings rather than
    /// as a nested stack, so that all three of them keep the one spacing.
    @ViewBuilder
    private func indicator(
        _ message: String,
        systemImage: String,
        symbolTint: Color,
        textTint: Color
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10))
            .foregroundStyle(symbolTint)
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(textTint)
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
