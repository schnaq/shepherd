import Foundation

/// Where a one-shot, user-initiated action stands: a connection test, a webhook test event, a
/// settings upload or download.
///
/// One type for all of them because the *view* is one view (``AsyncActionStatusLine``): every one
/// of these buttons shows nothing until it has run, a spinner while it runs, and one green or red
/// line afterwards. An action whose result is richer than a line of text models its own state
/// instead of widening this — ``SettingsModel/ModelListState`` is exactly that case, and stays
/// separate on purpose.
enum AsyncActionState: Equatable {
    /// Nothing run yet.
    case idle
    /// In flight.
    case running
    /// It worked, with a line to show.
    case success(String)
    /// It failed, with a line to show.
    case failure(String)
}
