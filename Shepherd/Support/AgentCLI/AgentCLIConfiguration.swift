import Foundation
import ShepherdCore

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
    /// The `{message}` placeholder of the session templates, replaced with the message the
    /// reviewer confirmed — as **one** argv element, exactly like `{prompt}` (ADR 0030).
    static let messagePlaceholder = "{message}"
    /// The `{sessionID}` placeholder, replaced with the id from the `Claude-Session:` trailer.
    static let sessionIDPlaceholder = "{sessionID}"
    /// The `{sessionURL}` placeholder, replaced with the trailer's URL — empty for a local
    /// session, which has no URL to substitute.
    static let sessionURLPlaceholder = "{sessionURL}"

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
    /// The command that continues a **local** session (ADR 0030).
    ///
    /// A second template beside ``AgentCLIKind/custom(commandTemplate:)``'s, and separate from
    /// it on purpose: resuming a conversation is a different command from starting a task, and a
    /// user who has replaced the *start* command has said nothing about the *resume* one.
    var sessionResumeTemplate: String
    /// The command that addresses a **remote** session, empty by default (ADR 0030).
    ///
    /// Empty means "there is no such command here", and that is the shipped state: whether the
    /// installed CLI can address a `claude.ai/code` session at all — and under which login — is
    /// an open question (`docs/plans/session-back-channel-spike.md`). While it is empty the
    /// button offers the session's link instead of a run, which is honest and needs no answer.
    var remoteSessionTemplate: String

    /// The default tool allow-list: read, edit, search, and git — but no arbitrary shell.
    static let defaultAllowedTools = "Read,Edit,Bash(git *),Glob,Grep"
    /// The default turn cap.
    static let defaultMaxTurns = 25
    /// The default spend cap in US dollars.
    static let defaultMaxBudgetUSD = 5.0
    /// The default local-session command: the CLI's documented session resume, headless.
    static let defaultSessionResumeTemplate = "claude --resume {sessionID} -p {message}"
    /// The default remote-session command: none, deliberately (see ``remoteSessionTemplate``).
    static let defaultRemoteSessionTemplate = ""

    /// Creates a configuration, guardrails on by default (ADR 0011).
    init(
        kind: AgentCLIKind = .claudeCode,
        executablePath: String = "",
        extraArguments: [String] = [],
        permissionMode: AgentPermissionMode = .acceptEdits,
        allowedTools: String = AgentCLIConfiguration.defaultAllowedTools,
        maxTurns: Int = AgentCLIConfiguration.defaultMaxTurns,
        maxBudgetUSD: Double? = AgentCLIConfiguration.defaultMaxBudgetUSD,
        sessionResumeTemplate: String = AgentCLIConfiguration.defaultSessionResumeTemplate,
        remoteSessionTemplate: String = AgentCLIConfiguration.defaultRemoteSessionTemplate
    ) {
        self.kind = kind
        self.executablePath = executablePath
        self.extraArguments = extraArguments
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.maxBudgetUSD = maxBudgetUSD
        self.sessionResumeTemplate = sessionResumeTemplate
        self.remoteSessionTemplate = remoteSessionTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case kind, executablePath, extraArguments, permissionMode, allowedTools
        case maxTurns, maxBudgetUSD, sessionResumeTemplate, remoteSessionTemplate
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
        // Absent means "written before the session back-channel existed", so both fall back to
        // their defaults — which for the remote one is the empty string, i.e. "offer the link"
        // (ADR 0030). An explicitly *empty* local template is kept as it is: clearing that field
        // is how a user switches the local button off.
        sessionResumeTemplate = (try? container.decodeIfPresent(
            String.self,
            forKey: .sessionResumeTemplate
        )).flatMap { $0 } ?? Self.defaultSessionResumeTemplate
        remoteSessionTemplate = (try? container.decodeIfPresent(
            String.self,
            forKey: .remoteSessionTemplate
        )).flatMap { $0 } ?? Self.defaultRemoteSessionTemplate
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
        try container.encode(sessionResumeTemplate, forKey: .sessionResumeTemplate)
        try container.encode(remoteSessionTemplate, forKey: .remoteSessionTemplate)
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
        /// No command is configured for this kind of session (ADR 0030).
        case emptySessionTemplate
        /// The session template never says where the message goes.
        case sessionTemplateMissingMessagePlaceholder

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
            case .emptySessionTemplate:
                return String(localized: "No command is configured for this kind of session. Set one in Settings → Delegation.")
            case .sessionTemplateMissingMessagePlaceholder:
                return String(localized: "The session command must contain {message} so Shepherd knows where the message goes.")
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
                    error.userFacingDescription
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

    /// The command configured for one kind of session, or an empty string when there is none.
    /// - Parameter kind: Local or remote.
    /// - Returns: The template, trimmed.
    func sessionTemplate(for kind: SessionReference.Kind) -> String {
        let template: String
        switch kind {
        case .local: template = sessionResumeTemplate
        case .remote: template = remoteSessionTemplate
        }
        return template.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a message can be sent to this kind of session at all.
    /// - Parameter kind: Local or remote.
    /// - Returns: `true` when a command is configured for it.
    func canSendToSession(kind: SessionReference.Kind) -> Bool {
        !sessionTemplate(for: kind).isEmpty
    }

    /// Builds the argv that carries one confirmed message to an existing session (ADR 0030).
    ///
    /// The same mechanism as ``AgentCLIKind/custom(commandTemplate:)``, deliberately: the
    /// template is split by ``ShellWords`` **first** and the placeholders are substituted into
    /// the already-split words **after**, so the message stays exactly one argv element no matter
    /// what the reviewer typed into it — no shell is involved anywhere, and a message containing
    /// quotes, semicolons or newlines cannot become a second command.
    ///
    /// The guardrails that apply here are the ones the *run* has: the worktree it runs in, the
    /// transcript kept locally, and "Shepherd never pushes". The turn and spend caps live in the
    /// template, for the reason the custom template gets no injected flags either — Shepherd does
    /// not know that the command a user configured accepts Claude Code's flags. ``extraArguments``
    /// is appended here as it is for every other invocation, so a flag the user added for their
    /// installation applies to this run too.
    ///
    /// The template's first word is the binary. A word with a `/` in it is used as the path it
    /// is; a bare word is resolved only when it *is* the CLI Shepherd located (which is what
    /// makes the shipped default, `claude …`, work with no path in it), because guessing at any
    /// other bare name would run something the user did not name.
    /// - Parameters:
    ///   - message: The message the reviewer confirmed, verbatim.
    ///   - session: The session it is addressed to.
    ///   - worktree: The worktree the run happens in, also `{worktree}`.
    ///   - executable: The located CLI, used for a bare first word.
    /// - Returns: The invocation to spawn.
    /// - Throws: ``Failure`` when no template is configured or it cannot produce a command.
    func sessionInvocation(
        message: String,
        session: SessionReference,
        worktree: URL,
        executable: URL?
    ) throws -> AgentInvocation {
        let template = sessionTemplate(for: session.kind)
        guard !template.isEmpty else { throw Failure.emptySessionTemplate }
        guard template.contains(AgentCLIKind.messagePlaceholder) else {
            throw Failure.sessionTemplateMissingMessagePlaceholder
        }
        let words: [String]
        do {
            words = try ShellWords.split(template)
        } catch {
            throw Failure.template(
                error.userFacingDescription
            )
        }
        guard let first = words.first, !first.isEmpty else { throw Failure.emptySessionTemplate }
        let expanded = words.map { word in
            word
                .replacingOccurrences(
                    of: AgentCLIKind.worktreePlaceholder,
                    with: worktree.path
                )
                .replacingOccurrences(
                    of: AgentCLIKind.sessionIDPlaceholder,
                    with: session.id
                )
                .replacingOccurrences(
                    of: AgentCLIKind.sessionURLPlaceholder,
                    with: session.url?.absoluteString ?? ""
                )
                // Last, so a session id or a worktree path that happens to contain the literal
                // text `{message}` cannot pull the message into a second place.
                .replacingOccurrences(
                    of: AgentCLIKind.messagePlaceholder,
                    with: message
                )
        }
        let binary = expanded.first ?? first
        let binaryURL: URL
        if binary.contains("/") || binary.hasPrefix("~") {
            binaryURL = URL(fileURLWithPath: (binary as NSString).expandingTildeInPath)
        } else if let executable, executable.lastPathComponent == binary {
            binaryURL = executable
        } else {
            throw Failure.executableNotFound
        }
        return AgentInvocation(
            executable: binaryURL,
            arguments: Array(expanded.dropFirst()) + extraArguments
        )
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
