import Foundation
import ShepherdCore

/// The on-screen half of the file prioritiser's reasons: one localised phrase per
/// ``ShepherdCore/FilePriorityReason`` (ADR 0007's tier-1 ranking, ADR 0022's catalog).
///
/// The same split as `EvidenceFactText.swift`, for the same two rules: ShepherdCore may not call
/// `String(localized:)`, and every string a reviewer reads has to be a catalog key with a German
/// row. So the prioritiser produces values and this is the one place that turns them into words
/// for the review file list, the inbox's file tooltip and the triage popover.
///
/// - **Paths and the matched security hint are interpolated verbatim.** A translated path would
///   be a wrong path, and the hint is a substring of one.
/// - **The quotation marks belong to the phrase**, so the German row can write „…“.
/// - **Counts go through the catalog's plural rules**, since the line count is the phrase's only
///   argument (ADR 0022).
///
/// ``ShepherdCore/FilePriorityReason/englishText`` is *not* this: it is what a model prompt, an
/// agent brief and the Linux tests read.
extension FilePriorityReason {
    /// The reason as a localised phrase, ready to draw.
    /// - Parameter bundle: Where to look the catalog up. `Bundle.main` in the app; a test passes
    ///   the compiled `de.lproj` (see `LocalizationTests`).
    /// - Returns: The phrase, in the bundle's language.
    func localizedText(bundle: Bundle = .main) -> String {
        switch self {
        case .category(let category):
            return category.localizedLabel(bundle: bundle)
        case .securitySensitivePath(let hint):
            return String(localized: "Touches security-sensitive path (“\(hint)”)", bundle: bundle)
        case .ciWorkflow:
            return String(localized: "Changes a CI workflow — supply-chain relevant", bundle: bundle)
        case .containerBuildFile:
            return String(
                localized: "Container build definition — supply-chain relevant",
                bundle: bundle
            )
        case .entitlements:
            return String(localized: "Changes app entitlements", bundle: bundle)
        case .deletesTestFile:
            return String(localized: "Deletes a test file", bundle: bundle)
        case .deletesSourceFile:
            return String(localized: "Deletes a source file", bundle: bundle)
        case .largeChange(let count):
            return String(localized: "Large change (\(count) lines)", bundle: bundle)
        case .sizeableChange(let count):
            return String(localized: "Sizeable change (\(count) lines)", bundle: bundle)
        case .dominatesChanges:
            return String(localized: "Dominates this pull request's changes", bundle: bundle)
        case .newSourceFile:
            return String(localized: "New source file", bundle: bundle)
        case .renamed(let previous):
            return String(localized: "Renamed from \(previous)", bundle: bundle)
        case .noDiffAvailable:
            return String(localized: "No diff available (binary or truncated)", bundle: bundle)
        }
    }
}

extension TriageRiskHint {
    /// The hint as a localised line for the inbox's "why this risk" popover.
    ///
    /// A file hint is its path, verbatim, then its reasons; the separators are the English
    /// line's, which read the same in German.
    /// - Parameter bundle: Where to look the catalog up.
    /// - Returns: The line, in the bundle's language.
    func localizedText(bundle: Bundle = .main) -> String {
        switch self {
        case .everyFileGenerated:
            return String(
                localized: "Every changed file is generated or vendored (a lockfile, a snapshot or a bundle).",
                bundle: bundle
            )
        case .file(let path, let reasons):
            let phrases = reasons.map { $0.localizedText(bundle: bundle) }
            return "\(path) — \(phrases.joined(separator: ", "))"
        }
    }
}
