import ShepherdCore
import SwiftUI

extension FileCategory {
    /// The localized label for this category, e.g. for the row that names a changed file's kind.
    ///
    /// `FileCategory`'s own English label (`ShepherdCore/Heuristics/FilePrioritizer.swift`) lives
    /// in ShepherdCore, which imports Foundation only, so it cannot call `String(localized:)`
    /// itself. That English label is what a model prompt reads as the first
    /// ``ShepherdCore/FilePriorityReason``; this is the app-side translation of the same words,
    /// keyed on that same English text so the two never drift apart silently.
    var localizedLabel: String { localizedLabel(bundle: .main) }

    /// The localized label, looked up in a given bundle.
    /// - Parameter bundle: Where to look the catalog up. A test passes the compiled `de.lproj`.
    /// - Returns: The label, in the bundle's language.
    func localizedLabel(bundle: Bundle) -> String {
        switch self {
        case .source: return String(localized: "Source file", bundle: bundle)
        case .tests: return String(localized: "Test file", bundle: bundle)
        case .config: return String(localized: "Configuration", bundle: bundle)
        case .docs: return String(localized: "Documentation", bundle: bundle)
        case .generated: return String(localized: "Generated or vendored file", bundle: bundle)
        }
    }
}

extension FileChangeStatus {
    /// The change kind in a file header's words — "new", "modified", "deleted", "renamed" — shared
    /// by the Mac's file list and the phone's files screen (ADR 0044), so the catalog's German
    /// rows apply to both.
    var localizedLabel: String {
        switch self {
        case .added: return String(localized: "new")
        case .modified: return String(localized: "modified")
        case .removed: return String(localized: "deleted")
        case .renamed: return String(localized: "renamed")
        }
    }

    /// The change kind's colour: green for new, the accent for modified, red for deleted.
    var color: Color {
        switch self {
        case .added: return Theme.success
        case .modified: return Theme.accentText
        case .removed: return Theme.failure
        case .renamed: return Theme.pending
        }
    }
}
