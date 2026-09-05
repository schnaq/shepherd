import Foundation
import GitHubKit
import Observation
import ShepherdCore
import ShepherdPersistence

/// Drives the full-window review screen.
///
/// Like the inbox, it renders from the database: the detail comes out of SQLite first and is
/// refreshed from GitHub in the background, and the pending review is a `ValueObservation` on
/// the drafts table so a crash cannot lose a comment (ADR 0006).
@MainActor
@Observable
final class ReviewModel {
    /// Everything the review screen can refuse to do, with a reason the user can act on.
    enum Failure: LocalizedError, Equatable {
        /// The comment was anchored to a line that is not part of the diff.
        case lineNotInDiff(line: Int, side: DiffSide)

        var errorDescription: String? {
            switch self {
            case .lineNotInDiff(let line, let side):
                let sideName = side == .left
                    ? String(localized: "base")
                    : String(localized: "head")
                return String(
                    localized: "Line \(line) of the \(sideName) side is not part of this diff. GitHub only accepts comments on lines the patch actually contains."
                )
            }
        }
    }

    /// A request to open the native comment composer on a diff line.
    struct ComposerRequest: Identifiable, Hashable {
        /// Identity for `sheet(item:)`.
        var id: String { "\(path):\(side.rawValue):\(startLine ?? line):\(line)" }
        /// The file being commented on.
        var path: String
        /// The (last) line.
        var line: Int
        /// Which side of the diff.
        var side: DiffSide
        /// The first line of a multi-line selection.
        var startLine: Int?

        /// The same anchor, as the intelligence layer wants it.
        var anchor: InlineCommentAnchor {
            InlineCommentAnchor(path: path, line: line, side: side, startLine: startLine)
        }
    }

    /// Which tab the right-hand area shows.
    enum Tab: String, CaseIterable, Identifiable {
        /// The Monaco diff.
        case files
        /// Description, commits and checks.
        case conversation

        var id: String { rawValue }

        /// The segmented-control label.
        var title: String {
            switch self {
            case .files: return String(localized: "Files")
            case .conversation: return String(localized: "Conversation")
            }
        }
    }

    /// What the banner above the review screen says, when GitHub has moved on without it.
    ///
    /// One slot for three facts, because they are the same kind of fact: something happened on
    /// GitHub that this screen cannot simply absorb. Which one is showing also decides whether
    /// the screen still takes a verdict — see ``ReviewModel/hasEndedOnGitHub``.
    enum Notice: Equatable {
        /// The head branch was pushed to, with how many commits are new when that is derivable.
        case newCommits(count: Int?)
        /// The pull request was merged on GitHub.
        case merged
        /// The pull request was closed on GitHub without being merged.
        case closed

        /// Whether this is the end of the pull request, so no verdict and no merge can land on
        /// it any more.
        var endsTheReview: Bool {
            switch self {
            case .merged, .closed: return true
            case .newCommits: return false
            }
        }

        /// Whether the banner draws a Reload — only a push has anything to reload into.
        var offersReload: Bool {
            if case .newCommits = self { return true }
            return false
        }
    }

    /// What an observed detail does to the one already on screen.
    enum ObservedChange: Equatable {
        /// Nothing a reviewer can see moved, so nothing happens at all.
        case unchanged
        /// The same head commit, so the diff is byte-identical and the volatile facts can be
        /// folded in where the reviewer is standing.
        case refresh
        /// A different head commit, so the fresh detail waits behind the banner.
        case newCommits(count: Int?)
    }

    /// The active session.
    let session: SignedInSession
    /// Preferences (diff mode, wrap, font size).
    let settings: AppSettings
    /// The pull request's node id.
    let prID: String

    /// The pull request, from the cache and then from GitHub.
    private(set) var detail: PullRequestDetail?
    /// Deterministic priorities for the file list.
    private(set) var priorities: [FilePriority] = []
    /// The locally drafted review, observed from the database.
    private(set) var draft: ReviewDraft?
    /// The paths the user marked as viewed at the current head commit.
    private(set) var viewedPaths: Set<String> = []
    /// AI focus hints, when a provider is configured.
    private(set) var focusOutcome: IntelligenceOutcome<[FocusHint]> = .disabled
    /// Whether a refresh is in flight.
    private(set) var isRefreshing = false
    /// Whether a submit is in flight.
    private(set) var isSubmitting = false
    /// What the banner above the screen is saying, or `nil` when GitHub has said nothing new.
    private(set) var notice: Notice?
    /// The fresh detail behind a ``Notice/newCommits(count:)``, waiting for Reload.
    ///
    /// Held rather than applied, and that is the whole of behaviour rule two: every inline
    /// comment in the pending review is anchored to a line number of the head commit on screen,
    /// and GitHub refuses — or worse, misplaces — a comment whose line is not part of the diff it
    /// is submitted against. So a push is *announced*; swapping the document under the reviewer's
    /// cursor is the one thing a background observation must never do.
    private var pendingDetail: PullRequestDetail?
    /// Whether the pull request's inbox row has gone.
    ///
    /// The prune's own signal that the pull request left the user's search (ADR 0027), and half
    /// of what the "merged"/"closed" banner needs; ``observedOutcome`` is the other half.
    private var hasLeftTheInbox = false
    /// How the pull request ended, when the sweep has read it (ADR 0027).
    private var observedOutcome: PullRequestOutcome?

    /// Set when the pull request is not (or no longer) in the local inbox.
    ///
    /// A sweep prunes everything its search did not return — a merged pull request, or one
    /// past the search's page cap — and the detail rows cascade away with it. Without this the
    /// screen sat on a `ProgressView` forever.
    private(set) var isMissingFromInbox = false

