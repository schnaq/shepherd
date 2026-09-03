import Foundation
import XCTest

@testable import ShepherdCore

/// Reading an issue's acceptance criteria, matching them, and what the card's issue line then says
/// (ADR 0026's amendment, plan §2.A).
///
/// Three things here are where a wrong answer does damage, so each has its own group:
///
/// - **Which list is the criteria.** A checklist wins outright; with none, an acceptance-ish
///   heading points at one; with neither, the first list is a *guess* — and the guess is the whole
///   reason an unmentioned bullet may never be a contradiction.
/// - **The thresholds.** Both of them, at the boundary: two of five words is mentioned, one of
///   five is not, and a cosine of exactly the floor counts.
/// - **The status derivation.** ✓ only when every bullet is mentioned, ? for anything less, and
///   ✗ unreachable — which is asserted rather than described, because "never" is the kind of rule
///   a later edit breaks quietly.
final class AcceptanceCriteriaTests: XCTestCase {
    // MARK: - Which list is the criteria

    func testACheckboxListWinsWhereverItIs() {
        let bullets = AcceptanceCriteria.bullets(from: """
        Uploads fail silently.

        ## Notes

        - reproduced on a train
        - happens on both networks

        ## Acceptance criteria

        - [ ] The upload retries a dropped connection
        - [x] A failure surfaces a toast
        """)

        XCTAssertEqual(
            bullets.map(\.text),
            ["The upload retries a dropped connection", "A failure surfaces a toast"]
        )
        XCTAssertEqual(bullets.map(\.isChecked), [false, true])
    }

    func testACheckboxInsideACodeFenceIsSyntaxNotACriterion() {
        let bullets = AcceptanceCriteria.bullets(from: """
        Please write the criteria like this:

        ```markdown
        - [ ] a thing that must be true
        - [x] a thing that already is
        ```

        ## Acceptance criteria

        - The upload retries a dropped connection
        - A failure surfaces a toast
        """)

        XCTAssertEqual(
            bullets.map(\.text),
            ["The upload retries a dropped connection", "A failure surfaces a toast"]
        )
        XCTAssertEqual(bullets.map(\.isChecked), [nil, nil])
    }

    func testATildeFenceHidesItsListTooAndAnUnclosedFenceHidesTheRest() {
        XCTAssertTrue(AcceptanceCriteria.bullets(from: """
        ~~~
        - [ ] not a criterion
        ~~~
        """).isEmpty)
        XCTAssertTrue(AcceptanceCriteria.bullets(from: """
        Example:
        ```
        - first
        - second
        """).isEmpty)
    }

    func testAHeadedListIsReadWhenThereAreNoCheckboxes() {
        let bullets = AcceptanceCriteria.bullets(from: """
        ## Steps to reproduce

        - open the uploader
        - pull the cable

        ### Definition of done

        - the upload retries three times
        - the partial write is recorded

        ## Notes

        - unrelated
        """)

        XCTAssertEqual(
            bullets.map(\.text),
            ["the upload retries three times", "the partial write is recorded"]
        )
        // Not a checkbox anywhere, so nothing claims to be ticked.
        XCTAssertEqual(bullets.compactMap(\.isChecked), [])
    }

    func testABoldLabelLineCountsAsAHeading() {
        // `**Acceptance criteria:**` is written at least as often as `## Acceptance criteria`.
        let bullets = AcceptanceCriteria.bullets(from: """
        Some prose first.

        **Acceptance criteria:**

        1. the retry is capped at three attempts
        2. the toast names the file
        """)

        XCTAssertEqual(
            bullets.map(\.text),
            ["the retry is capped at three attempts", "the toast names the file"]
        )
    }

    func testTheFirstListIsTheFallback() {
        let bullets = AcceptanceCriteria.bullets(from: """
        The uploader should stop lying about success.

        * retry a dropped connection
        * record the partial write

        Then some prose that is not a bullet.

        * and a second list nobody reads
        """)

        XCTAssertEqual(
            bullets.map(\.text),
            ["retry a dropped connection", "record the partial write"]
        )
    }

    func testABlankLineInsideALooseListDoesNotEndIt() {
        let bullets = AcceptanceCriteria.bullets(from: """
        - first

        - second

        prose
        """)
        XCTAssertEqual(bullets.map(\.text), ["first", "second"])
    }

    func testAnIssueWithNoListYieldsNoBullets() {
        XCTAssertTrue(AcceptanceCriteria.bullets(from: "").isEmpty)
        XCTAssertTrue(
            AcceptanceCriteria.bullets(from: """
            Uploads fail silently on a flaky connection. It should retry instead.

            See also the older report.
            """).isEmpty
        )
    }

