import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

/// The three issue facets, as strings (ADR 0032).
///
/// Pinned here for ``InboxQuery``'s reason: a facet's query string *is* the contract with
/// GitHub's search index, and its `impliedRelations` are the only thing that tells the inbox why
/// a row is in it — a typo in either is invisible until somebody notices a rail section is always
/// empty.
final class IssueQueryTests: XCTestCase {
    func testTheThreeFacetsAreTheDocumentedSearchExpressions() {
        XCTAssertEqual(IssueQuery.openIssuePrefix, "is:issue is:open archived:false")
        XCTAssertEqual(IssueQuery.assigned.rawQuery, "is:issue is:open archived:false assignee:@me")
        XCTAssertEqual(IssueQuery.authored.rawQuery, "is:issue is:open archived:false author:@me")
        XCTAssertEqual(
            IssueQuery.mentioned.rawQuery,
            "is:issue is:open archived:false mentions:@me"
        )
    }

    func testEachFacetImpliesExactlyOneRelation() {
        XCTAssertEqual(IssueQuery.assigned.impliedRelations, [.assigned])
        XCTAssertEqual(IssueQuery.authored.impliedRelations, [.authored])
        XCTAssertEqual(IssueQuery.mentioned.impliedRelations, [.mentioned])
    }

    func testTheDefaultSweepIsTheThreeFacetsInRailOrder() {
        XCTAssertEqual(
            IssueQuery.defaultSweep.map(\.rawQuery),
            [
                "is:issue is:open archived:false assignee:@me",
                "is:issue is:open archived:false author:@me",
                "is:issue is:open archived:false mentions:@me",
            ]
        )
        // No `involves:@me` catch-all, unlike the pull-request sweep: an issue reaches somebody
        // by being assigned to them, opened by them or mentioning them.
        XCTAssertFalse(IssueQuery.defaultSweep.contains { $0.rawQuery.contains("involves:@me") })
    }

    func testTheSweepIsTheInboxSweepWithOneWordChanged() {
        // The one line that says *why* this is a sibling and not a second read path (ADR 0032).
        XCTAssertEqual(
            IssueQuery.openIssuePrefix,
            InboxQuery.openPullRequestPrefix.replacingOccurrences(of: "is:pr", with: "is:issue")
        )
    }

    func testScopingToAnOrganisationKeepsTheRelations() {
        let scoped = IssueQuery.assigned.scoped(toOrganization: "schnaq")
        XCTAssertEqual(scoped.rawQuery, "is:issue is:open archived:false assignee:@me org:schnaq")
        XCTAssertEqual(scoped.impliedRelations, [.assigned])
    }
}
