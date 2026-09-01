import AppKit
import Foundation
import ShepherdCore

/// `shepherd` — the companion command-line tool (ADR 0013).
///
/// The whole program is: read argv, build a `shepherd://` URL, hand it to LaunchServices. There
/// is deliberately nothing else in it — no GitHub client, no Keychain access, no database, no
/// configuration file. Everything it can ask for goes through the URL scheme, the same channel
/// Raycast or an n8n *Execute Command* node uses, so installing the CLI grants no capability
/// the app does not already expose to every process on the Mac. The argument grammar itself
/// lives in ``ShepherdCommandLine`` (ShepherdCore) next to the URL grammar it targets, and is
/// unit-tested there.
@main
struct ShepherdCLI {
    /// The tool's version. Tracks `CFBundleShortVersionString` in `project.yml`; bump both.
    static let version = "0.1.0"

    /// A usage error: the arguments could not be understood.
    static let usageExitCode: Int32 = 2
    /// The command was understood but the URL could not be handed over.
    static let failureExitCode: Int32 = 1

    /// The entry point.
    @MainActor
    static func main() {
        let invocation: ShepherdCommandLine.Invocation
        do {
            invocation = try ShepherdCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            complain(message)
            exit(usageExitCode)
        }

        switch invocation {
        case .help:
            print(ShepherdCommandLine.usage)
        case .version:
            print("shepherd \(version)")
        case .open(let link):
            open(deepLink: link)
        }
    }

    /// Hands a deep link to the app.
    ///
    /// `NSWorkspace` launches Shepherd if it is not running; the app then does the work (and
    /// queues the link until sign-in, when nobody is signed in). Because the answer arrives in
    /// the app's window rather than on stdout, success here means "the URL was accepted", which
    /// is the only thing a URL-scheme client can honestly report.
    @MainActor
    private static func open(deepLink link: DeepLink) {
        guard let url = link.url else {
            // Unreachable in practice: every link the parser produces serialises.
            complain("Could not build a shepherd:// URL for that command.")
            exit(failureExitCode)
        }
        guard NSWorkspace.shared.open(url) else {
            complain("Could not open \(url.absoluteString). Is Shepherd installed?")
            exit(failureExitCode)
        }
    }

    /// Writes one line to standard error.
    ///
    /// Console text is English and unlocalised, like the developer documentation — the app's
    /// `String(localized:)` rule covers its UI, not a developer tool's diagnostics.
    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data("shepherd: \(message)\n".utf8))
    }
}
