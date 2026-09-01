import Foundation

/// The span one digest reports on.
public struct DigestWindow: Sendable, Equatable {
    /// The start of the span: the previous digest, or a first-run look-back.
    public let start: Date
    /// The end of the span, which is "now".
    public let end: Date
    /// Whether this is the first digest this Mac has ever delivered, so ``start`` is the
    /// look-back rather than a real previous digest.
    public let isFirstEver: Bool

    /// Creates a window.
    /// - Parameters:
    ///   - start: The start of the span.
    ///   - end: The end of the span.
    ///   - isFirstEver: Whether this is the first digest on this Mac.
    public init(start: Date, end: Date, isFirstEver: Bool) {
        self.start = start
        self.end = end
        self.isFirstEver = isFirstEver
    }
}

/// When the morning digest is delivered — the whole of the scheduling decision, as a value.
///
/// There is no launch agent, no daemon and no background task behind this. The app checks a cheap
/// pure function once a minute (`Features/Digest/DigestCoordinator.swift`) and that function is
/// this one, which is what makes the awkward parts testable rather than discoverable: a Mac that
/// was asleep at nine, a Saturday, a user who moves the time while the day is half over, a clock
/// that jumps backwards.
///
/// Off on a fresh install — ``isEnabled`` is the master switch, exactly as
/// `AutoDelegationRules.isEnabled` gates auto-delegation (ADR 0016) and `webhooksEnabled` gates
/// webhooks (ADR 0012). With it false this type answers `nil` and nothing else in the digest path
/// runs at all.
public struct DigestSchedule: Sendable, Codable, Hashable {
    /// The hour a fresh install delivers at.
    public static let defaultHour = 9
    /// The minute a fresh install delivers at.
    public static let defaultMinute = 0

    /// How far back the *first* digest on a Mac looks.
    ///
    /// Sixteen hours, so a nine-o'clock first run covers "since I stopped working yesterday"
    /// rather than "since midnight", which would miss the evening an agent spent opening pull
    /// requests.
    public static let firstWindow: TimeInterval = 16 * 60 * 60

    /// The longest span a digest ever reports on.
    ///
    /// A holiday should not turn the morning digest into a three-week backlog report: the inbox is
    /// where a backlog belongs, and a notification claiming "84 new review requests" is not a
    /// brief. Seven days is the cap.
    public static let maxWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Whether the digest is delivered at all. Off on a fresh install.
    public var isEnabled: Bool
    /// The delivery hour in the Mac's own time zone, 0…23.
    public var hour: Int
    /// The delivery minute, 0…59.
    public var minute: Int
    /// Whether Saturdays and Sundays are skipped.
    ///
    /// On by default, which is the *quieter* of the two: a morning digest is a work ritual, and the
    /// user who wants one at the weekend can say so.
    public var weekdaysOnly: Bool

    /// Creates a schedule.
    /// - Parameters:
    ///   - isEnabled: Whether the digest is delivered.
    ///   - hour: The delivery hour, 0…23.
    ///   - minute: The delivery minute, 0…59.
    ///   - weekdaysOnly: Whether weekends are skipped.
    public init(
        isEnabled: Bool = false,
        hour: Int = DigestSchedule.defaultHour,
        minute: Int = DigestSchedule.defaultMinute,
        weekdaysOnly: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.weekdaysOnly = weekdaysOnly
    }

    /// The delivery hour, clamped into range.
    ///
    /// Clamped rather than validated at the setter, for the same reason
    /// `AutoDelegationRules.dailyCap` is: the value can arrive from a settings document written by
    /// another build (ADR 0014), and a nonsensical hour must degrade to a sane delivery time rather
    /// than to no delivery at all.
    public var normalizedHour: Int { min(23, max(0, hour)) }

    /// The delivery minute, clamped into range.
    public var normalizedMinute: Int { min(59, max(0, minute)) }

    // MARK: - The due rule

    /// The moment the digest is due on the calendar day of `day`.
    /// - Parameters:
    ///   - day: Any moment on the day in question.
    ///   - calendar: The calendar, which carries the time zone. Injected so the tests are not at
    ///     the mercy of the machine they run on.
    /// - Returns: The delivery moment, or `nil` when the calendar cannot build one.
    public func deliveryTime(on day: Date, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = normalizedHour
        parts.minute = normalizedMinute
        parts.second = 0
        return calendar.date(from: parts)
    }

