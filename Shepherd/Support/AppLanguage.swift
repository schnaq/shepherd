import AppKit
import Foundation

/// The language Shepherd's own UI is shown in, independent of the Mac's.
///
/// Stored where macOS itself keeps a per-app language — `AppleLanguages` in the app's own defaults
/// domain, the key System Settings → General → Language & Region → Applications writes. So the
/// picker in Settings and the system's per-app setting are one setting seen from two places, and
/// "System" is the absence of the key rather than a value of ours. Device-local on purpose, and not
/// in the synced settings document (ADR 0014): a German Mac and an English one may well want
/// different answers.
///
/// Bundles read their localization once, at launch, so a change applies after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the Mac's preferred languages.
    case system
    /// English, the development language.
    case english = "en"
    /// German (ADR 0022).
    case german = "de"

    var id: String { rawValue }

    /// The picker label. The languages are named in themselves, as macOS names them, so someone
    /// who switched to a language they do not read can still find the way back.
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    private static let key = "AppleLanguages"

    /// The app's own choice — the app domain only, never the global list the Mac falls back to.
    static var current: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String],
              let first = languages.first
        else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    /// The choice this process was launched with — what the UI is showing now, whatever the
    /// picker says since. Read first by the Settings pane, before it can write a new choice.
    static let atLaunch = current

    /// Writes the choice for the next launch.
    func apply() {
        #if DEBUG
        // The demo shares the installed app's bundle id; its choice must not leak into the real one.
        if DemoMode.isActive { return }
        #endif
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// Quits and opens Shepherd again, so a language change takes effect.
    ///
    /// The new copy is opened by a small shell that waits for this process to exit first: two
    /// Shepherds at once would share one database and one Keychain item.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            // Without the helper there is nothing to reopen the app; stay open rather than vanish.
        }
    }
}
