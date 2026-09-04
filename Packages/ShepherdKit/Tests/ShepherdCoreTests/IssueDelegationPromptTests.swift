import Foundation
import XCTest
@testable import ShepherdCore

/// The task text an issue handover runs with (ADR 0032's 2026-09-04 amendment).
///
/// Pinned on the Linux runner for ``AutoDelegationPromptTests``' reason: what a brief says is the
/// whole of what the assistant is told, so it is worth asserting rather than reading in a sheet.
final class IssueDelegationPromptTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    private func issue(
        _ number: Int = 128,
        title: String = "Sync stalls on a renamed branch",
        labels: [String] = []
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: "I_\(number)",
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_788_100_000),
            labels: labels
        )
    }

    func testTheDefaultTemplateStatesTheIssueAndTheLabels() {
        let text = IssueDelegationPrompt.render(
            template: IssueDelegationPrompt.defaultTemplate,
            issue: issue(labels: ["bug", "sync"]),
            body: "It only happens after the default branch is renamed."
        )
        XCTAssertTrue(text.hasPrefix("Issue schnaq/review#128: Sync stalls on a renamed branch"))
        XCTAssertTrue(text.contains("Labels: bug, sync"))
        XCTAssertTrue(text.contains("It only happens after the default branch is renamed."))
        XCTAssertFalse(
            text.contains("{"),
            "an unreplaced placeholder would reach the assistant verbatim"
        )
    }

    func testAnIssueWithNoLabelsSaysNoneRatherThanLeavingAGap() {
        let text = IssueDelegationPrompt.render(
            template: IssueDelegationPrompt.defaultTemplate,
            issue: issue(),
            body: "Something is wrong."
        )
        XCTAssertTrue(text.contains("Labels: none"))
    }

    func testABodyNobodyHasReadIsSaidRatherThanShownAsEmpty() {
        // The sentence has to be true twice over: for an issue with no description, and for one
        // whose body this Mac has not fetched. So it says what Shepherd knows, not what the
        // issue contains.
        let text = IssueDelegationPrompt.render(
            template: IssueDelegationPrompt.defaultTemplate,
            issue: issue()
        )
        XCTAssertTrue(text.contains("Shepherd has not read a description for this issue."))
        XCTAssertFalse(text.contains("\n\n\n"), "and it leaves no blank paragraph behind")
    }

    func testEveryPlaceholderIsSubstituted() {
        let template = IssueDelegationPrompt.placeholders.joined(separator: "\n")
        let text = IssueDelegationPrompt.render(
            template: template,
            issue: issue(7, title: "Tidy up", labels: ["chore"]),
            body: "A body."
        )
        XCTAssertEqual(
            text,
            """
            7
            schnaq/review
            Tidy up
            chore
            A body.
            """
        )
    }

    func testAnEmptiedTemplateFallsBackToTheDefaultRatherThanStartingNothing() {
        let text = IssueDelegationPrompt.render(
            template: "   \n  ",
            issue: issue(),
            body: "A body."
        )
        XCTAssertEqual(
            text,
            IssueDelegationPrompt.render(
                template: IssueDelegationPrompt.defaultTemplate,
                issue: issue(),
                body: "A body."
            )
        )
    }

    func testTheTemplateNameIsAName() {
        // The handover event reports which template was used, and a template may quote the
        // issue — so what travels is the name.
        XCTAssertEqual(IssueDelegationPrompt.name(of: IssueDelegationPrompt.defaultTemplate), "default")
        XCTAssertEqual(IssueDelegationPrompt.name(of: "Do {title}."), "custom")
    }

    func testTheDefaultTemplateSaysNothingAboutWhatTheRunMayDo() {
        // What a run is allowed to do with the result is the preamble's business, and the
        // preamble is Shepherd's. A template anybody may rewrite must not be able to grant a
        // permission (ADR 0011).
        let template = IssueDelegationPrompt.defaultTemplate.lowercased()
        XCTAssertFalse(template.contains("pull request"))
        XCTAssertFalse(template.contains("push"))
        XCTAssertFalse(template.contains("branch"))
    }
}
