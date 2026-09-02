import Foundation
import XCTest
@testable import ShepherdCore

/// The pure half of ⌘K semantic search (ADR 0019): document composition, the lexical ranker, the
/// blend with an embedding, and the vector value type.
///
/// Runs on the Linux runner, which is the point of the split: no embedding model exists there, so
/// every "with embeddings" case here uses vectors a test wrote by hand.
final class SearchDocumentTests: XCTestCase {
    private func source(
        id: String = "PR_1",
        number: Int = 128,
        title: String = "Fix the flaky login test",
        labels: [String] = ["bug"],
        headRefName: String = "claude/fix-login-test",
        author: ShepherdCore.Actor = Fixtures.makeActor("octocat"),
        body: String = "",
        files: [ChangedFile] = [],
        detailFetchedAt: Date? = nil
    ) -> SearchIndexSource {
        SearchIndexSource(
            summary: Fixtures.summary(
                id: id,
                number: number,
                title: title,
                author: author,
                headRefName: headRefName,
                labels: labels
            ),
            bodyMarkdown: body,
            files: files,
            detailFetchedAt: detailFetchedAt
        )
    }

    func testTheDocumentIndexesEveryFieldTheInboxRowCarries() {
        let document = SearchDocument.make(source: source())
        XCTAssertEqual(document.prID, "PR_1")
        XCTAssertEqual(document.slug, "schnaq/review#128")
        // Title, identity, labels, author and branch all come from the row, so a pull request
        // nobody has opened is still searchable — that is the ADR's promise for the common case.
        XCTAssertNotNil(document.terms["flaky"])
        XCTAssertNotNil(document.terms["review"])
        XCTAssertNotNil(document.terms["bug"])
        XCTAssertNotNil(document.terms["octocat"])
        XCTAssertNotNil(document.terms["login"])
        XCTAssertNotNil(document.terms["128"])
        XCTAssertFalse(document.hasDetail)
    }

    func testTitleTermsWeighHeavierThanDiffTerms() {
        let document = SearchDocument.make(
            source: source(
                title: "Widget",
                labels: [],
                headRefName: "main",
                files: [Fixtures.file("a.swift", patch: "@@ -1 +1 @@\n+let gadget = 1\n")],
                detailFetchedAt: Date()
            )
        )
        let title = document.terms["widget"] ?? 0
        let added = document.terms["gadget"] ?? 0
        XCTAssertGreaterThan(title, added)
    }

    func testOnlyAddedLinesAreIndexed() {
        let patch = """
            @@ -1,4 +1,4 @@
             context untouched
            -removedIdentifier()
            +addedIdentifier()
            +++ not/a/line
            +}
            """
        let lines = SearchDocument.addedLines(inPatch: patch)
        XCTAssertEqual(lines, ["addedIdentifier()"])
    }

    func testTheDocumentIsCappedToItsByteBudget() {
        let hugePatch = "@@ -1 +1 @@\n" + String(
            repeating: "+someVeryLongAddedLineOfCode(withArguments: true)\n",
            count: 2_000
        )
        let budget = SearchDocumentBudget(
            bodyBytes: 20,
            filePathBytes: 20,
            addedLineBytes: 100,
            maximumAddedLineLength: 30
        )
        let document = SearchDocument.make(
            source: source(
                body: String(repeating: "b", count: 5_000),
                files: [
                    Fixtures.file("some/very/long/path/one.swift", patch: hugePatch),
                    Fixtures.file("some/very/long/path/two.swift", patch: hugePatch),
                ],
                detailFetchedAt: Date()
            ),
            budget: budget
        )
        XCTAssertEqual(document.bodyExcerpt.utf8.count, 20)
        XCTAssertLessThanOrEqual(document.filePaths.joined().utf8.count, 20)
        XCTAssertLessThanOrEqual(document.addedLines.joined().utf8.count, 100)
        for line in document.addedLines {
            XCTAssertLessThanOrEqual(line.count, 30)
        }
    }

    func testTheDocumentHashIsStableAcrossProcessesAndChangesWithTheContent() {
        let first = SearchDocument.make(source: source())
        let again = SearchDocument.make(source: source())
        // The re-embed gate: two runs over the same source must agree, which is what `Hasher`
        // (seeded per process) could not promise.
        XCTAssertEqual(first.documentHash, again.documentHash)
        let changed = SearchDocument.make(source: source(title: "Fix the flaky logout test"))
        XCTAssertNotEqual(first.documentHash, changed.documentHash)
    }

