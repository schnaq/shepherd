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
    /// An optional way out of the state: one button under the message.
    ///
    /// Optional, and last, so every existing call site compiles unchanged. It exists because not
    /// every empty state is a fact to be read: a detail fetch that failed and a file list GitHub
    /// has not sent yet are both *recoverable*, and describing a fixable problem without offering
    /// the fix leaves the reviewer hunting for the refresh key.
    var action: (title: String, run: () -> Void)?

    // No `.fixedSize(horizontal: false, vertical: true)` on the message, here or in the two
    // siblings below — and none may be added back. This view is the whole content of a
    // `NavigationSplitView` column whenever a list is empty, and with a vertically fixed message
    // the split view lays *every* column out far taller than the window and centres the lot: the
    // rail's first rows above the title bar, Fleet and Settings below the bottom edge, which is
    // what "the sidebar jumps when the list says Nothing to review" was.
    //
    // Measured on 2026-09-22 with a stand-alone three-column reproduction, columns logged in
    // window coordinates. With this sentence fixed, the columns came out 1,165 pt (one empty
    // state showing) and 1,224 pt (two) inside a 998 pt content area. Of nine candidate fixes —
    // the columns' ideal height, the window frame, the toolbar, the safe-area insets, a scroll
    // view around the empty state — only dropping `fixedSize` put all three columns back at the
    // toolbar's edge, in both the empty and the filled state; a ten-character message stayed
    // correct *with* the modifier, so the excess grows with the text. The rendered message was
    // 287 × 30 pt, two lines, in every run: without the modifier nothing truncates, because the
    // frame around it has all the height it needs. What the split view proposes during that
    // measurement is not observable from here; the deduction is a very narrow width, which a
    // fixed `Text` answers with a height for every word. The 1,158 pt of the 2026-09-17
    // cold-start fix is very likely the same mechanism through ``LoadingStateView``'s message —
    // not re-measured, since that state cannot be held still.
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
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// ``EmptyStateView``'s sibling for a list that has nothing to show *yet*.
///
/// Same geometry, same type sizes, same muted colours, with a `ProgressView` where the symbol
/// goes. It exists because an empty list a second after signing in and an empty list after the
/// sweep came back are the same pixels and opposite claims: "No one is waiting on you" is a
/// statement of fact, and Shepherd cannot make it before it has asked GitHub. The spinner is the
/// part that says the sentence is not final yet, so it is a component rather than a modifier on
/// the empty state — a caller has to choose one or the other, and choosing is the point.
struct LoadingStateView: View {
    /// The headline: what is happening, not what was found.
    var title: String
    /// An optional second line, saying what is being looked for.
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if let message {
                // Not vertically fixed — see ``EmptyStateView``.
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
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

/// Whether the control this environment reaches is running its own write.
///
/// An environment value rather than a parameter on each style, because the thing that knows is
/// the *call site* — it holds the ``ActionActivity`` key — and the thing that draws is the style.
/// Set it with ``SwiftUI/View/busy(_:)``.
private struct ButtonIsBusyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the control is running its own write, so the style can put a spinner in its label.
    var buttonIsBusy: Bool {
        get { self[ButtonIsBusyKey.self] }
        set { self[ButtonIsBusyKey.self] = newValue }
    }
}

extension View {
    /// Marks this control as running its own write: its label becomes a spinner, and it stops
    /// answering clicks and its keyboard shortcut.
    ///
    /// The presentation lives in the three button styles below rather than in a wrapper around
    /// the label, and that is not a detail: each of them ends with `.opacity(isEnabled ? 1 :
    /// 0.45)` over the whole label, so a spinner *inside* the label was drawn at 45 % — always,
    /// because the same flag that raised it had already disabled the button. Read where the dim
    /// is decided, the two rules compose: a busy button is not a dimmed button.
    ///
    /// The disable is part of the modifier on purpose. `.disabled` is what takes a
    /// `.keyboardShortcut` with it, and ⌘⏎ or ⏎ held down is the fastest way to ask for the same
    /// write twice — so "shows it is running" and "refuses a second press" cannot come apart.
    /// - Parameter isBusy: Whether this control's own write is in flight.
    /// - Returns: The control, spinning and inert while `isBusy`.
    func busy(_ isBusy: Bool) -> some View {
        environment(\.buttonIsBusy, isBusy)
            .disabled(isBusy)
    }
}

extension View {
    /// This label, while its control is busy: held in place at zero opacity with a spinner over
    /// it, so the button keeps its width and a row of them does not reflow.
    ///
    /// The three styles below draw it, and so does the one write button in the app that is on
    /// `.plain` rather than on a style — the file list's *Mark viewed*, which ``View/busy(_:)``
    /// cannot reach because the modifier's presentation lives in the styles. That button used to
    /// hand-roll this pair of modifiers, which is two chances for the app's spinners to stop
    /// agreeing about what "running" looks like.
    /// - Parameters:
    ///   - isBusy: Whether to show the spinner instead.
    ///   - tint: The spinner's colour, normally the caller's own text colour so it reads on the
    ///     fill. `nil` leaves the spinner on whatever tint it inherits, which is what a control
    ///     outside the three styles wants.
    /// - Returns: The label, or the spinner in its place.
    @ViewBuilder
    func busyLabel(isBusy: Bool, tint: Color? = nil) -> some View {
        opacity(isBusy ? 0 : 1)
            .overlay {
                if isBusy {
                    if let tint {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
    }
}

// MARK: - Buttons: which style goes where (ADR 0040)
//
// Two families, and the line between them is the line between the control layer and the content.
//
// **In a toolbar, or floating over content** — the window's toolbar, anything in a
// `GlassEffectContainer` — a button is the system's: the toolbar's default style for an ordinary
// item (a toolbar item *is* already Liquid Glass, so an explicit `.buttonStyle(.glass)` inside one
// nests a second capsule in the first), `.glassProminent` tinted with a theme colour for the one
// recommended action in the bar (the review toolbar's green Merge), and `.glass` only for a
// button that floats on its own outside a toolbar. The system then does what these styles cannot:
// Reduce Transparency, Increase Contrast, the press and hover response of the glass itself.
//
// **Inside content** — a card, a sheet, a panel, a list header, an empty state — a button is one
// of the three styles below. Content is opaque by rule (ADR 0040), and a glass button on an
// opaque card is glass with nothing behind it to refract. Do not mass-replace these with glass.
//
// **The prominent action is Merge** (ADR 0040's 2026-09-23 amendment, the maintainer's decision).
// On every surface that offers it, Merge is the one green, filled button — `.glassProminent`
// tinted ``Theme/success`` in a toolbar, ``SuccessButtonStyle`` in content — and a blocker
// disables it rather than repainting it. Approve is secondary everywhere (it keeps its tick and
// its shortcut), so no surface shows two green buttons. Green is Merge's colour and nothing
// else's: a sheet's default action that is not a merge (Submit, Commit & push, Approve N) is
// ``PrimaryButtonStyle``.
//
// One thing a system style does not inherit: ``SwiftUI/View/busy(_:)``'s spinner is drawn by the
// three styles here, so a write button on a system style must put
// ``SwiftUI/View/busyLabel(isBusy:tint:)`` on its own label, as the review toolbar's Merge does.

/// The filled accent button.
struct PrimaryButtonStyle: ButtonStyle {
    /// The control height.
    var height: CGFloat = 32

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonIsBusy) private var isBusy

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.white)
            // The style's own text colour, not ``Theme/textOnFilled``: this fill is the accent
            // and its label is white on both appearances.
            .busyLabel(isBusy: isBusy, tint: Color.white)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            // A busy button is disabled but not dimmed — the spinner is the message, and a
            // spinner at 45 % is the bug this arrangement exists to prevent.
            .opacity(isEnabled || isBusy ? 1 : 0.45)
    }
}

/// The filled green button used for Approve / Merge / Submit.
struct SuccessButtonStyle: ButtonStyle {
    /// The control height.
    var height: CGFloat = 32

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonIsBusy) private var isBusy

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textOnFilled)
            .busyLabel(isBusy: isBusy, tint: Theme.textOnFilled)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                Theme.success.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(isEnabled || isBusy ? 1 : 0.45)
    }
}

