import Foundation

/// What kind of value a tool parameter takes.
///
/// Two cases, and that is a decision rather than a first instalment: the tools Shepherd lets a
/// model call are *reads* whose arguments are a check name, a file path and a line number
/// (`docs/plans/apple-intelligence-v2.md` §0.3). A nested object or an array would mean a schema
/// the validator below could no longer check by walking a flat list — and an argument shape the
/// three tools have no use for is an argument shape that cannot be validated against anything.
public enum IntelligenceToolParameterType: String, Codable, Sendable, Hashable, CaseIterable {
    /// A JSON string.
    case string
    /// A JSON integer.
    case integer

    /// The type name used in the JSON-schema shapes both cloud providers speak.
    public var jsonSchemaType: String { rawValue }
}

/// One argument a tool accepts, in the shape a JSON schema needs.
///
/// Deliberately *not* a `[String: Any]` schema fragment: the descriptors are static data that has
/// to encode into two different wire formats and be comparable in a test, so the parameter list is
/// a value with four fields and the wire shapes are derived from it
/// (``AnthropicToolSchema``, ``OpenAIToolSchema``). A schema Shepherd cannot compare byte for
/// byte is a schema whose drift nobody notices.
public struct IntelligenceToolParameter: Codable, Sendable, Hashable {
    /// The argument name, as it appears as a JSON object key in a tool call.
    public var name: String
    /// What the argument's value must be.
    public var type: IntelligenceToolParameterType
    /// One sentence for the model, describing what the argument means.
    public var description: String
    /// Whether a call that omits the argument is invalid.
    public var isRequired: Bool

    /// Creates a parameter.
    /// - Parameters:
    ///   - name: The argument name.
    ///   - type: The value type.
    ///   - description: One sentence for the model.
    ///   - isRequired: Whether the argument must be present. Defaults to `true`.
    public init(
        name: String,
        type: IntelligenceToolParameterType,
        description: String,
        isRequired: Bool = true
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }

    /// Stable keys: `required` on the wire, `isRequired` in Swift, because "is" reads wrong in a
    /// JSON schema and a Swift `Bool` reads wrong without it.
    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case description
        case isRequired = "required"
    }
}

/// A tool the model may call: its name, what it is for, and what it takes.
///
/// The name is the ``IntelligenceToolName`` enum rather than a string, which is the type-level
/// half of the plan's invariant that the registry is fixed: a descriptor cannot name a tool that
/// does not exist, and a tool cannot be added at runtime because there is no case to add it as.
public struct IntelligenceToolDescriptor: Codable, Sendable, Hashable {
    /// Which tool this describes.
    public var name: IntelligenceToolName
    /// What the tool does, in the words the model sees.
    public var description: String
    /// The arguments it accepts, in the order they are presented to the model.
    public var parameters: [IntelligenceToolParameter]

    /// Creates a descriptor.
    /// - Parameters:
    ///   - name: Which tool this describes.
    ///   - description: What the tool does.
    ///   - parameters: The arguments, in presentation order.
    public init(
        name: IntelligenceToolName,
        description: String,
        parameters: [IntelligenceToolParameter] = []
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The required arguments, in declaration order — the `required` array of a JSON schema.
    public var requiredParameterNames: [String] {
        parameters.filter(\.isRequired).map(\.name)
    }

    /// Looks an argument up by name.
    /// - Parameter name: The argument name.
    /// - Returns: The parameter, or `nil` when the tool has no such argument.
    public func parameter(named name: String) -> IntelligenceToolParameter? {
        parameters.first { $0.name == name }
    }
}

/// One argument value in a tool call.
///
/// A closed enum rather than `Any`, so the whole contract stays `Sendable`, `Hashable` and
/// comparable in a test. It codes as a *bare* JSON value (`"App build"`, `42`) rather than as a
/// tagged object, because that is what arrives from both cloud shapes and what has to be sent
/// back: the wire has no room for a discriminator, and inventing one here would mean translating
/// at every boundary.
public enum IntelligenceToolArgument: Codable, Sendable, Hashable {
    /// A JSON string.
    case string(String)
    /// A JSON integer.
    case integer(Int)

    /// The string value, or `nil` when the argument is an integer.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The integer value, or `nil` when the argument is a string.
    public var integerValue: Int? {
        if case let .integer(value) = self { return value }
        return nil
    }

    /// Which parameter type this value satisfies.
    public var type: IntelligenceToolParameterType {
        switch self {
        case .string: return .string
        case .integer: return .integer
        }
    }

    /// The value as one line of display text, for the trace the review screen expands.
    ///
    /// Unquoted on purpose: this is read by a human next to the argument's name
    /// (`path: Sources/App.swift`), not parsed by anything.
    public var displayText: String {
        switch self {
        case let .string(value): return value
        case let .integer(value): return String(value)
        }
    }

