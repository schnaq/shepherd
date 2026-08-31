import Foundation

/// Parsing and formatting of the ISO-8601 timestamps GitHub uses
/// (`2026-08-31T09:41:00Z`, occasionally with fractional seconds or an offset).
///
/// Implemented by hand rather than with `ISO8601DateFormatter` for two reasons: the formatter
/// classes are not `Sendable`, and creating one per timestamp is wasteful in a decoder that
/// sees hundreds of them per sweep. The civil-date arithmetic below is the standard
/// days-from-civil algorithm and is exact for all Gregorian dates.
public enum GitHubTimestamp {
    /// Parses an ISO-8601 timestamp.
    /// - Parameter string: The timestamp, e.g. `"2026-08-31T09:41:00Z"`.
    /// - Returns: The parsed date, or `nil` when the string is not a timestamp Shepherd
    ///   understands.
    public static func parse(_ string: String) -> Date? {
        let characters = Array(string)
        // Minimum shape: YYYY-MM-DDTHH:MM:SSZ
        guard characters.count >= 19 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard index < characters.count, let digit = characters[index].wholeNumberValue,
                      characters[index].isASCII, characters[index].isNumber else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard characters[4] == "-", characters[7] == "-",
              characters[10] == "T" || characters[10] == "t" || characters[10] == " ",
              characters[13] == ":", characters[16] == ":",
              let year = number(0..<4),
              let month = number(5..<7),
              let day = number(8..<10),
              let hour = number(11..<13),
              let minute = number(14..<16),
              let second = number(17..<19)
        else { return nil }

        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60 else { return nil }

        var index = 19
        var fraction: Double = 0
        if index < characters.count, characters[index] == "." || characters[index] == "," {
            index += 1
            var scale = 0.1
            while index < characters.count, let digit = characters[index].wholeNumberValue,
                  characters[index].isNumber {
                fraction += Double(digit) * scale
                scale /= 10
                index += 1
            }
        }

        var offsetSeconds = 0
        if index < characters.count {
            let marker = characters[index]
            if marker == "Z" || marker == "z" {
                offsetSeconds = 0
            } else if marker == "+" || marker == "-" {
                guard let offsetHour = number((index + 1)..<(index + 3)) else { return nil }
                var offsetMinute = 0
                if index + 4 < characters.count, characters[index + 3] == ":" {
                    offsetMinute = number((index + 4)..<(index + 6)) ?? 0
                } else if index + 5 <= characters.count {
                    offsetMinute = number((index + 3)..<(index + 5)) ?? 0
                }
                offsetSeconds = offsetHour * 3600 + offsetMinute * 60
                if marker == "-" { offsetSeconds = -offsetSeconds }
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Formats a date the way GitHub's `since` query parameters expect it.
    /// - Parameter date: The date to format.
    /// - Returns: An ISO-8601 timestamp in UTC with second precision, e.g.
    ///   `"2026-08-31T09:41:00Z"`.
    public static func string(from date: Date) -> String {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var days = total / 86_400
        var remainder = total % 86_400
        if remainder < 0 {
            remainder += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = remainder / 3_600
        let minute = (remainder % 3_600) / 60
        let second = remainder % 60
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            year, month, day, hour, minute, second
        )
    }

    // MARK: - Civil date arithmetic (Howard Hinnant's chrono algorithms)

    /// Days since 1970-01-01 for a proleptic Gregorian civil date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400                                   // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The proleptic Gregorian civil date for a count of days since 1970-01-01.
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097                                // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153                              // [0, 11]
        let day = dayOfYear - (153 * mp + 2) / 5 + 1                    // [1, 31]
        let month = mp + (mp < 10 ? 3 : -9)                             // [1, 12]
        return (year + (month <= 2 ? 1 : 0), month, day)
    }
}
