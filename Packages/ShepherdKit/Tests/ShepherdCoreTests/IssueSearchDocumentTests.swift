import Foundation
import XCTest
@testable import ShepherdCore

/// Fixtures for the issues half of ⌘K search (ADR 0032).
enum IssueSearchFixtures {
    static let repo = RepoRef(owner: "schnaq", name: "review")

    static func summary(
        id: String,
        number: Int = 42,
        repo: RepoRef = IssueSearchFixtures.repo,
        title: String = "Login times out after the token refresh",
        labels: [String] = ["bug"],
        state: IssueSummary.State = .open,
        updatedAt: TimeInterval = 0
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: Date(timeIntervalSince1970: 1_788_162_000 - 3_600),
            updatedAt: Date(timeIntervalSince1970: 1_788_162_000 + updatedAt),
            state: state,
            labels: labels,
            myRelation: [.assigned],
            commentCount: 2
        )
    }

    static func source(
        id: String = "I_1",
        number: Int = 42,
        title: String = "Login times out after the token refresh",
        labels: [String] = ["bug"],
        body: String = "",
        detailFetchedAt: Date? = nil
    ) -> IssueSearchIndexSource {
        IssueSearchIndexSource(
            summary: summary(id: id, number: number, title: title, labels: labels),
            bodyMarkdown: body,
            detailFetchedAt: detailFetchedAt
        )
    }
}

/// The pure composition half: four fields, their weights, the caps and the two hashes.
final class IssueSearchDocumentTests: XCTestCase {
    func testTheDocumentIndexesTheFourFieldsAndNothingElse() {
        let document = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(body: "The refresh window is an hour long.")
        )
        XCTAssertEqual(document.issueID, "I_1")
        XCTAssertEqual(document.slug, "schnaq/review#42")
        XCTAssertNotNil(document.terms["login"], "the title")
        XCTAssertNotNil(document.terms["review"], "the identity")
        XCTAssertNotNil(document.terms["42"], "the number")
        XCTAssertNotNil(document.terms["bug"], "the labels")
        XCTAssertNotNil(document.terms["window"], "the body")
        // No author field: an issue's author is almost always a person on the team, and the rail
        // answers "whose issues" with a facet.
        XCTAssertNil(document.terms["octocat"])
        XCTAssertEqual(IssueSearchDocument.Field.allCases.count, 4)
    }

    func testTheWeightsAreTheOnesTheADRStates() {
        XCTAssertEqual(IssueSearchDocument.Field.title.weight, 3)
        XCTAssertEqual(IssueSearchDocument.Field.identity.weight, 3)
        XCTAssertEqual(IssueSearchDocument.Field.labels.weight, 2.5)
        XCTAssertEqual(IssueSearchDocument.Field.body.weight, 1)
    }

    func testTitleTermsWeighHeavierThanBodyTerms() {
        let document = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(
                title: "Widget",
                labels: [],
                body: "gadget"
            )
        )
        let title = document.terms["widget"] ?? 0
        let body = document.terms["gadget"] ?? 0
        XCTAssertGreaterThan(title, body)
    }

    func testAnIssueNobodyHasOpenedIsStillSearchable() {
        let document = IssueSearchDocument.make(source: IssueSearchFixtures.source())
        XCTAssertFalse(document.hasDetail)
        XCTAssertEqual(document.bodyExcerpt, "")
        XCTAssertNotNil(document.terms["login"])
    }

    func testTheBodyIsCappedToItsByteBudget() {
        let huge = String(repeating: "reproduction steps ", count: 2_000)
        let document = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(body: huge, detailFetchedAt: Date()),
            budget: IssueSearchDocumentBudget(bodyBytes: 40)
        )
        XCTAssertLessThanOrEqual(document.bodyExcerpt.utf8.count, 40)
        XCTAssertTrue(document.hasDetail)
    }

    func testTheDocumentHashIsStableAcrossProcessesAndChangesWithTheContent() {
        let first = IssueSearchDocument.make(source: IssueSearchFixtures.source())
        let again = IssueSearchDocument.make(source: IssueSearchFixtures.source())
        XCTAssertEqual(first.documentHash, again.documentHash)
        XCTAssertFalse(first.documentHash.isEmpty)

        let different = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(title: "Something else entirely")
        )
        XCTAssertNotEqual(first.documentHash, different.documentHash)
    }

    func testTheFingerprintChangesWhenADetailFetchStoresABody() {
        let before = IssueSearchDocument.make(source: IssueSearchFixtures.source())
        let after = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(
                body: "Steps to reproduce.",
                detailFetchedAt: Date(timeIntervalSince1970: 1_788_162_500)
            )
        )
        XCTAssertNotEqual(before.sourceFingerprint, after.sourceFingerprint)
    }

    func testTheFingerprintNoticesAnIssueClosing() {
        // Closing an issue is the one change that does not have to move `updatedAt`.
        let open = IssueSearchIndexSource(summary: IssueSearchFixtures.summary(id: "I_1"))
        let closed = IssueSearchIndexSource(
            summary: IssueSearchFixtures.summary(id: "I_1", state: .closed)
        )
        XCTAssertNotEqual(
            IssueSearchDocument.fingerprint(for: open),
            IssueSearchDocument.fingerprint(for: closed)
        )
    }

    func testAnIndexEntryIsOnlyReusableForTheSameTextAndTheSameModel() {
        let document = IssueSearchDocument.make(source: IssueSearchFixtures.source())
        let entry = IssueSearchIndexEntry(
            issueID: "I_1",
            documentHash: document.documentHash,
            modelIdentifier: "embedder-a",
            vector: SearchVector([1, 0]),
            indexedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(entry.isUsable(for: document, modelIdentifier: "embedder-a"))
        XCTAssertFalse(entry.isUsable(for: document, modelIdentifier: "embedder-b"))

        let other = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(title: "Another issue")
        )
        XCTAssertFalse(entry.isUsable(for: other, modelIdentifier: "embedder-a"))

        var withoutVector = entry
        withoutVector.vector = nil
        XCTAssertFalse(withoutVector.isUsable(for: document, modelIdentifier: "embedder-a"))
    }

    func testTheEmbeddingTextHasAFixedFieldOrder() {
        let document = IssueSearchDocument.make(
            source: IssueSearchFixtures.source(body: "The refresh window is an hour long.")
        )
        XCTAssertEqual(
            document.embeddingText,
            """
            Login times out after the token refresh
            Repository: schnaq/review #42
            Labels: bug
            The refresh window is an hour long.
            """
        )
    }
}

