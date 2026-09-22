import Foundation
import XCTest

@testable import ShepherdCore

/// The pure half of structured triage (ADR 0023): the tier-1 hints, the input the classifier is
/// shown, the ⌘K tokens, the rail's counts — and the rule that no rules engine may read a verdict.
///
/// All of it runs on the Linux runner, which is the point of the split: the classifier is Apple's
/// and lives in the app target, while everything that *decides* anything — what goes into the
/// prompt, what a token means, what the rail counts — is here.
final class StructuredTriageTests: XCTestCase {
    // MARK: - Tier-1 hints

    func testHintsNameTheRiskyFilesAndNotTheirCategory() {
        let hints = TriageRiskHints.hints(for: [
            Fixtures.file("Sources/Auth/TokenStore.swift"),
            Fixtures.file("Tests/LoginTests.swift", status: .removed),
            Fixtures.file("README.md"),
        ])

        XCTAssertTrue(
            hints.contains { $0.contains("Sources/Auth/TokenStore.swift") && $0.contains("auth") },
            "the security-sensitive path is the hint the model cannot work out for itself"
        )
        XCTAssertTrue(hints.contains { $0.contains("Deletes a test file") })
        XCTAssertFalse(
            hints.contains { $0.contains("README.md") },
            "a file whose only reason is its category says nothing about risk"
        )
    }

    func testHintsAreCappedAndKeepThePrioritisedOrder() {
        let files = (0..<12).map { index in
            Fixtures.file("Sources/Auth/File\(index).swift", additions: 400, deletions: 0)
        }
        let hints = TriageRiskHints.hints(for: files, limit: 4)
        XCTAssertEqual(hints.count, 4, "the hints summarise the analysis, they do not copy it")
    }

    func testALockfileOnlyChangeSaysSoInOneLine() {
        let hints = TriageRiskHints.hints(for: [
            Fixtures.file("Package.resolved"),
            Fixtures.file("pnpm-lock.yaml"),
        ])
        XCTAssertEqual(hints.first, "Every changed file is generated or vendored (a lockfile, a snapshot or a bundle).")
    }

    func testTheHeuristicRiskReadsTheExistingBuckets() {
        XCTAssertEqual(
            TriageRiskHints.heuristicRisk(for: [Fixtures.file(".github/workflows/ci.yml")]),
            .high,
            "a CI workflow is review-first, so it is high without any model"
        )
        XCTAssertEqual(
            TriageRiskHints.heuristicRisk(for: [Fixtures.file("Sources/Inbox/InboxModel.swift")]),
            .medium
        )
        XCTAssertEqual(
            TriageRiskHints.heuristicRisk(for: [Fixtures.file("Package.resolved")]),
            .low
        )
        XCTAssertNil(
            TriageRiskHints.heuristicRisk(for: []),
            "a pull request nobody has opened has no diff to judge, and inventing a level would be a verdict"
        )
    }

    // MARK: - The input

    func testTheInputCarriesTheDocumentTheIndexAlreadyBuilt() {
        let document = SearchDocument.make(
            source: SearchIndexSource(
                summary: Fixtures.summary(id: "PR_1", title: "Bump GRDB", labels: ["automerge"]),
                files: [Fixtures.file("Package.resolved")]
            )
        )
        let input = TriageInput.make(document: document, riskHints: ["only a lockfile"])

        XCTAssertEqual(input.prID, "PR_1")
        XCTAssertEqual(input.documentHash, document.documentHash)
        XCTAssertEqual(input.title, "Bump GRDB")
        XCTAssertTrue(input.promptText.hasPrefix("Pull request: Bump GRDB"))
        XCTAssertTrue(input.promptText.contains("- only a lockfile"))
        XCTAssertTrue(input.promptText.contains("automerge"), "the document's own text is the body")
        XCTAssertGreaterThan(input.approximateTokenCount, 0)
    }

    func testAnInputWithNoHintsHasNoHintSection() {
        let document = SearchDocument.make(
            source: SearchIndexSource(summary: Fixtures.summary(id: "PR_1"))
        )
        let input = TriageInput.make(document: document, riskHints: [])
        XCTAssertFalse(input.promptText.contains("Risk hints"))
    }

