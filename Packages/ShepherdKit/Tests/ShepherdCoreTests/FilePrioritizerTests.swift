import XCTest
@testable import ShepherdCore

final class FilePrioritizerTests: XCTestCase {
    // MARK: - Classification

    func testClassifiesSourceFiles() {
        XCTAssertEqual(
            FilePrioritizer.category(of: Fixtures.file("Sources/App/InboxView.swift")),
            .source
        )
        XCTAssertEqual(FilePrioritizer.category(of: Fixtures.file("src/index.ts")), .source)
    }

    func testClassifiesTestFiles() {
        let paths = [
            "Tests/ShepherdCoreTests/InboxGrouperTests.swift",
            "test/helpers.js",
            "src/__tests__/login.js",
            "internal/service_test.go",
            "web/src/inbox.spec.ts",
            "app/tests/test_login.py",
        ]
        for path in paths {
            XCTAssertEqual(
                FilePrioritizer.category(of: Fixtures.file(path)),
                .tests,
                "expected \(path) to be a test file"
            )
        }
    }

    func testDoesNotMistakeSourceFilesEndingInTestForTests() {
        // "Latest.swift" ends with "test" only when lowercased — the heuristic is
        // case-sensitive on the file name for exactly this reason.
        XCTAssertEqual(
            FilePrioritizer.category(of: Fixtures.file("Sources/App/Latest.swift")),
            .source
        )
    }

    func testClassifiesDocsAndConfig() {
        XCTAssertEqual(FilePrioritizer.category(of: Fixtures.file("README.md")), .docs)
        XCTAssertEqual(FilePrioritizer.category(of: Fixtures.file("docs/adr/0005-x.md")), .docs)
        XCTAssertEqual(
            FilePrioritizer.category(of: Fixtures.file(".github/workflows/ci.yml")),
            .config
        )
        XCTAssertEqual(FilePrioritizer.category(of: Fixtures.file("project.yml")), .config)
        XCTAssertEqual(FilePrioritizer.category(of: Fixtures.file("Package.swift")), .config)
    }

    func testClassifiesGeneratedAndVendoredFiles() {
        let paths = [
            "package-lock.json",
            "pnpm-lock.yaml",
            "Cargo.lock",
            "go.sum",
            "web/dist/bundle.min.js",
            "vendor/github.com/foo/bar.go",
            "node_modules/left-pad/index.js",
            "api/service.pb.go",
            "src/__snapshots__/inbox.test.js.snap",
            "Sources/Generated/Api.generated.swift",
        ]
        for path in paths {
            XCTAssertEqual(
                FilePrioritizer.category(of: Fixtures.file(path)),
                .generated,
                "expected \(path) to be generated/vendored"
            )
        }
    }

    // MARK: - Buckets

