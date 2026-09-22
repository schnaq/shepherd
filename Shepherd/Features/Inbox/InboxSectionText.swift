import Foundation
import ShepherdCore

/// The German half of the inbox's section headers and of a pull request's provenance (ADR 0022,
/// the 2026-09-22 amendment).
///
/// ``ShepherdCore/InboxGrouper`` and ``ShepherdCore/ActorKind/provenanceLabel`` live in a
/// Foundation-only package that cannot call `String(localized:)`, so the words they carry are
/// English — "People", "Bots", "Review required" — and they reached the list's pinned headers and
/// Shortcuts on a German Mac. The package now names what a section *is*
/// (``ShepherdCore/InboxSection/Kind``) and this file says it, reusing the keys the rest of the
/// app already says the same things with: the rail's "Humans" and "Bots", the review chip's
/// ``ShepherdCore/ReviewDecision/chipTitle``. Agent names and repository names are proper nouns
/// and pass through as they are.
extension InboxSection.Kind {
    /// The header text, in the user's language.
    var localizedTitle: String {
        switch self {
        case .agent(let displayName):
            return displayName
        case .bots:
            return String(localized: "Bots")
        case .humans:
            return String(localized: "Humans")
        case .repository(let repo):
            return repo.fullName
        case .reviewDecision(let decision?):
            return decision.chipTitle
        case .reviewDecision(nil):
            return String(localized: "No review decision")
        }
    }
}

extension InboxSection {
    /// The header text, in the user's language — what the list draws instead of ``title``.
    var localizedTitle: String { kind.localizedTitle }
}

extension ActorKind {
    /// ``ShepherdCore/ActorKind/provenanceLabel`` in the user's language: an agent's name, or
    /// "Humans" / "Bots" in the words the inbox's rail and section headers use, so a Shortcut
    /// that groups by it reads the way the inbox does.
    var localizedProvenanceLabel: String {
        switch self {
        case .agent(let identity): return identity.displayName
        case .bot: return InboxSection.Kind.bots.localizedTitle
        case .human: return InboxSection.Kind.humans.localizedTitle
        }
    }
}
