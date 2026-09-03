import Foundation
import Observation
import ShepherdCore

/// Everything ``ClaimsEvidenceCard`` draws and everything pressing a button on it does — as a
/// pure value, so the three rules worth getting right are unit-tested rather than inferred from a
/// screenshot (ADR 0026).
///
/// - **An empty report means no card.** A description that claims nothing has not asked a
///   question, so there is nothing to answer; ``isHidden`` is the whole of that rule.
/// - **Agent pull requests open expanded, human ones collapsed.** The provenance facet of
///   ADR 0008, applied to the one card whose reason for existing is the agent flood. The
///   reviewer's own toggle outranks it from then on (``didChooseExpansion``), because a
///   background refresh that re-collapsed the card the reviewer had just opened would be worse
///   than a wrong default.
/// - **A finding never silently overwrites the summary.** Same rule as ``AIDraftFieldState``'s,
///   for the same reason — but deliberately *not* the same code path: this text is not generated,
///   so it carries no tier, no "AI draft" caption and no sparkles. What it borrows is the
///   question, and ``ShepherdCore/SavedReply/inserting(_:into:)`` for the append, which is the
///   app's one documented answer to "how does text get added to a composer".
struct ClaimsEvidenceCardState: Equatable, Sendable {
    /// A finding waiting for the reviewer to answer replace-or-append.
    struct PendingInsertion: Equatable, Sendable {
        /// The text that will be written into the summary.
        var text: String
    }

    /// The reviewer's answer to that question.
    enum Choice: Equatable, Sendable {
        /// The finding takes the field.
        case replace
        /// The finding goes after what is already there.
        case append
    }

    /// What "Turn into a comment" asks the caller to do.
    enum Insertion: Equatable, Sendable {
        /// Write this into the review summary; the field was empty.
        case write(String)
        /// Nothing has been written: the field was not empty and the question is now up.
        case askFirst
    }

    /// The claims and their evidence.
    var report: ClaimsEvidenceReport
    /// Whether the rows are showing.
    var isExpanded: Bool
    /// Whether ``isExpanded`` is the reviewer's own decision rather than the provenance default.
    var didChooseExpansion: Bool
    /// The finding waiting for a replace-or-append answer, if any.
    var pendingInsertion: PendingInsertion?
    /// Whether a finding has been written into the summary on this screen.
    ///
    /// Only for the one line of confirmation the card shows: the summary field lives in the
    /// submit sheet, so a reviewer who presses the button and sees nothing move would reasonably
    /// conclude the button is broken.
    var didInsertIntoSummary: Bool

    /// Whether the optional on-device pass is reading the description right now.
    ///
    /// The card shows a spinner and one line while this is `true`, because the rows can *grow*
    /// underneath a reviewer who is already reading them and a card that gained a line out of
    /// nowhere would read as a bug (ADR 0026's amendment).
    var isReading: Bool

    /// Why the on-device model cannot read the description on this Mac, when it cannot.
    ///
    /// Nothing in the card shows it — the extra pass is simply absent, which is the tier-1 card
    /// this feature is a supplement to — but the sentence exists so that anything which later
    /// wants to explain the absence has the model's own words rather than an invented apology.
    /// The same arrangement ``ThreadDigestCoordinator/unavailabilityReason`` has.
    var modelUnavailableReason: String?

    /// Creates the state for one pull request.
    /// - Parameters:
    ///   - report: The claims and their evidence.
    ///   - provenance: The pull request author's detected kind. A recognised coding agent opens
    ///     the card; a human — and a bot that is *not* a recognised agent — leaves it collapsed.
    init(report: ClaimsEvidenceReport = .empty, provenance: ActorKind = .human) {
        self.report = report
        self.isExpanded = provenance.agentIdentity != nil
        self.didChooseExpansion = false
        self.pendingInsertion = nil
        self.didInsertIntoSummary = false
        self.isReading = false
        self.modelUnavailableReason = nil
    }

    /// Whether to draw nothing at all.
    var isHidden: Bool { report.isEmpty }

    /// The rows, in the report's order.
    var lines: [ClaimsEvidenceReport.Line] { report.lines }

    /// Whether any row is a claim the optional on-device pass added.
    var hasModelClaims: Bool { lines.contains { $0.claim.origin == .model } }

