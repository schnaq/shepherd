import Foundation

/// How a batch of events leaves the Mac. One method, so the tests can watch it without a network.
protocol TelemetrySender: Sendable {
    /// Sends events, oldest first.
    /// - Parameter events: The batch to send.
    func send(_ events: [QueuedEvent]) async throws
}

/// The PostHog EU request body (ADR 0036).
///
/// Separate from the sender because the body is the whole privacy claim: the four properties that
/// suppress person profiles and IP handling, the day-resolution timestamp, and nothing else. A
/// test can assert on bytes here without a URL loading system in the way.
enum PostHogBatchBody {
    /// Builds the `/batch/` body.
    /// - Parameters:
    ///   - apiKey: The project's public write key.
    ///   - events: The queued events, oldest first.
    ///   - appVersion: `CFBundleShortVersionString`.
    ///   - osMajor: The macOS major version.
    ///   - language: `de` or `en`.
    /// - Returns: The JSON body.
    /// - Throws: An encoding error, which the caller treats as a failed flush.
    static func make(
        apiKey: String,
        events: [QueuedEvent],
        appVersion: String,
        osMajor: Int,
        language: String
    ) throws -> Data {
        let batch: [[String: Any]] = events.map { event in
            var properties: [String: Any] = [
                "distinct_id": event.distinctID,
                // No person object is created, so nothing accumulates a history. Unique counting
                // still works off `distinct_id` on the events themselves.
                "$process_person_profile": false,
                // Present and null, not absent: PostHog's GeoIP step falls back to the sender's
                // address when the property is missing.
                "$ip": NSNull(),
                "$lib": "shepherd",
                "app_version": appVersion,
                "os_major": osMajor,
                "locale": language,
            ]
            for (key, value) in event.properties {
                switch value {
                case .flag(let flag): properties[key] = flag
                case .number(let number): properties[key] = number
                case .choice(let raw): properties[key] = raw
                }
            }
            return [
                "event": event.name,
                "timestamp": "\(event.day)T00:00:00Z",
                "properties": properties,
            ]
        }

        return try JSONSerialization.data(
            withJSONObject: ["api_key": apiKey, "batch": batch],
            options: [.sortedKeys]
        )
    }
}

/// Posts batches to PostHog's EU ingest endpoint (ADR 0036).
///
/// No SDK: one `POST` with a JSON body, through ``CredentialSafeSession`` like every other request
/// in the app that must not hand anything to a redirect it did not choose.
struct PostHogSender: TelemetrySender {
    private let apiKey: String
    private let appVersion: String
    private let osMajor: Int
    private let language: String
    private let session: URLSession
    private let endpoint: URL

    /// Creates the sender.
    /// - Parameters:
    ///   - apiKey: The public project key.
    ///   - appVersion: The version to report.
    ///   - osMajor: The macOS major version to report.
    ///   - language: `de` or `en`.
    ///   - session: The URL session to use.
    ///   - endpoint: The ingest URL. Injectable for tests.
    init(
        apiKey: String,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        language: String = PostHogSender.language(for: .current),
        session: URLSession = CredentialSafeSession.shared,
        endpoint: URL = AppConfig.postHogBatchURL
    ) {
        self.apiKey = apiKey
        self.appVersion = appVersion
        self.osMajor = osMajor
        self.language = language
        self.session = session
        self.endpoint = endpoint
    }

    /// The reported language: the UI Shepherd is actually showing, which is German or English and
    /// nothing else (ADR 0022).
    /// - Parameter locale: The locale to reduce.
    /// - Returns: `de` or `en`.
    static func language(for locale: Locale) -> String {
        locale.language.languageCode?.identifier == "de" ? "de" : "en"
    }

    func send(_ events: [QueuedEvent]) async throws {
        guard !events.isEmpty else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try PostHogBatchBody.make(
            apiKey: apiKey,
            events: events,
            appVersion: appVersion,
            osMajor: osMajor,
            language: language
        )

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
