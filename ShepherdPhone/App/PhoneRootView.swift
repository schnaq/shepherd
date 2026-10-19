import GitHubKit
import Observation
import ShepherdCore
import SwiftUI

/// A place on the signed-in navigation stack (ADR 0044).
///
/// Values rather than views, so a route can be pushed from anywhere that holds the router — a
/// row, a toast's action, later a notification — and the stack can be reset to the inbox in one
/// assignment. Routes *inside* a pull request (its files, one file's diff) are that screen's own
/// and registered there, so they share its ``ReviewModel``; only what can be reached from the
/// inbox belongs here.
enum PhoneRoute: Hashable {
    /// One pull request, by node id.
    case pullRequest(id: String)
}

/// The navigation path of the signed-in screens, and the review models of the pull requests on
/// it. Owned by ``PhoneEnvironment``.
///
/// The router rather than the screen owns each ``ReviewModel``, because a screen's lifetime is the
/// wrong one under a `NavigationStack`: `onDisappear` fires when the diff is pushed *on top of*
/// the pull request, and a model stopped there would be dead under the diff that is reading it.
/// What the Mac's `ReviewScreen` does in `.task` and `.onDisappear` — `start()` and `stop()` —
/// happens here instead, keyed on whether the pull request is on the path at all.
@MainActor
@Observable
final class PhoneRouter {
    /// What is pushed on top of the inbox, bottom first.
    ///
    /// Every change reconciles ``reviewModels``: a pull request that arrives gets a started model
    /// before its screen is built, one that leaves has its model stopped and dropped.
    var path: [PhoneRoute] = [] {
        didSet { reconcileReviewModels() }
    }

    /// The started model of every pull request on ``path``, by node id.
    private(set) var reviewModels: [String: ReviewModel] = [:]

    /// Builds a model for the open session; set by ``PhoneEnvironment`` when a session starts and
    /// cleared by ``reset()``, so no model is ever made against a session that has shut down.
    @ObservationIgnored var makeReviewModel: (@MainActor (String) -> ReviewModel)?

    /// The started model for a pull request on the path, or `nil` when there is no session.
    /// - Parameter id: The pull request's node id.
    func reviewModel(for id: String) -> ReviewModel? {
        reviewModels[id]
    }

    /// Back to the inbox with every model stopped, and no factory: sign-out.
    func reset() {
        makeReviewModel = nil
        path = []
    }

    private func reconcileReviewModels() {
        let onPath = Set(path.map { route in
            switch route {
            case .pullRequest(let id): id
            }
        })
        for (id, model) in reviewModels where !onPath.contains(id) {
            model.stop()
            reviewModels[id] = nil
        }
        guard let makeReviewModel else { return }
        for id in onPath where reviewModels[id] == nil {
            let model = makeReviewModel(id)
            model.start()
            reviewModels[id] = model
        }
    }
}

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
            // Replaced by U2's `PhoneInboxScreen(model: inbox)` at integration.
            PhoneInboxPlaceholder(model: inbox)
                .navigationDestination(for: PhoneRoute.self) { route in
                    switch route {
                    case .pullRequest(let id):
                        if let model = router.reviewModel(for: id) {
                            // Replaced by U3's `PhonePullRequestScreen(model: model)`.
                            PhonePullRequestPlaceholder(model: model)
                        } else {
                            ContentUnavailableView(
                                String(localized: "Pull request not available"),
                                systemImage: "arrow.triangle.pull"
                            )
                        }
                    }
                }
        }
        .task { inbox.startObserving() }
        // On the stack rather than on the inbox inside it, whose `onDisappear` fires on every
        // push: this one fires when the session's screens go — sign-out — as `InboxScreen` stops
        // its model on the Mac.
        .onDisappear { inbox.stopObserving() }
        .sheet(isPresented: $environment.isSettingsPresented) {
            PhoneSettingsView()
        }
        #if DEBUG
        // `-PhoneShowSettings YES` opens the sheet at launch, so the settings screen can be
        // screenshotted on a simulator nobody can tap.
        .onAppear {
            if UserDefaults.standard.bool(forKey: "PhoneShowSettings") {
                environment.isSettingsPresented = true
            }
        }
        #endif
    }
}

/// Stand-in for the phone's inbox until U2's screen lands: every stored pull request, newest
/// activity first, on the Mac's `InboxModel`, under the sync strip and with the settings button.
private struct PhoneInboxPlaceholder: View {
    let model: InboxModel

    var body: some View {
        List {
            PhoneSyncStrip()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(model.allRows.sorted { $0.updatedAt > $1.updatedAt }) { row in
                NavigationLink(value: PhoneRoute.pullRequest(id: row.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(row.repo.name) #\(row.number)")
                            .font(Theme.mono(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                        Text(row.title)
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(2)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "Inbox"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PhoneSettingsButton()
            }
        }
    }
}

/// Stand-in for the pull request screen until U3's lands, on the router's started model.
private struct PhonePullRequestPlaceholder: View {
    let model: ReviewModel

    var body: some View {
        ContentUnavailableView(
            model.summary?.title ?? "",
            systemImage: "arrow.triangle.pull"
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}
