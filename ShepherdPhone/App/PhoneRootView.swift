import GitHubKit
import Observation
import ShepherdCore
import SwiftUI

/// A place on the signed-in navigation stack (ADR 0044).
///
/// Values rather than views, so a route can be pushed from anywhere that holds the router — a
/// row, a toast's action, later a notification — and the stack can be reset to the inbox in one
/// assignment.
enum PhoneRoute: Hashable {
    /// One pull request, by node id.
    case pullRequest(id: String)
}

/// The navigation path of the signed-in screens, owned by ``PhoneEnvironment``.
@MainActor
@Observable
final class PhoneRouter {
    /// What is pushed on top of the inbox, bottom first.
    var path: [PhoneRoute] = []
}

/// The phone's one window: launch, sign-in or the signed-in stack, by ``PhoneEnvironment/phase``.
///
/// The screens behind it are placeholders that prove the wiring — a real session, the Mac's
/// `InboxModel` reading the real database — until the phone's own sign-in, inbox and review
/// screens replace them (ADR 0044, phase 1). Their copy is deliberately made of keys the String
/// Catalog already carries, so Scripts/check-localization.py stays green before the phone's own
/// German rows exist.
struct PhoneRootView: View {
    @Environment(PhoneEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                PhoneSignInPlaceholder()
            case .signedIn(let session):
                PhoneInboxPlaceholder(model: InboxModel(session: session, settings: environment.settings))
                    // A new session is a new inbox: without the id SwiftUI would keep the first
                    // model's `@State` across a sign-out and sign-in.
                    .id(ObjectIdentifier(session))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            ToastStackView(center: environment.toasts)
        }
    }
}

/// Stand-in for the phone's sign-in screen: the device flow and nothing else.
private struct PhoneSignInPlaceholder: View {
    @Environment(PhoneEnvironment.self) private var environment
    @State private var model = SignInModel()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "hare")
                .font(.largeTitle)
                .foregroundStyle(Theme.agent)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(String(localized: "Shepherd"))
                    .font(Theme.type(.largeTitle, weight: .bold))
                    .foregroundStyle(Theme.textStrong)
                Text(String(localized: "One review inbox for everything your agents open."))
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let grant = model.grant {
                VStack(spacing: 6) {
                    Text(String(localized: "ENTER THIS CODE ON GITHUB"))
                        .font(Theme.type(.caption, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(verbatim: grant.userCode)
                        .font(Theme.type(.title, weight: .semibold).monospaced())
                        .foregroundStyle(Theme.textStrong)
                        .textSelection(.enabled)
                }
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.failure)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                model.startDeviceFlow(environment: environment)
            } label: {
                Text(String(localized: "Sign in with GitHub"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!model.isDeviceFlowConfigured || model.isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

/// Stand-in for the phone's inbox: every stored pull request, newest activity first, on the
/// Mac's `InboxModel`.
private struct PhoneInboxPlaceholder: View {
    @Environment(PhoneEnvironment.self) private var environment
    @State var model: InboxModel

    var body: some View {
        @Bindable var router = environment.router
        NavigationStack(path: $router.path) {
            PhoneInboxScreen(model: model, onOpenSettings: {})
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .pullRequest(let id):
                        let title = model.allRows.first { $0.id == id }?.title ?? ""
                        ContentUnavailableView(title, systemImage: "arrow.triangle.pull")
                    }
                }
        }
        .task { model.startObserving() }
    }
}
