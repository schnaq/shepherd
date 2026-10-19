import Foundation

/// GitHub's suggested change: the commented lines inside a ```` ```suggestion ```` fence, which
/// the reviewer edits into what the lines should become and the author applies with one click.
///
/// Shared by the Mac's composer and the phone's inline-comment sheet (ADR 0044).
public enum SuggestionBlock {
    /// - Parameters:
    ///   - document: The head-side file, as the diff shows it.
    ///   - startLine: The first commented line, or `nil` for one line.
    ///   - line: The last commented line.
    /// - Returns: The block, or `nil` when the lines are not in the document.
    public static func make(document: String, startLine: Int?, line: Int) -> String? {
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        let start = startLine ?? line
        guard start >= 1, start <= line, line <= lines.count else { return nil }
        return "```suggestion\n" + lines[(start - 1)..<line].joined(separator: "\n") + "\n```"
    }
}