    /// Whether the card carries the on-device caption at all.
    ///
    /// Only while the pass is running or once it has actually added something: a card that said
    /// "read on-device" and listed four pattern claims would be taking credit for tier 1's work,
    /// and on a Mac without the model there is nothing to say (ADR 0026: the card is complete at
    /// tier 1).
    var showsReadingCaption: Bool { isReading || hasModelClaims }

    /// The reviewer opening or closing the card, which also settles the default from then on.
    mutating func toggleExpansion() {
        isExpanded.toggle()
        didChooseExpansion = true
    }

    /// The text one contradicted line becomes in the review summary: the claim, then the facts.
    ///
    /// The claim's own sentence comes first because that is what the author will recognise, and
    /// the facts follow as the reason. Every fact is already a sentence
    /// (``ShepherdCore/EvidenceFact``), so joining them with a space produces prose rather than a
    /// list — the reviewer edits it in the composer anyway, and a bullet list would be a shape
    /// they have to undo before writing their own sentence.
    /// - Parameter line: The line the button was pressed on.
    /// - Returns: The text to insert.
    static func commentText(for line: ClaimsEvidenceReport.Line) -> String {
        let facts = line.verdict.facts.map(\.text).joined(separator: " ")
        let quote = line.claim.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !facts.isEmpty else { return quote }
        guard !quote.isEmpty else { return facts }
        return "\(quote) — \(facts)"
    }

    /// "Turn into a comment" on one line.
    /// - Parameters:
    ///   - line: The line the button was pressed on.
    ///   - existingSummary: What the review summary holds right now.
    /// - Returns: The text to write, or that the reviewer has to be asked first.
    mutating func turnIntoComment(
        _ line: ClaimsEvidenceReport.Line,
        existingSummary: String
    ) -> Insertion {
        let text = Self.commentText(for: line)
        guard existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingInsertion = PendingInsertion(text: text)
            didInsertIntoSummary = false
            return .askFirst
        }
        pendingInsertion = nil
        didInsertIntoSummary = true
        return .write(text)
    }

    /// Applies the reviewer's answer to the replace-or-append question.
    /// - Parameters:
    ///   - choice: What they picked.
    ///   - existingSummary: What the review summary holds right now.
    /// - Returns: The text to write, or `nil` when nothing was waiting.
    mutating func resolveInsertion(_ choice: Choice, existingSummary: String) -> String? {
        guard let pending = pendingInsertion else { return nil }
        pendingInsertion = nil
        didInsertIntoSummary = true
        switch choice {
        case .replace:
            return pending.text
        case .append:
            return SavedReply.inserting(pending.text, into: existingSummary)
        }
    }

    /// Throws the waiting finding away. The summary is untouched, because it never was touched.
    mutating func discardInsertion() {
        pendingInsertion = nil
    }
}

/// Holds one pull request's claims card for as long as the review screen is open.
///
/// It exists for one reason: ``ShepherdCore/ClaimsEvidenceReport/build(detail:summary:)`` walks
/// every hunk of every file, and a SwiftUI `body` that computed it would do that on every redraw.
/// So the report is built when the pull request's data actually changes and cached until it does
/// — the equality check is on the whole ``ShepherdCore/PullRequestDetail``, which is exact and
/// (thanks to copy-on-write storage) cheap next to the work it avoids.
///
/// Nothing here is persisted. A card is a reading aid, like the CI diagnosis and the thread
/// digest, and it is recomputed from the database's own rows next time the screen opens.
///
/// It also owns the **optional tier-2 pass** (ADR 0026's amendment), and five things about that
/// are decisions rather than mechanics:
///
/// - **Its only model dependency is ``ClaimExtracting``, and it may be `nil`.** There is no
///   `IntelligenceRouter` here, no base URL and no key, so "the description never leaves this
///   Mac" holds by construction rather than by a setting somebody could flip. `nil` — the
///   intelligence tiers switched off — is the ordinary state and costs one optional unwrap.
/// - **It runs because the reviewer expanded the card, and never otherwise.** That expansion *is*
///   the click that makes this tier 2 rather than a model call on every pull request that scrolls
///   past (ADR 0026 forbids the second). Nothing calls it from a sweep, and there is no button —
///   a card the reviewer opened is a card they are reading.
/// - **Once per pull request, and a failure is not retried.** The pass is spent against the
///   ``ShepherdCore/PullRequestDetail`` it read, so collapsing and re-opening the card costs
///   nothing; a guardrail refusal or an overlong description would decline again on the same
///   words, which is ADR 0007's own no-retry rule.
/// - **It only ever adds.** The merge is ``ShepherdCore/ClaimList/merged(into:)``, the pattern
///   lines come out with their verdicts untouched, and the new ones go through the same
///   ``ShepherdCore/EvidenceChecker``. A Mac without the model shows a subset of this card rather
///   than a different one.
/// - **Nothing it produces acts, and nothing it fails at is reported.** A tier-2 failure leaves
///   the tier-1 card exactly as it was: the reviewer did not press a button labelled *read this*,
///   so an error line would be an apology for a question they never asked.
@MainActor
@Observable
final class ClaimsEvidenceModel {
    /// What the card draws, and what its buttons act on.
    var state = ClaimsEvidenceCardState()

