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
    ///
    /// A completed run without a conclusion is treated as green: GitHub always sets one, and
    /// a missing value must not paint the inbox red.
    public var rollupContribution: RollupContribution {
        guard status == .completed else { return .pending }
        guard let conclusion else { return .success }
        switch conclusion {
        case .failure, .timedOut, .actionRequired, .cancelled:
            return .failure
        case .success, .neutral, .skipped, .stale, .unknown:
            return .success
        }
    }
}

extension CheckRun {
    /// The id of the GitHub Actions job behind this check, when there is one (plan §3.F).
    ///
    /// A check run does not carry its job id: the only place it appears is inside
    /// ``detailsURL``, which for an Actions job is
    /// `https://github.com/{owner}/{repo}/actions/runs/{run}/job/{job}`. That is the id
    /// `GET /repos/{owner}/{repo}/actions/jobs/{id}/logs` needs, so parsing it here is what makes
    /// the job-log read reachable at all.
    ///
    /// It is a pure property in `ShepherdCore` rather than a helper next to the network call for
    /// the reason the rest of this layer's arithmetic is: this is a *parser of somebody else's
    /// URL shape*, it is wrong in a way nobody notices (an off-by-one in the path components
    /// yields a plausible number that reads the wrong job's log), and it has to be testable
    /// without a Mac.
    ///
    /// **A check that is not an Actions job answers `nil`, and that is a supported answer rather
    /// than a failure.** Buildkite, CircleCI and every other integration point their
    /// `detailsURL` somewhere else entirely, and the tool that asks for a log says "there is no
    /// readable log for this check" and works from the check's own summary instead. The path is
    /// matched from `actions/runs/…/job/…` rather than from the front, so a GitHub Enterprise
    /// Server host with a path prefix still parses.
    public var actionsJobID: Int? {
        guard let detailsURL else { return nil }
        let parts = detailsURL.pathComponents.filter { $0 != "/" }
        guard let actions = parts.firstIndex(of: "actions"), parts.count > actions + 4 else {
            return nil
        }
        guard parts[actions + 1] == "runs", parts[actions + 3] == "job" else { return nil }
        guard let id = Int(parts[actions + 4]), id > 0 else { return nil }
        return id
    }
}