    func testTheFingerprintChangesWhenADetailFetchStoresADiff() {
        let before = SearchDocument.make(source: source())
        let after = SearchDocument.make(
            source: source(
                body: "Retries the login flow twice.",
                files: [Fixtures.file("Tests/LoginTests.swift")],
                detailFetchedAt: Date(timeIntervalSince1970: 1)
            )
        )
        XCTAssertNotEqual(before.sourceFingerprint, after.sourceFingerprint)
        XCTAssertNotEqual(before.documentHash, after.documentHash)
        XCTAssertTrue(after.hasDetail)
    }

    func testTheFingerprintIgnoresWhatCannotChangeTheDocument() {
        // A check run finishing changes an inbox row on every sweep and cannot change a word of
        // the document. If it moved the fingerprint, every sweep would read every stored diff
        // back out of SQLite to discover that nothing had changed.
        let green = SearchIndexSource(
            summary: Fixtures.summary(id: "PR_1", checkRollup: CheckRollup(state: .success, total: 3))
        )
        let red = SearchIndexSource(
            summary: Fixtures.summary(id: "PR_1", checkRollup: CheckRollup(state: .failure, total: 3))
        )
        XCTAssertEqual(
            SearchDocument.make(source: green).sourceFingerprint,
            SearchDocument.make(source: red).sourceFingerprint
        )
    }

    func testTokenisationSplitsIdentifiersAndPathsButNotCamelCase() {
        XCTAssertEqual(
            SearchText.tokens(in: "Sources/Auth/TokenStore.swift"),
            ["sources", "auth", "tokenstore", "swift"]
        )
        XCTAssertEqual(SearchText.tokens(in: "AUTH_token-2"), ["auth", "token", "2"])
        // Single letters are noise; single digits are not.
        XCTAssertEqual(SearchText.tokens(in: "a 7 to"), ["7", "to"])
    }
}

final class SearchQueryTests: XCTestCase {
    func testAFullSlugIsRecognisedAsAReference() {
        let query = SearchQuery(text: "schnaq/review#128")
        XCTAssertEqual(
            query.reference,
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 128)
        )
        XCTAssertTrue(query.looksLikeProse)
    }

    func testABareHashNumberIsRecognisedAsAReference() {
        XCTAssertEqual(SearchQuery(text: "#42").reference, .number(42))
        XCTAssertEqual(SearchQuery(text: "  #42 ").reference, .number(42))
    }

    func testAPlainNumberIsNotAReference() {
        // `2026` is a search word far more often than it is a pull-request number.
        XCTAssertNil(SearchQuery(text: "2026").reference)
        XCTAssertNil(SearchQuery(text: "#notanumber").reference)
        XCTAssertNil(SearchQuery(text: "a/b/c#1").reference)
    }

    func testOneWordIsACommandAndTwoWordsAreASearch() {
        XCTAssertFalse(SearchQuery(text: "sync").looksLikeProse)
        XCTAssertTrue(SearchQuery(text: "flaky login").looksLikeProse)
        XCTAssertTrue(SearchQuery(text: "#7").looksLikeProse)
    }

    func testAnEmptyQueryIsEmpty() {
        XCTAssertTrue(SearchQuery(text: "   ").isEmpty)
        XCTAssertTrue(SearchQuery(text: "").isEmpty)
    }
}

final class SearchRankerTests: XCTestCase {
    private func document(
        id: String,
        number: Int,
        title: String,
        labels: [String] = [],
        branch: String = "main",
        author: ShepherdCore.Actor = Fixtures.makeActor("octocat"),
        body: String = "",
        paths: [String] = [],
        added: [String] = []
    ) -> SearchDocument {
        // Built outside the initialiser call: a ternary producing an optional `String` inside an
        // argument list is the kind of expression the type-checker is slowest at.
        var patch: String?
        if !added.isEmpty {
            patch = "@@ -1 +1 @@\n" + added.map { "+\($0)" }.joined(separator: "\n")
        }
        var files: [ChangedFile] = []
        for (index, path) in paths.enumerated() {
            files.append(Fixtures.file(path, patch: index == 0 ? patch : nil))
        }
        let summary = Fixtures.summary(
            id: id,
            number: number,
            title: title,
            author: author,
            headRefName: branch,
            labels: labels
        )
        return SearchDocument.make(
            source: SearchIndexSource(
                summary: summary,
                bodyMarkdown: body,
                files: files,
                detailFetchedAt: paths.isEmpty ? nil : Date(timeIntervalSince1970: 1)
            )
        )
    }

