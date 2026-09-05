import Foundation
import ShepherdCore

/// The spoken half of the native diff list: one localised sentence per row.
///
/// It sits here, in the app target, for ``EvidenceFactText``'s reason and no other. `ShepherdCore`
/// may not call `String(localized:)` — it is Foundation-only, it has to keep compiling and testing
/// on Linux, and it has no bundle to look a catalog up in — so the walk produces plain enum values
/// and this is the one place that turns them into prose. Every string here is a catalog key with a
/// German row: a diff read aloud in English to a German user is the failure ADR 0022 is about, and
/// this is the one surface in the app whose *whole point* is being read aloud.
///
/// What the sentence is made of, and why it is not simply everything:
///
/// - **A context row says nothing about its kind.** "Context. Line 41. Closing brace." two hundred
///   times is what makes a screen reader exhausting, and unchanged is the default — a reviewer
///   walking a diff learns nothing from being told, on nine rows out of ten, that this one is like
///   the others. Added and removed carry information and are announced. The asymmetry is
///   deliberate; it is not a case somebody forgot.
/// - **A row announces its own number, not the other side's.** A removed line has no head-side
///   number of its own (``ShepherdCore/PatchRow/headLine`` names the line the deletion sits *in
///   front of*), so it is announced as a base-side line. That is the same rule
///   ``DiffListContent/lineIdentity(of:)`` anchors a comment with, and it is read from there
///   rather than written a second time.
/// - **A row that cannot take a comment says so.** In "Since your review" the round narrows what
///   GitHub will accept, and a reviewer who presses `c` and hears nothing would have no way of
///   telling that from a key that did not arrive.
extension PatchReconstructor.DiffRow {
    /// The row as the one sentence VoiceOver reads.
    /// - Parameters:
    ///   - threadCount: How many published threads sit on this line.
    ///   - draftCount: How many of the reviewer's own unsent comments sit on it.
    ///   - takesComment: Whether the line may carry a comment at all.
    ///   - bundle: Where to look the catalog up. `Bundle.main` in the app; a test passes the
    ///     compiled `de.lproj` so what it asserts cannot depend on the runner's language.
    /// - Returns: The sentence, in the bundle's language.
    func spokenSentence(
        threadCount: Int = 0,
        draftCount: Int = 0,
        takesComment: Bool = true,
        bundle: Bundle = .main
    ) -> String {
        switch self {
        case .hunk(let originalStart, let modifiedStart):
            // The one row that is a *place* rather than a line. Monaco draws "@@ -12,7 +12,9 @@"
            // and reads it out as punctuation; this says what it means, which is the only thing a
            // hunk header is for.
            return String(
                localized:
                    "Hunk starting at base line \(originalStart) and head line \(modifiedStart).",
                bundle: bundle
            )
        case .line(let row):
            let identity = DiffListContent.lineIdentity(of: row)
            return SpokenRow.sentence([
                Self.kind(of: row, bundle: bundle),
                Self.number(identity.line, on: identity.side, bundle: bundle),
                row.text,
                threadCount > 0 ? Self.threads(count: threadCount, bundle: bundle) : nil,
                draftCount > 0 ? Self.drafts(count: draftCount, bundle: bundle) : nil,
                takesComment
                    ? nil
                    : String(
                        localized: "No comment can be left on this line.",
                        bundle: bundle
                    ),
            ])
        }
    }

    /// What the row did to the file, or `nil` for a context row.
    /// - Parameters:
    ///   - row: The line.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The word, or `nil`.
    private static func kind(of row: PatchRow, bundle: Bundle) -> String? {
        switch row.kind {
        case .added: return String(localized: "Added", bundle: bundle)
        case .removed: return String(localized: "Removed", bundle: bundle)
        case .context: return nil
        }
    }

    /// The row's own line number, named by the side it belongs to.
    /// - Parameters:
    ///   - line: The number.
    ///   - side: Which side it is a number on.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The phrase.
    private static func number(_ line: Int, on side: DiffSide, bundle: Bundle) -> String {
        // The head side is the file as it will be, which is what a reviewer reads, so it is the
        // unqualified "line 42". The base side is only ever reached by a deleted line, and there
        // the qualification is the point: it is a number in a file that no longer says that.
        side == .left
            ? String(localized: "Base line \(line).", bundle: bundle)
            : String(localized: "Line \(line).", bundle: bundle)
    }

    /// How many published threads hang on the line.
    ///
    /// Two keys picked on the count rather than one plural variation, the shape
    /// ``EvidenceFactText`` uses: it keeps the singular a sentence a translator can write freely
    /// rather than a slot in a table.
    /// - Parameters:
    ///   - count: How many there are; never zero at this call.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The phrase.
    private static func threads(count: Int, bundle: Bundle) -> String {
        count == 1
            ? String(localized: "1 comment thread.", bundle: bundle)
            : String(localized: "\(count) comment threads.", bundle: bundle)
    }

    /// How many of the reviewer's own unsent comments hang on the line.
    /// - Parameters:
    ///   - count: How many there are; never zero at this call.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The phrase.
    private static func drafts(count: Int, bundle: Bundle) -> String {
        count == 1
            ? String(localized: "1 pending comment.", bundle: bundle)
            : String(localized: "\(count) pending comments.", bundle: bundle)
    }
}