    func testAHeadingWithNothingUnderItDoesNotBorrowALaterList() {
        let bullets = AcceptanceCriteria.bullets(from: """
        ## Acceptance criteria

        ## Notes

        - just a note
        """)
        // The headed pass finds nothing, so the fallback runs — and the fallback is honest about
        // being a guess rather than pretending the note was under the criteria heading.
        XCTAssertEqual(bullets.map(\.text), ["just a note"])
    }

    func testDecorationIsStrippedAndDuplicatesAreDropped() {
        let bullets = AcceptanceCriteria.bullets(from: """
        - [ ] `UploadStore` records the **partial** write
        - [ ] See [the RFC](https://example.com/rfc) for the retry budget
        - [ ] `UploadStore` records the **partial** write
        - [ ] Keep `test_upload_retry` green
        """)

        XCTAssertEqual(bullets.map(\.text), [
            "UploadStore records the partial write",
            "See the RFC for the retry budget",
            "Keep test_upload_retry green",
        ])
    }

    func testTheBulletCountIsCapped() {
        let body = (1...30).map { "- [ ] requirement number \($0)" }.joined(separator: "\n")
        XCTAssertEqual(
            AcceptanceCriteria.bullets(from: body).count,
            AcceptanceCriteria.maximumBullets
        )
    }

    func testProseThatMerelyLooksLikeAListIsNotOne() {
        // A marker has to be followed by whitespace, so a negative number and a hyphenated word
        // are prose. Nothing here is a list, so there are no bullets at all.
        XCTAssertTrue(AcceptanceCriteria.bullets(from: "-42 is the offset\nwell-known issue").isEmpty)
    }

    // MARK: - The matcher's thresholds

    private func bullet(_ text: String) -> AcceptanceBullet { AcceptanceBullet(text: text) }

    func testDistinctiveWordsDropShortWordsStopWordsAndNumbers() {
        XCTAssertEqual(
            AcceptanceMatcher.distinctiveWords(in: "The upload should retry #142 on a 503"),
            ["upload", "retry"]
        )
    }

    func testTwoOfFiveWordsIsMentionedAndOneOfFiveIsNot() {
        let five = bullet("upload retry backoff toast resume")
        XCTAssertEqual(AcceptanceMatcher.distinctiveWords(in: five.text).count, 5)

        let mentioned = AcceptanceMatcher.match(
            bullets: [five],
            against: "Adds an upload retry with a fixed delay."
        )
        XCTAssertTrue(mentioned[0].mentioned)
        XCTAssertTrue(mentioned[0].reason.contains("2 of 5 words"), mentioned[0].reason)

        let missed = AcceptanceMatcher.match(
            bullets: [five],
            against: "Adds an upload path and nothing else."
        )
        XCTAssertFalse(missed[0].mentioned)
        XCTAssertTrue(missed[0].reason.contains("Only 1 of the 5 words"), missed[0].reason)
    }

    func testABulletWithNoDistinctiveWordIsNotMentionedAndSaysSo() {
        let matches = AcceptanceMatcher.match(
            bullets: [bullet("It should always be done")],
            against: "Everything is done."
        )
        // Every word here is in the stop list or too short; nothing is left to look for, and
        // matching on nothing would mark every such bullet as mentioned.
        XCTAssertTrue(AcceptanceMatcher.distinctiveWords(in: "It should always be done").isEmpty)
        XCTAssertFalse(matches[0].mentioned)
        XCTAssertEqual(
            matches[0].reason,
            "This bullet has no distinctive word Shepherd could look for."
        )
    }

    func testTheCosineFloorIsInclusiveAndOnlyRunsWhenTheKeywordsMiss() {
        let subject = bullet("network failures are retried")
        let prose = "Handles a dropped socket by trying again."
        // The keyword pass shares nothing at all with the bullet, which is the case the cosine
        // exists for.
        XCTAssertEqual(
            AcceptanceMatcher.distinctiveWords(in: subject.text),
            ["network", "failures", "retried"]
        )

        // Whole components, so the cosine is exact in `Float` as well as in `Double`:
        // 3 / √(3² + 4²) = 0.6, which is the floor and therefore counts.
        let atFloor = AcceptanceMatcher.match(
            bullets: [subject],
            against: prose,
            vectors: AcceptanceVectors(
                evidence: SearchVector([1, 0]),
                byBulletText: [subject.text: SearchVector([3, 4])]
            )
        )
        XCTAssertTrue(atFloor[0].mentioned)
        XCTAssertTrue(atFloor[0].reason.contains("similarity 0.60"), atFloor[0].reason)

        // 1 / √5 = 0.447: below the floor, so the bullet stays unmentioned and the number is
        // reported rather than hidden.
        let missed = AcceptanceMatcher.match(
            bullets: [subject],
            against: prose,
            vectors: AcceptanceVectors(
                evidence: SearchVector([1, 0]),
                byBulletText: [subject.text: SearchVector([1, 2])]
            )
        )
        XCTAssertFalse(missed[0].mentioned)
        XCTAssertTrue(
            missed[0].reason.contains("On-device similarity is 0.45"),
            missed[0].reason
        )
    }

