import Foundation

/// The folder of local diagnostic reports: what a report is called, how one is written, how many
/// are kept, and how they are counted and removed (ADR 0017).
///
/// This is the whole feature minus MetricKit. It is a separate type from ``DiagnosticsReporter``
/// for one reason: `MXDiagnosticPayload` cannot be constructed, so the only testable seam is the
/// one *below* it — the JSON bytes and the moment they arrived. Everything interesting (the file
/// name, the retention trim, the count, "delete all") therefore lives here and is exercised over a
/// temporary directory, while the subscriber above stays a four-line adapter with nothing to get
/// wrong.
///
/// Not an actor and not `Sendable`: it holds a `FileManager` and does blocking file I/O, and its
/// caller is either the main actor (Settings) or ``DiagnosticsReporter``'s lock (MetricKit's
/// callback). Both serialise access, and neither wants an `await` in front of a directory listing.
struct DiagnosticsStore {
    /// How many reports are kept. The oldest are deleted when a new one arrives.
    ///
    /// Thirty is a volume cap, not a policy: a diagnostic payload is a few dozen kilobytes, and
    /// the point of the folder is "the last handful of crashes", not an archive.
    static let retentionLimit = 30

    /// Every report is named `diagnostic-<UTC timestamp>Z.json`.
    static let fileNamePrefix = "diagnostic-"
    /// The extension every report carries.
    static let fileExtension = "json"

    /// The folder the reports live in.
    let directory: URL

    private let fileManager: FileManager

    /// Creates a store.
    /// - Parameters:
    ///   - directory: Where the reports live. Injectable so the tests never touch the real
    ///     Application Support folder.
    ///   - fileManager: The file manager to use. Injectable for the same reason.
    init(
        directory: URL = AppConfig.diagnosticsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    // MARK: - Reading

    /// Every stored report, oldest first.
    ///
    /// Ordered by *file name* rather than by a filesystem date, which the fixed-width UTC stamp
    /// makes chronological, deterministic, and independent of whatever a copy, a restore or a
    /// backup tool did to the modification times. Two reports from the same second are ordered
    /// arbitrarily but consistently; which of the two a trim drops first does not matter.
    ///
    /// A folder that does not exist yet is not an error — it is the state of every install that
    /// has never had a crash — so this answers with an empty list.
    /// - Returns: The report files.
    func reportURLs() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { Self.isReportFileName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// How many reports are stored, for the line in Settings.
    var reportCount: Int { reportURLs().count }

    /// The newest report, or `nil` when there is none.
    ///
    /// Used by "Show in Finder", which selects the newest report when there is one so the user
    /// lands on the file they came for rather than on a folder.
    var newestReportURL: URL? { reportURLs().last }

    /// Whether a file name is one of ours.
    ///
    /// "Delete all" removes only files this returns `true` for, so a note or an export the user
    /// dropped into the folder is left alone.
    /// - Parameter name: The last path component.
    /// - Returns: `true` for `diagnostic-….json`.
    static func isReportFileName(_ name: String) -> Bool {
        name.hasPrefix(fileNamePrefix) && name.hasSuffix(".\(fileExtension)")
    }

    // MARK: - Writing

    /// Writes one payload's JSON and trims the folder back to ``retentionLimit``.
    ///
    /// The bytes are stored exactly as MetricKit produced them: Shepherd does not re-encode,
    /// filter or annotate a report, so what the user reads (or attaches to an issue) is the
    /// payload itself and nothing this app made up about it.
    /// - Parameters:
    ///   - jsonRepresentation: `MXDiagnosticPayload.jsonRepresentation()`.
    ///   - receivedAt: The moment the payload covers — the caller passes the payload's own
    ///     `timeStampEnd`, so the name describes the crash rather than the launch that reported
    ///     it. Injected rather than read from the clock, which is what makes the name testable.
    /// - Returns: The file that was written.
    /// - Throws: Whatever creating the directory or writing the file throws.
    @discardableResult
    func store(jsonRepresentation: Data, receivedAt: Date) throws -> URL {
        try createDirectoryIfNeeded()
        let url = freeURL(receivedAt: receivedAt)
        try jsonRepresentation.write(to: url, options: .atomic)
        trimToRetentionLimit()
        return url
    }

    /// Deletes every stored report.
    ///
    /// Best effort by design: a file that cannot be removed must not stop the others, so the
    /// first failure is remembered and re-thrown after the loop rather than aborting it.
    /// - Throws: The first removal error, if any.
    func deleteAll() throws {
        var firstError: Error?
        for url in reportURLs() {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Creates the folder if it is not there yet.
    /// - Throws: Whatever `FileManager` throws.
    func createDirectoryIfNeeded() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Names

    /// The name a report received at a given moment gets.
    ///
    /// UTC and fixed width — `diagnostic-2026-09-01-101500Z.json` — built from
    /// `DateComponents` rather than from a `DateFormatter`: the name must be a pure function of
    /// the date, and a formatter would make it depend on the machine's locale, calendar and time
    /// zone (a Mac in `en_GB` and one in `ja_JP` must not name the same report differently).
    /// - Parameters:
    ///   - date: The moment the report covers.
    ///   - sequence: Disambiguates two reports from the same second; `1` adds no suffix.
    /// - Returns: The file name, extension included.
    static func fileName(receivedAt date: Date, sequence: Int = 1) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let stamp = String(
            format: "%04d-%02d-%02d-%02d%02d%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
        let suffix = sequence > 1 ? "-\(sequence)" : ""
        return "\(fileNamePrefix)\(stamp)\(suffix).\(fileExtension)"
    }

    /// The first name for this moment that is not taken.
    ///
    /// Bounded rather than a `while true`: after a hundred reports in the same second something is
    /// wrong with the caller, and overwriting the hundredth is a better answer than spinning.
    private func freeURL(receivedAt date: Date) -> URL {
        for sequence in 1...99 {
            let candidate = directory.appendingPathComponent(
                Self.fileName(receivedAt: date, sequence: sequence),
                isDirectory: false
            )
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(
            Self.fileName(receivedAt: date, sequence: 100),
            isDirectory: false
        )
    }

    /// Deletes the oldest reports until at most ``retentionLimit`` are left.
    ///
    /// Failures are swallowed: the report that was just written is what matters, and reporting
    /// "could not save the crash report" because a *previous* one could not be deleted would be
    /// both wrong and useless.
    private func trimToRetentionLimit() {
        let urls = reportURLs()
        guard urls.count > Self.retentionLimit else { return }
        for url in urls.prefix(urls.count - Self.retentionLimit) {
            try? fileManager.removeItem(at: url)
        }
    }
}