    /// The file being shown in the diff viewer.
    var selectedPath: String? {
        // ``selectedDiffRow`` is an index into *this* file's rows, so it cannot survive the file
        // changing: the same index in the next file names an unrelated line, and a shorter file
        // would leave it past the end. Compared against the old value because a background
        // refresh re-selects the same path routinely, and that must not throw away a cursor the
        // reviewer is standing on.
        didSet { if selectedPath != oldValue { selectedDiffRow = nil } }
    }
    /// A line the viewer should scroll to once it has the file.
    ///
    /// Set by ``reveal(path:line:)`` — the CI diagnosis card's `file:line` link — and by nothing
    /// else. It is deliberately not cleared afterwards: the viewer only acts on a *change* of
    /// this value, so clearing it would either do nothing or cost a second command for no reason.
    private(set) var revealLine: Int?
    /// How many times the keyboard has asked to be moved into the diff editor.
    ///
    /// A counter rather than a flag, for ``DiffViewerView/focusRequest``'s reason: handing the
    /// focus over is an event, and asking twice has to send twice.
    private(set) var focusEditorRequest = 0
    /// Which pane the most recent ``requestEditorFocus(side:)`` asked for.
    ///
    /// Read only when ``focusEditorRequest`` advances, so it cannot go stale on its own.
    private(set) var focusEditorSide: BridgeSide = .right
    /// Which tab is showing.
    ///
    /// Written only through ``setTab(_:)``, for ``roundView``'s reason: which tab a review opens
    /// on is a decision made once, and every path that changes it afterwards is the reviewer
    /// saying so.
    private(set) var tab: Tab = .files
    /// Which round the file list and the diff viewer are showing (ADR 0028).
    private(set) var roundView: RoundView = .all {
        // The other half of the reset above: the two rounds are two different documents of the
        // same file, so a row index means something else in each of them.
        didSet { if roundView != oldValue { selectedDiffRow = nil } }
    }
    /// The row the native diff list is standing on, as an index into its rows.
    ///
    /// Session-only and deliberately not persisted: it is a cursor, not a preference, and a
    /// reviewer coming back to a pull request tomorrow wants the top of the file rather than the
    /// line they happened to leave. It is cleared whenever the file or the round changes — see
    /// the two `didSet`s above — because both of those change which rows exist, and clamped into
    /// the rows a refresh leaves behind by ``clampDiffRowSelection()``, which is where the
    /// difference between the two is argued.
    private(set) var selectedDiffRow: Int?
    /// What changed since the head this reviewer last reviewed, when a baseline exists.
    private(set) var round: SinceReviewRound?
    /// Review priorities of the interdiff's files.
    ///
    /// The same prioritiser the full file list uses, run over the synthesized round files, so
    /// "Since your review" orders and buckets its list the way the reviewer is used to instead
    /// of inventing a second order.
    private(set) var interdiffPriorities: [FilePriority] = []
    /// The composer request currently open, if any.
    var composerRequest: ComposerRequest?
    /// The thread whose conversation popover is open, if any.
    var activeThreadID: String?
    /// Whether the submit sheet is up.
    var isSubmitSheetPresented = false
    /// Whether the merge sheet is up.
    var isMergeSheetPresented = false
    /// The verdict picked in the submit sheet.
    var pendingVerdict: ReviewVerdict = .comment
    /// The summary text typed in the submit sheet.
    var summaryText = ""

    /// The provider router.
    var intelligence: IntelligenceRouter = .disabled

    /// The two-keystroke state machine (`r a`, `r x`, `r c`, `m`).
    private var keySequence = KeySequenceState()

    /// Feeds a character into the two-keystroke state machine.
    /// - Parameter character: The typed character.
    /// - Returns: What it resolved to.
    func keySequenceResult(for character: Character) -> KeySequenceState.Resolution {
        keySequence.consume(character)
    }

    /// Whether the next keystroke completes a two-key sequence.
    ///
    /// Asked before any bare-key handling, because `c` is claimed twice over: `r c` submits the
    /// review as a comment, and `c` alone hands the keyboard to the diff.
    var isAwaitingSecondKey: Bool { keySequence.isAwaitingSecondKey() }

    /// Whether the draft observation has delivered at least one value.
    ///
    /// The template must not be applied before this: the observation is what tells the model
    /// whether a draft exists at all, and a template written into ``summaryText`` while the answer
    /// is still unknown would *also* stop the arriving draft's own summary from being shown (the
    /// observation only fills an empty field). So "no draft yet" is treated as "not known yet"
    /// until the stream has spoken once.
    private var hasObservedDraft = false
    /// Whether the per-repository template has already been offered on this screen.
    ///
    /// One shot per opened review. Without it, every refresh of the detail would re-fill a summary
    /// the user had deliberately cleared.
    private var hasOfferedTemplate = false

    /// Whether the reviewer picked a round view themselves.
    ///
    /// Once they have, a background refresh must not move them back: the default is only a
    /// default, and it is decided once per opened review.
    private var hasChosenRoundView = false

    /// Whether the tab this review opens on has been decided.
    ///
    /// ``hasChosenRoundView``'s twin, and it exists for exactly the same once-only reason. Set by
    /// the first detail to arrive *and* by ``setTab(_:)``, which covers both halves of "only at
    /// open": the cached detail and the fresh fetch behind it are one open rather than two, a
    /// live refresh and a Reload after a push are not an open at all, and a reviewer who reached
    /// for the picker while the fetch was still in flight has already said where they want to be.
    private var hasChosenTab = false

    private var draftTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var outcomeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var intelligenceTask: Task<Void, Never>?
    private var roundTask: Task<Void, Never>?

    /// Called after a detail fetch has been stored, with the pull request's node id.
    ///
    /// Exists for one consumer, the search index (ADR 0019): storing a detail is the moment a
    /// pull request's description and diff become searchable, and the coordinator would otherwise
    /// learn about it only on the next sweep. Imperative and read by nothing, so it stays out of
    /// the observation graph — the same treatment `AppEnvironment`'s routing closures get.
    @ObservationIgnored var onDidLoadDetail: (@MainActor (String) -> Void)?

    /// Creates the model.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - settings: The preference store.
    ///   - prID: The pull request's node id.
    init(session: SignedInSession, settings: AppSettings, prID: String) {
        self.session = session
        self.settings = settings
        self.prID = prID
    }

    // MARK: - Loading

    /// Loads the cached detail, then refreshes it, and starts observing.
    ///
    /// Three streams rather than one fetch: the draft the reviewer is writing, the pull request
    /// itself, and — for the one fact the pull request stops being able to carry — how it ended.
    /// Everything after the first fetch arrives through them, which is what makes an open review
    /// screen stop being a photograph of the moment it was opened.
    func start() {
        observeDraft()
        observeDetail()
        observeOutcome()
        load()
    }

    /// Cancels every background task.
    func stop() {
        draftTask?.cancel()
        draftTask = nil
        detailTask?.cancel()
        detailTask = nil
        outcomeTask?.cancel()
        outcomeTask = nil
        loadTask?.cancel()
        loadTask = nil
        intelligenceTask?.cancel()
        intelligenceTask = nil
        roundTask?.cancel()
        roundTask = nil
    }