/// The bordered neutral button.
struct SecondaryButtonStyle: ButtonStyle {
    /// The control height.
    var height: CGFloat = 32
    /// An optional label tint (used for the red "Request changes").
    var tint: Color?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonIsBusy) private var isBusy

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(
            configuration: configuration,
            height: height,
            tint: tint,
            isEnabled: isEnabled,
            isBusy: isBusy
        )
    }
}

/// ``SecondaryButtonStyle``'s body, a view of its own so it can hold the hover state.
///
/// A button that does not answer the pointer reads as a label — the review screen's back button
/// was the one that made it obvious — so every secondary button now lightens under the pointer and
/// shows the pointing hand, the same feedback the rail's rows give.
private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let tint: Color?
    let isEnabled: Bool
    let isBusy: Bool

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint ?? Theme.text)
            .busyLabel(isBusy: isBusy, tint: tint ?? Theme.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                Theme.control.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isHovering && isEnabled {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.text.opacity(0.06))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.controlBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled || isBusy ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
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
    /// Sends this target's failed writes again, right here. `nil` keeps the pointer to
    /// Settings → Sync, for a surface that cannot act.
    var onRetry: (() -> Void)?

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
                        onRetry == nil
                            ? String(localized: "\(failed) failed — see Settings → Sync")
                            : String(localized: "\(failed) not sent"),
                        systemImage: "xmark.octagon",
                        symbolTint: Theme.failure,
                        textTint: Theme.failure
                    )
                    if let onRetry {
                        Button(String(localized: "Retry"), action: onRetry)
                            .buttonStyle(SecondaryButtonStyle(height: 22, tint: Theme.accentText))
                            .help(String(localized: "Send the failed changes to GitHub again"))
                    }
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

extension View {
    /// A background that fills this view's own frame and nothing more (ADR 0040).
    ///
    /// A colour background reaches into every safe area its view touches by default. Under the
    /// window's toolbar that means a bar at the top of the content — a file list, a session bar,
    /// an update banner — paints an opaque band up behind the toolbar's glass. These surfaces are
    /// content, not the toolbar, so they paint where they are and leave the toolbar strip alone.
    /// - Parameter color: The fill.
    func ownFrameBackground(_ color: Color) -> some View {
        background(color, ignoresSafeAreaEdges: [])
    }
}
