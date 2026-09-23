#if DEBUG
import Foundation
import ShepherdCore

/// The one seeded pull request with a full detail (``DemoSeed/showcase``): real unified patches,
/// commits with agent trailers, and review threads anchored to lines those patches add.
///
/// Patches are GitHub's shape — hunks only, no `diff --git` header — and the hunk headers are
/// computed from the lines (``hunk(old:new:_:)``) rather than typed, because a count that
/// disagrees with its body is exactly what the diff renderers are strict about. A thread's `line`
/// is a right-side line number inside one of these hunks, or it would not be drawn in the diff.
enum ShowcaseFiles {
    /// The head commit.
    static let headOid = "9c41e07b2d5f3a86e1c0b4d7f29a58c3e6b1d0a4"

    /// The description, with the two claims the claims card looks for.
    static let body = """
        ## Summary

        Failed outbox writes now show on the inbox row itself, with **Retry** and **Discard** in \
        the row's context menu, instead of only in Settings → Sync.

        - `RowWriteState` gains `offersRetry`, and a merge in flight now outranks a parked review
        - `SignedInSession.discardFailedWrites(for:)` drops just that pull request's failed rows
        - ADR 0006 gets an amendment describing the new precedence

        ## Testing

        Tests added. `RowWriteStateTests` covers the precedence order, and I ran the app against a \
        revoked token to see the chip appear and clear.

        Fixes #42.
        """

    /// Every changed file, in GitHub's order.
    static var all: [ChangedFile] {
        [rowWriteState, inboxList, session, tests, catalog, adr]
    }

    // MARK: - Files

    private static let rowWriteState = ChangedFile(
        path: "Shepherd/Features/Inbox/RowWriteState.swift",
        status: .modified,
        patch: [
            hunk(old: 20, new: 20, [
                " enum RowWriteState: Equatable, Sendable {",
                "+    /// GitHub refused the write and retrying cannot help; the row offers Retry and Discard.",
                "     case failed(Int)",
                "     case parked(Int)",
                "     case merging",
                "     case merged",
                "     case mergeQueued",
                "     case queued(Int)",
                "+",
                "+    /// Whether the row's context menu offers *Retry* for this state.",
                "+    var offersRetry: Bool {",
                "+        if case .failed = self { return true }",
                "+        return false",
                "+    }",
                " }",
            ]),
            hunk(old: 52, new: 59, [
                "         let failed = mine.filter { $0.state == .failed }.count",
                "         if failed > 0 { return .failed(failed) }",
                "-        let parked = mine.filter { $0.state == .conflicted }.count",
                "-        if parked > 0 { return .parked(parked) }",
                "-        if isMerging { return .merging }",
                "+        // A merge in flight outranks a parked review: it is the one write that ends the row.",
                "+        if isMerging { return .merging }",
                "+        let parked = mine.filter { $0.state == .conflicted }.count",
                "+        if parked > 0 { return .parked(parked) }",
                "         if wasMerged { return .merged }",
                "         let waiting = mine.filter { $0.state == .pending || $0.state == .sending }",
            ]),
        ].joined(separator: "\n")
    )

    private static let inboxList = ChangedFile(
        path: "Shepherd/Features/Inbox/InboxListView.swift",
        status: .modified,
        patch: hunk(old: 212, new: 212, [
            "             .contextMenu {",
            "                 rowMenu(for: row)",
            "+                if writeState?.offersRetry == true {",
            "+                    Divider()",
            "+                    Button(String(localized: \"Retry Failed Writes\")) {",
            "+                        Task { await session.retryFailedWrites(for: row.id) }",
            "+                    }",
            "+                    Button(String(localized: \"Discard Failed Writes\"), role: .destructive) {",
            "+                        Task { await session.discardFailedWrites(for: row.id) }",
            "+                    }",
            "+                }",
            "             }",
            "             .accessibilityElement(children: .combine)",
        ])
    )

