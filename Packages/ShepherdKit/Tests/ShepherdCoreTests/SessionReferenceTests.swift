import Foundation
import XCTest

@testable import ShepherdCore

/// The return address in the head commits, and the message a finding becomes (ADR 0030).
///
/// Both halves are pure, so both are tested here rather than in the app: the parser decides
/// whether the button appears at all, and the composer decides what the confirmation sheet shows
/// — which is, character for character, what the user's own CLI receives.
final class SessionReferenceTests: XCTestCase {
    private func commit(
        _ oid: String,
        body: String,
        at seconds: TimeInterval = 0
    ) -> CommitInfo {
        CommitInfo(
            oid: oid,
            messageHeadline: "headline",
            messageBody: body,
            committedDate: Date(timeIntervalSince1970: seconds)
        )
    }

    // MARK: - One reference

    func testARemoteSessionURLIsParsedWithItsHost() {
        let references = SessionReference.parse(trailers: [
            "Co-Authored-By: Claude <noreply@anthropic.com>",
            "Claude-Session: https://claude.ai/code/session_01KcEgovTAxjdwUVJZMQSd6q",
        ])
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.id, "session_01KcEgovTAxjdwUVJZMQSd6q")
        XCTAssertEqual(references.first?.kind, .remote)
        XCTAssertEqual(references.first?.host, "claude.ai")
        XCTAssertEqual(
            references.first?.url?.absoluteString,
            "https://claude.ai/code/session_01KcEgovTAxjdwUVJZMQSd6q"
        )
    }

    func testABareSessionIDIsLocalAndCarriesNoURL() {
        let references = SessionReference.parse(trailers: ["Claude-Session: session_0abc"])
        XCTAssertEqual(references.first?.kind, .local)
        XCTAssertEqual(references.first?.id, "session_0abc")
        XCTAssertNil(references.first?.url)
        XCTAssertNil(references.first?.host)
    }

    func testAnExplicitLocalPrefixIsLocalAndKeepsWhateverIDFollows() {
        let references = SessionReference.parse(trailers: ["Claude-Session: local:my-session-7"])
        XCTAssertEqual(references.first?.kind, .local)
        XCTAssertEqual(references.first?.id, "my-session-7")
    }

    func testTheTrailerKeyIsMatchedCaseInsensitively() {
        XCTAssertEqual(
            SessionReference.parse(trailers: ["claude-session: session_1"]).first?.id,
            "session_1"
        )
    }

    func testAURLWithATrailingSlashAndAQueryStillYieldsTheID() {
        let references = SessionReference.parse(trailers: [
            "Claude-Session: https://claude.ai/code/session_01x/?tab=diff"
        ])
        XCTAssertEqual(references.first?.id, "session_01x")
        XCTAssertEqual(references.first?.kind, .remote)
    }

    // MARK: - Several references

    func testSeveralReferencesKeepTheirOrder() {
        let references = SessionReference.parse(trailers: [
            "Claude-Session: session_1",
            "Signed-off-by: Someone <someone@example.com>",
            "Claude-Session: https://claude.ai/code/session_2",
            "Claude-Session: local:three",
        ])
        XCTAssertEqual(references.map(\.id), ["session_1", "session_2", "three"])
        XCTAssertEqual(references.map(\.kind), [.local, .remote, .local])
    }

    // MARK: - No reference

    func testNoTrailersMeansNoReference() {
        XCTAssertTrue(SessionReference.parse(trailers: []).isEmpty)
        XCTAssertTrue(
            SessionReference.parse(trailers: ["Co-Authored-By: Claude"]).isEmpty
        )
    }

    // MARK: - Malformed references

    func testMalformedValuesAreSkippedRatherThanGuessedAt() {
        let references = SessionReference.parse(trailers: [
            // No colon at all.
            "Claude-Session session_1",
            // A URL with no id after `/code/`.
            "Claude-Session: https://claude.ai/code/",
            // A URL whose last component is not a session id.
            "Claude-Session: https://claude.ai/code/not-a-session",
            // The prefix and nothing else.
            "Claude-Session: session_",
            // Not a URL, not an id.
            "Claude-Session: ask me nicely",
            // `local:` with nothing behind it.
            "Claude-Session: local:",
            // An id with a shell metacharacter in it.
            "Claude-Session: session_1;rm -rf /",
        ])
        XCTAssertTrue(references.isEmpty, "parsed \(references.map(\.id))")
    }

    // MARK: - Ordering across commits

    func testTheLastCommitsReferenceWins() {
        let commits = [
            commit("a", body: "Claude-Session: session_first", at: 100),
            commit("b", body: "Co-Authored-By: Claude", at: 200),
            commit("c", body: "Claude-Session: session_last", at: 300),
        ]
        XCTAssertEqual(SessionReference.mostRecent(in: commits)?.id, "session_last")
    }

    func testTheLastTrailerOfTheLastCommitThatHasOneWins() {
        let commits = [
            commit("a", body: "Claude-Session: session_first"),
            commit(
                "b",
                body: """
                    Claude-Session: session_earlier
                    Claude-Session: session_later
                    """
            ),
        ]
        XCTAssertEqual(SessionReference.mostRecent(in: commits)?.id, "session_later")
    }

    func testCommitsWithoutAnyReferenceGiveNothing() {
        XCTAssertNil(SessionReference.mostRecent(in: [commit("a", body: "Fixes #1")]))
        XCTAssertNil(SessionReference.mostRecent(in: []))
    }

    // MARK: - The message

    func testTheMessageCarriesTheLocationTheTextAndTheLink() {
        let message = SessionMessage.compose(
            finding: SessionMessage.Finding(
                path: "Sources/App.swift",
                line: 120,
                text: "This leaks the file handle when the guard fires.\n"
            ),
            pullRequest: SessionMessage.PullRequestReference(
                slug: "schnaq/review#42",
                url: "https://github.com/schnaq/review/pull/42"
            )
        )
        XCTAssertEqual(
            message,
            """
            Review finding on schnaq/review#42
            Sources/App.swift:120

            This leaks the file handle when the guard fires.

            https://github.com/schnaq/review/pull/42
            """
        )
    }

    func testTheRoundIsNamedWhenThereIsOne() {
        let message = SessionMessage.compose(
            finding: SessionMessage.Finding(path: "a.swift", line: 1, text: "again"),
            pullRequest: SessionMessage.PullRequestReference(slug: "o/r#1", url: "https://x/1"),
            round: 3
        )
        XCTAssertTrue(message.hasPrefix("Review finding on o/r#1, review round 3\na.swift:1"))
        // A round of zero is no round, not "round 0".
        let zero = SessionMessage.compose(
            finding: SessionMessage.Finding(path: "a.swift", line: 1, text: "again"),
            pullRequest: SessionMessage.PullRequestReference(slug: "o/r#1", url: "https://x/1"),
            round: 0
        )
        XCTAssertTrue(zero.hasPrefix("Review finding on o/r#1\n"))
    }

    func testASummaryHasNoLocationLineAndAFindingWithoutALineJustNamesTheFile() {
        let summary = SessionMessage.compose(
            finding: SessionMessage.Finding(text: "The rename is inconsistent."),
            pullRequest: SessionMessage.PullRequestReference(slug: "o/r#2", url: "https://x/2")
        )
        XCTAssertEqual(
            summary,
            """
            Review finding on o/r#2

            The rename is inconsistent.

            https://x/2
            """
        )

        let fileOnly = SessionMessage.compose(
            finding: SessionMessage.Finding(path: "a.swift", text: "here"),
            pullRequest: SessionMessage.PullRequestReference(slug: "o/r#2", url: "https://x/2")
        )
        XCTAssertTrue(fileOnly.contains("\na.swift\n"))
    }

    func testTheReviewersTextIsCarriedVerbatim() {
        let typed = "Use `ShellWords` here — see line 20:\n\n  let x = 1\n"
        let message = SessionMessage.compose(
            finding: SessionMessage.Finding(path: "a.swift", line: 3, text: typed),
            pullRequest: SessionMessage.PullRequestReference(slug: "o/r#3", url: "https://x/3")
        )
        XCTAssertTrue(message.contains(typed.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
