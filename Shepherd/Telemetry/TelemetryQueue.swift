import Foundation

/// One event, as it waits on disk (ADR 0036).
struct QueuedEvent: Codable, Equatable, Sendable {
    /// The allow-listed event name.
    let name: String
    /// The UTC day the event happened on — the only time resolution that is ever sent.
    let day: String
    /// The `distinct_id` in force when it was recorded.
    let distinctID: String
    /// The event's own properties.
    let properties: [String: TelemetryValue]
}

/// The file of events not yet sent (ADR 0036).
///
/// A file rather than the database on purpose: the point of "Zeigen, was gesendet würde" is that a
/// user can open this in TextEdit and read every byte that would leave the Mac, and a SQLite table
/// is not readable like that. It is capped so that an offline month cannot grow it without bound,
/// and it is deleted — not emptied — when telemetry is switched off.
///
/// Not an actor: like ``DiagnosticsStore`` it does blocking file I/O and its only caller is the
/// main actor.
@MainActor
final class TelemetryQueue {
    /// How many events are kept. The oldest are dropped when a new one arrives.
    static let capacity = 500

    /// The folder the queue file lives in.
    let directory: URL

    /// The queue file itself.
    var fileURL: URL { directory.appendingPathComponent("queue.json", isDirectory: false) }

    private let fileManager: FileManager

    /// Creates the queue.
    /// - Parameters:
    ///   - directory: Where `queue.json` lives. Injected so tests never touch Application Support.
    ///   - fileManager: The file manager to use.
    init(directory: URL = AppConfig.telemetryDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Every stored event, oldest first. A missing or unreadable file is an empty queue, never an
    /// error: it is the state of every install that has not recorded anything yet.
    /// - Returns: The queued events.
    func load() -> [QueuedEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([QueuedEvent].self, from: data)) ?? []
    }

    /// Appends an event, dropping the oldest when the cap is reached.
    /// - Parameter event: The event to store.
    func append(_ event: QueuedEvent) {
        var events = load()
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        write(events)
    }

    /// Drops the first `count` events — what a successful flush sent — and keeps whatever was
    /// recorded while the request was in flight.
    /// - Parameter count: How many events to drop.
    func remove(_ count: Int) {
        guard count > 0 else { return }
        var events = load()
        events.removeFirst(min(count, events.count))
        write(events)
    }

    /// Deletes the queue file. Called when the level goes to `off`.
    func deleteAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func write(_ events: [QueuedEvent]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
