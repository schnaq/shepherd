import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The rail the inbox comes back to after a trip to the review screen (ADR 0013).
///
/// `InboxScreen` is rebuilt whenever the route changes, so the rail has to be *said* somewhere the
/// rebuild cannot reach — a `@SceneStorage` string — and ``InboxModel/RailState`` is that sentence.
/// What is asserted here is the sentence and nothing else: the token it stores, the two facets and
/// the cursor the link grammar has no words for, and the two combinations it deliberately refuses
/// to say.
///
/// Nothing here builds an `InboxModel`. It cannot: the model takes a `SignedInSession`, whose
/// initialiser is private and whose `make(account:tokenStore:sweepInterval:)` wants the Keychain
/// and the real database file. So ``InboxModel/RailState`` is a pure value for
/// ``InboxRailSelection``'s reason — the model only reads and assigns it — and both halves of the
/// round trip are exercised here: this type going out, and `InboxRailSelection` (which
/// `InboxModel.restore(_:)` reaches through `apply(_:)`) coming back.
@MainActor
final class InboxRailStateTests: XCTestCase {
    private let repo = RepoRef(owner: "n2o", name: "wahlen")

    // MARK: - The token

    /// The repository facet: the rail the live test lost on the way back from the review screen.
    func testTheRepositoryFacetRoundTripsThroughTheToken() throws {
        let state = InboxModel.RailState(
            smartView: .involved,
            provenanceFilter: nil,
            repoFilter: repo,
            riskFilter: nil,
            laneFilter: nil,
            selectedID: "PR_1"
        )
        XCTAssertEqual(state.filterToken, "repo:n2o/wahlen")

        let back = InboxRailSelection(try XCTUnwrap(state.filter))
        XCTAssertEqual(back.smartView, .involved)
        XCTAssertEqual(back.repoFilter, repo)
        XCTAssertNil(back.provenanceFilter)
        XCTAssertEqual(back.contentKind, .pullRequests)
        XCTAssertEqual(state.selectedID, "PR_1")
    }

    /// Every smart view on its own, because the grammar has a token for each of the four.
    func testEverySmartViewRoundTripsOnItsOwn() throws {
        for view in SmartView.allCases {
            let state = InboxModel.RailState(
                smartView: view,
                provenanceFilter: nil,
                repoFilter: nil,
                riskFilter: nil,
                laneFilter: nil,
                selectedID: nil
            )
            let back = InboxRailSelection(try XCTUnwrap(state.filter, "no token for \(view)"))
            XCTAssertEqual(back.smartView, view)
            XCTAssertNil(back.provenanceFilter)
            XCTAssertNil(back.repoFilter)
        }
    }

    /// The provenance facets, including the one that carries an id.
    func testTheProvenanceFacetsRoundTrip() throws {
        let facets: [ProvenanceFilter] = [.humans, .bots, .agent(id: "claude-code")]
        for facet in facets {
            let state = InboxModel.RailState(
                smartView: .involved,
                provenanceFilter: facet,
                repoFilter: nil,
                riskFilter: nil,
                laneFilter: nil,
                selectedID: nil
            )
            let back = InboxRailSelection(try XCTUnwrap(state.filter, "no token for \(facet)"))
            XCTAssertEqual(back.provenanceFilter, facet)
            // A facet token widens the smart view to "Involved" (``InboxRailSelection``), which is
            // why the rails above are stated with `.involved` and why the two below store nothing.
            XCTAssertEqual(back.smartView, .involved)
        }
    }

    /// The combinations `shepherd://inbox?filter=…` cannot say are stored as no token at all.
    ///
    /// Restoring the nearest expressible rail would put the user somewhere they never were — a
    /// facet token would move the smart view to "Involved", and a view token would drop the facet.
    /// Storing nothing loses the rail; storing the wrong one lies about it.
    func testARailTheGrammarCannotSayStoresNoToken() {
        let narrowedView = InboxModel.RailState(
            smartView: .needsMyReview,
            provenanceFilter: nil,
            repoFilter: repo,
            riskFilter: nil,
            laneFilter: nil,
            selectedID: nil
        )
        XCTAssertNil(narrowedView.filterToken)

        let twoFacets = InboxModel.RailState(
            smartView: .involved,
            provenanceFilter: .bots,
            repoFilter: repo,
            riskFilter: nil,
            laneFilter: nil,
            selectedID: nil
        )
        XCTAssertNil(twoFacets.filterToken)
    }

    // MARK: - What the grammar has no words for

    /// Risk (ADR 0023), lane (ADR 0027) and the cursor: carried beside the token, not in it.
    func testTheFacetsWithoutATokenAndTheCursorAreCarried() {
        let state = InboxModel.RailState(
            smartView: .involved,
            provenanceFilter: nil,
            repoFilter: nil,
            riskFilter: .high,
            laneFilter: .shortLook,
            selectedID: "PR_1"
        )
        XCTAssertEqual(state.risk, "high")
        XCTAssertEqual(state.lane, "shortLook")
        XCTAssertEqual(state.selectedID, "PR_1")
        XCTAssertEqual(state.risk.flatMap(TriageVerdict.Risk.init(rawValue:)), .high)
        XCTAssertEqual(state.lane.flatMap(TrustLane.init(rawValue:)), .shortLook)
    }

    // MARK: - The scene-storage string

    /// What `@SceneStorage` actually holds: JSON, and the same rail after a decode.
    func testTheStateSurvivesJSON() throws {
        let state = InboxModel.RailState(
            smartView: .involved,
            provenanceFilter: .agent(id: "claude-code"),
            repoFilter: nil,
            riskFilter: .medium,
            laneFilter: .fullReview,
            selectedID: "PR_7"
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(InboxModel.RailState.self, from: data), state)
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