    func testWithoutVectorsTheKeywordPassIsTheWholeAnswer() {
        let matches = AcceptanceMatcher.match(
            bullets: [bullet("network failures are retried")],
            against: "Handles a dropped socket by trying again.",
            vectors: nil
        )
        XCTAssertFalse(matches[0].mentioned)
        XCTAssertFalse(matches[0].reason.contains("similarity"), matches[0].reason)
    }

    func testTheEvidenceTextIsTheProseThePathsAndTheCommitMessages() {
        let text = AcceptanceMatcher.evidenceText(for: detail(
            body: "Retries a dropped upload.",
            files: [Fixtures.file("Sources/Uploader/RetryPolicy.swift")],
            commits: [
                CommitInfo(
                    oid: "abc",
                    messageHeadline: "record the partial write",
                    committedDate: Fixtures.date(0)
                )
            ]
        ))
        XCTAssertTrue(text.contains("Retries a dropped upload."), text)
        XCTAssertTrue(text.contains("Sources/Uploader/RetryPolicy.swift"), text)
        XCTAssertTrue(text.contains("record the partial write"), text)
        // The hunks are deliberately absent: a diff's identifiers are not the words a requirement
        // is written in, and feeding them in would mark every bullet as mentioned.
        XCTAssertFalse(text.contains("@@"), text)
    }

    // MARK: - The status the card shows

