import Foundation
import XCTest

@testable import ShepherdCore

/// The tool *contract* (plan §0.3): which tools exist, what a call must look like, and the one
/// rule that cannot be left to a tool implementation — a `fileDiff` path the model invented.
///
/// All of it is here rather than beside the concrete tools, because the concrete tools live in the
/// app target and cannot be tested on Linux, while every rule worth enforcing is a pure function
/// of the descriptor plus the call.
final class IntelligenceToolRegistryTests: XCTestCase {
    private static let composerPath = "Shepherd/Features/Review/ReviewComposer.swift"
    private static let testPath = "ShepherdTests/LocalizationTests.swift"

    private let registry = IntelligenceToolRegistry(changedFilePaths: [
        IntelligenceToolRegistryTests.composerPath,
        IntelligenceToolRegistryTests.testPath,
    ])

    // MARK: - What exists

    func testTheRegistryOffersExactlyTheThreePlannedReadTools() {
        XCTAssertEqual(IntelligenceToolName.allCases, [.failingChecks, .jobLogTail, .fileDiff])
        XCTAssertEqual(
            IntelligenceToolRegistry.descriptors.map(\.name),
            [.failingChecks, .jobLogTail, .fileDiff]
        )
        // The wire names are what both cloud shapes send, so they must stay in the character set
        // both APIs accept for a tool name.
        for name in IntelligenceToolName.allCases {
            XCTAssertFalse(name.rawValue.isEmpty)
            XCTAssertTrue(name.rawValue.allSatisfy { $0.isLetter || $0.isNumber })
        }
    }

    func testEveryDescriptorSaysWhatItIsForAndWhatItTakes() {
        for descriptor in IntelligenceToolRegistry.descriptors {
            XCTAssertFalse(descriptor.description.isEmpty, "\(descriptor.name)")
            for parameter in descriptor.parameters {
                XCTAssertFalse(parameter.name.isEmpty, "\(descriptor.name)")
                XCTAssertFalse(parameter.description.isEmpty, "\(descriptor.name)")
            }
        }
        XCTAssertTrue(IntelligenceToolRegistry.descriptor(for: .failingChecks).parameters.isEmpty)
        XCTAssertEqual(
            IntelligenceToolRegistry.descriptor(for: .jobLogTail).requiredParameterNames,
            ["checkName"]
        )
        // The window's line is optional: a log that names no line still has a diff worth reading.
        XCTAssertEqual(
            IntelligenceToolRegistry.descriptor(for: .fileDiff).requiredParameterNames,
            ["path"]
        )
        XCTAssertEqual(
            IntelligenceToolRegistry.descriptor(for: .fileDiff).parameter(named: "line")?.type,
            .integer
        )
        XCTAssertNil(
            IntelligenceToolRegistry.descriptor(for: .fileDiff).parameter(named: "sha")
        )
    }

    // MARK: - Valid calls

    func testTheThreeWellFormedCallsPass() throws {
        try registry.validate(IntelligenceToolCall(id: "1", tool: .failingChecks))
        try registry.validate(
            IntelligenceToolCall(
                id: "2",
                tool: .jobLogTail,
                arguments: ["checkName": .string("App build (macOS)")]
            )
        )
        try registry.validate(
            IntelligenceToolCall(
                id: "3",
                tool: .fileDiff,
                arguments: ["path": .string(Self.composerPath)]
            )
        )
        // …and the same call with the optional window.
        try registry.validate(
            IntelligenceToolCall(
                id: "4",
                tool: .fileDiff,
                arguments: ["path": .string(Self.composerPath), "line": .integer(42)]
            )
        )
    }

    func testARenamedFilesPreviousPathIsReadableToo() throws {
        let registry = IntelligenceToolRegistry(changedFiles: [
            ChangedFile(
                path: "ShepherdCore/Intelligence/Tools.swift",
                previousPath: "ShepherdCore/Tools.swift",
                status: .renamed
            ),
        ])
        for path in ["ShepherdCore/Intelligence/Tools.swift", "ShepherdCore/Tools.swift"] {
            try registry.validate(
                IntelligenceToolCall(id: "1", tool: .fileDiff, arguments: ["path": .string(path)])
            )
        }
    }

    // MARK: - Refusals

    func testAToolNobodyDeclaredIsRefused() {
        let call = IntelligenceToolCall(
            id: "1",
            toolName: "submitReview",
            arguments: ["verdict": .string("approve")]
        )
        assertRefusal(call, is: .unknownTool("submitReview"))
    }

