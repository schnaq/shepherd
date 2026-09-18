import AppKit
import Foundation
import MetricKit

/// The MetricKit subscriber: crash, hang, CPU-exception and disk-write-exception reports, written
/// to a folder on this Mac and to nowhere else (ADR 0017).
///
/// Three properties are the whole design, and all three are about *not* doing things:
///
/// 1. **Opt-in at the registration, not at the write.** With the setting off, `add(_:)` is never
///    called, so MetricKit has no subscriber, hands Shepherd nothing, and there is nothing to
///    filter. Turning the toggle off calls `remove(_:)` and the app is back to having no
///    diagnostics mechanism at all.
/// 2. **No network, ever.** There is no uploader, no endpoint, no queue and no "send" button in
///    this file or anywhere near it. The reports are files; the user reads them, attaches them to
///    an issue if they want to, or deletes them. This is what keeps CONTRIBUTING.md's "no
///    telemetry, ever" line literally true rather than nearly true. *(ADR 0036 has since replaced
///    that line with an allow-listed, anonymous, one-click-off usage count — but nothing here
///    moved: there is still no uploader for a diagnostic report, and crash data is still not sent.)*
/// 3. **Metric payloads are dropped on the floor.** MetricKit's *other* delivery — daily
///    performance metrics, `MXMetricPayload` — is exactly the shape of thing Shepherd has no
///    business keeping, so the subscriber implements the method and does nothing in it. Not
///    implementing it would leave the same behaviour to chance; implementing it as an explicit
///    no-op states the decision where a reader looks for it.
///
/// Deliberately *not* `@MainActor`: `MXMetricManagerSubscriber` is an Objective-C protocol and
/// MetricKit does not promise which queue it calls back on. The two callbacks are therefore
/// `nonisolated`, and every piece of mutable state — the subscription flag — is behind a lock,
/// which also closes the small race between "user switched the toggle off" and a callback that was
/// already in flight.
final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// How the reporter reaches `MXMetricManager`: add the subscriber, or remove it.
    ///
    /// A seam, and a narrow one. The tests need to prove that switching the toggle off really
    /// *removes* the subscription — the whole opt-in promise rests on it — and they must do that
    /// without registering the test host with the real MetricKit, which would be a global side
    /// effect on the machine running the suite.
    typealias SubscriptionChange = @MainActor (any MXMetricManagerSubscriber, Bool) -> Void

    private let store: DiagnosticsStore
    private let changeSubscription: SubscriptionChange?
    private let lock = NSLock()
    private var isSubscribed = false

    /// Creates the reporter. Registers nothing: ``setSubscribed(_:)`` is what does that, and only
    /// when the user has asked for it.
    /// - Parameters:
    ///   - store: Where reports are written. Injectable for tests and previews.
    ///   - changeSubscription: Replaces the call into `MXMetricManager`. `nil` — the only value
    ///     the app ever passes — means the real one.
    init(
        store: DiagnosticsStore = DiagnosticsStore(),
        changeSubscription: SubscriptionChange? = nil
    ) {
        self.store = store
        self.changeSubscription = changeSubscription
        super.init()
    }

    // MARK: - Subscription

    /// Registers or removes the MetricKit subscription to match the opt-in setting.
    ///
    /// Idempotent, because it is called from three places that do not know about each other:
    /// launch, the Settings toggle, and an applied settings-sync document (ADR 0014) that carried
    /// the flag from another Mac.
    ///
    /// On the main actor because `MXMetricManager` is an AppKit-era singleton and the callers all
    /// live there anyway; the callbacks it leads to are not.
    /// - Parameter subscribed: Whether Shepherd should receive diagnostics.
    @MainActor
    func setSubscribed(_ subscribed: Bool) {
        lock.lock()
        let changed = subscribed != isSubscribed
        isSubscribed = subscribed
        lock.unlock()
        guard changed else { return }
        if let changeSubscription {
            changeSubscription(self, subscribed)
        } else if subscribed {
            MXMetricManager.shared.add(self)
        } else {
            MXMetricManager.shared.remove(self)
        }
    }

    /// Whether Shepherd is currently subscribed. Read by the tests and by nothing else.
    var isReceivingDiagnostics: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSubscribed
    }

    // MARK: - The folder

    /// Where the reports are, for the path line in Settings.
    var directory: URL { store.directory }

    /// How many reports are stored.
    var reportCount: Int { store.reportCount }

    /// Deletes every stored report.
    /// - Throws: The first removal error, if any.
    func deleteAllReports() throws {
        try store.deleteAll()
    }

    /// Reveals the reports in the Finder: the newest report when there is one, the folder itself
    /// when there is not.
    ///
    /// Creates the folder first, so the button does something sensible before the first crash
    /// instead of silently failing on a path that does not exist yet.
    @MainActor
    func revealInFinder() {
        try? store.createDirectoryIfNeeded()
        let target = store.newestReportURL ?? store.directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - MXMetricManagerSubscriber

    /// Daily performance metrics. Deliberately ignored — see the type's documentation.
    /// - Parameter payloads: The metric payloads, which are dropped.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}

    /// Crash, hang, CPU-exception and disk-write-exception reports for previous runs of the app.
    ///
    /// MetricKit delivers these on the *next* launch after the event, in a batch, which is why the
    /// Settings card says a report shows up after the next launch following a crash rather than
    /// pretending it appears when the app dies.
    /// - Parameter payloads: The diagnostic payloads. One file is written per payload that
    ///   actually carries a diagnostic; a payload carrying none is not written at all, so the
    ///   folder never fills up with empty reports.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock()
        defer { lock.unlock() }
        // The subscription may have been removed while this batch was in flight. With the toggle
        // off, nothing is stored — that is the promise, and this is where it is kept.
        guard isSubscribed else { return }
        for payload in payloads where Self.carriesDiagnostics(payload) {
            // A payload that cannot be written is dropped in silence. A crash reporter that toasts
            // at launch — or worse, blocks it — is a bigger problem than the report it lost, and
            // there is nothing the user could do about a failing write anyway.
            try? store.store(
                jsonRepresentation: payload.jsonRepresentation(),
                receivedAt: payload.timeStampEnd
            )
        }
    }

    /// Whether a payload carries any of the four diagnostics Shepherd keeps.
    ///
    /// MetricKit will happily deliver a payload whose diagnostic arrays are all empty; writing
    /// that out would cost a file, a retention slot and the user's attention for nothing.
    /// - Parameter payload: The payload to inspect.
    /// - Returns: `true` when at least one crash, hang, CPU-exception or disk-write-exception
    ///   diagnostic is present.
    private static func carriesDiagnostics(_ payload: MXDiagnosticPayload) -> Bool {
        let counts = [
            payload.crashDiagnostics?.count ?? 0,
            payload.hangDiagnostics?.count ?? 0,
            payload.cpuExceptionDiagnostics?.count ?? 0,
            payload.diskWriteExceptionDiagnostics?.count ?? 0,
        ]
        return counts.contains { $0 > 0 }
    }
}