    private static let session = ChangedFile(
        path: "Shepherd/App/SignedInSession.swift",
        status: .modified,
        patch: hunk(old: 341, new: 341, [
            "     func retryFailedWrites(for targetID: String) async {",
            "         let failed = (try? await database.failedOutboxItems()) ?? []",
            "         for item in failed where item.prID == targetID {",
            "             try? await database.retryOutboxItem(id: item.id)",
            "         }",
            "         await drainOutbox()",
            "     }",
            "+",
            "+    /// Drops the failed writes of one pull request, from the row's context menu.",
            "+    func discardFailedWrites(for targetID: String) async {",
            "+        let failed = (try? await database.failedOutboxItems()) ?? []",
            "+        for item in failed where item.prID == targetID {",
            "+            try? await database.deleteOutboxItem(id: item.id)",
            "+        }",
            "+    }",
            " ",
            "     /// The pull requests the outbox still holds a write for — pending, in flight or parked.",
        ])
    )

    private static let tests = ChangedFile(
        path: "ShepherdTests/RowWriteStateTests.swift",
        status: .added,
        patch: hunk(old: 0, new: 1, [
            "+import ShepherdCore",
            "+import XCTest",
            "+@testable import Shepherd",
            "+",
            "+/// The precedence the row chip follows when a pull request has several writes queued.",
            "+final class RowWriteStateTests: XCTestCase {",
            "+    private let repo = RepoRef(owner: \"schnaq\", name: \"shepherd\")",
            "+",
            "+    func testFailedOutranksMergeQueued() {",
            "+        let items = [",
            "+            OutboxItem(prID: \"PR_1\", repo: repo, number: 1, action: .markReadyForReview, state: .failed),",
            "+            OutboxItem(prID: \"PR_1\", repo: repo, number: 1, action: .merge(method: \"squash\", expectedHeadOid: nil)),",
            "+        ]",
            "+        let state = RowWriteState.make(items: items, for: \"PR_1\", isMerging: false, wasMerged: false)",
            "+        XCTAssertEqual(state, .failed(1))",
            "+        XCTAssertEqual(state?.offersRetry, true)",
            "+    }",
            "+",
            "+    func testMergingOutranksParked() {",
            "+        let items = [",
            "+            OutboxItem(prID: \"PR_1\", repo: repo, number: 1, action: .markReadyForReview, state: .conflicted),",
            "+        ]",
            "+        let state = RowWriteState.make(items: items, for: \"PR_1\", isMerging: true, wasMerged: false)",
            "+        XCTAssertEqual(state, .merging)",
            "+    }",
            "+}",
        ])
    )

    private static let catalog = ChangedFile(
        path: "Shepherd/Resources/Localizable.xcstrings",
        status: .modified,
        patch: hunk(old: 4180, new: 4180, [
            "     },",
            "+    \"Discard Failed Writes\" : {",
            "+      \"localizations\" : {",
            "+        \"de\" : { \"stringUnit\" : { \"state\" : \"translated\", \"value\" : \"Fehlgeschlagene Änderungen verwerfen\" } }",
            "+      }",
            "+    },",
            "+    \"Retry Failed Writes\" : {",
            "+      \"localizations\" : {",
            "+        \"de\" : { \"stringUnit\" : { \"state\" : \"translated\", \"value\" : \"Fehlgeschlagene Änderungen erneut senden\" } }",
            "+      }",
            "+    },",
            "     \"Review\" : {",
        ])
    )

    private static let adr = ChangedFile(
        path: "docs/adr/0006-local-first-outbox.md",
        status: .modified,
        patch: hunk(old: 96, new: 96, [
            " rather than retried; the user decides.",
            "+",
            "+## Amendment 2026-09-23: failed writes on the row",
            "+",
            "+A failed write is now shown where the reviewer already is — on the inbox row — with",
            "+*Retry* and *Discard* beside it. A merge in flight outranks a parked review in the row",
            "+chip, because it is the one write that ends the row.",
        ])
    )

    // MARK: - Commits and threads

