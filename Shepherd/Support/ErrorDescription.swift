import Foundation
import GitHubKit

extension Error {
    /// The words this error is allowed to say to a user.
    ///
    /// One rule, in one place, in three steps. A ``GitHubKit/GitHubError`` first, through its
    /// app-side rendering (`GitHubError.localizedMessage(bundle:)`): it *is* a `LocalizedError`,
    /// but its `errorDescription` comes from a Foundation-only package and is English by
    /// construction, so that order is the whole of the German user's fix (ADR 0022, 2026-09-22
    /// amendment). Then a ``Foundation/LocalizedError``'s own `errorDescription` — every error the
    /// app target defines has one, written for a reader and in the catalog — and
    /// `localizedDescription` otherwise, which is what a `URLError` or an SQLite error arrives
    /// with. Errors are never printed to the console (project rule), so this string *is* the
    /// report: it reaches a toast, a settings card's message line or an inline composer's error
    /// row.
    ///
    /// It used to be spelled out at each of those. One extension instead, so the surfaces cannot
    /// drift into answering the same question differently — and so a new one has one obvious
    /// thing to call rather than a line to copy.
    var userFacingDescription: String {
        if let github = self as? GitHubError {
            return github.localizedMessage()
        }
        return (self as? any LocalizedError)?.errorDescription ?? localizedDescription
    }
}
