import Foundation
import Observation
import ShepherdCore

/// What the thread-digest card is showing for one thread.
///
/// Three states and no fourth: there is no "idle" case, because *no state at all* is what the
/// absence of a card means, and modelling that as a case would make every view unwrap the same
/// nothing twice.
enum ThreadDigestState: Sendable, Equatable {
    /// The model is reading the thread.
    case loading
    /// It answered, with how much of the thread it covered.
    case digest(ThreadDigestResult)
    /// It did not, in the tier's own words.
    case failed(String)
}

/// Spends the on-device model run behind *Summarise* on a review thread (plan §3.G).
///
/// The app half of the thread digest, and the counterpart of ``SavedReplySuggestionCoordinator``:
/// every *decision* is a pure value in `ShepherdCore` (``ShepherdCore/ThreadDigestRequest``
/// decides what the model may read; ``ShepherdCore/ThreadDigestResult`` carries what it covered),
/// and this type supplies the inputs, spends the run and holds the cache. It is created inert —
/// no model is loaded and no session exists until a reviewer clicks the button on a thread.
///
/// Five things about it are decisions rather than mechanics:
///
/// - **Its only dependency is ``ThreadDigesting``.** There is no `IntelligenceRouter` here, no
///   base URL and no key, so ADR 0007's amendment ("colleagues' comments are an on-device-only
///   content class") holds by construction rather than by a setting somebody could flip. The
///   initialiser's signature *is* the guarantee, which is why a test asserts it.
/// - **Availability is asked once and remembered for the life of the app.** Whether this Mac can
///   run the model is a property of the Mac. Until the answer is in, ``isAvailable`` is `false`
///   and no button is drawn — a *Summarise* that turned out to do nothing would be worse than one
///   that appears a moment after the popover.
/// - **The cache is keyed by the thread *and its content*.** Thread id, comment count and the id
///   of the newest comment: a reply arriving changes the key, so the digest of the conversation
///   as it was is never shown as a digest of the conversation as it is. Nothing is persisted —
///   no `UserDefaults`, no GRDB table, no field in `SyncedSettingsDocument` — for ADR 0020's
///   reason: this is somebody else's prose, held in memory for as long as somebody is reading it.
/// - **One run per thread at a time.** Two clicks, or a click and a re-render, cost one model
///   run; a click on a thread that has moved on cancels the run for the version that is gone.
///   Everything between the availability check and the task being recorded is synchronous on the
///   main actor, which is what makes "one" true rather than likely.
/// - **It summarises, it never acts.** The only thing this type produces is text in a card. There
///   is no path from here to a reply, to `setThread(on:threadID:resolved:)` or to the outbox:
///   resolving a thread stays the reviewer's own button, and the digest is not allowed to
///   recommend pressing it (the instructions say so; nothing here could act on it if it did).
@MainActor
@Observable
final class ThreadDigestCoordinator {
    /// How many comments a thread needs before *Summarise* is offered.
    ///
    /// Taken from the pure request rather than restated, so the button's condition and the
    /// request's idea of "long enough to summarise" cannot drift apart.
    static let minimumCommentCount = ThreadDigestRequest.minimumCommentCount

    private let digester: any ThreadDigesting
    private let budget: TokenBudget

    /// The model's answer about this Mac, once it has been asked.
    private var cachedAvailability: ThreadDigesterAvailability?
    /// The ask itself while it is in flight, so two popovers opening together ask once.
    ///
    /// Not observed: no view reads it, and the answer it produces lands in
    /// ``cachedAvailability``, which is the property a view *does* read.
    @ObservationIgnored private var availabilityTask: Task<ThreadDigesterAvailability, Never>?
    /// One state per ``cacheKey(threadID:comments:)``.
    private var states: [String: ThreadDigestState] = [:]
    /// The run in flight per thread, with the key it is answering for.
    ///
    /// Not observed either: what a view draws is the *state* the run produces, and a card that
    /// re-rendered because a task handle was stored would be re-rendering on bookkeeping.
    @ObservationIgnored private var inFlight: [String: (key: String, task: Task<Void, Never>)] = [:]

    /// Creates a coordinator.
    /// - Parameters:
    ///   - digester: The model seam. The default is the on-device digester — the reason a test can
    ///     drive this type without Apple's model being present or its answers being stable.
    ///   - budget: The tier's token budget. The comments are cut to fit it before anything is
    ///     sent, because tier 2's ceiling is a hard error (ADR 0007).
    init(
        digester: any ThreadDigesting = OnDeviceThreadDigester(),
        budget: TokenBudget = .onDevice
    ) {
        self.digester = digester
        self.budget = budget
    }

    // MARK: - Availability

    /// Whether *Summarise* may be drawn at all.
    ///
    /// `false` until ``prepare()`` has answered, and `false` forever on a Mac without the model.
    var isAvailable: Bool {
        guard let availability = cachedAvailability else { return false }
        return availability == .available
    }

    /// Why the model cannot summarise on this Mac, when it cannot.
    ///
    /// Nothing in the review screen shows it — the button is simply absent — but the sentence
    /// exists so that anything which later wants to explain the absence has the model's own words
    /// rather than an invented apology.
    var unavailabilityReason: String? { cachedAvailability?.reason }

