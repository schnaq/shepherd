import Foundation

/// The permission mode the agent CLI runs under.
///
/// The values are Claude Code's documented `--permission-mode` arguments. They are surfaced in
/// the delegation sheet because they are the single most consequential guardrail: the user has
/// to be able to see, before pressing Start, whether the agent may edit files unattended.
enum AgentPermissionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// File edits are applied without asking; the default.
    case acceptEdits
    /// The agent plans and reports, but changes nothing.
    case plan
    /// Nothing is asked at all — every permitted tool runs unattended.
    case dontAsk

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .acceptEdits: return String(localized: "Accept edits")
        case .plan: return String(localized: "Plan only")
        case .dontAsk: return String(localized: "Don't ask")
        }
    }

    /// A one-line explanation shown next to the picker.
    var explanation: String {
        switch self {
        case .acceptEdits:
            return String(localized: "The agent edits files in the worktree without asking. Nothing is pushed.")
        case .plan:
            return String(localized: "The agent only writes a plan. No file is changed.")
        case .dontAsk:
            return String(localized: "Every allowed tool runs unattended, including shell commands.")
        }
    }
}

/// Which CLI Shepherd invokes.
///
/// Claude Code is the first-class integration (ADR 0011): its `stream-json` output is parsed
/// event by event. Any other local agent CLI is reachable through a command template.
enum AgentCLIKind: Codable, Sendable, Hashable {
    /// `claude -p … --output-format stream-json`.
    case claudeCode
    /// A user-provided command line with `{prompt}` and `{worktree}` placeholders.
    case custom(commandTemplate: String)

    /// The `{prompt}` placeholder, replaced with the full prompt as **one** argv element.
    static let promptPlaceholder = "{prompt}"
    /// The `{worktree}` placeholder, replaced with the worktree's path.
    static let worktreePlaceholder = "{worktree}"

    /// The template of a custom kind, or an empty string for Claude Code.
    var commandTemplate: String {
        if case .custom(let template) = self { return template }
        return ""
    }

    /// The display name used in the sheet header.
    var displayName: String {
        switch self {
        case .claudeCode: return String(localized: "Claude Code")
        case .custom: return String(localized: "Custom agent CLI")
        }
    }
}

/// The picker tag for ``AgentCLIKind``, which has an associated value and therefore no raw value.
enum AgentCLIKindTag: String, CaseIterable, Identifiable, Sendable {
    /// Claude Code.
    case claudeCode
    /// A custom command template.
    case custom

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .claudeCode: return String(localized: "Claude Code")
        case .custom: return String(localized: "Custom command")
        }
    }
}

extension AgentCLIKind {
    /// The picker tag for this kind.
    var tag: AgentCLIKindTag {
        switch self {
        case .claudeCode: return .claudeCode
        case .custom: return .custom
        }
    }
}

/// One resolved invocation: an executable and its argv.
struct AgentInvocation: Sendable, Equatable {
    /// The binary to exec.
    var executable: URL
    /// The arguments, *excluding* argv[0].
    var arguments: [String]

    /// The command as one line, for the transcript header. Display only — never re-parsed.
    var displayCommand: String {
        ([executable.path] + arguments).joined(separator: " ")
    }
}

/// How Shepherd invokes the local agent CLI (ADR 0011).
///
/// Stored in `UserDefaults` as JSON. It holds **no credentials**: Shepherd never collects,
/// stores or injects agent authentication — the CLI brings its own, and the child process
/// inherits the user's environment untouched.
struct AgentCLIConfiguration: Codable, Sendable, Equatable {
    /// Which CLI to run.
    var kind: AgentCLIKind
    /// An explicit path to the executable; empty means "detect it".
    var executablePath: String
    /// Extra arguments appended verbatim after the ones Shepherd builds.
    var extraArguments: [String]
    /// The permission mode passed to the CLI.
    var permissionMode: AgentPermissionMode
    /// The comma-separated allow-list passed to `--allowedTools`.
    var allowedTools: String
    /// The turn cap passed to `--max-turns`.
    var maxTurns: Int
    /// The spend cap passed to `--max-budget-usd`; `nil` means uncapped.
    var maxBudgetUSD: Double?

    /// The default tool allow-list: read, edit, search, and git — but no arbitrary shell.
    static let defaultAllowedTools = "Read,Edit,Bash(git *),Glob,Grep"
    /// The default turn cap.
    static let defaultMaxTurns = 25
    /// The default spend cap in US dollars.
    static let defaultMaxBudgetUSD = 5.0

    /// Creates a configuration, guardrails on by default (ADR 0011).
    init(
        kind: AgentCLIKind = .claudeCode,
        executablePath: String = "",
        extraArguments: [String] = [],
        permissionMode: AgentPermissionMode = .acceptEdits,
        allowedTools: String = AgentCLIConfiguration.defaultAllowedTools,
        maxTurns: Int = AgentCLIConfiguration.defaultMaxTurns,
        maxBudgetUSD: Double? = AgentCLIConfiguration.defaultMaxBudgetUSD
    ) {
        self.kind = kind
        self.executablePath = executablePath
        self.extraArguments = extraArguments
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
    }

    private enum CodingKeys: String, CodingKey {
        case kind, executablePath, extraArguments, permissionMode, allowedTools
        case maxTurns, maxBudgetUSD
    }