    func testAMissingRequiredArgumentIsRefused() {
        assertRefusal(
            IntelligenceToolCall(id: "1", tool: .jobLogTail),
            is: .missingArgument(tool: .jobLogTail, argument: "checkName")
        )
        assertRefusal(
            IntelligenceToolCall(id: "2", tool: .fileDiff, arguments: ["line": .integer(7)]),
            is: .missingArgument(tool: .fileDiff, argument: "path")
        )
    }

    func testAnArgumentOfTheWrongTypeIsRefused() {
        assertRefusal(
            IntelligenceToolCall(
                id: "1",
                tool: .jobLogTail,
                arguments: ["checkName": .integer(3)]
            ),
            is: .wrongArgumentType(tool: .jobLogTail, argument: "checkName", expected: .string)
        )
        // A quoted line number is the shape a model reaches for most often, and it is still wrong
        // *here*: the tool takes an `Int`, and the tolerant reading belongs to the model's own
        // output types, not to a call that is about to run a read.
        assertRefusal(
            IntelligenceToolCall(
                id: "2",
                tool: .fileDiff,
                arguments: ["path": .string(Self.composerPath), "line": .string("42")]
            ),
            is: .wrongArgumentType(tool: .fileDiff, argument: "line", expected: .integer)
        )
    }

    func testAnInventedArgumentIsRefusedRatherThanDropped() {
        assertRefusal(
            IntelligenceToolCall(
                id: "1",
                tool: .failingChecks,
                arguments: ["repository": .string("acme/widgets")]
            ),
            is: .unexpectedArgument(tool: .failingChecks, argument: "repository")
        )
        assertRefusal(
            IntelligenceToolCall(
                id: "2",
                tool: .fileDiff,
                arguments: [
                    "path": .string(Self.composerPath),
                    "ref": .string("refs/heads/main"),
                ]
            ),
            is: .unexpectedArgument(tool: .fileDiff, argument: "ref")
        )
    }

    func testAPathTheModelInventedIsRefused() {
        assertRefusal(
            IntelligenceToolCall(
                id: "1",
                tool: .fileDiff,
                arguments: ["path": .string("Shepherd/Support/Keychain.swift")]
            ),
            is: .pathNotInChangedFiles("Shepherd/Support/Keychain.swift")
        )
        // A path that is *nearly* right is not right: no prefix matching, no fuzzy matching.
        assertRefusal(
            IntelligenceToolCall(
                id: "2",
                tool: .fileDiff,
                arguments: ["path": .string("Features/Review/ReviewComposer.swift")]
            ),
            is: .pathNotInChangedFiles("Features/Review/ReviewComposer.swift")
        )
        assertRefusal(
            IntelligenceToolCall(id: "3", tool: .fileDiff, arguments: ["path": .string("")]),
            is: .pathNotInChangedFiles("")
        )
    }

    func testWithNoChangedFilesNothingCanBeRead() {
        assertRefusal(
            IntelligenceToolCall(
                id: "1",
                tool: .fileDiff,
                arguments: ["path": .string(Self.composerPath)]
            ),
            in: IntelligenceToolRegistry(),
            is: .pathNotInChangedFiles(Self.composerPath)
        )
    }

    func testTheReportedProblemDoesNotDependOnDictionaryOrder() {
        // Two invented arguments: the one that sorts first is the one reported, on every run and
        // in every process, because the validator walks the names sorted rather than hashed.
        let call = IntelligenceToolCall(
            id: "1",
            tool: .failingChecks,
            arguments: ["zeta": .string("z"), "alpha": .string("a")]
        )
        for _ in 0..<20 {
            assertRefusal(call, is: .unexpectedArgument(tool: .failingChecks, argument: "alpha"))
        }
    }

    // MARK: - Arguments on the wire

    func testArgumentsCodeAsBareJSONValues() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let arguments: [String: IntelligenceToolArgument] = [
            "checkName": .string("App build (macOS)"),
            "line": .integer(42),
        ]
        let json = try XCTUnwrap(String(data: try encoder.encode(arguments), encoding: .utf8))
        XCTAssertEqual(json, #"{"checkName":"App build (macOS)","line":42}"#)

        let decoded = try JSONDecoder().decode(
            [String: IntelligenceToolArgument].self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded, arguments)
        XCTAssertEqual(decoded["line"]?.integerValue, 42)
        XCTAssertNil(decoded["line"]?.stringValue)
        XCTAssertEqual(decoded["checkName"]?.type, .string)
    }

