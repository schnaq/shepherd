import Foundation

extension Error {
    /// The words this error is allowed to say to a user.
    ///
    /// One rule, in one place: a ``Foundation/LocalizedError``'s own `errorDescription` when it
    /// has one — every error Shepherd defines does, and that sentence is written for a reader —
    /// and `localizedDescription` otherwise, which is what a `URLError` or an SQLite error
    /// arrives with. Errors are never printed to the console (project rule), so this string *is*
    /// the report: it reaches a toast, a settings card's message line or an inline composer's
    /// error row.
    ///
    /// It used to be spelled out at each of those. One extension instead, so the four surfaces
    /// cannot drift into answering the same question differently — and so a fifth has one obvious
    /// thing to call rather than a line to copy.
    var userFacingDescription: String {
        (self as? any LocalizedError)?.errorDescription ?? localizedDescription
    }
}