    /// Decodes a bare JSON value, integers before strings.
    ///
    /// The order matters and only in one direction: `JSONDecoder` will not read the string `"42"`
    /// as an `Int`, so trying the integer first cannot mis-type a string, while trying the string
    /// first would leave every integer to be caught by a fallback.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "A tool argument must be a JSON string or a JSON integer."
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }
}

/// A model's request to run one tool.
///
/// The tool name is a `String` rather than an ``IntelligenceToolName`` precisely because this
/// value comes *from* a model: the whole point of ``IntelligenceToolRegistry/validate(_:)`` is
/// that an unknown name is data to be rejected, not a state that cannot be represented. Nothing
/// downstream ever sees the raw name — the trace and the tools themselves take the enum.
public struct IntelligenceToolCall: Codable, Sendable, Hashable {
    /// The provider's id for this call, echoed back with the result so a multi-hop turn can be
    /// reassembled (`tool_use_id` for one cloud shape, `tool_calls[].id` for the other).
    public var id: String
    /// The tool the model asked for, as it spelled it.
    public var toolName: String
    /// The arguments, keyed by parameter name.
    public var arguments: [String: IntelligenceToolArgument]

    /// Creates a call.
    /// - Parameters:
    ///   - id: The provider's call id.
    ///   - toolName: The tool name as the model spelled it.
    ///   - arguments: The arguments, keyed by parameter name.
    public init(id: String, toolName: String, arguments: [String: IntelligenceToolArgument] = [:]) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }

    /// Creates a call for a known tool, for the app target and the tests.
    /// - Parameters:
    ///   - id: The provider's call id.
    ///   - tool: The tool.
    ///   - arguments: The arguments, keyed by parameter name.
    public init(
        id: String,
        tool: IntelligenceToolName,
        arguments: [String: IntelligenceToolArgument] = [:]
    ) {
        self.init(id: id, toolName: tool.rawValue, arguments: arguments)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case arguments
    }
}

/// What a tool answered: the text the model gets, plus what the reviewer is told it was.
///
/// ``content`` is *already budgeted* when this value exists — the tool decided what fits before
/// building it, which is the plan's rule that the model never sees a raw log or a raw file. The
/// two fields beside it exist so a truncation is never silent: ``summaryLine`` is what the trace
/// shows a human ("read 42 of 1,320 lines of App build (macOS)"), and ``wasTruncated`` says
/// whether anything was left out at all.
public struct IntelligenceToolResult: Codable, Sendable, Hashable {
    /// The ``IntelligenceToolCall/id`` this answers.
    public var callID: String
    /// The budgeted text handed to the model.
    public var content: String
    /// One line describing what the tool read, for the trace the reviewer expands.
    public var summaryLine: String
    /// Whether the tool had more to say than the budget allowed.
    public var wasTruncated: Bool

    /// Creates a result.
    /// - Parameters:
    ///   - callID: The call this answers.
    ///   - content: The budgeted text for the model.
    ///   - summaryLine: One line for the trace.
    ///   - wasTruncated: Whether content was left out.
    public init(
        callID: String,
        content: String,
        summaryLine: String,
        wasTruncated: Bool = false
    ) {
        self.callID = callID
        self.content = content
        self.summaryLine = summaryLine
        self.wasTruncated = wasTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case callID
        case content
        case summaryLine
        case wasTruncated
    }
}

/// Why a tool call was refused.
///
/// Refusals are values, not messages: nothing here is printed and nothing here is retried
/// automatically. The app turns one of these into a line the reviewer reads next to the trace,
/// and the model is told the call failed so it can answer from what it already has.
public enum IntelligenceToolError: Error, Sendable, Equatable {
    /// The model asked for a tool that does not exist. Carries the name it used.
    case unknownTool(String)
    /// A required argument was absent.
    case missingArgument(tool: IntelligenceToolName, argument: String)
    /// An argument was present with the wrong kind of value.
    case wrongArgumentType(
        tool: IntelligenceToolName,
        argument: String,
        expected: IntelligenceToolParameterType
    )
    /// The model invented an argument the tool does not accept.
    ///
    /// Refused rather than ignored: an argument nobody declared is an argument nobody validates,
    /// and the one thing this contract must not allow is free text travelling on a tool call.
    case unexpectedArgument(tool: IntelligenceToolName, argument: String)
    /// A `fileDiff` path that is not one of the pull request's changed files.
    ///
    /// The invariant from the plan, and the reason the registry needs the file list at all: no
    /// free text the model produced may reach GitHub, so the only path it can name is a path the
    /// diff already contains.
    case pathNotInChangedFiles(String)
}
