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
    /// Set when the pull request is not (or no longer) in the local inbox.
    ///
    /// A sweep prunes everything its search did not return — a merged pull request, or one
    /// past the search's page cap — and the detail rows cascade away with it. Without this the
    /// screen sat on a `ProgressView` forever.
    private(set) var isMissingFromInbox = false

    /// The file being shown in the diff viewer.
    var selectedPath: String?
    /// Which tab is showing.
    var tab: Tab = .files
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

    private var draftTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var intelligenceTask: Task<Void, Never>?

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

    /// Loads the cached detail, then refreshes it, and starts observing the draft.
    func start() {
        observeDraft()
        load()
    }

    /// Cancels every background task.
    func stop() {
        draftTask?.cancel()
        draftTask = nil
        loadTask?.cancel()
        loadTask = nil
        intelligenceTask?.cancel()
        intelligenceTask = nil
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
                if self.summaryText.isEmpty, let body = value?.summaryBody, !body.isEmpty {
                    self.summaryText = body
                }
            }
        }
    }

    private func apply(_ detail: PullRequestDetail) {
        self.detail = detail
        priorities = FilePrioritizer.prioritize(
            detail.files,
            context: PrioritizationContext(totalChangedLines: detail.summary.churn)
        )
        viewedPaths = Set(detail.files.filter(\.isViewed).map(\.path))
        if selectedPath == nil || !detail.files.contains(where: { $0.path == selectedPath }) {
            selectedPath = priorities.first?.file.path
        }
        requestFocusHints(for: detail)
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

    /// The file list, grouped into priority buckets.
    var buckets: [(bucket: PriorityBucket, files: [FilePriority])] {
        FilePrioritizer.bucketed(priorities)
    }

    /// The currently selected changed file.
    var selectedFile: ChangedFile? {
        guard let selectedPath else { return nil }
        return detail?.files.first { $0.path == selectedPath }
    }

    /// The reconstruction of the selected file's patch, or `nil` when GitHub sent no patch.
    var selectedReconstruction: PatchReconstructor.Reconstruction? {
        guard let file = selectedFile else { return nil }
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
            commentableLines: BridgeCommentableLines(
                left: reconstruction.commentableOriginalLines.sorted(),
                right: reconstruction.commentableModifiedLines.sorted()
            )
        )
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
        threadsForSelectedFile.compactMap { thread in
            guard let line = thread.line, line >= 1 else { return nil }
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

    /// The AI focus hint for a file, if the provider produced one.
    /// - Parameter path: The file path.
    func focusHint(for path: String) -> String? {
        focusOutcome.output?.value.first { $0.file == path }?.reason
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
              let commentable = selectedReconstruction?.commentableLines(on: request.side)
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
