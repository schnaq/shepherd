import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// What an inbox row says in words (``InboxRowText``) — the contract both the Mac's row and the
/// iPhone's row (ADR 0044) draw from: which status chip wins, and that the spoken sentence names
/// every chip the row shows.
final class InboxRowTextTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    private func row(
        isDraft: Bool = false,
        reviewDecision: ReviewDecision? = nil,
        checks: CheckRollup.State? = nil,
        relation: Set<Relation> = [],
        stack: PullRequestStack? = nil,
        mergeable: Mergeable? = nil
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: repo,
            number: 1,
            title: "Tidy the inbox",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            isDraft: isDraft,
            headRefName: "tidy",
            headRefOid: "abc",
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkRollup: checks.map { CheckRollup(state: $0, total: 2, failureCount: $0 == .failure ? 2 : 0) },
            myRelation: relation,
            mergeable: mergeable,
            stack: stack
        )
    }

    private func chip(_ row: PullRequestSummary, write: RowWriteState? = nil) -> String? {
        InboxRowText.statusChip(for: row, write: write)?.text
    }

    func testAWriteOnItsWayOutranksFailingChecks() {
        XCTAssertEqual(chip(row(checks: .failure), write: .mergeQueued), RowWriteState.mergeQueued.text)
    }

    func testTheChipFollowsTheFixedOrder() {
        let count = 2
        let failing = String(localized: "\(count) checks failing")
        XCTAssertEqual(chip(row(reviewDecision: .approved, checks: .failure, relation: [.reviewRequested])), failing)
        XCTAssertEqual(
            chip(row(reviewDecision: .approved, checks: .pending, relation: [.reviewRequested])),
            String(localized: "CI running")
        )
        XCTAssertEqual(
            chip(row(reviewDecision: .approved, relation: [.reviewRequested])),
            ReviewDecision.approved.chipTitle
        )
        XCTAssertEqual(chip(row(relation: [.reviewRequested])), String(localized: "Review requested"))
        XCTAssertNil(chip(row()))
    }

    func testAConflictOutranksFailingChecksAndTheVerdictButNotAWrite() {
        let conflicting = row(reviewDecision: .approved, checks: .failure, mergeable: .conflicting)
        XCTAssertEqual(chip(conflicting), String(localized: "Conflicts"))
        XCTAssertEqual(chip(conflicting, write: .mergeQueued), RowWriteState.mergeQueued.text)
        XCTAssertEqual(chip(row(reviewDecision: .approved, mergeable: .unknown)), ReviewDecision.approved.chipTitle)
    }

    func testTheSpokenLabelNamesEveryChipTheRowShows() {
        let stack = PullRequestStack(number: 7, size: 3, position: 2, baseRefName: "main")
        let rounds = ReviewRoundsSummary(roundCount: 2, unchangedFindingCount: 1)
        let summary = row(isDraft: true, checks: .failure, stack: stack)
        let label = InboxRowText.spokenLabel(for: summary, hasSession: false, rounds: rounds, write: nil)

        for part in [String(localized: "Draft"), stack.chipHelp, rounds.chipText!, chip(summary)!] {
            XCTAssertTrue(label.contains(part), "\(label) leaves out \(part)")
        }
    }
}
