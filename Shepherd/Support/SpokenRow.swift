import Foundation

/// Assembles the one sentence a list row is announced as.
///
/// SwiftUI's `.accessibilityElement(children: .combine)` turns a row of six sibling views into
/// one element and concatenates whatever labels those siblings carry — and an
/// `.accessibilityLabel` applied afterwards **replaces** that, rather than adding to it. Every
/// list in the app took the second step, so a row that showed the CI state, the author, the
/// track record, the triage verdict, the diff counts and the age was announced as
/// `owner/repo #12: title` and nothing else. The visual row said six things; the spoken row said
/// one.
///
/// The fix is to build the label from the same values the row draws, which is what this exists
/// for: the row hands over the parts it has, in reading order, and this decides how they are
/// punctuated so that five lists cannot punctuate them five ways. A screen reader pauses at a
/// full stop, which is what makes the parts hearable as separate facts rather than as one run-on
/// phrase.
///
/// Parts that are `nil` or blank are dropped rather than announced as a gap, because most of
/// them are conditional on screen too — a row with no triage chip should not say "no triage".
enum SpokenRow {
    /// Joins the parts of a row's spoken label.
    /// - Parameter parts: The facts, in the order the row shows them. `nil` and blank entries are
    ///   left out.
    /// - Returns: One sentence, or an empty string when there was nothing to say.
    static func sentence(_ parts: [String?]) -> String {
        let kept = parts
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            // A part that already ends in a full stop keeps it rather than getting a second one:
            // several of them are whole sentences from a component's tooltip.
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return kept.isEmpty ? "" : kept.joined(separator: ". ") + "."
    }
}
