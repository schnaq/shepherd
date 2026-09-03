import Foundation

/// One claim as a *model* reports it: a shape and the sentence it read the shape out of.
///
/// The `Codable` twin of the app target's `@Generable OnDeviceClaim`, and it lives here for
/// ADR 0007's rule about every generated shape: the type, its decoding tolerances and the merge
/// below are provider-neutral, so they are tested on the Linux runner, and only the Apple-only
/// mirror of it lives beside `FoundationModels`.
///
/// Two fields, the same two ``Claim`` carries minus the origin — because the origin of anything
/// decoded into this type is settled by construction (it came from the model) and is stamped on
/// in ``ClaimList/merged(into:)`` rather than trusted from the wire.
///
/// **The encoded shape is flat**, and deliberately not ``Claim/Kind``'s own synthesized shape:
/// `{"kind": "scopeLimited", "module": "Sources/Parser", "quote": "…"}` rather than
/// `{"kind": {"scopeLimited": {"module": "…"}}}`. A model writing JSON writes the first one; the
/// second is Swift's encoding of an enum with associated values and asking for it would be asking
/// a model to know about Swift.
public struct ExtractedClaim: Codable, Sendable, Hashable {
    /// Which of the four shapes the model says the sentence is.
    public var kind: Claim.Kind
    /// The sentence it read the claim out of.
    public var quote: String

    /// Creates an extracted claim.
    /// - Parameters:
    ///   - kind: The claim's shape.
    ///   - quote: The sentence it was read from.
    public init(kind: Claim.Kind, quote: String) {
        self.kind = kind
        self.quote = quote
    }

    /// The flat keys above. Stable, because they are the JSON contract.
    private enum CodingKeys: String, CodingKey {
        case kind
        case module
        case issueNumber
        case quote
    }

    /// Decodes one extracted claim, or throws.
    ///
    /// Throwing is not the same as losing the answer: ``ClaimList`` decodes its array
    /// element-wise, so a malformed entry costs that entry and nothing else — the tolerance
    /// ``CIDiagnosis`` and ``OpenAIModelsResponse`` already apply to a model's extras, applied to
    /// a list of them. What is refused here is exactly what would produce a wrong card:
    ///
    /// - a `kind` that is not one of the four (spelling is lenient, vocabulary is not);
    /// - a `scopeLimited` with no module — "no other changes" is tier 1's shape and the evidence
    ///   for it can only describe what *was* touched, so a model claim about scope has to name
    ///   the thing it is claiming about;
    /// - a `fixesIssue` with no number, which is a claim about no issue in particular;
    /// - a blank quote. The card shows the quote and links to it; a claim with nothing to show
    ///   is a category label with no evidence that the description said anything at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(Claim.Kind.Name.self, forKey: .kind)
        let module = try container.decodeIfPresent(String.self, forKey: .module)?
            .intelligenceTrimmedOrNil
        let issueNumber = try container.decodeIfPresent(Int.self, forKey: .issueNumber)
        guard let kind = Claim.Kind(name: name, module: module, issueNumber: issueNumber) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "\(name.rawValue) is missing the value that shape needs."
                )
            )
        }
        guard let quote = try container.decode(String.self, forKey: .quote)
            .intelligenceTrimmedOrNil
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "A claim with a blank quote has nothing to show."
                )
            )
        }
        self.kind = kind
        self.quote = quote
    }

    /// Encodes the flat shape above.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.name, forKey: .kind)
        switch kind {
        case .scopeLimited(let module):
            try container.encode(module, forKey: .module)
        case .fixesIssue(let number):
            try container.encode(number, forKey: .issueNumber)
        case .testsAdded, .noBreakingChanges:
            break
        }
        try container.encode(quote, forKey: .quote)
    }
}

