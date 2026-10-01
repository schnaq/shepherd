import ShepherdCore
import SwiftUI

extension View {
    /// Asks once before closing a pull request, then queues the close (ADR 0006).
    ///
    /// One dialog for every way in — the inbox panel's *Close…*, the row's context menu and ⌘K
    /// all set the same target — so the question is worded once. A confirmation rather than the
    /// undo toast, because the outbox may have sent the close before an undo could take it back;
    /// it is not the merge sheet's weight either, because a closed pull request can be reopened.
    /// Closing *with* a reason stays in the comment sheet.
    /// - Parameters:
    ///   - target: The pull request to ask about, or `nil` while no dialog is up.
    ///   - actions: The outbox-backed write actions.
    func closePullRequestConfirmation(
        _ target: Binding<PullRequestSummary?>,
        actions: PullRequestActions
    ) -> some View {
        alert(
            target.wrappedValue.map { String(localized: "Close \($0.slug)?") } ?? "",
            isPresented: Binding(
                get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } }
            ),
            presenting: target.wrappedValue
        ) { summary in
            Button(String(localized: "Close pull request"), role: .destructive) {
                Task { await actions.close(summary) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "Nothing is merged. It can be reopened on GitHub."))
        }
    }
}
