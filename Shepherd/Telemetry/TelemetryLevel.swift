import Foundation

/// How much Shepherd may count (ADR 0036).
///
/// Three levels rather than a switch, because the two questions behind them have different
/// answers in law: counting *events* needs no consent as long as nothing on the Mac can recognise
/// it again, and counting *people over time* needs exactly that recognition and therefore
/// exactly that consent.
enum TelemetryLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Nothing is collected and nothing is sent. Not "collected and discarded" — the mechanism is
    /// never built (`UsageTelemetry` is `nil`), so there is no queue file and no timer.
    case off
    /// Allow-listed counts with no identifier: the `distinct_id` is minted in memory at launch and
    /// is gone when the queue is flushed. Answers "how many installations were active today",
    /// never "which ones".
    case anonymous
    /// The above plus a random UUID stored for the current UTC month and thrown away when the
    /// month turns. This — and only this — makes monthly active users countable, which is why it
    /// is the only level that is opt-in.
    case reach

    var id: String { rawValue }

    /// Whether any event may be recorded at all.
    var sendsEvents: Bool { self != .off }

    /// Whether the `distinct_id` is stored on the Mac rather than minted in memory.
    var usesStoredIdentity: Bool { self == .reach }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .anonymous: return String(localized: "Anonymous")
        case .reach: return String(localized: "Anonymous + reach")
        }
    }

    /// The one-line explanation shown under each option.
    var explanation: String {
        switch self {
        case .off:
            return String(localized: "Nothing is collected and nothing is sent.")
        case .anonymous:
            return String(localized: "Version, language and which features you use. No identifier, and nothing that could recognise this Mac again.")
        case .reach:
            return String(localized: "Adds a random identifier that is thrown away every month, so we can count how many people use Shepherd. Switching this off deletes it.")
        }
    }
}