    // MARK: - Storage value

    func testAStoredVerdictIsReusableOnlyForTheSameTextAndTheSameModel() {
        let document = SearchDocument.make(
            source: SearchIndexSource(summary: Fixtures.summary(id: "PR_1"))
        )
        let input = TriageInput.make(document: document, riskHints: [])
        let entry = TriageVerdictEntry(
            prID: "PR_1",
            documentHash: input.documentHash,
            verdict: TriageVerdict(kind: .fix, risk: .low, reason: "One line."),
            modelIdentifier: "model-a",
            classifiedAt: Fixtures.date(0)
        )

        XCTAssertTrue(entry.isUsable(for: input, modelIdentifier: "model-a"))
        XCTAssertFalse(
            entry.isUsable(for: input, modelIdentifier: "model-b"),
            "two models' verdicts are not interchangeable"
        )

        var edited = input
        edited.documentText += "\nA new added line."
        edited.documentHash = "different"
        XCTAssertFalse(entry.isUsable(for: edited, modelIdentifier: "model-a"))
    }

    // MARK: - ⌘K tokens

    func testTheTokensAreParsedOutOfTheQueryAndOutOfTheRanking() {
        let query = SearchQuery(text: "risk:high kind:dependency login")

        XCTAssertEqual(query.triage.risks, [.high])
        XCTAssertEqual(query.triage.kinds, [.dependencyBump])
        XCTAssertEqual(query.tokens, ["login"], "the tokens do not rank as words")
        XCTAssertEqual(query.normalizedText, "login", "and they are not embedded either")
        XCTAssertTrue(query.looksLikeProse, "a filter query is a search, not a command name")
        XCTAssertTrue(query.hasSearchTerms)
    }

    func testAFilterOnlyQueryIsNotEmptyButHasNothingToRank() {
        let query = SearchQuery(text: "risk:high")
        XCTAssertFalse(query.isEmpty)
        XCTAssertFalse(query.hasSearchTerms)
        XCTAssertEqual(query.normalizedText, "")
    }

    func testEveryTokenSpellingTheVocabularyAllows() {
        XCTAssertEqual(SearchQuery(text: "RISK:High").triage.risks, [.high])
        XCTAssertEqual(SearchQuery(text: "kind:deps").triage.kinds, [.dependencyBump])
        XCTAssertEqual(SearchQuery(text: "kind:dependencies").triage.kinds, [.dependencyBump])
        XCTAssertEqual(SearchQuery(text: "kind:dependency-bump").triage.kinds, [.dependencyBump])
        XCTAssertEqual(
            SearchQuery(text: "risk:low risk:medium").triage.risks,
            [.low, .medium],
            "two values of one axis are an either/or"
        )
    }

    func testATokenThatNamesNothingStaysASearchWord() {
        let query = SearchQuery(text: "risk:urgent")
        XCTAssertFalse(query.triage.isActive)
        XCTAssertEqual(query.tokens, ["risk", "urgent"])
    }

