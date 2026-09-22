import Foundation
import ShepherdCore

/// How a pull request should be merged.
public enum MergeMethod: String, Sendable, Codable, Hashable, CaseIterable {
    /// Create a merge commit.
    case merge
    /// Squash the branch into a single commit.
    case squash
    /// Replay the commits onto the base branch.
    case rebase
}

/// The single façade over GitHub's GraphQL and REST APIs (ADR 0005).
///
/// One actor owns one `URLSession`-backed transport, the conditional-request cache, the
/// rate-limit state and the concurrency cap on detail fetches. Callers never see the split
/// between GraphQL and REST:
///
/// - **Reads of the inbox** go through one GraphQL `search` sweep per facet.
/// - **Detail reads** combine REST (`/pulls/{n}`, `/files`, `/commits`, `/reviews`,
///   `/check-runs`) with two GraphQL queries: review threads, because thread ids — and the
///   mutations that resolve them — exist only in GraphQL, and the issues the pull request
///   closes, because REST carries the description's `closes #123` text but not the references
///   GitHub resolved out of it (ADR 0032).
/// - **Writes** are REST, except thread resolution and "ready for review", which are
///   GraphQL-only.
public actor GitHubClient {
    private let configuration: GitHubConfiguration
    private let transport: any HTTPTransport
    private let tokenProvider: any AccessTokenProviding
    private let cache: any ConditionalCache
    private let sleeper: any Sleeping
    private let detector: AgentDetector
    private let detailSemaphore: AsyncSemaphore
    private let now: @Sendable () -> Date

    /// The most recent rate-limit counters GitHub reported, for the Settings screen.
    public private(set) var latestRateLimit: RateLimitSnapshot?

    /// Creates a client.
    /// - Parameters:
    ///   - configuration: Endpoints and tunables.
    ///   - transport: The HTTP transport; production wraps one shared `URLSession`.
    ///   - tokenProvider: Supplies the bearer token for every request.
    ///   - agentDetector: Classifies pull-request authors as human, bot or agent.
    ///   - cache: Conditional-request storage. Defaults to an in-memory cache; the app wires
    ///     in the SQLite-backed one from `ShepherdPersistence`.
    ///   - sleeper: The delay abstraction used for rate-limit backoff.
    ///   - now: Clock injection point for tests.
    public init(
        configuration: GitHubConfiguration = GitHubConfiguration(),
        transport: any HTTPTransport,
        tokenProvider: any AccessTokenProviding,
        agentDetector: AgentDetector,
        cache: any ConditionalCache = InMemoryConditionalCache(),
        sleeper: any Sleeping = SystemSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.detector = agentDetector
        self.cache = cache
        self.sleeper = sleeper
        self.now = now
        self.detailSemaphore = AsyncSemaphore(value: configuration.maxConcurrentDetailFetches)
    }

    // MARK: - Inbox sweep

    /// Runs the inbox sweep: one GraphQL `search` per facet, merged into one list.
    ///
    /// Rows returned by several facets are merged and their ``Relation``s unioned, so a pull
    /// request the user authored *and* was asked to review carries both.
    /// - Parameter queries: The facet queries. Defaults to ``InboxQuery/defaultSweep``.
    /// - Returns: The inbox rows, sorted most-recently-updated first.
    public func searchOpenPullRequests(
        queries: [InboxQuery] = InboxQuery.defaultSweep
    ) async throws -> [PullRequestSummary] {
        var collected: [PullRequestSummary] = []
        for query in queries {
            let page = try await search(query)
            collected.append(contentsOf: page)
        }
        return ResponseMapping.mergeFacetResults(collected)
    }

    private func search(_ query: InboxQuery) async throws -> [PullRequestSummary] {
        var results: [PullRequestSummary] = []
        var cursor: String? = nil
        // Five pages of 100 is 500 open pull requests per facet — far beyond any inbox a
        // human can triage, and a hard stop against a pathological account.
        for _ in 0..<5 {
            var variables: [String: GraphQLValue] = [
                "q": .string(query.rawQuery),
                "first": .int(100),
            ]
            variables["after"] = cursor.map { GraphQLValue.string($0) } ?? .null

            let data: SearchPullRequestsData = try await graphQL(
                document: GraphQLDocuments.searchPullRequests,
                variables: variables,
                resource: "search",
                isIdempotent: true
            )
            let nodes = (data.search?.nodes ?? []).compactMap { $0 }
            for node in nodes {
                if let summary = ResponseMapping.pullRequestSummary(
                    from: node,
                    relations: query.impliedRelations,
                    detector: detector
                ) {
                    results.append(summary)
                }
            }
            guard data.search?.pageInfo?.hasNextPage == true,
                  let next = data.search?.pageInfo?.endCursor
            else { break }
            cursor = next
        }
        return results
    }

    // MARK: - Issues sweep (ADR 0032)

    /// Runs the issues sweep: one GraphQL `search` per facet, merged into one list.
    ///
    /// The pull-request sweep's twin in every respect that matters — the same connection, the
    /// same five-page cap, the same merge-by-id — so it inherits the retry, the `Retry-After`
    /// backoff, the rate-limit snapshot and the request log rather than growing a second read
    /// path. It adds no host: this is `api.github.com`, the host Shepherd already talks to.
    ///
    /// Rows returned by several facets are merged and their ``IssueRelation``s unioned, so an
    /// issue the user opened *and* was assigned carries both.
    /// - Parameter queries: The facet queries. Defaults to ``IssueQuery/defaultSweep``.
    /// - Returns: The issue rows, most-recently-updated first.
    /// - Throws: Any ``GitHubError`` the request maps to.
    public func searchOpenIssues(
        queries: [IssueQuery] = IssueQuery.defaultSweep
    ) async throws -> [IssueRowSummary] {
        var collected: [IssueRowSummary] = []
        for query in queries {
            let page = try await searchIssues(query)
            collected.append(contentsOf: page)
        }
        return ResponseMapping.mergeIssueFacetResults(collected)
    }

    private func searchIssues(_ query: IssueQuery) async throws -> [IssueRowSummary] {
        var results: [IssueRowSummary] = []
        var cursor: String? = nil
        // Five pages of 100, the sweep's own cap: 500 open issues per facet is far beyond any
        // inbox a human can triage, and a hard stop against a pathological account.
        for _ in 0..<5 {
            var variables: [String: GraphQLValue] = [
                "q": .string(query.rawQuery),
                "first": .int(100),
            ]
            variables["after"] = cursor.map { GraphQLValue.string($0) } ?? .null

            let data: SearchIssuesData = try await graphQL(
                document: GraphQLDocuments.searchIssues,
                variables: variables,
                resource: "search",
                isIdempotent: true
            )
            let nodes = (data.search?.nodes ?? []).compactMap { $0 }
            for node in nodes {
                if let summary = ResponseMapping.issueRowSummary(
                    from: node,
                    relations: query.impliedRelations,
                    detector: detector
                ) {
                    results.append(summary)
                }
            }
            guard data.search?.pageInfo?.hasNextPage == true,
                  let next = data.search?.pageInfo?.endCursor
            else { break }
            cursor = next
        }
        return results
    }

    /// Fetches one issue as an inbox row, by repository and number (ADR 0032).
    ///
    /// What a `shepherd://issue/<owner>/<repo>/<number>` link falls back to when the row is not
    /// in the local cache, and it is `openPullRequest`'s argument applied to issues: the sweep
    /// searches `assignee:`/`author:`/`mentions:@me`, so an issue a colleague sends you is
    /// routinely not in the inbox, and running a sweep would be slow *and* still miss it.
    ///
    /// GraphQL rather than the REST read beside it (``issue(repo:number:)``), because the two
    /// answer different questions: that one is the claims card's body read and has no node id,
    /// no author and no timestamps, while this has to produce a row the `issues` table can hold.
    /// One query, the same document shape the sweep pages, the same mapper — and **no relation**,
    /// deliberately: a link says nothing about how the user relates to the issue, and
    /// `saveIssueSummaries`' "an empty relation keeps what the sweep saw" rule means storing this
    /// row cannot erase the facets a swept copy already has.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    /// - Returns: The row, or `nil` when the repository has no issue with that number — which is
    ///   an ordinary answer for a number somebody typed, not a failure.
    /// - Throws: Any ``GitHubError`` the request maps to.
    public func issueRow(repo: RepoRef, number: Int) async throws -> IssueRowSummary? {
        let data: IssueByNumberData = try await graphQL(
            document: GraphQLDocuments.issueByNumber,
            variables: [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
            ],
            resource: "\(repo.fullName)#\(number) issue",
            isIdempotent: true
        )
        guard let node = data.repository?.issue else { return nil }
        return ResponseMapping.issueRowSummary(from: node, relations: [], detector: detector)
    }

    // MARK: - Detail

    /// Fetches everything Shepherd shows on a pull request page.
    ///
    /// Concurrency is capped at ``GitHubConfiguration/maxConcurrentDetailFetches`` across all
    /// callers of this method — a sweep that finds twenty changed pull requests must not fire
    /// twenty detail fetches at once (ADR 0005).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: The fully populated detail record.
    public func pullRequestDetail(repo: RepoRef, number: Int) async throws -> PullRequestDetail {
        await detailSemaphore.wait()
        do {
            let detail = try await fetchDetail(repo: repo, number: number)
            await detailSemaphore.signal()
            return detail
        } catch {
            await detailSemaphore.signal()
            throw error
        }
    }

    private func fetchDetail(repo: RepoRef, number: Int) async throws -> PullRequestDetail {
        let pullResponse = try await performREST(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)",
            queryItems: [],
            body: nil,
            useCache: true,
            resource: "\(repo.fullName)#\(number)"
        )
        let pullDTO: RESTPullRequestDTO = try RESTJSON.decode(pullResponse.body)

        let fileList = try await changedFiles(repo: repo, number: number)
        let commitList = try await commits(repo: repo, number: number)
        let reviewList = try await reviews(repo: repo, number: number)
        let threadList = try await reviewThreads(repo: repo, number: number)
        // The one read of this fetch whose failure is tolerated (ADR 0032, Sprint 3). Everything
        // else here is the review screen: without the files, the commits or the threads there is
        // nothing to review, so those errors travel. The closing issues are a section *above* the
        // description, and a pull request whose links GitHub declined to resolve — a token that
        // cannot see the issues' repository, one field erroring inside an otherwise fine
        // response — is still a pull request worth reviewing. The attempt is not lost either: it
        // is in the in-app request log like every other request, through
        // ``GitHubConfiguration/requestLogger``, which is this package's only logging channel
        // (Foundation-only, Linux-tested, no `os.log`).
        let closingIssueList = (try? await closingIssues(repo: repo, number: number)) ?? []
        let headSHA = pullDTO.head?.sha ?? ""
        var checkList: [CheckRun] = []
        if !headSHA.isEmpty {
            checkList = try await checkRuns(repo: repo, ref: headSHA)
        }

        let reviewDecisionValue = Self.reviewDecision(from: reviewList)
        let rollup = checkList.isEmpty ? nil : CheckRollup(runs: checkList)
        let trailers = commitList.flatMap(\.trailers)

        guard let summary = ResponseMapping.pullRequestSummary(
            from: pullDTO,
            repo: repo,
            relations: [],
            reviewDecisionValue: reviewDecisionValue,
            rollup: rollup,
            detector: detector,
            commitTrailers: trailers
        ) else {
            throw GitHubError.decoding(
                message: "Pull request \(repo.fullName)#\(number) was missing required fields"
            )
        }

        return PullRequestDetail(
            summary: summary,
            bodyMarkdown: pullDTO.body ?? "",
            commits: commitList,
            files: fileList,
            threads: threadList,
            timeline: ResponseMapping.timeline(
                commits: commitList,
                reviews: reviewList,
                detector: detector
            ),
            checks: checkList,
            closingIssues: closingIssueList
        )
    }

    /// Fetches the issues GitHub says merging this pull request will close (ADR 0032).
    ///
    /// GraphQL-only, like ``reviewThreads(repo:number:)`` beside which it is read: REST's pull
    /// request carries the description's `closes #123` text but not the *resolved* references,
    /// and resolving them in the app would mean re-implementing GitHub's keyword parsing and
    /// still getting cross-repository references wrong.
    ///
    /// One page of ten and no pagination: the section lists what it gets, and a description that
    /// names an eleventh issue is a release note rather than a link.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: The references, in GitHub's own order. Empty when the pull request closes
    ///   nothing.
    /// - Throws: Any ``GitHubError`` the request maps to. ``pullRequestDetail(repo:number:)``
    ///   tolerates every one of them and shows no section; a caller that asks on its own gets
    ///   the error.
    public func closingIssues(
        repo: RepoRef,
        number: Int
    ) async throws -> [LinkedIssueReference] {
        let data: PullRequestClosingIssuesData = try await graphQL(
            document: GraphQLDocuments.pullRequestClosingIssues,
            variables: [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
            ],
            resource: "\(repo.fullName)#\(number) closing issues",
            isIdempotent: true
        )
        return ResponseMapping.closingIssues(from: data)
    }

    /// Derives an aggregate review decision from the review listing.
    ///
    /// REST does not expose `reviewDecision`; the last review per author decides, and a
    /// single outstanding "changes requested" outranks any number of approvals.
    static func reviewDecision(from reviews: [RESTReviewDTO]) -> ReviewDecision? {
        var latestByAuthor: [String: String] = [:]
        for review in reviews {
            guard let login = review.user?.login, let state = review.state?.uppercased() else {
                continue
            }
            guard state == "APPROVED" || state == "CHANGES_REQUESTED" || state == "DISMISSED"
            else { continue }
            latestByAuthor[login] = state
        }
        if latestByAuthor.values.contains("CHANGES_REQUESTED") { return .changesRequested }
        if latestByAuthor.values.contains("APPROVED") { return .approved }
        return nil
    }

    /// Fetches the changed files of a pull request, following pagination.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    public func changedFiles(repo: RepoRef, number: Int) async throws -> [ChangedFile] {
        var result: [ChangedFile] = []
        for page in 1...30 {
            let response = try await performREST(
                method: "GET",
                path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/files",
                queryItems: [
                    ("per_page", String(configuration.pageSize)),
                    ("page", String(page)),
                ],
                body: nil,
                useCache: true,
                resource: "\(repo.fullName)#\(number) files"
            )
            let dtos: [RESTFileDTO] = try RESTJSON.decode(response.body)
            result.append(contentsOf: dtos.compactMap(ResponseMapping.changedFile(from:)))
            if dtos.count < configuration.pageSize { break }
        }
        return result
    }

    /// Fetches the commits of a pull request, following pagination.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    public func commits(repo: RepoRef, number: Int) async throws -> [CommitInfo] {
        var result: [CommitInfo] = []
        for page in 1...10 {
            let response = try await performREST(
                method: "GET",
                path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/commits",
                queryItems: [
                    ("per_page", String(configuration.pageSize)),
                    ("page", String(page)),
                ],
                body: nil,
                useCache: true,
                resource: "\(repo.fullName)#\(number) commits"
            )
            let dtos: [RESTCommitDTO] = try RESTJSON.decode(response.body)
            result.append(
                contentsOf: dtos.compactMap { ResponseMapping.commit(from: $0, detector: detector) }
            )
            if dtos.count < configuration.pageSize { break }
        }
        return result
    }

    /// Fetches the submitted reviews of a pull request.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    func reviews(repo: RepoRef, number: Int) async throws -> [RESTReviewDTO] {
        let response = try await performREST(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/reviews",
            queryItems: [("per_page", String(configuration.pageSize))],
            body: nil,
            useCache: true,
            resource: "\(repo.fullName)#\(number) reviews"
        )
        return try RESTJSON.decode(response.body)
    }

    /// Fetches the check runs of a commit, following pagination.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - ref: The commit SHA (or any ref).
    public func checkRuns(repo: RepoRef, ref: String) async throws -> [CheckRun] {
        var result: [CheckRun] = []
        for page in 1...10 {
            let response = try await performREST(
                method: "GET",
                path: "/repos/\(repo.owner)/\(repo.name)/commits/\(ref)/check-runs",
                queryItems: [
                    ("per_page", String(configuration.pageSize)),
                    ("page", String(page)),
                ],
                body: nil,
                useCache: true,
                resource: "\(repo.fullName) checks for \(ref)"
            )
            let dto: RESTCheckRunsDTO = try RESTJSON.decode(response.body)
            let runs = dto.checkRuns ?? []
            result.append(contentsOf: runs.compactMap(ResponseMapping.checkRun(from:)))
            if runs.count < configuration.pageSize { break }
        }
        return result
    }

    // MARK: - Issue (ADR 0026's amendment)

    /// Fetches one referenced issue, so the claims card can check `fixes #N` against its
    /// acceptance bullets.
    ///
    /// **One `GET`, conditionally cached, and only when a reviewer opens the card.** REST rather
    /// than GraphQL for the reason ADR 0005 gives for `/pulls/{n}` and `/check-runs`: GraphQL
    /// earns its keep on the inbox *sweep*, where one query replaces fifty requests, and a single
    /// resource by number is one request either way — while the REST URL is what makes the
    /// conditional-request cache work at all, since ``cacheKey(for:)`` keys on the URL and every
    /// GraphQL document shares one. The URL is immutable (`/repos/o/r/issues/142`), so unlike
    /// `/check-runs` it leaves exactly one cache row behind however often it is read, and the
    /// second reviewer to open the same card pays a `304`.
    ///
    /// The endpoint answers for pull requests too; the result carries
    /// ``ShepherdCore/IssueSummary/isPullRequest`` so the caller can tell, rather than this
    /// method refusing — `#142` pointing at a pull request is a normal description and the card
    /// has something honest to say about it.
    /// - Parameters:
    ///   - repo: The repository. Always the pull request's own: a `fixes #N` reference is
    ///     repository-local and Shepherd does not resolve `owner/repo#N`.
    ///   - number: The issue number.
    /// - Returns: The issue, with its body as Markdown source.
    /// - Throws: Any ``GitHubError`` the request maps to — ``GitHubError/notFound(resource:)`` for
    ///   an issue that does not exist, ``GitHubError/forbidden(message:)`` for one this token
    ///   cannot see. Both are ordinary answers for a reference somebody typed, and the card turns
    ///   them into a sentence rather than a toast.
    public func issue(repo: RepoRef, number: Int) async throws -> IssueSummary {
        let response = try await performREST(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)",
            queryItems: [],
            body: nil,
            useCache: true,
            resource: "\(repo.fullName)#\(number) issue"
        )
        let dto: RESTIssueDTO = try RESTJSON.decode(response.body)
        guard let summary = ResponseMapping.issueSummary(from: dto, repo: repo) else {
            throw GitHubError.decoding(
                message: "\(repo.fullName)#\(number) came back without an issue number"
            )
        }
        return summary
    }

    // MARK: - Closed pull requests (ADR 0027)

    /// How many closed pull requests one page asks for. GitHub caps `search` at 100.
    public static let closedPullRequestPageSize = 100

    /// One page of a repository's closed pull requests, for the track-record backfill.
    ///
    /// The same `search(type: ISSUE)` connection the inbox sweep runs, with `is:closed` in place
    /// of `is:open` and one repository at a time (``InboxQuery/closedPullRequests(in:since:calendar:)``).
    /// So it inherits everything the sweep has — the retry, the `Retry-After` backoff, the
    /// rate-limit snapshot, the request log — and adds no host: this is `api.github.com`, the
    /// host Shepherd already talks to.
    ///
    /// **Conditional requests.** Unlike every other read in this client, a GraphQL request cannot
    /// be keyed on its URL: there is one endpoint and one URL for every document. So this read
    /// names its own cache key — the repository, the window and the cursor, which is exactly what
    /// makes two runs of the backfill ask the same question — and the entry is stored only when
    /// GitHub actually sends a validator. A page whose `ETag` comes back unchanged is answered
    /// from the local cache and costs no rate-limit budget; a page GitHub sends no validator for
    /// simply is not cached, which is a missed optimisation and never a wrong answer.
    ///
    /// - Parameters:
    ///   - repo: The repository to read.
    ///   - since: The oldest close date to include; the window the user asked for.
    ///   - cursor: The `endCursor` of the previous page, or `nil` for the first.
    ///   - pageSize: How many pull requests to ask for. Clamped to `1...100`.
    /// - Returns: The page, with the cursor for the next one when there is one.
    /// - Throws: Any ``GitHubError`` the request maps to.
    public func searchClosedPullRequests(
        repo: RepoRef,
        since: Date,
        cursor: String? = nil,
        pageSize: Int = GitHubClient.closedPullRequestPageSize
    ) async throws -> ClosedPullRequestPage {
        let query = InboxQuery.closedPullRequests(in: repo, since: since)
        let size = min(100, max(1, pageSize))
        var variables: [String: GraphQLValue] = [
            "q": .string(query),
            "first": .int(size),
        ]
        variables["after"] = cursor.map { GraphQLValue.string($0) } ?? .null

        let data: SearchClosedPullRequestsData = try await graphQL(
            document: GraphQLDocuments.searchClosedPullRequests,
            variables: variables,
            resource: "\(repo.fullName) closed pull requests",
            isIdempotent: true,
            cacheKey: "graphql:closedPullRequests:\(query):\(size):\(cursor ?? "-")"
        )
        let nodes = (data.search?.nodes ?? []).compactMap { $0 }
        let closed = nodes.compactMap {
            ResponseMapping.closedPullRequest(from: $0, detector: detector, source: .backfill)
        }
        return ClosedPullRequestPage(
            pullRequests: closed,
            totalCount: data.search?.issueCount ?? closed.count,
            hasNextPage: data.search?.pageInfo?.hasNextPage ?? false,
            endCursor: data.search?.pageInfo?.endCursor
        )
    }

    /// The final state of one pull request, read by number.
    ///
    /// What the sweep uses when an open pull request disappears from the inbox: **one** GraphQL
    /// request, not a detail fetch — the six REST reads `pullRequestDetail(repo:number:)` makes
    /// would be five too many for a pull request nobody is going to open, and none of them
    /// carries `merged` or `closedAt` anyway.
    ///
    /// Not conditionally cached: a closed pull request is read once and then never again, so a
    /// cache entry could only ever be an unreachable row holding a response body — the argument
    /// ``cacheKey(for:)`` already makes about `/check-runs`.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: The closed pull request, or `nil` when GitHub says it is still open — which is
    ///   a normal answer: a pull request can leave the inbox because the user's search facets
    ///   stopped matching it.
    /// - Throws: Any ``GitHubError`` the request maps to, including
    ///   ``GitHubError/notFound(resource:)`` for a pull request that no longer exists.
    public func closedPullRequest(
        repo: RepoRef,
        number: Int
    ) async throws -> ClosedPullRequest? {
        let data: ClosedPullRequestData = try await graphQL(
            document: GraphQLDocuments.closedPullRequest,
            variables: [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
            ],
            resource: "\(repo.fullName)#\(number) outcome",
            isIdempotent: true
        )
        guard let node = data.repository?.pullRequest else {
            throw GitHubError.notFound(resource: "\(repo.fullName)#\(number)")
        }
        return ResponseMapping.closedPullRequest(
            from: node,
            detector: detector,
            source: .sync
        )
    }

    // MARK: - Job logs (plan §3.F)

    /// The most bytes a job log may have before it is refused.
    ///
    /// Two megabytes is generous for a log whose *failing region* is what gets used — the tier-1
    /// `LogDigest` reduces it to about a thousand tokens — and it is the point past which
    /// downloading more would only be to throw it away. It is a refusal rather than a silent
    /// prefix because a truncated log's *end* is where a failure summary lives: a digest of the
    /// first two megabytes of a ten-megabyte log would be a confident answer about the wrong
    /// part of the run.
    public static let maximumJobLogBytes = 2 * 1024 * 1024

    /// Downloads the log of one GitHub Actions job (plan §3.F).
    ///
    /// `GET /repos/{owner}/{repo}/actions/jobs/{id}/logs` does not answer with a log: it answers
    /// `302` with a `Location` pointing at a short-lived blob on GitHub's own storage host. Two
    /// things about that shape are decisions rather than mechanics, and both are why this read
    /// does not go through ``perform(method:url:body:accept:useCache:resource:extraHeaders:isIdempotent:)``
    /// like every other one:
    ///
    /// - **The token does not follow the redirect.** The blob URL carries its own signed
    ///   credentials in its query string, so the `Authorization` header is not needed there — and
    ///   a bearer token sent to a host that does not need it is a token in one more place than
    ///   it has to be. The rule is therefore enforced twice, on the two paths a `302` can take.
    ///   A transport that follows redirects itself (``URLSessionTransport`` does, because
    ///   `URLSession` does) answers here with the blob already fetched — and stripped the header
    ///   on that hop, because ``RedirectPolicy`` decided it before `URLSession` sent it. A
    ///   transport that does not follow redirects answers with the `302`, and the second request
    ///   this method makes carries no credentials at all. Either way the redirect is followed
    ///   exactly once: a `Location` that points at another redirect is refused rather than
    ///   chased.
    /// - **It is not ETag-cached.** The URL is keyed by an immutable job id, so every cached
    ///   entry is one more row that can never be replayed — the reason
    ///   ``cacheKey(for:)`` already refuses to cache `/check-runs` — and here each row would hold
    ///   up to ``maximumJobLogBytes`` of log.
    ///
    /// The body is decoded UTF-8 **lossily**: a log is bytes a hundred tools wrote, some of it
    /// binary from a tool that printed a control sequence, and a diagnosis must not fail because
    /// one byte in a megabyte was not valid UTF-8.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - jobID: The Actions job id, from ``ShepherdCore/CheckRun/actionsJobID``.
    /// - Returns: The log as text. Empty when GitHub answered with an empty body.
    /// - Throws: ``GitHubError/responseTooLarge(resource:bytes:limit:)`` when the log is larger
    ///   than ``maximumJobLogBytes``, or any other ``GitHubError`` the status maps to.
    public func jobLog(repo: RepoRef, jobID: Int) async throws -> String {
        let resource = "\(repo.fullName) log of job \(jobID)"
        guard var components = URLComponents(
            url: configuration.apiBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubError.invalidURL(configuration.apiBaseURL.absoluteString)
        }
        let path = "/repos/\(repo.owner)/\(repo.name)/actions/jobs/\(jobID)/logs"
        components.path = (components.path == "/" ? "" : components.path) + path
        guard let url = components.url else {
            throw GitHubError.invalidURL(configuration.apiBaseURL.absoluteString + path)
        }

        var response = try await performLogRequest(url: url, authorized: true, resource: resource)
        if let location = response.header("location").flatMap({ URL(string: $0) }),
           (300..<400).contains(response.statusCode) {
            response = try await performLogRequest(
                url: location,
                authorized: false,
                resource: resource
            )
        }
        guard response.isSuccess else {
            throw Self.mapFailure(response, resource: resource, now: now())
        }
        guard response.body.count <= Self.maximumJobLogBytes else {
            throw GitHubError.responseTooLarge(
                resource: resource,
                bytes: response.body.count,
                limit: Self.maximumJobLogBytes
            )
        }
        return String(decoding: response.body, as: UTF8.self)
    }

    /// One request of the job-log read: no cache, no retry, and credentials only where they are
    /// needed.
    ///
    /// It still records the rate-limit snapshot and the request log, because a log download is a
    /// GitHub request like any other from the Settings screen's point of view — the blob host
    /// simply sends no rate-limit headers, so the snapshot is `nil` there and the counters keep
    /// whatever the API request left them at.
    /// - Parameters:
    ///   - url: The API URL, or the blob URL the redirect named.
    ///   - authorized: Whether to send the bearer token. `false` for the blob.
    ///   - resource: What is being read, for the error and the log entry.
    /// - Returns: The response, whatever its status — non-`2xx` is mapped by the caller.
    private func performLogRequest(
        url: URL,
        authorized: Bool,
        resource: String
    ) async throws -> HTTPResponse {
        var headers: [String: String] = [
            "Accept": "application/vnd.github+json",
            "User-Agent": configuration.userAgent,
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        if authorized {
            headers["Authorization"] = "Bearer \(try await tokenProvider.accessToken())"
        }
        let startedAt = now()
        let response: HTTPResponse
        do {
            response = try await transport.data(
                for: HTTPRequest(method: "GET", url: url, headers: headers, body: nil)
            )
        } catch {
            configuration.requestLogger?(
                GitHubRequestLogEntry(
                    method: "GET",
                    url: url,
                    statusCode: nil,
                    duration: now().timeIntervalSince(startedAt),
                    wasNotModified: false,
                    rateLimit: nil,
                    startedAt: startedAt
                )
            )
            throw (error as? GitHubError) ?? GitHubError.transport(message: String(describing: error))
        }
        let snapshot = RateLimitSnapshot.parse(from: response, observedAt: now())
        if let snapshot {
            latestRateLimit = snapshot
        }
        configuration.requestLogger?(
            GitHubRequestLogEntry(
                method: "GET",
                url: url,
                statusCode: response.statusCode,
                duration: now().timeIntervalSince(startedAt),
                wasNotModified: false,
                rateLimit: snapshot,
                startedAt: startedAt
            )
        )
        return response
    }

    // MARK: - Description screenshots (ADR 0038 item 4)

    /// The most bytes one description screenshot may have before it is refused.
    ///
    /// Eight megabytes covers a full-resolution Retina capture as PNG with room to spare; the model
    /// reads it downscaled to 1,024 pixels either way, so anything larger is bytes downloaded to be
    /// thrown away. A refusal rather than a prefix, because half a PNG does not decode.
    public static let maximumDescriptionImageBytes = 8 * 1024 * 1024

    /// GitHub's HTML rendering of a pull request's description, in which every upload is a
    /// short-lived signed link (ADR 0038 item 4).
    ///
    /// The same `GET /repos/{owner}/{repo}/pulls/{number}` the detail read makes, on the same host
    /// with the same token, asked for `application/vnd.github.html+json` instead. **Not
    /// ETag-cached**: the links in it expire within minutes, so a replayed `304` would hand back
    /// links that no longer open — and the JSON response's cache row, which shares this URL, is
    /// left alone.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: The rendered description; empty when it has none.
    public func pullRequestBodyHTML(repo: RepoRef, number: Int) async throws -> String {
        let response = try await performREST(
            method: "GET",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)",
            queryItems: [],
            body: nil,
            useCache: false,
            resource: "\(repo.fullName)#\(number) description",
            accept: "application/vnd.github.html+json"
        )
        let dto: RESTPullRequestBodyHTMLDTO = try RESTJSON.decode(response.body)
        return dto.bodyHtml ?? ""
    }

    /// Downloads one description screenshot from its signed link (ADR 0038 item 4).
    ///
    /// One plain `GET` with **no `Authorization` header**: the link carries its own signature, and
    /// ``ShepherdCore/DescriptionImages/isDownloadable(_:)`` is asked again here so that only
    /// GitHub's two upload hosts are ever contacted, whatever handed this method the URL — before
    /// the request, and of the URL that answered it, since a redirect from those hosts is refused
    /// by ``RedirectStrippingDelegate`` and must not have been followed by anything else. No cache
    /// and no retry, the job log's shape (``performLogRequest(url:authorized:resource:)``). The
    /// 8 MB cap is checked on the downloaded body, as the job log's is.
    /// - Parameter url: A link from ``ShepherdCore/DescriptionImages/signedSources(for:inBodyHTML:)``.
    /// - Returns: The image's bytes.
    /// - Throws: ``GitHubError/invalidURL(_:)`` for a link on any other host,
    ///   ``GitHubError/responseTooLarge(resource:bytes:limit:)`` past
    ///   ``maximumDescriptionImageBytes``, ``GitHubError/decoding(message:)`` when the answer is not
    ///   an image, or the status's own ``GitHubError``.
    public func descriptionImage(at url: URL) async throws -> Data {
        guard DescriptionImages.isDownloadable(url) else {
            throw GitHubError.invalidURL(url.host ?? url.absoluteString)
        }
        let resource = "description screenshot \(url.lastPathComponent)"
        let response = try await performLogRequest(url: url, authorized: false, resource: resource)
        // The transport may have followed a redirect on its own (``URLSessionTransport`` refuses
        // one from these hosts, but an injected session might not): whatever answered has to be
        // one of the two hosts too, or the bytes came from somewhere nobody agreed to.
        if let answered = response.url, !DescriptionImages.isDownloadable(answered) {
            throw GitHubError.invalidURL(answered.host ?? answered.absoluteString)
        }
        guard response.isSuccess else {
            throw Self.mapFailure(response, resource: resource, now: now())
        }
        guard response.body.count <= Self.maximumDescriptionImageBytes else {
            throw GitHubError.responseTooLarge(
                resource: resource,
                bytes: response.body.count,
                limit: Self.maximumDescriptionImageBytes
            )
        }
        guard response.header("content-type")?.lowercased().hasPrefix("image/") == true else {
            throw GitHubError.decoding(message: "\(resource) is not an image")
        }
        return response.body
    }

    /// Fetches the review threads of a pull request, following pagination.
    ///
    /// GraphQL-only: thread ids do not exist in REST, and without them threads cannot be
    /// resolved (ADR 0005).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    public func reviewThreads(repo: RepoRef, number: Int) async throws -> [ReviewThread] {
        var result: [ReviewThread] = []
        var cursor: String? = nil
        for _ in 0..<10 {
            var variables: [String: GraphQLValue] = [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
                "first": .int(50),
            ]
            variables["after"] = cursor.map { GraphQLValue.string($0) } ?? .null

            let data: ReviewThreadsData = try await graphQL(
                document: GraphQLDocuments.reviewThreads,
                variables: variables,
                resource: "\(repo.fullName)#\(number) threads",
                isIdempotent: true
            )
            let connection = data.repository?.pullRequest?.reviewThreads
            let nodes = (connection?.nodes ?? []).compactMap { $0 }
            result.append(
                contentsOf: nodes.compactMap {
                    ResponseMapping.reviewThread(from: $0, detector: detector)
                }
            )
            guard connection?.pageInfo?.hasNextPage == true,
                  let next = connection?.pageInfo?.endCursor
            else { break }
            cursor = next
        }
        return result
    }

    /// Reads the current head commit of a pull request.
    ///
    /// The cheapest staleness probe there is; the sync engine calls it before submitting a
    /// review draft (ADR 0006).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: The head SHA.
    public func headRefOid(repo: RepoRef, number: Int) async throws -> String {
        let data: PullRequestHeadData = try await graphQL(
            document: GraphQLDocuments.pullRequestHead,
            variables: [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
            ],
            resource: "\(repo.fullName)#\(number) head",
            isIdempotent: true
        )
        guard let oid = data.repository?.pullRequest?.headRefOid else {
            throw GitHubError.notFound(resource: "\(repo.fullName)#\(number)")
        }
        return oid
    }

    // MARK: - Writes

    /// Submits (or parks) a locally composed review.
    ///
    /// One REST `POST` carries the summary body and every inline comment (ADR 0005). When
    /// ``ReviewDraft/verdict`` is `nil` the `event` field is omitted, which is how GitHub is
    /// told to leave the review `PENDING`.
    /// - Parameters:
    ///   - draft: The draft to submit.
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: A receipt describing the review GitHub created.
    @discardableResult
    public func submitReview(
        _ draft: ReviewDraft,
        repo: RepoRef,
        number: Int
    ) async throws -> SubmittedReview {
        // GitHub documents `body` as required when `event` is `REQUEST_CHANGES` or `COMMENT`
        // and answers 422 otherwise, which is not retryable — the whole review, inline
        // comments included, is lost. The UI already refuses to compose one, but a queued
        // outbox row from an older build can still arrive here, so this is the last gate.
        if let verdict = draft.verdict, verdict != .approve,
           draft.summaryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitHubError.validationFailed(
                message: "GitHub requires a summary when a review comments or requests changes."
            )
        }
        let body = ReviewSubmissionBody(
            commitId: draft.basedOnHeadOid.isEmpty ? nil : draft.basedOnHeadOid,
            body: draft.summaryBody.isEmpty ? nil : draft.summaryBody,
            event: draft.verdict?.apiEvent,
            comments: draft.comments.map { comment in
                ReviewSubmissionBody.Comment(
                    path: comment.path,
                    body: comment.body,
                    line: comment.line,
                    side: comment.side.rawValue,
                    startLine: comment.startLine,
                    startSide: comment.startLine == nil ? nil : comment.side.rawValue
                )
            }
        )
        let encodedBody = try RESTJSON.encode(body)
        let response = try await performREST(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/reviews",
            queryItems: [],
            body: encodedBody,
            useCache: false,
            resource: "\(repo.fullName)#\(number) review"
        )
        let dto: RESTReviewDTO = try RESTJSON.decode(response.body)
        guard let id = dto.id else {
            throw GitHubError.decoding(message: "Review response was missing an id")
        }
        return SubmittedReview(
            id: id,
            nodeId: dto.nodeId,
            state: dto.state ?? "PENDING",
            commitID: dto.commitId
        )
    }

    /// Replies to an existing review comment.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    ///   - commentID: The **REST database id** of the comment being replied to.
    ///   - body: The reply text as Markdown.
    public func replyToComment(
        repo: RepoRef,
        number: Int,
        commentID: Int,
        body: String
    ) async throws {
        let encodedBody = try RESTJSON.encode(CommentBody(body: body))
        _ = try await performREST(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/comments/\(commentID)/replies",
            queryItems: [],
            body: encodedBody,
            useCache: false,
            resource: "\(repo.fullName)#\(number) reply"
        )
    }

    /// Resolves a review thread. GraphQL-only.
    /// - Parameter id: The thread's GraphQL node id.
    public func resolveThread(id: String) async throws {
        let _: ResolveThreadData = try await graphQL(
            document: GraphQLDocuments.resolveReviewThread,
            variables: ["threadId": .string(id)],
            resource: "resolve thread",
            isIdempotent: false
        )
    }

    /// Unresolves a review thread. GraphQL-only.
    /// - Parameter id: The thread's GraphQL node id.
    public func unresolveThread(id: String) async throws {
        let _: ResolveThreadData = try await graphQL(
            document: GraphQLDocuments.unresolveReviewThread,
            variables: ["threadId": .string(id)],
            resource: "unresolve thread",
            isIdempotent: false
        )
    }

    /// Takes a pull request out of draft state. GraphQL-only.
    /// - Parameter pullRequestID: The pull request's GraphQL node id.
    public func markReadyForReview(pullRequestID: String) async throws {
        let _: MarkReadyData = try await graphQL(
            document: GraphQLDocuments.markPullRequestReadyForReview,
            variables: ["pullRequestId": .string(pullRequestID)],
            resource: "mark ready for review",
            isIdempotent: false
        )
    }

    /// Merges a pull request.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    ///   - method: How to merge.
    ///   - expectedHeadOid: The head SHA the user saw. GitHub refuses the merge with `409`
    ///     if the branch moved on, which is surfaced as ``GitHubError/staleHead(expected:actual:)``.
    ///   - commitTitle: An optional override for the merge commit title.
    /// - Returns: The SHA of the merge commit.
    @discardableResult
    public func mergePullRequest(
        repo: RepoRef,
        number: Int,
        method: MergeMethod,
        expectedHeadOid: String?,
        commitTitle: String? = nil
    ) async throws -> String? {
        let body = MergeBody(
            commitTitle: commitTitle,
            sha: expectedHeadOid,
            mergeMethod: method.rawValue
        )
        let encodedBody = try RESTJSON.encode(body)
        do {
            let response = try await performREST(
                method: "PUT",
                path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/merge",
                queryItems: [],
                body: encodedBody,
                useCache: false,
                resource: "\(repo.fullName)#\(number) merge"
            )
            let dto: RESTMergeResultDTO = try RESTJSON.decode(response.body)
            return dto.sha
        } catch GitHubError.conflict {
            // A 409 on the merge endpoint always means the head SHA precondition failed.
            throw GitHubError.staleHead(expected: expectedHeadOid ?? "", actual: nil)
        }
    }

    /// Whether a pull request has already been merged.
    ///
    /// `GET /repos/{owner}/{repo}/pulls/{number}/merge` — the same path
    /// ``mergePullRequest(repo:number:method:expectedHeadOid:commitTitle:)`` writes to, read
    /// rather than written, and the one endpoint that answers with a status code and no body at
    /// all: `204` when the pull request is merged, `404` when it is not. So the `404` is an
    /// *answer* here rather than a failure, and it is the only status this swallows — anything
    /// else is thrown, because "we could not ask" must never read as "it is not merged": the
    /// drain would then report a merge that landed as a failure, which is the whole reason this
    /// exists.
    ///
    /// Uncached on purpose, for ``issueState(repo:number:)``'s reason: a probe that can be
    /// answered out of a conditional cache is not a probe.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    /// - Returns: `true` when GitHub says the pull request is merged.
    /// - Throws: Whatever the transport or the status mapping produced, `404` excepted.
    public func isPullRequestMerged(repo: RepoRef, number: Int) async throws -> Bool {
        do {
            _ = try await performREST(
                method: "GET",
                path: "/repos/\(repo.owner)/\(repo.name)/pulls/\(number)/merge",
                queryItems: [],
                body: nil,
                useCache: false,
                resource: "\(repo.fullName)#\(number) merged"
            )
            return true
        } catch GitHubError.notFound {
            return false
        }
    }

    // MARK: - Branch deletion (ADR 0005's 2026-09-05 amendment)

    /// Reads the three facts a queued branch deletion is decided on.
    ///
    /// ``headRefOid(repo:number:)``'s sibling, and it exists for the same reason: the outbox row
    /// names a repository and a number, and everything else a write needs has to be read back at
    /// the moment the write goes out. A merged pull request still answers all four fields —
    /// GitHub keeps `headRefName` as a plain string even once the branch is gone — so this is
    /// asked *after* the merge, where it costs nothing when the merge never happened.
    /// - Parameters:
    ///   - repo: The base repository — the one the merge was made in.
    ///   - number: The pull request number.
    /// - Returns: The head branch's name, the repository it lives in and the base repository's
    ///   default branch. Any field GitHub did not answer is `nil`, which
    ///   ``HeadBranchContext/deletableBranch(in:)`` reads as a refusal.
    public func headBranchContext(repo: RepoRef, number: Int) async throws -> HeadBranchContext {
        let data: HeadBranchContextData = try await graphQL(
            document: GraphQLDocuments.headBranchContext,
            variables: [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
            ],
            resource: "\(repo.fullName)#\(number) head branch",
            isIdempotent: true
        )
        let pullRequest = data.repository?.pullRequest
        return HeadBranchContext(
            headRefName: pullRequest?.headRefName,
            headRepositoryFullName: pullRequest?.headRepository?.nameWithOwner,
            defaultBranchName: data.repository?.defaultBranchRef?.name
        )
    }

    /// Deletes a branch.
    ///
    /// `DELETE /repos/{o}/{r}/git/refs/heads/{branch}` — REST, like every other write (ADR 0005).
    /// The branch name goes into the path unencoded on purpose: `URLComponents` percent-encodes
    /// what a path segment may not contain while leaving `/` a separator, which is exactly right
    /// for a ref — `feature/thing` is one ref, not two segments GitHub would have to guess at.
    ///
    /// It reports failure the way every other write does, and the *caller* decides what that is
    /// worth: the drain swallows it, because by then the merge has already happened.
    /// - Parameters:
    ///   - repo: The repository the branch lives in.
    ///   - name: The branch name, without the `refs/heads/` prefix.
    /// - Throws: ``GitHubError/notFound(resource:)`` or
    ///   ``GitHubError/validationFailed(message:)`` when the ref is already gone — which is what
    ///   a repository with "automatically delete head branches" switched on will usually say —
    ///   and whatever else the status maps to.
    public func deleteBranch(repo: RepoRef, name: String) async throws {
        _ = try await performREST(
            method: "DELETE",
            path: "/repos/\(repo.owner)/\(repo.name)/git/refs/heads/\(name)",
            queryItems: [],
            body: nil,
            useCache: false,
            resource: "\(repo.fullName) branch \(name)"
        )
    }

    // MARK: - Issue writes (ADR 0032's Sprint 4a amendment)

    /// Reads an issue's current `updatedAt` — the staleness probe for a queued triage write.
    ///
    /// ``headRefOid(repo:number:)``'s twin for the other kind of node, and the reason it exists
    /// is the same: ADR 0006 requires every write to be re-validated against the state the user
    /// actually saw, and an issue has no head commit to compare. `updatedAt` is what GitHub moves
    /// for every edit, label, assignment, comment and state change, so it is the one field a
    /// triage write can be pinned to.
    ///
    /// GraphQL rather than the REST `GET /repos/…/issues/{n}` the claims card uses, and
    /// deliberately: that read is ETag-cached on its URL, and a probe that can be answered from
    /// the cache is not a probe. Three fields on one node, sent as an idempotent query.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    /// - Returns: The issue's node id, its current `updatedAt` and whether it is closed.
    /// - Throws: ``GitHubError/notFound(resource:)`` when the issue is not there (or is a pull
    ///   request, which `Repository.issue` does not answer for), and whatever else the transport
    ///   maps.
    public func issueState(repo: RepoRef, number: Int) async throws -> IssueState {
        let data: IssueStateData = try await graphQL(
            document: GraphQLDocuments.issueState,
            variables: [
                "owner": .string(repo.owner),
                "name": .string(repo.name),
                "number": .int(number),
            ],
            resource: "\(repo.fullName)#\(number) issue state",
            isIdempotent: true
        )
        guard let issue = data.repository?.issue,
              let id = issue.id,
              let timestamp = issue.updatedAt,
              let updatedAt = GitHubTimestamp.parse(timestamp)
        else {
            throw GitHubError.notFound(resource: "\(repo.fullName)#\(number)")
        }
        return IssueState(id: id, updatedAt: updatedAt, isClosed: issue.closed ?? false)
    }

    /// Posts a comment on an issue.
    ///
    /// `POST /repos/{o}/{r}/issues/{n}/comments` — REST, like every other write (ADR 0005).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - body: The comment as Markdown source.
    public func addIssueComment(repo: RepoRef, number: Int, body: String) async throws {
        let encodedBody = try RESTJSON.encode(CommentBody(body: body))
        _ = try await performREST(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)/comments",
            queryItems: [],
            body: encodedBody,
            useCache: false,
            resource: "\(repo.fullName)#\(number) issue comment"
        )
    }

    /// Adds labels to an issue, leaving the ones already on it alone.
    ///
    /// `POST /repos/{o}/{r}/issues/{n}/labels`, the **additive** endpoint. Not the full-replace
    /// `PATCH /issues/{n}` with a `labels` array, and that is the interesting part: two label
    /// writes queued a second apart would each carry the list as it was when they were composed,
    /// so the second would silently undo the first. An additive `POST` cannot lose an update
    /// (ADR 0032).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - labels: The label names to add, exactly as GitHub spells them.
    public func addIssueLabels(repo: RepoRef, number: Int, labels: [String]) async throws {
        let encodedBody = try RESTJSON.encode(IssueLabelsBody(labels: labels))
        _ = try await performREST(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)/labels",
            queryItems: [],
            body: encodedBody,
            useCache: false,
            resource: "\(repo.fullName)#\(number) issue labels"
        )
    }

    /// Adds assignees to an issue, leaving the ones already on it alone.
    ///
    /// `POST /repos/{o}/{r}/issues/{n}/assignees`, additive for ``addIssueLabels(repo:number:labels:)``'s
    /// reason. GitHub silently ignores a login that cannot be assigned in that repository, which
    /// is why this returns nothing to check: the honest confirmation is the next sweep.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - logins: The GitHub logins to assign.
    public func addIssueAssignees(repo: RepoRef, number: Int, logins: [String]) async throws {
        let encodedBody = try RESTJSON.encode(IssueAssigneesBody(assignees: logins))
        _ = try await performREST(
            method: "POST",
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)/assignees",
            queryItems: [],
            body: encodedBody,
            useCache: false,
            resource: "\(repo.fullName)#\(number) issue assignees"
        )
    }

    /// Opens or closes an issue.
    ///
    /// `PATCH /repos/{o}/{r}/issues/{n}` carrying `state` and `state_reason` and **nothing else**.
    /// The endpoint can also rewrite the title, the body, the labels and the assignees; a body
    /// that sent any of those would replace what somebody else changed in the meantime, which is
    /// the lost update the staleness probe exists to prevent (ADR 0032).
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - state: `"open"` or `"closed"`.
    ///   - stateReason: GitHub's `state_reason`, or `nil` to send none at all.
    public func setIssueState(
        repo: RepoRef,
        number: Int,
        state: String,
        stateReason: String?
    ) async throws {
        let encodedBody = try RESTJSON.encode(
            IssueStateBody(state: state, stateReason: stateReason)
        )
        _ = try await performREST(
            method: "PATCH",
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(number)",
            queryItems: [],
            body: encodedBody,
            useCache: false,
            resource: "\(repo.fullName)#\(number) issue state change"
        )
    }

    // MARK: - Notifications

    /// Polls `GET /notifications`.
    ///
    /// Honours the two things ADR 0005 requires of this loop: the server's `X-Poll-Interval`
    /// is returned to the caller so the loop can slow down when GitHub asks it to, and
    /// `If-Modified-Since` makes an unchanged inbox a free `304`.
    /// - Parameters:
    ///   - since: Only return threads updated after this time.
    ///   - lastModified: The `Last-Modified` value from the previous poll.
    ///   - participating: Whether to restrict to threads the user participates in.
    /// - Returns: The page, including the poll interval and the new `Last-Modified`.
    public func notifications(
        since: Date? = nil,
        lastModified: String? = nil,
        participating: Bool = true
    ) async throws -> NotificationsPage {
        var queryItems: [(String, String)] = [
            ("participating", participating ? "true" : "false"),
            ("per_page", String(configuration.pageSize)),
        ]
        if let since {
            queryItems.append(("since", GitHubTimestamp.string(from: since)))
        }
        var extraHeaders: [String: String] = [:]
        if let lastModified {
            extraHeaders["If-Modified-Since"] = lastModified
        }

        let response = try await performREST(
            method: "GET",
            path: "/notifications",
            queryItems: queryItems,
            body: nil,
            useCache: true,
            resource: "notifications",
            extraHeaders: extraHeaders
        )

        let pollInterval = response.header("x-poll-interval").flatMap { TimeInterval($0) }
        let newLastModified = response.header("last-modified") ?? lastModified

        // The status code alone decides. `perform` substitutes the cached body into a `304`
        // so ordinary callers can keep parsing, but for this endpoint that body is *last*
        // poll's threads: returning them as if they had just arrived pulls a full sweep
        // forward on every single poll.
        if response.statusCode == 304 {
            return NotificationsPage(
                items: [],
                pollInterval: pollInterval,
                lastModified: newLastModified,
                notModified: true
            )
        }
        let dtos: [RESTNotificationDTO] = try RESTJSON.decode(response.body)
        return NotificationsPage(
            items: dtos.compactMap(ResponseMapping.notification(from:)),
            pollInterval: pollInterval,
            lastModified: newLastModified,
            notModified: false
        )
    }

    // MARK: - GraphQL plumbing

    /// Runs one GraphQL document.
    /// - Parameter isIdempotent: `true` for queries, `false` for mutations. GraphQL always
    ///   travels by `POST`, so the HTTP method cannot answer this: only the caller knows
    ///   whether replaying the document after a dropped connection is safe.
    private func graphQL<Payload: Decodable>(
        document: String,
        variables: [String: GraphQLValue],
        resource: String,
        isIdempotent: Bool,
        cacheKey: String? = nil
    ) async throws -> Payload {
        let body = try RESTJSON.encodeGraphQL(
            GraphQLRequestBody(query: document, variables: variables)
        )
        let response = try await perform(
            method: "POST",
            url: configuration.graphQLURL,
            body: body,
            accept: "application/json",
            useCache: cacheKey != nil,
            resource: resource,
            extraHeaders: [:],
            isIdempotent: isIdempotent,
            cacheKeyOverride: cacheKey
        )
        let envelope: GraphQLEnvelope<Payload> = try RESTJSON.decodeGraphQL(response.body)
        if let errors = envelope.errors, !errors.isEmpty {
            let messages = errors.compactMap(\.message)
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw GitHubError.rateLimited(retryAfter: nil, resetAt: latestRateLimit?.resetAt)
            }
            throw GitHubError.graphQL(messages: messages.isEmpty ? ["Unknown error"] : messages)
        }
        guard let data = envelope.data else {
            throw GitHubError.decoding(message: "GraphQL response had no data for \(resource)")
        }
        return data
    }

    // MARK: - REST plumbing

    private func performREST(
        method: String,
        path: String,
        queryItems: [(String, String)],
        body: Data?,
        useCache: Bool,
        resource: String,
        extraHeaders: [String: String] = [:],
        accept: String = "application/vnd.github+json"
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(
            url: configuration.apiBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubError.invalidURL(configuration.apiBaseURL.absoluteString)
        }
        components.path = (components.path == "/" ? "" : components.path) + path
        if !queryItems.isEmpty {
            components.queryItems = queryItems.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw GitHubError.invalidURL(configuration.apiBaseURL.absoluteString + path)
        }
        return try await perform(
            method: method,
            url: url,
            body: body,
            accept: accept,
            useCache: useCache,
            resource: resource,
            extraHeaders: extraHeaders,
            isIdempotent: Self.isIdempotentMethod(method)
        )
    }

    /// Whether replaying a request after a dropped connection is safe.
    ///
    /// Only `GET`/`HEAD`. A `POST` that timed out may well have been executed — GitHub could
    /// have created the review and lost the response — so replaying it duplicates the write.
    static func isIdempotentMethod(_ method: String) -> Bool {
        let upper = method.uppercased()
        return upper == "GET" || upper == "HEAD"
    }

    /// The conditional-request cache key for a request, or `nil` when the response must not
    /// be cached at all.
    ///
    /// Two endpoints need special handling, because the cache has no eviction cheap enough to
    /// clean up after them:
    ///
    /// - `/notifications` carries a `since` that is rewritten on every poll. Keying on the
    ///   full URL mints a brand-new row — holding the whole payload — roughly every minute,
    ///   and the stored `ETag` can never be replayed because the next request has a different
    ///   URL. Keying on the path alone makes the validators actually work.
    /// - `/commits/{sha}/check-runs` is keyed by an immutable SHA, so every push leaves one
    ///   more permanently unreachable row behind. Not worth caching.
    static func cacheKey(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if components.path.hasSuffix("/check-runs") { return nil }
        if components.path.hasSuffix("/notifications") {
            components.queryItems = nil
            return components.url?.absoluteString ?? url.absoluteString
        }
        return url.absoluteString
    }

    /// The one place a request leaves this process.
    ///
    /// Applies the conditional-request cache, records rate-limit counters, maps status codes
    /// to ``GitHubError`` and retries rate-limited or transport-failed requests with the
    /// server-supplied backoff.
    private func perform(
        method: String,
        url: URL,
        body: Data?,
        accept: String,
        useCache: Bool,
        resource: String,
        extraHeaders: [String: String],
        isIdempotent: Bool,
        cacheKeyOverride: String? = nil
    ) async throws -> HTTPResponse {
        // Every REST read is keyed by its URL. A GraphQL read cannot be — one endpoint, one
        // URL, every document — so the *caller* names the key when it wants a conditional
        // request, and only then (`useCache` follows the key). See
        // ``searchClosedPullRequests(repo:since:cursor:pageSize:)``.
        let cacheKey = cacheKeyOverride ?? Self.cacheKey(for: url)
        var attempt = 0

        while true {
            var headers: [String: String] = [
                "Accept": accept,
                "User-Agent": configuration.userAgent,
                "X-GitHub-Api-Version": "2022-11-28",
            ]
            let token = try await tokenProvider.accessToken()
            headers["Authorization"] = "Bearer \(token)"
            if body != nil {
                headers["Content-Type"] = "application/json; charset=utf-8"
            }
            for (name, value) in extraHeaders {
                headers[name] = value
            }

            var cached: ConditionalCacheEntry? = nil
            if useCache, let cacheKey {
                cached = await cache.entry(for: cacheKey)
                if let etag = cached?.etag {
                    headers["If-None-Match"] = etag
                }
                if headers["If-Modified-Since"] == nil, let lastModified = cached?.lastModified {
                    headers["If-Modified-Since"] = lastModified
                }
            }

            let startedAt = now()
            let request = HTTPRequest(method: method, url: url, headers: headers, body: body)
            let response: HTTPResponse
            do {
                response = try await transport.data(for: request)
            } catch {
                let mapped = (error as? GitHubError)
                    ?? GitHubError.transport(message: String(describing: error))
                configuration.requestLogger?(
                    GitHubRequestLogEntry(
                        method: method,
                        url: url,
                        statusCode: nil,
                        duration: now().timeIntervalSince(startedAt),
                        wasNotModified: false,
                        rateLimit: nil,
                        startedAt: startedAt
                    )
                )
                // A connection that dropped mid-request says nothing about whether the server
                // ran it. Replaying is only safe for reads; a retried `POST /reviews` after a
                // 30 s timeout is exactly how one review becomes two.
                guard mapped.isRetryable, isIdempotent, attempt < configuration.maxRetries else {
                    throw mapped
                }
                attempt += 1
                try await sleeper.sleep(for: .seconds(min(configuration.maxBackoff, 2)))
                continue
            }

            let snapshot = RateLimitSnapshot.parse(from: response, observedAt: now())
            if let snapshot {
                latestRateLimit = snapshot
            }
            configuration.requestLogger?(
                GitHubRequestLogEntry(
                    method: method,
                    url: url,
                    statusCode: response.statusCode,
                    duration: now().timeIntervalSince(startedAt),
                    wasNotModified: response.statusCode == 304,
                    rateLimit: snapshot,
                    startedAt: startedAt
                )
            )

            if response.statusCode == 304 {
                if let payload = cached?.payload, !payload.isEmpty {
                    return HTTPResponse(
                        statusCode: 304,
                        headers: response.headers,
                        body: payload
                    )
                }
                return response
            }

            if response.isSuccess {
                if useCache, let cacheKey {
                    let etag = response.header("etag")
                    let lastModified = response.header("last-modified")
                    if etag != nil || lastModified != nil {
                        await cache.store(
                            ConditionalCacheEntry(
                                etag: etag,
                                lastModified: lastModified,
                                payload: response.body,
                                storedAt: now()
                            ),
                            for: cacheKey
                        )
                    }
                }
                return response
            }

            let error = Self.mapFailure(response, resource: resource, now: now())
            if case .rateLimited(let retryAfter, _) = error, attempt < configuration.maxRetries {
                let delay = min(configuration.maxBackoff, retryAfter ?? 60)
                attempt += 1
                try await sleeper.sleep(for: .seconds(delay))
                continue
            }
            throw error
        }
    }

    /// Maps a non-success response onto a typed error.
    static func mapFailure(_ response: HTTPResponse, resource: String, now: Date) -> GitHubError {
        let message = Self.errorMessage(from: response.body)
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403, 429:
            if RateLimitPolicy.isRateLimit(response) {
                return .rateLimited(
                    retryAfter: RateLimitPolicy.retryDelay(for: response, now: now),
                    resetAt: RateLimitSnapshot.parse(from: response, observedAt: now)?.resetAt
                )
            }
            return .forbidden(message: message)
        case 404:
            return .notFound(resource: resource)
        case 405:
            return .notMergeable(message: message)
        case 409:
            return .conflict(message: message)
        case 422:
            return .validationFailed(message: message)
        default:
            return .server(status: response.statusCode, message: message)
        }
    }

    private static func errorMessage(from body: Data) -> String {
        if let dto = try? RESTJSON.decodeRaw(RESTErrorDTO.self, from: body) {
            return dto.combinedMessage
        }
        let text = String(decoding: body, as: UTF8.self)
        return text.isEmpty ? "No response body" : text
    }
}

