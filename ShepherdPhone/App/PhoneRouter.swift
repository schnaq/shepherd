import Observation
import ShepherdCore

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
