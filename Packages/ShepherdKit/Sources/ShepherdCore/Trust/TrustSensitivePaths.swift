import Foundation

/// The one exclusion the short-look lane carries: a diff that touches something dangerous is
/// never a short look, however small and however green (ADR 0027).
///
/// The classifications are ``FilePrioritizer``'s, not a second opinion about the same paths:
/// the security hints are its own `securityPathHints`, "is this a test file" is its
/// ``FilePrioritizer/category(of:)``, and the two surfaces therefore cannot come to different
/// conclusions about `Sources/Auth/Token.swift`. Two shapes the prioritiser scores but does not
/// *name* are named here, because the lane gate has to be able to state them: a CI workflow and
/// a database migration.
public enum TrustSensitivePaths {
    /// Path fragments that mark a schema migration.
    ///
    /// Deliberately fragments of a *directory or file name* rather than a general "migrate"
    /// substring: `Sources/Migration/` and `db/migrate/0007_add_column.sql` are migrations,
    /// `Sources/Onboarding/MigrationHintView.swift` is a view, and a rule that caught the third
    /// one would push half an app into the full-review lane.
    public static let migrationPathHints: [String] = [
        "/migrations/", "/migration/", "/migrate/", "/schema/",
    ]

    /// Whether one file makes the pull request a full review.
    /// - Parameters:
    ///   - file: The changed file.
    ///   - extraHints: Extra lowercase substrings from the user's settings, exactly as
    ///     ``PrioritizationContext/extraSecurityPathHints`` supplies them to the prioritiser.
    /// - Returns: `true` when the file is one of the four sensitive shapes.
    public static func isSensitive(_ file: ChangedFile, extraHints: [String] = []) -> Bool {
        let path = file.path.lowercased()
        let category = FilePrioritizer.category(of: file)

        // A deleted test is the shape the interview named explicitly, and it is the only one of
        // the four that is about the *status* rather than about the path.
        if file.status == .removed, category == .tests { return true }

        if path.hasPrefix(".github/workflows/") || path.contains("/.github/workflows/") {
            return true
        }

        if migrationPathHints.contains(where: { path.contains($0) }) { return true }
        // A migration directory at the root has no leading slash to match on.
        if migrationPathHints.contains(where: { path.hasPrefix(String($0.dropFirst())) }) {
            return true
        }

        // Generated content is exempt from the security hints for the prioritiser's reason: a
        // vendored bundle that happens to contain the word "token" is not the auth layer.
        guard category != .generated else { return false }
        let hints = FilePrioritizer.securityPathHints + extraHints.map { $0.lowercased() }
        return hints.contains { !$0.isEmpty && path.contains($0) }
    }

    /// Whether any of a pull request's files makes it a full review.
    /// - Parameters:
    ///   - files: The changed files, as the local database holds them. An **empty** list is
    ///     `false`: it means "this pull request changes nothing sensitive", not "we do not
    ///     know". Callers that have no diff at all pass `true` to the lane instead — see
    ///     ``TrustLaneInput/sensitivePaths``.
    ///   - extraHints: Extra lowercase substrings from the user's settings.
    /// - Returns: `true` when at least one file is sensitive.
    public static func contains(files: [ChangedFile], extraHints: [String] = []) -> Bool {
        files.contains { isSensitive($0, extraHints: extraHints) }
    }
}
