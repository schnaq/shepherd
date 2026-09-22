import Foundation
import GitHubKit
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
    /// the facts follow as the reason. Every fact renders to a sentence
    /// (``ShepherdCore/EvidenceFact/englishSentence``), so joining them with a space produces
    /// prose rather than a list — the reviewer edits it in the composer anyway, and a bullet list
    /// would be a shape they have to undo before writing their own sentence.
    ///
    /// **The English sentence, deliberately, on a German Mac too.** This text goes into a review
    /// comment, and a review comment is written to GitHub, where the author — and every later
    /// reader of the thread — reads English (ADR 0022's rule about the review vocabulary, taken
    /// to its end). The card above it shows the same facts in the reviewer's own language through
    /// `EvidenceFact.localizedSentence(bundle:)`.
    /// - Parameter line: The line the button was pressed on.
    /// - Returns: The text to insert.
    static func commentText(for line: ClaimsEvidenceReport.Line) -> String {
        let facts = line.verdict.facts.map(\.englishSentence).joined(separator: " ")
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

/// How the claims card reads the issue a `fixes #N` claim points at (ADR 0026's amendment).
///
/// The ``JobLogFetching`` / ``WebhookPosting`` seam once more, and it exists for the same three
/// reasons:
///
/// - **The card stays testable.** Every other line of this card is a pure function of a
///   `PullRequestDetail`; the issue line is the one that needs a GitHub call, and a test of
///   "what does the card say when the issue is a 404" must not need a token or a network.
/// - **No fetcher is a state, not a failure.** The parameter is optional wherever it is passed, so
///   a signed-out window produces a card whose issue line says the criteria were not checked —
///   which is exactly what it said before this read existed.
/// - **The seam adds nothing.** The one production conformance is ``GitHubKit/GitHubClient``,
///   whose `issue(repo:number:)` this method *is*: the ETag cache, the retry policy and the
///   error mapping all live there, and a seam that transformed the answer on the way through
///   would be a second place for them to live.
protocol IssueFetching: Sendable {
    /// Reads one issue of one repository.
    /// - Parameters:
    ///   - repo: The pull request's own repository.
    ///   - number: The issue number.
    /// - Returns: The issue, with its body as Markdown source.
    /// - Throws: Whatever the read failed with; the model turns it into one sentence on the card.
    func issue(repo: RepoRef, number: Int) async throws -> IssueSummary
}

/// The live issue read: GitHub's own, with nothing in between.
extension GitHubClient: IssueFetching {}

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
///
/// **The acceptance-criteria read is the one thing here that touches the network** (ADR 0026's
/// amendment), and four rules bound it:
///
/// - **Only while the card is open, and only for a line that references an issue.** A collapsed
///   card and a description with no `fixes #N` in it cost nothing — ``loadAcceptanceCriteria(using:)``
///   returns before it reaches the fetcher.
/// - **Once per pull request.** The fetched issues and the failures are held in memory here, keyed
///   by number, and cleared when the reviewer moves to a different pull request. Together with the
///   client's own ETag cache that is the whole of the caching story, and it is why ADR 0026's
///   amendment adds **no table**: an issue body is needed while the card is open and is worthless
///   afterwards, so a migration would buy a row that is stale the next time it is read and a
///   "delete on sign out" obligation to go with it.
/// - **Cancellable, and cancelled when the detail changes.** A reviewer who clicks through five
///   pull requests must not leave five reads running, and a read that lands after the screen has
///   moved on must not write into the new pull request's card.
/// - **The embedder is optional.** With no on-device model — or with none supplied —
///   ``ShepherdCore/AcceptanceMatcher`` runs its keyword pass alone, which is the complete
///   behaviour rather than a degraded one.
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

    /// The text the tier-2 pass has already been spent on (``readKey(for:)``).
    ///
    /// The description and the pull request, not the whole detail: a check finishing or a new
    /// thread changes the detail and not one word the model read, and a pass per sweep would be
    /// the unattended model feature ADR 0026 refuses.
    @ObservationIgnored private var readKey: String?

    /// What that pass read, so a routine refresh — which rebuilds the report from the patterns —
    /// folds it in again rather than asking the model a second time.
    @ObservationIgnored private var readList: ClaimList?

    /// The pass in flight, so a new pull request can stop one nobody will see the answer to.
    @ObservationIgnored private var readTask: Task<Void, Never>?

    /// The model's answer about this Mac, once it has been asked.
    @ObservationIgnored private var cachedAvailability: OnDeviceAvailability?

    /// The ask itself while it is in flight, so two expansions ask once.
    @ObservationIgnored private var availabilityTask: Task<OnDeviceAvailability, Never>?

    /// The issue read, when one was injected at construction time.
    private let issues: (any IssueFetching)?
    /// The embedding seam, for the matcher's optional cosine pass.
    private let embedder: (any EmbeddingProviding)?

    /// The issues this screen has read, keyed by number. Cleared when the pull request changes.
    private var issuesByNumber: [Int: IssueSummary] = [:]
    /// Why an issue could not be read, keyed by number. A failure is remembered so the read is
    /// not retried on every redraw.
    private var failuresByNumber: [Int: IssueLookupFailure] = [:]
    /// The matches, keyed by issue number. Cleared when the head commit changes, because the
    /// evidence text is built from the description, the paths and the commit messages.
    private var matchesByNumber: [Int: [AcceptanceMatch]] = [:]
    /// The embedder's answer about this Mac, once it has been asked.
    private var cachedEmbeddingAvailability: EmbeddingAvailability?
    /// The read in flight, so a detail change can cancel it.
    private var loadTask: Task<Void, Never>?

    /// What *Look closer* found, per line id (ADR 0026's 2026-09-22 amendment).
    ///
    /// Lives exactly as long as the review screen and the detail it was read from, like the rest
    /// of the card: nothing here is stored.
    private(set) var checks: [String: ClaimCheckState] = [:]

    /// What the checker said about this Mac, `nil` until it was asked — the same one-optional
    /// arrangement ``cachedAvailability`` uses for the extractor. Observed, because the answer
    /// is what makes the *Look closer* buttons appear.
    private var checkAvailability: OnDeviceAvailability?

    @ObservationIgnored private var checker: (any ClaimChecking)?
    @ObservationIgnored private var checkTasks: [String: Task<Void, Never>] = [:]

    /// Creates a model.
    /// - Parameters:
    ///   - issues: The issue read. `nil` — the default — is a card that never fetches, which is
    ///     what every screen without a signed-in session gets; a screen with one hands its client
    ///     to ``loadAcceptanceCriteria(using:)`` instead, because the session does not exist yet
    ///     when SwiftUI builds the `@State`.
    ///   - embedder: The embedding seam for the matcher's cosine pass. The default is the
    ///     on-device model — the same actor ⌘K search uses — and it loads nothing until a bullet
    ///     is actually embedded.
    init(
        issues: (any IssueFetching)? = nil,
        embedder: (any EmbeddingProviding)? = NaturalLanguageEmbedder()
    ) {
        self.issues = issues
        self.embedder = embedder
    }

    /// Rebuilds the report when the pull request's data changed, and does nothing when it did not.
    /// - Parameters:
    ///   - detail: The pull request, or `nil` while it is still loading.
    ///   - extractor: The tier-2 seam as it stands, or `nil` when the intelligence tiers are off
    ///     — in which case this model is exactly the tier-1 model it has always been.
    func refresh(
        detail: PullRequestDetail?,
        extractor: (any ClaimExtracting)? = nil,
        checker: (any ClaimChecking)? = nil
    ) {
        // Assigned before the guard: the reviewer can switch the tiers off while the same pull
        // request is on screen, and that has to reach the next expansion.
        self.extractor = extractor
        if checker == nil { checkAvailability = nil }
        self.checker = checker
        guard builtFrom != detail else { return }
        let previous = builtFrom
        builtFrom = detail
        // What the model pointed at belongs to the diff it read: a new head, or another pull
        // request, makes every note a pointer into lines that may no longer be there. A routine
        // refresh of the same head — a check finishing, a new thread — changes no line of it.
        if !ClaimsEvidenceModel.sameDiff(previous, detail) { cancelChecks() }
        // A pass for a pull request that is gone, or for a description that was edited: nobody
        // will see its answer, so it is stopped rather than left to finish on the battery, and
        // the new text gets its own pass when the reviewer opens the card. The same text keeps
        // its pass — in flight or done.
        let sameText = previous.map(ClaimsEvidenceModel.readKey(for:))
            == detail.map(ClaimsEvidenceModel.readKey(for:))
        let wasReading = state.isReading
        if !sameText {
            cancelReading()
            readKey = nil
            readList = nil
        }

        // A different pull request: the issue this screen read belongs to the old one, and the
        // read in flight for it has nowhere to land.
        if detail?.id != previous?.id {
            loadTask?.cancel()
            loadTask = nil
            issuesByNumber.removeAll()
            failuresByNumber.removeAll()
            matchesByNumber.removeAll()
        } else if detail?.summary.headRefOid != previous?.summary.headRefOid {
            // Same pull request, new head: the issue is still the issue, but what the pull
            // request says about itself has changed, so the matches have to be recomputed.
            matchesByNumber.removeAll()
        }

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
        if sameText, let detail {
            next.isReading = wasReading
            if let readList {
                next.report = ClaimsEvidenceModel.merging(readList, into: next.report, of: detail)
            }
        }
        state = next
        applyIssueEvidence()
    }

    /// What identifies the text a tier-2 pass reads: the pull request and its description.
    static func readKey(for detail: PullRequestDetail) -> String {
        "\(detail.id)|\(detail.bodyMarkdown.hashValue)"
    }

    // MARK: - The acceptance criteria

    /// Identifies the work ``loadAcceptanceCriteria(using:)`` would do, for a view's `task(id:)`.
    ///
    /// The pull request, its head commit, whether the card is open and which issues the card
    /// references — the four things a change in which means the read has to be reconsidered. The
    /// fourth is there for the tier-2 pass: a `fixes #N` the model found after the patterns ran
    /// is a new line with an issue behind it, and without it in the key the view's task would
    /// never fire for it. Everything else about the screen (the diff tab, a keystroke in the
    /// summary field, a redraw) leaves it alone, which is what keeps a `task(id:)` from
    /// restarting the read for no reason.
    var acceptanceLoadKey: String {
        guard let detail = builtFrom else { return "-" }
        let issues = referencedIssueNumbers.map(String.init).joined(separator: ",")
        return "\(detail.id)|\(detail.summary.headRefOid)|\(state.isExpanded)|\(issues)"
    }

    /// The issue numbers the report references, in the report's order and without duplicates.
    var referencedIssueNumbers: [Int] {
        var seen: Set<Int> = []
        var result: [Int] = []
        for line in state.lines {
            guard case .fixesIssue(let number) = line.claim.kind else { continue }
            guard seen.insert(number).inserted else { continue }
            result.append(number)
        }
        return result
    }

    /// Reads the referenced issues and matches their acceptance bullets against the pull request.
    ///
    /// Awaits the read, so a caller — a view's `task`, or a test — can act on the state that comes
    /// out of it rather than polling for one. Returns immediately, having asked GitHub nothing,
    /// when the card is collapsed, when the description references no issue, when there is no
    /// fetcher, or when every referenced issue has already been read or already failed on this
    /// screen.
    /// - Parameter fetcher: The screen's issue read. Wins over the one injected at construction
    ///   time, because it is how a view hands over the signed-in session's client — `nil` falls
    ///   back to the injected one, which is how a test drives this without a view.
    func loadAcceptanceCriteria(using fetcher: (any IssueFetching)? = nil) async {
        guard state.isExpanded, let detail = builtFrom else { return }
        guard let reader = fetcher ?? issues else { return }
        let numbers = referencedIssueNumbers
        guard !numbers.isEmpty else { return }
        // An issue that already failed is not asked about again on this screen; one that was read
        // but not yet matched still needs the matcher, which is how a new head commit gets a
        // fresh answer without a second network read.
        let outstanding = numbers.filter { number in
            guard failuresByNumber[number] == nil else { return false }
            return issuesByNumber[number] == nil || matchesByNumber[number] == nil
        }
        guard !outstanding.isEmpty else { return }

        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load(outstanding, in: detail, using: reader)
        }
        loadTask = task
        await task.value
    }

    /// Reads and matches one issue at a time, updating the card after each.
    ///
    /// One at a time rather than in a group: a description references one issue in all but a
    /// handful of cases, and the reviewer sees the first line resolve while the second is still
    /// being read. Every step checks for cancellation, because the answer belongs to the pull
    /// request this call started on and to no other.
    private func load(
        _ numbers: [Int],
        in detail: PullRequestDetail,
        using reader: any IssueFetching
    ) async {
        for number in numbers {
            guard !Task.isCancelled else { return }

            if issuesByNumber[number] == nil, failuresByNumber[number] == nil {
                do {
                    let summary = try await reader.issue(repo: detail.repo, number: number)
                    guard !Task.isCancelled else { return }
                    issuesByNumber[number] = summary
                } catch {
                    guard !Task.isCancelled else { return }
                    failuresByNumber[number] = ClaimsEvidenceModel.failure(for: error)
                }
            }

            if let issue = issuesByNumber[number], matchesByNumber[number] == nil {
                // A pull request has no acceptance criteria, and a task list in one is not a
                // checklist of them: no bullets, and the card says why.
                let bullets: [AcceptanceBullet] = issue.isPullRequest
                    ? []
                    : AcceptanceCriteria.bullets(from: issue.bodyMarkdown)
                if bullets.isEmpty {
                    matchesByNumber[number] = []
                } else {
                    let evidence = AcceptanceMatcher.evidenceText(for: detail)
                    let vectors = await self.vectors(for: bullets, evidenceText: evidence)
                    guard !Task.isCancelled else { return }
                    matchesByNumber[number] = AcceptanceMatcher.match(
                        bullets: bullets,
                        against: evidence,
                        vectors: vectors
                    )
                }
            }

            guard !Task.isCancelled else { return }
            applyIssueEvidence()
        }
    }

    /// Embeds the bullets and the evidence text, when this Mac can.
    ///
    /// `nil` is a normal outcome with a single meaning — the matcher runs its keyword pass alone —
    /// and there is deliberately nothing to report and nothing to print: a card that appeared with
    /// a warning in it because an embedding did not happen would be a worse card.
    private func vectors(
        for bullets: [AcceptanceBullet],
        evidenceText: String
    ) async -> AcceptanceVectors? {
        guard let embedder else { return nil }
        let availability: EmbeddingAvailability
        if let cached = cachedEmbeddingAvailability {
            availability = cached
        } else {
            availability = await embedder.availability()
            cachedEmbeddingAvailability = availability
        }
        guard case .available = availability else { return nil }
        guard let evidence = await embedder.vector(for: evidenceText) else { return nil }

        var byBulletText: [String: SearchVector] = [:]
        for bullet in bullets {
            guard !Task.isCancelled else { return nil }
            // A bullet the model has nothing to say about is skipped rather than stored as a zero
            // vector: a zero would be comparable to everything and rank as related to nothing.
            guard let vector = await embedder.vector(for: bullet.text) else { continue }
            byBulletText[bullet.text] = vector
        }
        guard !byBulletText.isEmpty else { return nil }
        return AcceptanceVectors(evidence: evidence, byBulletText: byBulletText)
    }

    /// Rewrites every issue line of the current report from what this screen has read.
    ///
    /// Only the verdict of an issue line is replaced, and nothing else about the state is touched:
    /// a reviewer looking at the replace-or-append question when the issue lands must not have it
    /// taken away, and the three other claims' evidence has not changed.
    ///
    /// A line is rewritten only once its answer is *complete* — a failure, or an issue **and** its
    /// matches. An issue that has been read but not yet matched (which is the state for a moment
    /// after a fix round invalidates the matches) keeps the "not fetched" line rather than briefly
    /// claiming the issue holds no checklist.
    private func applyIssueEvidence() {
        guard let detail = builtFrom else { return }
        guard !issuesByNumber.isEmpty || !failuresByNumber.isEmpty else { return }
        for index in state.report.lines.indices {
            let line = state.report.lines[index]
            guard case .fixesIssue(let number) = line.claim.kind else { continue }
            let hasAnswer = failuresByNumber[number] != nil
                || (issuesByNumber[number] != nil && matchesByNumber[number] != nil)
            guard hasAnswer else { continue }
            state.report.lines[index].verdict = EvidenceChecker.check(
                line.claim,
                in: detail,
                issue: issuesByNumber[number],
                matches: matchesByNumber[number],
                failure: failuresByNumber[number]
            )
        }
    }

    /// Which of ``ShepherdCore/IssueLookupFailure``'s four answers a failed read gets.
    ///
    /// The mapping lives here because this is the only layer that can see both types: the failure
    /// is a `ShepherdCore` case that travels inside an evidence fact and the error is
    /// `GitHubKit`'s. A rate limit is `failed` rather than `offline` — GitHub was reached and
    /// answered, and "could not be reached" would be the wrong sentence to put on the card.
    /// - Parameter error: Whatever the read threw.
    /// - Returns: The classification.
    static func failure(for error: any Error) -> IssueLookupFailure {
        guard let github = error as? GitHubError else { return .failed }
        switch github {
        case .notFound:
            return .notFound
        case .forbidden, .unauthorized, .missingToken:
            return .noPermission
        case .transport:
            return .offline
        default:
            return .failed
        }
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
        let key = ClaimsEvidenceModel.readKey(for: detail)
        guard readKey != key else { return }
        // Marked spent before the pass starts, which is what makes "once" true rather than
        // likely: a second expansion arriving while this one is generating finds it spent.
        readKey = key
        state.isReading = true
        let body = detail.bodyMarkdown
        let task = Task { [weak self] in
            let list = try? await extractor.extract(from: body)
            guard !Task.isCancelled else { return }
            self?.finishReading(list, for: detail)
        }
        readTask = task
        // The pass is its own task so that `cancelReading()` has something to cancel, and this
        // handler is what ties it back to the caller: the card's `.task(id:)` is cancelled when
        // the reviewer collapses the card or the pull request changes, and an unstructured child
        // would otherwise finish on the battery and fold its answer into a card nobody opened.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled, readTask == task {
            // Cancelled from outside, so nothing was folded in and nothing was really spent: the
            // spinner comes down, and the next expansion earns a new pass.
            cancelReading()
            readKey = nil
        }
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
        guard let current = builtFrom,
              ClaimsEvidenceModel.readKey(for: current) == ClaimsEvidenceModel.readKey(for: detail)
        else { return }
        readTask = nil
        state.isReading = false
        guard let list, !list.isEmpty else { return }
        readList = list
        // Folded into the report of the detail on screen now, which may be a routine refresh
        // newer than the one the pass started from: the text is the same, the evidence is newer.
        state.report = ClaimsEvidenceModel.merging(list, into: state.report, of: current)
        // A model claim about an issue this screen has already read gets that issue's answer too.
        applyIssueEvidence()
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

