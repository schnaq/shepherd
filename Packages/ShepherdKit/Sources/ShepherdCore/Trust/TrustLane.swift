import Foundation

/// How much attention a pull request is asking for (ADR 0027).
///
/// Two lanes, and the inbox shows them as a facet beside Risk. The gate is deliberately the
/// *hard* heuristic — green CI, a small diff, no sensitive path — and nothing else: the track
/// record beside an agent's name colours a chip and orders rows inside a lane, and it may never
/// move a pull request between them.
public enum TrustLane: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// Green, small, and nowhere near anything dangerous.
    case shortLook
    /// Everything else.
    case fullReview

    /// `TrustLane` is identified by its raw value.
    public var id: String { rawValue }

    /// A stable display order: the short lane first, because it is the one that empties.
    public var sortIndex: Int {
        switch self {
        case .shortLook: return 0
        case .fullReview: return 1
        }
    }
}

/// The two numbers that decide what "small" means (ADR 0027).
///
/// Synced (ADR 0014), because "small" is a preference about the repositories a person works in
/// rather than a fact about a Mac. Both values are clamped on the way in: a threshold of zero
/// would empty the short lane permanently and read as a bug rather than as a setting.
public struct TrustLaneConfiguration: Sendable, Codable, Hashable {
    /// The largest number of changed files a short look may have.
    public var maxFiles: Int
    /// The largest number of added-plus-deleted lines a short look may have.
    public var maxChangedLines: Int

    /// The defaults the interview settled on: five files, a hundred and twenty lines.
    public static let `default` = TrustLaneConfiguration()

    /// The narrowest a threshold may be set to.
    public static let minimumThreshold = 1
    /// The widest the file threshold may be set to.
    public static let maximumFiles = 100
    /// The widest the line threshold may be set to.
    public static let maximumChangedLines = 5_000

    /// Creates a configuration, clamping both thresholds into their documented ranges.
    /// - Parameters:
    ///   - maxFiles: The file ceiling. Clamped to `1...100`.
    ///   - maxChangedLines: The churn ceiling. Clamped to `1...5000`.
    public init(maxFiles: Int = 5, maxChangedLines: Int = 120) {
        self.maxFiles = min(Self.maximumFiles, max(Self.minimumThreshold, maxFiles))
        self.maxChangedLines = min(
            Self.maximumChangedLines,
            max(Self.minimumThreshold, maxChangedLines)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case maxFiles, maxChangedLines
    }

    /// Decodes tolerantly: a missing or unreadable threshold falls back to its default rather
    /// than costing the whole value, which is what the synced document expects of every group
    /// it carries (ADR 0014).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let files = (try? container.decodeIfPresent(Int.self, forKey: .maxFiles)) ?? nil
        let lines = (try? container.decodeIfPresent(Int.self, forKey: .maxChangedLines)) ?? nil
        self.init(maxFiles: files ?? 5, maxChangedLines: lines ?? 120)
    }
}

/// Everything ``TrustLane/classify(_:configuration:)`` is allowed to look at.
///
/// The type is the rule. ADR 0027 says the lane gate is CI, size and sensitive paths — and that
/// the track record informs the badge and the sort but never the lane — so the inputs are these
/// four values and there is nowhere for a history type to hide. `ShepherdCoreTests` asserts it
/// reflectively, the way ADR 0023's verdict rule is asserted, because a rule nobody can see being
/// broken is not a rule.
public struct TrustLaneInput: Sendable, Codable, Hashable {
    /// The rolled-up CI state of the head commit, or `nil` when the pull request has none.
    public var checkState: CheckRollup.State?
    /// How many files the pull request changes.
    public var changedFiles: Int
    /// Added plus deleted lines.
    public var changedLines: Int
    /// Whether the pull request has to be treated as touching a sensitive path.
    ///
    /// `true` also covers "Shepherd cannot tell": *short look* is a claim, and a pull request
    /// whose diff has not been fetched yet cannot be shown to touch nothing dangerous. Callers
    /// that have the files compute it with ``TrustSensitivePaths/contains(files:extraHints:)``.
    public var sensitivePaths: Bool

    /// Creates an input.
    public init(
        checkState: CheckRollup.State?,
        changedFiles: Int,
        changedLines: Int,
        sensitivePaths: Bool
    ) {
        self.checkState = checkState
        self.changedFiles = changedFiles
        self.changedLines = changedLines
        self.sensitivePaths = sensitivePaths
    }
}

extension TrustLane {
    /// Classifies one pull request from the four values the lane is allowed to see.
    ///
    /// A short look needs **all** of it: the rollup says `success`, the diff is within both
    /// thresholds, and no sensitive path is involved. Every other combination — a red build, a
    /// pending one, a pull request with no checks at all (``CheckRollup/State/none`` is not
    /// `success`, so "nothing ran" is never green), one file too many, one line too many, a
    /// workflow file — is a full review. The asymmetry is the point: the short lane is the
    /// *narrow* claim, so anything unknown lands in the wide one.
    /// - Parameters:
    ///   - input: The four values, and nothing else.
    ///   - configuration: The thresholds.
    /// - Returns: The lane.
    public static func classify(
        _ input: TrustLaneInput,
        configuration: TrustLaneConfiguration = .default
    ) -> TrustLane {
        guard !input.sensitivePaths else { return .fullReview }
        guard input.checkState == CheckRollup.State.success else { return .fullReview }
        guard input.changedFiles <= configuration.maxFiles else { return .fullReview }
        guard input.changedLines <= configuration.maxChangedLines else { return .fullReview }
        return .shortLook
    }

    /// Classifies one inbox row.
    ///
    /// The convenience the app uses, and it takes the sensitive-path flag as a parameter for the
    /// reason the whole feature exists: ``PullRequestSummary`` carries counts, not paths, so the
    /// exclusion is worked out from the cached diff by the caller and handed in. The summary
    /// contributes exactly three of the four inputs — the check rollup, `changedFiles` and
    /// `additions + deletions` — and nothing else about it is read.
    /// - Parameters:
    ///   - summary: The inbox row.
    ///   - sensitivePaths: Whether the pull request must be treated as touching a sensitive
    ///     path; `true` when that is unknown (see ``TrustLaneInput/sensitivePaths``).
    ///   - configuration: The thresholds.
    /// - Returns: The lane.
    public static func classify(
        summary: PullRequestSummary,
        sensitivePaths: Bool,
        configuration: TrustLaneConfiguration = .default
    ) -> TrustLane {
        classify(
            TrustLaneInput(
                checkState: summary.checkRollup?.state,
                changedFiles: summary.changedFiles,
                changedLines: summary.churn,
                sensitivePaths: sensitivePaths
            ),
            configuration: configuration
        )
    }
}
