import Foundation
import SwiftUI

/// Compact relative timestamps, matching the inbox mockup (`12 m`, `2 h`, `1 d`).
///
/// `RelativeDateTimeFormatter` produces "12 minutes ago", which is too wide for a 34-point
/// column, so the short form is computed here and the long form is offered as help text.
enum RelativeDate {
    /// The compact form used in list rows.
    /// - Parameters:
    ///   - date: The moment to describe.
    ///   - reference: "Now". Injectable for tests and previews.
    static func short(_ date: Date, relativeTo reference: Date = Date()) -> String {
        let seconds = max(0, reference.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return String(localized: "now")
        case ..<3_600:
            return String(localized: "\(Int(seconds / 60)) m")
        case ..<86_400:
            return String(localized: "\(Int(seconds / 3_600)) h")
        case ..<(86_400 * 30):
            return String(localized: "\(Int(seconds / 86_400)) d")
        default:
            return String(localized: "\(Int(seconds / (86_400 * 30))) mo")
        }
    }

    /// The long form used in tooltips and the detail panel ("12 minutes ago").
    /// - Parameters:
    ///   - date: The moment to describe.
    ///   - reference: "Now".
    static func long(_ date: Date, relativeTo reference: Date = Date()) -> String {
        // Everything this form describes has already happened — a sync, a commit, an opened pull
        // request. Below a second the numeric formatter says "in 0 seconds", the future tense for
        // the past, which is exactly what the title bar showed beside a label reading "2 m"
        // (2026-09-09 live test). ``short(_:relativeTo:)`` above has the same kind of floor — a
        // whole minute of it, because it has one word to say it in.
        guard reference.timeIntervalSince(date) >= 1 else { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// A duration in the compact `1 m 42 s` form used by the checks card.
    /// - Parameter seconds: The duration.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return String(localized: "\(total) s") }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return String(localized: "\(minutes) m \(remainder) s") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) m")
    }
}

/// A label that re-renders as time passes, so "12 m" does not go stale while the app is open.
struct RelativeDateText: View {
    /// The moment being described.
    let date: Date
    /// Whether to use the long form.
    var style: Style = .short

    /// Which form to render.
    enum Style {
        /// `12 m`
        case short
        /// `12 minutes ago`
        case long
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(text(now: context.date))
                // Inside the timeline rather than beside it. Outside, the help text was built
                // once — when the view was first laid out — and never again, so the label went on
                // ticking to "2 m" next to a tooltip still frozen at the moment of the sync
                // (2026-09-09 live test). Both now read the same instant.
                .help(RelativeDate.long(date, relativeTo: context.date))
        }
    }

    private func text(now: Date) -> String {
        switch style {
        case .short: return RelativeDate.short(date, relativeTo: now)
        case .long: return RelativeDate.long(date, relativeTo: now)
        }
    }
}
