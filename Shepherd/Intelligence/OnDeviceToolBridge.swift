import Foundation
import FoundationModels
import ShepherdCore

// MARK: - The trace, collected from wherever the framework calls a tool

/// Collects the hops the on-device tools take, so the answer can carry them.
///
/// An `actor` because this is the one place in the tool loop where Shepherd is not driving: the
/// framework decides when to call a tool, and may call two of them for one turn, so the trace is
/// written from a context Shepherd does not control. The alternative — a class with a lock, or a
/// `Sendable` closure per tool — would be the same thing spelled worse.
///
/// It is deliberately not the trace *type*: ``ShepherdCore/IntelligenceTrace`` stays a pure value
/// that the cloud providers build by appending, and this is the box that value sits in while the
/// framework is in charge of the turn.
actor ToolTraceRecorder {
    private var trace = IntelligenceTrace()

    /// Creates an empty recorder.
    init() {}

    /// The trace so far.
    var current: IntelligenceTrace { trace }

    /// How many hops have happened, which is what the hop cap is measured against.
    var count: Int { trace.count }

    /// Records one finished hop.
    /// - Parameters:
    ///   - tool: Which tool ran.
    ///   - call: The call, for the rendered arguments.
    ///   - result: What it answered, for the summary line.
    ///   - duration: How long it took, in seconds.
    func record(
        tool: IntelligenceToolName,
        call: IntelligenceToolCall,
        result: IntelligenceToolResult,
        duration: TimeInterval
    ) {
        trace.append(tool: tool, call: call, result: result, duration: duration)
    }
}

// MARK: - The three tools, in the framework's shape

/// Wraps the read-only tool contract in `FoundationModels.Tool` conformances.
///
/// **This file may import `FoundationModels`, and it is the second and last one that does.** The
/// containment rule the app is built on now reads: only files named `OnDevice*.swift` under
/// `Shepherd/Intelligence/` may import that framework. Everything below deals in
/// ``IntelligenceToolExecuting`` and ``ShepherdCore/IntelligenceToolCall``, so the wrappers hold
/// no logic of their own — no data source, no budgeting, no validation. They translate an
/// `@Generable` argument struct into a call, hand it to the executor that the cloud providers use
/// too, and record the hop. If the framework renames `Tool`, this file is what breaks.
///
/// Three wrappers rather than one generic one, because `Tool`'s `Arguments` is an associated type
/// and each tool's argument struct has to be its own `@Generable` type. What they share is
/// ``OnDeviceToolBridge/run(_:tool:executor:recorder:)``.
enum OnDeviceToolBridge {
    /// Every tool, ready to be handed to a session.
    ///
    /// In ``ShepherdCore/IntelligenceToolName``'s declaration order, which is the registry's
    /// order and therefore the same order the cloud tiers offer them in: the checks first,
    /// because they are the only tool that needs no argument.
    /// - Parameters:
    ///   - executor: The reads, bound to one pull request.
    ///   - recorder: Where the hops are collected.
    /// - Returns: The tools.
    static func tools(
        executor: any IntelligenceToolExecuting,
        recorder: ToolTraceRecorder
    ) -> [any Tool] {
        [
            OnDeviceFailingChecksTool(executor: executor, recorder: recorder),
            OnDeviceJobLogTailTool(executor: executor, recorder: recorder),
            OnDeviceFileDiffTool(executor: executor, recorder: recorder),
        ]
    }

