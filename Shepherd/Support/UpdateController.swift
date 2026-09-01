import Foundation
import Observation
import Sparkle

/// Why the updater is not running.
///
/// A build can be perfectly valid and still have no working update feed — a fork that has not
/// registered its own signing key, or this repository before the maintainer has run
/// `generate_keys` for the first time (docs/RELEASING.md). That is a *state of the build*, not an
/// error to report to the user mid-session, so it is a value the UI reads rather than a thrown
/// error or a log line.
enum UpdateProblem: Equatable, Sendable {
    /// `SUFeedURL` is absent, empty, or not an absolute `http(s)` URL.
    case noFeedURL
    /// `SUPublicEDKey` is absent or is not a base64 ed25519 public key — the placeholder
    /// `project.yml` ships until the real key is pasted in.
    case unusablePublicKey
    /// Sparkle itself refused to start; the string is its own description of why.
    case couldNotStart(String)

    /// The one line Settings shows under the toggle.
    var explanation: String {
        switch self {
        case .noFeedURL:
            return String(localized: "This build has no update feed, so it will never offer an update. Releases from github.com/schnaq/review do.")
        case .unusablePublicKey:
            return String(localized: "This build has no update-signing key yet, so updates are switched off rather than unverified. Releases from github.com/schnaq/review are signed.")
        case .couldNotStart(let reason):
            return String(localized: "The updater could not start: \(reason)")
        }
    }
}

/// What the app's `Info.plist` says about updates.
///
/// Read once, from a plain dictionary rather than straight from `Bundle`, so the validation below
/// is testable without a bundle to fake.
struct UpdateConfiguration: Equatable, Sendable {
    /// The appcast URL from `SUFeedURL`, when it is a usable absolute web URL.
    let feedURL: URL?
    /// The raw `SUPublicEDKey` string, whatever it contains.
    let publicKey: String?

    /// Reads the configuration out of an `Info.plist` dictionary.
    /// - Parameter info: The bundle's info dictionary.
    init(info: [String: Any]) {
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let feed, let url = URL(string: feed), let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http", url.host != nil {
            feedURL = url
        } else {
            feedURL = nil
        }
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        publicKey = (key?.isEmpty ?? true) ? nil : key
    }

    /// Reads the configuration out of a bundle.
    /// - Parameter bundle: The bundle to read. Defaults to the running app.
    init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    /// Whether a string is an ed25519 public key Sparkle can actually use.
    ///
    /// Checked by shape rather than against the literal placeholder in `project.yml`: an
    /// ed25519 public key is exactly 32 bytes, so this rejects the placeholder, an empty string,
    /// a truncated paste and a key with a stray newline in it alike — and keeps working if the
    /// placeholder text is ever reworded.
    /// - Parameter key: The candidate key.
    /// - Returns: `true` when it base64-decodes to 32 bytes.
    static func isUsable(publicKey key: String?) -> Bool {
        guard let key, let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }

    /// What is missing, or `nil` when the build is fully configured for updates.
    var problem: UpdateProblem? {
        if feedURL == nil { return .noFeedURL }
        if !Self.isUsable(publicKey: publicKey) { return .unusablePublicKey }
        return nil
    }
}

/// Sparkle 2, wrapped so that the rest of the app never imports it (ADR 0010).
///
/// Two things this wrapper exists for:
///
/// 1. **It refuses to start an updater that cannot work.** `SPUStandardUpdaterController`'s own
///    `startUpdater()` reports a misconfigured `Info.plist` by logging and then putting an alert
///    in front of the user a few seconds after launch, telling them to contact the developer.
///    That is the right behaviour for a shipped app whose feed broke and exactly the wrong one
///    for a source build or a fork that has no signing key yet — which is every build until
///    `generate_keys` has been run once. So the controller is created with
///    `startingUpdater: false`, the configuration is validated here, and the updater is started
///    through the throwing `SPUUpdater.startUpdater()` only when it can succeed. A build without
///    keys gets a disabled menu item and one explanatory line in Settings; it never gets an
///    alert and it never crashes.
/// 2. **It makes Sparkle's state observable.** `automaticallyChecksForUpdates` is a KVO property
///    on `SPUUpdater`, which SwiftUI does not watch. The toggle in Settings binds to the mirror
///    below, and Sparkle keeps persisting the value in the host's user defaults itself — so
///    unlike every other preference, this one deliberately does *not* live in ``AppSettings``.
@MainActor
@Observable
final class UpdateController {
    /// What the `Info.plist` said.
    let configuration: UpdateConfiguration

    /// Why updates are off, or `nil` when the updater is running.
    private(set) var problem: UpdateProblem?

    /// Whether Sparkle checks for updates on its own.
    ///
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. Reads `false` and does nothing when
    /// there is no updater, which is what the disabled toggle in Settings wants.
    var checksAutomatically: Bool {
        didSet { updater?.automaticallyChecksForUpdates = checksAutomatically }
    }

    /// The standard controller, or `nil` when this build has no usable update configuration.
    ///
    /// Not part of the observation graph: it is an AppKit object with its own KVO, and nothing
    /// in SwiftUI should re-render because Sparkle touched it.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    /// Sparkle's updater, when there is one.
    private var updater: SPUUpdater? { controller?.updater }

    /// Whether updates are wired up and the menu item should do something.
    var isEnabled: Bool { controller != nil && problem == nil }

    /// The feed the app would check, for the line in Settings.
    var feedURL: URL? { configuration.feedURL }

    /// When Sparkle last completed a check, if it ever has.
    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }

    /// Creates the updater.
    ///
    /// Safe to call in any build: with no feed and no key it becomes an inert object that
    /// reports why.
    /// - Parameter configuration: What the `Info.plist` says. Injectable for tests and previews.
    init(configuration: UpdateConfiguration = UpdateConfiguration()) {
        self.configuration = configuration
        self.problem = configuration.problem
        guard configuration.problem == nil else {
            self.controller = nil
            self.checksAutomatically = false
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.checksAutomatically = controller.updater.automaticallyChecksForUpdates
        do {
            try controller.updater.startUpdater()
        } catch {
            // Reachable even with a valid feed and key — a damaged bundle, or an updater Sparkle
            // will not run for this host. Nothing is shown to the user beyond the Settings line:
            // an update mechanism that cannot start is not something they can act on.
            self.problem = .couldNotStart(error.localizedDescription)
        }
    }

    /// Checks for an update now, showing Sparkle's own progress and result windows.
    ///
    /// A failing check — the feed is 404 because no release has been published yet, or the
    /// machine is offline — surfaces as Sparkle's ordinary "could not check for updates" sheet.
    /// Does nothing at all when the build has no update configuration.
    func checkForUpdates() {
        guard let updater, problem == nil else { return }
        updater.checkForUpdates()
    }
}
