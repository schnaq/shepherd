import Foundation

/// How a `429` with a `Retry-After` header becomes at most one short wait.
///
/// **Once, never a loop, and only when the endpoint named a delay a person will sit through.**
/// A rate-limited drafting request is the one failure in this layer where the endpoint has told
/// Shepherd exactly what to do about it, and doing nothing means a reviewer presses ✨ again a
/// second later and is refused again. But a retry policy is also the easiest way to spend
/// somebody's money and battery in a tight circle, so the rules are deliberately narrow:
///
/// - **one** retry, decided by the caller having no second call site rather than by a counter;
/// - a delay of at most ``maximumDelay``. A gateway that says "come back in five minutes" is
///   saying the request should fail now, and a spinner nobody can cancel for five minutes is not
///   a kindness;
/// - a delay of at least ``minimumDelay``, so a `Retry-After: 0` still lets the far side breathe;
/// - both RFC 9110 spellings, because the header is allowed to be either and a gateway relaying
///   an upstream refusal relays whatever the upstream sent: `delay-seconds` as an integer, or an
///   HTTP-date, which is honoured only when it falls inside the same ceiling;
/// - anything else — no header, a blank one, prose, a delay over the ceiling — is `nil`, and the
///   caller surfaces the `429` exactly as it surfaces every other status. A date already in the
///   past is a clock disagreement rather than a refusal to answer, so it reads as the shortest
///   wait rather than as no retry.
///
/// The parse is pure and the clock is a parameter, so the whole policy is unit-testable without
/// waiting for anything.
enum IntelligenceRetryAfter {
    /// The header field.
    static let header = "Retry-After"

    /// The longest wait worth making a reviewer sit through.
    static let maximumDelay: TimeInterval = 30

    /// The shortest wait that is still a wait.
    static let minimumDelay: TimeInterval = 1

    /// How long to wait before the single retry, or `nil` when there should not be one.
    /// - Parameters:
    ///   - headers: The response headers, keyed by field name in any spelling.
    ///   - now: The current instant. A parameter so an HTTP-date can be tested against a fixed
    ///     clock rather than against the runner's.
    /// - Returns: The delay in seconds, clamped into
    ///   ``minimumDelay``…``maximumDelay``, or `nil` when the header said nothing usable.
    static func delay(headers: [String: String], now: Date = Date()) -> TimeInterval? {
        guard let raw = IntelligenceRetryAfter.value(in: headers) else { return nil }
        if let seconds = Int(raw) {
            guard TimeInterval(seconds) <= maximumDelay else { return nil }
            return max(minimumDelay, TimeInterval(seconds))
        }
        guard let date = IntelligenceRetryAfter.httpDate(raw) else { return nil }
        let interval = date.timeIntervalSince(now)
        // A date in the past is a clock disagreement, not an instruction to wait: the shortest
        // wait is the honest reading of "you may go now".
        guard interval <= maximumDelay else { return nil }
        return max(minimumDelay, interval)
    }

    /// The header's trimmed value, matched without regard to case.
    private static func value(in headers: [String: String]) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare(header) == .orderedSame {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Parses an IMF-fixdate, the one HTTP-date spelling a server is required to send.
    ///
    /// A fixed `en_US_POSIX` locale and a fixed GMT zone, because the format is fixed: reading it
    /// with the runner's locale is the classic way a date parser passes in Cupertino and fails in
    /// Berlin.
    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: raw)
    }
}