    func testAReferenceStillWorksBesideAToken() {
        let query = SearchQuery(text: "risk:high schnaq/review#128")
        XCTAssertEqual(query.triage.risks, [.high])
        XCTAssertEqual(
            query.reference,
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 128)
        )
    }

    func testTheFilterMatchesOnBothAxesAndRefusesARowWithNoVerdict() {
        let filter = TriageFilter(kinds: [.dependencyBump], risks: [.high])
        XCTAssertTrue(
            filter.matches(TriageVerdict(kind: .dependencyBump, risk: .high, reason: ""))
        )
        XCTAssertFalse(
            filter.matches(TriageVerdict(kind: .dependencyBump, risk: .low, reason: "")),
            "the axes are ANDed"
        )
        XCTAssertFalse(
            filter.matches(nil),
            "the tokens name what the model said, so an unclassified row is not an answer"
        )
        XCTAssertTrue(
            TriageFilter().matches(nil),
            "and an inactive filter is not a filter"
        )
    }

    func testAFilterOnlyQueryListsTheCandidatesInATotalOrder() {
        let other = RepoRef(owner: "schnaq", name: "shepherd-web")
        let documents = [
            document(id: "PR_1", number: 7),
            document(id: "PR_2", number: 9),
            document(id: "PR_3", number: 4, repo: other),
        ]
        let results = SearchRanker.rank(
            query: SearchQuery(text: "risk:high"),
            documents: documents
        )
        XCTAssertEqual(
            results.map(\.prID),
            ["PR_2", "PR_1", "PR_3"],
            "repository ascending, number descending — a list, not a ranking"
        )
        XCTAssertNil(results.first?.reason, "there is no word that matched, so there is no reason")
    }

    // MARK: - The rail's counts

    func testTheRiskFacetCountsHighFirstAndOmitsEmptyLevels() {
        let facets = TriageFacets.riskFacets([
            TriageRowRisk(risk: .low, isClassified: true),
            TriageRowRisk(risk: .high, isClassified: true),
            TriageRowRisk(risk: .high, isClassified: false),
            TriageRowRisk(risk: .high, isClassified: true),
        ])

        XCTAssertEqual(facets.map(\.risk), [.high, .low], "medium is at nobody, so it has no row")
        XCTAssertEqual(facets.first?.count, 3)
        XCTAssertEqual(
            facets.first?.classifiedCount,
            2,
            "the rail can say how much of a count is the model's and how much is tier 1"
        )
    }

    func testAnEmptyInboxHasNoRiskFacet() {
        XCTAssertTrue(TriageFacets.riskFacets([]).isEmpty)
    }

    // MARK: - It sorts, it does not approve (ADR 0023)

    /// The rule that makes structured triage safe, asserted on the *inputs* of every path that
    /// can write to GitHub or start an agent.
    ///
    /// It is written by reflection rather than as a comment because the failure mode is a future
    /// change, not today's code: the moment somebody adds a `verdict` to one of these values, the
    /// rules engine underneath it *can* read a generated classification, and a rule nobody can
    /// see being broken is not a rule. Reflection walks the whole tree, so smuggling one in on a
    /// nested value fails here too.
    func testNoAutomationInputCanSeeAVerdict() {
        let summary = Fixtures.summary(id: "PR_1")
        assertNoVerdict(in: summary, label: "PullRequestSummary")
        assertNoVerdict(
            in: BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [summary]),
            label: "BulkTriagePlan"
        )
        assertNoVerdict(
            in: AutoMergeRules(isEnabled: true),
            label: "AutoMergeRules"
        )
        assertNoVerdict(in: AutoMergeLedger(), label: "AutoMergeLedger")
        assertNoVerdict(
            in: MergeWhenGreenList().arming(
                MergeWhenGreenRequest(
                    prID: "PR_1",
                    slug: "schnaq/review#1",
                    title: "Fix the thing",
                    headRefOid: "abc123",
                    mergeMethod: "squash",
                    deletesHeadBranch: false,
                    armedAt: Fixtures.date(0)
                )
            ),
            label: "MergeWhenGreenList"
        )
        assertNoVerdict(
            in: AutoDelegationSignal(
                trigger: .checksFailed,
                pullRequest: summary,
                isTransition: true
            ),
            label: "AutoDelegationSignal"
        )
        assertNoVerdict(
            in: AutoDelegationContext(
                rules: AutoDelegationRules(isEnabled: true),
                isConfigured: true,
                hasRunningDelegation: false,
                runningAutomaticCount: 0,
                ledger: AutoDelegationLedger(),
                now: Fixtures.date(0),
                timeZone: TimeZone(identifier: "UTC") ?? .current
            ),
            label: "AutoDelegationContext"
        )
    }

    /// The same rule for the track record and the trust lane (ADR 0027).
    ///
    /// A second assertion over the *same* inputs rather than a second mechanism: ADR 0027 makes
    /// the identical promise ADR 0023 makes — the numbers sort and filter the inbox and nothing
    /// else — so the failure mode is identical too. The moment somebody hangs a
    /// ``ShepherdCore/TrackRecord``, a ``ShepherdCore/PullRequestOutcome`` or a lane off one of
    /// these values, a rules engine underneath it *can* read a history, and merging on a track
    /// record is exactly the "Shepherd forms a verdict" line ADR 0018 refuses to cross.
    func testNoAutomationInputCanSeeATrackRecord() {
        let summary = Fixtures.summary(id: "PR_1")
        assertNoHistoryOrLane(in: summary, label: "PullRequestSummary")
        assertNoHistoryOrLane(
            in: BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [summary]),
            label: "BulkTriagePlan"
        )
        assertNoHistoryOrLane(in: AutoMergeRules(isEnabled: true), label: "AutoMergeRules")
        assertNoHistoryOrLane(in: AutoMergeLedger(), label: "AutoMergeLedger")
        assertNoHistoryOrLane(
            in: MergeWhenGreenList().arming(
                MergeWhenGreenRequest(
                    prID: "PR_1",
                    slug: "schnaq/review#1",
                    title: "Fix the thing",
                    headRefOid: "abc123",
                    mergeMethod: "squash",
                    deletesHeadBranch: false,
                    armedAt: Fixtures.date(0)
                )
            ),
            label: "MergeWhenGreenList"
        )
        assertNoHistoryOrLane(
            in: AutoDelegationSignal(
                trigger: .checksFailed,
                pullRequest: summary,
                isTransition: true
            ),
            label: "AutoDelegationSignal"
        )
        assertNoHistoryOrLane(
            in: AutoDelegationContext(
                rules: AutoDelegationRules(isEnabled: true),
                isConfigured: true,
                hasRunningDelegation: false,
                runningAutomaticCount: 0,
                ledger: AutoDelegationLedger(),
                now: Fixtures.date(0),
                timeZone: TimeZone(identifier: "UTC") ?? .current
            ),
            label: "AutoDelegationContext"
        )
    }

    /// Fails when any value reachable from `value` is a track-record or trust-lane type.
    ///
    /// Names rather than types, for ``assertNoVerdict(in:label:depth:file:line:)``'s reason. The
    /// history families are ``TrustLaneTests/isHistoryType(_:)``'s, so the two suites cannot come
    /// to different conclusions about what counts as history; the lane types are named here.
    private func assertNoHistoryOrLane(
        in value: Any,
        label: String,
        depth: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard depth < 6 else { return }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            let typeName = "\(type(of: child.value))"
            XCTAssertFalse(
                TrustLaneTests.isHistoryType(typeName) || typeName.contains("TrustLane"),
                """
                \(label) reached a \(typeName) through \(child.label ?? "?"). ADR 0027: a track \
                record informs the badge and the sort — no automation input may read one, and no \
                automation input may read a lane either.
                """,
                file: file,
                line: line
            )
            assertNoHistoryOrLane(
                in: child.value,
                label: "\(label).\(child.label ?? "?")",
                depth: depth + 1,
                file: file,
                line: line
            )
        }
    }

    /// Fails when any value reachable from `value` is a triage type.
    ///
    /// The names are matched rather than the types, because that is what a reflective walk has:
    /// `Mirror` reports `type(of:)`, and a field added as `TriageVerdict?`, `[TriageVerdict]` or
    /// `TriageVerdictEntry` all spell it in there.
    private func assertNoVerdict(
        in value: Any,
        label: String,
        depth: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Deep enough for every value above and bounded so a recursive type cannot hang the
        // suite; the shapes here are three levels at most.
        guard depth < 6 else { return }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            let typeName = "\(type(of: child.value))"
            XCTAssertFalse(
                typeName.contains("Triage") && typeName.contains("Verdict"),
                """
                \(label) reached a \(typeName) through \(child.label ?? "?"). ADR 0023: a triage \
                verdict sorts and filters the inbox — no automation input may read one.
                """,
                file: file,
                line: line
            )
            assertNoVerdict(
                in: child.value,
                label: "\(label).\(child.label ?? "?")",
                depth: depth + 1,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Fixtures

    private func document(
        id: String,
        number: Int,
        repo: RepoRef = Fixtures.repo
    ) -> SearchDocument {
        SearchDocument.make(
            source: SearchIndexSource(
                summary: Fixtures.summary(id: id, number: number, repo: repo)
            )
        )
    }
}
