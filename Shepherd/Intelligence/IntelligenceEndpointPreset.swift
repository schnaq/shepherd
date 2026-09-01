import Foundation

/// A known OpenAI-compatible endpoint, offered in Settings so nobody has to remember a base
/// URL (ADR 0007, tier 3b).
///
/// The preset is a *convenience over* the free-form configuration, not a second code path:
/// selecting one only fills in the base URL that ``OpenAICompatibleProvider`` already takes, so
/// the provider, the router and the connection test are untouched by it. ``custom`` is the
/// behaviour that existed before presets — whatever base URL the user typed.
enum IntelligenceEndpointPreset: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Konduit: an EU-hosted gateway in front of open models.
    case konduitEU
    /// Ollama on this Mac, which serves the same shape under `/v1`.
    case ollamaLocal
    /// A base URL the user types themselves.
    case custom

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .konduitEU: return String(localized: "Konduit (EU)")
        case .ollamaLocal: return String(localized: "Ollama (local)")
        case .custom: return String(localized: "Custom")
        }
    }

    /// The base URL this preset fills in, or `nil` for ``custom``, which keeps the typed one.
    var baseURL: String? {
        switch self {
        case .konduitEU: return "https://api.konduit.eu/v1"
        case .ollamaLocal: return "http://localhost:11434/v1"
        case .custom: return nil
        }
    }

    /// A one-line note shown under the endpoint picker, or `nil` when there is nothing to say.
    var note: String? {
        switch self {
        case .konduitEU:
            return String(
                localized: "EU-hosted, open models. The request goes straight from your Mac to the gateway."
            )
        case .ollamaLocal:
            return String(
                localized: "A model server on this Mac. No key required; nothing leaves the machine."
            )
        case .custom:
            return nil
        }
    }

    /// Where the user creates a key, for endpoints that issue them.
    var consoleURL: URL? {
        switch self {
        case .konduitEU: return URL(string: "https://console.konduit.eu")
        case .ollamaLocal, .custom: return nil
        }
    }

    /// The label of the ``consoleURL`` link, when there is one.
    var consoleLinkTitle: String? {
        switch self {
        case .konduitEU: return String(localized: "Get your API key at console.konduit.eu")
        case .ollamaLocal, .custom: return nil
        }
    }

    /// The placeholder shown in the API-key field.
    var apiKeyPlaceholder: String {
        switch self {
        case .konduitEU: return "kdt-…"
        case .ollamaLocal: return String(localized: "not required")
        case .custom: return "sk-…"
        }
    }

    /// The placeholder shown in the model field while no list has been loaded.
    var modelPlaceholder: String {
        switch self {
        case .konduitEU, .ollamaLocal: return String(localized: "Load models to pick one")
        case .custom: return String(localized: "model name")
        }
    }

    /// Whether the model list may be fetched while the key field is empty.
    ///
    /// A local or self-hosted server usually ignores the bearer token, so requiring a key there
    /// would mean the list never loads. Konduit always needs one, and firing a request that is
    /// certain to come back `401` only produces a confusing error.
    var allowsKeylessDiscovery: Bool {
        switch self {
        case .konduitEU: return false
        case .ollamaLocal, .custom: return true
        }
    }

    /// The preset a base URL belongs to.
    ///
    /// Used both when restoring settings written before presets existed and whenever the user
    /// edits the base URL by hand, so the picker never claims a preset the field contradicts.
    /// - Parameter baseURL: The configured base URL, exactly as stored or typed.
    /// - Returns: The matching preset, or ``custom``.
    static func matching(baseURL: String) -> IntelligenceEndpointPreset {
        guard let normalized = OpenAICompatibleProvider.normalizedBase(baseURL) else {
            return .custom
        }
        for preset in allCases {
            guard let candidate = preset.baseURL,
                  let normalizedCandidate = OpenAICompatibleProvider.normalizedBase(candidate),
                  normalized.caseInsensitiveCompare(normalizedCandidate) == .orderedSame
            else { continue }
            return preset
        }
        return .custom
    }
}
