import Foundation

/// The text a review finding becomes when it is addressed to the session that wrote the code
/// (ADR 0030).
///
/// One template, no options, and nothing Shepherd invented: the reviewer's own words, the place
/// they are about, and the pull request they belong to. It is shown verbatim in a confirmation
/// sheet before anything runs, which is why the composition is pure and tested — what the sheet
/// shows and what the CLI receives are the same string, produced once.
///
/// The text is **English and unlocalised on purpose.** It is not chrome: it is a prompt handed to
/// an agent, and the sheet that displays it says so in the reviewer's language around it.
/// Translating the frame would change what is sent depending on the Mac's language, which is
/// exactly what a message shown verbatim before sending must not do.
public enum SessionMessage {
    /// The finding the message is about.
    public struct Finding: Sendable, Equatable {
        /// The file the finding is anchored to, or `nil` for a review summary.
        public var path: String?
        /// The line, when the finding has one.
        public var line: Int?
        /// Exactly what the reviewer typed.
        public var text: String

        /// Creates a finding.
        /// - Parameters:
        ///   - path: The anchored file, if any.
        ///   - line: The anchored line, if any.
        ///   - text: The reviewer's text.
        public init(path: String? = nil, line: Int? = nil, text: String) {
            self.path = path
            self.line = line
            self.text = text
        }
    }

    /// Which pull request the finding is on.
    public struct PullRequestReference: Sendable, Equatable {
        /// `owner/name#number`.
        public var slug: String
        /// The pull request's web address, as a string so this stays platform-free.
        public var url: String

        /// Creates a reference.
        /// - Parameters:
        ///   - slug: `owner/name#number`.
        ///   - url: The pull request's web address.
        public init(slug: String, url: String) {
            self.slug = slug
            self.url = url
        }
    }

    /// Composes the message.
    ///
    /// The shape is fixed: a headline naming the pull request (and the review round when there
    /// is one), the location on its own line, the reviewer's text verbatim, and the link last.
    /// - Parameters:
    ///   - finding: What the reviewer wrote and where.
    ///   - pullRequest: Which pull request it is on.
    ///   - round: Which review round this is, when Shepherd knows.
    /// - Returns: The message, exactly as it will be sent.
    public static func compose(
        finding: Finding,
        pullRequest: PullRequestReference,
        round: Int? = nil
    ) -> String {
        var lines: [String] = []
        if let round, round > 0 {
            lines.append("Review finding on \(pullRequest.slug), review round \(round)")
        } else {
            lines.append("Review finding on \(pullRequest.slug)")
        }
        if let location = location(for: finding) {
            lines.append(location)
        }
        lines.append("")
        lines.append(finding.text.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append(pullRequest.url)
        return lines.joined(separator: "\n")
    }

    /// `path:line`, `path`, or nothing at all for a review summary.
    private static func location(for finding: Finding) -> String? {
        guard let path = finding.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        guard let line = finding.line else { return path }
        return "\(path):\(line)"
    }
}
