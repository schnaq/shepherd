import AppKit
import SwiftUI

extension View {
    /// A click that acts at once, and a double-click that adds a second action on top of it.
    ///
    /// The list idiom — one click selects, two open — without SwiftUI's own way of saying it.
    /// `.onTapGesture(count: 2)` beside `.onTapGesture` makes the single tap *wait* for the
    /// double-click interval to run out before it fires, because until then the first click might
    /// still become half of a double one. That wait (up to half a second, the system setting) was
    /// the whole of "I click a pull request and nothing happens" in the inbox (2026-09-25).
    ///
    /// So there is one tap gesture here, and it never waits: every click runs `onClick`, and the
    /// click AppKit reports as the second of a pair runs `onDoubleClick` after it. The first click
    /// of a double-click has already selected by the time the second one arrives, which is the
    /// Finder's behaviour and the one a list is expected to have.
    ///
    /// Modified clicks are not this modifier's business. A ⌘- or ⇧-click gesture attached
    /// *outside* it with `highPriorityGesture` still wins over it (ADR 0015).
    /// - Parameters:
    ///   - onClick: What every click does — normally, select.
    ///   - onDoubleClick: What the second click of a double-click does as well — normally, open.
    func onClick(_ onClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) -> some View {
        onTapGesture {
            onClick()
            if PointerClick.isSecondOfDoubleClick {
                onDoubleClick()
            }
        }
    }
}

/// What the event being handled right now says about the mouse.
enum PointerClick {
    /// Whether the event AppKit is dispatching is the second click of a double-click.
    ///
    /// Only a mouse event is asked for its click count: `NSEvent.clickCount` raises on a key or
    /// accessibility event, and VoiceOver's press and a keyboard activation reach a tap gesture
    /// with exactly those. Such an activation is a single click, which is the answer they get.
    ///
    /// `== 2` rather than `>= 2`, so a triple-click does not open the same thing twice.
    @MainActor
    static var isSecondOfDoubleClick: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            return event.clickCount == 2
        default:
            return false
        }
    }
}
