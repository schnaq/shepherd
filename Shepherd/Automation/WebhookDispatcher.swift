import Foundation
import Observation
import ShepherdCore

/// Why a webhook delivery did not happen.
///
/// Every one of these is *reported*, never escalated: a webhook is an integration the user
/// added, and a broken one must not be able to interrupt a review, a merge or a sweep
/// (ADR 0012). The descriptions exist for the status line in Settings and for the
/// "Send test event" button, which is the one place a webhook failure is worth a sentence.
enum WebhookError: Error, LocalizedError, Equatable {
    /// No URL is configured.
    case notConfigured
    /// The configured URL is not a URL.
    case invalidURL
    /// The URL is plain HTTP for something other than this machine.
    case insecureScheme(String)
    /// The envelope could not be encoded — a bug, not a user error.
    case malformedPayload
    /// The receiver answered with a non-2xx status.
    case rejected(status: Int)
    /// The request never got an answer.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "No webhook URL configured.")
        case .invalidURL:
            return String(localized: "That is not a valid URL.")
        case .insecureScheme(let host):
            return String(localized: "Refusing to send to \(host) over plain HTTP. Use https, or a URL on this machine.")
        case .malformedPayload:
            return String(localized: "The event could not be encoded.")
        case .rejected(let status):
            return String(localized: "The webhook answered \(status).")
        case .transport(let message):
            return String(localized: "The webhook could not be reached: \(message)")
        }
    }
}

/// The user's webhook configuration, assembled fresh for every delivery.
///
/// The non-secret half lives in ``AppSettings``/`UserDefaults`; ``secret`` is read from the
/// Keychain at the moment it is needed and is never persisted here.
struct WebhookConfiguration: Sendable, Equatable {
    /// Whether Shepherd may post events at all.
    var isEnabled: Bool
    /// The URL as the user typed it.
    var urlText: String
    /// Which events the user subscribed to.
    var events: Set<WebhookEventKind>
    /// The shared secret, or empty for unsigned deliveries.
    var secret: String

    /// Creates a configuration.
    init(
        isEnabled: Bool = false,
        urlText: String = "",
        events: Set<WebhookEventKind> = [],
        secret: String = ""
    ) {
        self.isEnabled = isEnabled
        self.urlText = urlText
        self.events = events
        self.secret = secret
    }

    /// Whether an event of this kind is to be delivered.
    ///
    /// ``WebhookEventKind/test`` is exempt from the subscription check because it only ever
    /// exists as a button press; it is *not* exempt from the enable toggle or the URL.
    /// - Parameter kind: The event kind.
    func wantsEvent(_ kind: WebhookEventKind) -> Bool {
        guard isEnabled, WebhookConfiguration.isUsable(urlText) else { return false }
        return kind == .test || events.contains(kind)
    }

    /// Whether a URL string is a destination Shepherd would post to at all.
    /// - Parameter text: The URL as typed.
    static func isUsable(_ text: String) -> Bool {
        (try? destination(text)) != nil
    }

    /// Validates the configured URL.
    ///
    /// `https` anywhere, `http` only for this machine: an n8n running on `localhost` is the
    /// common local-first case, and refusing plain HTTP to a remote host means a mistyped URL
    /// cannot quietly put pull-request titles on the wire in the clear.
    /// - Parameter text: The URL as typed.
    /// - Returns: The validated destination.
    /// - Throws: ``WebhookError`` describing what is wrong with it.
    static func destination(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebhookError.notConfigured }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { throw WebhookError.invalidURL }
        switch scheme {
        case "https":
            return url
        case "http":
            guard localHosts.contains(host.lowercased()) else {
                throw WebhookError.insecureScheme(host)
            }
            return url
        default:
            throw WebhookError.invalidURL
        }
    }

    private static let localHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]", "host.docker.internal",
    ]
}