    /// Three commits, each carrying the agent's trailer.
    static func commits(author: Actor) -> [CommitInfo] {
        let trailer = "\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
        return [
            CommitInfo(
                oid: "4e2a91c07d3b58f6a1e9c2d4b7f0a3e58c61d2b9",
                messageHeadline: "Offer Retry and Discard on a row with failed writes",
                messageBody: "The chip already said a write failed; now the row can act on it." + trailer,
                author: author,
                committedDate: Date().addingTimeInterval(-3 * 3_600)
            ),
            CommitInfo(
                oid: "3f2c1ab8e6d04c7b9a15f3e2d8c07b4a6e91f5d2",
                messageHeadline: "Let a merge in flight outrank a parked review",
                messageBody: "Refs #42." + trailer,
                author: author,
                committedDate: Date().addingTimeInterval(-2 * 3_600)
            ),
            CommitInfo(
                oid: headOid,
                messageHeadline: "Add RowWriteState precedence tests",
                messageBody: trailer.trimmingCharacters(in: .whitespacesAndNewlines),
                author: author,
                committedDate: Date().addingTimeInterval(-0.4 * 3_600)
            ),
        ]
    }

    /// Three threads: an open question to the agent, a resolved one, and the viewer's own.
    static func threads(author: Actor, reviewer: Actor, other: Actor) -> [ReviewThread] {
        let viewer = Actor(login: DemoSeed.viewerLogin, displayName: "Jonas Weber", kind: .human)
        return [
            ReviewThread(
                id: "RT_demo_1",
                path: rowWriteState.path,
                line: 62,
                comments: [
                    comment("RC_demo_1", 9001, reviewer, hoursAgo: 1.5, """
                        Is `merging` above `parked` what we want? A parked review on a pull request \
                        that is being merged is the one case where the reviewer still has to act.
                        """),
                    comment("RC_demo_2", 9002, author, hoursAgo: 1.1, """
                        The merge ends the row either way — once it lands the parked review can no \
                        longer be submitted, and the conflict sheet still opens from Settings → Sync. \
                        I've written that down in the ADR amendment.
                        """),
                ]
            ),
            ReviewThread(
                id: "RT_demo_2",
                path: inboxList.path,
                line: 217,
                isResolved: true,
                comments: [
                    comment("RC_demo_3", 9003, other, hoursAgo: 2.8, "Does a retry that fails again toast?"),
                    comment("RC_demo_4", 9004, author, hoursAgo: 2.6, """
                        Yes — the drain posts the usual failure toast. Covered in 3f2c1ab.
                        """),
                ]
            ),
            ReviewThread(
                id: "RT_demo_3",
                path: session.path,
                line: 353,
                comments: [
                    comment("RC_demo_5", 9005, viewer, hoursAgo: 0.3, """
                        `try?` swallows a failed delete, and then the chip stays with no explanation. \
                        Can this surface the error the way `retryFailedWrites` does?
                        """),
                ]
            ),
        ]
    }

    private static func comment(
        _ id: String,
        _ databaseID: Int,
        _ author: Actor,
        hoursAgo: Double,
        _ body: String
    ) -> ReviewComment {
        ReviewComment(
            id: id,
            databaseID: databaseID,
            author: author,
            bodyMarkdown: body,
            createdAt: Date().addingTimeInterval(-hoursAgo * 3_600)
        )
    }

    // MARK: - Patch building

    /// One hunk with its header computed from its lines.
    /// - Parameters:
    ///   - old: The first old-side line, `0` for an added file.
    ///   - new: The first new-side line.
    ///   - lines: The hunk body, each line prefixed with `" "`, `"+"` or `"-"`.
    private static func hunk(old: Int, new: Int, _ lines: [String]) -> String {
        let oldCount = lines.filter { !$0.hasPrefix("+") }.count
        let newCount = lines.filter { !$0.hasPrefix("-") }.count
        return (["@@ -\(old),\(oldCount) +\(new),\(newCount) @@"] + lines).joined(separator: "\n")
    }
}

extension ChangedFile {
    /// A file whose counts are read off its patch, the way GitHub reports them.
    fileprivate init(path: String, status: FileChangeStatus, patch: String) {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        self.init(
            path: path,
            status: status,
            additions: lines.filter { $0.hasPrefix("+") }.count,
            deletions: lines.filter { $0.hasPrefix("-") }.count,
            patch: patch
        )
    }
}
#endif
