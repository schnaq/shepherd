import Foundation
import ShepherdCore

/// A non-secret snapshot of the intelligence settings, plus the key read from the Keychain.
///
/// A value type so the router can be handed to background work without touching
/// `@MainActor` state; it is rebuilt whenever Settings change.
struct IntelligenceConfiguration: Sendable, Hashable {
    /// Which tiers are on.
    var mode: IntelligenceMode = .off
    /// Which cloud shape tier 3 uses.
    var cloudKind: CloudProviderKind = .anthropic
    /// The Anthropic model id.
    var anthropicModel: String = ClaudeProvider.defaultModelID
    /// The OpenAI-compatible base URL.
    var openAIBaseURL: String = ""
    /// The OpenAI-compatible model name.
    var openAIModel: String = ""
    /// ISO 3166-1 alpha-2 countries the OpenAI-compatible endpoint may serve a request from.
    ///
    /// The user's optional sovereignty policy (plan §3.K), empty by default and empty for every
    /// endpoint that does not understand it. It is part of the *request body* rather than a
    /// per-endpoint setting with behaviour behind it, and it is only sent when set — see
    /// ``OpenAICompatibleProvider/sovereigntyCountries``.
    var openAISovereigntyCountries: [String] = []
    /// Whether the OpenAI-compatible endpoint must pick a zero-retention operator.
    var openAIZeroRetention: Bool = false
    /// The API key for whichever cloud provider is selected.
    var cloudAPIKey: String = ""

    /// Everything off — the state the app must remain fully usable in.
    static let disabled = IntelligenceConfiguration()
}

/// A produced hint together with the tier that produced it.
struct IntelligenceOutput<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Which tier answered.
    var kind: IntelligenceKind
    /// The answer.
    var value: Value
    /// Who actually ran the model, when the endpoint volunteered it (plan §3.K).
    ///
    /// Almost always `nil`: the on-device tier has no operator to name and a single-company API
    /// has already been named by ``IntelligenceKind/badge``. A gateway in front of several
    /// operators can fill it, and a caption that has one appends it — see ``ServedBy``.
    var servedBy: String? = nil
}

