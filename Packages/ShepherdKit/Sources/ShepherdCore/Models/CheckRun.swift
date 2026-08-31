import Foundation

/// A single CI check on a pull request's head commit.
public struct CheckRun: Sendable, Codable, Hashable, Identifiable {
    /// The lifecycle state of a check run.
    public enum Status: String, Sendable, Codable, Hashable, CaseIterable {
        /// Scheduled but not started.
        case queued
        /// Currently running.
        case inProgress
        /// Finished, see ``CheckRun/conclusion``.
        case completed
        /// GitHub reported a state Shepherd does not model.
        case unknown

        /// Maps GitHub's REST/GraphQL `status` string onto a status.
        /// - Parameter raw: The raw status string, e.g. `"in_progress"`.
        public static func fromAPI(_ raw: String) -> Status {
            switch raw.lowercased() {
            case "queued", "waiting", "pending", "requested": return .queued
            case "in_progress": return .inProgress
            case "completed": return .completed
            default: return .unknown
            }
        }
    }

    /// The outcome of a completed check run.
    public enum Conclusion: String, Sendable, Codable, Hashable, CaseIterable {
        /// The check passed.
        case success
        /// The check failed.
        case failure
        /// The check reported a neutral result.
        case neutral
        /// The check was cancelled.
        case cancelled
        /// The check was skipped.
        case skipped
        /// The check timed out.
        case timedOut
        /// The check needs a manual action.
        case actionRequired
        /// The check is stale.
        case stale
        /// GitHub reported a conclusion Shepherd does not model.
        case unknown

        /// Maps GitHub's REST/GraphQL `conclusion` string onto a conclusion.
        /// - Parameter raw: The raw conclusion string, e.g. `"timed_out"`.
        public static func fromAPI(_ raw: String) -> Conclusion {
            switch raw.lowercased() {
            case "success": return .success
            case "failure": return .failure
            case "neutral": return .neutral
            case "cancelled", "canceled": return .cancelled
            case "skipped": return .skipped
            case "timed_out": return .timedOut
            case "action_required": return .actionRequired
            case "stale": return .stale
            default: return .unknown
            }
        }
    }

    /// A stable identifier for the check run (REST id as a string, or the GraphQL node id).
    public let id: String
    /// The check name as shown on GitHub, e.g. `"ShepherdKit tests (Linux)"`.
    public var name: String
    /// The lifecycle state.
    public var status: Status
    /// The outcome, once ``status`` is ``Status/completed``.
    public var conclusion: Conclusion?
    /// A link to the check's logs.
    public var detailsURL: URL?
    /// When the check started.
    public var startedAt: Date?
    /// When the check finished.
    public var completedAt: Date?
    /// The check's one-line output summary, when it published one.
    public var summary: String?

    /// Creates a check run.
    public init(
        id: String,
        name: String,
        status: Status,
        conclusion: Conclusion? = nil,
        detailsURL: URL? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.summary = summary
    }

    /// How this run contributes to a ``CheckRollup``.
    public enum RollupContribution: Sendable, Hashable {
        /// Counts as green.
        case success
        /// Counts as red.
        case failure
        /// Counts as still running.
        case pending
    }

    /// Whether this run counts as green, red or still running for the rollup.
    public var rollupContribution: RollupContribution {
        guard status == .completed else { return .pending }
        switch conclusion {
        case .failure, .timedOut, .actionRequired, .cancelled:
            return .failure
        case .success, .neutral, .skipped, .stale, .unknown, .none:
            return .success
        }
    }
}
