#if DEBUG
import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// The sample data the demo mode (``DemoMode``) launches on.
///
/// Written through the same stores a sweep writes through, so what is on screen is rendered by the
/// code that renders real data — nothing here is a view-level stand-in. The mix is chosen to put
/// every inbox state on screen at once: agent and human authors, green, red and running CI, every
/// review decision, a draft, a watched repository with a linked checkout, a failed write and a
/// queued merge.
///
/// The strings are sample *data* — titles, descriptions, commit messages — and therefore plain
/// `String`s: they are not UI copy, and nothing here goes through the string catalog.
enum DemoSeed {
    /// The signed-in login.
    static let viewerLogin = "jonas-weber"

    /// The pull request with the full detail: files with patches, a failing check, review
    /// threads and a description with claims. The screenshot script opens it on the review screen.
    static let showcase = (repo: "schnaq/shepherd", number: 412)

    // MARK: - Settings

    /// Puts the demo's preferences into the (already emptied) demo suite.
    ///
    /// Set through the properties rather than written to the suite, so each `didSet` persists the
    /// value exactly as a user's change would. Everything that would reach the network or the
    /// shared system state is switched off explicitly, not left to a default that may change.
    /// - Parameters:
    ///   - settings: The demo's settings store.
    ///   - checkout: The folder to link as `schnaq/shepherd`'s local checkout.
    @MainActor
    static func configure(_ settings: AppSettings, checkout: URL) {
        settings.store(account: Account(login: viewerLogin, authKind: .pat))
        // The first-run question has been answered — with "no".
        settings.telemetryLevel = .off
        settings.telemetryNoticeAcknowledged = true
        // Screenshots must not depend on whether this Mac has the on-device model, and the cloud
        // rung needs a key the demo does not have.
        settings.intelligenceMode = .off
        settings.structuredTriageEnabled = false
        settings.semanticSearchEnabled = false
        // The system Spotlight index is the installed app's; ``DemoSpotlightIndex`` backs this up.
        settings.spotlightExportEnabled = false
        settings.webhooksEnabled = false
        // No path raises one today — the sweep that emits these events never runs here — but a
        // notification is the one side effect with a real, bundle-id-scoped permission prompt on
        // the developer's Mac, so the demo does not leave it to that reasoning.
        settings.notifyOnReviewRequest = false
        settings.notifyOnChecksFailed = false
        settings.notifyOnDraftConflict = false
        settings.settingsSyncEnabled = false
        settings.diagnosticsEnabled = false
        // A second Shepherd icon in the menu bar would only confuse whoever is running the demo.
        settings.showsMenuBarExtra = false
        // The track-record card asks to read closed pull requests from GitHub; the demo has none.
        settings.hasDismissedTrackRecordNotice = true
        if let appearance = demoAppearance { settings.appearance = appearance }
        // `SHEPHERD_DEMO_REVIEW_TAB=files`: open an agent's pull request on its diff rather than on
        // the conversation, so the screenshot script can capture both tabs of the review screen.
        if ProcessInfo.processInfo.environment["SHEPHERD_DEMO_REVIEW_TAB"]?.lowercased() == "files" {
            settings.opensAgentPullRequestsOnConversation = false
        }
        // The line list unless `SHEPHERD_DEMO_DIFF=web`: the Monaco viewer is a web view, and
        // WebKit does not paint a window that is occluded — which a window the screenshot script
        // launched behind the terminal usually is — so a captured rich diff comes out blank.
        settings.diffRenderer = ProcessInfo.processInfo.environment["SHEPHERD_DEMO_DIFF"]?.lowercased() == "web"
            ? .web : .native

        settings.watchedRepositories = [shepherd, unlock]
        try? FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        settings.setLocalCheckout(checkout, forRepoNamed: shepherd.fullName)
    }