    /// The detail the current ``state`` was built from.
    private var builtFrom: PullRequestDetail?

    /// The tier-2 seam, as the caller had it at the last refresh.
    ///
    /// Taken per refresh rather than in the initialiser, for ``CIDiagnosisModel``'s reason: what
    /// the intelligence settings allow is a value the settings tab replaces, and a seam captured
    /// when the review screen was built is how a card ends up asking a model the reviewer
    /// switched off ten minutes ago. Not observed — no view reads it.
    @ObservationIgnored private var extractor: (any ClaimExtracting)?

    /// The detail the tier-2 pass has already been spent on.
    @ObservationIgnored private var readFrom: PullRequestDetail?

    /// The pass in flight, so a new pull request can stop one nobody will see the answer to.
    @ObservationIgnored private var readTask: Task<Void, Never>?

    /// The model's answer about this Mac, once it has been asked.
    @ObservationIgnored private var cachedAvailability: ClaimExtractorAvailability?

    /// The ask itself while it is in flight, so two expansions ask once.
    @ObservationIgnored private var availabilityTask: Task<ClaimExtractorAvailability, Never>?

    /// Creates an empty model. No report is built until ``refresh(detail:extractor:)`` is called.
    init() {}

    /// Rebuilds the report when the pull request's data changed, and does nothing when it did not.
    /// - Parameters:
    ///   - detail: The pull request, or `nil` while it is still loading.
    ///   - extractor: The tier-2 seam as it stands, or `nil` when the intelligence tiers are off
    ///     — in which case this model is exactly the tier-1 model it has always been.
    func refresh(detail: PullRequestDetail?, extractor: (any ClaimExtracting)? = nil) {
        // Assigned before the guard: the reviewer can switch the tiers off while the same pull
        // request is on screen, and that has to reach the next expansion.
        self.extractor = extractor
        guard builtFrom != detail else { return }
        builtFrom = detail
        // A pass for a pull request that is gone: nobody will ever see its answer, so it is
        // stopped rather than left to finish on the battery, and the pull request that arrived
        // gets its own pass when the reviewer opens the card.
        cancelReading()
        readFrom = nil
        let report = detail.map { current in
            ClaimsEvidenceReport.build(detail: current, summary: current.summary)
        } ?? .empty
        var next = ClaimsEvidenceCardState(
            report: report,
            provenance: detail?.summary.author.kind ?? .human
        )
        // The reviewer's own toggle survives a background refresh; the provenance default does
        // not have to, because it is a default.
        if state.didChooseExpansion {
            next.isExpanded = state.isExpanded
            next.didChooseExpansion = true
        }
        // Whether this Mac has the model is a property of the Mac and not of the pull request.
        next.modelUnavailableReason = state.modelUnavailableReason
        state = next
    }

    // MARK: - The optional on-device pass

