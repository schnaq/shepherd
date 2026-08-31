import Foundation

/// A counting semaphore for structured concurrency.
///
/// Shepherd uses it to cap how many pull-request detail fetches are in flight at once
/// (ADR 0005: firing every detail fetch of a sweep simultaneously is the one pattern that
/// reliably trips GitHub's secondary rate limit).
///
/// Waiters are served first-in-first-out, so a burst of detail fetches keeps its ordering.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a semaphore.
    /// - Parameter value: The number of concurrent holders allowed. Values below 1 are
    ///   clamped to 1.
    public init(value: Int) {
        self.permits = max(1, value)
    }

    /// Acquires a permit, suspending until one is free.
    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Releases a permit, waking the longest-waiting caller if there is one.
    public func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }

    /// Runs a body while holding a permit, releasing it even if the body throws.
    /// - Parameter body: The work to perform.
    /// - Returns: Whatever the body returned.
    public func withPermit<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await body()
    }

    /// The number of permits currently available. Intended for tests.
    public var availablePermits: Int { permits }
}
