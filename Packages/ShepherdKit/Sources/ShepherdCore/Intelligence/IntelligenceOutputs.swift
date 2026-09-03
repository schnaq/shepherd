import Foundation

/// Matching a model's raw string against a fixed set of cases.
///
/// Every enum below is produced by a *model*, and the two tiers spell the same case differently:
/// the on-device model generates the case directly, while a cloud provider answers with JSON it
/// wrote from a prompt and will happily write `"Dependency Bump"`, `"dependency_bump"` or
/// `"HIGH"`. Those are the same answer, and throwing the whole verdict away over the spelling
/// would mean an empty card where a correct classification was available.
///
/// What is *not* tolerated is a value that is not one of the cases: an unknown kind is a decoding
/// error, because the alternative is inventing a default and presenting a guess as the model's
/// verdict.
enum IntelligenceEnumDecoding {
    /// Lower-cases and drops everything that is not a letter or a digit.
    private static func normalized(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Finds the case whose raw value matches `raw`, ignoring case, spaces, hyphens and
    /// underscores.
    /// - Parameter raw: What the model wrote.
    /// - Returns: The matching case, or `nil`.
    static func match<Value>(_ raw: String) -> Value?
    where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
        let wanted = normalized(raw)
        return Value.allCases.first { normalized($0.rawValue) == wanted }
    }

    /// Decodes a lenient enum from a single-value container, or throws.
    /// - Parameters:
    ///   - decoder: The decoder positioned at the value.
    ///   - type: The enum being decoded, for the error message.
    /// - Returns: The matching case.
    static func decode<Value>(from decoder: any Decoder, as type: Value.Type) throws -> Value
    where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value: Value = match(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "\"\(raw)\" is not a \(type) value."
                )
            )
        }
        return value
    }
}

/// Text a model produced, cleaned up before anything shows it.
extension String {
    /// The string trimmed of whitespace and newlines, or `nil` when nothing is left.
    ///
    /// Models answer "no failing test" as `""` about as often as they omit the field, and the two
    /// have to mean the same thing by the time the UI decides whether to draw a row.
    var intelligenceTrimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Structured triage

/// What kind of change a pull request is, and how much it can hurt (plan §3.A).
///
/// The `Codable` twin of the on-device `@Generable` struct, and the type the cloud providers
/// decode straight into. It lives here, in a target that builds on Linux, because that is ADR
/// 0007's rule for every generated shape: the schema, the validation and the tests are
/// provider-neutral, and only the `@Generable` mirror of it is Apple-only.
///
/// It is a **hint**. Nothing in the plan lets a verdict approve, merge or delegate: it sorts the
/// inbox and it fills a facet, and the bulk-triage and auto-merge rules deliberately do not read
/// it.
public struct TriageVerdict: Codable, Sendable, Hashable {
    /// What kind of change this is.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// New behaviour.
        case feature
        /// A correction to existing behaviour.
        case fix
        /// Housekeeping: CI, tooling, formatting, generated files.
        case chore
        /// A dependency version change, lockfile included.
        case dependencyBump
        /// Documentation only.
        case docs
        /// Behaviour-preserving restructuring.
        case refactor

        public init(from decoder: any Decoder) throws {
            self = try IntelligenceEnumDecoding.decode(from: decoder, as: Kind.self)
        }
    }

    /// How much of a risk the change carries.
    public enum Risk: String, Codable, Sendable, Hashable, CaseIterable {
        /// Mechanical, contained, or fully covered by tests.
        case low
        /// Touches behaviour a reviewer should read carefully.
        case medium
        /// Touches something that hurts when it is wrong — auth, migrations, deleted tests.
        case high

        public init(from decoder: any Decoder) throws {
            self = try IntelligenceEnumDecoding.decode(from: decoder, as: Risk.self)
        }
    }

    /// What kind of change this is.
    public var kind: Kind
    /// How much it can hurt.
    public var risk: Risk
    /// One sentence saying why, shown in the "why?" popover next to the chip.
    public var reason: String

    /// Creates a verdict.
    /// - Parameters:
    ///   - kind: What kind of change this is.
    ///   - risk: How much it can hurt.
    ///   - reason: One sentence saying why.
    public init(kind: Kind, risk: Risk, reason: String) {
        self.kind = kind
        self.risk = risk
        self.reason = reason
    }

    /// Stable keys: they are the JSON contract the cloud prompt asks for, so renaming one is a
    /// prompt change, not a refactor.
    private enum CodingKeys: String, CodingKey {
        case kind
        case risk
        case reason
    }

    /// Decodes a verdict, tolerating a missing or padded reason.
    ///
    /// `kind` and `risk` are the verdict and are required. `reason` is the sentence beside it and
    /// is not: a model that classified correctly and forgot to explain itself has still produced
    /// something the facet can sort by, and an empty popover is a smaller loss than no chip.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        risk = try container.decode(Risk.self, forKey: .risk)
        let rawReason = try container.decodeIfPresent(String.self, forKey: .reason)
        reason = rawReason?.intelligenceTrimmedOrNil ?? ""
    }
}