/// One prepared POST: everything the transport needs and nothing it has to derive itself,
/// which is what lets the tests assert on the headers and on the exact body that was signed.
struct WebhookRequest: Sendable, Equatable {
    /// Where to post.
    var url: URL
    /// Which event this is, mirrored into a header so a receiver can route without parsing.
    var eventKind: WebhookEventKind
    /// The idempotency key, likewise mirrored into a header.
    var deliveryID: UUID
    /// The exact bytes to send — and the bytes ``signature`` was computed over.
    var body: Data
    /// `X-Shepherd-Signature`, when a secret is configured.
    var signature: String?
    /// How long one attempt may take.
    var timeout: TimeInterval
}

/// What one POST attempt reported.
struct WebhookResponse: Sendable, Equatable {
    /// The HTTP status, or `0` when there was no HTTP response.
    var status: Int

    /// Whether the receiver accepted the event.
    var isSuccess: Bool { (200..<300).contains(status) }

    /// Whether trying again could plausibly help.
    ///
    /// A `404` or a `401` will not fix itself in two seconds — a wrong URL or a rejected
    /// signature is a configuration problem — so only timeouts, throttling and server errors
    /// are retried.
    var isRetryable: Bool { status == 408 || status == 429 || status >= 500 }
}

/// The seam the dispatcher's tests drive instead of a network, in the same spirit as
/// ``ModelListing`` and ``AgentRunning``.
protocol WebhookPosting: Sendable {
    /// Posts one prepared request.
    /// - Parameter request: What to send.
    /// - Returns: The status the receiver answered with.
    /// - Throws: ``WebhookError/transport(_:)`` when there was no answer.
    func post(_ request: WebhookRequest) async throws -> WebhookResponse
}

/// The production transport.
///
/// A plain `URLSession` call: this is the *only* place in Shepherd that opens a connection to a
/// host the user typed, and it sends nothing but the envelope.
struct URLSessionWebhookPoster: WebhookPosting {
    /// A shared instance; the type is stateless.
    static let shared = URLSessionWebhookPoster()

    /// Creates a poster.
    init() {}

    func post(_ request: WebhookRequest) async throws -> WebhookResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Shepherd", forHTTPHeaderField: "user-agent")
        urlRequest.setValue(request.eventKind.rawValue, forHTTPHeaderField: "X-Shepherd-Event")
        urlRequest.setValue(
            request.deliveryID.uuidString.lowercased(),
            forHTTPHeaderField: "X-Shepherd-Delivery"
        )
        if let signature = request.signature {
            urlRequest.setValue(signature, forHTTPHeaderField: WebhookSignature.headerName)
        }
        urlRequest.httpBody = request.body

        do {
            let (_, response) = try await CredentialSafeSession.shared.data(for: urlRequest)
            return WebhookResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw WebhookError.transport(error.localizedDescription)
        }
    }
}

/// Delivers events to the one URL the user configured (ADR 0012).
///
/// Three properties are the whole design:
///
/// - **It cannot block anything.** ``deliver(_:configuration:)`` never throws and is always
///   called from a detached task, so a webhook that hangs for its full ten-second timeout
///   delays only itself — not the review, the merge or the sweep that produced the event.
/// - **It barely retries.** Two attempts, one two-second wait between them, and only for
///   failures a retry could fix. A queue with persistence would be a second outbox, and a
///   webhook that missed one event is not worth that; the sync engine's outbox is the thing
///   that guarantees delivery, and it guarantees it *to GitHub*.
/// - **It is quiet.** The only trace of a failure is ``lastDelivery``, which Settings renders
///   as a single line. Nothing toasts, nothing alerts, nothing is logged.
///
/// `@MainActor` rather than an actor, matching the rest of the app layer: the work is one
/// `URLSession` await and a hash, and being main-actor-bound is what makes ``lastDelivery``
/// directly observable by the settings tab.
@MainActor
@Observable
final class WebhookDispatcher {
    /// What the last delivery amounted to.
    struct Delivery: Sendable, Equatable {
        /// Which event it was.
        var event: WebhookEventKind
        /// When the attempt finished.
        var at: Date
        /// How many attempts were made.
        var attempts: Int
        /// The failure description, or `nil` when it succeeded.
        var failure: String?

        /// Whether the receiver accepted it.
        var isSuccess: Bool { failure == nil }

        /// The one line Settings shows.
        var summary: String {
            if let failure {
                return String(localized: "Last delivery failed (\(event.rawValue)): \(failure)")
            }
            return String(localized: "Last delivery succeeded (\(event.rawValue)).")
        }
    }

