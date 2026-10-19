import GitHubKit
import ShepherdCore
import SwiftUI

/// The phone's one window: launch, sign-in or the signed-in stack, by ``PhoneEnvironment/phase``.
struct PhoneRootView: View {
    @Environment(PhoneEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                PhoneSignInView()
            case .signedIn(let session):
                PhoneSignedInView(session: session, settings: environment.settings)
                    // A new session is a new inbox: without the id SwiftUI would keep the first
                    // model's `@State` across a sign-out and sign-in.
                    .id(ObjectIdentifier(session))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        // The app's accent for every system control, sheets included — once here rather than
        // per button, so nothing falls back to the system blue.
        .tint(Theme.accent)
        .overlay(alignment: .bottom) {
            ToastStackView(center: environment.toasts)
        }
        .sensoryFeedback(.success, trigger: environment.signInCount)
    }
}

/// The signed-in stack: the inbox at the root, ``PhoneRoute`` destinations above it, and the
/// settings sheet.
///
/// The inbox's ``InboxModel`` lives here, as `InboxScreen` holds it on the Mac, so it outlives
/// every push and pop of the stack above it.
private struct PhoneSignedInView: View {
    @Environment(PhoneEnvironment.self) private var environment
    let session: SignedInSession
    @State private var inbox: InboxModel

    init(session: SignedInSession, settings: AppSettings) {
        self.session = session
        _inbox = State(initialValue: InboxModel(session: session, settings: settings))
    }

    var body: some View {
        @Bindable var environment = environment
        @Bindable var router = environment.router
        NavigationStack(path: $router.path) {
            PhoneInboxScreen(model: inbox, onOpenSettings: { environment.isSettingsPresented = true })
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .pullRequest(let id):
                        if let model = router.reviewModel(for: id) {
                            PhonePullRequestScreen(model: model)
                        } else {
                            ContentUnavailableView(
                                String(localized: "Pull request not available"),
                                systemImage: "arrow.triangle.pull"
                            )
                        }
                    }
                }
        }
        // On the stack rather than on the inbox inside it, whose `onDisappear` fires on every
        // push: this one fires when the session's screens go — sign-out — as `InboxScreen` stops
        // its model on the Mac. The inbox screen starts the model itself.
        .onDisappear { inbox.stopObserving() }
        .sheet(isPresented: $environment.isSettingsPresented) {
            PhoneSettingsView()
        }
    }
}
