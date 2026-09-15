import SwiftUI

extension View {
    /// Lets a scroll view take the height of the split-view column it sits in, rather than the
    /// height of its own content.
    ///
    /// The bug it exists for: a scroll view's *ideal* height is the height of everything inside
    /// it, and a `NavigationSplitView` column hands that ideal up as the window's minimum content
    /// height. Every row the inbox rail grew — LANES, RISK, AGENTS, one per repository — made that
    /// minimum taller, and once it passed the window's own height the split view overflowed and
    /// centred itself: the first rail rows ended up behind the traffic lights and the list header
    /// collided with the window title. It came and went with the facets, so it looked like the
    /// rail "sometimes" slid up.
    ///
    /// `idealHeight: 0` says what was meant all along — this view has no preferred height, it
    /// takes what the column gives it and scrolls the rest.
    ///
    /// One modifier rather than the same three lines per call site, because the next column added
    /// to a split view has to have it too and a convention nobody can see is a convention that
    /// gets missed. The two rails carry it because they are where the bug was seen; the list and
    /// fleet columns have the same shape and are candidates for the same treatment the next time
    /// one of them is worked on.
    func columnHeight() -> some View {
        frame(idealHeight: 0, maxHeight: .infinity)
    }
}