    /// Reloads from the cache and from GitHub.
    func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let cached = try? await self.session.database.fetchPullRequestDetail(id: self.prID) {
                self.apply(cached)
            }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            // The row is normally in the inbox table even when no detail has been fetched yet.
            // When it is not, the sweep pruned it: say so instead of spinning forever.
            guard let row = try? await self.session.database.fetchPullRequestSummary(id: self.prID)
            else {
                self.isMissingFromInbox = self.detail == nil
                return
            }
            self.isMissingFromInbox = false
            if let fresh = try? await self.session.github.pullRequestDetail(
                repo: row.repo,
                number: row.number
            ) {
                try? await self.session.database.savePullRequestDetail(fresh)
                guard !Task.isCancelled else { return }
                self.apply(fresh)
                self.onDidLoadDetail?(self.prID)
            }
        }
    }

    private func observeDraft() {
        guard draftTask == nil else { return }
        let stream = session.database.observeDraft(prID: prID)
        draftTask = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.draft = value
                self.hasObservedDraft = true
                if self.summaryText.isEmpty, let body = value?.summaryBody, !body.isEmpty {
                    self.summaryText = body
                }
                self.applyReviewTemplateIfNeeded()
            }
        }
    }

    private func observeDetail() {
        guard detailTask == nil else { return }
        let stream = session.database.observePullRequestDetail(prID: prID)
        detailTask = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.received(value)
            }
        }
    }

    private func observeOutcome() {
        guard outcomeTask == nil else { return }
        let stream = session.database.observePullRequestOutcome(prID: prID)
        outcomeTask = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.observedOutcome = value
                self.noteEndOnGitHub()
            }
        }
    }

    /// Decides what an observed detail does to a review that is already open.
    ///
    /// The head commit is the whole rule (behaviour rules one and two). Same head, and the diff
    /// is byte-identical, so everything the pull request's *state* can do — checks, review
    /// decision, mergeability, new threads and replies — is applied in place and the reviewer
    /// notices nothing. Different head, and the document the pending review is anchored against
    /// has been replaced, so the screen says so and waits.
    /// - Parameter fresh: What the database now holds, or `nil` when the row has gone.
    private func received(_ fresh: PullRequestDetail?) {
        guard let fresh else {
            // The inbox row was pruned and the detail cascaded with it. What is deliberately not
            // done here is clearing ``detail``: blanking a diff somebody is reading is the worst
            // possible way to tell them the pull request was merged, and the banner tells them
            // without taking anything away.
            hasLeftTheInbox = true
            noteEndOnGitHub()
            return
        }
        if hasLeftTheInbox {
            // The row came back — reopened, or simply matching the user's facets again — so what
            // the banner said about its end has stopped being true.
            hasLeftTheInbox = false
            if hasEndedOnGitHub { notice = nil }
        }
        guard let shown = detail else {
            apply(fresh)
            return
        }
        switch ReviewModel.change(shown: shown, fresh: fresh) {
        case .unchanged:
            return
        case .newCommits(let count):
            // A pull request that has ended keeps its banner: reloading the diff of a merged pull
            // request is of no use to anybody, and the sentence that matters is the other one.
            guard !hasEndedOnGitHub else { return }
            pendingDetail = fresh
            notice = .newCommits(count: count)
        case .refresh:
            refresh(fresh, replacing: shown)
        }
    }

    /// Classifies an observed detail against the one on screen.
    ///
    /// The head commit is the whole rule, and the equality check in front of it is behaviour rule
    /// five: the sweep rewrites the whole detail whenever anything about the pull request moved,
    /// and the reviewer's own submitted review is one of the things that moves it, so a value
    /// equal to the one on screen is the ordinary case rather than the odd one and must produce
    /// no event of any kind.
    ///
    /// Pure and `static` so the three answers are unit-tested rather than inferred from task
    /// ordering, the same treatment ``defaultRoundView(for:)`` gets.
    /// - Parameters:
    ///   - shown: The detail the screen is showing.
    ///   - fresh: The detail the database now holds.
    /// - Returns: What the screen should do with it.
    static func change(shown: PullRequestDetail, fresh: PullRequestDetail) -> ObservedChange {
        guard fresh != shown else { return .unchanged }
        guard fresh.summary.headRefOid == shown.summary.headRefOid else {
            return .newCommits(count: newCommitCount(shown: shown.commits, fresh: fresh.commits))
        }
        return .refresh
    }

    /// Puts "merged" or "closed" in the banner once both halves of that fact are known.
    ///
    /// Both halves, because neither is enough on its own: an outcome row is never deleted, so a
    /// pull request that was closed and then reopened still has one and it describes the previous
    /// ending; and a vanished inbox row means only that the search stopped returning the pull
    /// request, which happens to open ones too when the user's facets stop matching. A pull
    /// request that leaves the inbox while still open therefore changes nothing on this screen,
    /// which is right — it is still open, and the review still submits.
    private func noteEndOnGitHub() {
        guard let ended = ReviewModel.endNotice(
            hasLeftTheInbox: hasLeftTheInbox,
            outcome: observedOutcome
        ) else { return }
        notice = ended
        // Nothing to reload into: the diff on screen is the last one there will ever be.
        pendingDetail = nil
    }

    /// What a vanished inbox row and a stored outcome say when they are read together.
    ///
    /// Pure and `static` for ``change(shown:fresh:)``'s reason, and the pairing is the point: an
    /// outcome alone is not an ending, and a vanished row alone is not one either.
    /// - Parameters:
    ///   - hasLeftTheInbox: Whether the prune has removed the pull request's row.
    ///   - outcome: The stored outcome, when there is one.
    /// - Returns: The banner's sentence, or `nil` when the pull request has not ended.
    static func endNotice(hasLeftTheInbox: Bool, outcome: PullRequestOutcome?) -> Notice? {
        guard hasLeftTheInbox, let outcome else { return nil }
        return outcome.merged ? .merged : .closed
    }

    /// Applies an observed detail that shares the head commit the screen is showing.
    ///
    /// The half of ``apply(_:)`` that is safe to run under a reviewer's cursor. What it leaves
    /// alone is everything that is theirs rather than GitHub's: ``selectedPath``,
    /// ``selectedDiffRow``, ``tab``, ``roundView``, ``summaryText`` and the open composer are
    /// untouched, and so are the two once-per-opened-review decisions ``apply(_:)`` also makes —
    /// ``requestFocusHints(for:)``, which would re-ask a provider on every sweep, and
    /// ``applyReviewTemplateIfNeeded()``, whose guards exist for exactly this reason.
    ///
    /// The interdiff is recomputed only when the threads moved, because that is the only input to
    /// it that can move while the head does not: both rounds' files are what they were, so the
    /// diff itself cannot have changed and only a finding's state can (ADR 0028). The baseline is
    /// never touched here at all.
    /// - Parameters:
    ///   - fresh: The detail to fold in.
    ///   - shown: The detail it replaces, for the one comparison this has to make.
    private func refresh(_ fresh: PullRequestDetail, replacing shown: PullRequestDetail) {
        let threadsMoved = fresh.threads != shown.threads
        detail = fresh
        priorities = FilePrioritizer.prioritize(
            fresh.files,
            context: PrioritizationContext(totalChangedLines: fresh.summary.churn)
        )
        viewedPaths = Set(fresh.files.filter(\.isViewed).map(\.path))
        if threadsMoved {
            loadRound(for: fresh)
        }
    }

    /// Applies the update the banner is holding back, and clears the banner.
    ///
    /// The full ``apply(_:)`` this time, because the head moved: the files, their priorities and
    /// the interdiff are all about a different set of commits than the ones that were on screen.
    /// ADR 0028's baseline is not disturbed by this — the round is recomputed against the *stored*
    /// snapshot of the head this reviewer reviewed, which is precisely what has to stay put while
    /// the branch moves on top of it.
    func reloadPendingUpdate() {
        guard let update = pendingDetail else { return }
        apply(update)
    }

    /// How many commits the observed detail has that the one on screen did not.
    ///
    /// `nil` when either side carries no commit list, because a detail fetch that learned nothing
    /// about the commits would otherwise make every one of them look new — and `nil` again when
    /// the count comes out at zero, because a banner reading "0 new commits" says less than the
    /// bare sentence does.
    ///
    /// A force-push therefore counts the whole branch, which is deliberate: a rebase replaces
    /// every commit, and every one of the replacements is a commit this reviewer has not seen.
    ///
    /// Pure and `static` so the number in the banner is unit-tested rather than inferred from task
    /// ordering, the same treatment ``defaultRoundView(for:)`` gets.
    /// - Parameters:
    ///   - shown: The commits of the head on screen.
    ///   - fresh: The commits of the head GitHub now has.
    /// - Returns: The number of new commits, or `nil` when none can be named.
    static func newCommitCount(shown: [CommitInfo], fresh: [CommitInfo]) -> Int? {
        guard !shown.isEmpty, !fresh.isEmpty else { return nil }
        let known = Set(shown.map(\.oid))
        let count = fresh.filter { !known.contains($0.oid) }.count
        return count > 0 ? count : nil
    }

    /// Fills the summary from the repository's review template, if the rules allow it.
    ///
    /// Called from the two places that can complete the picture — the draft observation and the
    /// arrival of the pull-request detail (which is where the repository comes from) — because
    /// either can win the race. The decision itself is
    /// ``ShepherdCore/ReviewTemplate/prefill(templates:repo:draft:summaryText:)``: a pure function,
    /// so the "never overwrite a draft" rule is unit-tested rather than inferred from task ordering.
    private func applyReviewTemplateIfNeeded() {
        guard !hasOfferedTemplate, hasObservedDraft, let repo = summary?.repo else { return }
        // Asked and answered, whatever the answer is: the template is a *starting point*, so it is
        // offered when the review opens and never again while it stays open. Anything else would
        // let a background refresh put the checklist back after the user deleted it.
        hasOfferedTemplate = true
        guard let body = ReviewTemplate.prefill(
            templates: settings.reviewTemplates,
            repo: repo,
            draft: draft,
            summaryText: summaryText
        ) else { return }
        summaryText = body
    }

    private func apply(_ detail: PullRequestDetail) {
        // Applying *is* the answer to the banner, from wherever the call came: what was being
        // held back is now what the screen shows. The "it ended" notice is the one that survives,
        // because it is not about a document anybody could reload.
        pendingDetail = nil
        if !hasEndedOnGitHub { notice = nil }
        self.detail = detail
        // The one place the tab default is spent, and the flag is what keeps it to the *first*
        // detail: this function runs again for the fresh fetch behind the cached row, for the
        // banner's Reload, and for nothing a reviewer would call a new open.
        if !hasChosenTab {
            hasChosenTab = true
            tab = ReviewModel.defaultTab(
                for: detail,
                opensAgentPullRequestsOnConversation: settings.opensAgentPullRequestsOnConversation
            )
        }
        priorities = FilePrioritizer.prioritize(
            detail.files,
            context: PrioritizationContext(totalChangedLines: detail.summary.churn)
        )
        viewedPaths = Set(detail.files.filter(\.isViewed).map(\.path))
        clampSelection()
        requestFocusHints(for: detail)
        loadRound(for: detail)
        // The repository only becomes known here, and the draft observation may already have run.
        applyReviewTemplateIfNeeded()
    }

    /// Keeps ``selectedPath`` on a file the current round view actually lists.
    private func clampSelection() {
        if selectedPath == nil
            || !visiblePriorities.contains(where: { $0.file.path == selectedPath }) {
            selectedPath = visiblePriorities.first?.file.path
        }
        // After the path, never before: assigning it clears the row cursor when the file actually
        // changed, and what is left to do here is the case that assignment cannot see.
        clampDiffRowSelection()
    }

    /// Keeps ``selectedDiffRow`` inside the rows that now exist.
    ///
    /// The two `didSet`s clear the cursor when the *file* or the *round* changes, because a row
    /// index means something else in a different document. Neither fires when a refresh replaces
    /// ``detail`` with a newly fetched patch of the same file in the same round — and that patch
    /// can have fewer rows, or the same rows shifted by a hunk that grew.
    ///
    /// Clamped rather than reset, and that is the decision worth stating. The index staying in
    /// bounds is not the problem — nothing crashes, and ``DiffListContent/anchor(for:)`` re-reads
    /// the row it now names, so no comment can land on the wrong line. What drifts is the
    /// cursor's *meaning*, and resetting to the top would answer that by throwing away the place
    /// a reviewer is standing on every time a background sweep lands, which is the worse of the
    /// two: a cursor that moved a line or two is recoverable with `j` and `k`, a cursor sent back
    /// to the top of a nine-hundred-line diff is not.
    private func clampDiffRowSelection() {
        // The cursor first, the rows second: rebuilding them parses the patch, and a review with
        // no cursor in the list — every review the rich viewer is drawing — has nothing to clamp.
        guard let current = selectedDiffRow else { return }
        guard let rows = selectedListContent?.rows, !rows.isEmpty else {
            selectedDiffRow = nil
            return
        }
        selectedDiffRow = min(current, rows.count - 1)
    }

    // MARK: - Since your review (ADR 0028)

    /// Reads the baseline and computes the interdiff for the detail that just arrived.
    ///
    /// Off the main actor because it reads SQLite and diffs text; the result is applied back
    /// here. Nothing is fetched — the baseline is local, which is the whole point of storing it
    /// at submit time.
    /// - Parameter detail: The pull request as it is now.
    private func loadRound(for detail: PullRequestDetail) {
        roundTask?.cancel()
        let database = session.database
        let viewerLogin = session.account.login
        roundTask = Task { [weak self] in
            let computed = await SinceReviewLoader.load(
                database: database,
                detail: detail,
                viewerLogin: viewerLogin
            )
            guard let self, !Task.isCancelled else { return }
            self.apply(round: computed)
        }
    }

    private func apply(round computed: SinceReviewRound?) {
        self.round = computed
        interdiffPriorities = FilePrioritizer.prioritize(
            computed?.changedFiles ?? [],
            context: PrioritizationContext(
                totalChangedLines: (computed?.changedFiles ?? []).reduce(0) { $0 + $1.churn }
            )
        )
        if !hasChosenRoundView {
            roundView = ReviewModel.defaultRoundView(for: computed)
        } else if roundView == .sinceReview, computed?.isOffered != true {
            // The tab the reviewer chose stopped existing — the pull request was reset to the
            // head they reviewed, or the baseline became unreadable.
            roundView = .all
        }
        clampSelection()
    }

    /// Which round view a review opens on.
    ///
    /// "Since your review" whenever there is something to show there — a stored baseline *and*
    /// a head that has moved past it — because that is the question a fix round poses; the whole
    /// pull request otherwise, which is every first review (ADR 0028).
    ///
    /// Pure and `static` so the default is unit-tested rather than inferred from task ordering.
    /// - Parameter round: The computed round, or `nil` when there is no baseline.
    /// - Returns: The view to open on.
    static func defaultRoundView(for round: SinceReviewRound?) -> RoundView {
        round?.isOffered == true ? .sinceReview : .all
    }

    /// Switches the file list and the diff viewer between the rounds.
    /// - Parameter view: The view the reviewer picked.
    func setRoundView(_ view: RoundView) {
        guard view != roundView else { return }
        hasChosenRoundView = true
        roundView = view
        clampSelection()
    }

    // MARK: - Which tab a review opens on

    /// Which tab a review opens on.
    ///
    /// Conversation for an agent's pull request whose description actually claims something,
    /// Files for everything else — which is every human pull request, and every agent one whose
    /// description asserts nothing to check. The reason is ADR 0026's amendment: the
    /// claims-vs-evidence card is the one surface in the app that knows something github.com does
    /// not, and putting it a click away on every single pull request buried the difference.
    ///
    /// **"An agent wrote it"** is ``ShepherdCore/ActorKind/agentIdentity`` being non-`nil` — the
    /// same test the card's own expansion, ``ShepherdCore/AutoMergePolicy`` and the bulk-triage
    /// plan all use, so a bot that is not a recognised agent counts as a person here too, exactly
    /// as it does on the card.
    ///
    /// **"It claims something"** is ``ShepherdCore/ClaimExtractor/extract(from:)``, the card's own
    /// tier-1 pass: compiled regular expressions over the description and nothing else. That is
    /// the whole reason it can be asked here — the tab has to be decided synchronously, in the
    /// same turn the detail arrives, and asking a model would mean the review opened on one tab
    /// and moved to another under the reviewer, and on a different tab on a Mac without the
    /// model. It is also what makes the answer agree with the card by construction: an empty
    /// extraction is precisely the case ``ShepherdCore/ClaimsEvidenceReport/build(detail:summary:)``
    /// turns into an empty report and the card draws nothing for, so this can never open the
    /// Conversation tab on a card that is not there.
    ///
    /// Pure and `static` so the rule is unit-tested rather than inferred from task ordering, the
    /// same treatment ``defaultRoundView(for:)`` gets.
    /// - Parameters:
    ///   - detail: The pull request the screen has just been given.
    ///   - opensAgentPullRequestsOnConversation: The reviewer's preference. With it off the answer
    ///     is always Files, for the reviewer who wants the diff first whatever wrote the
    ///     description.
    /// - Returns: The tab to open on.
    static func defaultTab(
        for detail: PullRequestDetail,
        opensAgentPullRequestsOnConversation: Bool
    ) -> Tab {
        guard opensAgentPullRequestsOnConversation else { return .files }
        guard detail.summary.author.kind.agentIdentity != nil else { return .files }
        return ClaimExtractor.extract(from: detail.bodyMarkdown).isEmpty ? .files : .conversation
    }

    /// Switches the right-hand area between the diff and the conversation.
    ///
    /// Every path that moves the tab goes through here — the picker, `t`, a finding that lost its
    /// anchor, a card's link into a file — because all of them are the reviewer saying where they
    /// want to be, and the default above must not outlive that.
    /// - Parameter tab: The tab to show.
    func setTab(_ tab: Tab) {
        // Unconditionally, and before the guard: clicking the tab you are already on is still a
        // choice, and a detail arriving a moment later must not move you off it.
        hasChosenTab = true
        guard tab != self.tab else { return }
        self.tab = tab
    }

    /// Shows one finding: its file and line, or the conversation when the anchor is gone.
    ///
    /// An outdated finding's line is a number in the head that was reviewed, so it is not used
    /// to scroll the current diff — the conversation view is where a thread that lost its anchor
    /// belongs, and it says where it came from.
    /// - Parameter finding: The finding the reviewer clicked.
    func jump(to finding: ReviewFinding) {
        guard let path = finding.path, let line = finding.line, !finding.isLineOutdated else {
            setTab(.conversation)
            activeThreadID = finding.threadID
            return
        }
        reveal(path: path, line: line)
    }

    private func requestFocusHints(for detail: PullRequestDetail) {
        guard intelligence.isEnabled else {
            focusOutcome = .disabled
            return
        }
        guard case .disabled = focusOutcome else { return }
        let router = intelligence
        intelligenceTask?.cancel()
        intelligenceTask = Task { [weak self] in
            let outcome = await router.focusHints(for: detail)
            guard let self, !Task.isCancelled else { return }
            self.focusOutcome = outcome
        }
    }

    // MARK: - Derived state

    /// The pull request's inbox row.
    var summary: PullRequestSummary? { detail?.summary }

    /// Whether the banner is offering to show a head commit the screen is not showing yet.
    var canReloadPendingUpdate: Bool {
        notice?.offersReload == true && pendingDetail != nil
    }

    /// Whether GitHub has ended this pull request while the review was open.
    ///
    /// What disables approving, requesting changes and merging — the same shape
    /// ``isMissingFromInbox`` gives the screen, one step earlier: that one answers "there is
    /// nothing here to show", this one answers "there is, and none of it can be acted on any
    /// more". A verdict queued against a merged pull request would sit in the outbox until the
    /// drain's staleness check refused it, so the buttons say so before the click rather than a
    /// toast saying so afterwards.
    var hasEndedOnGitHub: Bool { notice?.endsTheReview == true }

    /// The priorities the file list shows in the current round view.
    var visiblePriorities: [FilePriority] {
        roundView == .sinceReview ? interdiffPriorities : priorities
    }

    /// The file list, grouped into priority buckets.
    var buckets: [(bucket: PriorityBucket, files: [FilePriority])] {
        FilePrioritizer.bucketed(visiblePriorities)
    }

    /// Whether the "Since your review" segment is offered at all (ADR 0028).
    var isSinceReviewOffered: Bool { round?.isOffered == true }

    /// The reviewer's findings from the round they reviewed, with their states.
    var findings: [ReviewFinding] { round?.findings ?? [] }

    /// What changed since the reviewed head, or `nil` when there is no baseline.
    var interdiff: [InterdiffFile]? { round?.interdiff }

    /// The pull request's own changed file at the selection, whatever the round view.
    ///
    /// The anchor validation and the commentable-line gate use this rather than
    /// ``selectedFile``: GitHub accepts an inline comment only on a line of the *pull
    /// request's* diff, which the interdiff's synthesized patch is not.
    var currentFile: ChangedFile? {
        guard let selectedPath else { return nil }
        return detail?.files.first { $0.path == selectedPath }
    }

    /// The currently selected changed file — the round's version of it in
    /// ``RoundView/sinceReview``.
    var selectedFile: ChangedFile? {
        guard let selectedPath else { return nil }
        if roundView == .sinceReview,
           let file = interdiff?.first(where: { $0.path == selectedPath }) {
            return file.changedFile(isViewed: viewedPaths.contains(selectedPath))
        }
        return currentFile
    }

    /// The reconstruction of the selected file's patch, or `nil` when there is no patch.
    var selectedReconstruction: PatchReconstructor.Reconstruction? {
        guard let file = selectedFile else { return nil }
        return PatchReconstructor.reconstruct(file)
    }

    /// The reconstruction of the *pull request's* patch at the selection.
    var currentReconstruction: PatchReconstructor.Reconstruction? {
        guard let file = currentFile else { return nil }
        return PatchReconstructor.reconstruct(file)
    }

    /// The reconstructed left/right documents for the selected file.
    var selectedContent: DiffViewerContent? {
        guard let file = selectedFile,
              let reconstruction = selectedReconstruction
        else { return nil }
        return DiffViewerContent(
            path: file.path,
            language: MonacoLanguage.id(for: file),
            original: reconstruction.original,
            modified: reconstruction.modified,
            commentableLines: commentableLines(in: reconstruction)
        )
    }

    /// The same file as ``selectedContent``, in the shape the native list draws.
    ///
    /// The rows come out of the same walk that built the two documents, and the two sets come
    /// out of ``commentableLineSets(in:)`` — so the list and Monaco cannot come to different
    /// conclusions about which lines may carry a comment. That is the first item of the contract
    /// in `docs/plans/accessible-diff.md`, and this is one of its two call sites.
    var selectedListContent: DiffListContent? {
        guard let file = selectedFile,
              let reconstruction = selectedReconstruction
        else { return nil }
        let sets = commentableLineSets(in: reconstruction)
        return DiffListContent(
            path: file.path,
            rows: reconstruction.rows,
            commentableLeft: sets.left,
            commentableRight: sets.right
        )
    }

    /// Which lines may carry a comment, for whichever renderer is drawing.
    ///
    /// In ``RoundView/all`` this is simply what the patch contained. In
    /// ``RoundView/sinceReview`` the document is a synthesized diff of two heads: its right-hand
    /// side shares the current head's line numbers, so a comment there is meaningful, but only
    /// on a line the pull request's *own* patch also contains — GitHub rejects an entire review
    /// when one `comments[].line` is not part of the diff. The left-hand side is the head that
    /// was reviewed and has no valid anchors at all, so it is empty rather than omitted.
    ///
    /// This is the function, and ``commentableLines(in:)`` below is only its sorted-array
    /// spelling for the bridge's JSON. Both renderers land here, which is the point: the rule
    /// that a padding line is unclickable — and the narrowing this applies on top of it — is now
    /// a call site rather than an intention, and a second renderer cannot quietly grow a second
    /// answer to the same question.
    /// - Parameter reconstruction: The reconstruction being shown.
    /// - Returns: The commentable base-side and head-side lines.
    private func commentableLineSets(
        in reconstruction: PatchReconstructor.Reconstruction
    ) -> (left: Set<Int>, right: Set<Int>) {
        guard roundView == .sinceReview else {
            return (
                left: reconstruction.commentableOriginalLines,
                right: reconstruction.commentableModifiedLines
            )
        }
        let allowed = currentReconstruction?.commentableModifiedLines ?? []
        return (
            left: [],
            right: reconstruction.commentableModifiedLines.intersection(allowed)
        )
    }

    /// The same answer as ``commentableLineSets(in:)``, in the two sorted arrays the bridge's
    /// JSON is defined in terms of.
    /// - Parameter reconstruction: The reconstruction being shown.
    /// - Returns: The bridge payload.
    private func commentableLines(
        in reconstruction: PatchReconstructor.Reconstruction
    ) -> BridgeCommentableLines {
        let sets = commentableLineSets(in: reconstruction)
        return BridgeCommentableLines(left: sets.left.sorted(), right: sets.right.sorted())
    }

    /// How many inline comments are waiting in the draft.
    var pendingCommentCount: Int { draft?.comments.count ?? 0 }

    /// The published threads that still anchor into the selected file's current diff.
    var threadsForSelectedFile: [ReviewThread] {
        guard let selectedPath, let detail else { return [] }
        return detail.threads.filter {
            $0.path == selectedPath && $0.isAnchoredInCurrentDiff
        }
    }

    /// Threads that cannot be drawn on the diff, shown in the conversation tab instead.
    ///
    /// Pull-request-level conversations, threads whose anchor GitHub reports as lost, and
    /// outdated threads — an outdated thread's `line` refers to an older commit, so mounting
    /// it as a view zone would park the conversation on unrelated code.
    var unanchoredThreads: [ReviewThread] {
        (detail?.threads ?? []).filter { !$0.isAnchoredInCurrentDiff }
    }

    /// The thread the popover is showing.
    var activeThread: ReviewThread? {
        guard let activeThreadID else { return nil }
        return detail?.threads.first { $0.id == activeThreadID }
    }

    /// The bridge payload for the selected file's threads.
    ///
    /// Markdown is rendered to sanitized HTML **here**, on the native side: that is the
    /// bridge's `bodyHTML` contract.
    var bridgeThreads: [BridgeThread] {
        // In "Since your review" the document only holds the lines that changed between the
        // rounds; everything else is padding, and mounting a thread on padding would park a
        // conversation on a blank line.
        let visibleLines = roundView == .sinceReview
            ? selectedReconstruction?.commentableModifiedLines
            : nil
        return threadsForSelectedFile.compactMap { thread in
            guard let line = thread.line, line >= 1 else { return nil }
            if let visibleLines, !visibleLines.contains(line) { return nil }
            return BridgeThread(
                id: thread.id,
                line: line,
                side: thread.side == .left ? .left : .right,
                resolved: thread.isResolved,
                outdated: thread.isOutdated,
                comments: thread.comments.map { comment in
                    BridgeThreadComment(
                        author: comment.author.login,
                        bodyHTML: MarkdownHTML.render(comment.bodyMarkdown),
                        createdAt: comment.createdAt.formatted(.iso8601),
                        isAgent: comment.author.kind.agentIdentity != nil
                    )
                }
            )
        }
    }

    /// The bridge payload for the selected file's draft comments.
    var bridgeDraftComments: [BridgeDraftComment] {
        guard let selectedPath, let draft else { return [] }
        return draft.comments
            .filter { $0.path == selectedPath && $0.line >= 1 }
            .map { comment in
                BridgeDraftComment(
                    localID: comment.localID.uuidString,
                    line: comment.line,
                    side: comment.side == .left ? .left : .right,
                    body: comment.body
                )
            }
    }

    // MARK: - AI drafting (ADR 0007 amendment)

    /// Whether the "Draft with AI" buttons are offered at all.
    ///
    /// Two conditions, both of which have to hold before a button appears: a tier could take the
    /// request, and the pull request has actually loaded — there is nothing to draft from before
    /// that.
    var canDraftWithAI: Bool {
        detail != nil && intelligence.canDraft
    }

    /// Drafts a review summary suggestion.
    ///
    /// Returns the outcome instead of writing anywhere: the field belongs to the composer, and
    /// what happens to a draft that arrives over text the reviewer already wrote is
    /// ``AIDraftFieldState``'s decision, not this model's. Nothing about this call submits
    /// anything — the reviewer still presses Submit themselves.
    /// - Returns: The drafted text, or why there is none.
    func draftReviewSummary() async -> IntelligenceOutcome<String> {
        guard let detail else {
            return .unavailable(String(localized: "The pull request is still loading."))
        }
        return await intelligence.draftReviewSummary(
            for: detail,
            pendingComments: draft?.comments ?? []
        )
    }

    /// Drafts an inline comment suggestion for one anchor.
    /// - Parameter request: The composer's anchor.
    /// - Returns: The drafted text, or why there is none.
    func draftInlineComment(for request: ComposerRequest) async -> IntelligenceOutcome<String> {
        guard let detail else {
            return .unavailable(String(localized: "The pull request is still loading."))
        }
        return await intelligence.draftInlineComment(for: detail, anchor: request.anchor)
    }

    /// Drafts a review summary suggestion, streamed (plan §0.2).
    ///
    /// What the composers use: the ladder, the budgets and the failure shapes are the same as
    /// ``draftReviewSummary()``, and a tier that cannot stream answers with a stream of one
    /// element, so preferring this path costs nothing and never loses a tier.
    /// - Returns: A labelled stream, or why there is none.
    func streamReviewSummaryDraft() async -> IntelligenceStreamOutcome {
        guard let detail else {
            return .unavailable(String(localized: "The pull request is still loading."))
        }
        return await intelligence.streamReviewSummaryDraft(
            for: detail,
            pendingComments: draft?.comments ?? []
        )
    }

    /// Drafts an inline comment suggestion for one anchor, streamed (plan §0.2).
    /// - Parameter request: The composer's anchor.
    /// - Returns: A labelled stream, or why there is none.
    func streamInlineCommentDraft(for request: ComposerRequest) async -> IntelligenceStreamOutcome {
        guard let detail else {
            return .unavailable(String(localized: "The pull request is still loading."))
        }
        return await intelligence.streamInlineCommentDraft(for: detail, anchor: request.anchor)
    }

    /// Explains the lines the reviewer selected, streamed (plan §3.D).
    ///
    /// Reachable from the same ``ComposerRequest`` the gutter gesture produces, because that is
    /// the whole feature: the selection the reviewer already made is the selection they want
    /// explained, and asking for it must not need a second gesture. Returns the outcome rather
    /// than writing anywhere — the popover owns the text, and putting it into the comment field
    /// is a further click.
    /// - Parameter request: The composer's anchor.
    /// - Returns: A labelled stream, or why there is none.
    func streamExplanation(for request: ComposerRequest) async -> IntelligenceStreamOutcome {
        guard let detail else {
            return .unavailable(String(localized: "The pull request is still loading."))
        }
        return await intelligence.streamExplanation(for: detail, anchor: request.anchor)
    }

    /// The AI focus hint for a file, if the provider produced one.
    /// - Parameter path: The file path.
    func focusHint(for path: String) -> String? {
        focusOutcome.output?.value.first { $0.file == path }?.reason
    }

    /// The riskiest files with the reasons the prioritiser gave, as prompt-ready lines.
    ///
    /// This is what makes "Delegate to agent…" from the review screen worth more than a bare
    /// pull-request link: the agent starts with the same focus list the reviewer sees.
    var delegationFocusReasons: [String] {
        priorities
            .filter { !$0.reasons.isEmpty }
            .prefix(6)
            .map { "\($0.file.path) — \($0.reasons.joined(separator: ", "))" }
    }

    /// The delegation context for the whole pull request, when it has loaded.
    var delegationContext: DelegationContext? {
        guard let summary else { return nil }
        return .pullRequest(summary, focusReasons: delegationFocusReasons)
    }

    /// Whether every file has been marked viewed.
    var isFullyReviewed: Bool {
        guard let detail, !detail.files.isEmpty else { return false }
        return viewedPaths.count >= detail.files.count
    }

    // MARK: - Mutations

    /// Handles a message from the diff viewer.
    /// - Parameter event: The decoded event.
    func handle(_ event: DiffViewerEvent) {
        switch event {
        case .ready:
            break
        case .addComment(let line, let side, let startLine):
            guard let selectedPath else { return }
            composerRequest = ComposerRequest(
                path: selectedPath,
                line: line,
                side: side == .left ? .left : .right,
                startLine: startLine
            )
        case .commentClicked(let target):
            switch target {
            case .thread(let id):
                activeThreadID = id
            case .draft(let localID):
                guard let uuid = UUID(uuidString: localID),
                      let comment = draft?.comments.first(where: { $0.localID == uuid })
                else { return }
                composerRequest = ComposerRequest(
                    path: comment.path,
                    line: comment.line,
                    side: comment.side,
                    startLine: comment.startLine
                )
            }
        case .viewportChanged:
            break
        }
    }

    /// Adds (or replaces) an inline draft comment.
    /// - Parameters:
    ///   - request: Where the comment is anchored.
    ///   - body: The comment text.
    func saveDraftComment(_ request: ComposerRequest, body: String) async throws {
        guard let summary else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try validateAnchor(of: request)
        let existing = draft?.comments.first {
            $0.path == request.path && $0.line == request.line && $0.side == request.side
        }
        let comment = DraftComment(
            localID: existing?.localID ?? UUID(),
            path: request.path,
            line: request.line,
            side: request.side,
            startLine: request.startLine,
            body: trimmed
        )
        if existing != nil {
            try await session.database.deleteDraftComment(localID: comment.localID)
        }
        try await session.database.upsertDraftComment(
            comment,
            prID: prID,
            headRefOid: summary.headRefOid
        )
    }

    /// Rejects a comment anchored to a line the patch does not contain.
    ///
    /// The reconstruction pads the gaps between hunks so that line numbers match GitHub's;
    /// those blank fillers look exactly like real lines once they are in the document. GitHub
    /// answers a review containing one with a 422 and drops the *whole* submission — summary
    /// and every other inline comment included — so it is caught here, before the draft is
    /// written, while the user still has the composer open.
    /// - Parameter request: The anchor to check.
    /// - Throws: ``Failure/lineNotInDiff(line:side:)``.
    func validateAnchor(of request: ComposerRequest) throws {
        // Only the selected file has a reconstruction to check against; a request for any
        // other path cannot be produced by the viewer.
        guard request.path == selectedPath,
              let commentable = currentReconstruction?.commentableLines(on: request.side)
        else { return }
        for line in [request.startLine, request.line].compactMap({ $0 }) {
            guard commentable.contains(line) else {
                throw Failure.lineNotInDiff(line: line, side: request.side)
            }
        }
    }

    /// Deletes an inline draft comment.
    /// - Parameter localID: The comment's local identity.
    func deleteDraftComment(localID: UUID) async throws {
        try await session.database.deleteDraftComment(localID: localID)
    }

    /// Throws away the pending review for a pull request that left the inbox.
    ///
    /// The draft outlives the pull-request row it was written against (no foreign key), so
    /// the user needs a way to let go of one they can no longer act on.
    func discardDraft() async throws {
        try await session.database.deleteDraft(prID: prID)
        draft = nil
        summaryText = ""
    }

    /// Toggles a file's viewed state.
    /// - Parameters:
    ///   - path: The file path.
    ///   - actions: The write helper (for error toasts).
    func toggleViewed(path: String, actions: PullRequestActions) async {
        guard let summary else { return }
        let isViewed = !viewedPaths.contains(path)
        await actions.setFileViewed(path: path, on: summary, isViewed: isViewed)
        if isViewed {
            viewedPaths.insert(path)
        } else {
            viewedPaths.remove(path)
        }
    }

    /// Moves the file selection within the flattened bucket order.
    /// - Parameter offset: `+1` or `-1`.
    func moveFileSelection(by offset: Int) {
        let paths = buckets.flatMap { $0.files.map(\.file.path) }
        guard !paths.isEmpty else { return }
        guard let selectedPath, let index = paths.firstIndex(of: selectedPath) else {
            self.selectedPath = paths.first
            return
        }
        self.selectedPath = paths[min(max(0, index + offset), paths.count - 1)]
    }

    /// Moves the native diff list's cursor.
    ///
    /// Hunk headers are **not** skipped, and that is a decision rather than an omission. Skipping
    /// them would make `j` and `k` a little faster for a reviewer who can see at a glance where
    /// one hunk ends and the next begins. Landing on them is the only way a reviewer who cannot
    /// see that gets told it: the header row is where "the file jumps from line 41 to line 214"
    /// is said, and Monaco says it to a screen reader nowhere at all. This list exists for
    /// exactly that reader, so the extra keystroke per hunk is the cheaper of the two costs.
    /// - Parameter offset: `+1` or `-1`.
    func moveDiffRowSelection(by offset: Int) {
        guard let rows = selectedListContent?.rows, !rows.isEmpty else {
            selectedDiffRow = nil
            return
        }
        // A cursor that is `nil` — or that a background refresh left past the end of a shorter
        // file — starts again at the top rather than being moved from a position it no longer has.
        guard let current = selectedDiffRow, rows.indices.contains(current) else {
            selectedDiffRow = 0
            return
        }
        selectedDiffRow = min(max(0, current + offset), rows.count - 1)
    }

    /// Puts the native diff list's cursor on one row, for a click.
    /// - Parameter index: The row index.
    func selectDiffRow(_ index: Int) {
        guard let rows = selectedListContent?.rows, rows.indices.contains(index) else { return }
        selectedDiffRow = index
    }

    /// Opens the composer on the selected row, or does nothing when the row takes no comment.
    ///
    /// What `c` does inside the native list. It goes through ``handle(_:)`` rather than building
    /// a ``ComposerRequest`` here, and that is the second item of the contract in
    /// `docs/plans/accessible-diff.md`: the bridge's request and the list's request are the same
    /// request, demonstrably, because there is one place that turns "line and side" into an open
    /// composer. The only thing done at this call is the conversion from ``DiffSide`` to the
    /// ``BridgeSide`` the event is defined in terms of — the event's own spelling of the same
    /// two-valued fact.
    func requestCommentOnSelectedRow() {
        guard let content = selectedListContent,
              let index = selectedDiffRow,
              content.rows.indices.contains(index),
              let anchor = content.anchor(for: content.rows[index])
        else { return }
        handle(
            .addComment(
                line: anchor.line,
                side: anchor.side == .left ? .left : .right,
                startLine: nil
            )
        )
    }

    /// The published thread the native list's cursor would open, or `nil` when its row has none.
    ///
    /// The line is the row's own — ``DiffListContent/lineIdentity(of:)`` again — because a thread
    /// on a deleted line is a base-side thread, and looking on the head side would find none and
    /// quietly report that the row has nothing to open.
    ///
    /// **When a line carries several.** ``activeThread`` is one id and the popover shows one
    /// conversation, and a row has one key to press, so this needs a rule rather than a picker:
    /// the first thread on the line that is still *unresolved*, and the first thread otherwise.
    /// An unresolved thread is the one still waiting for an answer, which is what a reviewer has
    /// stopped on the row for; a resolved one is a record of a question already settled. The
    /// order within each is ``threadsForSelectedFile``'s, which is GitHub's own — oldest first,
    /// so the same press always opens the same thread. The row's sentence still says how many
    /// there are, and every one of them stays reachable in the rich viewer, where a thread is a
    /// card that is clicked rather than a count that is announced.
    private var threadOnSelectedDiffRow: ReviewThread? {
        guard let content = selectedListContent,
              let index = selectedDiffRow,
              content.rows.indices.contains(index),
              case .line(let patchRow) = content.rows[index]
        else { return nil }
        let identity = DiffListContent.lineIdentity(of: patchRow)
        let onTheLine = threadsForSelectedFile.filter {
            $0.side == identity.side && $0.line == identity.line
        }
        return onTheLine.first { !$0.isResolved } ?? onTheLine.first
    }

    /// Opens the conversation on the selected row, if it has one.
    ///
    /// What Return does inside the native list, and what a click on a row's comment indicator
    /// does. It goes through ``handle(_:)`` for ``requestCommentOnSelectedRow()``'s reason: the
    /// gutter click in the rich viewer and the key press in the list open the *same* thread the
    /// same way, because there is one place that turns "this thread" into an open popover. The
    /// event carries a thread's GraphQL node id and nothing else, which is precisely what a row
    /// has, so the shared path costs nothing to take.
    /// - Returns: Whether there was a thread to open — which is how the key press knows whether
    ///   to report itself handled, so Return on a row without one travels on rather than being
    ///   swallowed.
    @discardableResult
    func openThreadOnSelectedRow() -> Bool {
        guard let thread = threadOnSelectedDiffRow else { return false }
        handle(.commentClicked(.thread(thread.id)))
        return true
    }

    /// Asks for the keyboard focus to move into one pane of the diff editor.
    ///
    /// What `c` does when the diff does not have the focus, and what `[` and `]` do by naming a
    /// pane. Inside the editor the same keys act on a line: `c` comments on the cursor's, the
    /// brackets cross between the panes. So the pair is the keyboard path to an inline comment —
    /// one press to get a cursor, one to comment on it — and the side is what makes it reach a
    /// *deleted* line, which exists only in the original pane (ADR 0033's amendment).
    ///
    /// The native list reads the same counter and ignores the side: it is one column, so it has
    /// no second pane to be sent to, and a deleted line is simply a row in it. Two renderers, one
    /// answer to "who has the keyboard now".
    func requestEditorFocus(side: BridgeSide = .right) {
        focusEditorSide = side
        focusEditorRequest += 1
    }

    /// Shows one file in the diff viewer, scrolled to a line.
    ///
    /// The CI diagnosis card's `file:line` link (plan §3.F): a model that named
    /// `ShepherdTests/LocalizationTests.swift:231` should cost one click to check, not a hunt
    /// through the file list. Both halves are the viewer's existing plumbing —
    /// ``selectedPath`` picks the file, and `DiffViewerView`'s `revealLine` sends the same
    /// `revealLine` command a thread anchor uses — so this is one place that sets them together.
    ///
    /// A path the pull request does not contain is ignored rather than selected: `selectedPath`
    /// drives the viewer, and pointing it at a file with no patch would blank the diff. The card
    /// does not draw a link in that case either, so this is the second gate rather than the only
    /// one.
    /// - Parameters:
    ///   - path: The file to show.
    ///   - line: The head-side line to scroll to, when the diagnosis named one.
    func reveal(path: String, line: Int?) {
        if !visiblePriorities.contains(where: { $0.file.path == path }) {
            // The file is not in the round the reviewer is looking at. Showing the whole pull
            // request is the honest way to show it, rather than selecting a file the list does
            // not contain.
            guard detail?.files.contains(where: { $0.path == path }) == true else { return }
            setRoundView(.all)
        }
        selectedPath = path
        setTab(.files)
        revealLine = line
    }

    /// Submits the pending review through the outbox.
    /// - Parameters:
    ///   - verdict: The verdict to submit with.
    ///   - actions: The write helper.
    func submit(verdict: ReviewVerdict, actions: PullRequestActions) async {
        guard let summary else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await actions.submitReview(on: summary, verdict: verdict, body: summaryText)
        summaryText = ""
    }
}
