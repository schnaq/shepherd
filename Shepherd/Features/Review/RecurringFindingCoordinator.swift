import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence

/// Notices that the reviewer has now written the same finding three times (ADR 0029).
///
/// The app half of the feedback loop, and the third coordinator built to
/// ``SavedReplySuggestionCoordinator``'s shape: every *decision* is a pure value in `ShepherdCore`
/// (``ShepherdCore/RecurringFindingDetector``), and this type supplies the inputs, spends the
/// embeddings and holds the caches. It is created inert — no model is loaded, no comment is read
/// and no vector exists until a sweep has actually landed rows in the inbox.
///
/// Six things about it are decisions rather than mechanics:
///
/// - **It reuses ADR 0019's embedder and adds nothing.** The dependency is ``EmbeddingProviding``,
///   whose only production implementation is ``NaturalLanguageEmbedder``. There is no
///   ``IntelligenceRouter`` here, no base URL, no key and no language model, so this pass —
///   which runs *unattended*, after every sweep — cannot reach a cloud endpoint by construction
///   rather than by a setting somebody could flip. That is the same structural rule ADR 0019
///   states for `Features/Search/` and the reason the saved-reply suggester is allowed to run
///   without asking anybody.
/// - **The reviewer's own comments, and only those.** The database read
///   (``ShepherdPersistence/DatabaseManager/viewerReviewComments(login:since:)``) matches the
///   signed-in login and returns nothing else, so a colleague's sentence never enters a cluster
///   (ADR 0020's reasoning). The pass is unattended, and "these are your own words" is what makes
///   an unattended pass over review prose acceptable at all.
/// - **One vector per comment *body*, cached under the body itself.** Not under the comment id:
///   the reviewer writes the same sentence on four pull requests, and four identical bodies must
///   cost one embedding. The bodies are already in memory as the input to the pass, so a hash key
///   would buy nothing but a collision to reason about — the string *is* the key.
/// - **A ceiling on how much one repository may cost.** ``maximumComments`` newest comments per
///   repository enter the clustering, which bounds both the embeddings and the *n*² cosines. A
///   reviewer with three years of review on one repository is exactly the person this feature is
///   for, and they must not be the person it stalls.
/// - **A dismissal is device-local and it is not a setting.** It lives in `UserDefaults` beside
///   the auto-delegation ledger (``AutoDelegationStore``'s argument, applied again): it must
///   survive a relaunch, it carries no secret and no content — one hash per dismissed finding —
///   and it deliberately does **not** travel in the settings document (ADR 0014). "I do not want
///   this card" is a judgement about one screen in front of one person; a second Mac that has
///   never shown the card has nothing to suppress, and syncing the set would let one Mac silently
///   hide a card the other has never offered.
/// - **It offers, it never starts.** The only things this type produces are values a card draws
///   and a `Bool` a dismissal button flips. There is no path from here to the delegation engine,
///   to the outbox or to a rules engine — the card's button is what builds a context, and Run is
///   still the reviewer's click (ADR 0029, amending ADR 0011; ADR 0016's rules get no trigger
///   from here, and cannot: nothing in this file emits an event).
@MainActor
@Observable
final class RecurringFindingCoordinator {
    /// How many of a repository's newest comments enter one pass.
    ///
    /// Two hundred, which is a bounded cost rather than a quality judgement: the clustering is
    /// *n*² cosines, so the ceiling is what keeps the worst case (a repository the reviewer has
    /// been reviewing for years) the same size as the ordinary case. The newest are kept because
    /// the window already throws the old ones away.
    static let maximumComments = 200

    private let embedder: any EmbeddingProviding
    private let window: TimeInterval
    private let defaults: UserDefaults
    private let dismissalKey: String
    private let now: @MainActor () -> Date

    /// Every finding the last pass produced, keyed by lower-cased repository full name.
    private(set) var findingsByRepo: [String: [RecurringFinding]] = [:]

    /// The exemplar hashes the reviewer has dismissed on this Mac.
    private(set) var dismissedKeys: Set<String> = []

    /// One vector per comment body, keyed by the trimmed body itself.
    private var vectors: [String: SearchVector] = [:]

    /// The model's answer about this Mac, once it has been asked.
    private var cachedAvailability: EmbeddingAvailability?

    /// What the last pass was computed from, so an unchanged sweep costs nothing.
    private var lastFingerprint: String?

    /// The pass that is running, if one is.
    ///
    /// `private(set)` rather than private so `ShepherdTests` can *await* a pass instead of polling
    /// for its effects — ``SearchIndexCoordinator/passTask``'s seam. Nothing in the app reads it.
    private(set) var passTask: Task<Void, Never>?

