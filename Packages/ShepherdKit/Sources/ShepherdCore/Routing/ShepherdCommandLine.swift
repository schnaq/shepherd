import Foundation

/// The `shepherd` CLI's argument grammar: argv in, a ``DeepLink`` out (ADR 0013).
///
/// The CLI is a URL builder and nothing more — it has no network code, no token, no database
/// and no knowledge of GitHub. Everything it can ask for, it asks for through the URL scheme,
/// which is the same channel Raycast, n8n or a shell script uses. This type is that mapping,
/// kept next to ``DeepLink`` on purpose: the grammar the CLI writes and the grammar the app
/// reads are one source of truth, tested together, and neither can drift.
///
/// ```
/// shepherd open <owner>/<repo>#<number>
/// shepherd open <owner>/<repo>/<number>
/// shepherd open https://github.com/<owner>/<repo>/pull/<number>
/// shepherd inbox [<filter> | --filter <filter>]
/// shepherd sync
/// shepherd settings [<tab>]
/// shepherd --help | --version
/// ```
public enum ShepherdCommandLine {
    /// What one invocation asks for.
    public enum Invocation: Hashable, Sendable {
        /// Hand a deep link to the app.
        case open(DeepLink)
        /// Print the usage text.
        case help
        /// Print the version.
        case version
    }

    /// Why an invocation could not be understood.
    ///
    /// The messages are plain English, deliberately not localised: console output follows the
    /// developer documentation, not the app's UI language rules (`CONTRIBUTING.md`).
    public enum Failure: LocalizedError, Equatable {
        /// The first argument is not a known command.
        case unknownCommand(String)
        /// A command needs an argument that was not given.
        case missingArgument(command: String, expected: String)
        /// There were more arguments than the command takes.
        case unexpectedArgument(String)
        /// An option the command does not have.
        case unknownOption(String)
        /// The pull-request reference is not `owner/repo#number` or a github.com pull URL.
        case invalidPullRequestReference(String)
        /// The inbox filter is not one of the known tokens.
        case invalidInboxFilter(String)
        /// The settings tab is not one of the known tabs.
        case unknownSettingsTab(String)

        public var errorDescription: String? {
            switch self {
            case .unknownCommand(let command):
                return "Unknown command “\(command)”. Run “shepherd --help”."
            case .missingArgument(let command, let expected):
                return "“shepherd \(command)” needs \(expected)."
            case .unexpectedArgument(let argument):
                return "Unexpected argument “\(argument)”."
            case .unknownOption(let option):
                return "Unknown option “\(option)”."
            case .invalidPullRequestReference(let reference):
                return """
                    Could not read “\(reference)” as a pull request. Use owner/repo#123, \
                    owner/repo/123, or a https://github.com/owner/repo/pull/123 URL.
                    """
            case .invalidInboxFilter(let filter):
                return """
                    Unknown inbox filter “\(filter)”. Use one of \
                    \(InboxDeepLinkFilter.keywordTokens.joined(separator: ", ")), \
                    agent:<id> or repo:<owner>/<name>.
                    """
            case .unknownSettingsTab(let tab):
                return """
                    Unknown settings tab “\(tab)”. Use one of \
                    \(SettingsDeepLinkTab.allCases.map(\.token).joined(separator: ", ")).
                    """
            }
        }
    }

    /// The usage text printed by `--help` and by a bare `shepherd`.
    public static let usage = """
        shepherd — drive Shepherd, the macOS review inbox, from the command line.

        USAGE
          shepherd open <pull request>     Open a pull request in Shepherd's review screen
          shepherd inbox [<filter>]        Show the inbox, optionally filtered
          shepherd sync                    Sweep every repository now
          shepherd settings [<tab>]        Open Settings on a tab
          shepherd --help | --version

        PULL REQUEST
          owner/repo#123
          owner/repo/123
          https://github.com/owner/repo/pull/123

        INBOX FILTERS
          needs-my-review, mine, involved, approved-by-me
          humans, bots, agent:<id>, repo:<owner>/<name>

        SETTINGS TABS
          account, sync, agents, intelligence, delegation, automation, appearance

        EXAMPLES
          shepherd open schnaq/review#42
          shepherd inbox needs-my-review
          shepherd inbox --filter agent:claude-code
          shepherd sync

        Every command works by opening a shepherd:// URL, so Shepherd itself does the work —
        the CLI never talks to GitHub and never sees a token.
        """

