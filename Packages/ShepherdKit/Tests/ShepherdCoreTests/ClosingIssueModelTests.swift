import Foundation
import XCTest
@testable import ShepherdCore

/// The pull-request side of ADR 0032's link as a value: what identifies a
/// ``LinkedIssueReference``, and what ``PullRequestDetail`` does with a payload that predates the
/// field.
final class ClosingIssueModelTests: XCTestCase {
    private func reference(
        number: Int = 142,
        repo: RepoRef = Fixtures.repo,
        title: String = "Uploads fail silently",
        state: IssueSummary.State = .open
    ) -> LinkedIssueReference {
        LinkedIssueReference(repo: repo, number: number, title: title, state: state)
    }

    func testAReferenceIsIdentifiedByItsRepositoryAndNumber() {
        let issue = reference()
        XCTAssertEqual(issue.id, "schnaq/review#142")
        XCTAssertEqual(issue.slug, "schnaq/review#142")
        // The same number in another repository is another issue — which is the whole reason the
        // repository is stored by value.
        let elsewhere = reference(repo: RepoRef(owner: "schnaq", name: "shepherd-web"))
        XCTAssertNotEqual(issue.id, elsewhere.id)
        XCTAssertNotEqual(issue, elsewhere)
    }

    func testAReferenceRoundTripsThroughCoding() throws {
        let issue = reference(state: .closed)
        let data = try JSONEncoder().encode(issue)
        let decoded = try JSONDecoder().decode(LinkedIssueReference.self, from: data)
        XCTAssertEqual(decoded, issue)
        XCTAssertEqual(decoded.state, .closed)
    }

    func testADetailCarriesNoClosingIssuesUnlessItIsGivenSome() {
        let detail = PullRequestDetail(summary: Fixtures.summary(id: "PR_1"))
        XCTAssertTrue(detail.closingIssues.isEmpty)
    }

    func testADetailRoundTripsItsClosingIssues() throws {
        let detail = PullRequestDetail(
            summary: Fixtures.summary(id: "PR_1"),
            bodyMarkdown: "Closes #142.",
            closingIssues: [reference(), reference(number: 7, state: .closed)]
        )
        let data = try JSONEncoder().encode(detail)
        let decoded = try JSONDecoder().decode(PullRequestDetail.self, from: data)
        XCTAssertEqual(decoded, detail)
        XCTAssertEqual(decoded.closingIssues.map(\.number), [142, 7])
    }

    func testADetailEncodedBeforeTheFieldExistedStillDecodes() throws {
        // The tolerance the field was added with: a payload with no `closingIssues` key at all —
        // anything written by a build before this sprint — decodes as "closes nothing" rather
        // than failing the whole record.
        let detail = PullRequestDetail(
            summary: Fixtures.summary(id: "PR_1"),
            bodyMarkdown: "Moves the token store."
        )
        let data = try JSONEncoder().encode(detail)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "closingIssues")
        XCTAssertNil(object["closingIssues"])
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PullRequestDetail.self, from: stripped)
        XCTAssertTrue(decoded.closingIssues.isEmpty)
        XCTAssertEqual(decoded.bodyMarkdown, "Moves the token store.")
    }

    func testOnlyTheSummaryIsRequired() throws {
        // Every list is a list of things a fetch may have learned nothing about, so an absent one
        // is empty; the summary *is* the pull request and stays required.
        let summary = Fixtures.summary(id: "PR_1")
        let summaryData = try JSONEncoder().encode(summary)
        let summaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: summaryData) as? [String: Any]
        )
        let data = try JSONSerialization.data(withJSONObject: ["summary": summaryObject])

        let decoded = try JSONDecoder().decode(PullRequestDetail.self, from: data)
        XCTAssertEqual(decoded.summary, summary)
        XCTAssertEqual(decoded.bodyMarkdown, "")
        XCTAssertTrue(decoded.commits.isEmpty)
        XCTAssertTrue(decoded.files.isEmpty)
        XCTAssertTrue(decoded.threads.isEmpty)
        XCTAssertTrue(decoded.timeline.isEmpty)
        XCTAssertTrue(decoded.checks.isEmpty)
        XCTAssertTrue(decoded.closingIssues.isEmpty)
    }

    func testADetailWithoutASummaryIsRefused() throws {
        let data = Data("{\"bodyMarkdown\":\"no summary here\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PullRequestDetail.self, from: data))
    }
}
