import ShepherdSync
import SwiftUI

/// The window's root: onboarding, or the signed-in app.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .overlay(alignment: .bottomTrailing) {
            ToastStackView(center: environment.toasts)
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch environment.phase {
        case .launching:
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "Opening your review inbox…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        case .signedOut:
            SignInView()
        case .signedIn(let session):
            SignedInRootView(session: session)
        }
    }
}

/// The signed-in window: inbox or review screen, plus the ⌘K palette.
struct SignedInRootView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The active session.
    let session: SignedInSession

    var body: some View {
        ZStack {
            switch environment.route {
            case .inbox:
                InboxScreen(session: session, settings: environment.settings)
            case .review(let prID):
                ReviewScreen(session: session, settings: environment.settings, prID: prID)
                    .id(prID)
            }

            if environment.isCommandPaletteVisible {
                CommandPaletteView(session: session)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: environment.isCommandPaletteVisible)
        // The delegation sheet lives here rather than on a screen: a run started from the
        // review screen must survive going back to the inbox (ADR 0011).
        .sheet(
            isPresented: Binding(
                get: { environment.delegation.presented != nil },
                set: { if !$0 { environment.delegation.dismiss() } }
            )
        ) {
            if let model = environment.delegation.presented {
                DelegationSheet(model: model)
                    .environment(environment)
            }
        }
        // One alert, one parked review: dismissing it lets the next conflict of the same drain
        // through instead of losing it (ADR 0006, ADR 0015).
        .alert(
            String(localized: "This review was not sent"),
            isPresented: Binding(
                get: { environment.draftConflicts.current != nil },
                set: { if !$0 { environment.draftConflicts.dismiss() } }
            ),
            presenting: environment.draftConflicts.current
        ) { conflict in
            Button(String(localized: "Re-review")) {
                environment.draftConflicts.dismiss()
                environment.openReview(prID: conflict.prID)
            }
            Button(String(localized: "Later"), role: .cancel) {
                environment.draftConflicts.dismiss()
            }
        } message: { conflict in
            Text(conflictMessage(for: conflict))
        }
    }

    /// What the conflict alert says, plus how many more are behind it.
    private func conflictMessage(for conflict: DraftConflict) -> String {
        let explanation = String(
            localized: """
                \(conflict.repo.fullName)#\(conflict.number) got new commits after you wrote \
                your review, so your inline comments would land on the wrong lines. \
                Your draft is kept — open the pull request again to check it against the \
                new commit.
                """
        )
        let waiting = environment.draftConflicts.waiting.count
        guard waiting > 0 else { return explanation }
        let more = waiting == 1
            ? String(localized: "One more review was parked in the same run; it comes up next.")
            : String(localized: "\(waiting) more reviews were parked in the same run; they come up next.")
        return explanation + "\n\n" + more
    }
}
