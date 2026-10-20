import Foundation

/// Callers parked until the run they joined is over.
struct RunWaiters {
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]

    var count: Int { waiting.count }

    mutating func add(_ id: UUID, _ continuation: CheckedContinuation<Void, any Error>) {
        waiting[id] = continuation
    }

    mutating func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    mutating func resumeAll(with outcome: Result<Void, any Error>) {
        let parked = waiting
        waiting = [:]
        for continuation in parked.values { continuation.resume(with: outcome) }
    }
}

extension SyncEngine {
    enum Run: Sendable { case sweep, drain }

    /// Parks the caller until the running sweep or drain finishes, with its outcome. Cancelling
    /// the caller stops the wait, never the run: the run belongs to whoever started it.
    func waitFor(_ run: Run) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.park(id, run, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWait(id, run) }
        }
    }

    private func park(_ id: UUID, _ run: Run, _ continuation: CheckedContinuation<Void, any Error>) {
        switch run {
        case .sweep: sweepWaiters.add(id, continuation)
        case .drain: drainWaiters.add(id, continuation)
        }
    }

    private func cancelWait(_ id: UUID, _ run: Run) {
        switch run {
        case .sweep: sweepWaiters.cancel(id)
        case .drain: drainWaiters.cancel(id)
        }
    }
}