    /// Runs one call and records it, enforcing the hop cap.
    ///
    /// The cap has to be enforced *here* rather than in the provider, because on this tier the
    /// framework drives the calls: there is no loop Shepherd could count. Throwing is the only
    /// way to stop a turn from inside a tool, which is why it is
    /// ``IntelligenceError/toolLoopExceeded`` and not a result — a result saying "that is
    /// enough" is a sentence a model is free to ignore.
    /// - Parameters:
    ///   - call: The call built from the generated arguments.
    ///   - tool: Which tool it is, for the trace.
    ///   - executor: The reads.
    ///   - recorder: Where the hop is recorded.
    /// - Returns: The budgeted text the model gets.
    static func run(
        _ call: IntelligenceToolCall,
        tool: IntelligenceToolName,
        executor: any IntelligenceToolExecuting,
        recorder: ToolTraceRecorder
    ) async throws -> String {
        guard await recorder.count < IntelligenceToolLoop.maximumHops else {
            throw IntelligenceError.toolLoopExceeded
        }
        let started = Date()
        let result = try await executor.execute(call)
        await recorder.record(
            tool: tool,
            call: call,
            result: result,
            duration: Date().timeIntervalSince(started)
        )
        return result.content
    }

    /// A call id, for a tier whose framework does not issue one.
    ///
    /// The id only matters to the two cloud shapes, which have to pair a result with the call it
    /// answers; here nothing pairs anything, and the contract still wants a value that is not
    /// shared between hops.
    /// - Parameter tool: The tool being called.
    /// - Returns: An id unique to this hop.
    fileprivate static func callID(for tool: IntelligenceToolName) -> String {
        "\(tool.rawValue)-\(UUID().uuidString)"
    }
}

/// The failing checks on this pull request.
struct OnDeviceFailingChecksTool: Tool {
    /// No arguments, exactly as the descriptor declares.
    @Generable
    struct Arguments {}

    /// Pinned to the registry's raw value rather than derived from the type name, so the
    /// name the model calls is the name the validator knows.
    let name = IntelligenceToolName.failingChecks.rawValue
    /// The descriptor's own sentence, so all three tiers describe the tool identically.
    let description = IntelligenceToolRegistry
        .descriptor(for: .failingChecks)
        .description

    /// The reads.
    let executor: any IntelligenceToolExecuting
    /// Where hops are recorded.
    let recorder: ToolTraceRecorder

    func call(arguments: Arguments) async throws -> String {
        try await OnDeviceToolBridge.run(
            IntelligenceToolCall(
                id: OnDeviceToolBridge.callID(for: .failingChecks),
                tool: .failingChecks
            ),
            tool: .failingChecks,
            executor: executor,
            recorder: recorder
        )
    }
}

/// The failing region of one check's job log.
struct OnDeviceJobLogTailTool: Tool {
    /// The descriptor's one required argument.
    @Generable
    struct Arguments {
        /// The check to read, which must be one `failingChecks` reported.
        @Guide(description: "The name of the check, exactly as failingChecks reported it.")
        var checkName: String
    }

    let name = IntelligenceToolName.jobLogTail.rawValue
    let description = IntelligenceToolRegistry
        .descriptor(for: .jobLogTail)
        .description

    /// The reads.
    let executor: any IntelligenceToolExecuting
    /// Where hops are recorded.
    let recorder: ToolTraceRecorder

    func call(arguments: Arguments) async throws -> String {
        try await OnDeviceToolBridge.run(
            IntelligenceToolCall(
                id: OnDeviceToolBridge.callID(for: .jobLogTail),
                tool: .jobLogTail,
                arguments: [
                    IntelligenceToolName.checkNameArgument: .string(arguments.checkName),
                ]
            ),
            tool: .jobLogTail,
            executor: executor,
            recorder: recorder
        )
    }
}

/// A window into one changed file's diff.
struct OnDeviceFileDiffTool: Tool {
    /// The descriptor's required path and optional line.
    ///
    /// `line` is `Int?` rather than a sentinel, because it is the one place in this file
    /// where "the model did not say" and "the model said zero" have to stay different: a
    /// window centred on line zero is not the window a model that named no line wants.
    @Generable
    struct Arguments {
        /// The file to read, which must be one this pull request changed.
        @Guide(
            description: """
                The path of the file, exactly as this pull request's list of changed files \
                spells it.
                """
        )
        var path: String

        /// The line to centre the window on.
        @Guide(
            description: """
                A line number to centre the window on. Optional; without it the window \
                starts at the first hunk.
                """
        )
        var line: Int?
    }

