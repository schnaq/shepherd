import Foundation
import ShepherdCore

/// Turning a `shepherd://` URL into navigation (ADR 0013).
///
/// The parsing is in ``DeepLink`` (ShepherdCore, unit-tested on Linux); this is only the
/// routing, and it deliberately goes through the same surfaces the menu bar and the ⌘K palette
/// use — ``AppEnvironment/route``, ``AppEnvironment/openReview(prID:composing:)``,
/// ``AppEnvironment/syncNow()`` and a pending-request slot the owning screen consumes. Nothing
/// here reaches into a model a screen owns.
extension AppEnvironment {
    /// One thing a deep link asked for, waiting for the screen that owns the state to do it.
    ///
    /// The identity is the whole point of the wrapper: the value alone is `Equatable`, so a
    /// second `shepherd://inbox?filter=agents` while the first is still on the slot would compare
    /// equal to it and the screen would never notice the new request. A fresh `UUID` per request
    /// makes two identical asks two asks — exactly as ``PendingAction`` does for shortcuts.
    struct Pending<Value: Equatable>: Equatable, Identifiable {
        /// Makes two identical requests distinguishable.
        let id = UUID()
        /// What was asked for.
        let value: Value

        /// Wraps a request.
        /// - Parameter value: What was asked for.
        init(_ value: Value) {
            self.value = value
        }
    }

    // MARK: - Entry point

    /// Handles a URL the system handed to the app (`onOpenURL`).
    ///
    /// The URL is untrusted input: anything that can call `open(1)` can send one. Everything it
    /// is allowed to mean is in ``DeepLink``; anything else becomes a toast and nothing else.
    /// - Parameter url: The incoming URL.
    func open(deepLinkURL url: URL) {
        guard let link = DeepLink.parse(url) else {
            toasts.show(
                Toast(
                    message: String(
                        localized: "Shepherd did not understand the link “\(url.absoluteString)”."
                    ),
                    kind: .warning
                )
            )
            return
        }
        open(link)
    }

    /// Runs a deep link, or remembers it until there is a session to run it with.
    /// - Parameter link: The parsed link.
    func open(_ link: DeepLink) {
        switch phase {
        case .signedIn(let session):
            run(link, in: session)
        case .launching:
            // The Keychain lookup is still in flight; ``bootstrap()`` replays this.
            pendingDeepLink = link
        case .signedOut:
            pendingDeepLink = link
            announceDeepLinkNeedsSignIn()
        }
    }

    /// Says why a link that just arrived is not doing anything yet.
    ///
    /// Called both when a link arrives on the sign-in screen and when the launch check ends
    /// there — a link that silently does nothing is indistinguishable from a broken one.
    func announceDeepLinkNeedsSignIn() {
        guard pendingDeepLink != nil else { return }
        toasts.info(
            String(localized: "Sign in to Shepherd — the link will open right afterwards.")
        )
    }

    /// Runs the link that arrived before sign-in, if there was one.
    ///
    /// Called at the end of a successful session start, which is the first moment any deep link
    /// can do something.
    func runPendingDeepLink() {
        guard let link = pendingDeepLink, case .signedIn(let session) = phase else { return }
        pendingDeepLink = nil
        run(link, in: session)
    }

    /// Forgets a queued deep link — on sign-out it would run against a different account.
    func clearPendingDeepLink() {
        pendingDeepLink = nil
    }

    /// Clears the inbox filter request after the inbox has applied it.
    func clearPendingInboxFilter() {
        pendingInboxFilter = nil
    }

    // MARK: - Routing

    private func run(_ link: DeepLink, in session: SignedInSession) {
        switch link {
        case .pullRequest(let repo, let number):
            openPullRequest(repo: repo, number: number, in: session)
        case .issue(let repo, let number):
            openIssue(repo: repo, number: number, in: session)
        case .inbox(let filter):
            route = .inbox
            pendingInboxFilter = filter.map { Pending($0) }
        case .fleet(let agentID):
            // Straight to the method the rail row, the ⌘K command and the track-record popover
            // all use (ADR 0035), rather than assigning ``route`` here: `openFleet(agentID:)`
            // also ends a running focus session, and a link that navigated *without* ending it
            // would leave the session's bar on screen naming a pull request the window is no
            // longer showing. One implementation of "show the fleet", exactly as `.pullRequest`
            // has one of "open the review screen".
            //
            // An id the registry does not know needs nothing here: the grammar guarantees it is
            // *shaped* like an id (never a login), and answering an unknown one is the screen's
            // job, which is where the list it would fall back to already is.
            openFleet(agentID: agentID)
        case .sync:
            toasts.info(String(localized: "Syncing all repositories…"))
            Task { await syncNow() }
        case .settings(let tab):
            // Straight to the method the rail's gear and the fleet's empty state use, and for
            // `.fleet`'s reason above: one implementation of "show Settings". No `route` change
            // beside it — Settings is a second window, so the link no longer drags whoever was
            // on the review screen back to the inbox to see it.
            showSettings(tab)
        }
    }

