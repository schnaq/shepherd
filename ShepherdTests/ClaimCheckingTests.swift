import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// *Look closer* on the claims card (ADR 0026's 2026-09-22 amendment): offered only where the
/// checker is available and Shepherd's own evidence is ✗ or ?, run once per line and detail,
/// forgotten when the diff changes.
@MainActor
final class ClaimCheckingTests: XCTestCase {
    // MARK: - Doubles

    private actor FakeChecker: ClaimChecking {
        private let result: ClaimCheck
        private let availabilityReason: String?
        private let failure: IntelligenceError?
        private(set) var lineIDs: [String] = []

        init(
            result: ClaimCheck = ClaimCheck(notes: []),
            availabilityReason: String? = nil,
            failure: IntelligenceError? = nil
        ) {
            self.result = result
            self.availabilityReason = availabilityReason
            self.failure = failure
        }

        var callCount: Int { lineIDs.count }

        func availability() async -> ClaimExtractorAvailability {
            guard let availabilityReason else { return .available }
            return .unavailable(availabilityReason)
        }

        func check(
            _ line: ClaimsEvidenceReport.Line,
            in detail: PullRequestDetail
        ) async throws -> ClaimCheck {
            lineIDs.append(line.id)
            if let failure { throw failure }
            return result
        }
    }

    // MARK: - Fixtures

    private func detail(
        body: String = "Tests added.",
        head: String = "abc123",
        files: [ChangedFile]? = nil
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: PullRequestSummary(
                id: "PR_1",
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 42,
                title: "Retry the flaky upload",
                author: ShepherdCore.Actor(login: "alice", kind: .human),
                updatedAt: Date(timeIntervalSince1970: 1_000),
                createdAt: Date(timeIntervalSince1970: 0),
                additions: 12,
                deletions: 3,
                changedFiles: 1,
                headRefName: "alice/retry",
                headRefOid: head,
                baseRefName: "main",
                checkRollup: CheckRollup(state: .success, total: 1, failureCount: 0)
            ),
            bodyMarkdown: body,
            files: files ?? [
                ChangedFile(
                    path: "Sources/Uploader/Upload.swift",
                    status: .modified,
                    additions: 1,
                    deletions: 1,
                    patch: "@@ -1,2 +1,2 @@\n-old\n+new\n"
                ),
            ]
        )
    }

    private func loaded(
        _ checker: (any ClaimChecking)?,
        detail: PullRequestDetail? = nil
    ) async -> ClaimsEvidenceModel {
        let model = ClaimsEvidenceModel(embedder: nil)
        model.refresh(detail: detail ?? self.detail(), extractor: nil, checker: checker)
        await model.prepareCheckAvailability()
        return model
    }

    private func firstLine(_ model: ClaimsEvidenceModel) throws -> ClaimsEvidenceReport.Line {
        try XCTUnwrap(model.state.lines.first)
    }

    private let note = ClaimCheck.Note(
        path: "Sources/Uploader/Upload.swift",
        excerpt: "new",
        sentence: "The upload line changed.",
        line: 1
    )

    // MARK: - Offered

    func testAnUnavailableCheckerOffersNothing() async throws {
        let model = await loaded(FakeChecker(availabilityReason: "Apple Intelligence is off."))
        XCTAssertFalse(model.canCheck(try firstLine(model)))
    }

    func testNoCheckerOffersNothing() async throws {
        let model = await loaded(nil)
        XCTAssertFalse(model.canCheck(try firstLine(model)))
    }

    func testALineWithoutSupportingEvidenceIsOffered() async throws {
        let model = await loaded(FakeChecker())
        let line = try firstLine(model)
        XCTAssertNotEqual(line.verdict.status, .ok, "fixture: a source-only diff does not show tests")
        XCTAssertTrue(model.canCheck(line))
    }

    func testASupportedLineIsNotOffered() async throws {
        let files = [
            ChangedFile(
                path: "Tests/UploaderTests/UploadTests.swift",
                status: .added,
                additions: 20,
                patch: "@@ -0,0 +1,2 @@\n+func testUpload() {\n+    XCTAssertTrue(upload())\n"
            ),
        ]
        let model = await loaded(FakeChecker(), detail: detail(files: files))
        let line = try firstLine(model)
        XCTAssertEqual(line.verdict.status, .ok, "fixture: an added test file supports the claim")
        XCTAssertFalse(model.canCheck(line))
    }

    // MARK: - Running

    func testACheckLandsAsDoneAndIsNotOfferedAgain() async throws {
        let checker = FakeChecker(result: ClaimCheck(notes: [note]))
        let model = await loaded(checker)
        let line = try firstLine(model)

        await model.check(line)

        XCTAssertEqual(model.checks[line.id], .done(ClaimCheck(notes: [note])))
        XCTAssertFalse(model.canCheck(line))
        await model.check(line)
        let calls = await checker.callCount
        XCTAssertEqual(calls, 1)
    }

    func testTheLinesMarkIsNotChangedByACheck() async throws {
        let model = await loaded(FakeChecker(result: ClaimCheck(notes: [note])))
        let before = try firstLine(model)
        await model.check(before)
        XCTAssertEqual(try firstLine(model).verdict, before.verdict)
    }

    func testAFailureKeepsItsSentenceAndCanBeRetried() async throws {
        let checker = FakeChecker(failure: .unavailable("The model is busy."))
        let model = await loaded(checker)
        let line = try firstLine(model)

        await model.check(line)

        guard case .failed(let reason) = model.checks[line.id] else {
            return XCTFail("expected a failure, got \(String(describing: model.checks[line.id]))")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(model.canCheck(line))
    }

    func testANewHeadForgetsEveryAnswer() async throws {
        let model = await loaded(FakeChecker(result: ClaimCheck(notes: [note])))
        let line = try firstLine(model)
        await model.check(line)
        XCTAssertNotNil(model.checks[line.id])

        model.refresh(detail: detail(head: "def456"), extractor: nil, checker: FakeChecker())

        XCTAssertTrue(model.checks.isEmpty)
    }

    func testTurningTheTiersOffWithdrawsTheOffer() async throws {
        let model = await loaded(FakeChecker())
        model.refresh(detail: detail(), extractor: nil, checker: nil)
        XCTAssertFalse(model.canCheck(try firstLine(model)))
    }
}
