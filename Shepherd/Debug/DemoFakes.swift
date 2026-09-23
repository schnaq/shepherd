#if DEBUG
import Foundation
import GitHubKit
import Synchronization

/// The demo mode's Keychain: a dictionary that lives exactly as long as the process.
///
/// Behind the same ``KeychainStoring`` seam the system Keychain sits behind, so the token store,
/// the AI keys, the webhook secret and the settings-sync credentials all land here without any of
/// their callers knowing. The real Keychain is never read — which also means an ad-hoc-signed
/// Debug build never raises an access prompt over the window being screenshotted.
final class DemoKeychain: KeychainStoring {
    private let items = Mutex<[String: Data]>([:])

    func readData(service: String, account: String) throws -> Data? {
        items.withLock { $0[Self.key(service, account)] }
    }

    func writeData(_ data: Data, service: String, account: String) throws {
        items.withLock { $0[Self.key(service, account)] = data }
    }

    func delete(service: String, account: String) throws {
        _ = items.withLock { $0.removeValue(forKey: Self.key(service, account)) }
    }

    private static func key(_ service: String, _ account: String) -> String {
        "\(service)\u{1F}\(account)"
    }
}

/// The demo mode's network: every request is refused at once.
///
/// Refusing rather than answering from the seed on purpose. The seed is written straight into the
/// database, and an answer — even an empty search result — would be something a sweep could act
/// on: `savePullRequestSummaries(_:pruneMissing:)` would take the whole seeded inbox away. A
/// failure is the one answer every caller already treats as "keep what is on disk".
///
/// `forbidden` rather than `transport`, because a transport failure is retryable: the client would
/// back off and try again for several seconds, and a panel waiting on it would sit on its spinner
/// through the screenshot. The sweep loop is not started in demo mode, so this is only reached by
/// a panel's own read or by something a person clicked.
struct DemoTransport: HTTPTransport {
    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        throw GitHubError.forbidden(message: "Demo mode never talks to GitHub.")
    }
}

/// The demo mode's Spotlight index: accepts everything and writes nothing.
///
/// Core Spotlight is keyed by bundle id, so the real index would be the installed app's: the demo
/// would put fake pull requests into the developer's Spotlight, and switching the export off would
/// delete the real app's items along with them.
struct DemoSpotlightIndex: SpotlightIndexing {
    func index(_ items: [SpotlightItemFields]) async -> Bool { true }

    func delete(identifiers: [String]) async -> Bool { true }

    func deleteDomain() async -> Bool { true }
}
#endif
