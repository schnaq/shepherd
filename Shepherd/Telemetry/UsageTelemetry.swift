import Foundation

/// Usage telemetry, whole (ADR 0036).
///
/// The type exists *only* when telemetry may happen: ``make(settings:key:queue:sender:)`` answers
/// `nil` when this build has no PostHog key, when the level is `off`, or when the first-run notice
/// has not been answered yet. That is the same shape ``DiagnosticsReporter`` uses for MetricKit —
/// gate the mechanism, not the output — and it is why there is nothing here that filters events:
/// an event that must not be sent was never recorded, because this object did not exist.
@MainActor
final class UsageTelemetry {
    private(set) var level: TelemetryLevel
    private let identity: TelemetryIdentity
    private let heartbeat: TelemetryHeartbeat
    private let queue: TelemetryQueue
    private let sender: any TelemetrySender
    private let now: () -> Date
    private var flushTimer: Timer?

    /// How long after launch the first flush happens: late enough to stay off the launch path,
    /// early enough that a short session still reports.
    static let firstFlushDelay: TimeInterval = 30
    /// How often a running app flushes afterwards.
    static let flushInterval: TimeInterval = 24 * 60 * 60

    /// Creates the façade. Prefer ``make(settings:key:queue:sender:)``, which applies the gate.
    /// - Parameters:
    ///   - level: The level in force.
    ///   - identity: The `distinct_id` source.
    ///   - heartbeat: The once-a-day gate for `app_active_day`.
    ///   - queue: Where events wait.
    ///   - sender: How they leave.
    ///   - now: The clock, injected for tests.
    init(
        level: TelemetryLevel,
        identity: TelemetryIdentity,
        heartbeat: TelemetryHeartbeat,
        queue: TelemetryQueue,
        sender: any TelemetrySender,
        now: @escaping () -> Date = Date.init
    ) {
        self.level = level
        self.identity = identity
        self.heartbeat = heartbeat
        self.queue = queue
        self.sender = sender
        self.now = now
    }

    /// Builds the façade when — and only when — telemetry may happen.
    /// - Parameters:
    ///   - settings: The level and the acknowledgement flag.
    ///   - key: The build's PostHog key, `nil` in development builds and forks.
    ///   - queue: Where events wait.
    ///   - sender: How they leave. `nil` builds a ``PostHogSender`` for `key`.
    /// - Returns: The façade, or `nil` when nothing may be collected.
    static func make(
        settings: AppSettings,
        key: String? = AppConfig.postHogProjectKey,
        queue: TelemetryQueue = TelemetryQueue(),
        sender: (any TelemetrySender)? = nil
    ) -> UsageTelemetry? {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.telemetryLevel.sendsEvents, settings.telemetryNoticeAcknowledged
        else { return nil }
        return UsageTelemetry(
            level: settings.telemetryLevel,
            identity: TelemetryIdentity(),
            heartbeat: TelemetryHeartbeat(),
            queue: queue,
            sender: sender ?? PostHogSender(apiKey: key)
        )
    }

    // MARK: - Recording

    /// Queues one event.
    /// - Parameter event: What happened, from the allow-list and nowhere else.
    func record(_ event: TelemetryEvent) {
        guard level.sendsEvents else { return }
        let moment = now()
        queue.append(
            QueuedEvent(
                name: event.name,
                day: TelemetryDay.utcDay(moment),
                distinctID: identity.distinctID(for: level, now: moment),
                properties: event.properties
            )
        )
    }

    /// Queues the day-event unless this UTC day already has one.
    ///
    /// The closure is only called when the event is actually due, so counting repositories and
    /// reading feature flags costs nothing on the launches that will not report.
    /// - Parameter makeEvent: Builds the `app_active_day` event.
    func recordHeartbeatIfDue(_ makeEvent: () -> TelemetryEvent) {
        guard level.sendsEvents else { return }
        let moment = now()
        guard heartbeat.isDue(now: moment) else { return }
        heartbeat.markSent(now: moment)
        record(makeEvent())
    }

    // MARK: - Sending

    /// Starts the flush schedule: once shortly after launch, then once a day.
    func startFlushing() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstFlushDelay))
            await self?.flush()
        }
    }

    /// Sends what is queued and drops exactly what was sent. A failure keeps everything for the
    /// next flush; there is no retry loop, because a bad network must not become a busy one.
    func flush() async {
        let pending = queue.load()
        guard !pending.isEmpty else { return }
        do {
            try await sender.send(pending)
            queue.remove(pending.count)
        } catch {
            // Deliberately silent: a failed flush is not a thing to tell the user about, and the
            // events stay queued until the cap pushes the oldest out.
        }
    }

    // MARK: - Level changes

    /// Applies a new level, erasing whatever the new level may no longer hold.
    ///
    /// Withdrawal deletes: `off` takes the queue, the heartbeat day and the monthly identity with
    /// it, and leaving `reach` takes the identity. Consent that is withdrawn has to remove what it
    /// allowed, not merely stop adding to it.
    /// - Parameter newLevel: The level the user chose, or a settings document carried over.
    func apply(level newLevel: TelemetryLevel) {
        if !newLevel.usesStoredIdentity {
            identity.clearStoredIdentity()
        }
        if !newLevel.sendsEvents {
            queue.deleteAll()
            heartbeat.clear()
            flushTimer?.invalidate()
            flushTimer = nil
        }
        level = newLevel
    }

    /// Empties the queue on request — the "Warteschlange löschen" button.
    func clearQueue() {
        queue.deleteAll()
    }

    /// What is waiting to be sent, for the payload preview in Settings.
    var pendingEvents: [QueuedEvent] { queue.load() }

    /// Where the queue file is, for the path line in Settings.
    var queueFileURL: URL { queue.fileURL }
}
