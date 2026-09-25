import Foundation
import ShepherdCore
import SwiftUI

/// Every keyboard-driven action the inbox and review screens expose.
///
/// `docs/ARCHITECTURE.md` ("UI conventions") makes the two-keystroke review actions normative:
/// `r a` approve, `r c` comment, `r x` request changes, `r f` start a focus review session,
/// `m` merge; `g` prefixes the grouping commands. Single keys navigate.
enum ShortcutAction: Equatable, Sendable {
    /// Move the selection one row down (`j` / ↓).
    case selectNext
    /// Move the selection one row up (`k` / ↑).
    case selectPrevious
    /// Open the selected pull request (⏎).
    case openSelection
    /// Approve (`r a`).
    case approve
    /// Request changes (`r x`).
    case requestChanges
    /// Leave a comment review (`r c`).
    case comment
    /// Open the merge dialog (`m`).
    case merge
    /// Start the guided pass over every pull request waiting for review (`r f`, ⇧⌘⏎).
    ///
    /// Under the `r` prefix because it is a review command, not a grouping one, and `f` for
    /// *focus*: the session is the app's one screen with nothing else on it.
    case startReviewSession
    /// Re-group the inbox (`g a` / `g r` / `g s`).
    case groupBy(InboxFacet)
    /// Hand the selected pull request to the local agent CLI (ADR 0011). Menu/palette only —
    /// it opens a sheet, which is not something a bare keystroke should do by accident.
    case delegate
    /// Tick or untick the pull request under the cursor for a bulk action (`x`, ADR 0015).
    case toggleMark
    /// Tick every green agent pull request in the current view (ADR 0015). Menu/palette only:
    /// it changes a whole selection, so it wants a name, not a keystroke.
    case markGreenAgentPullRequests
    /// Open the bulk-triage confirmation for the ticked pull requests (ADR 0015). Menu/palette
    /// only — like ``merge`` it opens a dialog rather than writing anything.
    case bulkTriage(BulkTriageAction)
    /// Open the merge-series sheet for the ticked pull requests (ADR 0041). Menu/palette only,
    /// like ``bulkTriage(_:)``: it opens a dialog.
    case mergeSeries

    /// The key hint shown in the shortcut bar and the command palette.
    var keyHint: String {
        switch self {
        case .delegate, .markGreenAgentPullRequests, .bulkTriage, .mergeSeries: return ""
        case .toggleMark: return "x"
        case .selectNext: return "j"
        case .selectPrevious: return "k"
        case .openSelection: return "⏎"
        case .approve: return "r a"
        case .requestChanges: return "r x"
        case .comment: return "r c"
        case .startReviewSession: return "r f"
        case .merge: return "m"
        case .groupBy(.provenance): return "g a"
        case .groupBy(.repository): return "g r"
        case .groupBy(.reviewState): return "g s"
        }
    }
}

/// The two-keystroke state machine behind `r a`, `r x`, `r c`, `r f` and `g a/r/s`.
///
/// Kept as a value type with an injected clock so it can be unit-tested without a window: a
/// prefix that is not completed within ``timeout`` is forgotten, so a stray `r` never swallows
/// the next keystroke.
struct KeySequenceState: Sendable {
    /// What a keystroke produced.
    enum Resolution: Equatable, Sendable {
        /// The keystroke completed (or was) a command.
        case action(ShortcutAction)
        /// The keystroke started a two-key sequence; the next key completes it.
        case awaitingSecondKey(Character)
        /// Nothing matched; the caller should let the event travel on.
        case unhandled
    }

    /// How long a pending prefix stays armed.
    var timeout: TimeInterval = 1.5

    private var pendingPrefix: Character?
    private var pendingSince: Date?

    /// Creates an idle state machine.
    init(timeout: TimeInterval = 1.5) {
        self.timeout = timeout
    }

    /// The prefix currently armed, for the UI hint.
    var armedPrefix: Character? { pendingPrefix }

    /// Whether the *next* keystroke belongs to a sequence rather than meaning what it usually
    /// means.
    ///
    /// Which matters because two commands can want the same letter: `r c` submits the review as
    /// a comment, and a bare `c` hands the keyboard to the diff (ADR 0033's amendment). A screen
    /// that acts on a bare key before consulting this would eat the second half of every
    /// sequence that ends in the same letter — and, worse, leave the prefix armed, so the
    /// keystroke *after* it would be read as a second key too.
    ///
    /// Time-aware for the same reason ``consume(_:at:)`` is: a prefix nobody completed within
    /// ``timeout`` is forgotten, so a stale `r` from a minute ago must not block anything.
    /// - Parameter date: When the next keystroke would arrive.
    func isAwaitingSecondKey(at date: Date = Date()) -> Bool {
        guard pendingPrefix != nil, let since = pendingSince else { return false }
        return date.timeIntervalSince(since) <= timeout
    }

