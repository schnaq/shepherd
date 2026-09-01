import Foundation
import Observation
import ShepherdSync

/// The parked reviews waiting to be shown to the user, one alert at a time.
///
/// A conflict is the one outcome the drain cannot resolve on its own: the pull request moved on,
/// so the review is kept and never sent (ADR 0006). That makes it the one outcome the user *must*
/// see. A single slot was enough while conflicts arrived one at a time, but one bulk-triage drain
/// can park several reviews in a row (ADR 0015), and each arriving conflict overwrote the last —
/// so all but one disappeared without ever being shown.
///
/// This keeps them in arrival order and hands them to the alert one by one. With exactly one
/// conflict the behaviour is what it always was: it becomes ``current``, the alert shows it, and
/// dismissing it clears it.
@MainActor
@Observable
final class DraftConflictQueue {
    /// The conflict the alert is showing, if any.
    private(set) var current: DraftConflict?
    /// The conflicts behind it, in arrival order.
    private(set) var waiting: [DraftConflict] = []

    /// How long the next conflict waits after the one on screen is dismissed.
    ///
    /// A SwiftUI alert is presented when its `isPresented` binding goes from `false` to `true`.
    /// Swapping the next conflict straight into ``current`` would keep the binding `true`
    /// throughout, and the alert on screen would simply be dismissed with everything behind it
    /// unshown — so the next one is raised a beat later, once the dismissal has actually run.
    private let gap: Duration

    /// Creates an empty queue.
    /// - Parameter gap: The pause between one alert being dismissed and the next being raised.
    ///   Tests pass `.zero`.
    init(gap: Duration = .milliseconds(350)) {
        self.gap = gap
    }

    /// How many conflicts are unresolved, including the one on screen.
    var count: Int { (current == nil ? 0 : 1) + waiting.count }

    /// Adds a conflict, or shows it immediately when nothing else is up.
    ///
    /// A second conflict for the same pull request is dropped: the two rows of an
    /// "approve & merge" park together, and the alert says the same thing about both.
    /// - Parameter conflict: The parked review.
    func raise(_ conflict: DraftConflict) {
        guard current?.prID != conflict.prID,
              !waiting.contains(where: { $0.prID == conflict.prID })
        else { return }
        guard current != nil else {
            current = conflict
            return
        }
        waiting.append(conflict)
    }

    /// Dismisses the conflict on screen and lets the next one through.
    func dismiss() {
        current = nil
        guard !waiting.isEmpty else { return }
        let gap = self.gap
        Task { [weak self] in
            try? await Task.sleep(for: gap)
            self?.raiseNextIfIdle()
        }
    }

    /// Clears everything — the account signing out takes its conflicts with it.
    func removeAll() {
        current = nil
        waiting = []
    }

    /// Moves the next waiting conflict onto the alert, unless one is already there.
    private func raiseNextIfIdle() {
        guard current == nil, !waiting.isEmpty else { return }
        current = waiting.removeFirst()
    }
}