    func testAnArgumentThatIsNeitherAStringNorAnIntegerIsRefused() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                [String: IntelligenceToolArgument].self,
                from: Data(#"{"path":{"nested":true}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                [String: IntelligenceToolArgument].self,
                from: Data(#"{"line":1.5}"#.utf8)
            )
        )
    }

    // MARK: - Helpers

    private func assertRefusal(
        _ call: IntelligenceToolCall,
        in registry: IntelligenceToolRegistry? = nil,
        is expected: IntelligenceToolError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try (registry ?? self.registry).validate(call), file: file, line: line) {
            XCTAssertEqual($0 as? IntelligenceToolError, expected, file: file, line: line)
        }
    }
}

/// The two wire shapes, pinned byte for byte.
///
/// A schema is the one part of the tool contract that nothing in Shepherd can verify at runtime:
/// an endpoint that dislikes it answers `400` with a sentence, on the user's machine, with their
/// key. So the encoding is asserted against the exact JSON here, where a renamed key or a lost
/// `required` entry fails on Linux instead.
final class IntelligenceToolSchemaTests: XCTestCase {
    private func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(String(data: try encoder.encode(value), encoding: .utf8))
    }

    func testTheAnthropicShapeIsNameDescriptionAndInputSchema() throws {
        let schemas = AnthropicToolSchema.all
        XCTAssertEqual(schemas.map(\.name), ["failingChecks", "jobLogTail", "fileDiff"])

        XCTAssertEqual(
            try encoded(schemas[0]),
            #"{"description":"Lists the checks that are currently failing on this pull request, with each check's name, its conclusion and the summary text the check itself reported. Takes no arguments.","input_schema":{"properties":{},"required":[],"type":"object"},"name":"failingChecks"}"#
        )
        XCTAssertEqual(
            try encoded(schemas[1]),
            #"{"description":"Reads the log of the CI job behind one check, reduced to the failing region: the error and failure lines with a little context around them. Says so plainly when the check has no readable log.","input_schema":{"properties":{"checkName":{"description":"The name of the check, exactly as failingChecks reported it.","type":"string"}},"required":["checkName"],"type":"object"},"name":"jobLogTail"}"#
        )
        XCTAssertEqual(
            try encoded(schemas[2]),
            #"{"description":"Reads the diff of one file this pull request changed, as a window around a line when you name one. Only a path from this pull request's own list of changed files can be read.","input_schema":{"properties":{"line":{"description":"A line number to centre the window on. Optional; without it the window starts at the first hunk.","type":"integer"},"path":{"description":"The path of the file, exactly as this pull request's list of changed files spells it.","type":"string"}},"required":["path"],"type":"object"},"name":"fileDiff"}"#
        )
    }

    func testTheOpenAIShapeWrapsTheSameSchemaOneEnvelopeDeeper() throws {
        let schemas = OpenAIToolSchema.all
        XCTAssertEqual(schemas.map(\.function.name), ["failingChecks", "jobLogTail", "fileDiff"])
        XCTAssertEqual(Set(schemas.map(\.type)), ["function"])

        XCTAssertEqual(
            try encoded(schemas[0]),
            #"{"function":{"description":"Lists the checks that are currently failing on this pull request, with each check's name, its conclusion and the summary text the check itself reported. Takes no arguments.","name":"failingChecks","parameters":{"properties":{},"required":[],"type":"object"}},"type":"function"}"#
        )
        XCTAssertEqual(
            try encoded(schemas[1]),
            #"{"function":{"description":"Reads the log of the CI job behind one check, reduced to the failing region: the error and failure lines with a little context around them. Says so plainly when the check has no readable log.","name":"jobLogTail","parameters":{"properties":{"checkName":{"description":"The name of the check, exactly as failingChecks reported it.","type":"string"}},"required":["checkName"],"type":"object"}},"type":"function"}"#
        )
        XCTAssertEqual(
            try encoded(schemas[2]),
            #"{"function":{"description":"Reads the diff of one file this pull request changed, as a window around a line when you name one. Only a path from this pull request's own list of changed files can be read.","name":"fileDiff","parameters":{"properties":{"line":{"description":"A line number to centre the window on. Optional; without it the window starts at the first hunk.","type":"integer"},"path":{"description":"The path of the file, exactly as this pull request's list of changed files spells it.","type":"string"}},"required":["path"],"type":"object"}},"type":"function"}"#
        )
    }

    func testBothShapesCarryTheSameSchemaForEveryTool() {
        for descriptor in IntelligenceToolRegistry.descriptors {
            XCTAssertEqual(
                AnthropicToolSchema(descriptor).inputSchema,
                OpenAIToolSchema(descriptor).function.parameters,
                "\(descriptor.name)"
            )
        }
    }

    func testATypeThatCarriesNoRequiredArgumentStillEncodesAnEmptyRequiredList() throws {
        let schema = IntelligenceToolJSONSchema(
            IntelligenceToolRegistry.descriptor(for: .failingChecks)
        )
        XCTAssertEqual(schema.type, "object")
        XCTAssertTrue(schema.properties.isEmpty)
        XCTAssertEqual(schema.required, [])
        XCTAssertEqual(try encoded(schema), #"{"properties":{},"required":[],"type":"object"}"#)
    }
}

