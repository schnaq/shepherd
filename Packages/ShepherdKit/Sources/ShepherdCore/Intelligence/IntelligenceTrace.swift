import Foundation

/// One hop of a tool-calling turn, in the shape the review screen renders it.
///
/// A *display* record, not an audit log: it holds the rendered arguments and the tool's own
/// summary line rather than the budgeted content the model was given, because what a reviewer
/// needs from an expanded step is "what did it look at, and what did it find" — and because a
/// trace that carried the content would carry a log tail into whatever the UI does with its
/// state. Nothing here is persisted (the plan: "stored nowhere; lives with the card").
///
/// ``order`` is a field rather than an array index so a step stays self-describing once the UI has
/// it: a disclosure row that was handed a single step still knows it is the third one.
public struct IntelligenceTraceStep: Codable, Sendable, Hashable {
    /// The step's position in the turn, counting from zero.
    public var order: Int
    /// Which tool ran. The enum, not a string: only a validated call becomes a step.
    public var toolName: IntelligenceToolName
    /// The arguments as one line of display text, e.g. `path: Sources/App.swift, line: 42`.
    public var argumentsDisplay: String
    /// The tool's one-line description of what it read.
    public var summaryLine: String
    /// How long the hop took, in seconds.
    public var duration: TimeInterval

    /// Creates a step.
    /// - Parameters:
    ///   - order: Position in the turn, counting from zero.
    ///   - toolName: Which tool ran.
    ///   - argumentsDisplay: The rendered arguments.
    ///   - summaryLine: The tool's summary line.
    ///   - duration: How long the hop took, in seconds.
    public init(
        order: Int,
        toolName: IntelligenceToolName,
        argumentsDisplay: String,
        summaryLine: String,
        duration: TimeInterval
    ) {
        self.order = order
        self.toolName = toolName
        self.argumentsDisplay = argumentsDisplay
        self.summaryLine = summaryLine
        self.duration = duration
    }

    /// Renders a call's arguments as one line, sorted by argument name.
    ///
    /// Sorted because a `Dictionary` has no order and a trace whose first row reads
    /// `line: 42, path: …` on one run and the other way round on the next looks like a bug.
    /// Values are unquoted: this is read, not parsed.
    /// - Parameter arguments: The call's arguments.
    /// - Returns: `"name: value, name: value"`, or `""` for a tool that takes none.
    public static func renderArguments(_ arguments: [String: IntelligenceToolArgument]) -> String {
        arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displayText)" }
            .joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey {
        case order
        case toolName
        case argumentsDisplay
        case summaryLine
        case duration
    }
}

/// Every hop of one tool-calling turn, in the order it happened.
///
/// The trace is what makes a tool-calling answer inspectable instead of magic: the plan's UI for
/// "Why is CI red?" is a card whose steps expand to show exactly what the model was allowed to
/// see. Appending is the only way to grow one, and appending is what assigns ``order``, so the
/// numbering cannot disagree with the sequence.
public struct IntelligenceTrace: Codable, Sendable, Hashable {
    /// The steps, in the order they were appended.
    public private(set) var steps: [IntelligenceTraceStep]

    /// Creates a trace.
    /// - Parameter steps: Pre-built steps, in order. Their ``IntelligenceTraceStep/order`` is
    ///   taken as given, so a decoded trace round-trips unchanged.
    public init(steps: [IntelligenceTraceStep] = []) {
        self.steps = steps
    }

    /// Whether no tool ran.
    public var isEmpty: Bool { steps.isEmpty }

    /// How many hops the turn took.
    public var count: Int { steps.count }

    /// The wall-clock time spent inside tools.
    public var totalDuration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    /// The steps sorted by ``IntelligenceTraceStep/order``, which is what the UI lists.
    ///
    /// Appending keeps `steps` in order already; this exists for a trace that arrived decoded
    /// from somewhere, so the view never has to trust the array's order.
    public var orderedSteps: [IntelligenceTraceStep] {
        steps.sorted { $0.order < $1.order }
    }

    /// Appends a hop, numbering it.
    /// - Parameters:
    ///   - tool: Which tool ran.
    ///   - arguments: The call's arguments; rendered for display.
    ///   - summaryLine: The tool's summary line.
    ///   - duration: How long the hop took, in seconds.
    public mutating func append(
        tool: IntelligenceToolName,
        arguments: [String: IntelligenceToolArgument] = [:],
        summaryLine: String,
        duration: TimeInterval
    ) {
        steps.append(
            IntelligenceTraceStep(
                order: steps.count,
                toolName: tool,
                argumentsDisplay: IntelligenceTraceStep.renderArguments(arguments),
                summaryLine: summaryLine,
                duration: duration
            )
        )
    }

    /// Appends a hop from the call that ran and the result it produced.
    ///
    /// The convenience the app target will use: the tool has just answered, and both halves of
    /// the step are already in hand.
    /// - Parameters:
    ///   - tool: Which tool ran.
    ///   - call: The validated call.
    ///   - result: What the tool answered.
    ///   - duration: How long the hop took, in seconds.
    public mutating func append(
        tool: IntelligenceToolName,
        call: IntelligenceToolCall,
        result: IntelligenceToolResult,
        duration: TimeInterval
    ) {
        append(
            tool: tool,
            arguments: call.arguments,
            summaryLine: result.summaryLine,
            duration: duration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case steps
    }
}
