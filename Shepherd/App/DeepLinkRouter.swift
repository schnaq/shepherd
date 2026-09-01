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
    /// An inbox rail filter waiting for the inbox screen to apply it.
    struct PendingInboxFilter: Equatable, Identifiable {
        /// Makes two identical requests distinguishable, exactly as ``PendingAction`` does.
        let id = UUID()
        /// The filter to apply.
        let filter: InboxDeepLinkFilter
    }

    /// A Settings tab waiting to be presented.
    struct PendingSettingsTab: Equatable, Identifiable {
        /// Makes two identical requests distinguishable.
        let id = UUID()
        /// The tab to open on.
        let tab: SettingsDeepLinkTab
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

    /// Clears the Settings tab request after it has been presented.
    func clearPendingSettingsTab() {
        pendingSettingsTab = nil
    }

    // MARK: - Routing

    private func run(_ link: DeepLink, in session: SignedInSession) {
        switch link {
        case .pullRequest(let repo, let number):
            openPullRequest(repo: repo, number: number, in: session)
        case .inbox(let filter):
            route = .inbox
            pendingInboxFilter = filter.map { PendingInboxFilter(filter: $0) }
        case .sync:
            toasts.info(String(localized: "Syncing all repositories…"))
            Task { await syncNow() }
        case .settings(let tab):
            route = .inbox
            pendingSettingsTab = PendingSettingsTab(tab: tab)
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
