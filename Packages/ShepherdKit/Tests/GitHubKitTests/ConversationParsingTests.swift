import Foundation
import ShepherdCore
import XCTest

@testable import GitHubKit

/// ADR 0043's conversation read, against recorded responses: one node of every type the document
/// asks for (and one it does not), the description's reactions and flags, and the backwards
/// paging that keeps the newest five hundred items rather than the oldest.
final class ConversationParsingTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    /// Reads #128's conversation from the given fixtures, which answer the requests in order;
    /// the last one repeats.
    private func read(
        _ fixtures: String...
    ) async throws -> (conversation: PullRequestConversation, transport: MockTransport) {
        let transport = MockTransport()
        for fixture in fixtures {
            await transport.route("ShepherdPullRequestConversation", try Fixture.response(fixture))
        }
        let client = GitHubClient.makeForTesting(transport: transport)
        let conversation = try await client.pullRequestConversation(repo: repo, number: 128)
        return (conversation, transport)
    }

    // MARK: - One node of every kind

    func testMapsEveryItemKindInGitHubsOrder() async throws {
        let conversation = try await read("pull-conversation").conversation

        // Twenty-two types in the table, in the order GitHub sent them; the `SubscribedEvent`
        // between the comment and the review is not one of them and is gone.
        XCTAssertEqual(conversation.items.count, 22)
        XCTAssertEqual(conversation.items.map(\.id), [
            "LE_kwDOLabeled", "AE_kwDOAssigned", "RRE_kwDORequested", "IC_kwDOCommentOne",
            "PRR_kwDOReviewOne", "HRFPE_kwDOForcePushed", "RDE_kwDODismissed",
            "RRRE_kwDORequestRemoved", "ULE_kwDOUnlabeled", "UAE_kwDOUnassigned",
            "RTE_kwDORenamed", "CTDE_kwDODraft", "RFRE_kwDOReady", "CRE_kwDOCrossReferenced",
            "BRCE_kwDOBaseChanged", "AMEE_kwDOAutoMergeOn", "AMDE_kwDOAutoMergeOff",
            "CE_kwDOClosed", "REE_kwDOReopened", "ME_kwDOMerged", "HRDE_kwDOBranchDeleted",
            "HRRE_kwDOBranchRestored",
        ])
    }

    func testMapsACommentWithItsFlagsReactionsAndMinimizedState() async throws {
        let conversation = try await read("pull-conversation").conversation

        guard case .comment(let comment)? = conversation.items.first(where: {
            $0.id == "IC_kwDOCommentOne"
        }) else { return XCTFail("the comment is missing") }
        XCTAssertEqual(comment.databaseID, 2001)
        XCTAssertEqual(comment.author.login, "n2o")
        XCTAssertEqual(comment.author.kind, .human)
        XCTAssertEqual(comment.bodyMarkdown, "Unrelated: the office printer is out of toner again.")
        XCTAssertEqual(comment.createdAt, GitHubTimestamp.parse("2026-08-31T06:30:00Z"))
        XCTAssertTrue(comment.isEdited)
        XCTAssertEqual(
            comment.url,
            URL(string: "https://github.com/schnaq/review/pull/128#issuecomment-2001")
        )
        // The zero group and the content this build does not know are both dropped.
        XCTAssertEqual(comment.reactions, [
            ReactionGroup(content: .thumbsUp, count: 1),
            ReactionGroup(content: .eyes, count: 2, viewerHasReacted: true),
        ])
        XCTAssertTrue(comment.viewerCanUpdate)
        XCTAssertTrue(comment.viewerCanDelete)
        XCTAssertTrue(comment.isMinimized)
        // GitHub documents lowercase words; the fixture shouts, and the mapping lowercases anyway.
        XCTAssertEqual(comment.minimizedReason, "off-topic")
    }

    func testMapsAReviewDatedBySubmissionWithItsState() async throws {
        let conversation = try await read("pull-conversation").conversation

        guard case .review(let review)? = conversation.items.first(where: {
            $0.id == "PRR_kwDOReviewOne"
        }) else { return XCTFail("the review is missing") }
        // Started at 07:00, submitted at 07:15: nobody saw it before the second.
        XCTAssertEqual(review.createdAt, GitHubTimestamp.parse("2026-08-31T07:15:00Z"))
        XCTAssertEqual(review.state, .changesRequested)
        XCTAssertEqual(review.commitOid, "1111111111111111111111111111111111111111")
        XCTAssertEqual(review.databaseID, 3001)
        XCTAssertEqual(review.bodyMarkdown, "The store should not force-unwrap the token.")
        XCTAssertFalse(review.isEdited)
        XCTAssertEqual(
            review.url,
            URL(string: "https://github.com/schnaq/review/pull/128#pullrequestreview-3001")
        )
        XCTAssertEqual(review.reactions, [ReactionGroup(content: .rocket, count: 1)])
        XCTAssertTrue(review.viewerCanUpdate)

        // The other verdicts, and a word this build does not know, which claims nothing.
        XCTAssertEqual(ResponseMapping.reviewState("APPROVED"), .approved)
        XCTAssertEqual(ResponseMapping.reviewState("DISMISSED"), .dismissed)
        XCTAssertEqual(ResponseMapping.reviewState("PENDING"), .pending)
        XCTAssertEqual(ResponseMapping.reviewState("COMMENTED"), .commented)
        XCTAssertEqual(ResponseMapping.reviewState("ESCALATED"), .commented)
        XCTAssertEqual(ResponseMapping.reviewState(nil), .commented)
    }

    func testMapsEventsToValues() async throws {
        let conversation = try await read("pull-conversation").conversation
        func event(_ id: String) -> ConversationEventItem? {
            guard case .event(let event)? = conversation.items.first(where: { $0.id == id }) else {
                return nil
            }
            return event
        }

        XCTAssertEqual(event("LE_kwDOLabeled")?.event, .labeled(name: "agent", color: "5319e7"))
        XCTAssertEqual(event("ULE_kwDOUnlabeled")?.event, .unlabeled(name: "wip", color: "fbca04"))
        XCTAssertEqual(event("AE_kwDOAssigned")?.event, .assigned(login: "claude[bot]"))
        XCTAssertEqual(event("UAE_kwDOUnassigned")?.event, .unassigned(login: "claude[bot]"))
        XCTAssertEqual(
            event("RRE_kwDORequested")?.event,
            .reviewRequested(reviewer: "reviewers"),
            "a team has no login and is named by its name"
        )
        XCTAssertEqual(
            event("RRRE_kwDORequestRemoved")?.event,
            .reviewRequestRemoved(reviewer: "n2o")
        )
        XCTAssertEqual(
            event("RTE_kwDORenamed")?.event,
            .renamed(from: "WIP: token store", to: "Refactor the token store")
        )
        XCTAssertEqual(event("RFRE_kwDOReady")?.event, .readyForReview)
        XCTAssertEqual(event("CTDE_kwDODraft")?.event, .convertedToDraft)
        XCTAssertEqual(
            event("ME_kwDOMerged")?.event,
            .merged(commitOid: "3f1a9c0d5b7e2a4c6d8f0b1a2c3e4d5f60718293", into: "release/1.12")
        )
        XCTAssertEqual(event("CE_kwDOClosed")?.event, .closed)
        XCTAssertEqual(event("REE_kwDOReopened")?.event, .reopened)
        XCTAssertEqual(
            event("HRDE_kwDOBranchDeleted")?.event,
            .headRefDeleted(branch: "claude/refactor-token-store")
        )
        XCTAssertEqual(event("HRRE_kwDOBranchRestored")?.event, .headRefRestored)
        XCTAssertEqual(
            event("BRCE_kwDOBaseChanged")?.event,
            .baseRefChanged(from: "main", to: "release/1.12")
        )
        XCTAssertEqual(
            event("HRFPE_kwDOForcePushed")?.event,
            .forcePushed(
                fromOid: "1111111111111111111111111111111111111111",
                toOid: "3f1a9c0d5b7e2a4c6d8f0b1a2c3e4d5f60718293"
            )
        )
        XCTAssertEqual(
            event("CRE_kwDOCrossReferenced")?.event,
            .crossReferenced(
                ConversationReference(
                    repo: RepoRef(owner: "schnaq", name: "shepherd-web"),
                    number: 7,
                    title: "Use the new token store",
                    isPullRequest: true,
                    url: URL(string: "https://github.com/schnaq/shepherd-web/pull/7")
                ),
                willClose: true
            )
        )
        XCTAssertEqual(
            event("RDE_kwDODismissed")?.event,
            .reviewDismissed(message: "Fixed by the force-push.")
        )
        XCTAssertEqual(event("AMEE_kwDOAutoMergeOn")?.event, .autoMergeEnabled)
        XCTAssertEqual(event("AMDE_kwDOAutoMergeOff")?.event, .autoMergeDisabled)

        // Who and when.
        let forcePush = event("HRFPE_kwDOForcePushed")
        XCTAssertEqual(forcePush?.createdAt, GitHubTimestamp.parse("2026-08-31T07:40:00Z"))
        XCTAssertEqual(forcePush?.actor?.login, "claude[bot]")
        XCTAssertNotNil(
            forcePush?.actor?.kind.agentIdentity,
            "a Bot actor goes through the detector"
        )
        XCTAssertEqual(event("LE_kwDOLabeled")?.actor?.kind, .human)
        XCTAssertNil(event("REE_kwDOReopened")?.actor, "a deleted account is no actor, not a ghost")
    }

    func testDropsANodeMissingWhatItIsAbout() throws {
        func item(_ json: String) throws -> ConversationItem? {
            let node = try JSONDecoder().decode(TimelineItemDTO.self, from: Data(json.utf8))
            return ResponseMapping.conversationItem(from: node, detector: TestRegistry.detector)
        }
        let stamp = #""id":"X_kwDO","createdAt":"2026-08-31T06:00:00Z""#

        XCTAssertNotNil(try item(#"{\#(stamp),"__typename":"ClosedEvent"}"#), "the control case")
        // A sentence with a hole in it is dropped, never filled in.
        for fields in [
            #""__typename":"LabeledEvent","label":{"color":"5319e7"}"#,
            #""__typename":"UnlabeledEvent""#,
            #""__typename":"AssignedEvent","assignee":{"__typename":"User"}"#,
            #""__typename":"UnassignedEvent","assignee":null"#,
            #""__typename":"ReviewRequestedEvent","requestedReviewer":{"__typename":"Team"}"#,
            #""__typename":"ReviewRequestRemovedEvent""#,
            #""__typename":"RenamedTitleEvent","previousTitle":"WIP: token store""#,
            #""__typename":"CrossReferencedEvent","source":{"__typename":"Issue","title":"x"}"#,
            #""label":{"name":"agent"}"#,
        ] {
            XCTAssertNil(try item(#"{\#(stamp),\#(fields)}"#), fields)
        }
        // Every item is keyed by its id and ordered by its date, so neither may be missing.
        XCTAssertNil(try item(#"{"__typename":"ClosedEvent","id":"X_kwDO"}"#))
        XCTAssertNil(try item(#"{"__typename":"ClosedEvent","createdAt":"2026-08-31T06:00:00Z"}"#))
    }

    func testReadsTheDescriptionsReactionsAndPermissions() async throws {
        let conversation = try await read("pull-conversation").conversation

        // GitHub answered all eight groups; the six nobody used are dropped.
        XCTAssertEqual(conversation.descriptionReactions, [
            ReactionGroup(content: .thumbsUp, count: 2, viewerHasReacted: true),
            ReactionGroup(content: .heart, count: 1),
        ])
        XCTAssertTrue(conversation.isDescriptionEdited)
        XCTAssertTrue(conversation.viewerCanUpdateDescription)
        XCTAssertTrue(conversation.viewerCanReact)
        XCTAssertFalse(conversation.hasEarlierItems)
    }

    func testAMissingPullRequestIsNotFound() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdPullRequestConversation",
            Fixture.response(json: #"{"data":{"repository":{"pullRequest":null}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.pullRequestConversation(repo: repo, number: 128)
            XCTFail("expected notFound")
        } catch GitHubError.notFound {
            // Expected: the same answer the head probe gives.
        }
    }

    // MARK: - Paging backwards

    func testReadsPagesNewestFirstAndAssemblesThemOldestFirst() async throws {
        let (conversation, transport) = try await read(
            "pull-conversation-page-newest",
            "pull-conversation-page-oldest"
        )

        let bodies = await transport.requests.map {
            String(decoding: $0.body ?? Data(), as: UTF8.self)
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains(#""before":null"#), bodies[0])
        XCTAssertTrue(bodies[0].contains("timelineItems(last: 100, before: $before"), bodies[0])
        XCTAssertTrue(bodies[1].contains(#""before":"CUR1""#), bodies[1])
        XCTAssertEqual(
            conversation.items.map(\.id),
            ["IC_kwDOOldestOne", "IC_kwDONewestOne", "IC_kwDONewestTwo"]
        )
        XCTAssertFalse(conversation.hasEarlierItems)
        // The description is the first page's, the freshest answer, where a later one disagrees.
        XCTAssertEqual(
            conversation.descriptionReactions,
            [ReactionGroup(content: .hooray, count: 1)]
        )
        XCTAssertFalse(conversation.isDescriptionEdited)
        XCTAssertTrue(conversation.viewerCanUpdateDescription)
        XCTAssertTrue(conversation.viewerCanReact)
    }

    func testStopsAfterFivePagesAndSaysThereIsMore() async throws {
        // The newest page is the only answer and repeats: GitHub always says there is more.
        let (conversation, transport) = try await read("pull-conversation-page-newest")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(conversation.hasEarlierItems)
        XCTAssertEqual(conversation.items.count, 10, "every page read is kept")
    }
}