// MARK: - Look closer (ADR 0026's 2026-09-22 amendment, ADR 0038 item 2)

/// Where one line's *Look closer* stands.
enum ClaimCheckState: Equatable, Sendable {
    /// The on-device session is reading the diff.
    case checking
    /// What it pointed at, already located in the diff by Shepherd.
    case done(ClaimCheck)
    /// Why there is no answer, in the tier's own words. The reviewer asked, so this is said.
    case failed(String)
}

extension ClaimsEvidenceModel {
    /// Asks the checker once per screen whether this Mac can look closer.
    func prepareCheckAvailability() async {
        guard let checker, checkAvailability == nil else { return }
        checkAvailability = await checker.availability()
    }

    /// Whether *Look closer* is offered on this line: only where Shepherd's own evidence
    /// contradicts the claim or is not enough, because a ✓ line already carries the facts that
    /// support it, and only once per line and detail.
    func canCheck(_ line: ClaimsEvidenceReport.Line) -> Bool {
        guard checkAvailability == .available, builtFrom != nil else { return false }
        guard line.verdict.status != .ok else { return false }
        // The button captured this line when it was drawn; a refresh since then may have put
        // another pull request's claim of the same kind under the same id.
        guard state.lines.contains(line) else { return false }
        switch checks[line.id] {
        case nil, .failed: return true
        case .checking, .done: return false
        }
    }

    /// Reads the diff for one line, on the reviewer's click.
    func check(_ line: ClaimsEvidenceReport.Line) async {
        guard canCheck(line), let checker, let detail = builtFrom else { return }
        let id = line.id
        checks[id] = .checking
        let task = Task { [weak self] in
            let state: ClaimCheckState
            do {
                state = .done(try await checker.check(line, in: detail))
            } catch {
                state = .failed(error.userFacingDescription)
            }
            guard !Task.isCancelled, let self,
                  ClaimsEvidenceModel.sameDiff(self.builtFrom, detail)
            else { return }
            self.checks[id] = state
            self.checkTasks[id] = nil
        }
        checkTasks[id] = task
        await task.value
    }

    /// Whether two details show the same diff: the same pull request at the same head.
    static func sameDiff(_ lhs: PullRequestDetail?, _ rhs: PullRequestDetail?) -> Bool {
        lhs?.id == rhs?.id && lhs?.summary.headRefOid == rhs?.summary.headRefOid
    }

    /// Stops every check in flight and forgets every answer.
    func cancelChecks() {
        for task in checkTasks.values { task.cancel() }
        checkTasks.removeAll()
        checks.removeAll()
    }
}