// MARK: - Request bodies

/// The body of `POST /repos/{owner}/{repo}/pulls/{number}/reviews`.
struct ReviewSubmissionBody: Encodable {
    /// One inline comment of the review.
    struct Comment: Encodable {
        var path: String
        var body: String
        var line: Int
        var side: String
        var startLine: Int?
        var startSide: String?
    }
    var commitId: String?
    var body: String?
    /// Omitted entirely for a draft, which is how GitHub is asked for a `PENDING` review.
    var event: String?
    var comments: [Comment]?
}

/// The body of the reply endpoint.
struct CommentBody: Encodable {
    var body: String
}

/// The body of `POST /repos/{owner}/{repo}/issues/{number}/labels` (ADR 0032).
struct IssueLabelsBody: Encodable {
    var labels: [String]
}

/// The body of `POST /repos/{owner}/{repo}/issues/{number}/assignees` (ADR 0032).
struct IssueAssigneesBody: Encodable {
    var assignees: [String]
}

/// The body of `PATCH /repos/{owner}/{repo}/issues/{number}` — two keys, and only ever two
/// (ADR 0032).
///
/// `stateReason` is a plain optional so that a `nil` is *omitted* rather than sent as an explicit
/// null: the two are not the same request to GitHub, and "do not mention the reason" is what a
/// reopen means.
struct IssueStateBody: Encodable {
    var state: String
    var stateReason: String?
}

/// The body of `PUT /repos/{owner}/{repo}/pulls/{number}/merge`.
struct MergeBody: Encodable {
    var commitTitle: String?
    var sha: String?
    var mergeMethod: String
}

/// A GraphQL request body.
struct GraphQLRequestBody: Encodable {
    var query: String
    var variables: [String: GraphQLValue]
}

/// A GraphQL variable value. Only the scalar kinds Shepherd's documents use.
enum GraphQLValue: Encodable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// JSON coding for GitHub's REST and GraphQL payloads.
enum RESTJSON {
    /// Decodes a REST payload (snake_case keys).
    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(message: String(describing: error))
        }
    }

    /// Decodes a REST payload without throwing a ``GitHubError``; used for error bodies.
    static func decodeRaw<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    /// Decodes a GraphQL payload (camelCase keys, no conversion).
    static func decodeGraphQL<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(message: String(describing: error))
        }
    }

    /// Encodes a REST request body (camelCase properties become snake_case keys).
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw GitHubError.decoding(message: String(describing: error))
        }
    }

    /// Encodes a GraphQL request body verbatim.
    static func encodeGraphQL<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw GitHubError.decoding(message: String(describing: error))
        }
    }
}