    private func detail(
        body: String = "",
        files: [ChangedFile] = [],
        commits: [CommitInfo] = []
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: Fixtures.summary(id: "PR_1", title: "Retry a dropped upload"),
            bodyMarkdown: body,
            commits: commits,
            files: files
        )
    }

    private func issue(
        number: Int = 142,
        body: String,
        state: IssueSummary.State = .open,
        isPullRequest: Bool = false
    ) -> IssueSummary {
        IssueSummary(
            repo: Fixtures.repo,
            number: number,
            title: "Uploads fail silently",
            bodyMarkdown: body,
            state: state,
            isPullRequest: isPullRequest,
            url: URL(string: "https://github.com/schnaq/review/issues/\(number)")
        )
    }

    private func verdict(
        issue: IssueSummary?,
        detail: PullRequestDetail,
        failure: IssueLookupFailure? = nil
    ) -> EvidenceVerdict {
        let bullets = issue.map { AcceptanceCriteria.bullets(from: $0.bodyMarkdown) } ?? []
        let matches = issue.map { _ in
            AcceptanceMatcher.match(
                bullets: bullets,
                against: AcceptanceMatcher.evidenceText(for: detail)
            )
        }
        return EvidenceChecker.check(
            Claim(kind: .fixesIssue(number: issue?.number ?? 142), quote: "Fixes #142."),
            in: detail,
            issue: issue,
            matches: matches,
            failure: failure
        )
    }

    func testTheOldSignatureStillSaysTheCriteriaWereNotChecked() {
        // The wrapper every other claim goes through, unchanged: two facts, the reference and
        // what was not checked.
        let old = EvidenceChecker.check(
            Claim(kind: .fixesIssue(number: 142), quote: "Fixes #142."),
            in: detail()
        )
        XCTAssertEqual(old.status, .unclear)
        XCTAssertEqual(old.facts.count, 2)
        XCTAssertEqual(
            old.facts.last?.text,
            "Acceptance criteria not checked — the issue is not fetched."
        )
        XCTAssertTrue(old.facts.allSatisfy { $0.mark == nil })
    }

    func testAFailedReadKeepsTheNotCheckedFactAndAddsTheReason() {
        for failure in IssueLookupFailure.allCases {
            let result = verdict(issue: nil, detail: detail(), failure: failure)
            XCTAssertEqual(result.status, .unclear)
            XCTAssertEqual(result.facts.count, 3, "\(failure)")
            XCTAssertEqual(
                result.facts[1].text,
                "Acceptance criteria not checked — the issue is not fetched."
            )
            XCTAssertEqual(result.facts[2].text, failure.sentence)
        }
        XCTAssertTrue(
            IssueLookupFailure.notFound.sentence.contains("no issue with that number")
        )
    }

    func testEveryBulletMentionedIsTheOneWayToGetATick() {
        let result = verdict(
            issue: issue(body: """
            ## Acceptance criteria

            - [ ] the upload retries a dropped connection
            - [ ] the partial write is recorded
            """),
            detail: detail(
                body: "Retries a dropped connection and records the partial write.",
                files: [Fixtures.file("Sources/Uploader/RetryPolicy.swift")]
            )
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.facts.filter { $0.mark == .mentioned }.count, 2)
        XCTAssertTrue(
            result.facts.contains { $0.text.contains("Every acceptance bullet is mentioned") },
            result.facts.map(\.text).joined(separator: " | ")
        )
    }

    func testSomeBulletsMentionedIsUnclearAndNeverContradicted() {
        let result = verdict(
            issue: issue(body: """
            ## Acceptance criteria

            - [ ] the upload retries a dropped connection
            - [ ] the crash reporter learns about the failure
            """),
            detail: detail(body: "Retries a dropped connection.")
        )
        // The whole point of the amendment: an unmentioned bullet is a question, so the strongest
        // answer here is "?" with the bullet named.
        XCTAssertEqual(result.status, .unclear)
        XCTAssertNotEqual(result.status, .contradicted)
        XCTAssertEqual(result.facts.filter { $0.mark == .mentioned }.count, 1)
        XCTAssertEqual(result.facts.filter { $0.mark == .notMentioned }.count, 1)
        XCTAssertTrue(
            result.facts.contains { $0.text.contains("1 of 2 acceptance bullets are mentioned") },
            result.facts.map(\.text).joined(separator: " | ")
        )
    }

    func testNoBulletMentionedIsStillUnclear() {
        let result = verdict(
            issue: issue(body: "- [ ] the crash reporter learns about the failure"),
            detail: detail(body: "Renames a variable.")
        )
        XCTAssertEqual(result.status, .unclear)
        XCTAssertEqual(result.facts.filter { $0.mark == .notMentioned }.count, 1)
    }

    func testAnIssueWithNoChecklistSaysThatRatherThanTickingNothing() {
        let result = verdict(
            issue: issue(body: "Uploads fail silently. Please fix."),
            detail: detail(body: "Retries a dropped connection.")
        )
        XCTAssertEqual(result.status, .unclear)
        XCTAssertEqual(result.facts.count, 2)
        XCTAssertTrue(
            result.facts[1].text.contains("holds no checklist or list"),
            result.facts[1].text
        )
        XCTAssertTrue(result.facts.allSatisfy { $0.mark == nil })
    }

    func testAPullRequestReferenceHasNoBullets() {
        let result = verdict(
            issue: issue(
                number: 7,
                body: "- [ ] this is a task list in a pull request",
                isPullRequest: true
            ),
            detail: detail(body: "Fixes #7.")
        )
        XCTAssertEqual(result.status, .unclear)
        XCTAssertEqual(result.facts.count, 2)
        XCTAssertTrue(
            result.facts[1].text.contains("is a pull request rather than an issue"),
            result.facts[1].text
        )
        XCTAssertTrue(result.facts.allSatisfy { $0.mark == nil })
    }

    func testTheReferenceFactCarriesTheIssuesOwnURL() {
        let result = verdict(
            issue: issue(body: "- [ ] retry the upload"),
            detail: detail(body: "Retries the upload.")
        )
        XCTAssertEqual(
            result.facts.first?.url,
            URL(string: "https://github.com/schnaq/review/issues/142")
        )
        // Only the reference fact links out: a bullet is text, and eight copies of the same link
        // under one line would be noise.
        XCTAssertEqual(result.facts.filter { $0.url != nil }.count, 1)
    }

    func testTheIssueFactNamesTheTitleTheStateAndTheCount() {
        let openIssue = verdict(
            issue: issue(body: "- [ ] retry the upload"),
            detail: detail(body: "Retries the upload.")
        )
        XCTAssertEqual(
            openIssue.facts[1].text,
            "Issue #142 “Uploads fail silently” is open and lists 1 acceptance bullet."
        )

        let closedIssue = verdict(
            issue: issue(body: "- [ ] retry the upload\n- [ ] record the write", state: .closed),
            detail: detail(body: "Retries the upload and records the write.")
        )
        XCTAssertEqual(
            closedIssue.facts[1].text,
            "Issue #142 “Uploads fail silently” is closed and lists 2 acceptance bullets."
        )
    }
}
