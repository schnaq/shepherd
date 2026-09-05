import Foundation

/// Which diff view renders a pull request's changes: the Monaco `WKWebView`, or the native
/// SwiftUI list built for keyboard and VoiceOver navigation.
///
/// This is three states rather than a toggle on purpose. `automatic` does not mean "pick one and
/// stick with it" — it means "use the native list while VoiceOver is running, and Monaco
/// otherwise," a rule that only makes sense as a runtime condition, not a fixed setting. A boolean
/// cannot say that. And a screen-reader user who actually prefers Monaco — because they know its
/// shortcuts, or because the native list is still catching up — needs a way to say so explicitly;
/// `automatic` is a sensible default, not a lock that overrides their own choice.
enum DiffRenderer: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The native list when VoiceOver is running, Monaco otherwise.
    case automatic
    /// Always Monaco.
    case web
    /// Always the native, walkable list.
    case native

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .web: return String(localized: "Rich viewer")
        case .native: return String(localized: "Line list")
        }
    }
}