/// What the optional tier-2 pass read out of a description (ADR 0026's amendment, plan §2.A).
///
/// The whole of the model's answer: a list, and nothing about how sure it is or what it thinks of
/// the pull request. There is no confidence field on purpose — a claim is a *quote plus a shape*,
/// the card puts it next to the same evidence every other line gets, and a number beside it would
/// be the beginning of the score ADR 0026 forbids.
///
/// It is additive by construction: the only thing this type can do to a report is
/// ``merged(into:)``, which takes the deterministic claims as they are and appends to them.
public struct ClaimList: Codable, Sendable, Hashable {
    /// The claims, in whatever order the model produced them.
    public var claims: [ExtractedClaim]

    /// Creates a list.
    /// - Parameter claims: The claims.
    public init(claims: [ExtractedClaim] = []) {
        self.claims = claims
    }

    /// The answer with nothing in it — the patterns already had everything.
    public static let empty = ClaimList()

    /// Whether the model added nothing.
    public var isEmpty: Bool { claims.isEmpty }

    /// Stable keys — the JSON contract the prompt asks for.
    private enum CodingKeys: String, CodingKey {
        case claims
    }

    /// Decodes a list, dropping the entries it cannot use and keeping the rest.
    ///
    /// Element-wise, through ``LenientClaim``, because the alternative is throwing away four good
    /// claims over a fifth that named no module. An absent `claims` key reads as an empty list:
    /// "the patterns already had everything" is a real and common answer, and a model expressing
    /// it by omitting the key is not an error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([LenientClaim].self, forKey: .claims) ?? []
        claims = raw.compactMap { $0.claim }
    }

    /// The deterministic claims with the model's additions after them, in the card's own order.
    ///
    /// Three rules, and they are the whole of what "additive" means (ADR 0026's amendment):
    ///
    /// - **The pattern claims are returned untouched.** Same kinds, same quotes, same
    ///   ``Claim/Origin/pattern`` origin. Tier 2 cannot correct, re-quote or remove a tier-1
    ///   claim, so a Mac without the model shows a subset of this card rather than a different
    ///   one.
    /// - **A model claim that duplicates one of them is dropped**, by ``Claim/Kind/dedupKey`` —
    ///   the same key ``ClaimExtractor`` deduplicates by, so "Only the parser changed" found
    ///   twice is one line and not two asking the reviewer to read one piece of evidence twice.
    ///   Model claims are deduplicated against each other by the same key.
    /// - **What survives is marked ``Claim/Origin/model``**, which is what puts the "read by the
    ///   model" tag on its line.
    ///
    /// The order is ``ClaimExtractor``'s: shape first, then issue number. That is a *total* order
    /// on a deduplicated set — two claims can only share a ``Claim/Kind/sortIndex`` by both being
    /// `fixesIssue`, and then their numbers differ — so the merged card reads top to bottom the
    /// same way a tier-1 card does, with the additions in their places rather than in a block at
    /// the end. The index is the final tiebreak so that the sort is total even if a caller hands
    /// in pattern claims that were not deduplicated.
    /// - Parameter patternClaims: What ``ClaimExtractor/extract(from:)`` found, in its order.
    /// - Returns: The union, ordered.
    public func merged(into patternClaims: [Claim]) -> [Claim] {
        var seen = Set(patternClaims.map { $0.kind.dedupKey })
        var merged = patternClaims
        for extracted in claims {
            // Blank quotes are refused on the way in as well, in both the decoder above and the
            // app's conversion from the generated shape; the check is repeated here because this
            // is the function whose output is drawn, and a line with nothing to quote is a
            // category label pretending the description said something.
            let quote = extracted.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }
            guard seen.insert(extracted.kind.dedupKey).inserted else { continue }
            merged.append(Claim(kind: extracted.kind, quote: quote, origin: .model))
        }
        return merged
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.kind
                let right = rhs.element.kind
                if left.sortIndex != right.sortIndex {
                    return left.sortIndex < right.sortIndex
                }
                if case .fixesIssue(let leftNumber) = left,
                   case .fixesIssue(let rightNumber) = right,
                   leftNumber != rightNumber {
                    return leftNumber < rightNumber
                }
                return lhs.offset < rhs.offset
            }
            // A tuple has no key path, so this is a closure rather than `\.element`.
            .map { $0.element }
    }
}