    /// Creates a coordinator.
    /// - Parameters:
    ///   - embedder: The embedding seam. The default is the on-device model — the same actor ⌘K
    ///     search and the saved-reply suggester use, and the reason a test can drive this type
    ///     without Apple's model being present or its output being stable.
    ///   - window: How far back a comment may have been written. Defaults to the detector's
    ///     thirty days, taken from the pure rule rather than restated.
    ///   - defaults: Where dismissals live. Injectable for tests.
    ///   - dismissalKey: The defaults key. Injectable so two coordinators can share one suite.
    ///   - now: The clock, so the window is assertable.
    init(
        embedder: any EmbeddingProviding = NaturalLanguageEmbedder(),
        window: TimeInterval = RecurringFindingDetector.defaultWindow,
        defaults: UserDefaults = .standard,
        dismissalKey: String = "review.recurringFindings.dismissed",
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.embedder = embedder
        self.window = window
        self.defaults = defaults
        self.dismissalKey = dismissalKey
        self.now = now
        self.dismissedKeys = Set(
            AppSettings.readJSON(defaults, dismissalKey, default: [String]())
        )
    }

    /// How many comment bodies currently have a cached vector.
    ///
    /// `internal` rather than private so `ShepherdTests` can assert the cost promise directly —
    /// the seam ``SavedReplySuggestionCoordinator/cachedBodyCount`` is. Nothing in the app reads
    /// it.
    var cachedBodyCount: Int { vectors.count }

    // MARK: - Reading

    /// The findings a repository's review screen may show, best first.
    ///
    /// Dismissed findings are filtered *here* rather than dropped in the pass, so Settings can
    /// still list them with a "Show again" button — a card the reviewer cannot get back would
    /// make dismissing it a decision they cannot undo.
    /// - Parameter repo: The repository the reviewer is looking at.
    /// - Returns: The undismissed findings, largest cluster first.
    func findings(for repo: RepoRef) -> [RecurringFinding] {
        (findingsByRepo[repo.fullName.lowercased()] ?? []).filter { !isDismissed($0) }
    }

    /// The one finding the review screen's card draws, or `nil` when there is nothing to say.
    /// - Parameter repo: The repository the reviewer is looking at.
    func topFinding(for repo: RepoRef) -> RecurringFinding? {
        findings(for: repo).first
    }

    /// Every finding on every repository, for the list under Settings → Replies.
    ///
    /// Repository first, then largest cluster, so the list does not reorder itself while somebody
    /// is reading it. Dismissed ones are included — that list is where they can be brought back.
    var everyFinding: [RecurringFinding] {
        findingsByRepo.values.flatMap { $0 }.sorted { left, right in
            let leftRepo = left.repo.fullName.lowercased()
            let rightRepo = right.repo.fullName.lowercased()
            if leftRepo != rightRepo { return leftRepo < rightRepo }
            if left.count != right.count { return left.count > right.count }
            return left.exemplar < right.exemplar
        }
    }

    /// Whether a finding has been dismissed on this Mac.
    /// - Parameter finding: The finding.
    func isDismissed(_ finding: RecurringFinding) -> Bool {
        dismissedKeys.contains(finding.dismissalKey)
    }

    // MARK: - Dismissing

    /// Hides a finding on this repository, for good, on this Mac.
    /// - Parameter finding: The finding to hide.
    func dismiss(_ finding: RecurringFinding) {
        guard !dismissedKeys.contains(finding.dismissalKey) else { return }
        dismissedKeys.insert(finding.dismissalKey)
        persistDismissals()
    }

    /// Brings a dismissed finding back, from the list in Settings.
    /// - Parameter finding: The finding to show again.
    func showAgain(_ finding: RecurringFinding) {
        guard dismissedKeys.contains(finding.dismissalKey) else { return }
        dismissedKeys.remove(finding.dismissalKey)
        persistDismissals()
    }

    /// Drops everything. Called from "Sign out & erase local data".
    ///
    /// The dismissals go too, for ``AutoDelegationStore/reset()``'s reason: they name findings of
    /// the account that is leaving, and the comments they were computed from went with
    /// `eraseAllData()`.
    func reset() {
        passTask?.cancel()
        passTask = nil
        findingsByRepo = [:]
        vectors = [:]
        cachedAvailability = nil
        lastFingerprint = nil
        dismissedKeys = []
        defaults.removeObject(forKey: dismissalKey)
    }

    // MARK: - Scanning

