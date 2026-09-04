import AppKit
import ShepherdCore
import SwiftUI

/// Which appearance the user picked in Settings.
enum AppearanceSetting: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Follow the system.
    case system
    /// Always light.
    case light
    /// Always dark.
    case dark

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    /// The AppKit appearance to force, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// The SwiftUI color scheme, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension NSColor {
    /// Creates an opaque sRGB color from a `0xRRGGBB` literal.
    /// - Parameter rgbHex: The packed colour value.
    convenience init(rgbHex: UInt32) {
        let red = Double((rgbHex >> 16) & 0xFF) / 255
        let green = Double((rgbHex >> 8) & 0xFF) / 255
        let blue = Double(rgbHex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension Color {
    /// A colour that resolves differently in light and dark appearance.
    ///
    /// Shepherd ships both themes from day one (see `docs/ARCHITECTURE.md`, "UI conventions"),
    /// so every colour in the app is defined as a pair rather than a literal.
    /// - Parameters:
    ///   - dark: The `0xRRGGBB` value used in dark appearance.
    ///   - light: The `0xRRGGBB` value used in light appearance.
    static func shepherd(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return NSColor(rgbHex: match == .darkAqua ? dark : light)
        })
    }
}

/// The semantic colour tokens of the Shepherd design language.
///
/// Values come straight from the approved mockups: dark `#101116`/`#14161d`/`#1a1d26`, light
/// `#f7f8fa`/`#ffffff`/`#f6f7fa`. Views never use raw hex.
enum Theme {
    // MARK: - Surfaces

    /// The window background behind the centre list.
    static var background: Color { .shepherd(dark: 0x101116, light: 0xF7F8FA) }
    /// Rails, headers and the detail panel.
    static var panel: Color { .shepherd(dark: 0x14161D, light: 0xFFFFFF) }
    /// Cards inside the detail panel.
    static var raised: Color { .shepherd(dark: 0x1A1D26, light: 0xF6F7FA) }
    /// The floating command palette.
    static var overlay: Color { .shepherd(dark: 0x16181F, light: 0xFFFFFF) }
    /// Secondary button and segmented-control fill.
    static var control: Color { .shepherd(dark: 0x232733, light: 0xEEF0F4) }

    // MARK: - Lines

    /// The structural border between panes.
    static var border: Color { .shepherd(dark: 0x262A35, light: 0xE3E6EC) }
    /// A quieter line used between list rows.
    static var hairline: Color { .shepherd(dark: 0x191C24, light: 0xEEF0F4) }
    /// The border of buttons and key caps.
    static var controlBorder: Color { .shepherd(dark: 0x2C3140, light: 0xD7DCE4) }

    // MARK: - Text

    /// Emphasised text: titles, selected rows.
    static var textStrong: Color { .shepherd(dark: 0xECEEF4, light: 0x14181F) }
    /// Default body text.
    static var text: Color { .shepherd(dark: 0xE8EAF0, light: 0x1B1F27) }
    /// Secondary text: unselected rows, labels.
    static var textSecondary: Color { .shepherd(dark: 0x9AA1B2, light: 0x5B6472) }
    /// Tertiary text: counts, timestamps, section captions.
    static var textMuted: Color { .shepherd(dark: 0x636B7E, light: 0x8A93A5) }
    /// Text on a filled accent/success button.
    static var textOnFilled: Color { .shepherd(dark: 0x0C1F16, light: 0xFFFFFF) }

    // MARK: - Accents

    /// The azure accent: selection, links, primary affordances.
    static var accent: Color { .shepherd(dark: 0x6E9DF2, light: 0x3B74D9) }
    /// A lighter accent used for text on accent-tinted backgrounds.
    static var accentText: Color { .shepherd(dark: 0x8FB3F5, light: 0x2C5CB3) }
    /// The amber used for agent provenance (ADR 0008).
    static var agent: Color { .shepherd(dark: 0xD9A13C, light: 0xA86F13) }
    /// CI green.
    static var success: Color { .shepherd(dark: 0x4CC38A, light: 0x1A9E63) }
    /// CI red.
    static var failure: Color { .shepherd(dark: 0xF2555A, light: 0xD64550) }
    /// CI yellow (running/queued).
    static var pending: Color { .shepherd(dark: 0xF0B429, light: 0xC98A0A) }
    /// The violet used for review-priority dots.
    static var priority: Color { .shepherd(dark: 0xB18CF5, light: 0x7C5CD6) }
    /// A second violet for the lower priority tier.
    static var prioritySecondary: Color { .shepherd(dark: 0x9D8CF0, light: 0x6D5BD9) }
    /// A neutral dot for de-prioritised files.
    static var priorityMuted: Color { .shepherd(dark: 0x3A4152, light: 0xD7DCE4) }

