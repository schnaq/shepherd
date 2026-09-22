import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// How far one repository's backfill has got, for the progress line (ADR 0027).
public struct TrackRecordBackfillProgress: Sendable, Equatable {
    /// The repository being read.
    public var repo: RepoRef
    /// How many closed pull requests have been stored for it so far.
    public var stored: Int
    /// GitHub's estimate of how many the query matches. An estimate on purpose — the search
    /// index is eventually consistent, so the number can move between pages, which is why the
    /// line the user reads says "of about 340".
    public var estimatedTotal: Int
    /// Which repository this is, one-based.
    public var repositoryIndex: Int
    /// How many repositories the run covers.
    public var repositoryCount: Int

    /// Creates a progress value.
    public init(
        repo: RepoRef,
        stored: Int,
        estimatedTotal: Int,
        repositoryIndex: Int,
        repositoryCount: Int
    ) {
        self.repo = repo
        self.stored = stored
        self.estimatedTotal = estimatedTotal
        self.repositoryIndex = repositoryIndex
        self.repositoryCount = repositoryCount
    }
}

/// One repository the backfill could not finish.
///
/// A value rather than a thrown error, because a run over six repositories that fails on the
/// third has still imported two: the failures are collected and shown as one line each, and the
/// run keeps going.
public struct TrackRecordBackfillFailure: Sendable, Equatable {
    /// The repository that failed.
    public var repo: RepoRef
    /// What went wrong, in the words the error gave — English, for tests and logs.
    public var message: String
    /// The GitHub error behind it, when it was one, so the app can say it in the user's language
    /// rather than showing ``message`` (ADR 0022, 2026-09-22 amendment).
    public var error: GitHubError?

    /// Creates a failure.
    public init(repo: RepoRef, message: String, error: GitHubError? = nil) {
        self.repo = repo
        self.message = message
        self.error = error
    }
}

/// What a backfill run did.
public struct TrackRecordBackfillResult: Sendable, Equatable {
    /// How many outcomes were written.
    public var stored: Int
    /// How many stored pull requests were marked as reverted.
    public var revertsLinked: Int
    /// How many repositories hit the per-repository page cap.
    public var cappedRepositories: [RepoRef]
    /// The repositories that failed, one message each.
    public var failures: [TrackRecordBackfillFailure]
    /// Whether the run stopped because it was cancelled.
    public var wasCancelled: Bool

    /// Creates a result.
    public init(
        stored: Int = 0,
        revertsLinked: Int = 0,
        cappedRepositories: [RepoRef] = [],
        failures: [TrackRecordBackfillFailure] = [],
        wasCancelled: Bool = false
    ) {
        self.stored = stored
        self.revertsLinked = revertsLinked
        self.cappedRepositories = cappedRepositories
        self.failures = failures
        self.wasCancelled = wasCancelled
    }
}

