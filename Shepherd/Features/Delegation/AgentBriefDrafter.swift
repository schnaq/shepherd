import Foundation
import ShepherdCore

/// How the delegation sheet's ✨ button reaches the intelligence layer (plan §3.E).
///
/// One `Sendable` value with one closure in it, rather than the router plus a database handed to
/// ``DelegationModel``, for three reasons that are all the same reason:
///
/// - **An automatic delegation cannot have one.** ``DelegationCenter/startAutomatically(context:task:settings:toasts:onDidPush:onDidFinish:)``
///   has no parameter for it, so a rule-started run is *structurally* incapable of receiving a
///   drafted brief — ADR 0016's "an unattended rule keeps its fixed template" is expressed as a
///   missing argument rather than as a check somebody could invert later.
/// - **The sheet stays testable.** A test scripts the closure and drives the field without a
///   window, a key, a database or Apple Intelligence.
/// - **The delegation feature keeps knowing nothing about persistence.** The pull request is
///   fetched through the ``detail`` closure the app layer supplies, exactly the way the model
///   already takes its git and its CLI as seams.
///
/// It produces text for a field and nothing else. Run is still the reviewer's click.
struct AgentBriefDrafter: Sendable {
    /// Whether a tier could take the request right now (``IntelligenceRouter/canDraft``).
    ///
    /// Read before the click, so the button can be *absent* rather than present and failing —
    /// with no model configured, the sheet is exactly the sheet it was before this feature.
    let canDraft: Bool
    /// Starts one streamed brief for a delegation.
    let stream: @Sendable (DelegationContext) async -> IntelligenceStreamOutcome

    /// Creates a drafter.
    /// - Parameters:
    ///   - canDraft: Whether a tier could answer right now.
    ///   - stream: Starts one streamed brief.
    init(
        canDraft: Bool,
        stream: @escaping @Sendable (DelegationContext) async -> IntelligenceStreamOutcome
    ) {
        self.canDraft = canDraft
        self.stream = stream
    }

    /// The live drafter: the router, the signed-in login, and a way to read the pull request.
    ///
    /// The digest is built here rather than inside the router because it is built *once*, at the
    /// on-device tier's budget (``AgentBriefRequest/digest(for:budget:)`` reserves the finding
    /// comments' share of it first). That is tier 2 first, made concrete: the brief a cloud rung
    /// is asked for is never larger than the one that would have stayed on this Mac.
    /// - Parameters:
    ///   - router: The tier ladder.
    ///   - viewerLogin: The signed-in user's login, when there is one — it decides which quoted
    ///     comments count as the reviewer's own (``AgentBriefRequest/onDeviceOnly``).
    ///   - detail: Reads a pull request out of the local database by node id. `nil` when it has
    ///     not been fetched yet.
    /// - Returns: The drafter the sheet uses.
    static func live(
        router: IntelligenceRouter,
        viewerLogin: String?,
        detail: @escaping @Sendable (String) async -> PullRequestDetail?
    ) -> AgentBriefDrafter {
        AgentBriefDrafter(canDraft: router.canDraft) { context in
            guard let pullRequest = await detail(context.prID) else {
                // The delegation can be started from a row the inbox has but whose detail has
                // never been fetched. A brief written from a title alone would be invention, so
                // this says what is missing instead.
                return .unavailable(
                    String(
                        localized: "Shepherd has not fetched this pull request yet, so there is nothing to draft a brief from."
                    )
                )
            }
            return await router.streamAgentBrief(
                for: context,
                digest: AgentBriefRequest.digest(
                    for: pullRequest,
                    budget: OnDeviceProvider.budget
                ),
                viewerLogin: viewerLogin
            )
        }
    }
}
