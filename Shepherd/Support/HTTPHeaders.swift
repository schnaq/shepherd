import Foundation

extension Dictionary where Key == String, Value == String {
    /// One header's trimmed value, matched without regard to case, or `nil` when it is absent or
    /// blank.
    ///
    /// Field names are case-insensitive per RFC 9110 and `URLSession` does not promise a
    /// spelling, so every reader of a response header goes through here — ``IntelligenceRetryAfter``
    /// and ``ServedBy`` today.
    func headerValue(_ name: String) -> String? {
        for (key, value) in self where key.caseInsensitiveCompare(name) == .orderedSame {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// The HTTP-date parser, shared by every header that carries one (`Retry-After`, `Last-Modified`).
enum HTTPDate {
    /// Parses an IMF-fixdate, the one HTTP-date spelling a server is required to send.
    ///
    /// A fixed `en_US_POSIX` locale and a fixed GMT zone, because the format is fixed: reading it
    /// with the runner's locale is the classic way a date parser passes in Cupertino and fails in
    /// Berlin — and a user in a non-Gregorian region would get no date at all.
    /// - Parameter raw: The header value, e.g. `Wed, 21 Oct 2015 07:28:00 GMT`.
    /// - Returns: The date, or `nil` when the text is not an IMF-fixdate.
    static func parse(_ raw: String) -> Date? {
        formatter.date(from: raw)
    }

    /// Built once: `DateFormatter` is expensive to create, and this one is only used for parsing.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter
    }()
}
