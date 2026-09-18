import Foundation

/// What goes in `distinct_id`, and how little of it survives (ADR 0036).
///
/// The two levels differ here and nowhere else. At `anonymous` the value is a UUID created when
/// this object is created — one per launch, never written down, gone when the process ends. At
/// `reach` it is a UUID stored alongside the UTC month it was minted in; when the month turns, the
/// old value is overwritten by a fresh random one. There is deliberately **no** root secret and no
/// hash: a derived identity could be recomputed for a past month, and a random one cannot, so
/// September and October are unlinkable to us as much as to anyone else.
@MainActor
final class TelemetryIdentity {
    /// Where the monthly value lives. `UserDefaults`, not the Keychain: it is not a secret, it is
    /// a value we want *deletable* — and "Sign out & erase local data" must be able to remove it.
    static let identityKey = "telemetry.monthlyIdentity"
    /// The UTC month the stored value was minted in.
    static let monthKey = "telemetry.monthlyIdentityMonth"

    private let defaults: UserDefaults
    private let launchIdentity = UUID().uuidString

    /// Creates the identity source.
    /// - Parameter defaults: The store the monthly value lives in. Injected so tests never touch
    ///   the user's own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The identifier to send.
    /// - Parameters:
    ///   - level: The current level. `off` never reaches here; `anonymous` gets the in-memory
    ///     value, `reach` the stored one.
    ///   - now: The moment the event happened, which decides the month.
    /// - Returns: The `distinct_id`.
    func distinctID(for level: TelemetryLevel, now: Date) -> String {
        guard level.usesStoredIdentity else { return launchIdentity }

        let month = TelemetryDay.utcMonth(now)
        if defaults.string(forKey: Self.monthKey) == month,
           let stored = defaults.string(forKey: Self.identityKey) {
            return stored
        }

        let minted = UUID().uuidString
        defaults.set(minted, forKey: Self.identityKey)
        defaults.set(month, forKey: Self.monthKey)
        return minted
    }

    /// Deletes the stored monthly value. Called when the level leaves `reach` — withdrawal erases,
    /// it does not merely stop.
    func clearStoredIdentity() {
        defaults.removeObject(forKey: Self.identityKey)
        defaults.removeObject(forKey: Self.monthKey)
    }
}
