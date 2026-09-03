import Foundation

/// The diff a review was written against, kept so a later round can be compared with it.
///
/// Written when a `submitReview` mutation reaches GitHub — the one moment Shepherd knows "this
/// is the head I reviewed" — and read by the interdiff (ADR 0028). It holds the pull request's
/// changed files *including their patches*, because that is what the comparison needs and
/// because GitHub cannot be asked for them again after a force-push.
public struct ReviewSnapshot: Sendable, Codable, Hashable, Identifiable {
    /// The pull request's node id.
    public var prID: String
    /// The head commit the review was made against.
    public var reviewedHeadOid: String
    /// When the review was submitted.
    public var reviewedAt: Date
    /// The changed files as they were at ``reviewedHeadOid``.
    public var files: [ChangedFile]

    /// Creates a snapshot.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - reviewedHeadOid: The reviewed head commit.
    ///   - reviewedAt: When the review was submitted.
    ///   - files: The changed files at that head.
    public init(
        prID: String,
        reviewedHeadOid: String,
        reviewedAt: Date,
        files: [ChangedFile]
    ) {
        self.prID = prID
        self.reviewedHeadOid = reviewedHeadOid
        self.reviewedAt = reviewedAt
        self.files = files
    }

    /// A snapshot is identified by the pull request and the head it covers.
    public var id: String { "\(prID):\(reviewedHeadOid)" }

    /// Whether a pull request has moved on since this snapshot was taken.
    /// - Parameter headRefOid: The pull request's current head commit.
    public func isBehind(_ headRefOid: String) -> Bool {
        !reviewedHeadOid.isEmpty && reviewedHeadOid != headRefOid
    }
}
