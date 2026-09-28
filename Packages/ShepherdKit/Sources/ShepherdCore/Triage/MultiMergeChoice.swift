import Foundation

/// What the inbox's *Merge* button merges, given the ticked rows (ADR 0015, ADR 0041, ADR 0042).
///
/// With several rows ticked, a button that still merged only the row under the cursor would
/// ignore the one thing the user just said about what they want. So the ticks decide, and this
/// value is the decision — a pure one, so the rule for "is this a stack" is tested and not left
/// to a view.
public enum MultiMergeChoice: Sendable, Equatable {
    /// Nothing or one row is ticked: the button merges the selected row, as it always has.
    case single
    /// The ticks are exactly the bottom of one stack, positions `1…count` of the same repository
    /// and stack number. Merging `top` merges every one of them and nothing else, because GitHub
    /// merges a stacked pull request together with everything below it (ADR 0042).
    case stack(top: PullRequestSummary, count: Int)
    /// Any other set of two or more ticks: merged one after another by the merge series
    /// (ADR 0041), which decides on its own which of them are eligible.
    case several(count: Int)

    /// Whether the choice acts on the ticked rows rather than on the selected one.
    public var isMulti: Bool {
        if case .single = self { return false }
        return true
    }

    /// The choice for a set of ticked rows.
    ///
    /// A stack is recognised only when merging its top would merge *exactly* the ticked rows.
    /// A gap in the positions, or a slice that does not start at the bottom, would take along a
    /// pull request nobody ticked — so those become ``several(count:)``, where each one merges
    /// on its own.
    /// - Parameter marked: The ticked rows, in any order.
    /// - Returns: What the *Merge* button should do.
    public static func make(marked: [PullRequestSummary]) -> MultiMergeChoice {
        guard marked.count >= 2 else { return .single }
        guard
            let first = marked.first,
            let stack = first.stack,
            marked.allSatisfy({ $0.repo == first.repo && $0.stack?.number == stack.number })
        else {
            return .several(count: marked.count)
        }
        let byPosition = marked.sorted { ($0.stack?.position ?? 0) < ($1.stack?.position ?? 0) }
        let positions = byPosition.compactMap { $0.stack?.position }
        guard positions == Array(1...marked.count), let top = byPosition.last else {
            return .several(count: marked.count)
        }
        return .stack(top: top, count: marked.count)
    }
}
