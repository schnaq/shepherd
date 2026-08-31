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
///   `/check-runs`) with a GraphQL query for review threads, because thread ids — and the
///   mutations that resolve them — exist only in GraphQL.
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
                resource: "search"
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
            checks: checkList
        )
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
                resource: "\(repo.fullName)#\(number) threads"
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
            resource: "\(repo.fullName)#\(number) head"
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
            resource: "resolve thread"
        )
    }

    /// Unresolves a review thread. GraphQL-only.
    /// - Parameter id: The thread's GraphQL node id.
    public func unresolveThread(id: String) async throws {
        let _: ResolveThreadData = try await graphQL(
            document: GraphQLDocuments.unresolveReviewThread,
            variables: ["threadId": .string(id)],
            resource: "unresolve thread"
        )
    }

    /// Takes a pull request out of draft state. GraphQL-only.
    /// - Parameter pullRequestID: The pull request's GraphQL node id.
    public func markReadyForReview(pullRequestID: String) async throws {
        let _: MarkReadyData = try await graphQL(
            document: GraphQLDocuments.markPullRequestReadyForReview,
            variables: ["pullRequestId": .string(pullRequestID)],
            resource: "mark ready for review"
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

        if response.statusCode == 304 && response.body.isEmpty {
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
            notModified: response.statusCode == 304
        )
    }

    // MARK: - GraphQL plumbing

    private func graphQL<Payload: Decodable>(
        document: String,
        variables: [String: GraphQLValue],
        resource: String
    ) async throws -> Payload {
        let body = try RESTJSON.encodeGraphQL(
            GraphQLRequestBody(query: document, variables: variables)
        )
        let response = try await perform(
            method: "POST",
            url: configuration.graphQLURL,
            body: body,
            accept: "application/json",
            useCache: false,
            resource: resource,
            extraHeaders: [:]
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
        extraHeaders: [String: String] = [:]
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
            accept: "application/vnd.github+json",
            useCache: useCache,
            resource: resource,
            extraHeaders: extraHeaders
        )
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
        extraHeaders: [String: String]
    ) async throws -> HTTPResponse {
        let cacheKey = url.absoluteString
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
            if useCache {
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
                guard mapped.isRetryable, attempt < configuration.maxRetries else { throw mapped }
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
                if useCache {
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
