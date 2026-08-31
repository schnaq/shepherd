import Foundation

/// One commit on a pull request's head branch.
public struct CommitInfo: Sendable, Codable, Hashable, Identifiable {
    /// The commit SHA.
    public let oid: String
    /// The first line of the commit message.
    public var messageHeadline: String
    /// The full commit message body below the headline, if any.
    public var messageBody: String
    /// The commit author, when GitHub could resolve it to an account.
    public var author: Actor?
    /// When the commit was authored.
    public var committedDate: Date
    /// Trailer lines (`Key: value`) found in the commit message body.
    public var trailers: [String]

    /// Creates a commit.
    public init(
        oid: String,
        messageHeadline: String,
        messageBody: String = "",
        author: Actor? = nil,
        committedDate: Date,
        trailers: [String]? = nil
    ) {
        self.oid = oid
        self.messageHeadline = messageHeadline
        self.messageBody = messageBody
        self.author = author
        self.committedDate = committedDate
        self.trailers = trailers ?? CommitInfo.parseTrailers(in: messageBody)
    }

    /// `CommitInfo` is identified by its ``oid``.
    public var id: String { oid }

    /// Extracts `Key: value` trailer lines from a commit message body.
    ///
    /// Only lines that look like a git trailer are returned: a key made of letters and
    /// hyphens, a colon, a space and a non-empty value. Order is preserved.
    /// - Parameter body: The commit message body (everything below the headline).
    /// - Returns: The trailer lines, verbatim and trimmed.
    public static func parseTrailers(in body: String) -> [String] {
        var result: [String] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
            guard !key.isEmpty else { continue }
            let keyIsTrailerLike = key.allSatisfy { character in
                character.isLetter || character == "-"
            }
            guard keyIsTrailerLike else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            result.append(line)
        }
        return result
    }

    /// Splits a full commit message into headline and body.
    /// - Parameter message: The full commit message.
    /// - Returns: The first line and everything after it.
    public static func splitMessage(_ message: String) -> (headline: String, body: String) {
        guard let newline = message.firstIndex(of: "\n") else { return (message, "") }
        let headline = String(message[message.startIndex..<newline])
        let body = String(message[message.index(after: newline)...])
        return (headline, body)
    }
}