/// One list element that decodes to `nil` instead of failing the whole list.
///
/// The standard shape for "tolerate a bad element": each element of an unkeyed container gets its
/// own decoder, so a `try?` here cannot leave the container half-read the way a `try?` around the
/// array itself would.
private struct LenientClaim: Decodable {
    /// The claim, or `nil` when this entry was not usable.
    let claim: ExtractedClaim?

    init(from decoder: any Decoder) throws {
        claim = try? ExtractedClaim(from: decoder)
    }
}

// MARK: - The four shapes as a flat vocabulary

extension Claim.Kind {
    /// The four shapes as a closed vocabulary of names, with no values attached.
    ///
    /// ``Claim/Kind`` carries a module and an issue number in its cases, which is right for the
    /// card and wrong for a wire format: a model chooses the *shape* first and then fills in what
    /// that shape needs, and the app's `@Generable` enum has exactly these four cases and no
    /// payloads for the same reason. So this is the third spelling of the four shapes, and the
    /// only one that is a plain string.
    public enum Name: String, Sendable, Codable, Hashable, CaseIterable {
        /// ``Claim/Kind/testsAdded``.
        case testsAdded
        /// ``Claim/Kind/scopeLimited(module:)``, which needs a module beside it.
        case scopeLimited
        /// ``Claim/Kind/noBreakingChanges``.
        case noBreakingChanges
        /// ``Claim/Kind/fixesIssue(number:)``, which needs a number beside it.
        case fixesIssue

        /// Decodes a name the way a model actually writes one.
        ///
        /// Lenient about spelling and nothing else: `"tests_added"`, `"Tests Added"` and
        /// `"testsadded"` are the same answer, and a fifth shape is a decoding error rather than
        /// a default — inventing one would present a guess as the model's reading (the rule
        /// ``IntelligenceEnumDecoding`` states for every generated enum).
        public init(from decoder: any Decoder) throws {
            self = try IntelligenceEnumDecoding.decode(from: decoder, as: Name.self)
        }
    }

    /// This shape's name, with its values left off.
    public var name: Name {
        switch self {
        case .testsAdded: return .testsAdded
        case .scopeLimited: return .scopeLimited
        case .noBreakingChanges: return .noBreakingChanges
        case .fixesIssue: return .fixesIssue
        }
    }

    /// Rebuilds a shape from a name and whatever the name needs, or fails.
    ///
    /// The one place the flat vocabulary becomes a ``Claim/Kind``, shared by the twin's decoding
    /// and by the app's conversion from the generated shape — so "a scope claim without a module
    /// is not a claim" is decided once instead of twice.
    /// - Parameters:
    ///   - name: Which shape.
    ///   - module: The module a scope claim names. Trimmed and non-empty, or `nil`.
    ///   - issueNumber: The issue an issue claim references.
    /// - Returns: The shape, or `nil` when the name needs a value it was not given.
    public init?(name: Name, module: String? = nil, issueNumber: Int? = nil) {
        switch name {
        case .testsAdded:
            self = .testsAdded
        case .noBreakingChanges:
            self = .noBreakingChanges
        case .scopeLimited:
            // Empty is not "no other changes" here: that sentence is tier 1's, matched by a fixed
            // pattern, and a model that produced a scope claim without naming anything has
            // produced a line whose evidence could only ever say "?".
            guard let module, !module.isEmpty else { return nil }
            self = .scopeLimited(module: module)
        case .fixesIssue:
            guard let issueNumber, issueNumber > 0 else { return nil }
            self = .fixesIssue(number: issueNumber)
        }
    }
}