/// The trace: what the review screen expands under a tool-calling answer.
final class IntelligenceTraceTests: XCTestCase {
    func testAppendingNumbersTheStepsInTheOrderTheyHappened() {
        var trace = IntelligenceTrace()
        XCTAssertTrue(trace.isEmpty)

        trace.append(
            tool: .failingChecks,
            summaryLine: "2 failing checks",
            duration: 0.01
        )
        trace.append(
            tool: .jobLogTail,
            arguments: ["checkName": .string("App build (macOS)")],
            summaryLine: "42 of 1320 lines",
            duration: 0.5
        )
        trace.append(
            tool: .fileDiff,
            arguments: ["line": .integer(88), "path": .string("Sources/App.swift")],
            summaryLine: "24 diff lines around line 88",
            duration: 0.02
        )

        XCTAssertEqual(trace.count, 3)
        XCTAssertFalse(trace.isEmpty)
        XCTAssertEqual(trace.steps.map(\.order), [0, 1, 2])
        XCTAssertEqual(
            trace.steps.map(\.toolName),
            [.failingChecks, .jobLogTail, .fileDiff]
        )
        XCTAssertEqual(trace.totalDuration, 0.53, accuracy: 0.0001)
    }

    func testArgumentsAreRenderedSortedByNameSoTheRowReadsTheSameEveryTime() {
        var trace = IntelligenceTrace()
        for _ in 0..<20 {
            trace.append(
                tool: .fileDiff,
                arguments: ["path": .string("Sources/App.swift"), "line": .integer(88)],
                summaryLine: "read",
                duration: 0
            )
        }
        XCTAssertEqual(
            Set(trace.steps.map(\.argumentsDisplay)),
            ["line: 88, path: Sources/App.swift"]
        )
        // A tool that takes nothing renders nothing, rather than "{}" or "()".
        trace.append(tool: .failingChecks, summaryLine: "2 failing checks", duration: 0)
        XCTAssertEqual(trace.steps.last?.argumentsDisplay, "")
    }

    func testAStepCanBeBuiltFromTheCallAndTheResultTheToolProduced() {
        var trace = IntelligenceTrace()
        let call = IntelligenceToolCall(
            id: "call_1",
            tool: .jobLogTail,
            arguments: ["checkName": .string("App build (macOS)")]
        )
        let result = IntelligenceToolResult(
            callID: "call_1",
            content: "error: no such module 'FoundationModels'",
            summaryLine: "42 of 1320 lines of App build (macOS)",
            wasTruncated: true
        )
        trace.append(tool: .jobLogTail, call: call, result: result, duration: 0.25)

        let step = trace.steps.first
        XCTAssertEqual(step?.toolName, .jobLogTail)
        XCTAssertEqual(step?.argumentsDisplay, "checkName: App build (macOS)")
        XCTAssertEqual(step?.summaryLine, "42 of 1320 lines of App build (macOS)")
        XCTAssertEqual(step?.duration, 0.25)
        // The budgeted content travels with the step, because that is what the card's expanded
        // row shows: exactly what the model was given, not a re-description of it (ADR 0024).
        // The *summary* line stays the one-line version beside the collapsed row.
        XCTAssertEqual(step?.resultContent, "error: no such module 'FoundationModels'")
        XCTAssertFalse(trace.steps.contains { $0.summaryLine.contains("FoundationModels") })

        // A step recorded without a result has no content rather than a placeholder — which is
        // what a test scripting a sequence of hops produces.
        trace.append(tool: .failingChecks, summaryLine: "2 failing checks", duration: 0)
        XCTAssertEqual(trace.steps.last?.resultContent, "")
    }

    func testADecodedTraceIsOrderedByItsOwnNumbersRatherThanByArrayOrder() throws {
        var trace = IntelligenceTrace()
        trace.append(tool: .failingChecks, summaryLine: "first", duration: 0)
        trace.append(tool: .fileDiff, arguments: ["path": .string("a")], summaryLine: "second", duration: 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(trace)
        XCTAssertEqual(try JSONDecoder().decode(IntelligenceTrace.self, from: data), trace)

        let shuffled = IntelligenceTrace(steps: trace.steps.reversed())
        XCTAssertEqual(shuffled.orderedSteps.map(\.summaryLine), ["first", "second"])
    }
}