/// The pure ranking half: BM25 without embeddings, the blend with one, the exact-reference
/// override and the similarity floor.
final class IssueSearchRankerTests: XCTestCase {
    private func document(
        id: String,
        number: Int,
        title: String,
        labels: [String] = [],
        body: String = ""
    ) -> IssueSearchDocument {
        IssueSearchDocument.make(
            source: IssueSearchIndexSource(
                summary: IssueSearchFixtures.summary(
                    id: id,
                    number: number,
                    title: title,
                    labels: labels
                ),
                bodyMarkdown: body,
                detailFetchedAt: body.isEmpty ? nil : Date(timeIntervalSince1970: 1)
            )
        )
    }

    private var corpus: [IssueSearchDocument] {
        [
            document(
                id: "I_1",
                number: 42,
                title: "Login times out after the token refresh",
                labels: ["bug", "auth"]
            ),
            document(
                id: "I_2",
                number: 43,
                title: "Sidebar loses its selection on relaunch",
                labels: ["regression"],
                body: "Happens after a restart, every time."
            ),
            document(
                id: "I_3",
                number: 51,
                title: "Add a keyboard shortcut for the focus session",
                labels: ["enhancement"]
            ),
        ]
    }

    func testALexicalQueryRanksTheMatchingIssueFirst() {
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "login token"),
            documents: corpus
        )
        XCTAssertEqual(results.first?.issueID, "I_1")
        XCTAssertNil(results.first?.similarity, "no vectors were given")
    }

    func testAQueryThatMatchesNothingReturnsNothing() {
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "kubernetes helm chart"),
            documents: corpus
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testAnExactSlugAlwaysWinsHoweverBadlyItScores() {
        // The query's words describe I_1; the reference names I_3. The reference wins.
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "schnaq/review#51"),
            documents: corpus
        )
        XCTAssertEqual(results.first?.issueID, "I_3")
        XCTAssertTrue(results.first?.isExactReference == true)
        XCTAssertEqual(results.first?.reason, .exactReference)
        XCTAssertEqual(results.first?.score, 1)
    }

    func testABareHashNumberWinsToo() {
        let results = IssueSearchRanker.rank(query: SearchQuery(text: "#43"), documents: corpus)
        XCTAssertEqual(results.first?.issueID, "I_2")
        XCTAssertTrue(results.first?.isExactReference == true)
    }

    func testAReferenceInAnotherRepositoryIsNotAMatch() {
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "schnaq/shepherd-web#42"),
            documents: corpus
        )
        XCTAssertTrue(results.allSatisfy { !$0.isExactReference })
    }

    func testTheEmbeddingCanSurfaceAnIssueWithNoLiteralMatch() {
        let vectors = IssueSearchVectors(
            query: SearchVector([1, 0]),
            documents: ["I_3": SearchVector([1, 0])]
        )
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "hotkey binding"),
            documents: corpus,
            vectors: vectors
        )
        XCTAssertEqual(results.map(\.issueID), ["I_3"])
        XCTAssertEqual(results.first?.reason, .semantic)
    }

    func testAWeakSimilarityIsNotAResult() {
        // Below the floor, and with no literal match, the honest answer is nothing at all.
        let vectors = IssueSearchVectors(
            query: SearchVector([1, 0]),
            documents: ["I_3": SearchVector([0.2, 1])]
        )
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "hotkey binding"),
            documents: corpus,
            vectors: vectors
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testADocumentWithoutAVectorStillRanksOnItsWords() {
        let vectors = IssueSearchVectors(
            query: SearchVector([1, 0]),
            documents: [:]
        )
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "login token"),
            documents: corpus,
            vectors: vectors
        )
        XCTAssertEqual(results.first?.issueID, "I_1")
        XCTAssertNil(results.first?.similarity)
    }

    func testTheOrderIsTotalSoTheListCannotReshuffle() {
        let first = IssueSearchRanker.rank(query: SearchQuery(text: "the"), documents: corpus)
        let again = IssueSearchRanker.rank(
            query: SearchQuery(text: "the"),
            documents: corpus.reversed()
        )
        XCTAssertEqual(first.map(\.issueID), again.map(\.issueID))
    }

    func testTheLimitIsRespected() {
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "the"),
            documents: corpus,
            options: SearchRankingOptions(limit: 1)
        )
        XCTAssertEqual(results.count, 1)
    }

    func testAnEmptyQueryRanksNothing() {
        XCTAssertTrue(
            IssueSearchRanker.rank(query: SearchQuery(text: "   "), documents: corpus).isEmpty
        )
        let empty = IssueSearchRanker.rank(query: SearchQuery(text: "bug"), documents: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testATriageOnlyQueryIsNotAnIssueListing() {
        // Where this parts company with its twin: a structured-triage verdict is a statement
        // about a pull request, so there is no issue the filter could have narrowed.
        let results = IssueSearchRanker.rank(
            query: SearchQuery(text: "risk:high"),
            documents: corpus
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testTheReasonNamesTheLabelRatherThanTheTitle() {
        let results = IssueSearchRanker.rank(query: SearchQuery(text: "auth"), documents: corpus)
        XCTAssertEqual(results.first?.reason, .label("auth"))
    }

    func testTheReasonIsTheBodyWhenThatIsAllThereIs() {
        let results = IssueSearchRanker.rank(query: SearchQuery(text: "restart"), documents: corpus)
        XCTAssertEqual(results.first?.issueID, "I_2")
        XCTAssertEqual(results.first?.reason, .body)
    }

    func testTheBM25ConstantsAreTheSameOnesTheOtherRankerUses() {
        // Duplicated arithmetic, one curve: a query must not be scored differently depending on
        // which section of the palette answers it.
        XCTAssertEqual(IssueSearchRanker.k1, SearchRanker.k1)
        XCTAssertEqual(IssueSearchRanker.b, SearchRanker.b)
    }
}
