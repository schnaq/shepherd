import Foundation

/// Which kind of thing the inbox is showing (ADR 0032).
///
/// A picker at the top of the rail, not a second top-level route, and that is the decision the
/// type records. `j`/`k`, ⌘K, the focus session and the menu-bar item all already address "the
/// model that owns the selection" rather than a screen, so a second route would duplicate the
/// whole chrome — toolbar, digest card, Settings sheet, palette overlay — for one segmented
/// control's worth of difference.
enum ContentKind: String, CaseIterable, Identifiable, Sendable {
    /// The review inbox: `pull_requests`, `InboxModel`.
    case pullRequests
    /// The issues inbox: `issues`, ``IssueInboxModel``.
    case issues

    var id: String { rawValue }

    /// The segmented control's label.
    var title: String {
        switch self {
        case .pullRequests: return String(localized: "Pull requests")
        case .issues: return String(localized: "Issues")
        }
    }

    /// The SF Symbol shown beside the label.
    var systemImage: String {
        switch self {
        case .pullRequests: return "arrow.triangle.pull"
        case .issues: return "smallcircle.circle"
        }
    }
}
