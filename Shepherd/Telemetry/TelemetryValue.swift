import Foundation

/// A property value that is allowed to leave the Mac (ADR 0036).
///
/// Three shapes and no fourth. There is no `case text(String)`, which is the point: the payload
/// cannot carry a repository name, a branch, a pull-request title or a path, because there is no
/// case that would hold one. The `choice` case does hold a `String`, but it can only be built from
/// a ``TelemetryChoice`` — an enum whose cases are written in this repository and reviewed like
/// any other code.
enum TelemetryValue: Equatable, Sendable {
    case flag(Bool)
    case number(Int)
    /// The raw value of a ``TelemetryChoice``. Build it with ``init(_:)``, never by hand.
    case choice(String)

    /// Wraps an enum case as a property value.
    /// - Parameter choice: The enum case to send.
    init(_ choice: some TelemetryChoice) {
        self = .choice(choice.rawValue)
    }
}

/// An enum whose cases may appear in a payload: a closed vocabulary with a stable raw value.
protocol TelemetryChoice: RawRepresentable<String>, CaseIterable, Sendable {}

extension TelemetryChoice {
    /// This case as a payload value.
    ///
    /// A property rather than only ``TelemetryValue/init(_:)``, and the difference is not style:
    /// the initialiser is generic, so every entry of a dictionary literal that uses it adds an
    /// overload-resolution problem to one constraint system. An eleven-entry literal mixing it
    /// with `.flag(_:)` is exactly the shape that makes the Swift type checker take exponential
    /// time — and how exponential depends on the compiler version, so it can pass on one Xcode
    /// and hang on another. Reading a property of a concrete type costs the solver nothing.
    var telemetryValue: TelemetryValue { .choice(rawValue) }
}

extension TelemetryValue: Codable {
    private enum Kind: String, Codable {
        case flag, number, choice
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flag(let flag):
            try container.encode(Kind.flag, forKey: .kind)
            try container.encode(flag, forKey: .value)
        case .number(let number):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(number, forKey: .value)
        case .choice(let raw):
            try container.encode(Kind.choice, forKey: .kind)
            try container.encode(raw, forKey: .value)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .flag: self = .flag(try container.decode(Bool.self, forKey: .value))
        case .number: self = .number(try container.decode(Int.self, forKey: .value))
        case .choice: self = .choice(try container.decode(String.self, forKey: .value))
        }
    }
}
