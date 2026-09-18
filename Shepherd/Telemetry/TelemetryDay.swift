import Foundation

/// The only two date shapes telemetry knows: a UTC day, and that day's midnight (ADR 0036).
///
/// Everything is truncated to the day on purpose. Omitting the timestamp would let PostHog stamp
/// ingestion time, so a week offline would collapse onto one day; sending the full time would
/// describe working hours. The day is also what the heartbeat de-duplicates against, so having one
/// formatter for both keeps "today" from meaning two things.
enum TelemetryDay {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// `2026-09-18` in UTC.
    /// - Parameter date: The moment to describe.
    /// - Returns: The UTC day.
    static func utcDay(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// `2026-09` in UTC — what the reach identity rotates on.
    /// - Parameter date: The moment to describe.
    /// - Returns: The UTC month.
    static func utcMonth(_ date: Date) -> String { monthFormatter.string(from: date) }

    /// `2026-09-18T00:00:00Z`: the day's midnight, which is the only timestamp that is ever sent.
    /// - Parameter date: The moment to describe.
    /// - Returns: The ISO-8601 timestamp of that day's start.
    static func dayStartTimestamp(_ date: Date) -> String { "\(utcDay(date))T00:00:00Z" }
}