    /// Asks the model whether it is there, at most once per app run.
    ///
    /// Called from the thread popover's `.task`, so the answer is in before a reviewer has read
    /// the first comment, and never on a screen that has no thread on it.
    func prepare() async {
        if cachedAvailability != nil { return }
        if let running = availabilityTask {
            cachedAvailability = await running.value
            return
        }
        let digester = self.digester
        let task = Task { await digester.availability() }
        availabilityTask = task
        cachedAvailability = await task.value
    }

    // MARK: - Reading

    /// The card's state for one thread, or `nil` when there is no card.
    /// - Parameters:
    ///   - threadID: The thread's GraphQL node id.
    ///   - comments: The thread's comments, as the view has them.
    func state(for threadID: String, comments: [ReviewComment]) -> ThreadDigestState? {
        states[Self.cacheKey(threadID: threadID, comments: comments)]
    }

    /// How many digests are currently held.
    ///
    /// `internal` rather than private so `ShepherdTests` can assert the invalidation rule
    /// directly — the same kind of seam ``SavedReplySuggestionCoordinator/cachedBodyCount`` is.
    /// Nothing in the app reads it.
    var cachedDigestCount: Int { states.count }

    /// What a thread's digest is remembered under.
    ///
    /// The comment *count* and the newest comment's *id*, not a hash of the whole conversation: a
    /// reply is the only thing that can happen to a thread a reviewer is looking at, and both an
    /// arriving reply and a locally drafted one change one of the two. An edited comment body is
    /// deliberately not covered — GitHub gives an edit no new id, the digest of a thread whose
    /// wording changed is still a digest of that conversation, and hashing every body on every
    /// render to catch it would cost more than it saves.
    /// - Parameters:
    ///   - threadID: The thread's GraphQL node id.
    ///   - comments: The thread's comments.
    static func cacheKey(threadID: String, comments: [ReviewComment]) -> String {
        "\(threadID)|\(comments.count)|\(comments.last?.id ?? "")"
    }

    // MARK: - Summarising

    /// Summarises one thread, or does nothing because there is nothing to do.
    ///
    /// Nothing is the answer in four cases, and all four are normal: the digest is already there
    /// or already loading, this Mac has no model, the same run is already going, or the thread has
    /// no comment with any text in it. None of them is an error to report and none of them prints
    /// anything — a card with a warning in it because a cache hit occurred would be a worse card
    /// than none.
    /// - Parameters:
    ///   - threadID: The thread's GraphQL node id.
    ///   - comments: The thread's comments, oldest first.
    ///   - isResolved: Whether GitHub has the thread marked resolved.
    func digest(
        for threadID: String,
        comments: [ReviewComment],
        isResolved: Bool = false
    ) async {
        // Awaited *first*, so that everything below is one synchronous stretch on the main actor.
        // With the availability check in the middle, two clicks arriving together could both get
        // past the "is one already running?" test and start two sessions.
        await prepare()
        guard isAvailable else { return }

        let key = Self.cacheKey(threadID: threadID, comments: comments)
        // A finished digest is final for this content; a failed one is not — the reviewer may
        // press the button again, and a guardrail decline or a transient error deserves a
        // second run.
        switch states[key] {
        case nil, .failed: break
        default: return
        }
        if let running = inFlight[threadID] {
            guard running.key != key else {
                // The same click twice: wait for the run that is already paying for it.
                await running.task.value
                return
            }
            // A run for a version of the thread that no longer exists. Nobody will ever see its
            // answer, so it is stopped rather than left to finish on the battery.
            running.task.cancel()
            states.removeValue(forKey: running.key)
            inFlight.removeValue(forKey: threadID)
        }

        let request = ThreadDigestRequest.build(
            comments: comments.map { ThreadDigestRequest.Comment($0) },
            isResolved: isResolved,
            budget: budget
        )
        guard !request.isEmpty else { return }

        states[key] = .loading
        let digester = self.digester
        let task = Task { [weak self] in
            do {
                let result = try await digester.digest(request)
                guard !Task.isCancelled else { return }
                self?.finish(.digest(result), for: key, threadID: threadID)
            } catch {
                guard !Task.isCancelled else { return }
                // The tier's own words, verbatim, exactly the way a failed draft surfaces one —
                // and never printed anywhere.
                self?.finish(.failed(AIDraftFailure.describe(error)), for: key, threadID: threadID)
            }
        }
        inFlight[threadID] = (key: key, task: task)
        await task.value
    }

    /// Stops the run for one thread, if there is one.
    ///
    /// Called when the popover moves to a different thread. The loading state goes with it: a
    /// spinner nobody is filling any more is a lie, and the reviewer can ask again.
    /// - Parameter threadID: The thread to stop summarising.
    func cancel(for threadID: String) {
        guard let running = inFlight.removeValue(forKey: threadID) else { return }
        running.task.cancel()
        if isLoading(running.key) {
            states.removeValue(forKey: running.key)
        }
    }

    /// Whether one key is showing a spinner rather than an answer.
    private func isLoading(_ key: String) -> Bool {
        guard let state = states[key] else { return false }
        return state == .loading
    }

    /// Records an answer, and forgets the run that produced it.
    private func finish(_ state: ThreadDigestState, for key: String, threadID: String) {
        states[key] = state
        if inFlight[threadID]?.key == key {
            inFlight.removeValue(forKey: threadID)
        }
    }
}