    /// Whether a moment falls on a Saturday or a Sunday.
    ///
    /// By weekday number rather than `Calendar.isDateInWeekend(_:)`: the toggle is called "weekdays
    /// only" and means Monday to Friday, the numbers are fixed for the Gregorian calendar family
    /// (1 = Sunday, 7 = Saturday), and the answer is then identical on both runners ShepherdKit is
    /// tested on. A locale-defined weekend would make the due rule platform-dependent, which is a
    /// bad property for the one function that decides whether a notification fires.
    /// - Parameters:
    ///   - date: The moment to test.
    ///   - calendar: The calendar, which carries the time zone.
    public static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Whether a digest is due right now, and if so what span it covers.
    ///
    /// The checks run in a fixed order, so the answer never depends on evaluation order:
    ///
    /// 1. switched off → no;
    /// 2. today's delivery time has not arrived yet → no. This is also what makes a *missed*
    ///    delivery work: at 11:30 with a nine-o'clock schedule the answer is still yes, because the
    ///    comparison is against today's nine o'clock and not against a timer that was asleep;
    /// 3. weekends, when the user asked for weekdays only → no. Note that a Friday digest missed
    ///    over the weekend is **not** delivered on Saturday and not "caught up" on Monday either:
    ///    Monday delivers *Monday's* digest, whose window reaches back to the last one, so nothing
    ///    is lost and there is still exactly one digest a day;
    /// 4. a digest was already delivered at or after today's delivery time, or anywhere on today's
    ///    calendar day → no. Two conditions rather than one, and both are needed: the first catches
    ///    the ordinary "already done today", the second catches a user who moves the time forward
    ///    at lunchtime and would otherwise get a second digest the same afternoon.
    ///
    /// - Parameters:
    ///   - now: The clock.
    ///   - lastDeliveredAt: When this Mac last delivered a digest, or `nil` if it never has. Device
    ///     state that deliberately does not travel between Macs.
    ///   - calendar: The calendar, which carries the time zone.
    /// - Returns: The window to report on, or `nil` when nothing is due.
    public func window(
        now: Date,
        lastDeliveredAt: Date?,
        calendar: Calendar
    ) -> DigestWindow? {
        guard isEnabled else { return nil }
        guard let due = deliveryTime(on: now, calendar: calendar) else { return nil }
        guard now >= due else { return nil }
        if weekdaysOnly, Self.isWeekend(due, calendar: calendar) { return nil }
        if let lastDeliveredAt {
            guard lastDeliveredAt < due else { return nil }
            guard !calendar.isDate(lastDeliveredAt, inSameDayAs: due) else { return nil }
        }

        let earliest = now.addingTimeInterval(-Self.maxWindow)
        guard let lastDeliveredAt else {
            return DigestWindow(
                start: max(now.addingTimeInterval(-Self.firstWindow), earliest),
                end: now,
                isFirstEver: true
            )
        }
        return DigestWindow(
            start: max(lastDeliveredAt, earliest),
            end: now,
            isFirstEver: false
        )
    }

    // MARK: - Storage

    private enum CodingKeys: String, CodingKey {
        case isEnabled, hour, minute, weekdaysOnly
    }

    /// Decodes tolerantly, like ``AutoDelegationRules``: a schedule written by an older or a newer
    /// build is missing keys, and a missing key falls back to the default rather than throwing the
    /// whole schedule — and with it the user's opt-in — away.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled))
            .flatMap { $0 } ?? false
        hour = (try? container.decodeIfPresent(Int.self, forKey: .hour))
            .flatMap { $0 } ?? Self.defaultHour
        minute = (try? container.decodeIfPresent(Int.self, forKey: .minute))
            .flatMap { $0 } ?? Self.defaultMinute
        weekdaysOnly = (try? container.decodeIfPresent(Bool.self, forKey: .weekdaysOnly))
            .flatMap { $0 } ?? true
    }
}