    /// Reads the description with the on-device model, once, because the card is open.
    ///
    /// Does nothing — and reports nothing — in six cases, all of them ordinary: the tiers are
    /// off, there is no pull request yet, the description claims nothing so there is no card to
    /// expand, the card is collapsed, this Mac has no model, or this pull request's pass has
    /// already been spent.
    ///
    /// Awaits the pass, so a caller — the card's `.task`, or a test — can act on the state that
    /// comes out of it rather than polling for one.
    /// - Parameter detail: The pull request the card is showing.
    func readWithModel(detail: PullRequestDetail?) async {
        guard extractor != nil, let detail else { return }
        // Awaited *first*, so that everything below is one synchronous stretch on the main actor.
        // With the availability check in the middle, two expansions arriving together could both
        // get past the "has this pull request been read?" test and start two sessions.
        await prepareAvailability()
        guard let extractor, let availability = cachedAvailability else { return }
        guard availability == .available else {
            state.modelUnavailableReason = availability.reason
            return
        }
        guard builtFrom == detail, state.isExpanded, !state.isHidden else { return }
        guard readFrom != detail else { return }
        // Marked spent before the pass starts, which is what makes "once" true rather than
        // likely: a second expansion arriving while this one is generating finds it spent.
        readFrom = detail
        state.isReading = true
        let body = detail.bodyMarkdown
        let task = Task { [weak self] in
            let list = try? await extractor.extract(from: body)
            guard !Task.isCancelled else { return }
            self?.finishReading(list, for: detail)
        }
        readTask = task
        await task.value
    }

    /// Stops the pass in flight, if there is one.
    ///
    /// The spinner goes with it: a spinner nobody is filling any more is a lie, and the card
    /// below it is complete without the pass.
    func cancelReading() {
        readTask?.cancel()
        readTask = nil
        state.isReading = false
    }

    /// Asks the model whether it is there, at most once per model instance.
    ///
    /// Whether this Mac can run the pass is a property of the Mac, so the answer is remembered
    /// for as long as the review screen is open — the same arrangement
    /// ``ThreadDigestCoordinator/prepare()`` uses, and for the same reason.
    private func prepareAvailability() async {
        if cachedAvailability != nil { return }
        guard let extractor else { return }
        if let running = availabilityTask {
            cachedAvailability = await running.value
            return
        }
        let task = Task { await extractor.availability() }
        availabilityTask = task
        cachedAvailability = await task.value
    }

    /// Folds what the model read into the report, or records that it read nothing.
    /// - Parameters:
    ///   - list: What the model read, or `nil` when the pass failed.
    ///   - detail: The pull request the pass was for.
    private func finishReading(_ list: ClaimList?, for detail: PullRequestDetail) {
        // The screen moved on while the model was reading; `refresh(detail:extractor:)` has
        // already cleared the spinner for the pull request that is showing now.
        guard builtFrom == detail else { return }
        readTask = nil
        state.isReading = false
        guard let list, !list.isEmpty else { return }
        state.report = ClaimsEvidenceModel.merging(list, into: state.report, of: detail)
    }

    /// The report with the model's claims added, and only the new lines checked.
    ///
    /// The pattern lines come out of this function as the *same values* that went in — claim,
    /// quote, origin and verdict — so tier 2 cannot change what tier 1 said about a pull request;
    /// it can only add rows beside it. The added rows go through
    /// ``ShepherdCore/EvidenceChecker/check(_:in:)``, which is the same function
    /// ``ShepherdCore/ClaimsEvidenceReport/build(detail:summary:)`` puts every pattern claim
    /// through, because "the evidence is the diff and CI" is not a rule about where the claim came
    /// from (ADR 0026).
    ///
    /// The verdicts are looked up by line id — ``ShepherdCore/Claim/id`` is the dedup key, and the
    /// merge guarantees one claim per key — so a re-check of a pattern claim can never happen by
    /// accident.
    /// - Parameters:
    ///   - list: What the model read.
    ///   - report: The tier-1 report.
    ///   - detail: The pull request, carrying the summary the tier-1 report was built against.
    /// - Returns: The merged report.
    static func merging(
        _ list: ClaimList,
        into report: ClaimsEvidenceReport,
        of detail: PullRequestDetail
    ) -> ClaimsEvidenceReport {
        let existing = Dictionary(
            report.lines.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let merged = list.merged(into: report.lines.map { $0.claim })
        return ClaimsEvidenceReport(
            lines: merged.map { claim in
                existing[claim.id] ?? ClaimsEvidenceReport.Line(
                    claim: claim,
                    verdict: EvidenceChecker.check(claim, in: detail)
                )
            }
        )
    }
}
