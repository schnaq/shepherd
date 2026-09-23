import Foundation

/// Names the branch a free-text agent task on a repository works on (ADR 0011's 2026-09-23
/// amendment).
///
/// The issue path names its branch after the issue (`agent/issue-128`); a task typed into a sheet
/// has no number, so its branch is named after its words: *"Fix the flaky login test"* becomes
/// `agent/fix-the-flaky-login-test`. **Shepherd** names it rather than the assistant, for the
/// issue path's reason — a name the app can predict is one it can show in the sheet, put in the
/// preamble and push from the button.
///
/// Unlike an issue, a task is never "the same work again": two tasks that happen to start with the
/// same words are two pieces of work, and the issue path's *resume an existing branch* would land
/// the second on top of the first. So a name that is already taken is **uniqued** with a short
/// suffix rather than reused, and that decision is made here, before git is asked to create
/// anything.
///
/// Pure and Foundation-only, so the slug rules are pinned by tests on the Linux runner.
public enum RepositoryTaskBranch {
    /// The namespace every agent branch lives in, shared with the issue path.
    public static let prefix = "agent/"
    /// The longest slug, suffix included — short enough to read in a chip and a `git branch`.
    public static let maximumSlugLength = 40
    /// The slug of a task with no usable characters at all (`"???"`, an emoji, Cyrillic).
    public static let fallbackSlug = "task"

    /// A branch-safe slug for a task: lowercase ASCII letters and digits, runs of anything else
    /// collapsed to one dash, at most ``maximumSlugLength`` characters, never starting or ending
    /// with a dash.
    ///
    /// Only the first line is read — it is the one that says what the task is, and everything
    /// after it is detail. Accented letters keep their base letter (*"Übersetzung prüfen"* →
    /// `ubersetzung-prufen`) rather than vanishing, and a cut at the length limit backs up to the
    /// last dash when there is one, so a word is not left half-spelled.
    /// - Parameter task: The task text as typed.
    public static func slug(from task: String) -> String {
        let firstLine = task
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        var slug = ""
        var pendingDash = false
        for scalar in firstLine.decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.append(Character(scalar).lowercased())
            } else if scalar.properties.isDiacritic || scalar.properties.generalCategory == .nonspacingMark {
                // The combining half of a decomposed "ü": dropping it keeps the "u".
                continue
            } else {
                pendingDash = true
            }
        }
        return truncated(slug, to: maximumSlugLength)
    }

    /// `agent/<slug>`.
    /// - Parameter slug: A slug from ``slug(from:)`` or ``unique(_:isTaken:suffix:)``.
    public static func branchName(slug: String) -> String { prefix + slug }

    /// The slug itself when it is free, or the slug with a short suffix when it is not.
    ///
    /// The suffix is injected so the tests can be deterministic; the app hands in four random hex
    /// digits. Tries a handful of suffixes and gives up with `nil` rather than looping forever on
    /// an `isTaken` that answers `true` for everything.
    /// - Parameters:
    ///   - slug: The preferred slug.
    ///   - isTaken: Whether a slug already names a branch or a worktree directory.
    ///   - suffix: A fresh short suffix per call.
    /// - Returns: A slug no branch or directory uses, or `nil` after five collisions.
    public static func unique(
        _ slug: String,
        isTaken: (String) -> Bool,
        suffix: () -> String
    ) -> String? {
        guard isTaken(slug) else { return slug }
        for _ in 0..<5 {
            let tail = suffix()
            let head = truncated(slug, to: maximumSlugLength - tail.count - 1)
            let candidate = head.isEmpty ? tail : "\(head)-\(tail)"
            if !isTaken(candidate) { return candidate }
        }
        return nil
    }

    /// Four lowercase hex digits, for ``unique(_:isTaken:suffix:)``.
    public static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: .min ... .max))
    }

    /// Cuts a slug to a length, backing up to a dash when the cut lands inside a word.
    private static func truncated(_ slug: String, to length: Int) -> String {
        guard length > 0 else { return "" }
        var result = slug
        if result.count > length {
            result = String(result.prefix(length))
            // Back up to the last word boundary, unless that would leave almost nothing.
            if let dash = result.lastIndex(of: "-"), result.distance(from: result.startIndex, to: dash) >= length / 2 {
                result = String(result[..<dash])
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        while result.hasPrefix("-") { result.removeFirst() }
        return result.isEmpty ? fallbackSlug : result
    }
}