    let name = IntelligenceToolName.fileDiff.rawValue
    let description = IntelligenceToolRegistry
        .descriptor(for: .fileDiff)
        .description

    /// The reads.
    let executor: any IntelligenceToolExecuting
    /// Where hops are recorded.
    let recorder: ToolTraceRecorder

    func call(arguments: Arguments) async throws -> String {
        var values: [String: IntelligenceToolArgument] = [
            IntelligenceToolName.pathArgument: .string(arguments.path),
        ]
        if let line = arguments.line {
            values[IntelligenceToolName.lineArgument] = .integer(line)
        }
        return try await OnDeviceToolBridge.run(
            IntelligenceToolCall(
                id: OnDeviceToolBridge.callID(for: .fileDiff),
                tool: .fileDiff,
                arguments: values
            ),
            tool: .fileDiff,
            executor: executor,
            recorder: recorder
        )
    }
}

// MARK: - The generated twin

/// The shape the on-device model fills in for a CI diagnosis (plan §3.F).
///
/// The `@Generable` mirror of ``ShepherdCore/CIDiagnosis``, and the first one in the app with an
/// enum in it: `confidence` is a fixed set of three, which is exactly what guided generation is
/// for — the model cannot answer "quite sure", so nothing downstream has to interpret that.
///
/// The three locating fields are **not** optional here, and that is a deliberate difference from
/// the twin they convert into. Every other `@Generable` type in this app is a flat struct of
/// `String`/`[String]`, because the on-device model is good at short structured answers and the
/// schema should ask for nothing clever (ADR 0007); an empty string and a zero are how a model
/// says "the log did not name one", which is a convention ``ShepherdCore/CIDiagnosis`` already
/// tolerates from the cloud tiers for the same reason. ``CIDiagnosis/init(_:)`` is where the
/// convention is applied, once.
@Generable
struct OnDeviceCIDiagnosis {
    /// How sure the model says it is.
    @Generable
    enum Confidence {
        /// A guess from thin evidence.
        case low
        /// Consistent with the log, not proven by it.
        case medium
        /// The log names it.
        case high
    }

    /// The failing test's name, or empty when the log named none.
    @Guide(
        description: "The name of the failing test, or an empty string if the log named none."
    )
    var failingTest: String

    /// The file the failure points at, or empty when the log named none.
    @Guide(
        description: "The path of the file the failure points at, or an empty string if unknown."
    )
    var file: String

    /// The line in that file, or zero when the log named none.
    @Guide(description: "The line number in that file, or 0 if unknown.")
    var line: Int

    /// One sentence on what is wrong.
    @Guide(description: "One sentence on what is wrong. This is the answer; never leave it empty.")
    var hypothesis: String

    /// How sure the model says it is.
    var confidence: Confidence
}

extension CIDiagnosis {
    /// Converts the generated shape into the twin the UI and the router see.
    ///
    /// The whole conversion: blank means unknown, zero means unknown, and the three confidences
    /// map one to one. Everything else about a diagnosis — the tolerances, the coding keys, the
    /// decision that only `hypothesis` is required — lives in `ShepherdCore` with the twin, where
    /// it is tested on Linux and shared with the cloud tiers.
    /// - Parameter generated: What the on-device model filled in.
    init(_ generated: OnDeviceCIDiagnosis) {
        self.init(
            failingTest: CIDiagnosis.trimmed(generated.failingTest),
            file: CIDiagnosis.trimmed(generated.file),
            line: generated.line > 0 ? generated.line : nil,
            hypothesis: generated.hypothesis.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: CIDiagnosis.Confidence(generated.confidence)
        )
    }

    /// A generated string, or `nil` when the model left it blank.
    /// - Parameter text: What the model wrote.
    private static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CIDiagnosis.Confidence {
    /// Maps the generated confidence onto the twin's.
    /// - Parameter generated: What the model chose.
    init(_ generated: OnDeviceCIDiagnosis.Confidence) {
        switch generated {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}