    // MARK: - Metrics

    /// The monospaced font used for repo slugs, paths and diff counts, at a fixed point size.
    ///
    /// Kept for the surfaces that pin a row height around it; ``mono(_:weight:)`` below is the
    /// one that grows.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Type scale

    /// The app's text sizes, as *text styles* rather than point sizes — which is the whole of
    /// taking part in macOS's Larger Text setting.
    ///
    /// `Font.system(size:)` is a fixed measurement and ignores that setting entirely, so a
    /// low-vision user's system preference did nothing at all in Shepherd: worse than clipping,
    /// because the standard remedy silently had no effect (ADR 0033's fourth amendment). A text
    /// style is the same size by default and grows when the user asks it to.
    ///
    /// The mapping is deliberately the identity at the default size — on macOS `.body` is 13pt,
    /// `.callout` 12, `.subheadline` 11, `.footnote` 10, `.title3` 15, `.title` 22 — so adopting
    /// this changes nothing whatsoever until somebody turns the setting up. Sizes with no exact
    /// style behind them (8, 9, and the half points) deliberately stay fixed rather than being
    /// rounded onto one, because rounding would change the app at the default size, which is a
    /// visual decision and not a mechanical one.
    ///
    /// One function rather than a property per style, so the weighted form reads like the plain
    /// one and so a later decision — retune the scale, cap how far it grows — is made here
    /// instead of at several hundred call sites. `.headline` is deliberately absent: it carries
    /// a semibold weight of its own, which would silently double up on a call site that already
    /// asks for one.
    static func type(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }

    /// ``type(_:weight:)``'s monospaced sibling, for the same reason.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// Tint used behind a chip of a given colour.
    /// - Parameter color: The chip's foreground colour.
    static func chipBackground(_ color: Color) -> Color { color.opacity(0.13) }

    /// The selection tint used for list rows.
    static var selection: Color { accent.opacity(0.11) }
}

/// Colours for the agent facet, so "Claude Code" is the same amber everywhere.
enum AgentPalette {
    private static let known: [String: (dark: UInt32, light: UInt32)] = [
        "claude-code": (0xD9A13C, 0xA86F13),
        "github-copilot": (0x7BB8F0, 0x2F7FD1),
        "openai-codex": (0x58C2A9, 0x17806E),
        "devin": (0x9D8CF0, 0x6D5BD9),
        "cursor": (0x8B74D9, 0x6D5BD9),
        "dependabot": (0x58C2A9, 0x1D9A85),
        "renovate": (0x7BB8F0, 0x2F7FD1),
    ]

    private static let fallbacks: [(dark: UInt32, light: UInt32)] = [
        (0xD9A13C, 0xA86F13),
        (0x7BB8F0, 0x2F7FD1),
        (0x9D8CF0, 0x6D5BD9),
        (0x58C2A9, 0x1D9A85),
        (0xB18CF5, 0x7C5CD6),
    ]

    /// The colour for an agent identity, stable across launches.
    /// - Parameter id: The registry id, e.g. `"claude-code"`.
    static func color(forAgentID id: String) -> Color {
        if let pair = known[id] {
            return .shepherd(dark: pair.dark, light: pair.light)
        }
        // A deterministic, launch-stable fallback: sum of the id's UTF-8 bytes.
        let bucket = id.utf8.reduce(0) { ($0 + Int($1)) % fallbacks.count }
        let pair = fallbacks[bucket]
        return .shepherd(dark: pair.dark, light: pair.light)
    }

    /// The colour for an author's provenance.
    /// - Parameter kind: The detected provenance.
    static func color(for kind: ActorKind) -> Color {
        switch kind {
        case .agent(let identity): return color(forAgentID: identity.id)
        case .bot: return Theme.textSecondary
        case .human: return Theme.accent
        }
    }
}
