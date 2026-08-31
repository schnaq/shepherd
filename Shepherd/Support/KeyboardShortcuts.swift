import Foundation
import ShepherdCore
import SwiftUI

/// Every keyboard-driven action the inbox and review screens expose.
///
/// `docs/ARCHITECTURE.md` ("UI conventions") makes the two-keystroke review actions normative:
/// `r a` approve, `r c` comment, `r x` request changes, `m` merge; `g` prefixes the grouping
/// commands. Single keys navigate.
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
    /// Re-group the inbox (`g a` / `g r` / `g s`).
    case groupBy(InboxFacet)

    /// The key hint shown in the shortcut bar and the command palette.
    var keyHint: String {
        switch self {
        case .selectNext: return "j"
        case .selectPrevious: return "k"
        case .openSelection: return "⏎"
        case .approve: return "r a"
        case .requestChanges: return "r x"
        case .comment: return "r c"
        case .merge: return "m"
        case .groupBy(.provenance): return "g a"
        case .groupBy(.repository): return "g r"
        case .groupBy(.reviewState): return "g s"
        }
    }
}

/// The two-keystroke state machine behind `r a`, `r x`, `r c` and `g a/r/s`.
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

/// A key cap, as drawn in the shortcut bar and the command palette footer.
struct KeyCapView: View {
    /// The key text, e.g. `"⌘K"` or `"r a"`.
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Theme.controlBorder, lineWidth: 1)
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
