import Foundation

/// An abstraction over "wait for a while" so that poll loops, retry backoff and rate-limit
/// handling can be unit-tested without wall-clock delays.
///
/// Production code uses ``SystemSleeper``; tests inject a recorder that returns immediately.
public protocol Sleeping: Sendable {
    /// Suspends the current task for the given duration.
    /// - Parameter duration: How long to wait.
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    func sleep(for duration: Duration) async throws
}

/// The production ``Sleeping`` implementation, backed by `Task.sleep(for:)`.
public struct SystemSleeper: Sleeping {
    /// Creates a system sleeper.
    public init() {}

    /// Suspends the current task for the given duration.
    /// - Parameter duration: How long to wait.
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    public func sleep(for duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }
}

/// A ``Sleeping`` implementation that never actually waits but records what it was asked to
/// wait for. Intended for tests.
public actor RecordingSleeper: Sleeping {
    /// Every duration this sleeper was asked to wait for, in order.
    public private(set) var recorded: [Duration] = []

    /// Creates a recording sleeper.
    public init() {}

    /// Records the duration and returns immediately.
    /// - Parameter duration: The duration that would have been waited for.
    public func sleep(for duration: Duration) async throws {
        recorded.append(duration)
        try Task.checkCancellation()
        await Task.yield()
    }

    /// Forgets all recorded durations.
    public func reset() {
        recorded.removeAll()
    }
}

extension Duration {
    /// The duration expressed as fractional seconds.
    ///
    /// Convenience for tests and for interoperating with APIs that speak `TimeInterval`
    /// (GitHub's `Retry-After` and `X-Poll-Interval` headers, for instance).
    public var inSeconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