    /// Feeds one character in.
    /// - Parameters:
    ///   - character: The typed character (already lowercased by the caller if needed).
    ///   - date: When it was typed.
    /// - Returns: What the keystroke means.
    mutating func consume(_ character: Character, at date: Date = Date()) -> Resolution {
        let lowered = Character(String(character).lowercased())

        if let prefix = pendingPrefix, let since = pendingSince,
           date.timeIntervalSince(since) <= timeout {
            pendingPrefix = nil
            pendingSince = nil
            if let action = Self.action(prefix: prefix, second: lowered) {
                return .action(action)
            }
            return .unhandled
        }

        pendingPrefix = nil
        pendingSince = nil

        switch lowered {
        case "j": return .action(.selectNext)
        case "k": return .action(.selectPrevious)
        case "m": return .action(.merge)
        case "x": return .action(.toggleMark)
        case "r", "g":
            pendingPrefix = lowered
            pendingSince = date
            return .awaitingSecondKey(lowered)
        default:
            return .unhandled
        }
    }

    /// Drops any armed prefix (called when the view loses focus or Escape is pressed).
    mutating func reset() {
        pendingPrefix = nil
        pendingSince = nil
    }

    private static func action(prefix: Character, second: Character) -> ShortcutAction? {
        switch (prefix, second) {
        case ("r", "a"): return .approve
        case ("r", "x"): return .requestChanges
        case ("r", "c"): return .comment
        case ("r", "f"): return .startReviewSession
        case ("g", "a"): return .groupBy(.provenance)
        case ("g", "r"): return .groupBy(.repository)
        case ("g", "s"): return .groupBy(.reviewState)
        default: return nil
        }
    }
}

extension KeyPress {
    /// Whether this key press is the given key equivalent.
    ///
    /// Compares the underlying `Character` rather than the `KeyEquivalent` values themselves,
    /// which keeps the check independent of whether `KeyEquivalent` is `Equatable` in the SDK
    /// being built against.
    /// - Parameter equivalent: The key to test for.
    func matches(_ equivalent: KeyEquivalent) -> Bool {
        key.character == equivalent.character
    }
}

extension View {
    /// Asks for a focus again, a frame or two after `condition` becomes true.
    ///
    /// The hop the command palette and the two keyboard-driven lists all need, for one reason:
    /// the view that is *giving* focus up is being torn down in the same update as the ask, and a
    /// focus requested during a teardown does not always stick. The palette then looks focused
    /// and is not — the first word typed goes to the list behind it as shortcuts — and the list,
    /// coming back after the palette closes, stays dead to `j` and `k` until a row is clicked.
    ///
    /// `.task(id:)` rather than a `Task {}`: it is cancelled and restarted when `condition`
    /// changes and torn down with the view, which is the behaviour the manual version had to be
    /// trusted to get right three times. The `try?` on the sleep is deliberate and the one place
    /// this is written down: a cancelled hop is not a failure anybody asked for, and there is
    /// nothing to report — the `Task.isCancelled` check after it is what stops a focus that has
    /// *just* been handed elsewhere from being snatched back.
    /// - Parameters:
    ///   - focus: The focus state to reassert.
    ///   - condition: Reassert while this is true; do nothing while it is false.
    ///   - delay: How long to wait. Long enough for the teardown, short enough to be invisible.
    /// - Returns: The view, reasserting the focus once per trigger.
    func reassertingFocus(
        _ focus: FocusState<Bool>.Binding,
        when condition: Bool,
        after delay: Duration = .milliseconds(60)
    ) -> some View {
        task(id: condition) {
            guard condition else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            focus.wrappedValue = true
        }
    }
}

/// A key cap, as drawn in the shortcut bar and the command palette footer.
struct KeyCapView: View {
    /// The key text, e.g. `"⌘K"` or `"r a"`.
    let keys: String
    /// Whether this cap sits on a filled button (Success / Primary).
    ///
    /// The muted stroke and secondary text this view draws everywhere else disappear against an
    /// accent or green fill, so a cap on one of those buttons needs its own colours instead.
    var onFilledBackground = false

    var body: some View {
        Text(keys)
            .font(.system(size: 11))
            .foregroundStyle(onFilledBackground ? Theme.textOnFilled : Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                onFilledBackground ? Color.white.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(onFilledBackground ? Color.clear : Theme.controlBorder, lineWidth: 1)
            )
    }
}

/// One `j k navigate`-style hint in the footer bar.
struct ShortcutHintView: View {
    /// The key cap text.
    let keys: [String]
    /// What the keys do.
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                KeyCapView(keys: key)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
    }
}