    /// Considers the rows a sweep just wrote.
    ///
    /// Wired to ``SignedInSession/start(settings:notifications:onEvent:onInboxRows:)`` beside the
    /// search index and the triage pass, so all three see the same rows at the same moment — and
    /// a *peer* of them rather than something hanging off the end of one, for the reason
    /// ``TriageCoordinator`` argues: the three share a data source and nothing else.
    ///
    /// A second call while a pass is running is dropped rather than queued. The inputs are the
    /// whole of the reviewer's last thirty days of review, so the pass that is already running is
    /// reading almost exactly the same rows; the next sweep picks up anything it missed. That is
    /// the opposite of ``TriageCoordinator``'s merging queue, and deliberately — there is no
    /// per-row work here that a queue could preserve.
    /// - Parameters:
    ///   - rows: Every inbox row the local database now holds.
    ///   - database: Where the review comments live.
    ///   - viewerLogin: The signed-in user's login. Its comments are the only input.
    func considerScanning(
        rows: [PullRequestSummary],
        database: DatabaseManager,
        viewerLogin: String
    ) {
        // Nothing in the inbox means nothing to have commented on, and the findings would be
        // about pull requests the database no longer holds.
        guard !rows.isEmpty else {
            findingsByRepo = [:]
            lastFingerprint = nil
            return
        }
        guard !viewerLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard passTask == nil else { return }
        let since = now().addingTimeInterval(-window)
        let clock = now()
        passTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.pass(
                database: database,
                viewerLogin: viewerLogin,
                since: since,
                now: clock
            )
            self.passTask = nil
        }
    }

    /// One pass: read, embed, cluster.
    ///
    /// Split out so the pass is one readable sequence and so a test can await it through
    /// ``passTask``.
    private func pass(
        database: DatabaseManager,
        viewerLogin: String,
        since: Date,
        now: Date
    ) async {
        guard let comments = try? await database.viewerReviewComments(
            login: viewerLogin,
            since: since
        ) else { return }
        guard !Task.isCancelled else { return }
        // Under the count nothing can recur, and this is checked before a single embedding is
        // spent — the same early exit the saved-reply suggester makes on the reply count.
        guard comments.count >= RecurringFindingDetector.minimumCount else {
            findingsByRepo = [:]
            lastFingerprint = fingerprint(of: comments)
            return
        }

        let stamp = fingerprint(of: comments)
        guard stamp != lastFingerprint else { return }

        // Written as a plain `if let` over a non-optional local rather than as a comparison
        // against an optional, so the pattern match below has exactly one meaning.
        let availability: EmbeddingAvailability
        if let cached = cachedAvailability {
            availability = cached
        } else {
            availability = await embedder.availability()
            cachedAvailability = availability
        }
        // With no model on this Mac the feature is simply absent: no card, no cost, and no line
        // anywhere saying so. It is a suggestion nobody asked for, so a failure to make it is not
        // news (the saved-reply menu degrades the same way).
        guard case .available = availability else {
            findingsByRepo = [:]
            lastFingerprint = stamp
            return
        }

        var grouped: [String: [ViewerReviewComment]] = [:]
        for comment in comments {
            grouped[comment.repo.fullName.lowercased(), default: []].append(comment)
        }

        var liveBodies: Set<String> = []
        var result: [String: [RecurringFinding]] = [:]
        for (key, all) in grouped {
            guard let repo = all.first?.repo else { continue }
            // Newest first for the ceiling, then back to oldest first: the detector imposes its
            // own order, but keeping the input chronological makes the fixture in a test readable.
            let considered = all
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(RecurringFindingCoordinator.maximumComments)
                .sorted { $0.createdAt < $1.createdAt }
            guard considered.count >= RecurringFindingDetector.minimumCount else { continue }

            var candidates: [(
                id: String,
                body: String,
                prID: String,
                number: Int,
                createdAt: Date,
                vector: SearchVector
            )] = []
            for comment in considered {
                let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                liveBodies.insert(body)
                let vector: SearchVector
                if let cached = vectors[body] {
                    vector = cached
                } else {
                    // A body the model has nothing to say about is skipped rather than stored as
                    // a zero vector: a zero would be comparable to everything and cluster with
                    // nothing in particular.
                    guard let embedded = await embedder.vector(for: body) else { continue }
                    guard !Task.isCancelled else { return }
                    vectors[body] = embedded
                    vector = embedded
                }
                candidates.append((
                    id: comment.id,
                    body: body,
                    prID: comment.prID,
                    number: comment.number,
                    createdAt: comment.createdAt,
                    vector: vector
                ))
            }

            let findings = RecurringFindingDetector.detect(
                repo: repo,
                comments: candidates,
                now: now,
                window: window
            )
            if !findings.isEmpty { result[key] = findings }
        }
        guard !Task.isCancelled else { return }

        findingsByRepo = result
        lastFingerprint = stamp
        // A comment that has left the window is unreachable through any body this pass saw, so
        // dropping its vector is what keeps the cache the size of the reviewer's last month of
        // review rather than the size of their history.
        vectors = vectors.filter { liveBodies.contains($0.key) }
    }

    /// What a pass was computed from, cheaply.
    ///
    /// The count plus the oldest and newest ids, which is what changes when a comment is written,
    /// posted or falls out of the window. An *edit* to an existing comment does not change it, so
    /// a reworded comment is picked up by the pass after the next one that does change the set —
    /// accepted, because the alternative is hashing every body on every sweep to notice a case
    /// that changes a card's wording and not its existence.
    private func fingerprint(of comments: [ViewerReviewComment]) -> String {
        "\(comments.count)|\(comments.first?.id ?? "")|\(comments.last?.id ?? "")"
    }

    private func persistDismissals() {
        // Sorted, so the stored blob does not churn between launches for no reason.
        AppSettings.writeJSON(defaults, dismissedKeys.sorted(), dismissalKey)
    }
}