    private var corpus: [SearchDocument] {
        [
            document(
                id: "PR_1",
                number: 128,
                title: "Fix the flaky login test",
                labels: ["bug"],
                branch: "claude/fix-login",
                paths: ["Tests/LoginTests.swift"],
                added: ["retryUntilStable(attempts: 3)"]
            ),
            document(
                id: "PR_2",
                number: 129,
                title: "Bump the GRDB dependency",
                labels: ["dependencies", "automerge"],
                branch: "bump/grdb-7-11",
                author: Fixtures.makeActor(
                    "dependabot[bot]",
                    kind: Fixtures.agent("dependabot", "Dependabot")
                ),
                paths: ["Package.swift"]
            ),
            document(
                id: "PR_3",
                number: 130,
                title: "Add a settings tab for the appearance",
                body: "Moves the theme picker out of the sidebar.",
                paths: ["Shepherd/Features/Settings/AppearanceTab.swift"]
            ),
        ]
    }

    func testALexicalQueryRanksTheMatchingPullRequestFirst() {
        let results = SearchRanker.rank(query: SearchQuery(text: "flaky login"), documents: corpus)
        XCTAssertEqual(results.first?.prID, "PR_1")
        XCTAssertNil(results.first?.similarity)
    }

    func testAQueryThatMatchesNothingReturnsNothing() {
        let results = SearchRanker.rank(
            query: SearchQuery(text: "kubernetes helm chart"),
            documents: corpus
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testAnExactSlugAlwaysWinsHoweverBadlyItScores() {
        // The query's words describe PR_1; the reference names PR_3. The reference wins.
        let results = SearchRanker.rank(
            query: SearchQuery(text: "schnaq/review#130"),
            documents: corpus
        )
        XCTAssertEqual(results.first?.prID, "PR_3")
        XCTAssertTrue(results.first?.isExactReference == true)
        XCTAssertEqual(results.first?.reason, .exactReference)
    }

    func testABareHashNumberWinsToo() {
        let results = SearchRanker.rank(query: SearchQuery(text: "#129"), documents: corpus)
        XCTAssertEqual(results.first?.prID, "PR_2")
        XCTAssertTrue(results.first?.isExactReference == true)
    }

    func testAnExactReferenceWinsEvenAgainstAStrongEmbeddingMatch() {
        let vectors = SearchVectors(
            query: SearchVector([1, 0]),
            documents: [
                "PR_1": SearchVector([1, 0]),
                "PR_2": SearchVector([1, 0]),
                "PR_3": SearchVector([0, 1]),
            ]
        )
        let results = SearchRanker.rank(
            query: SearchQuery(text: "#130"),
            documents: corpus,
            vectors: vectors
        )
        XCTAssertEqual(results.first?.prID, "PR_3")
    }

    func testTheEmbeddingCanSurfaceAPullRequestWithNoLiteralMatch() {
        // "dependency upgrade" shares no token with "Bump the GRDB dependency"… except
        // `dependency`/`dependencies`, so the query below avoids even that.
        let query = SearchQuery(text: "newer library version")
        XCTAssertTrue(
            SearchRanker.rank(query: query, documents: corpus).isEmpty,
            "the lexical half must not match, or the test proves nothing"
        )
        let vectors = SearchVectors(
            query: SearchVector([1, 0, 0]),
            documents: [
                "PR_1": SearchVector([0, 1, 0]),
                "PR_2": SearchVector([0.9, 0.1, 0]),
                "PR_3": SearchVector([0, 0, 1]),
            ]
        )
        let results = SearchRanker.rank(query: query, documents: corpus, vectors: vectors)
        XCTAssertEqual(results.map(\.prID), ["PR_2"])
        XCTAssertEqual(results.first?.reason, .semantic)
    }

    func testAWeakSimilarityIsNotAResult() {
        // Every document has a cosine with every query; without the floor the palette would
        // answer every query with the six least-unrelated pull requests in the inbox.
        let vectors = SearchVectors(
            query: SearchVector([1, 0]),
            documents: [
                "PR_1": SearchVector([0.2, 0.98]),
                "PR_2": SearchVector([0.1, 0.99]),
                "PR_3": SearchVector([0, 1]),
            ]
        )
        let results = SearchRanker.rank(
            query: SearchQuery(text: "kubernetes helm chart"),
            documents: corpus,
            vectors: vectors
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testADocumentWithoutAVectorStillRanksOnItsWords() {
        // The state during a first index pass, and the permanent state on a Mac with no
        // embedding model: some rows have vectors, some do not, and a literal match still wins.
        let vectors = SearchVectors(
            query: SearchVector([1, 0]),
            documents: ["PR_3": SearchVector([1, 0])]
        )
        let results = SearchRanker.rank(
            query: SearchQuery(text: "flaky login"),
            documents: corpus,
            vectors: vectors
        )
        XCTAssertTrue(results.contains { $0.prID == "PR_1" })
        XCTAssertNil(results.first { $0.prID == "PR_1" }?.similarity)
    }

    func testTheBlendIsHalfLexicalAndHalfSemantic() throws {
        let vectors = SearchVectors(
            query: SearchVector([1, 0]),
            documents: ["PR_1": SearchVector([1, 0])]
        )
        let results = SearchRanker.rank(
            query: SearchQuery(text: "flaky login"),
            documents: corpus,
            vectors: vectors
        )
        let best = try XCTUnwrap(results.first)
        XCTAssertEqual(best.prID, "PR_1")
        // Top of the lexical ranking (1.0, normalised) and a perfect cosine (1.0).
        XCTAssertEqual(best.score, 1, accuracy: 0.0001)
        XCTAssertEqual(best.lexicalScore, 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(best.similarity), 1, accuracy: 0.0001)
    }

    func testTheOrderIsTotalSoTheListCannotReshuffle() {
        // Two documents that score identically must always come back in the same order.
        let identical = [
            document(id: "PR_b", number: 2, title: "Same words here"),
            document(id: "PR_a", number: 3, title: "Same words here"),
        ]
        let query = SearchQuery(text: "same words")
        let first = SearchRanker.rank(query: query, documents: identical).map(\.prID)
        let second = SearchRanker.rank(query: query, documents: identical.reversed()).map(\.prID)
        XCTAssertEqual(first, ["PR_a", "PR_b"])
        XCTAssertEqual(first, second)
    }

    func testTheLimitIsRespected() {
        let results = SearchRanker.rank(
            query: SearchQuery(text: "the"),
            documents: corpus,
            vectors: nil,
            options: SearchRankingOptions(limit: 1)
        )
        XCTAssertEqual(results.count, 1)
    }

    func testAnEmptyQueryRanksNothing() {
        XCTAssertTrue(SearchRanker.rank(query: SearchQuery(text: " "), documents: corpus).isEmpty)
    }

    // MARK: - Why it matched

    func testTheReasonNamesTheLabelRatherThanTheTitle() {
        let results = SearchRanker.rank(query: SearchQuery(text: "automerge"), documents: corpus)
        XCTAssertEqual(results.first?.reason, .label("automerge"))
    }

    func testTheReasonNamesTheMatchedFilePath() {
        let results = SearchRanker.rank(query: SearchQuery(text: "package"), documents: corpus)
        XCTAssertEqual(results.first?.reason, .filePath("Package.swift"))
    }

    func testTheReasonNamesTheMatchedDiffLine() {
        let results = SearchRanker.rank(query: SearchQuery(text: "retryuntilstable"), documents: corpus)
        XCTAssertEqual(results.first?.reason, .addedLine("retryUntilStable(attempts: 3)"))
    }

    func testTheReasonNamesTheAgentThatWroteIt() {
        // The detected agent's display name, not the `[bot]` login: provenance is the name the
        // rest of the app shows for that author (ADR 0008).
        let results = SearchRanker.rank(query: SearchQuery(text: "dependabot"), documents: corpus)
        XCTAssertEqual(results.first?.prID, "PR_2")
        XCTAssertEqual(results.first?.reason, .author("Dependabot"))
    }

    func testTheReasonIsTheDescriptionWhenThatIsAllThereIs() {
        let results = SearchRanker.rank(query: SearchQuery(text: "sidebar"), documents: corpus)
        XCTAssertEqual(results.first?.prID, "PR_3")
        XCTAssertEqual(results.first?.reason, .body)
    }
}

final class SearchVectorTests: XCTestCase {
    func testTheBlobRoundTrips() throws {
        let vector = SearchVector([0.5, -0.25, 1, 0])
        let data = vector.data
        XCTAssertEqual(data.count, 16)
        let restored = try XCTUnwrap(SearchVector(data: data))
        XCTAssertEqual(restored, vector)
    }

    func testAnUnalignedOrTruncatedBlobDecodesToNothing() {
        XCTAssertNil(SearchVector(data: Data()))
        XCTAssertNil(SearchVector(data: Data([1, 2, 3])))
    }

    func testTheBlobIsReadBackFromAnArbitrarilyAlignedBuffer() throws {
        // The stored blob comes out of SQLite with no alignment promise, so the decoder copies
        // rather than binding in place. Slicing off one byte is the cheapest way to produce a
        // `Data` whose backing bytes are misaligned for `Float`.
        let vector = SearchVector([1, 2, 3, 4])
        var padded = Data([0])
        padded.append(vector.data)
        let sliced = padded.dropFirst()
        let restored = try XCTUnwrap(SearchVector(data: Data(sliced)))
        XCTAssertEqual(restored, vector)
    }

    func testCosineSimilarity() throws {
        let unit = SearchVector([1, 0])
        XCTAssertEqual(try XCTUnwrap(unit.cosineSimilarity(to: unit)), 1, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(unit.cosineSimilarity(to: SearchVector([0, 1]))),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(unit.cosineSimilarity(to: SearchVector([-1, 0]))),
            -1,
            accuracy: 0.0001
        )
    }

    func testIncomparableVectorsHaveNoSimilarity() {
        XCTAssertNil(SearchVector([1, 0]).cosineSimilarity(to: SearchVector([1, 0, 0])))
        XCTAssertNil(SearchVector([0, 0]).cosineSimilarity(to: SearchVector([1, 0])))
        XCTAssertNil(SearchVector([]).cosineSimilarity(to: SearchVector([])))
    }

    func testMeanPoolingProducesAUnitVectorBetweenItsChunks() throws {
        let pooled = try XCTUnwrap(
            SearchVector.meanPooled([SearchVector([1, 0]), SearchVector([0, 1])])
        )
        XCTAssertEqual(Double(pooled.values[0]), 0.7071, accuracy: 0.001)
        XCTAssertEqual(Double(pooled.values[1]), 0.7071, accuracy: 0.001)
        XCTAssertNil(SearchVector.meanPooled([]))
        XCTAssertNil(SearchVector.meanPooled([SearchVector([])]))
    }

    func testMismatchedChunksAreDroppedRatherThanCorruptingThePool() throws {
        let pooled = try XCTUnwrap(
            SearchVector.meanPooled([
                SearchVector([1, 0]),
                SearchVector([1, 0, 0]),
            ])
        )
        XCTAssertEqual(pooled.dimensions, 2)
    }

    func testAnEntryIsOnlyReusableForTheSameTextAndTheSameModel() {
        let document = SearchDocument.make(
            source: SearchIndexSource(summary: Fixtures.summary(id: "PR_1"))
        )
        let entry = SearchIndexEntry(
            prID: "PR_1",
            documentHash: document.documentHash,
            modelIdentifier: "model-a",
            vector: SearchVector([1, 0]),
            indexedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(entry.isUsable(for: document, modelIdentifier: "model-a"))
        XCTAssertFalse(entry.isUsable(for: document, modelIdentifier: "model-b"))

        var withoutVector = entry
        withoutVector.vector = nil
        XCTAssertFalse(withoutVector.isUsable(for: document, modelIdentifier: "model-a"))

        var staleHash = entry
        staleHash.documentHash = "something else"
        XCTAssertFalse(staleHash.isUsable(for: document, modelIdentifier: "model-a"))
    }
}