// MARK: - "Why is CI red?"

/// What the model made of a red check (plan §3.F).
///
/// Every locating field is optional and that is the design: a log that says only
/// `** TEST FAILED **` yields a hypothesis and nothing else, and a diagnosis that had to invent a
/// file to be decodable would be worse than one that admits it does not know. The card renders
/// what is there.
public struct CIDiagnosis: Codable, Sendable, Hashable {
    /// How sure the model says it is.
    public enum Confidence: String, Codable, Sendable, Hashable, CaseIterable {
        /// A guess from thin evidence.
        case low
        /// Consistent with the log, not proven by it.
        case medium
        /// The log names it.
        case high

        public init(from decoder: any Decoder) throws {
            self = try IntelligenceEnumDecoding.decode(from: decoder, as: Confidence.self)
        }
    }

    /// The failing test's name, when the log named one.
    public var failingTest: String?
    /// The file the failure points at, when the log named one.
    public var file: String?
    /// The line in that file, when the log named one.
    public var line: Int?
    /// One sentence on what is wrong.
    public var hypothesis: String
    /// How sure the model says it is.
    public var confidence: Confidence

    /// Creates a diagnosis.
    /// - Parameters:
    ///   - failingTest: The failing test's name, if known.
    ///   - file: The file, if known.
    ///   - line: The line, if known.
    ///   - hypothesis: One sentence on what is wrong.
    ///   - confidence: How sure the model says it is.
    public init(
        failingTest: String? = nil,
        file: String? = nil,
        line: Int? = nil,
        hypothesis: String,
        confidence: Confidence
    ) {
        self.failingTest = failingTest
        self.file = file
        self.line = line
        self.hypothesis = hypothesis
        self.confidence = confidence
    }

    /// Stable keys — the JSON contract the cloud prompt asks for.
    private enum CodingKeys: String, CodingKey {
        case failingTest
        case file
        case line
        case hypothesis
        case confidence
    }

    /// Decodes a diagnosis the way models actually write one.
    ///
    /// Three tolerances, each for a shape seen from real endpoints, and no more than that:
    ///
    /// - an empty or whitespace-only `failingTest`/`file` is `nil`, because `""` is how a model
    ///   says "not applicable" when the field is not optional in its own head;
    /// - `line` is accepted as a number *or* as a numeric string, since JSON written by a model
    ///   quotes numbers about as often as not; anything else is `nil` rather than an error,
    ///   because a line number is the least load-bearing field on the card;
    /// - an absent `confidence` reads as ``Confidence/low``: a model that did not say how sure it
    ///   is has not earned more than that.
    ///
    /// `hypothesis` is required. It *is* the answer — without it there is nothing to show.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        failingTest = try container.decodeIfPresent(String.self, forKey: .failingTest)?
            .intelligenceTrimmedOrNil
        file = try container.decodeIfPresent(String.self, forKey: .file)?
            .intelligenceTrimmedOrNil
        line = Self.decodeLine(from: container)
        hypothesis = try container.decode(String.self, forKey: .hypothesis)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        confidence = try container.decodeIfPresent(Confidence.self, forKey: .confidence) ?? .low
    }

    /// Reads `line` as an integer, as a numeric string, or not at all.
    /// - Parameter container: The decoding container.
    /// - Returns: The line number, or `nil`.
    private static func decodeLine(from container: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let number = (try? container.decodeIfPresent(Int.self, forKey: .line)).flatMap({ $0 }) {
            return number
        }
        guard let text = (try? container.decodeIfPresent(String.self, forKey: .line))
            .flatMap({ $0 }),
            let trimmed = text.intelligenceTrimmedOrNil
        else { return nil }
        return Int(trimmed)
    }
}

// MARK: - Thread digest

/// Where a review thread stands (plan §3.G).
///
/// Tier 2 only by decision: the input is colleagues' comments, which never travel to a BYOK
/// endpoint. The twin still lives here, because the type, its keys and its decoding are worth
/// testing on Linux even when only one tier will ever produce one.
public struct ThreadDigest: Codable, Sendable, Hashable {
    /// What the thread has arrived at.
    public enum State: String, Codable, Sendable, Hashable, CaseIterable {
        /// The participants agreed on what happens next.
        case agreed
        /// The discussion is still going.
        case open
        /// Somebody is waiting on somebody else.
        case blocked

        public init(from decoder: any Decoder) throws {
            self = try IntelligenceEnumDecoding.decode(from: decoder, as: State.self)
        }
    }

    /// What the thread has arrived at.
    public var state: State
    /// A few lines on what was agreed.
    public var summary: String
    /// The questions nobody has answered yet, one per entry.
    public var openQuestions: [String]

    /// Creates a digest.
    /// - Parameters:
    ///   - state: What the thread has arrived at.
    ///   - summary: What was agreed.
    ///   - openQuestions: The unanswered questions.
    public init(state: State, summary: String, openQuestions: [String] = []) {
        self.state = state
        self.summary = summary
        self.openQuestions = openQuestions
    }