    /// Decodes tolerantly: a stored configuration written by an older build is missing keys
    /// that were added later, and a missing key must fall back to the default rather than
    /// throwing away the whole configuration.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(AgentCLIKind.self, forKey: .kind))
            .flatMap { $0 } ?? .claudeCode
        executablePath = (try? container.decodeIfPresent(String.self, forKey: .executablePath))
            .flatMap { $0 } ?? ""
        extraArguments = (try? container.decodeIfPresent([String].self, forKey: .extraArguments))
            .flatMap { $0 } ?? []
        permissionMode = (try? container.decodeIfPresent(
            AgentPermissionMode.self,
            forKey: .permissionMode
        )).flatMap { $0 } ?? .acceptEdits
        allowedTools = (try? container.decodeIfPresent(String.self, forKey: .allowedTools))
            .flatMap { $0 } ?? Self.defaultAllowedTools
        maxTurns = (try? container.decodeIfPresent(Int.self, forKey: .maxTurns))
            .flatMap { $0 } ?? Self.defaultMaxTurns
        // `nil` and "absent" mean different things here: an explicit null is "no cap", a
        // missing key is a configuration written before the field existed.
        if container.contains(.maxBudgetUSD) {
            maxBudgetUSD = try? container.decodeIfPresent(Double.self, forKey: .maxBudgetUSD)
        } else {
            maxBudgetUSD = Self.defaultMaxBudgetUSD
        }
    }

    /// Encodes `maxBudgetUSD` as an explicit `null` when it is "no cap" — the synthesized
    /// encoder would omit the key, and the decoder above reads an absent key as "field did
    /// not exist yet", falling back to the default cap.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(extraArguments, forKey: .extraArguments)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(allowedTools, forKey: .allowedTools)
        try container.encode(maxTurns, forKey: .maxTurns)
        try container.encode(maxBudgetUSD, forKey: .maxBudgetUSD)
    }

    // MARK: - Invocation

    /// Why an invocation could not be built.
    enum Failure: LocalizedError, Equatable {
        /// No executable was configured or found.
        case executableNotFound
        /// The custom template is empty.
        case emptyTemplate
        /// The custom template never says where the prompt goes.
        case templateMissingPromptPlaceholder
        /// The template could not be split.
        case template(String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return String(localized: "The agent CLI could not be found. Set its path in Settings → Delegation.")
            case .emptyTemplate:
                return String(localized: "The custom command template is empty.")
            case .templateMissingPromptPlaceholder:
                return String(localized: "The custom command template must contain {prompt} so Shepherd knows where the prompt goes.")
            case .template(let message):
                return message
            }
        }
    }

    /// Builds the exact argv for one run.
    ///
    /// The prompt is **always** a single argv element: for Claude Code it follows `-p`, for a
    /// custom template it replaces the `{prompt}` placeholder inside one already-split word.
    /// - Parameters:
    ///   - prompt: The full prompt, preamble included.
    ///   - worktree: The detached worktree the agent works in.
    ///   - executable: The located binary; ignored for a custom template, which names its own.
    /// - Returns: The invocation to spawn.
    /// - Throws: ``Failure`` when the configuration cannot produce a command.
    func invocation(prompt: String, worktree: URL, executable: URL?) throws -> AgentInvocation {
        switch kind {
        case .claudeCode:
            guard let executable else { throw Failure.executableNotFound }
            return AgentInvocation(
                executable: executable,
                arguments: claudeArguments(prompt: prompt) + extraArguments
            )
        case .custom(let template):
            let words: [String]
            do {
                words = try ShellWords.split(template)
            } catch {
                throw Failure.template(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            guard let first = words.first, !first.isEmpty else { throw Failure.emptyTemplate }
            guard template.contains(AgentCLIKind.promptPlaceholder) else {
                throw Failure.templateMissingPromptPlaceholder
            }
            let expanded = words.map {
                Self.expand($0, prompt: prompt, worktree: worktree)
            }
            let binary = (expanded.first ?? first) as NSString
            return AgentInvocation(
                executable: URL(fileURLWithPath: binary.expandingTildeInPath),
                arguments: Array(expanded.dropFirst()) + extraArguments
            )
        }
    }

    /// The Claude Code argument list, without argv[0].
    ///
    /// `--verbose` is required by the CLI whenever `--output-format stream-json` is used in
    /// headless mode; without it the run refuses to start.
    private func claudeArguments(prompt: String) -> [String] {
        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode.rawValue,
        ]
        let tools = allowedTools.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tools.isEmpty {
            arguments.append(contentsOf: ["--allowedTools", tools])
        }
        if maxTurns > 0 {
            arguments.append(contentsOf: ["--max-turns", String(maxTurns)])
        }
        if let maxBudgetUSD {
            arguments.append(contentsOf: ["--max-budget-usd", Self.format(budget: maxBudgetUSD)])
        }
        return arguments
    }

    /// Replaces the placeholders inside one already-split word.
    private static func expand(_ word: String, prompt: String, worktree: URL) -> String {
        word
            .replacingOccurrences(of: AgentCLIKind.worktreePlaceholder, with: worktree.path)
            .replacingOccurrences(of: AgentCLIKind.promptPlaceholder, with: prompt)
    }

    /// Formats the budget without a locale-dependent separator and without a pointless `.0`.
    static func format(budget: Double) -> String {
        guard budget.isFinite else { return "0" }
        if budget == budget.rounded(), abs(budget) < 1e15 {
            return String(Int(budget))
        }
        return String(format: "%.2f", budget)
    }
}
