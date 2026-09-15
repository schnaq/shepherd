import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The rail the inbox comes back to after a trip to the review screen (ADR 0013).
///
/// `InboxScreen` is rebuilt whenever the route changes, so the rail has to be *said* somewhere the
/// rebuild cannot reach — a `@SceneStorage` string — and ``InboxModel/RailState`` is that sentence.
/// What is asserted here is the sentence and nothing else: that every facet the sidebar can set
/// survives being written down and read back, including the combinations the
/// `shepherd://inbox?filter=…` grammar has no way to say.
///
/// That last part is the point of the type. The rail composes — a smart view *and* a repository
/// *and* a provenance *and* a risk *and* a lane — while a link token does not, so the facets
/// travel as fields. The ordinary rail "Needs my review, in this repository" is the case that
/// proves it: it has no token, and the first draft of this feature restored it as an unfiltered
/// inbox.
///
/// Nothing here builds an `InboxModel`. It cannot: the model takes a `SignedInSession`, whose
/// initialiser is private and whose `make(account:tokenStore:sweepInterval:)` wants the Keychain
/// and the real database file. So ``InboxModel/RailState`` is a pure value for
/// ``InboxRailSelection``'s reason — the model only reads it and assigns it — and both halves run
/// here: the initialiser writing a rail down, and the typed readings
/// (``InboxModel/RailState/view``, ``InboxModel/RailState/riskFacet``,
/// ``InboxModel/RailState/laneFacet``) that `InboxModel.restore(_:)` assigns from.
@MainActor
final class InboxRailStateTests: XCTestCase {
    private let repo = RepoRef(owner: "n2o", name: "wahlen")

    // MARK: - Helpers

    /// A rail, written down and read back the way scene storage does it.
    /// - Parameter state: The rail to store.
    /// - Returns: The same rail, after a trip through JSON.
    private func stored(_ state: InboxModel.RailState) throws -> InboxModel.RailState {
        let json = try JSONEncoder().encode(state)
        return try JSONDecoder().decode(InboxModel.RailState.self, from: json)
    }

    // MARK: - The facets the link grammar cannot compose

    /// A repository facet beside a smart view that is not "Involved".
    ///
    /// The rail the live test lost on the way back from the review screen, and the one no
    /// `filter=` token can express: `filter=repo:n2o/wahlen` widens the smart view to "Involved"
    /// (``InboxRailSelection``), so a token would have brought back a different inbox.
    func testARepositoryFacetSurvivesBesideTheSmartViewThatNarrowsIt() throws {
        let state = try stored(
            InboxModel.RailState(
                smartView: .needsMyReview,
                provenanceFilter: nil,
                repoFilter: repo,
                riskFilter: nil,
                laneFilter: nil,
                selectedID: "PR_1"
            )
        )
        XCTAssertEqual(state.view, .needsMyReview)
        XCTAssertEqual(state.repo, repo)
        XCTAssertNil(state.provenance)
        XCTAssertEqual(state.selectedID, "PR_1")
    }

    /// Every facet at once, which is the whole reason they are fields.
    func testASmartViewAnAgentBothNarrowingsAndTheCursorAllSurviveTogether() throws {
        let state = try stored(
            InboxModel.RailState(
                smartView: .myPullRequests,
                provenanceFilter: .agent(id: "claude-code"),
                repoFilter: repo,
                riskFilter: .high,
                laneFilter: .shortLook,
                selectedID: "PR_7"
            )
        )
        XCTAssertEqual(state.view, .myPullRequests)
        XCTAssertEqual(state.provenance, .agent(id: "claude-code"))
        XCTAssertEqual(state.repo, repo)
        XCTAssertEqual(state.riskFacet, .high)
        XCTAssertEqual(state.laneFacet, .shortLook)
        XCTAssertEqual(state.selectedID, "PR_7")
    }

    // MARK: - One facet at a time

    /// Every smart view, on its own.
    func testEverySmartViewSurvives() throws {
        for view in SmartView.allCases {
            let state = try stored(
                InboxModel.RailState(
                    smartView: view,
                    provenanceFilter: nil,
                    repoFilter: nil,
                    riskFilter: nil,
                    laneFilter: nil,
                    selectedID: nil
                )
            )
            XCTAssertEqual(state.view, view)
            XCTAssertNil(state.provenance)
            XCTAssertNil(state.repo)
        }
    }

    /// Every provenance facet, including the one that carries an id.
    func testEveryProvenanceFacetSurvives() throws {
        for facet: ProvenanceFilter in [.humans, .bots, .agent(id: "claude-code")] {
            let state = try stored(
                InboxModel.RailState(
                    smartView: .involved,
                    provenanceFilter: facet,
                    repoFilter: nil,
                    riskFilter: nil,
                    laneFilter: nil,
                    selectedID: nil
                )
            )
            XCTAssertEqual(state.provenance, facet)
            XCTAssertEqual(state.view, .involved)
        }
    }

    /// Risk (ADR 0023) and lane (ADR 0027), which travel as raw values.
    func testRiskAndLaneSurviveAsRawValues() throws {
        let state = InboxModel.RailState(
            smartView: .involved,
            provenanceFilter: nil,
            repoFilter: nil,
            riskFilter: .high,
            laneFilter: .shortLook,
            selectedID: nil
        )
        XCTAssertEqual(state.risk, "high")
        XCTAssertEqual(state.lane, "shortLook")
        XCTAssertEqual(try stored(state).riskFacet, .high)
        XCTAssertEqual(try stored(state).laneFacet, .shortLook)
    }

    // MARK: - Rails this build cannot read all of

    /// A whole `RailState`, encoded and decoded, is the same rail.
    func testTheStateSurvivesJSON() throws {
        let state = InboxModel.RailState(
            smartView: .approvedByMe,
            provenanceFilter: .bots,
            repoFilter: repo,
            riskFilter: .medium,
            laneFilter: .fullReview,
            selectedID: "PR_9"
        )
        XCTAssertEqual(try stored(state), state)
    }

    /// A raw value this build does not know is "not set", not a failure.
    ///
    /// The smart view is the one that cannot be nothing, so it falls back to the rail's default;
    /// the two facets simply come back unset. What this rules out is a rail written by another
    /// build throwing away the parts this one *can* read.
    func testARawValueThisBuildDoesNotKnowFallsBackWithoutLosingTheRest() throws {
        let json = Data(
            """
            {"smartView":"needsEverything","risk":"catastrophic","lane":"noLook","selectedID":"PR_3"}
            """.utf8
        )
        let state = try JSONDecoder().decode(InboxModel.RailState.self, from: json)
        XCTAssertEqual(state.view, .needsMyReview)
        XCTAssertNil(state.riskFacet)
        XCTAssertNil(state.laneFacet)
        XCTAssertEqual(state.selectedID, "PR_3")
    }

    /// The one thing the screen swallows: a string that is not a rail at all.
    ///
    /// Asserted rather than assumed, because the screen's empty `catch` is only defensible if the
    /// failure it drops is exactly this one — a scene-storage string from an older build, which
    /// means "no restore" and nothing else.
    func testAStringThatIsNotARailFailsToDecode() {
        let data = Data("not a rail".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(InboxModel.RailState.self, from: data))
    }
}