/// Reads the last ninety days of closed pull requests, one repository at a time (ADR 0027).
///
/// The one-time load behind Settings → Automation → *Load track record*. It is a pager and
/// nothing else: it asks ``ClosedPullRequestReading`` for a page, writes it through
/// ``OutcomeRecording``, reports where it is, and asks for the next one. Every decision that is
/// not paging is somewhere else — the query is `InboxQuery.closedPullRequests(in:since:)`, the
/// mapping is `ResponseMapping`, the revert linking is the pure `RevertDetector`, and the
/// ninety-day window is `TrackRecord.windowDays`.
///
/// An actor rather than a struct of static functions because a run has state a caller must not
/// see half of: the page cursor, the collected candidates, and the counters the result is built
/// from.
///
/// **Nothing here writes to GitHub**, and nothing here is on the sync's own path: the backfill
/// runs when a person presses a button, at `.utility` priority in the app, and a `Task` the app
/// cancels stops it between pages.
public actor TrackRecordBackfill {
    /// The most closed pull requests read per repository.
    ///
    /// Five pages of a hundred. The cap is the plan's, and the reasoning is the inbox sweep's own
    /// five-page stop: five hundred closed pull requests in ninety days is more than a solo
    /// maintainer's repository produces, and the numbers a badge shows do not get better past
    /// that — while a repository with twenty thousand closed pull requests would otherwise spend
    /// two hundred requests to tell somebody that an agent merges most of what it opens.
    public static let maximumPullRequestsPerRepository = 500

    /// How many pull requests one page asks for.
    public static let pageSize = 100

    private let reader: any ClosedPullRequestReading
    private let store: any OutcomeRecording
    private let now: @Sendable () -> Date

    /// Creates a backfill.
    /// - Parameters:
    ///   - reader: Where closed pull requests are read from.
    ///   - store: Where outcomes are written.
    ///   - now: Clock injection point for tests; decides the ninety-day window.
    public init(
        reader: any ClosedPullRequestReading,
        store: any OutcomeRecording,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.store = store
        self.now = now
    }

    /// Runs the backfill over some repositories.
    ///
    /// Repositories are read **in order and one at a time**, which is what makes the progress
    /// line legible ("konduit: 120 of about 340") and what keeps the request rate to one in
    /// flight. Each repository is stored as it is paged, so a cancel halfway through keeps
    /// everything read so far — the table is an upsert, so the next run simply reads it again.
    /// - Parameters:
    ///   - repos: The repositories to read, in the order they should be read.
    ///   - since: The oldest close date to include. Defaults to the ninety-day window.
    ///   - progress: Called after every page, on the actor's own executor. Sendable, because the
    ///     caller is a `@MainActor` view model that hops back.
    /// - Returns: What the run did, including the repositories that failed and whether it was
    ///   cancelled.
    public func run(
        repos: [RepoRef],
        since: Date? = nil,
        progress: @Sendable @escaping (TrackRecordBackfillProgress) -> Void = { _ in }
    ) async -> TrackRecordBackfillResult {
        let cutoff = since ?? TrackRecord.windowStart(from: now())
        var result = TrackRecordBackfillResult()
        for (index, repo) in repos.enumerated() {
            if Task.isCancelled {
                result.wasCancelled = true
                return result
            }
            do {
                let repositoryResult = try await backfill(
                    repo: repo,
                    since: cutoff,
                    repositoryIndex: index + 1,
                    repositoryCount: repos.count,
                    progress: progress
                )
                result.stored += repositoryResult.stored
                result.revertsLinked += repositoryResult.revertsLinked
                if repositoryResult.wasCapped {
                    result.cappedRepositories.append(repo)
                }
                if repositoryResult.wasCancelled {
                    result.wasCancelled = true
                    return result
                }
            } catch is CancellationError {
                result.wasCancelled = true
                return result
            } catch {
                // A cancellation does not always arrive as a `CancellationError`: a `URLSession`
                // task cancelled mid-flight surfaces as a transport failure, and reporting
                // "could not read konduit" to somebody who just pressed *Stop* would be a lie
                // about their own click.
                if Task.isCancelled {
                    result.wasCancelled = true
                    return result
                }
                // Otherwise: one repository's failure is one line in the UI, not the end of the
                // run. The commonest cause is a repository the token cannot search, and the other
                // five repositories' histories are still worth having.
                result.failures.append(
                    TrackRecordBackfillFailure(
                        repo: repo,
                        message: describe(error),
                        error: error as? GitHubError
                    )
                )
            }
        }
        return result
    }

    /// What one repository's pass produced.
    private struct RepositoryOutcome {
        var stored = 0
        var revertsLinked = 0
        var wasCapped = false
        var wasCancelled = false
    }

    private func backfill(
        repo: RepoRef,
        since: Date,
        repositoryIndex: Int,
        repositoryCount: Int,
        progress: @Sendable (TrackRecordBackfillProgress) -> Void
    ) async throws -> RepositoryOutcome {
        var outcome = RepositoryOutcome()
        var cursor: String? = nil
        var collected: [ClosedPullRequest] = []

        while true {
            if Task.isCancelled {
                outcome.wasCancelled = true
                break
            }
            let remaining = Self.maximumPullRequestsPerRepository - outcome.stored
            guard remaining > 0 else {
                outcome.wasCapped = true
                break
            }
            let page = try await reader.searchClosedPullRequests(
                repo: repo,
                since: since,
                cursor: cursor,
                pageSize: min(Self.pageSize, remaining)
            )
            // A page can carry fewer rows than it returned nodes: `search(type: ISSUE)` also
            // matches plain issues, and a node the mapper could not read is dropped rather than
            // faked (`ResponseMapping.closedPullRequest`).
            let batch = Array(page.pullRequests.prefix(remaining))
            if !batch.isEmpty {
                outcome.stored += try await store.savePullRequestOutcomes(batch)
                collected.append(contentsOf: batch)
            }
            progress(
                TrackRecordBackfillProgress(
                    repo: repo,
                    stored: outcome.stored,
                    estimatedTotal: max(page.totalCount, outcome.stored),
                    repositoryIndex: repositoryIndex,
                    repositoryCount: repositoryCount
                )
            )
            guard page.hasNextPage, let next = page.endCursor else { break }
            cursor = next
            if outcome.stored >= Self.maximumPullRequestsPerRepository {
                outcome.wasCapped = true
                break
            }
        }

        // Linked once per repository rather than once per page: a `Revert "…"` can appear in an
        // earlier page than the pull request it undoes, so a per-page pass would miss exactly the
        // pairs the badge's "2 reverted" is made of. `known` is what is already on disk — which
        // includes everything this pass just wrote — so a revert whose target the *last* run
        // imported is linked too.
        // Not after a stop: "the pager stops between pages" is the promise, and the links can
        // wait for the next run, which reads everything on disk anyway.
        if !collected.isEmpty, !outcome.wasCancelled {
            let known = try await store.mergedClosedPullRequests(repo: repo, since: since)
            let links = RevertDetector.links(candidates: collected, known: known)
            outcome.revertsLinked = try await store.applyRevertLinks(links)
        }
        return outcome
    }

    /// One line for a failure, without leaking a Swift type name into the UI where the server
    /// gave a sentence.
    private func describe(_ error: any Error) -> String {
        if let githubError = error as? GitHubError,
           let description = githubError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