    func testSecuritySensitivePathIsReviewedFirst() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file("Sources/App/AuthService.swift")
        ])
        XCTAssertEqual(priorities.first?.bucket, .reviewFirst)
        XCTAssertTrue(
            priorities.first?.reasons.contains(where: { $0.contains("security-sensitive") }) == true
        )
    }

    func testDeletingATestFileIsARiskBoost() {
        let deleted = FilePrioritizer.prioritize([
            Fixtures.file("Tests/AppTests/LoginTests.swift", status: .removed)
        ])
        let kept = FilePrioritizer.prioritize([
            Fixtures.file("Tests/AppTests/LoginTests.swift", status: .modified)
        ])
        XCTAssertEqual(deleted.first?.bucket, .reviewFirst)
        XCTAssertTrue(
            deleted.first?.reasons.contains("Deletes a test file") == true
        )
        guard let deletedScore = deleted.first?.score, let keptScore = kept.first?.score else {
            return XCTFail("expected both files to be scored")
        }
        XCTAssertGreaterThan(deletedScore, keptScore)
    }

    func testCIWorkflowChangesAreReviewedFirst() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file(".github/workflows/release.yml")
        ])
        XCTAssertEqual(priorities.first?.bucket, .reviewFirst)
        XCTAssertTrue(priorities.first?.reasons.contains(where: { $0.contains("CI workflow") }) == true)
    }

    func testContainerBuildFilesAreReviewedFirst() {
        XCTAssertEqual(
            FilePrioritizer.prioritize([Fixtures.file("Dockerfile")]).first?.bucket,
            .reviewFirst
        )
    }

    func testEntitlementsChangesAreReviewedFirst() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file("Shepherd/Support/Shepherd.entitlements")
        ])
        XCTAssertEqual(priorities.first?.bucket, .reviewFirst)
    }

    func testLockfilesLandInTheGeneratedBucket() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file("package-lock.json", additions: 4_000, deletions: 3_800, patch: nil)
        ])
        XCTAssertEqual(priorities.first?.bucket, .generated)
        XCTAssertEqual(priorities.first?.category, .generated)
    }

    func testOrdinarySourceFileIsStandard() {
        XCTAssertEqual(
            FilePrioritizer.prioritize([Fixtures.file("Sources/App/InboxRow.swift")]).first?.bucket,
            .standard
        )
    }

    func testDocumentationIsSkimmed() {
        XCTAssertEqual(
            FilePrioritizer.prioritize([Fixtures.file("docs/ROADMAP.md")]).first?.bucket,
            .skim
        )
    }

    // MARK: - Ordering and reasons

    func testRealisticPullRequestOrdersRiskFirstAndNoiseLast() {
        let files = [
            Fixtures.file("package-lock.json", additions: 900, deletions: 850, patch: nil),
            Fixtures.file("README.md", additions: 4, deletions: 1),
            Fixtures.file("Sources/App/InboxRow.swift", additions: 30, deletions: 5),
            Fixtures.file("Sources/Auth/TokenStore.swift", additions: 60, deletions: 12),
            Fixtures.file("Tests/AppTests/TokenStoreTests.swift", status: .removed,
                          additions: 0, deletions: 90),
        ]
        let priorities = FilePrioritizer.prioritize(files)
        let order = priorities.map(\.file.path)

        XCTAssertEqual(order.count, files.count)
        XCTAssertEqual(order.last, "package-lock.json")
        XCTAssertEqual(priorities.last?.bucket, .generated)

        let topTwo = Set(order.prefix(2))
        XCTAssertEqual(
            topTwo,
            ["Sources/Auth/TokenStore.swift", "Tests/AppTests/TokenStoreTests.swift"]
        )
        XCTAssertTrue(priorities.allSatisfy { !$0.reasons.isEmpty })
    }

    func testOrderingIsStableForEqualScores() {
        let files = [
            Fixtures.file("Sources/B.swift", additions: 10, deletions: 4),
            Fixtures.file("Sources/A.swift", additions: 10, deletions: 4),
        ]
        let first = FilePrioritizer.prioritize(files).map(\.file.path)
        let second = FilePrioritizer.prioritize(Array(files.reversed())).map(\.file.path)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["Sources/A.swift", "Sources/B.swift"])
    }

    func testScoreIsClampedToOneHundred() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file(
                ".github/workflows/auth-secrets-deploy.yml",
                additions: 800,
                deletions: 400
            )
        ])
        XCTAssertEqual(priorities.first?.score, 100)
    }

    func testMissingPatchIsCalledOut() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file("Resources/icon.png", patch: nil)
        ])
        XCTAssertTrue(
            priorities.first?.reasons.contains(where: { $0.contains("No diff available") }) == true
        )
    }

    func testBucketedOmitsEmptyBucketsAndKeepsDisplayOrder() {
        let priorities = FilePrioritizer.prioritize([
            Fixtures.file("Sources/Auth/Token.swift"),
            Fixtures.file("Sources/App/View.swift"),
            Fixtures.file("go.sum", patch: nil),
        ])
        let buckets = FilePrioritizer.bucketed(priorities).map(\.bucket)
        XCTAssertEqual(buckets, [.reviewFirst, .standard, .generated])
    }
}
