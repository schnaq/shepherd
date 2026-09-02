import Foundation

/// Every tool a model may call, and there will never be one this enum does not list.
///
/// A fixed enum is the plan's invariant expressed as a type (`docs/plans/apple-intelligence-v2.md`
/// §0.3): a tool cannot be registered at runtime, cannot be assembled from a string, and cannot
/// be anything but a read. The three cases are the three reads "Why is CI red?" needs — the
/// failing checks, the tail of one job log, the diff of one changed file — and adding a fourth is
/// a case here, a descriptor below, a concrete tool in the app target and an ADR line, in that
/// order.
///
/// The raw values are the names both cloud shapes put on the wire, so they stay inside
/// `[a-zA-Z0-9_-]` and match nothing else in either API.
public enum IntelligenceToolName: String, Codable, Sendable, Hashable, CaseIterable {
    /// The red checks on this pull request, from the locally cached `check_runs` rows.
    case failingChecks
    /// The failing region of one check's job log.
    case jobLogTail
    /// The diff of one changed file, windowed.
    case fileDiff
}

extension IntelligenceToolName {
    /// The argument name ``IntelligenceToolName/jobLogTail`` takes.
    public static let checkNameArgument = "checkName"
    /// The argument name ``IntelligenceToolName/fileDiff`` requires.
    public static let pathArgument = "path"
    /// The optional argument ``IntelligenceToolName/fileDiff`` centres its window on.
    public static let lineArgument = "line"
}

/// The tool contract: the fixed descriptors, plus the one check that decides whether a call the
/// model produced may run.
///
/// A value rather than a namespace because validation needs one piece of context that is not
/// static — the pull request's changed-file paths. That is what makes the plan's hardest rule
/// enforceable here instead of inside a tool: *no free text the model wrote reaches GitHub*, so
/// the only file path a call may carry is one this pull request's own diff already contains.
///
/// Everything else about the contract is static data. Validation is pure and total: it either
/// throws one ``IntelligenceToolError`` or the call is runnable, and the order in which the
/// checks are made is fixed so the error a reviewer sees for a given call is always the same
/// one.
public struct IntelligenceToolRegistry: Sendable, Hashable {
    /// The paths ``IntelligenceToolName/fileDiff`` may be asked for.
    ///
    /// Both a rename's new and previous path belong here — both are in the diff, and a log that
    /// names the old one is not the model inventing anything.
    public var changedFilePaths: Set<String>

    /// Creates a registry for one pull request.
    /// - Parameter changedFilePaths: The paths the diff contains. Empty means no file may be
    ///   read, which is the right answer for a pull request whose files have not been fetched.
    public init(changedFilePaths: Set<String> = []) {
        self.changedFilePaths = changedFilePaths
    }

    /// Creates a registry from the pull request's changed files.
    /// - Parameter changedFiles: The changed files, as the detail fetch stored them.
    public init(changedFiles: [ChangedFile]) {
        var paths = Set<String>()
        for file in changedFiles {
            paths.insert(file.path)
            if let previous = file.previousPath { paths.insert(previous) }
        }
        self.init(changedFilePaths: paths)
    }

    // MARK: - Descriptors

    /// The descriptor of one tool.
    ///
    /// Total by construction — the parameter is the enum — which is why no caller has to handle
    /// "no such tool" twice.
    /// - Parameter name: The tool.
    /// - Returns: Its descriptor.
    public static func descriptor(for name: IntelligenceToolName) -> IntelligenceToolDescriptor {
        switch name {
        case .failingChecks:
            return IntelligenceToolDescriptor(
                name: .failingChecks,
                description: """
                    Lists the checks that are currently failing on this pull request, with each \
                    check's name, its conclusion and the summary text the check itself reported. \
                    Takes no arguments.
                    """
            )
        case .jobLogTail:
            return IntelligenceToolDescriptor(
                name: .jobLogTail,
                description: """
                    Reads the log of the CI job behind one check, reduced to the failing region: \
                    the error and failure lines with a little context around them. Says so \
                    plainly when the check has no readable log.
                    """,
                parameters: [
                    IntelligenceToolParameter(
                        name: IntelligenceToolName.checkNameArgument,
                        type: .string,
                        description: "The name of the check, exactly as failingChecks reported it."
                    ),
                ]
            )
        case .fileDiff:
            return IntelligenceToolDescriptor(
                name: .fileDiff,
                description: """
                    Reads the diff of one file this pull request changed, as a window around a \
                    line when you name one. Only a path from this pull request's own list of \
                    changed files can be read.
                    """,
                parameters: [
                    IntelligenceToolParameter(
                        name: IntelligenceToolName.pathArgument,
                        type: .string,
                        description: """
                            The path of the file, exactly as this pull request's list of changed \
                            files spells it.
                            """
                    ),
                    IntelligenceToolParameter(
                        name: IntelligenceToolName.lineArgument,
                        type: .integer,
                        description: """
                            A line number to centre the window on. Optional; without it the \
                            window starts at the first hunk.
                            """,
                        isRequired: false
                    ),
                ]
            )
        }
    }

    /// Every descriptor, in ``IntelligenceToolName``'s declaration order.
    ///
    /// The order is the order the tools are offered to the model, and it is deliberate: the
    /// checks come first because they are the only tool that needs no argument, so a model with
    /// nothing to go on has somewhere to start.
    public static var descriptors: [IntelligenceToolDescriptor] {
        IntelligenceToolName.allCases.map { descriptor(for: $0) }
    }

    // MARK: - Validation

    /// Decides whether a call the model produced may run.
    ///
    /// The checks, in this fixed order:
    ///
    /// 1. the tool exists;
    /// 2. every argument in the call is one the tool declares (an invented argument is refused,
    ///    not dropped — see ``IntelligenceToolError/unexpectedArgument(tool:argument:)``);
    /// 3. every required argument is present, and every present argument has the declared type;
    /// 4. a `fileDiff` path is one of ``changedFilePaths``.
    ///
    /// Arguments are walked in sorted name order rather than in dictionary order, because a
    /// `Dictionary` has none: without sorting, a call with two problems would report whichever
    /// one the hash seed happened to put first, and the error a reviewer sees would differ
    /// between runs.
    /// - Parameter call: The call the provider parsed out of the model's answer.
    /// - Throws: ``IntelligenceToolError``.
    public func validate(_ call: IntelligenceToolCall) throws {
        guard let name = IntelligenceToolName(rawValue: call.toolName) else {
            throw IntelligenceToolError.unknownTool(call.toolName)
        }
        let descriptor = Self.descriptor(for: name)
        let declared = Set(descriptor.parameters.map(\.name))
        for argument in call.arguments.keys.sorted() where !declared.contains(argument) {
            throw IntelligenceToolError.unexpectedArgument(tool: name, argument: argument)
        }
        for parameter in descriptor.parameters {
            guard let value = call.arguments[parameter.name] else {
                guard parameter.isRequired else { continue }
                throw IntelligenceToolError.missingArgument(tool: name, argument: parameter.name)
            }
            guard value.type == parameter.type else {
                throw IntelligenceToolError.wrongArgumentType(
                    tool: name,
                    argument: parameter.name,
                    expected: parameter.type
                )
            }
        }
        guard name == .fileDiff else { return }
        // Reached only once the loop above has established that the path is present and is a
        // string, so the fallback below cannot mask a missing argument.
        let path = call.arguments[IntelligenceToolName.pathArgument]?.stringValue ?? ""
        guard changedFilePaths.contains(path) else {
            throw IntelligenceToolError.pathNotInChangedFiles(path)
        }
    }
}