/// What asking a tier produced.
enum IntelligenceOutcome<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Intelligence is switched off; no card is shown at all.
    case disabled
    /// Nothing could answer, with a user-readable reason.
    case unavailable(String)
    /// Every configured tier failed, with the last error's description.
    case failed(String)
    /// An answer.
    case value(IntelligenceOutput<Value>)

    /// The answer, when there is one.
    var output: IntelligenceOutput<Value>? {
        if case .value(let output) = self { return output }
        return nil
    }

    /// A message explaining why there is no answer, when there is none.
    var message: String? {
        switch self {
        case .disabled, .value: return nil
        case .unavailable(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

/// A stream of cumulative drafts together with the tier producing them.
///
/// The pair is the point (plan §0.2). A streamed draft has to be *labelled* — "Drafted
/// on-device", "Drafted by Anthropic" — and a caption that appeared after the text would be a
/// caption nobody reads, so the tier is settled before the reviewer sees a character. That is
/// also why ``IntelligenceRouter/streamReviewSummaryDraft(for:pendingComments:)`` is `async`
/// although it returns a stream: it waits for the tier's *first* element before answering, which
/// is exactly what lets the cloud → on-device ladder still step down. A cloud tier that is going
/// to fail almost always fails on the connection, before any text exists; once the first token is
/// out, the tier is committed and a failure is a failure.
struct IntelligenceStream: Sendable {
    /// Which tier is producing the text.
    var kind: IntelligenceKind
    /// Who actually ran the model, when the endpoint volunteered it (plan §3.K).
    ///
    /// Settled at the same moment ``kind`` is, and for the same reason: the served-by headers
    /// arrive with the response's status line, which is *before* the first server-sent event, so
    /// a caption that names the operator is correct before the reviewer sees a character rather
    /// than growing a second clause half-way through their draft. `nil` for every endpoint that
    /// does not send the headers, which leaves the caption exactly as it was.
    var servedBy: String?
    /// What the endpoint said about this request, when anyone is recording it.
    ///
    /// The one thing on this value that is only readable **after** the stream finished: the usage
    /// chunk is the last frame before the sentinel. Nothing in the UI reads it — it is the cloud
    /// twin of the measured on-device budget, kept so that a later comparison has the number
    /// instead of having to add the wire field first.
    var report: IntelligenceEndpointReport?
    /// The draft so far, growing. Never deltas.
    var text: AsyncThrowingStream<String, Error>

    /// Creates a labelled stream.
    /// - Parameters:
    ///   - kind: The tier producing the text.
    ///   - servedBy: Who ran the model, when the endpoint said.
    ///   - report: Where the endpoint's own facts about this request are recorded.
    ///   - text: The cumulative drafts.
    init(
        kind: IntelligenceKind,
        servedBy: String? = nil,
        report: IntelligenceEndpointReport? = nil,
        text: AsyncThrowingStream<String, Error>
    ) {
        self.kind = kind
        self.servedBy = servedBy
        self.report = report
        self.text = text
    }

    /// What the endpoint said this answer cost, once the stream has finished.
    ///
    /// **Read it after `text` is exhausted, or it is `nil` for the boring reason**: the usage
    /// chunk is the last frame before the sentinel, so it does not exist while the draft is still
    /// growing. `nil` also for every tier that reports none — the on-device model, an endpoint
    /// that ignored `stream_options`.
    ///
    /// Nothing in the UI reads this yet, on purpose: it is the cloud twin of the measured
    /// on-device budget (ADR 0007's 2026-09-02 amendment), and a token count under a reviewer's
    /// draft would be noise. It is decoded and carried so that whatever compares the estimate
    /// against the real cost later has the number rather than having to add the wire field first.
    var usage: StreamUsage? {
        get async { await report?.usage }
    }
}

/// What asking a tier for a *stream* produced.
///
/// The same four shapes as ``IntelligenceOutcome``, because the UI has to say the same four
/// things; it cannot be that generic type because a stream is not `Hashable` and never will be.
/// ``failure`` converts the three failure shapes back into it, so a caller that already knows how
/// to show "no draft, and here is why" — ``AIDraftFieldState`` — needs no second code path.
enum IntelligenceStreamOutcome: Sendable {
    /// Intelligence is switched off.
    case disabled
    /// Nothing could answer, with a user-readable reason.
    case unavailable(String)
    /// Every configured tier failed, with the last error's description.
    case failed(String)
    /// A tier is answering.
    case stream(IntelligenceStream)

    /// The stream, when a tier answered.
    var stream: IntelligenceStream? {
        if case .stream(let stream) = self { return stream }
        return nil
    }

    /// The same result as a non-streaming outcome, when it is not a stream.
    var failure: IntelligenceOutcome<String>? {
        switch self {
        case .disabled: return .disabled
        case .unavailable(let reason): return .unavailable(reason)
        case .failed(let reason): return .failed(reason)
        case .stream: return nil
        }
    }
}

/// A diagnosis attempt: what came back, and whether the cloud rung is an answer to it.
///
/// A separate value rather than a fourth case on ``IntelligenceOutcome`` because the question it
/// answers is local to one feature: every surface in the app knows how to show "no answer, and
/// here is the sentence", and only the CI card has a *second* thing to do with two particular
/// refusals — offer the cloud rung. Widening the generic outcome for that would make every other
/// caller carry a case it can never see.
struct CIDiagnosisAttempt: Sendable {
    /// What the ladder produced.
    var outcome: IntelligenceOutcome<IntelligenceToolRun<CIDiagnosis>>
    /// Whether the on-device tier refused because the content did not fit.
    ///
    /// `true` only for ``IntelligenceError/contextExceeded`` and
    /// ``IntelligenceError/digestTooLarge(tokens:limit:)`` — the two failures a larger context
    /// window is an answer to (``IntelligenceRouter/isBudgetFailure(_:)``) — and `false` once the
    /// cloud rung has itself been asked and failed, so a card cannot offer the same rung twice.
    var didExceedBudget: Bool = false
    /// Whether the only thing in the way was that the on-device tier is **unavailable**, with a
    /// cloud tier configured that has not been asked yet.
    ///
    /// The second failure with a way out of it, and it is a different sentence rather than a
    /// second meaning for ``didExceedBudget``: a log that did not fit and a Mac with Apple
    /// Intelligence switched off are the same *offer* ("ask the endpoint you configured?") and
    /// two different explanations, and a card that told a cloud-only reviewer their log was too
    /// large would be explaining the wrong thing. `false` once the cloud rung has itself been
    /// asked, so the offer cannot be made twice.
    var isOnDeviceUnavailableWithCloudTier: Bool = false
}

/// What a tier's stream did first — the ladder's whole decision.
private enum FirstElement: Sendable {
    /// Text arrived; this tier owns the answer from here on.
    case arrived
    /// The stream finished without ever yielding.
    case empty
    /// The request was cancelled before any text existed.
    ///
    /// Its own case rather than a ``failed(_:)`` with a cancellation message, because the ladder
    /// treats it differently: a failure moves down a rung, a cancellation stops.
    case cancelled
    /// The stream failed before yielding, with a readable reason.
    case failed(String)
}

/// What starting one tier's stream told the ladder.
private enum StartedStream: Sendable {
    /// The tier produced its first element; everything after this belongs to that tier.
    case started(IntelligenceStream)
    /// The request was cancelled while this tier was still thinking, so there is no next rung.
    case cancelled
    /// The tier produced nothing usable, with a reason the next tier's failure can replace.
    case failed(String)
}

/// Where a router gets its tiers from.
///
/// A seam, for the same reason ``ModelListing`` is one: the degradation ladder — cloud first, then
/// on-device, then a reason the user can read — is the part of the intelligence layer with real
/// behaviour in it, and verifying it must not require an API key, a network, or a Mac with Apple
/// Intelligence switched on. Production uses ``live``; the tests substitute stubs.
struct IntelligenceTiers: Sendable {
    /// Builds the cloud tier from the configuration, or `nil` when none is configured.
    var cloud: @Sendable (IntelligenceConfiguration) -> (any IntelligenceProvider)?
    /// Builds the on-device tier.
    var onDevice: @Sendable () -> any IntelligenceProvider
    /// Why the on-device tier cannot answer right now, or `nil` when it can.
    var onDeviceUnavailabilityReason: @Sendable () -> String?
    /// How a review-summary draft is streamed out of a tier.
    ///
    /// Defaulted to the provider's own method, so this is a seam rather than a decision: a test
    /// that has to drive the *ladder* — first token, then a failure, then the tier below — needs
    /// a stream it controls element by element, and every test that does not care never mentions
    /// it (the memberwise initialiser keeps its three original arguments).
    var summaryStream: @Sendable (
        any IntelligenceProvider, ReviewSummaryDraftRequest
    ) -> AsyncThrowingStream<String, Error> = { $0.streamReviewSummaryDraft($1) }
    /// How an inline-comment draft is streamed out of a tier.
    var inlineStream: @Sendable (
        any IntelligenceProvider, InlineCommentDraftRequest
    ) -> AsyncThrowingStream<String, Error> = { $0.streamInlineCommentDraft($1) }
    /// How an explanation of a selection is streamed out of a tier (plan §3.D).
    ///
    /// The same kind of seam as the two above and needed for the same reason: what is worth
    /// testing about explaining is the *ladder* and the popover behind it, and driving either
    /// through a real provider would need Apple Intelligence, a key and a network.
    var explanationStream: @Sendable (
        any IntelligenceProvider, ExplainSelectionRequest
    ) -> AsyncThrowingStream<String, Error> = { $0.streamExplanation($1) }
    /// How a CI diagnosis is asked of a tier.
    ///
    /// The same kind of seam as the two streams above, and needed for the same reason: the part
    /// of ``IntelligenceRouter/diagnoseFailingChecks(for:summary:preferCloud:)`` worth testing is
    /// the *ladder* — on-device first, the cloud rung only after a budget failure and only with
    /// consent — and driving that through a real provider would need Apple Intelligence, a key
    /// and a network. A test scripts this closure with the failure it wants; every test that does
    /// not care never mentions it.
    var diagnose: @Sendable (
        any IntelligenceProvider, CIDiagnosisRequest, any IntelligenceToolExecuting
    ) async throws -> IntelligenceToolRun<CIDiagnosis> = {
        try await $0.diagnoseFailingChecks($1, tools: $2)
    }
    /// How an agent brief is streamed out of a tier (plan §3.E).
    ///
    /// The same kind of seam as ``summaryStream``, and needed for one thing the other two cannot
    /// show: that a brief quoting a colleague's comment never reaches the cloud rung. A test
    /// scripts this closure per tier and reads back *which* tier answered, which is the whole of
    /// the privacy rule expressed as an assertion.
    var briefStream: @Sendable (
        any IntelligenceProvider, AgentBriefRequest
    ) -> AsyncThrowingStream<String, Error> = { $0.streamAgentBrief($1) }

    /// The real tiers.
    static let live = IntelligenceTiers(
        cloud: { IntelligenceRouter.liveCloudProvider(for: $0) },
        onDevice: { OnDeviceProvider() },
        onDeviceUnavailabilityReason: { OnDeviceProvider.unavailabilityReason() }
    )
}

/// Picks the provider for a request and degrades gracefully to the tier below (ADR 0007).
///
/// The order is deliberate: the cloud tier sees a large digest and answers best, so it is
/// tried first when the user configured a key; on any failure the on-device tier gets a small
/// digest; if that is unavailable too, the caller is told why and the UI simply shows the
/// deterministic heuristics on their own.
struct IntelligenceRouter: Sendable {
    /// The configuration this router was built from.
    let configuration: IntelligenceConfiguration
    /// Where the tiers come from — ``IntelligenceTiers/live`` outside tests.
    private let tiers: IntelligenceTiers

    /// Creates a router.
    /// - Parameters:
    ///   - configuration: The settings snapshot.
    ///   - tiers: Where to get the providers from. Defaults to the real ones.
    init(configuration: IntelligenceConfiguration, tiers: IntelligenceTiers = .live) {
        self.configuration = configuration
        self.tiers = tiers
    }

    /// A router with everything switched off.
    static let disabled = IntelligenceRouter(configuration: .disabled)

    /// Whether any tier could answer at all.
    var isEnabled: Bool { configuration.mode != .off }

    /// The cloud provider, when the user configured one.
    var cloudProvider: (any IntelligenceProvider)? { tiers.cloud(configuration) }

    /// Whether a tier could take a request right now, as far as is knowable synchronously.
    ///
    /// The drafting buttons need an answer *before* the click, so they can be absent rather than
    /// present and then failing (ADR 0007: no feature may hard-depend on an LLM). On-device
    /// availability happens to be a synchronous property of `SystemLanguageModel`, so this is an
    /// honest answer rather than an optimistic one — but it is still only "could take it", not
    /// "will succeed": a wrong key or an unreachable endpoint is found out on the request itself,
    /// and shows up as ``IntelligenceOutcome/failed(_:)``.
    var canDraft: Bool {
        guard isEnabled else { return false }
        if cloudProvider != nil { return true }
        return tiers.onDeviceUnavailabilityReason() == nil
    }

    /// The cloud provider the configuration asks for, or `nil` when it does not ask for one.
    /// - Parameter configuration: The settings snapshot.
    static func liveCloudProvider(
        for configuration: IntelligenceConfiguration
    ) -> (any IntelligenceProvider)? {
        guard configuration.mode == .onDeviceAndCloud else { return nil }
        switch configuration.cloudKind {
        case .anthropic:
            guard !configuration.cloudAPIKey.isEmpty else { return nil }
            return ClaudeProvider(
                apiKey: configuration.cloudAPIKey,
                modelID: configuration.anthropicModel
            )
        case .openAICompatible:
            guard !configuration.openAIModel.isEmpty,
                  OpenAICompatibleProvider.completionsURL(base: configuration.openAIBaseURL) != nil
            else { return nil }
            return OpenAICompatibleProvider(
                baseURL: configuration.openAIBaseURL,
                model: configuration.openAIModel,
                apiKey: configuration.cloudAPIKey,
                // Carried through as configuration, not as behaviour: the provider sends the
                // policy only when it holds one, and an endpoint that has never heard of the
                // field sees a body identical to the one it saw before (plan §3.K).
                sovereigntyCountries: configuration.openAISovereigntyCountries,
                requiresZeroRetention: configuration.openAIZeroRetention
            )
        }
    }

    /// Summarises a pull request.
    ///
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - onDeviceOnly: Whether the cloud rung may see this request at all. The default keeps
    ///     the review screen's own call on the full ladder; `true` is the same *rule* — not a
    ///     preference — that ``streamAgentBrief(for:digest:viewerLogin:)`` applies for a
    ///     colleague's comment, and the App Intents surface passes it (plan §3.H): an intent
    ///     runs with no review screen and no human to fall back to, so tier 2 is the ceiling
    ///     there (ADR 0007's "unattended means on-device only"). Expressing it as a ladder that
    ///     skips the rung is a stronger guarantee than a caller remembering to check the mode.
    /// - Returns: The summary, or why there is none.
    func summary(
        for detail: PullRequestDetail,
        onDeviceOnly: Bool = false
    ) async -> IntelligenceOutcome<PRSummary> {
        await run(detail: detail, allowsCloud: !onDeviceOnly) { provider, digest in
            try await provider.summarizePullRequest(digest)
        }
    }

    /// Suggests where to look first.
    /// - Parameter detail: The fetched pull request.
    func focusHints(for detail: PullRequestDetail) async -> IntelligenceOutcome<[FocusHint]> {
        await run(detail: detail) { provider, digest in
            try await provider.suggestReviewFocus(digest)
        }
    }

    /// Drafts the body of a review, as a suggestion the reviewer edits and submits themselves.
    ///
    /// Same ladder and the same ``IntelligenceOutcome`` semantics as the hint calls above, so the
    /// UI shows the failure the same way it shows a missing summary card: one line of plain text
    /// saying which tier said what. Nothing here submits anything.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - pendingComments: The inline comments already in the local draft, quoted (and capped)
    ///     so the draft can refer to what the reviewer found.
    /// - Returns: The drafted text, or why there is none.
    func draftReviewSummary(
        for detail: PullRequestDetail,
        pendingComments: [DraftComment] = []
    ) async -> IntelligenceOutcome<String> {
        await run { provider, budget in
            try await provider.draftReviewSummary(
                ReviewSummaryDraftRequest.build(
                    detail: detail,
                    pendingComments: pendingComments,
                    budget: budget
                )
            )
        }
    }

    /// Drafts one inline comment, as a suggestion the reviewer edits and saves themselves.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - anchor: The line the comment hangs off.
    /// - Returns: The drafted text, or why there is none.
    func draftInlineComment(
        for detail: PullRequestDetail,
        anchor: InlineCommentAnchor
    ) async -> IntelligenceOutcome<String> {
        guard isEnabled else { return .disabled }
        // Settled before a tier is picked, because the answer is the same for all of them: with
        // no patch there is no excerpt, and a comment drafted from a file name alone would be
        // invention. GitHub sends no patch for binaries and for diffs it truncated.
        guard detail.files.first(where: { $0.path == anchor.path })?.hasPatch == true else {
            return .unavailable(
                String(
                    localized: "GitHub sent no diff for this file, so there is nothing to draft a comment from."
                )
            )
        }
        return await run { provider, budget in
            try await provider.draftInlineComment(
                InlineCommentDraftBuilder.build(detail: detail, anchor: anchor, budget: budget)
            )
        }
    }

    // MARK: - Tool calling (plan §3.F)

    /// Whether a cloud rung exists at all, for the card that may have to offer it.
    ///
    /// The card asks this *before* it draws "ask <provider> with the full log?": on a Mac with no
    /// key configured, the honest answer to a log that did not fit is "it did not fit", not a
    /// button that would fail. Same reasoning as ``canDraft``, one rung further up.
    var hasCloudTier: Bool { isEnabled && cloudProvider != nil }

    /// Whether the **Why?** button may be drawn at all, on a red check.
    ///
    /// Deliberately *not* ``canDraft``: drafting is cloud-first, so a configured key alone is
    /// enough for it, while a diagnosis is on-device-first
    /// (``attemptDiagnosis(for:summary:preferCloud:jobLog:)``) and a cloud-only Mac reaches its
    /// cloud tier only through the card's own question. Both of those Macs can be *asked* — the
    /// one with Apple Intelligence, and the one with a key — and a Mac with neither cannot, which
    /// is the case that must not draw a button that can only fail (ADR 0007: no feature
    /// hard-depends on a tier).
    var canDiagnose: Bool {
        guard isEnabled else { return false }
        if tiers.onDeviceUnavailabilityReason() == nil { return true }
        return hasCloudTier
    }

    /// What to call the configured cloud tier on that button, or `nil` when there is none.
    ///
    /// The tier's own badge — "Anthropic", "custom endpoint" — so the question the reviewer is
    /// asked names the endpoint they configured rather than "the cloud".
    var cloudBadge: String? { cloudProvider?.kind.badge }

    /// Works out why CI is red, by letting a tier read the pull request (plan §3.F).
    ///
    /// **The ladder runs the other way round here, and that is the point.** Every other call in
    /// this router tries the cloud tier first, because it sees a larger digest and answers
    /// better. This one is tier 2 first and tier 3 only as an *explicit* second rung, because the
    /// content is different in kind: a diagnosis reads check summaries, diff windows chosen by a
    /// model rather than a digest a human can see the shape of, and — since the job-log read
    /// landed with ADR 0024 — the reduced tail of a CI log. ADR 0007 lets that travel only when
    /// the user says so for this click, so:
    ///
    /// - tier 2 answers, and normally that is the whole story;
    /// - tier 3 is tried **only** with `preferCloud` — the reviewer's click — and then only for
    ///   the two things a different tier is an answer to: tier 2 failed *because the content did
    ///   not fit* (``IntelligenceError/contextExceeded`` or
    ///   ``IntelligenceError/digestTooLarge(tokens:limit:)``), or tier 2 is **not available on
    ///   this Mac at all** and tier 3 is the only tier there is. Any other tier-2 failure — a
    ///   guardrail refusal, an unreadable answer — is reported as it happened. A cloud provider
    ///   is not a retry.
    ///
    /// `preferCloud` is the reviewer's answer to one button: ``CIDiagnosisCard`` asks *"ask
    /// <provider> with the full log?"* when — and only when — the on-device tier reported the
    /// budget exceeded or reported itself unavailable, and a cloud tier is configured. It
    /// defaults to `false` so that no caller
    /// can send a pull request's contents, log included, to a configured endpoint by leaving an
    /// argument out.
    /// - Parameters:
    ///   - detail: The fetched pull request. The tools answer from this snapshot.
    ///   - summary: The inbox row the reviewer opened — where the title and number come from.
    ///   - preferCloud: Whether the reviewer has agreed to the cloud rung for *this* diagnosis.
    ///   - jobLog: How the `jobLogTail` tool downloads a log. `nil` makes that tool answer that
    ///     there is no log — see ``JobLogFetching``.
    /// - Returns: The diagnosis and its trace, or why there is none.
    func diagnoseFailingChecks(
        for detail: PullRequestDetail,
        summary: PullRequestSummary,
        preferCloud: Bool = false,
        jobLog: (any JobLogFetching)? = nil
    ) async -> IntelligenceOutcome<IntelligenceToolRun<CIDiagnosis>> {
        await attemptDiagnosis(
            for: detail,
            summary: summary,
            preferCloud: preferCloud,
            jobLog: jobLog
        ).outcome
    }

    /// The same diagnosis, plus the two things about a failure the card has to know.
    ///
    /// ``IntelligenceOutcome`` carries a failure as a *sentence*, which is right for every other
    /// surface: a missing summary card shows the tier's own words and there is nothing to decide.
    /// Here there is one decision — whether to offer the cloud rung — and it may only be offered
    /// for the failures another tier is a fix for: the content not fitting
    /// (``CIDiagnosisAttempt/didExceedBudget``), and the on-device tier not being available on
    /// this Mac while a cloud tier is (``CIDiagnosisAttempt/isOnDeviceUnavailableWithCloudTier``).
    /// Recovering either from the sentence would mean string-matching an error message, so both
    /// facts are returned beside the outcome instead, and
    /// ``diagnoseFailingChecks(for:summary:preferCloud:jobLog:)`` stays the call for everything
    /// that does not care.
    /// - Parameters:
    ///   - detail: The fetched pull request. The tools answer from this snapshot.
    ///   - summary: The inbox row the reviewer opened.
    ///   - preferCloud: Whether the reviewer has agreed to the cloud rung for *this* diagnosis.
    ///   - jobLog: How the `jobLogTail` tool downloads a log.
    /// - Returns: The outcome, and which of the two answerable refusals — if either — tier 2
    ///   came back with.
    func attemptDiagnosis(
        for detail: PullRequestDetail,
        summary: PullRequestSummary,
        preferCloud: Bool = false,
        jobLog: (any JobLogFetching)? = nil
    ) async -> CIDiagnosisAttempt {
        guard isEnabled else { return CIDiagnosisAttempt(outcome: .disabled) }
        // Settled before a tier is picked, because the answer is the same for all of them and
        // costs nothing to find out: a pull request with nothing red has nothing to diagnose.
        guard !LocalToolExecutor.failingChecks(in: detail).isEmpty else {
            return CIDiagnosisAttempt(
                outcome: .unavailable(
                    String(
                        localized: "No check on this pull request is failing, so there is nothing to diagnose."
                    )
                )
            )
        }
        // An unavailable on-device model is still not a reason to *silently* use the cloud one —
        // this rung is not a retry, and on this path nothing has been read or sent yet. What it
        // is, on a Mac with a key configured, is a *question*: the same question a log that did
        // not fit asks, with a different explanation in front of it. So the reason travels back
        // with `isOnDeviceUnavailableWithCloudTier` set, the card turns that into its one button,
        // and only that button arrives here with `preferCloud` — which is ADR 0024's rule
        // unchanged (the cloud rung after an explicit click, never before one). With no cloud
        // tier there is nothing to offer and the reason is the whole answer; on such a Mac
        // ``canDiagnose`` drew no button in the first place.
        if let reason = tiers.onDeviceUnavailabilityReason() {
            guard let cloud = cloudProvider else {
                return CIDiagnosisAttempt(outcome: .unavailable(reason))
            }
            guard preferCloud else {
                return CIDiagnosisAttempt(
                    outcome: .unavailable(reason),
                    isOnDeviceUnavailableWithCloudTier: true
                )
            }
            return await askCloud(cloud, detail: detail, summary: summary, jobLog: jobLog)
        }

        let onDevice = tiers.onDevice()
        do {
            return CIDiagnosisAttempt(
                outcome: .value(
                    IntelligenceOutput(
                        kind: onDevice.kind,
                        value: try await ask(
                            onDevice,
                            detail: detail,
                            summary: summary,
                            budget: OnDeviceProvider.budget,
                            jobLog: jobLog
                        )
                    )
                )
            )
        } catch {
            let didExceedBudget = IntelligenceRouter.isBudgetFailure(error)
            guard preferCloud, didExceedBudget, let cloud = cloudProvider else {
                return CIDiagnosisAttempt(
                    outcome: .failed(IntelligenceRouter.describe(error)),
                    didExceedBudget: didExceedBudget
                )
            }
            return await askCloud(cloud, detail: detail, summary: summary, jobLog: jobLog)
        }
    }

    /// Asks the cloud rung, and turns what it answers into an attempt with no offer left in it.
    ///
    /// Two paths reach tier 3 and both of them are one click old: a log that did not fit, and an
    /// on-device tier that is not available on this Mac at all. Neither may offer the rung a
    /// second time, so both `didExceedBudget` and `isOnDeviceUnavailableWithCloudTier` stay
    /// `false` on the way back out — otherwise an endpoint with a wrong key would answer every
    /// click with the same button (ADR 0024: the offer is spent by pressing it).
    /// - Parameters:
    ///   - cloud: The configured cloud tier.
    ///   - detail: The pull request snapshot.
    ///   - summary: The inbox row.
    ///   - jobLog: How the `jobLogTail` tool downloads a log.
    /// - Returns: The diagnosis and its trace, or the endpoint's own failure.
    private func askCloud(
        _ cloud: any IntelligenceProvider,
        detail: PullRequestDetail,
        summary: PullRequestSummary,
        jobLog: (any JobLogFetching)?
    ) async -> CIDiagnosisAttempt {
        do {
            return CIDiagnosisAttempt(
                outcome: .value(
                    IntelligenceOutput(
                        kind: cloud.kind,
                        value: try await ask(
                            cloud,
                            detail: detail,
                            summary: summary,
                            budget: ClaudeProvider.budget,
                            jobLog: jobLog
                        )
                    )
                )
            )
        } catch {
            return CIDiagnosisAttempt(outcome: .failed(IntelligenceRouter.describe(error)))
        }
    }

    /// Asks one tier for a diagnosis, with an executor budgeted for that tier.
    ///
    /// The executor is built per tier rather than once, because the budget is what the tools cut
    /// their answers to: the same `fileDiff` call returns a window a cloud model can afford and a
    /// window an on-device model can, from the same snapshot. Building it once would mean the
    /// second rung inheriting the first rung's budget, which is precisely the budget that just
    /// failed.
    /// - Parameters:
    ///   - provider: The tier to ask.
    ///   - detail: The pull request snapshot.
    ///   - summary: The inbox row.
    ///   - budget: The tier's token budget.
    ///   - jobLog: How the `jobLogTail` tool downloads a log.
    /// - Returns: The diagnosis and its trace.
    private func ask(
        _ provider: any IntelligenceProvider,
        detail: PullRequestDetail,
        summary: PullRequestSummary,
        budget: TokenBudget,
        jobLog: (any JobLogFetching)?
    ) async throws -> IntelligenceToolRun<CIDiagnosis> {
        try await tiers.diagnose(
            provider,
            CIDiagnosisRequest.build(detail: detail, summary: summary, budget: budget),
            LocalToolExecutor(detail: detail, budget: budget, jobLog: jobLog)
        )
    }

    /// Whether a failure was the content not fitting — the one failure the cloud rung answers.
    ///
    /// Two cases, and they are the two ends of the same problem: `digestTooLarge` is Shepherd's
    /// own pre-flight refusing to start, `contextExceeded` is the model's real tokenizer
    /// disagreeing with that estimate from inside a session. Both mean "this does not fit in
    /// 8,192 tokens", which is the only thing a 100,000-token window is a fix for.
    /// - Parameter error: What the tier threw.
    /// - Returns: `true` when a larger context window would be a different answer.
    static func isBudgetFailure(_ error: any Error) -> Bool {
        guard let intelligence = error as? IntelligenceError else { return false }
        switch intelligence {
        case .contextExceeded, .digestTooLarge:
            return true
        default:
            return false
        }
    }

    /// Whether a failure means the work was **cancelled** rather than that a tier failed.
    ///
    /// The distinction the degradation ladder cannot do without. Every rung of both ladders
    /// catches whatever the tier threw and tries the tier below, which is right for a wrong key,
    /// an unreachable endpoint or a guardrail refusal — and wrong for a cancellation: the
    /// reviewer who pressed Stop while the cloud tier was in flight would have the on-device
    /// model started for them, and would watch a draft they had just cancelled appear anyway.
    ///
    /// Three shapes, because cancellation reaches us in three spellings: the language's own
    /// ``CancellationError``, `URLSession`'s ``URLError/Code/cancelled`` (what an in-flight cloud
    /// request throws when its task goes away), and — as a backstop — the state of the current
    /// task itself, for a provider that swallows the cancellation and reports something of its
    /// own instead. ``IntelligenceError/cancelled`` is included so that a ladder rung that has
    /// already mapped one of the three keeps being recognised by the next.
    /// - Parameter error: What the tier threw.
    /// - Returns: `true` when nobody is waiting for an answer any more.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let intelligence = error as? IntelligenceError, intelligence == .cancelled { return true }
        return Task.isCancelled
    }

    /// The one line a cancelled request answers with, in both ladders and on both rungs.
    private static var cancelledFailureMessage: String {
        describe(IntelligenceError.cancelled)
    }

    // MARK: - Streaming (plan §0.2)

    /// Drafts the body of a review as a stream of cumulative text.
    ///
    /// Same ladder, same budgets and the same four answers as
    /// ``draftReviewSummary(for:pendingComments:)`` — the difference is only that the reviewer
    /// watches it arrive. Nothing here submits anything.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - pendingComments: The inline comments already in the local draft, quoted and capped.
    /// - Returns: A labelled stream, or why there is none.
    func streamReviewSummaryDraft(
        for detail: PullRequestDetail,
        pendingComments: [DraftComment] = []
    ) async -> IntelligenceStreamOutcome {
        let tiers = self.tiers
        return await runStream { provider, budget in
            tiers.summaryStream(
                provider,
                ReviewSummaryDraftRequest.build(
                    detail: detail,
                    pendingComments: pendingComments,
                    budget: budget
                )
            )
        }
    }

    /// Drafts one inline comment as a stream of cumulative text.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - anchor: The line the comment hangs off.
    /// - Returns: A labelled stream, or why there is none.
    func streamInlineCommentDraft(
        for detail: PullRequestDetail,
        anchor: InlineCommentAnchor
    ) async -> IntelligenceStreamOutcome {
        guard isEnabled else { return .disabled }
        // Settled before a tier is picked, exactly as in the non-streaming call: with no patch
        // there is no excerpt, and a comment drafted from a file name alone would be invention.
        guard detail.files.first(where: { $0.path == anchor.path })?.hasPatch == true else {
            return .unavailable(
                String(
                    localized: "GitHub sent no diff for this file, so there is nothing to draft a comment from."
                )
            )
        }
        let tiers = self.tiers
        return await runStream { provider, budget in
            tiers.inlineStream(
                provider,
                InlineCommentDraftBuilder.build(detail: detail, anchor: anchor, budget: budget)
            )
        }
    }

    /// Explains the lines a reviewer selected, as a stream of cumulative prose (plan §3.D).
    ///
    /// The same ladder as the two drafting streams, deliberately and not by coincidence: an
    /// explanation carries the excerpt an inline draft carries, so a tier that may draft a
    /// comment about these lines may explain them, and one that may not, may not. Tier 2 is what
    /// the feature is designed for; the cloud rung is tried first only because it is tried first
    /// for everything that sends a diff excerpt, and it is only ever a tier the user configured
    /// themselves.
    ///
    /// Nothing here writes anywhere. The result is text in a popover, and turning it into a
    /// comment is a separate click that goes through ``AIDraftFieldState`` — there is no path
    /// from this call to the outbox (ADR 0007's non-goal).
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - anchor: The lines the reviewer selected.
    ///   - languageName: The language to answer in. Defaults to the reviewer's own, which is the
    ///     whole point of the parameter existing at the edge rather than being read inside the
    ///     prompt builder: a test can pin a language without pinning the runner's locale.
    /// - Returns: A labelled stream, or why there is none.
    func streamExplanation(
        for detail: PullRequestDetail,
        anchor: InlineCommentAnchor,
        languageName: String = ExplainSelectionRequest.currentLanguageName()
    ) async -> IntelligenceStreamOutcome {
        guard isEnabled else { return .disabled }
        // Settled before a tier is picked, exactly as in the drafting calls: with no patch there
        // is no excerpt, and an explanation of a file name would be invention.
        guard detail.files.first(where: { $0.path == anchor.path })?.hasPatch == true else {
            return .unavailable(
                String(
                    localized: "GitHub sent no diff for this file, so there is nothing to explain."
                )
            )
        }
        let tiers = self.tiers
        return await runStream { provider, budget in
            tiers.explanationStream(
                provider,
                ExplainSelectionRequest.build(
                    detail: detail,
                    anchor: anchor,
                    budget: budget,
                    languageName: languageName
                )
            )
        }
    }

    /// The degradation ladder, for streams.
    ///
    /// The shape mirrors ``run(operation:)`` deliberately, down to which failure wins, and adds
    /// one rule streams need: a tier has "answered" only once its first element exists. Until
    /// then the ladder may still step down, and after that it may not — a half-written draft the
    /// reviewer is watching must not be replaced by another tier's attempt at the same thing.
    /// - Parameters:
    ///   - allowsCloud: Whether the cloud rung may see this request at all. `false` is not a
    ///     preference but a rule: the delegation brief passes it when the request carries a
    ///     colleague's comment (ADR 0020's reasoning), and a ladder that skips the rung is a
    ///     stronger guarantee than a prompt asking a provider not to look.
    ///   - operation: How one tier is asked, given its token budget.
    private func runStream(
        allowsCloud: Bool = true,
        operation: @escaping @Sendable (any IntelligenceProvider, TokenBudget)
            -> AsyncThrowingStream<String, Error>
    ) async -> IntelligenceStreamOutcome {
        guard isEnabled else { return .disabled }

        var lastFailure: String?

        if allowsCloud, let cloud = cloudProvider {
            // One report per request, handed to the tier before it is asked and read back once it
            // has committed to answering. A tier whose endpoint volunteers nothing keeps the
            // default no-op and leaves it empty (plan §3.K).
            let report = IntelligenceEndpointReport()
            switch await IntelligenceRouter.start(
                operation(cloud.reporting(to: report), ClaudeProvider.budget),
                kind: cloud.kind,
                report: report
            ) {
            case .started(let stream): return .stream(stream)
            // A cancellation ends the request instead of moving down a rung: the reviewer who
            // pressed Stop is not asking for the tier below to try the same thing.
            case .cancelled: return .failed(IntelligenceRouter.cancelledFailureMessage)
            case .failed(let reason): lastFailure = reason
            }
        }

        let unavailabilityReason = tiers.onDeviceUnavailabilityReason()
        if unavailabilityReason == nil {
            let onDevice = tiers.onDevice()
            switch await IntelligenceRouter.start(
                operation(onDevice, OnDeviceProvider.budget),
                kind: onDevice.kind
            ) {
            case .started(let stream): return .stream(stream)
            case .cancelled: return .failed(IntelligenceRouter.cancelledFailureMessage)
            case .failed(let reason): lastFailure = reason
            }
        } else if lastFailure == nil {
            return .unavailable(
                unavailabilityReason
                    ?? String(localized: "No intelligence provider is available.")
            )
        }

        return .failed(lastFailure ?? String(localized: "No intelligence provider is available."))
    }

    /// Waits for a tier's first element and re-publishes the whole stream behind it.
    ///
    /// Everything the provider yields is forwarded into a second stream rather than the caller
    /// being handed the provider's own: the first element has to be *awaited* here to decide
    /// whether this tier answered at all, and an already-started iteration cannot be given away.
    /// Buffering is what makes that free — the elements that arrive while the ladder is still
    /// deciding are queued, not dropped, so the reviewer sees the draft from its first word.
    ///
    /// A tier that finishes without ever yielding counts as a failure. It is the on-device
    /// model's most likely bad day (a guardrail refusal arrives as an error, but an empty answer
    /// arrives as nothing at all), and treating it as success would leave the reviewer watching
    /// an empty field with no reason in sight.
    ///
    /// **The wait is structured, and it has to be.** The task driving the provider is created
    /// before the wait, and the wait itself runs inside ``withTaskCancellationHandler``, so a
    /// caller cancelled while the tier is still thinking — the reviewer pressing Stop before the
    /// first token — cancels that task rather than abandoning it. Cancelling through
    /// ``AsyncThrowingStream/Continuation/onTermination`` alone cannot do that job: it fires when
    /// the *relay* is terminated, and until the first element exists the relay has not been handed
    /// to anybody who could terminate it, so an in-flight cloud request would run to completion
    /// with nobody left to read it. The handshake travels through a one-element stream rather than
    /// a continuation for the same reason — the driving task has to exist before the wait does, so
    /// that the cancellation handler has something to cancel.
    /// - Parameters:
    ///   - source: The provider's stream, not yet iterated.
    ///   - kind: The tier it came from.
    ///   - report: The box the tier records what its endpoint said into, when there is one. It is
    ///     read exactly here, after the first element: the served-by headers arrive with the
    ///     response's status line, so by the time a tier has produced text they are already in —
    ///     and this is the last moment before the caption is handed out (plan §3.K).
    /// - Returns: The labelled stream, the fact that the request was cancelled, or the reason this
    ///   tier did not answer.
    private static func start(
        _ source: AsyncThrowingStream<String, Error>,
        kind: IntelligenceKind,
        report: IntelligenceEndpointReport? = nil
    ) async -> StartedStream {
        let relay = AsyncThrowingStream<String, Error>.makeStream()
        // One value, from the driving task to the ladder: which of the four things happened first.
        let handshake = AsyncStream<FirstElement>.makeStream()
        let driver = Task {
            // The only thing that answers the handshake, and it must do so exactly once: the flag
            // is local to this task, so there is nothing to synchronise.
            var reported = false
            func report(_ value: FirstElement) {
                guard !reported else { return }
                reported = true
                handshake.continuation.yield(value)
                handshake.continuation.finish()
            }
            do {
                for try await text in source {
                    report(.arrived)
                    relay.continuation.yield(text)
                }
                // A cancelled `AsyncThrowingStream` ends by *finishing*, not by throwing, so an
                // empty answer and a stopped one arrive at the same place and are told apart here.
                report(Task.isCancelled ? .cancelled : .empty)
                relay.continuation.finish()
            } catch {
                report(isCancellation(error) ? .cancelled : .failed(describe(error)))
                relay.continuation.finish(throwing: error)
            }
        }
        // The reviewer closing the sheet ends the request too: the stream going away cancels the
        // task, which cancels the URL session's byte stream or the model's session.
        relay.continuation.onTermination = { _ in driver.cancel() }

        let signal: FirstElement? = await withTaskCancellationHandler {
            var iterator = handshake.stream.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            driver.cancel()
        }

        // Checked after the first element, not only before it: the wait can be cancelled while
        // the tier is still thinking (`next()` then comes back empty), and it can be cancelled in
        // the instant between the first element and this line — in which case handing the stream
        // out would hand a live request to a caller that has already stopped waiting for it.
        guard let signal, !Task.isCancelled else {
            driver.cancel()
            return .cancelled
        }

        switch signal {
        case .arrived:
            return .started(
                IntelligenceStream(
                    kind: kind,
                    servedBy: await IntelligenceRouter.servedByCaption(report),
                    report: report,
                    text: relay.stream
                )
            )
        case .empty:
            return .failed(describe(IntelligenceError.malformedResponse))
        case .cancelled:
            return .cancelled
        case .failed(let reason):
            return .failed(reason)
        }
    }

    /// Runs an operation that needs a digest, building one per tier's budget.
    /// - Parameters:
    ///   - detail: The fetched pull request the digest is built from.
    ///   - allowsCloud: Whether the cloud rung may see this request at all — passed straight
    ///     through to ``run(allowsCloud:operation:)``.
    ///   - operation: How one tier is asked, given the digest built for its budget.
    private func run<Value: Sendable & Hashable>(
        detail: PullRequestDetail,
        allowsCloud: Bool = true,
        operation: @Sendable (any IntelligenceProvider, PullRequestDigest) async throws -> Value
    ) async -> IntelligenceOutcome<Value> {
        await run(allowsCloud: allowsCloud) { provider, budget in
            try await operation(provider, PullRequestDigestBuilder.build(from: detail, budget: budget))
        }
    }

    /// The degradation ladder itself: cloud, then on-device, then a reason.
    ///
    /// The operation is handed the tier's token budget rather than a finished prompt, because that
    /// is the one thing that genuinely differs between the tiers — the cloud tier sees a large
    /// context, the on-device tier a small one, and every request type caps itself against the
    /// budget it is given.
    /// - Parameters:
    ///   - allowsCloud: Whether the cloud rung may see this request at all. The mirror of
    ///     ``runStream(allowsCloud:operation:)``'s parameter and there for the same reason: `false`
    ///     is a rule rather than a preference, so a request that may not travel is never *offered*
    ///     to a provider instead of being asked nicely not to look. Defaulted, so every existing
    ///     call site keeps the full ladder unchanged.
    ///   - operation: How one tier is asked, given its token budget.
    private func run<Value: Sendable & Hashable>(
        allowsCloud: Bool = true,
        operation: @Sendable (any IntelligenceProvider, TokenBudget) async throws -> Value
    ) async -> IntelligenceOutcome<Value> {
        guard isEnabled else { return .disabled }

        var lastFailure: String?

        if allowsCloud, let cloud = cloudProvider {
            // The non-streaming twin of the same hook: one report per request, read after the
            // answer rather than after the first element, because here there is only an answer.
            let report = IntelligenceEndpointReport()
            do {
                let value = try await operation(
                    cloud.reporting(to: report),
                    ClaudeProvider.budget
                )
                return .value(
                    IntelligenceOutput(
                        kind: cloud.kind,
                        value: value,
                        servedBy: await IntelligenceRouter.servedByCaption(report)
                    )
                )
            } catch {
                // A cancellation is not a tier failure: stepping down here would start the
                // on-device tier for a reviewer who has just stopped the request.
                guard !IntelligenceRouter.isCancellation(error) else {
                    return .failed(IntelligenceRouter.cancelledFailureMessage)
                }
                lastFailure = IntelligenceRouter.describe(error)
            }
        }

        let unavailabilityReason = tiers.onDeviceUnavailabilityReason()
        if unavailabilityReason == nil {
            let onDevice = tiers.onDevice()
            do {
                return .value(
                    IntelligenceOutput(
                        kind: onDevice.kind,
                        value: try await operation(onDevice, OnDeviceProvider.budget)
                    )
                )
            } catch {
                guard !IntelligenceRouter.isCancellation(error) else {
                    return .failed(IntelligenceRouter.cancelledFailureMessage)
                }
                lastFailure = IntelligenceRouter.describe(error)
            }
        } else if lastFailure == nil {
            return .unavailable(
                unavailabilityReason
                    ?? String(localized: "No intelligence provider is available.")
            )
        }

        return .failed(lastFailure ?? String(localized: "No intelligence provider is available."))
    }

    private static func describe(_ error: any Error) -> String {
        error.userFacingDescription
    }

    /// The one phrase a caption appends when the endpoint named who served the request.
    ///
    /// Written out rather than inlined as an optional chain across an actor boundary, so the
    /// hop is one statement and the `nil` cases — no report, nothing recorded — read as the
    /// same "nothing to say" they are (plan §3.K).
    /// - Parameter report: The request's report, when there was one.
    /// - Returns: The caption suffix, or `nil` when the endpoint volunteered nothing.
    private static func servedByCaption(
        _ report: IntelligenceEndpointReport?
    ) async -> String? {
        guard let report else { return nil }
        let servedBy = await report.servedBy
        return servedBy?.caption
    }

    // MARK: - Delegation brief (plan §3.E)

    /// Drafts the task for a coding agent as a stream of cumulative Markdown (plan §3.E).
    ///
    /// The same ladder and the same four answers as the two drafting streams, with one rule of
    /// its own: **a brief that quotes somebody else's comment does not use the cloud rung.** The
    /// digest and the reviewer's own words already travel under the ADR 0007 amendment, but a
    /// colleague's review comment has an author who never chose the reviewer's endpoint (ADR
    /// 0020's reasoning), and the honest place for that rule is the ladder — a request built with
    /// ``AgentBriefRequest/onDeviceOnly`` simply never gets offered to a cloud provider, so no
    /// future caller can opt out of it by passing a flag.
    ///
    /// Nothing here starts anything. The stream fills the sheet's task field; Run stays the
    /// reviewer's click (ADR 0011 amendment), and an automatic delegation never calls this at all
    /// (ADR 0016 — its rules keep their fixed template).
    /// - Parameters:
    ///   - context: What the delegation is about — the slug, the worktree's commit, the finding
    ///     and its comments.
    ///   - digest: The tier-1 digest, built with
    ///     ``AgentBriefRequest/digest(for:budget:)`` so the finding comments' share of the budget
    ///     is already reserved. It is built once, for the smallest tier that may answer, which is
    ///     also what keeps a cloud rung from ever seeing *more* than the on-device rung would
    ///     have.
    ///   - viewerLogin: The signed-in user's login, when there is one. It decides which quoted
    ///     comments count as the reviewer's own.
    /// - Returns: A labelled stream, or why there is none.
    func streamAgentBrief(
        for context: DelegationContext,
        digest: PullRequestDigest,
        viewerLogin: String? = nil
    ) async -> IntelligenceStreamOutcome {
        let tiers = self.tiers
        let onDeviceOnly = AgentBriefRequest.requiresOnDevice(
            context: context,
            viewerLogin: viewerLogin
        )
        return await runStream(allowsCloud: !onDeviceOnly) { provider, budget in
            tiers.briefStream(
                provider,
                AgentBriefRequest.build(
                    context: context,
                    digest: digest,
                    budget: budget,
                    viewerLogin: viewerLogin
                )
            )
        }
    }
}
