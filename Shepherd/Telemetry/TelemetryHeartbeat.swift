import Foundation

/// Whether today's `app_active_day` has already been sent (ADR 0036, § 1.1).
///
/// Shepherd stays open for weeks — the menu-bar inbox is the whole point — so an event fired at
/// launch would count the heaviest users least. The heartbeat fires at launch *and* whenever a
/// running app crosses UTC midnight, and this type is what stops two launches on one day from
/// counting twice.
///
/// What it stores is a date, not an identifier: it cannot distinguish this Mac from any other, it
/// is never sent, and it is deleted when telemetry is switched off.
@MainActor
final class TelemetryHeartbeat {
    /// Where the last sent day is remembered.
    static let lastDayKey = "telemetry.lastHeartbeatDay"

    private let defaults: UserDefaults

    /// Creates the heartbeat.
    /// - Parameter defaults: The store the day lives in.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the day-event is due.
    /// - Parameter now: The current moment.
    /// - Returns: `true` when nothing has been sent for this UTC day yet.
    func isDue(now: Date) -> Bool {
        defaults.string(forKey: Self.lastDayKey) != TelemetryDay.utcDay(now)
    }

    /// Records that the day-event has been queued for this UTC day.
    /// - Parameter now: The current moment.
    func markSent(now: Date) {
        defaults.set(TelemetryDay.utcDay(now), forKey: Self.lastDayKey)
    }

    /// Forgets the day, so the next launch counts again. Called when telemetry is switched off.
    func clear() {
        defaults.removeObject(forKey: Self.lastDayKey)
    }
}