    /// How many attempts one event gets in total.
    static let attemptLimit = 2
    /// How long to wait before the second attempt.
    static let retryDelay = Duration.seconds(2)
    /// How long one attempt may take.
    static let timeout: TimeInterval = 10

    /// The last delivery this launch, for the status line in Settings. Not persisted.
    private(set) var lastDelivery: Delivery?

    private let poster: any WebhookPosting
    private let sleeper: any Sleeping
    private let now: @Sendable () -> Date

    /// Creates a dispatcher.
    /// - Parameters:
    ///   - poster: The transport; tests pass a recorder instead of a network.
    ///   - sleeper: The backoff abstraction; tests pass one that does not wait.
    ///   - now: Clock injection point for tests.
    init(
        poster: any WebhookPosting = URLSessionWebhookPoster.shared,
        sleeper: any Sleeping = SystemSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.poster = poster
        self.sleeper = sleeper
        self.now = now
    }

    /// Delivers an event if the configuration asks for it. Never throws.
    /// - Parameters:
    ///   - event: The envelope.
    ///   - configuration: The user's webhook configuration.
    func deliver(_ event: WebhookEvent, configuration: WebhookConfiguration) async {
        guard configuration.wantsEvent(event.event) else { return }
        let result = await perform(event, configuration: configuration)
        record(event.event, result)
    }

    /// Delivers the test event and reports what happened.
    ///
    /// The only entry point that throws, because here the press *is* the request for feedback.
    /// It ignores the subscription checkboxes and the enable toggle — a button that only works
    /// once the feature is already switched on would be useless for setting it up — but it
    /// still refuses to send anywhere except the URL in the field.
    /// - Parameter configuration: The user's webhook configuration.
    /// - Throws: ``WebhookError`` describing why nothing arrived.
    func deliverTestEvent(configuration: WebhookConfiguration) async throws {
        let event = WebhookEvent.testEvent(occurredAt: now())
        let result = await perform(event, configuration: configuration)
        record(.test, result)
        if let failure = result.failure { throw failure }
    }

    // MARK: - Plumbing

    private func record(_ kind: WebhookEventKind, _ result: (attempts: Int, failure: WebhookError?)) {
        lastDelivery = Delivery(
            event: kind,
            at: now(),
            attempts: result.attempts,
            failure: result.failure?.errorDescription
        )
    }

    private func perform(
        _ event: WebhookEvent,
        configuration: WebhookConfiguration
    ) async -> (attempts: Int, failure: WebhookError?) {
        let url: URL
        let body: Data
        do {
            url = try WebhookConfiguration.destination(configuration.urlText)
            body = try event.canonicalJSON()
        } catch let error as WebhookError {
            return (0, error)
        } catch {
            return (0, .malformedPayload)
        }

        // Built once and reused for the retry: the same bytes, and therefore the same
        // signature and the same delivery id, so a receiver that saw the first attempt can
        // recognise the second as a duplicate.
        let request = WebhookRequest(
            url: url,
            eventKind: event.event,
            deliveryID: event.deliveryID,
            body: body,
            signature: WebhookSignature.header(for: body, secret: configuration.secret),
            timeout: WebhookDispatcher.timeout
        )

        var attempts = 0
        var lastFailure: WebhookError?
        while attempts < WebhookDispatcher.attemptLimit {
            attempts += 1
            var failure: WebhookError
            do {
                let response = try await poster.post(request)
                if response.isSuccess { return (attempts, nil) }
                failure = .rejected(status: response.status)
                guard response.isRetryable else { return (attempts, failure) }
            } catch let error as WebhookError {
                failure = error
            } catch {
                failure = .transport(error.localizedDescription)
            }
            lastFailure = failure
            guard attempts < WebhookDispatcher.attemptLimit else { break }
            do {
                try await sleeper.sleep(for: WebhookDispatcher.retryDelay)
            } catch {
                // The app is quitting, or the task was cancelled. One missed webhook is the
                // right price for shutting down promptly.
                break
            }
        }
        return (attempts, lastFailure)
    }
}