    /// Opens the review screen for a pull request named by `owner/repo/number`.
    ///
    /// The cache is asked first, because that is free and covers every pull request in the
    /// inbox. When the pull request is *not* cached the app fetches that one pull request
    /// directly instead of starting a sweep: a sweep searches `involves:@me`, so it would not
    /// find a pull request the user is not involved in — which is exactly the link somebody
    /// sends you in chat — and it would cost several seconds of API calls to fail. The fetched
    /// detail is written to the database, so the review screen renders from SQLite like every
    /// other screen (ADR 0006).
    private func openPullRequest(repo: RepoRef, number: Int, in session: SignedInSession) {
        Task {
            let cached = (try? await session.database.fetchInbox()) ?? []
            if let prID = AppEnvironment.pullRequestID(repo: repo, number: number, in: cached) {
                openReview(prID: prID)
                return
            }
            // The fetch can take a second or two and there is no screen to spin on yet.
            toasts.info(String(localized: "Fetching \(repo.fullName)#\(number) from GitHub…"))
            do {
                let detail = try await session.github.pullRequestDetail(repo: repo, number: number)
                try? await session.database.savePullRequestDetail(detail)
                openReview(prID: detail.id)
            } catch {
                toasts.failure(
                    error,
                    context: String(localized: "Could not open \(repo.fullName)#\(number)")
                )
            }
        }
    }

    /// Opens the issues section on the issue named by `owner/repo/number` (ADR 0032).
    ///
    /// ``openPullRequest(repo:number:in:)``'s rule, unchanged and for its reason. The cache is
    /// asked first, because that is free and covers every issue in the inbox. When the issue is
    /// *not* cached the app fetches that one issue and stores it, so the section renders from
    /// SQLite like every other screen (ADR 0006) — a sweep searches
    /// `assignee:`/`author:`/`mentions:@me`, so it would not find an issue somebody sent the user
    /// in chat, and it would cost several API calls to fail.
    ///
    /// `pruneMissing: false` on the write is the one difference worth naming: this is a row the
    /// *link* asked for, not the result of a sweep, so it must not be treated as the new complete
    /// set and take the whole issues inbox with it.
    private func openIssue(repo: RepoRef, number: Int, in session: SignedInSession) {
        Task {
            let cached = (try? await session.database.fetchIssues()) ?? []
            if let issueID = AppEnvironment.issueID(repo: repo, number: number, in: cached) {
                openIssue(issueID: issueID)
                return
            }
            // The fetch can take a second or two and there is no row to select yet.
            toasts.info(String(localized: "Fetching \(repo.fullName)#\(number) from GitHub…"))
            do {
                guard let row = try await session.github.issueRow(repo: repo, number: number)
                else {
                    toasts.show(
                        Toast(
                            message: String(
                                localized: "\(repo.fullName)#\(number) is not an issue Shepherd can open."
                            ),
                            kind: .warning
                        )
                    )
                    return
                }
                try? await session.database.saveIssueSummaries([row], pruneMissing: false)
                openIssue(issueID: row.id)
            } catch {
                toasts.failure(
                    error,
                    context: String(localized: "Could not open \(repo.fullName)#\(number)")
                )
            }
        }
    }

    /// Finds a cached issue by repository and number.
    ///
    /// ``pullRequestID(repo:number:in:)``'s twin, case-insensitive for its reason: a link carries
    /// whatever casing was typed while the cache holds the casing GitHub returned.
    /// - Parameters:
    ///   - repo: The repository from the link.
    ///   - number: The issue number from the link.
    ///   - rows: The cached issue rows.
    /// - Returns: The issue's node id, or `nil` when it is not cached.
    nonisolated static func issueID(
        repo: RepoRef,
        number: Int,
        in rows: [IssueRowSummary]
    ) -> String? {
        rows.first { $0.number == number && $0.repo.isSameRepository(as: repo) }?.id
    }

    /// Finds a cached pull request by repository and number.
    ///
    /// The repository comparison ignores case: a link may carry whatever casing was typed,
    /// while the cache holds the casing GitHub returned.
    /// - Parameters:
    ///   - repo: The repository from the link.
    ///   - number: The pull-request number from the link.
    ///   - rows: The cached inbox rows.
    /// - Returns: The pull request's node id, or `nil` when it is not cached.
    nonisolated static func pullRequestID(
        repo: RepoRef,
        number: Int,
        in rows: [PullRequestSummary]
    ) -> String? {
        rows.first { $0.number == number && $0.repo.isSameRepository(as: repo) }?.id
    }
}