    /// `SHEPHERD_DEMO_APPEARANCE=dark|light`, for a Mac where `-AppleInterfaceStyle` is not enough.
    private static var demoAppearance: AppearanceSetting? {
        switch ProcessInfo.processInfo.environment["SHEPHERD_DEMO_APPEARANCE"]?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    // MARK: - Database

    /// Writes the pull requests, their details, the issues and the outbox rows.
    ///
    /// The order matters: the summaries go first *with* their relations, because a detail save
    /// keeps the relation of an existing row and would otherwise leave every row without one — and
    /// the default smart view, "Needs my review", reads exactly that relation.
    /// - Parameter database: The scratch database.
    static func write(into database: DatabaseManager) async throws {
        let rows = pullRequests
        try await database.savePullRequestSummaries(rows, pruneMissing: true)
        for row in rows {
            try await database.savePullRequestDetail(detail(for: row))
        }
        try await database.saveIssueSummaries(issues, pruneMissing: true)
        // With a stored body the issue panel has nothing to fetch, so it never waits on GitHub.
        for issue in issues {
            try await database.saveIssueDetail(IssueDetail(summary: issue, bodyMarkdown: issueBody(issue)))
        }
        for item in outbox {
            try await database.enqueue(item)
        }
    }

    // MARK: - People and agents

    private static let shepherd = RepoRef(owner: "schnaq", name: "shepherd")
    private static let konduit = RepoRef(owner: "schnaq", name: "konduit")
    private static let unlock = RepoRef(owner: "schnaq", name: "unlock")
    private static let acmeAPI = RepoRef(owner: "acme", name: "api")

    private static let viewer = person(viewerLogin, "Jonas Weber")
    private static let sophie = person("sophie-mueller", "Sophie Müller")
    private static let tobias = person("tkrause", "Tobias Krause")
    private static let priya = person("priya-nair", "Priya Nair")
    private static let dan = person("dan-okafor", "Dan Okafor")

    private static let claude = agent("claude[bot]", id: "claude-code", name: "Claude Code")
    private static let copilot = agent("copilot-swe-agent[bot]", id: "github-copilot", name: "GitHub Copilot")
    private static let codex = agent("chatgpt-codex-connector[bot]", id: "openai-codex", name: "OpenAI Codex")
    private static let dependabot = agent("dependabot[bot]", id: "dependabot", name: "Dependabot")

    private static func person(_ login: String, _ name: String) -> Actor {
        // No avatar URL: an avatar is a request to GitHub's image host, and the demo makes none.
        Actor(login: login, displayName: name, kind: .human)
    }

    private static func agent(_ login: String, id: String, name: String) -> Actor {
        Actor(login: login, kind: .agent(AgentIdentity(id: id, displayName: name, matchedBy: .login)))
    }

    // MARK: - Pull requests

    /// One row of the inbox, before the detail is attached.
    private struct Sample {
        var repo: RepoRef
        var number: Int
        var title: String
        var author: Actor
        var branch: String
        var hoursAgo: Double
        var ci: CheckRollup.State
        var decision: ReviewDecision?
        var relation: Set<Relation>
        var labels: [String]
        var files: [ChangedFile]
        var body: String
        var isDraft = false
    }

    private static var samples: [Sample] {
        [
            Sample(
                repo: shepherd, number: 412,
                title: "Retry failed outbox writes from the inbox row",
                author: claude, branch: "claude/outbox-retry-from-row", hoursAgo: 0.4,
                ci: .failure, decision: .reviewRequired,
                relation: [.reviewRequested, .assigned], labels: ["outbox", "ux"],
                files: ShowcaseFiles.all, body: ShowcaseFiles.body
            ),
            Sample(
                repo: shepherd, number: 409,
                title: "Group inbox rows by trust lane",
                author: copilot, branch: "copilot/trust-lane-grouping", hoursAgo: 2.5,
                ci: .success, decision: .reviewRequired,
                relation: [.reviewRequested], labels: ["inbox"],
                files: [
                    file("Shepherd/Features/Inbox/TrustLanes.swift", lines: 46, removed: 9),
                    file("Shepherd/Features/Inbox/InboxListView.swift", lines: 21, removed: 3),
                    file("ShepherdTests/TrustLaneUITests.swift", status: .added, lines: 38),
                ],
                body: """
                    Adds a *Group by trust lane* option next to agent, repository and review state.

                    Rows keep their priority order inside each lane. Closes #398.
                    """
            ),
            Sample(
                repo: konduit, number: 88,
                title: "Stream webhook deliveries through a bounded queue",
                author: codex, branch: "codex/bounded-delivery-queue", hoursAgo: 1.2,
                ci: .pending, decision: .reviewRequired,
                relation: [.reviewRequested], labels: ["performance"],
                files: [
                    file("Sources/Konduit/Delivery/DeliveryQueue.swift", status: .added, lines: 142),
                    file("Sources/Konduit/Delivery/Dispatcher.swift", lines: 64, removed: 71),
                    file("Sources/Konduit/Config/Limits.swift", lines: 18, removed: 4),
                    file("Tests/KonduitTests/DeliveryQueueTests.swift", status: .added, lines: 88),
                ],
                body: """
                    Deliveries used to be spawned one task each, which let a slow receiver pile up
                    thousands of in-flight requests. They now go through a queue capped at
                    `Limits.maxInFlightDeliveries` (default 64) with back-pressure on the producer.

                    Benchmarked with 10k events against a receiver that sleeps 2 s: peak memory
                    went from 1.9 GB to 140 MB.
                    """
            ),
            Sample(
                repo: konduit, number: 86,
                title: "Bump swift-nio from 2.71.0 to 2.74.0",
                author: dependabot, branch: "dependabot/swift/swift-nio-2.74.0", hoursAgo: 20,
                ci: .success, decision: .approved,
                relation: [.reviewRequested], labels: ["dependencies"],
                files: [file("Package.resolved", lines: 3, removed: 3)],
                body: "Bumps [swift-nio](https://github.com/apple/swift-nio) from 2.71.0 to 2.74.0."
            ),
            Sample(
                repo: konduit, number: 90,
                title: "Retry DNS lookups with jittered backoff",
                author: claude, branch: "claude/dns-retry-jitter", hoursAgo: 5,
                ci: .success, decision: .reviewRequired,
                relation: [.reviewRequested], labels: ["reliability"],
                files: [
                    file("Sources/Konduit/Net/Resolver.swift", lines: 58, removed: 17),
                    file("Tests/KonduitTests/ResolverTests.swift", lines: 39, removed: 4),
                ],
                body: """
                    Transient `EAI_AGAIN` failures now retry three times with full jitter
                    (50–400 ms) before the delivery is marked failed. Tests added.
                    """
            ),
            Sample(
                repo: unlock, number: 231,
                title: "Rotate signing keys without downtime",
                author: sophie, branch: "sophie/key-rotation", hoursAgo: 26,
                ci: .success, decision: .changesRequested,
                relation: [.reviewRequested], labels: ["security"],
                files: [
                    file("Sources/Unlock/Signing/KeyRing.swift", status: .added, lines: 164),
                    file("Sources/Unlock/Signing/Signer.swift", lines: 71, removed: 48),
                    file("Sources/Unlock/Routes/JWKS.swift", lines: 36, removed: 12),
                    file("docs/operations/key-rotation.md", status: .added, lines: 57),
                ],
                body: """
                    Keeps the previous key in the JWKS for one rotation period so licences signed
                    just before a rotation still verify. The runbook is in
                    `docs/operations/key-rotation.md`.
                    """
            ),
            Sample(
                repo: unlock, number: 229,
                title: "Fix off-by-one in licence expiry check",
                author: claude, branch: "claude/expiry-off-by-one", hoursAgo: 7,
                ci: .success, decision: .reviewRequired,
                relation: [.reviewRequested], labels: ["bug"],
                files: [
                    file("Sources/Unlock/Licence/Expiry.swift", lines: 4, removed: 2),
                    file("Tests/UnlockTests/ExpiryTests.swift", lines: 4, removed: 1),
                ],
                body: "A licence expiring today was rejected at 00:00 UTC instead of 23:59:59. Fixes #227."
            ),
            Sample(
                repo: unlock, number: 233,
                title: "Export the audit log as CSV",
                author: dan, branch: "dan/audit-csv", hoursAgo: 30,
                ci: .pending, decision: nil,
                relation: [.watched], labels: ["feature"],
                files: [
                    file("Sources/Unlock/Audit/CSVExporter.swift", status: .added, lines: 112),
                    file("Sources/Unlock/Routes/Audit.swift", lines: 41, removed: 9),
                ],
                body: "Adds `GET /audit.csv` behind the `audit:read` scope."
            ),
            Sample(
                repo: acmeAPI, number: 624,
                title: "Add cursor pagination to /v2/orders",
                author: copilot, branch: "copilot/orders-cursor-pagination", hoursAgo: 3,
                ci: .failure, decision: .reviewRequired,
                relation: [.reviewRequested], labels: ["api"],
                files: [
                    file("app/routes/v2/orders.ts", lines: 88, removed: 21),
                    file("app/lib/cursor.ts", status: .added, lines: 64),
                    file("openapi/v2.yaml", lines: 47, removed: 6),
                    file("test/routes/orders.test.ts", lines: 57, removed: 4),
                ],
                body: "Replaces `?page=` with an opaque `?cursor=`. The old parameter keeps working until v3."
            ),
            Sample(
                repo: acmeAPI, number: 621,
                title: "Migrate order totals to Decimal",
                author: codex, branch: "codex/decimal-order-totals", hoursAgo: 9,
                ci: .pending, decision: nil,
                relation: [.reviewRequested], labels: ["refactor"],
                files: [
                    file("app/models/order.ts", lines: 52, removed: 44),
                    file("app/lib/money.ts", status: .added, lines: 71),
                    file("migrations/20260921_decimal_totals.sql", status: .added, lines: 17),
                ],
                body: "Work in progress — the migration still needs a backfill for archived orders.",
                isDraft: true
            ),
            Sample(
                repo: acmeAPI, number: 619,
                title: "Document rate-limit headers in the OpenAPI spec",
                author: priya, branch: "priya/ratelimit-docs", hoursAgo: 44,
                ci: .success, decision: .approved,
                relation: [.mentioned], labels: ["docs"],
                files: [file("openapi/v2.yaml", lines: 61, removed: 4)],
                body: "@\(viewerLogin) could you double-check the `Retry-After` wording?"
            ),
            Sample(
                repo: shepherd, number: 405,
                title: "Show the head commit in the merge sheet",
                author: viewer, branch: "jonas/merge-sheet-head", hoursAgo: 4,
                ci: .success, decision: .reviewRequired,
                relation: [.author], labels: ["merge"],
                files: [
                    file("Shepherd/Features/PullRequest/MergeSheet.swift", lines: 27, removed: 8),
                    file("Shepherd/Resources/Localizable.xcstrings", lines: 12),
                ],
                body: "The sheet now says which commit it is about to merge, so a push during review is visible."
            ),
        ]
    }

    /// Every seeded inbox row.
    static var pullRequests: [PullRequestSummary] {
        samples.map(summary(for:))
    }

    private static func summary(for sample: Sample) -> PullRequestSummary {
        let checks = checkRuns(for: sample)
        return PullRequestSummary(
            id: nodeID(sample.repo, sample.number),
            repo: sample.repo,
            number: sample.number,
            title: sample.title,
            author: sample.author,
            updatedAt: Date().addingTimeInterval(-sample.hoursAgo * 3_600),
            createdAt: Date().addingTimeInterval(-(sample.hoursAgo + 18) * 3_600),
            isDraft: sample.isDraft,
            additions: sample.files.reduce(0) { $0 + $1.additions },
            deletions: sample.files.reduce(0) { $0 + $1.deletions },
            changedFiles: sample.files.count,
            headRefName: sample.branch,
            headRefOid: headOid(sample),
            baseRefName: "main",
            reviewDecision: sample.decision,
            checkRollup: CheckRollup(runs: checks),
            myRelation: sample.relation,
            labels: sample.labels,
            mergeable: .mergeable
        )
    }

    private static func detail(for summary: PullRequestSummary) -> PullRequestDetail {
        guard let sample = samples.first(where: { nodeID($0.repo, $0.number) == summary.id }) else {
            return PullRequestDetail(summary: summary)
        }
        let isShowcase = sample.repo.fullName == showcase.repo && sample.number == showcase.number
        let commits = isShowcase ? ShowcaseFiles.commits(author: sample.author) : [
            CommitInfo(
                oid: headOid(sample),
                messageHeadline: sample.title,
                author: sample.author,
                committedDate: summary.updatedAt
            ),
        ]
        return PullRequestDetail(
            summary: summary,
            bodyMarkdown: sample.body,
            commits: commits,
            files: sample.files,
            threads: isShowcase ? ShowcaseFiles.threads(author: sample.author, reviewer: sophie, other: tobias) : [],
            timeline: commits.map { commit in
                TimelineEvent(
                    id: "commit-\(commit.oid)",
                    kind: .commit,
                    author: commit.author ?? sample.author,
                    createdAt: commit.committedDate,
                    summary: commit.messageHeadline,
                    commitOid: commit.oid
                )
            },
            checks: checkRuns(for: sample),
            closingIssues: isShowcase
                ? [LinkedIssueReference(
                    repo: shepherd,
                    number: 42,
                    title: "Failed writes are only visible in Settings → Sync",
                    state: .open
                )]
                : []
        )
    }

    // MARK: - Checks

    private static func checkRuns(for sample: Sample) -> [CheckRun] {
        let finished = Date().addingTimeInterval(-sample.hoursAgo * 3_600 + 240)
        let names = sample.repo == acmeAPI
            ? ["lint", "typecheck", "openapi-diff", "test (node 22)"]
            : ["build (macOS 27)", "test (Linux)", "lint", "test (app, macOS 27)"]
        // Durations that differ per check and per pull request, as real CI's do.
        let durations: [TimeInterval] = [412, 263, 48, 731]
        return names.enumerated().map { index, name in
            let isLast = index == names.count - 1
            let duration = durations[index % durations.count] + Double(sample.number % 37)
            var run = CheckRun(
                id: "\(nodeID(sample.repo, sample.number))-check-\(index)",
                name: name,
                status: .completed,
                conclusion: .success,
                startedAt: finished.addingTimeInterval(-duration),
                completedAt: finished
            )
            switch sample.ci {
            case .failure where isLast:
                run.conclusion = .failure
                run.summary = sample.repo == acmeAPI
                    ? "2 failing: orders › returns next_cursor on the last page"
                    : "RowWriteStateTests.testFailedOutranksMergeQueued — XCTAssertEqual failed: (\"mergeQueued\") is not equal to (\"failed(1)\")"
            case .pending where isLast || index == names.count - 2:
                run.status = .inProgress
                run.conclusion = nil
                run.completedAt = nil
            default:
                break
            }
            return run
        }
    }

    // MARK: - Issues

    /// The issues section's rows: one an agent's pull request is already fixing, one nobody has
    /// picked up.
    static var issues: [IssueRowSummary] {
        [
            IssueRowSummary(
                id: "I_demo_shepherd_42",
                repo: shepherd,
                number: 42,
                title: "Failed writes are only visible in Settings → Sync",
                author: tobias,
                createdAt: Date().addingTimeInterval(-9 * 86_400),
                updatedAt: Date().addingTimeInterval(-0.4 * 3_600),
                labels: ["outbox", "ux"],
                myRelation: [.assigned],
                commentCount: 4,
                linkedPullRequests: [
                    LinkedPullRequestReference(
                        repo: shepherd,
                        number: 412,
                        title: "Retry failed outbox writes from the inbox row",
                        state: "OPEN",
                        author: claude
                    ),
                ]
            ),
            IssueRowSummary(
                id: "I_demo_konduit_77",
                repo: konduit,
                number: 77,
                title: "Deliveries to a slow receiver exhaust memory",
                author: dan,
                createdAt: Date().addingTimeInterval(-4 * 86_400),
                updatedAt: Date().addingTimeInterval(-1.2 * 3_600),
                labels: ["bug", "performance"],
                myRelation: [.mentioned],
                commentCount: 7
            ),
            IssueRowSummary(
                id: "I_demo_unlock_227",
                repo: unlock,
                number: 227,
                title: "Licences expiring today are rejected at midnight UTC",
                author: sophie,
                createdAt: Date().addingTimeInterval(-2 * 86_400),
                updatedAt: Date().addingTimeInterval(-7 * 3_600),
                labels: ["bug"],
                myRelation: [.authored],
                commentCount: 2
            ),
        ]
    }

    private static func issueBody(_ issue: IssueRowSummary) -> String {
        switch issue.number {
        case 42:
            return """
                When GitHub refuses a write — a revoked token, a branch protection rule — the only \
                place that says so is Settings → Sync. The inbox row keeps looking as if the review \
                went out.

                **Expected:** the row shows that the write failed and offers to retry it.
                """
        case 77:
            return """
                A receiver that answers in 2 s makes Konduit spawn one task per event until the \
                process is killed. Seen on the staging cluster with ~10k events a minute.
                """
        default:
            return "`Expiry.isValid(on:)` compares against the start of the day, not the end."
        }
    }

    // MARK: - Outbox

    /// A comment GitHub refused, and a merge waiting to be sent — so the row chips for both show.
    ///
    /// Nothing drains them: the sweep loop is off in demo mode, and a manual drain would fail
    /// against ``DemoTransport`` and leave them as they are.
    /// One merge series in progress on konduit (ADR 0041), so a screenshot shows the chips: the
    /// first entry merged, the second waiting for GitHub's branch update, the third in line. The
    /// active entry stays in "updating branch" for the demo's lifetime — the demo never sweeps,
    /// so no new head arrives and nothing is written.
    /// - Parameter now: When the series was started.
    static func mergeSeries(now: Date) -> MergeSeries {
        let rows = pullRequests.filter { $0.repo == konduit }
        func row(_ number: Int) -> PullRequestSummary? { rows.first { $0.number == number } }
        var series = MergeSeries(
            repository: konduit,
            pullRequests: [row(86), row(90), row(88)].compactMap { $0 },
            mergeMethod: "squash",
            deletesHeadBranch: true,
            now: now.addingTimeInterval(-600)
        )
        if series.entries.count == 3 {
            series.entries[0].state = .merged
            series.entries[1].state = .updatingBranch(from: series.entries[1].pinnedHeadOid)
            series.entries[1].activeSince = now
            series.entries[1].updateQueuedAt = now
        }
        return series
    }

    static var outbox: [OutboxItem] {
        [
            OutboxItem(
                prID: nodeID(shepherd, 409),
                repo: shepherd,
                number: 409,
                action: .addPullRequestComment(body: "Could the lane headers show the thresholds?"),
                createdAt: Date().addingTimeInterval(-3_000),
                attemptCount: 1,
                lastError: "Resource not accessible by integration",
                lastErrorCode: GitHubError.forbidden(message: "Resource not accessible by integration")
                    .storageCode,
                state: .failed
            ),
            OutboxItem(
                prID: nodeID(unlock, 229),
                repo: unlock,
                number: 229,
                action: .merge(method: "squash", expectedHeadOid: headOid(unlock, 229)),
                createdAt: Date().addingTimeInterval(-60),
                // Due in an hour, so even a drain somebody starts by hand leaves it queued.
                nextAttemptAt: Date().addingTimeInterval(3_600)
            ),
        ]
    }

    // MARK: - Helpers

    private static func nodeID(_ repo: RepoRef, _ number: Int) -> String {
        "PR_demo_\(repo.owner)_\(repo.name)_\(number)"
    }

    private static func headOid(_ sample: Sample) -> String {
        let isShowcase = sample.repo.fullName == showcase.repo && sample.number == showcase.number
        return isShowcase ? ShowcaseFiles.headOid : headOid(sample.repo, sample.number)
    }

    /// A stable, commit-shaped hex string for a pull request.
    private static func headOid(_ repo: RepoRef, _ number: Int) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(repo.fullName)#\(number)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hex = String(hash, radix: 16)
        return String(repeating: hex, count: 3).prefix(40).description
    }

    /// A changed file whose counts are given rather than derived from a patch.
    private static func file(
        _ path: String,
        status: FileChangeStatus = .modified,
        lines additions: Int,
        removed deletions: Int = 0
    ) -> ChangedFile {
        ChangedFile(path: path, status: status, additions: additions, deletions: deletions)
    }
}
#endif
