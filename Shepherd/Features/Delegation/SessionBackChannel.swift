import Foundation
import ShepherdCore
import ShepherdPersistence

/// The session back-channel's decisions, as values (ADR 0030).
///
/// Everything a reviewer's press does is decided here rather than in the two composers: which
/// button they get, what the confirmation sheet shows, and what the delegation is handed. The
/// views own no state of their own, which is why the whole feature is testable without a window.
enum SessionBackChannel {
    /// What the second button beside "Add comment" offers, or `nil` when it is not shown at all.
    enum Action: Equatable {
        /// A command is configured for this kind of session: confirm the message, then run it.
        case send(SessionReference)
        /// No command is configured, but the trailer carried a URL: offer the link instead.
        ///
        /// This is the shipped state for a remote session, and it is deliberately not a
        /// degraded version of the other one — a link the reviewer clicks is still one step less
        /// than copying a comment into a browser, and it asks Shepherd for no credential at all.
        case open(SessionReference, URL)
    }

    /// Decides which button a finding gets.
    ///
    /// Three inputs, all known before the click: whether the head commits carry a return
    /// address, whether a command is configured for that kind of session, and whether the
    /// trailer left a URL to fall back to. A local session with the local template cleared and
    /// no URL gets **no** button — there is nothing to offer and nothing to link to.
    /// - Parameters:
    ///   - session: The return address, when the pull request has one.
    ///   - configuration: The delegation settings the two templates live in.
    /// - Returns: The action, or `nil` when the button stays away.
    static func action(
        session: SessionReference?,
        configuration: AgentCLIConfiguration
    ) -> Action? {
        guard let session else { return nil }
        if configuration.canSendToSession(kind: session.kind) { return .send(session) }
        if let url = session.url { return .open(session, url) }
        return nil
    }

    /// Everything one Send needs: the message, and the delegation it opens.
    ///
    /// Built once and used twice — the sheet shows ``message`` verbatim and the run receives the
    /// same string — because "what you were shown is what was sent" is only true if there is one
    /// composition, not two.
    struct Plan: Equatable {
        /// The message, exactly as the sheet shows it and the CLI receives it.
        var message: String
        /// The delegation to open, carrying the return address.
        var context: DelegationContext

        /// The session the message goes to.
        var session: SessionReference? { context.session }
    }

    /// Builds the plan for one finding.
    /// - Parameters:
    ///   - summary: The pull request the finding is on.
    ///   - session: The return address.
    ///   - path: The anchored file, or `nil` for the review summary.
    ///   - line: The anchored line, when there is one.
    ///   - text: Exactly what the reviewer typed.
    ///   - round: Which review round this is, when Shepherd knows (ADR 0028).
    /// - Returns: The plan.
    static func plan(
        summary: PullRequestSummary,
        session: SessionReference,
        path: String?,
        line: Int?,
        text: String,
        round: Int? = nil
    ) -> Plan {
        let message = SessionMessage.compose(
            finding: SessionMessage.Finding(path: path, line: line, text: text),
            pullRequest: SessionMessage.PullRequestReference(
                slug: summary.slug,
                url: AppConfig.pullRequestURL(
                    owner: summary.repo.owner,
                    name: summary.repo.name,
                    number: summary.number
                ).absoluteString
            ),
            round: round
        )
        return Plan(
            message: message,
            context: .sessionFinding(
                summary,
                session: session,
                path: path,
                line: line,
                text: text
            )
        )
    }
}

/// Reads the inbox's return addresses out of the local cache (ADR 0030).
///
/// The glyph on a row is a fact about commits, and commits live in the detail rows the sync
/// engine has already written — so this is a *local* read and never a fetch. Rows nobody has
/// opened yet have no detail and therefore no glyph, which is the honest answer: Shepherd does
/// not know whether they have a return address.
enum SessionReturnAddressLoader {
    /// How many rows one refresh is willing to read a detail for.
    ///
    /// The same cap and the same reasoning as ``SinceReviewLoader/inboxRowLimit``: the glyph is a
    /// nicety on a list that has to stay instant.
    static let inboxRowLimit = 40

    /// The return address of each row that has one.
    /// - Parameters:
    ///   - database: The local source of truth.
    ///   - rows: The inbox rows, in display order.
    /// - Returns: One entry per row whose cached head commits carry a `Claude-Session:` trailer.
    static func references(
        database: DatabaseManager,
        rows: [PullRequestSummary]
    ) async -> [String: SessionReference] {
        var result: [String: SessionReference] = [:]
        var read = 0
        for row in rows {
            // Machine-authored rows only: a return address is a fact about an agent's commits,
            // and reading every human pull request's detail to find none would be work spent on
            // an answer that is known in advance (ADR 0008's facet).
            guard row.author.kind.isMachine else { continue }
            guard read < inboxRowLimit else { break }
            read += 1
            guard let detail = try? await database.fetchPullRequestDetail(id: row.id),
                  let reference = SessionReference.mostRecent(in: detail.commits)
            else { continue }
            result[row.id] = reference
        }
        return result
    }
}
