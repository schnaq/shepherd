import Foundation

/// One named, reusable piece of review text — a "saved reply".
///
/// The point of the type is that reviewing the flood of agent pull requests is *repetitive*: the
/// same "please add a test for this branch", the same "this looks like generated code, keep it out
/// of the diff", the same nit about naming, twenty times a week. A saved reply is the smallest
/// value that makes that repetition a single click: a ``name`` the user recognises in a menu and a
/// ``body`` that is inserted verbatim into whichever composer is open.
///
/// The body is Markdown *source*, exactly like ``DraftComment/body`` and ``ReviewDraft/summaryBody``
/// — it is inserted into the same fields the user types into, so it is never rendered, escaped or
/// interpreted on the way in.
public struct SavedReply: Sendable, Codable, Hashable, Identifiable {
    /// Stable identity, so renaming a reply keeps it the same row in Settings.
    public let id: UUID
    /// The name shown in the insert menu and in Settings.
    public var name: String
    /// The Markdown source inserted into the composer.
    public var body: String

    /// Creates a saved reply.
    /// - Parameters:
    ///   - id: Stable identity. A fresh one by default.
    ///   - name: The name shown in the insert menu.
    ///   - body: The Markdown source to insert.
    public init(id: UUID = UUID(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    /// The name without surrounding whitespace.
    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body without surrounding whitespace.
    public var trimmedBody: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the reply is worth offering: it has both a name to click and something to insert.
    ///
    /// The editor refuses to save anything else, but a document written by another build (or a
    /// half-finished row from an older one) may still carry one, and an unnamed empty entry in the
    /// insert menu is worse than no entry at all.
    public var isUsable: Bool {
        !trimmedName.isEmpty && !trimmedBody.isEmpty
    }

    /// The text of a composer after a saved reply has been inserted into it.
    ///
    /// **Append, not insert-at-cursor.** SwiftUI's `TextEditor` exposes neither the selection nor
    /// the insertion point, and `TextField` does not either; the only ways to a real caret offset
    /// are an `NSViewRepresentable` around `NSTextView` or a private-ish focus hack, and both would
    /// replace every review text field in the app to buy one convenience. So the reply is appended
    /// to what is already there, separated by a blank line, which is both predictable ("it goes at
    /// the end") and lossless ("it never overwrites what I typed"). The user can then move it.
    ///
    /// Trailing whitespace of the existing text is dropped so that clicking twice produces exactly
    /// one blank line between the two bodies rather than a growing gap.
    /// - Parameters:
    ///   - body: The reply body to add.
    ///   - text: What the composer holds right now.
    /// - Returns: The composer's new text.
    public static func inserting(_ body: String, into text: String) -> String {
        let reply = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return text }
        // `while` rather than a single trim call: the existing text keeps its *leading* whitespace
        // (the user may be writing an indented code block) and loses only what would collide with
        // the separator.
        var existing = text
        while let last = existing.last, last.isWhitespace {
            existing.removeLast()
        }
        guard !existing.isEmpty else { return reply }
        return "\(existing)\n\n\(reply)"
    }
}