    /// Stable keys — the JSON contract the prompt asks for.
    private enum CodingKeys: String, CodingKey {
        case state
        case summary
        case openQuestions
    }

    /// Decodes a digest, tolerating an omitted question list.
    ///
    /// A thread where everything is settled has no open questions, and a model expressing that by
    /// leaving the key out is not an error — it is the most common way of saying it. Blank
    /// entries are dropped for the same reason they are in ``CIDiagnosis``: `[""]` would draw an
    /// empty bullet.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(State.self, forKey: .state)
        summary = try container.decode(String.self, forKey: .summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        openQuestions = raw.compactMap { $0.intelligenceTrimmedOrNil }
    }
}

// MARK: - Delegation brief

/// The task a coding agent is handed, as a model drafted it (plan §3.E).
///
/// The `Codable` twin of the on-device `@Generable` struct, here for ADR 0007's reason: the shape,
/// its decoding tolerances and its rendering are provider-neutral and therefore testable on Linux,
/// and only the Apple-only mirror of it lives in the app target.
///
/// Three fields because a brief that is useful to an agent answers three questions and no more:
/// what to achieve, what not to touch, and how the reviewer will know it worked. The rendering
/// below is the *only* thing that turns those into text, so the prompt that asks a tier for the
/// three sections and the code that writes them can be pinned against each other
/// (``goalHeading`` and its siblings are what both sides name).
///
/// It stays a **suggestion**: the Markdown lands in the delegation sheet's task field, the reviewer
/// edits it, and Run is still their click (ADR 0011 amendment).
public struct AgentBrief: Codable, Sendable, Hashable {
    /// The heading the goal section carries.
    ///
    /// Public constants rather than literals inside ``markdown``, because the prompt asks the tier
    /// for these exact headings: two spellings of "## Goal" would be a brief the reviewer reads
    /// twice.
    public static let goalHeading = "## Goal"
    /// The heading the constraints section carries.
    public static let constraintsHeading = "## Constraints"
    /// The heading the acceptance section carries.
    public static let acceptanceHeading = "## Acceptance"

    /// What the agent is being asked to achieve, in one or two sentences.
    public var goal: String
    /// What it must keep to, or must not do. One short line each.
    public var constraints: [String]
    /// What the reviewer should see when the work is done. One short line each.
    public var acceptance: [String]

    /// Creates a brief.
    /// - Parameters:
    ///   - goal: What to achieve.
    ///   - constraints: What to keep to.
    ///   - acceptance: How the reviewer will know it worked.
    public init(goal: String, constraints: [String] = [], acceptance: [String] = []) {
        self.goal = goal
        self.constraints = constraints
        self.acceptance = acceptance
    }

    /// Stable keys: they are the JSON contract a cloud prompt would ask for, so renaming one is a
    /// prompt change rather than a refactor.
    private enum CodingKeys: String, CodingKey {
        case goal
        case constraints
        case acceptance
    }

    /// Decodes a brief the way a model actually writes one.
    ///
    /// `goal` is required — it *is* the task, and a brief without it is not a brief. The two lists
    /// are not: a mechanical fix has no constraints worth listing, and a model expressing that by
    /// leaving the key out is the most common way of saying it. Blank entries are dropped for the
    /// same reason ``CIDiagnosis`` drops them: `[""]` renders as an empty bullet.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = try container.decode(String.self, forKey: .goal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawConstraints = try container.decodeIfPresent([String].self, forKey: .constraints) ?? []
        constraints = rawConstraints.compactMap { $0.intelligenceTrimmedOrNil }
        let rawAcceptance = try container.decodeIfPresent([String].self, forKey: .acceptance) ?? []
        acceptance = rawAcceptance.compactMap { $0.intelligenceTrimmedOrNil }
    }

    /// The brief as the Markdown that goes into the task field.
    ///
    /// A section with nothing in it is left out rather than rendered as a bare heading: the task
    /// field is handed to an agent verbatim, and "## Constraints" followed by nothing reads as an
    /// instruction that was cut off. Pure and deterministic, so the rendering is a Linux test
    /// rather than something inspected in a screenshot.
    public var markdown: String {
        var sections: [String] = []
        if !goal.isEmpty {
            sections.append(AgentBrief.goalHeading + "\n\n" + goal)
        }
        if !constraints.isEmpty {
            sections.append(
                AgentBrief.constraintsHeading + "\n\n" + AgentBrief.bullets(constraints)
            )
        }
        if !acceptance.isEmpty {
            sections.append(
                AgentBrief.acceptanceHeading + "\n\n" + AgentBrief.bullets(acceptance)
            )
        }
        return sections.joined(separator: "\n\n")
    }

    /// Renders a list as Markdown bullets.
    /// - Parameter lines: The list.
    /// - Returns: One `- ` bullet per line.
    private static func bullets(_ lines: [String]) -> String {
        lines.map { "- \($0)" }.joined(separator: "\n")
    }
}
