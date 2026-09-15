import ShepherdCore
import SwiftUI

extension FileCategory {
    /// The localized label for this category, e.g. for the row that names a changed file's kind.
    ///
    /// `FileCategory`'s own English label (`ShepherdCore/Heuristics/FilePrioritizer.swift`) lives
    /// in ShepherdCore, which imports Foundation only, so it cannot call `String(localized:)`
    /// itself — and it is not just display text there: `FilePrioritizer` also always puts that
    /// same English string first in a file's list of review reasons, so the two jobs, "a stable
    /// English word `FilePrioritizer` builds a sentence around" and "a word a reviewer reads on
    /// screen", cannot share one property once one of them has to be German. This is the app-side
    /// translation, keyed on that same English text so the two never drift apart silently.
    var localizedLabel: String {
        switch self {
        case .source: return String(localized: "Source file")
        case .tests: return String(localized: "Test file")
        case .config: return String(localized: "Configuration")
        case .docs: return String(localized: "Documentation")
        case .generated: return String(localized: "Generated or vendored file")
        }
    }
}
