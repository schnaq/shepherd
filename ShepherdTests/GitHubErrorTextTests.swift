import Foundation
import GitHubKit
import ShepherdCore
import ShepherdSync
import XCTest

@testable import Shepherd

/// The app-side rendering of GitHub errors, sync failures, stored outbox errors and inbox section
/// headers (ADR 0022, 2026-09-22 amendment).
///
/// Asserted in English — the suite runs with `-testLanguage en` — plus two lookups through the
/// compiled `de.lproj`, the way `LocalizationTests` does it, so the German wiring is covered
/// without depending on the runner's language.
@MainActor
final class GitHubErrorTextTests: XCTestCase {
    /// Every case whose English rendering is the package's own sentence, word for word.
    private let parityCases: [GitHubError] = [
        .invalidURL("not a url"),
        .transport(message: "offline"),
        .unauthorized,
        .forbidden(message: "Resource not accessible by integration"),
        .rateLimited(retryAfter: 41.6, resetAt: nil),
        .rateLimited(retryAfter: nil, resetAt: nil),
        .notFound(resource: "schnaq/review#128"),
        .validationFailed(message: "line not in diff"),
        .notMergeable(message: "Pull Request is not mergeable"),
        .staleHead(expected: "abc", actual: "def"),
        .staleHead(expected: "abc", actual: nil),
        .conflict(message: "reference already exists"),
        .graphQL(messages: ["one", "two"]),
        .decoding(message: "keyNotFound"),
        .responseTooLarge(resource: "The log", bytes: 20_971_520, limit: 10_485_760),
        .server(status: 502, message: "bad gateway"),
        .deviceFlowDenied,
        .deviceFlowExpired,
        .deviceFlowError(code: "unsupported_grant_type", description: nil),
        .deviceFlowError(code: "x", description: "GitHub's own words"),
        .tokenRefreshFailed(message: "bad_refresh_token"),
        .missingToken(login: "octocat"),
        .missingToken(login: nil),
    ]

    private func germanTable() throws -> Bundle {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "de", withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    // MARK: - GitHubError

    func testTheEnglishRenderingSaysWhatThePackageSays() {
        for error in parityCases {
            XCTAssertEqual(error.localizedMessage(), error.errorDescription, "\(error)")
        }
    }

    func testUserFacingDescriptionPrefersTheAppRendering() {
        let error: any Error = GitHubError.unauthorized
        XCTAssertEqual(
            error.userFacingDescription,
            GitHubError.unauthorized.localizedMessage()
        )
    }

    func testTheGermanTableIsConsultedAndGitHubsWordsStayVerbatim() throws {
        let german = try germanTable()
        XCTAssertEqual(
            GitHubError.unauthorized.localizedMessage(bundle: german),
            "GitHub hat die Anmeldedaten abgelehnt. Melde dich erneut an."
        )
        XCTAssertEqual(
            GitHubError.server(status: 502, message: "bad gateway").localizedMessage(bundle: german),
            "GitHub antwortete mit 502: bad gateway"
        )
    }

    // MARK: - SyncFailure

    func testAFailureWithoutAGitHubErrorShowsItsEnglishMessage() {
        let failure = SyncFailure(stage: .sweep, message: "disk I/O error")
        XCTAssertEqual(failure.localizedMessage(), "disk I/O error")
    }

    func testAFailureIsRecomposedFromItsContext() {
        let error = GitHubError.notFound(resource: "schnaq/review#12")
        XCTAssertEqual(
            SyncFailure(stage: .sweep, message: "x", error: error, context: .issueSweep)
                .localizedMessage(),
            "Issue sweep: Not found: schnaq/review#12"
        )
        XCTAssertEqual(
            SyncFailure(
                stage: .detail,
                message: "x",
                error: error,
                context: .pullRequestDetail(slug: "schnaq/review#12")
            ).localizedMessage(),
            "schnaq/review#12: Not found: schnaq/review#12"
        )
    }

    // MARK: - Stored outbox errors

    func testAStoredCodeIsPreferredAndAnUnreadableOneFallsBackToTheText() {
        var item = OutboxItem(
            prID: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 1,
            action: .markReadyForReview,
            lastError: "English text from an older build"
        )
        XCTAssertEqual(item.localizedLastError, "English text from an older build")

        item.lastErrorCode = GitHubError.forbidden(message: "nope").storageCode
        XCTAssertEqual(item.localizedLastError, "GitHub refused the request: nope")

        item.lastErrorCode = "not a code"
        XCTAssertEqual(item.localizedLastError, "English text from an older build")
    }

    // MARK: - Inbox sections

    func testSectionHeadersUseTheRailsAndTheChipsWords() {
        XCTAssertEqual(InboxSection.Kind.humans.localizedTitle, "Humans")
        XCTAssertEqual(InboxSection.Kind.bots.localizedTitle, "Bots")
        XCTAssertEqual(
            InboxSection.Kind.agent(displayName: "Claude Code").localizedTitle,
            "Claude Code"
        )
        XCTAssertEqual(
            InboxSection.Kind.repository(RepoRef(owner: "schnaq", name: "review")).localizedTitle,
            "schnaq/review"
        )
        XCTAssertEqual(
            InboxSection.Kind.reviewDecision(.changesRequested).localizedTitle,
            ReviewDecision.changesRequested.chipTitle
        )
        XCTAssertEqual(InboxSection.Kind.reviewDecision(nil).localizedTitle, "No review decision")
    }
}