    /// Parses one invocation.
    /// - Parameter arguments: argv **without** the executable name.
    /// - Returns: What the invocation asks for.
    /// - Throws: ``Failure`` when the arguments cannot be understood.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        guard let command = arguments.first else { return .help }
        if arguments.contains(where: { $0 == "--help" || $0 == "-h" || $0 == "help" }) {
            return .help
        }
        if arguments.contains(where: { $0 == "--version" || $0 == "-v" || $0 == "version" }) {
            return .version
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "open":
            guard let reference = rest.first else {
                throw Failure.missingArgument(command: "open", expected: "a pull request")
            }
            if let extra = rest.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            guard let link = pullRequestLink(for: reference) else {
                throw Failure.invalidPullRequestReference(reference)
            }
            return .open(link)

        case "inbox":
            guard let token = try filterToken(in: rest) else { return .open(.inbox(filter: nil)) }
            guard let filter = InboxDeepLinkFilter(token: token) else {
                throw Failure.invalidInboxFilter(token)
            }
            return .open(.inbox(filter: filter))

        case "sync":
            if let extra = rest.first { throw Failure.unexpectedArgument(extra) }
            return .open(.sync)

        case "settings":
            guard let token = rest.first else { return .open(.settings(tab: .account)) }
            if let extra = rest.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            guard let tab = SettingsDeepLinkTab(token: token) else {
                throw Failure.unknownSettingsTab(token)
            }
            return .open(.settings(tab: tab))

        default:
            throw Failure.unknownCommand(command)
        }
    }

    /// Reads the inbox filter from `inbox`'s arguments, positional or as `--filter`.
    private static func filterToken(in arguments: [String]) throws -> String? {
        guard let first = arguments.first else { return nil }
        if first == "--filter" {
            guard let value = arguments.dropFirst().first else {
                throw Failure.missingArgument(command: "inbox --filter", expected: "a filter")
            }
            if let extra = arguments.dropFirst(2).first {
                throw Failure.unexpectedArgument(extra)
            }
            return value
        }
        if let value = optionValue(of: first, named: "--filter") {
            if let extra = arguments.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            return value
        }
        if first.hasPrefix("-") { throw Failure.unknownOption(first) }
        if let extra = arguments.dropFirst().first { throw Failure.unexpectedArgument(extra) }
        return first
    }

    /// The value of a `--name=value` argument.
    /// - Parameters:
    ///   - argument: The argument to read.
    ///   - name: The option including its dashes, e.g. `"--filter"`.
    /// - Returns: The value, or `nil` when the argument is not that option in `=` form.
    private static func optionValue(of argument: String, named name: String) -> String? {
        let prefix = name + "="
        guard argument.hasPrefix(prefix) else { return nil }
        return String(argument.dropFirst(prefix.count))
    }

    /// Reads the three accepted spellings of a pull-request reference.
    ///
    /// Pure string work: the github.com form is accepted because that is what a browser puts on
    /// the clipboard, not because the CLI ever fetches it.
    static func pullRequestLink(for reference: String) -> DeepLink? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return gitHubPullRequestLink(for: trimmed)
        }

        // owner/repo#123
        if let hash = trimmed.lastIndex(of: "#") {
            let fullName = String(trimmed[trimmed.startIndex..<hash])
            let numberText = String(trimmed[trimmed.index(after: hash)...])
            return link(fullName: fullName, number: numberText)
        }
        // owner/repo/123
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return link(fullName: "\(parts[0])/\(parts[1])", number: String(parts[2]))
    }

    /// `https://github.com/<owner>/<repo>/pull/<number>`, with anything after the number
    /// (`/files`, a query, a comment anchor) ignored.
    private static func gitHubPullRequestLink(for reference: String) -> DeepLink? {
        guard let components = URLComponents(string: reference),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        let segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        guard segments.count >= 4, segments[2].lowercased() == "pull" else { return nil }
        return link(fullName: "\(segments[0])/\(segments[1])", number: segments[3])
    }

    private static func link(fullName: String, number: String) -> DeepLink? {
        guard let repo = DeepLinkValidation.repository(fullName: fullName),
              let number = DeepLinkValidation.number(number)
        else { return nil }
        return .pullRequest(repo: repo, number: number)
    }
}
