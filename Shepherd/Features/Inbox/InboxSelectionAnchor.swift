import ShepherdCore

/// Where the selected row stood when it was selected, so the list does not move it away from
/// under the reader while they are looking at it (2026-09-25).
///
/// Selecting a pull request loads its detail, and the fresh copy from GitHub is written back to
/// the database — a newer `updatedAt`, a checks rollup that has moved on. The observation hands
/// the inbox those rows, the sort puts the selected one where it now belongs, and the row the
/// reader just clicked slides up the list, usually to the top. Correct as an order and wrong as
/// an interface: "it annoys me that the selected PR then gets sorted up."
///
/// So the selected row keeps the section and the position it had when it was selected, for as
/// long as it stays selected. Everything else is sorted as before, around it. The anchor is
/// released by moving the selection (the next row gets an anchor of its own), by the row leaving
/// the list, and by any change of the rail, the grouping or the sort — a choice the reader made
/// themselves, whose result they expect to see in full.
///
/// A pure value, for ``InboxRailSelection``'s reason: `InboxModel` cannot be built in a test, and
/// this is the part of it worth asserting.
struct InboxSelectionAnchor: Equatable {
    /// What the list's order depended on when the anchor was taken. An anchor applies only while
    /// every part of this is unchanged.
    struct Context: Equatable {
        /// The rail — smart view and facets — with the cursor left out.
        var rail: InboxModel.RailState
        /// The grouping.
        var groupBy: InboxFacet
        /// The sort.
        var sortOrder: InboxSortOrder
    }

    /// The selected pull request's node id.
    let id: String
    /// The section it was in.
    let sectionID: String
    /// Its position inside that section.
    let index: Int
    /// What the order depended on at the time.
    let context: Context

    /// Records where a row stands in the list as it is shown.
    /// - Parameters:
    ///   - id: The row being selected.
    ///   - sections: The sections as they are on screen — including any anchor still in force,
    ///     because the position to keep is the one the reader clicked on.
    ///   - context: What the order depends on right now.
    /// - Returns: The anchor, or `nil` when the row is not in the list.
    static func capture(
        id: String,
        in sections: [InboxSection],
        context: Context
    ) -> InboxSelectionAnchor? {
        for section in sections {
            if let index = section.items.firstIndex(where: { $0.id == id }) {
                return InboxSelectionAnchor(id: id, sectionID: section.id, index: index, context: context)
            }
        }
        return nil
    }

    /// Puts the anchored row back where it was, and leaves every other row where the sort put it.
    ///
    /// The sections come back unchanged when the anchor no longer applies: the order's context
    /// moved, the row is not in the list any more, or the section it was in has gone (its last
    /// other row left, and a section conjured back for one row would be a header that is not true
    /// of anything else). A section the row's move leaves empty is dropped.
    /// - Parameters:
    ///   - sections: The sections as grouped and sorted.
    ///   - context: What the order depends on right now.
    /// - Returns: The sections to show.
    func apply(to sections: [InboxSection], context: Context) -> [InboxSection] {
        guard context == self.context,
              let targetSection = sections.firstIndex(where: { $0.id == sectionID }),
              let currentSection = sections.firstIndex(where: { $0.items.contains { $0.id == id } }),
              let row = sections[currentSection].items.first(where: { $0.id == id })
        else { return sections }

        var result = sections
        let removed = sections[currentSection].items.filter { $0.id != id }
        result[currentSection] = sections[currentSection].replacingItems(removed)

        var target = result[targetSection].items
        target.insert(row, at: min(index, target.count))
        result[targetSection] = result[targetSection].replacingItems(target)

        return result.filter { !$0.items.isEmpty }
    }
}

extension InboxSection {
    /// The same section with other rows.
    /// - Parameter items: The rows it should hold.
    /// - Returns: A copy of this section's header with `items` under it.
    func replacingItems(_ items: [PullRequestSummary]) -> InboxSection {
        InboxSection(id: id, title: title, kind: kind, facet: facet, items: items)
    }
}
