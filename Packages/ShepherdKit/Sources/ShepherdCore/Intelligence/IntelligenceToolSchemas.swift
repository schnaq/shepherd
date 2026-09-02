import Foundation

/// The JSON-schema object both cloud shapes wrap around a tool's parameters.
///
/// One type for the two providers, because the *schema* is the same in both: an object with
/// typed, described properties and a list of the required ones. Only the envelope differs
/// (``AnthropicToolSchema`` calls it `input_schema`, ``OpenAIToolSchema`` calls it `parameters`),
/// which is exactly the sort of difference that belongs in a wrapper rather than in two copies of
/// the schema builder.
///
/// A `Codable` struct rather than a `[String: Any]` dictionary, for the reason the whole contract
/// is: a value can be compared. The encoders are pinned by fixture tests that assert the exact
/// JSON, so a renamed parameter or a dropped `required` entry fails on Linux instead of
/// surfacing as a provider rejecting a request.
public struct IntelligenceToolJSONSchema: Codable, Sendable, Hashable {
    /// One property of the parameter object.
    public struct Property: Codable, Sendable, Hashable {
        /// The JSON type name (`string`, `integer`).
        public var type: String
        /// The sentence the model reads.
        public var description: String

        /// Creates a property.
        /// - Parameters:
        ///   - type: The JSON type name.
        ///   - description: The sentence for the model.
        public init(type: String, description: String) {
            self.type = type
            self.description = description
        }
    }

    /// Always `"object"`: a tool's arguments are a JSON object in both APIs.
    public var type: String
    /// The properties, keyed by argument name.
    public var properties: [String: Property]
    /// The names of the required arguments, sorted so the encoding is a pure function of the
    /// descriptor rather than of declaration order.
    public var required: [String]

    /// Creates a schema.
    /// - Parameters:
    ///   - type: The JSON type. Defaults to `"object"`.
    ///   - properties: The properties, keyed by argument name.
    ///   - required: The required argument names.
    public init(
        type: String = "object",
        properties: [String: Property] = [:],
        required: [String] = []
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    /// Derives the schema of one tool's parameters.
    /// - Parameter descriptor: The tool descriptor.
    public init(_ descriptor: IntelligenceToolDescriptor) {
        var properties: [String: Property] = [:]
        for parameter in descriptor.parameters {
            properties[parameter.name] = Property(
                type: parameter.type.jsonSchemaType,
                description: parameter.description
            )
        }
        self.init(
            properties: properties,
            required: descriptor.requiredParameterNames.sorted()
        )
    }
}

/// One tool in the shape Anthropic's Messages API takes: `{name, description, input_schema}`.
///
/// Lives in `ShepherdCore` rather than beside the provider so it can be fixture-tested on Linux.
/// The provider's only job is to put an array of these in the request body — no schema building
/// at the call site, which is what keeps the two providers from drifting apart in what they offer
/// the model.
public struct AnthropicToolSchema: Codable, Sendable, Hashable {
    /// The tool name the model calls.
    public var name: String
    /// What the tool does.
    public var description: String
    /// The parameter object.
    public var inputSchema: IntelligenceToolJSONSchema

    /// Creates a schema.
    /// - Parameters:
    ///   - name: The tool name.
    ///   - description: What the tool does.
    ///   - inputSchema: The parameter object.
    public init(name: String, description: String, inputSchema: IntelligenceToolJSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Renders a descriptor into the Anthropic shape.
    /// - Parameter descriptor: The tool descriptor.
    public init(_ descriptor: IntelligenceToolDescriptor) {
        self.init(
            name: descriptor.name.rawValue,
            description: descriptor.description,
            inputSchema: IntelligenceToolJSONSchema(descriptor)
        )
    }

    /// Every tool, in the registry's order — the array a request carries.
    public static var all: [AnthropicToolSchema] {
        IntelligenceToolRegistry.descriptors.map { AnthropicToolSchema($0) }
    }

    /// `input_schema` is snake_case on the wire and camelCase in Swift; the mapping is the whole
    /// reason this type has coding keys at all.
    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

/// One tool in the shape an OpenAI-compatible endpoint takes:
/// `{type: "function", function: {name, description, parameters}}`.
///
/// The nesting is the difference from the Anthropic shape, and it is the only difference: the
/// same descriptor, the same schema value, one envelope deeper.
public struct OpenAIToolSchema: Codable, Sendable, Hashable {
    /// The function half of the envelope.
    public struct Function: Codable, Sendable, Hashable {
        /// The tool name the model calls.
        public var name: String
        /// What the tool does.
        public var description: String
        /// The parameter object.
        public var parameters: IntelligenceToolJSONSchema

        /// Creates a function.
        /// - Parameters:
        ///   - name: The tool name.
        ///   - description: What the tool does.
        ///   - parameters: The parameter object.
        public init(
            name: String,
            description: String,
            parameters: IntelligenceToolJSONSchema
        ) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    /// Always `"function"`: the only tool type either endpoint offers that Shepherd uses.
    public var type: String
    /// The function.
    public var function: Function

    /// Creates a schema.
    /// - Parameters:
    ///   - type: The tool type. Defaults to `"function"`.
    ///   - function: The function.
    public init(type: String = "function", function: Function) {
        self.type = type
        self.function = function
    }

    /// Renders a descriptor into the OpenAI-compatible shape.
    /// - Parameter descriptor: The tool descriptor.
    public init(_ descriptor: IntelligenceToolDescriptor) {
        self.init(
            function: Function(
                name: descriptor.name.rawValue,
                description: descriptor.description,
                parameters: IntelligenceToolJSONSchema(descriptor)
            )
        )
    }

    /// Every tool, in the registry's order — the array a request carries.
    public static var all: [OpenAIToolSchema] {
        IntelligenceToolRegistry.descriptors.map { OpenAIToolSchema($0) }
    }
}
