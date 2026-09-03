import Foundation

/// One checkable fact about a pull request, written as a sentence.
///
/// A fact is never a judgement — "8 of 11 changed files are under “Sources/Parser”" is a fact,
/// "the scope claim is wrong" is not — because the whole point of the claims card is that the
/// reviewer draws the conclusion (ADR 0026, ADR 0007's "hints, never verdicts").
///
/// ``path`` and ``line`` exist so a fact can be *checked in one click*: they are what the card
/// turns into a link into the diff viewer. A fact without a path is not a lesser fact; it is one
/// about the pull request as a whole ("CI is green: 7 of 7 checks passed").
public struct EvidenceFact: Sendable, Codable, Hashable, Identifiable {
    /// The fact, as one sentence. Already ends in a full stop.
    public var text: String
    /// The changed file the fact is about, when it is about one.
    public var path: String?
    /// The head-side line the fact is about, when it names one.
    ///
    /// Head-side, because that is the numbering the diff viewer and GitHub's review API speak
    /// (see ``PatchRow/headLine``). For a deleted line it is the line the deletion sits in front
    /// of, which is where a reviewer following the link needs to land.
    public var line: Int?
    /// A link out of the app, for a fact whose subject is not in the diff at all.
    ///
    /// Currently only the issue reference, which is a GitHub URL rather than a file — Shepherd
    /// does not read issues (ADR 0026), so the honest thing a fact about `#142` can offer is the
    /// address of `#142`.
    public var url: URL?

    /// Creates a fact.
    /// - Parameters:
    ///   - text: The sentence.
    ///   - path: The changed file it is about, if any.
    ///   - line: The head-side line it names, if any.
    ///   - url: An external link, if any.
    public init(text: String, path: String? = nil, line: Int? = nil, url: URL? = nil) {
        self.text = text
        self.path = path
        self.line = line
        self.url = url
    }

    /// A fact is identified by what it says and where.
    public var id: String {
        let lineKey: String
        if let line {
            lineKey = "\(line)"
        } else {
            lineKey = ""
        }
        return "\(text)|\(path ?? "")|\(lineKey)"
    }
}

/// What the diff and CI say about one claim: a status and the facts it was derived from.
///
/// **The facts come first and the status is a function of them.** That order is the design: the
/// status is one glyph, it is derived by the documented rules in ``EvidenceChecker``, and it is
/// never the only thing on the card — a `contradicted` line always carries the facts that
/// contradict it, so a reviewer who disagrees with Shepherd can see exactly where it went wrong.
/// There is no score and no aggregate across lines, because a number would be a verdict.
public struct EvidenceVerdict: Sendable, Codable, Hashable {
    /// The three answers a line can give. There is deliberately no fourth, and no ranking.
    public enum Status: String, Sendable, Codable, Hashable, CaseIterable {
        /// The evidence supports the claim. ✓
        case ok
        /// The evidence contradicts the claim. ✗
        case contradicted
        /// The evidence is not enough to say either way. ?
        case unclear
    }

    /// The status, derived from ``facts``.
    public var status: Status
    /// The facts, in the order the checker produced them.
    public var facts: [EvidenceFact]

    /// Creates a verdict.
    /// - Parameters:
    ///   - status: The derived status.
    ///   - facts: The facts it was derived from.
    public init(status: Status, facts: [EvidenceFact]) {
        self.status = status
        self.facts = facts
    }
}

/// Looks for evidence of one claim in a pull request's diff and CI — pure, deterministic, and
/// testable without a Mac (tier 1 of ADR 0007, ADR 0026).
///
/// Nothing here reads the network. The inputs are exactly what ``PullRequestDetail`` already
/// holds after a detail fetch: the changed files with their patches, the check runs, and the
/// pull request's own row. That is a decision, not a limitation of the current code — a card that
/// opens on every pull request must cost nothing, and the one thing it would need a network for
/// (the referenced issue's acceptance bullets) is left explicitly unchecked and *says so*.
public enum EvidenceChecker {
    // MARK: - Entry point

    /// Checks one claim.
    /// - Parameters:
    ///   - claim: The claim to look for evidence of.
    ///   - detail: Everything Shepherd knows about the pull request.
    /// - Returns: The status and the facts behind it.
    public static func check(_ claim: Claim, in detail: PullRequestDetail) -> EvidenceVerdict {
        switch claim.kind {
        case .testsAdded:
            return checkTests(in: detail)
        case .scopeLimited(let module):
            return checkScope(module: module, in: detail)
        case .noBreakingChanges:
            return checkBreakingChanges(in: detail)
        case .fixesIssue(let number):
            return checkIssue(number: number, in: detail)
        }
    }

    // MARK: - Tests

    /// Evidence for "tests added / tests pass".
    ///
    /// Three independent signals, and the status rule that combines them:
    ///
    /// 1. **Changed test files**, classified by ``FilePrioritizer/category(of:)`` — the same
    ///    conventions the file list already ranks by (`Tests/`, `*Tests.swift`, `__tests__/`,
    ///    `*.spec.*`, `*.test.*`, `test_*.py`, `*_test.go`, …), so the card and the file list
    ///    cannot disagree about what a test file is.
    /// 2. **The check rollup**, with the failing checks named.
    /// 3. **Assertion drift** over the hunks: an assertion removed, or a skip added.
    ///
    /// | Facts | Status |
    /// | --- | --- |
    /// | any assertion drift | ✗ contradicted |
    /// | no test file changed **and** CI not green | ✗ contradicted |
    /// | a test file changed **and** CI green | ✓ ok |
    /// | anything else | ? unclear |
    ///
    /// Drift outranks a green CI on purpose: a hunk that deletes an `XCTAssert` or adds an
    /// `XCTSkip` makes CI *greener*, and a card that read "✓ tests added, CI green" over exactly
    /// that hunk would be actively misleading. This is the case the feature exists for.
    private static func checkTests(in detail: PullRequestDetail) -> EvidenceVerdict {
        var facts: [EvidenceFact] = []

        let testFiles = detail.files.filter { FilePrioritizer.category(of: $0) == .tests }
        if testFiles.isEmpty {
            facts.append(EvidenceFact(text: "No changed file matches a test naming convention."))
        } else {
            facts.append(
                EvidenceFact(
                    text: testFiles.count == 1
                        ? "1 changed file matches a test naming convention."
                        : "\(testFiles.count) changed files match a test naming convention."
                )
            )
            for file in testFiles.prefix(namedFileLimit) {
                facts.append(
                    EvidenceFact(
                        text: "\(quoted(file.path)) is a test file (+\(file.additions) −\(file.deletions)).",
                        path: file.path
                    )
                )
            }
        }

        // Qualified and renamed: an unqualified `rollup(of:)` assigned to a local called
        // `rollup` is a name that resolves to itself.
        let ciRollup = EvidenceChecker.rollup(of: detail)
        facts.append(contentsOf: checkFacts(rollup: ciRollup, checks: detail.checks))

        let drift = assertionDrift(in: detail.files)
        facts.append(contentsOf: drift)

        let isGreen = ciRollup?.state == CheckRollup.State.success
        let status: EvidenceVerdict.Status
        if !drift.isEmpty {
            status = .contradicted
        } else if testFiles.isEmpty, !isGreen {
            status = .contradicted
        } else if !testFiles.isEmpty, isGreen {
            status = .ok
        } else {
            status = .unclear
        }
        return EvidenceVerdict(status: status, facts: facts)
    }

    /// An assertion removed, or a skip added, anywhere in the diff.
    ///
    /// Both halves are needed and they are different failures: deleting the assertion that used
    /// to fail turns a red suite green without fixing anything, and adding a skip does the same
    /// while leaving the assertion in the file where a reader will still see it. Each hit is one
    /// fact with a path and a head-side line, so the reviewer can open it.
    ///
    /// The patterns are literal markers of the five ecosystems this repository and the pull
    /// requests it reviews actually use; a file whose language has no marker in the lists simply
    /// contributes no drift, which is a quiet answer rather than a wrong one.
    /// - Parameter files: The changed files.
    /// - Returns: The drift facts, capped so one machine-rewritten test file cannot fill the card.
    static func assertionDrift(in files: [ChangedFile]) -> [EvidenceFact] {
        var facts: [EvidenceFact] = []
        for file in files {
            guard let patch = file.patch, !patch.isEmpty else { continue }
            for row in PatchWalker.rows(in: patch) {
                guard facts.count < driftLimit else { return facts }
                switch row.kind {
                case .removed where removedAssertion.matches(row.text):
                    facts.append(
                        EvidenceFact(
                            text: "\(quoted(file.path)) removes an assertion at line \(row.headLine): \(quoted(snippet(row.text))).",
                            path: file.path,
                            line: row.headLine
                        )
                    )
                case .added where addedSkip.matches(row.text):
                    facts.append(
                        EvidenceFact(
                            text: "\(quoted(file.path)) adds a skipped test at line \(row.headLine): \(quoted(snippet(row.text))).",
                            path: file.path,
                            line: row.headLine
                        )
                    )
                default:
                    continue
                }
            }
        }
        return facts
    }

    // MARK: - Scope

    /// Evidence for "only X changed".
    ///
    /// The module token is matched against paths **fuzzily**: the token appears anywhere in the
    /// path, case-insensitively, and a renamed file's previous path counts too. Fuzzy because the
    /// token comes from prose — "the parser", "`Sources/Parser/`" and "Parser" all have to reach
    /// `Sources/Parser/Lexer.swift`, and an exact prefix rule would only ever match the second.
    ///
    /// | Facts | Status |
    /// | --- | --- |
    /// | the claim names no module ("no other changes") | ? unclear |
    /// | no changed path contains the token | ? unclear |
    /// | every changed path contains the token | ✓ ok |
    /// | some changed path does not | ✗ contradicted |
    ///
    /// "No changed path contains the token" is deliberately *not* a contradiction: the reviewer's
    /// word for a module and the repository's directory names often differ, and Shepherd claiming
    /// a contradiction it cannot substantiate is exactly the failure ADR 0026 forbids.
    ///
    /// The workflow, lockfile, generated-file and configuration flags are appended whatever the
    /// module says, because they are the four things a "only a small change" claim most often
    /// hides — and they are ``FilePrioritizer``'s own classifications rather than a second copy
    /// of them.
    private static func checkScope(module: String, in detail: PullRequestDetail) -> EvidenceVerdict {
        var facts: [EvidenceFact] = []
        let files = detail.files

        guard !files.isEmpty else {
            return EvidenceVerdict(
                status: .unclear,
                facts: [EvidenceFact(text: "The pull request has no changed files.")]
            )
        }

        facts.append(topLevelFact(for: files))

        let token = module.trimmingCharacters(in: .whitespaces)
        let status: EvidenceVerdict.Status
        if token.isEmpty {
            facts.append(
                EvidenceFact(
                    text: "The claim names no module, so there is nothing to match the changed paths against."
                )
            )
            status = .unclear
        } else {
            let needle = token.lowercased()
            let inside = files.filter { matches(needle: needle, file: $0) }
            if inside.isEmpty {
                facts.append(
                    EvidenceFact(
                        text: "No changed path contains \(quoted(token)), so the claim could not be matched to the diff."
                    )
                )
                status = .unclear
            } else {
                facts.append(
                    EvidenceFact(
                        text: "\(inside.count) of \(files.count) changed files are under \(quoted(token))."
                    )
                )
                let outside = files.filter { !matches(needle: needle, file: $0) }
                for file in outside.prefix(namedFileLimit) {
                    facts.append(
                        EvidenceFact(
                            text: "\(quoted(file.path)) is outside \(quoted(token)).",
                            path: file.path
                        )
                    )
                }
                status = outside.isEmpty ? .ok : .contradicted
            }
        }

        facts.append(contentsOf: classificationFacts(for: files))
        return EvidenceVerdict(status: status, facts: facts)
    }

    // MARK: - Breaking changes

    /// Evidence for "no breaking changes".
    ///
    /// Three kinds of fact, and they carry different weight because they answer different
    /// questions:
    ///
    /// - **A removed or changed exported declaration** is somebody else's compile error. Detected
    ///   per language by extension, over the `-` rows of every hunk: Swift `public`/`open`/
    ///   `package` declarations, TypeScript and JavaScript `export`/`declare`, Go's
    ///   capitalised `func`/`type`/`var`/`const`, Python's non-underscored `def`/`class`. A file
    ///   in a language with no rule here contributes nothing rather than a guess.
    /// - **A migration or schema change** breaks data rather than code, which is why it counts
    ///   even though no symbol moved.
    /// - **A manifest's version or dependency line** (`Package.swift`, `package.json`) breaks a
    ///   consumer's resolution.
    ///
    /// | Facts | Status |
    /// | --- | --- |
    /// | an exported declaration removed or changed | ✗ contradicted |
    /// | a migration, or a manifest version/dependency line | ? unclear |
    /// | no patch was readable at all | ? unclear |
    /// | none of the above | ✓ ok |
    ///
    /// CI-workflow and configuration changes are *named* and do not move the status: a workflow
    /// is not somebody else's API, and a rule that turned every `.yml` into a question mark would
    /// make the line meaningless on the pull requests that touch one routinely.
    ///
    /// "Removes **or changes**" is honest about what a `-` row proves: a signature edit appears as
    /// a removal and an addition, and Shepherd does not try to pair them up — the fact names the
    /// line, and the reviewer opens it.
    private static func checkBreakingChanges(in detail: PullRequestDetail) -> EvidenceVerdict {
        var facts: [EvidenceFact] = []
        var declarations: [EvidenceFact] = []
        var dataOrDependency: [EvidenceFact] = []
        var readAnyPatch = false

        for file in detail.files {
            if let patch = file.patch, !patch.isEmpty {
                readAnyPatch = true
                if let pattern = exportedDeclarationPattern(for: file) {
                    for row in PatchWalker.rows(in: patch) where row.kind == .removed {
                        guard declarations.count < declarationLimit else { break }
                        guard pattern.matches(row.text) else { continue }
                        declarations.append(
                            EvidenceFact(
                                text: "\(quoted(file.path)) removes or changes an exported declaration at line \(row.headLine): \(quoted(snippet(row.text))).",
                                path: file.path,
                                line: row.headLine
                            )
                        )
                    }
                }
                if isManifest(file), manifestLine(in: patch) {
                    dataOrDependency.append(
                        EvidenceFact(
                            text: "\(quoted(file.path)) changes a version or dependency line.",
                            path: file.path
                        )
                    )
                }
            }
            if isSchemaChange(file) {
                dataOrDependency.append(
                    EvidenceFact(
                        text: "\(quoted(file.path)) changes the database schema or a migration.",
                        path: file.path
                    )
                )
            }
        }

        facts.append(contentsOf: declarations)
        facts.append(contentsOf: dataOrDependency)

        let configuration = detail.files
            .filter { isWorkflow($0) || FilePrioritizer.category(of: $0) == .config }
            .prefix(namedFileLimit)
            .map { file in
                EvidenceFact(
                    text: isWorkflow(file)
                        ? "\(quoted(file.path)) changes a CI workflow."
                        : "\(quoted(file.path)) changes configuration.",
                    path: file.path
                )
            }
        facts.append(contentsOf: configuration)

        if !readAnyPatch {
            facts.append(
                EvidenceFact(
                    text: "No diff was readable; GitHub sends no patch for binary files and for diffs it truncated."
                )
            )
        } else if declarations.isEmpty {
            facts.append(
                EvidenceFact(
                    text: "No exported declaration is removed or changed in the diff Shepherd read."
                )
            )
        }

        let status: EvidenceVerdict.Status
        if !declarations.isEmpty {
            status = .contradicted
        } else if !dataOrDependency.isEmpty || !readAnyPatch {
            status = .unclear
        } else {
            status = .ok
        }
        return EvidenceVerdict(status: status, facts: facts)
    }

    // MARK: - Issue

    /// Evidence for "fixes #N".
    ///
    /// **Always unclear, and that is the feature.** The reference is a fact — it exists, and here
    /// is where it points. Whether the pull request does what `#142` asks for is a question about
    /// `#142`'s acceptance bullets, and Shepherd does not fetch issues: `GitHubKit` has no issue
    /// read (ADR 0026), so this line says what it checked and what it did not, rather than
    /// implying the reference is enough. Adding the read is an additive later step; a ✓ here today
    /// would be a claim Shepherd cannot make.
    private static func checkIssue(number: Int, in detail: PullRequestDetail) -> EvidenceVerdict {
        let repo = detail.summary.repo
        let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)/issues/\(number)")
        return EvidenceVerdict(
            status: .unclear,
            facts: [
                EvidenceFact(
                    text: "Issue #\(number) of \(repo.fullName) is referenced.",
                    url: url
                ),
                EvidenceFact(
                    text: "Acceptance criteria not checked — the issue is not fetched."
                ),
            ]
        )
    }

    // MARK: - Shared facts

    /// The check rollup to reason with.
    ///
    /// The fetched check runs win over the row's rollup when there are any: they are the per-check
    /// truth and they carry the counts, while the inbox sweep's rollup often carries only a state
    /// (ADR 0005). With no runs fetched, the row's rollup is all there is.
    /// - Parameter detail: The pull request.
    /// - Returns: The rollup, or `nil` when nothing is known about CI.
    static func rollup(of detail: PullRequestDetail) -> CheckRollup? {
        if !detail.checks.isEmpty { return CheckRollup(runs: detail.checks) }
        return detail.summary.checkRollup
    }

    private static func checkFacts(rollup: CheckRollup?, checks: [CheckRun]) -> [EvidenceFact] {
        guard let rollup, rollup.state != CheckRollup.State.none else {
            return [EvidenceFact(text: "No checks are configured for this commit.")]
        }
        var facts: [EvidenceFact] = []
        switch rollup.state {
        case .success:
            facts.append(
                EvidenceFact(
                    text: rollup.total > 0
                        ? "CI is green: \(rollup.successCount) of \(counted(rollup.total)) passed."
                        : "CI is green."
                )
            )
        case .failure:
            facts.append(
                EvidenceFact(
                    text: rollup.total > 0
                        ? "CI is red: \(rollup.failureCount) of \(counted(rollup.total)) failed."
                        : "CI is red."
                )
            )
            let failing = checks.filter { $0.rollupContribution == .failure }
            for check in failing.prefix(namedCheckLimit) {
                facts.append(EvidenceFact(text: "Check \(quoted(check.name)) failed."))
            }
        case .pending:
            let running = rollup.pendingCount
            facts.append(
                EvidenceFact(
                    text: running == 0
                        ? "CI has not finished."
                        : (running == 1
                            ? "CI has not finished: 1 check is still running."
                            : "CI has not finished: \(running) checks are still running.")
                )
            )
        case .none:
            break
        }
        return facts
    }

    /// "The pull request touches 3 top-level paths: …".
    private static func topLevelFact(for files: [ChangedFile]) -> EvidenceFact {
        var seen: Set<String> = []
        var ordered: [String] = []
        for file in files {
            let component = file.path.contains("/")
                ? (file.path.split(separator: "/").first.map(String.init) ?? "(repository root)")
                : "(repository root)"
            if seen.insert(component).inserted { ordered.append(component) }
        }
        let named = ordered.sorted().prefix(namedPathLimit).map { quoted($0) }.joined(separator: ", ")
        let suffix = ordered.count > namedPathLimit ? "\(named), …" : named
        return EvidenceFact(
            text: ordered.count == 1
                ? "The pull request touches 1 top-level path: \(suffix)."
                : "The pull request touches \(ordered.count) top-level paths: \(suffix)."
        )
    }

    /// The workflow / lockfile / generated / configuration flags, one fact each.
    ///
    /// In that order and mutually exclusive per file, because the four overlap by design:
    /// ``FilePrioritizer`` already calls a lockfile generated and a `.github/` file configuration,
    /// and a card that said all three about `Package.resolved` would be padding rather than
    /// reporting.
    private static func classificationFacts(for files: [ChangedFile]) -> [EvidenceFact] {
        var facts: [EvidenceFact] = []
        var workflows = 0
        var lockfiles = 0
        var generated = 0
        var configs = 0
        for file in files {
            let category = FilePrioritizer.category(of: file)
            if isWorkflow(file) {
                guard workflows < namedFileLimit else { continue }
                workflows += 1
                facts.append(
                    EvidenceFact(text: "\(quoted(file.path)) changes a CI workflow.", path: file.path)
                )
            } else if FilePrioritizer.isLockfile(file) {
                guard lockfiles < namedFileLimit else { continue }
                lockfiles += 1
                facts.append(
                    EvidenceFact(
                        text: "\(quoted(file.path)) is a dependency lockfile.",
                        path: file.path
                    )
                )
            } else if category == .generated {
                guard generated < namedFileLimit else { continue }
                generated += 1
                facts.append(
                    EvidenceFact(
                        text: "\(quoted(file.path)) is a generated or vendored file.",
                        path: file.path
                    )
                )
            } else if category == .config {
                guard configs < namedFileLimit else { continue }
                configs += 1
                facts.append(
                    EvidenceFact(text: "\(quoted(file.path)) is configuration.", path: file.path)
                )
            }
        }
        return facts
    }

    // MARK: - Classification helpers

    /// Whether a path is a GitHub Actions workflow. The same test ``FilePrioritizer`` scores with.
    static func isWorkflow(_ file: ChangedFile) -> Bool {
        let path = file.path.lowercased()
        return path.hasPrefix(".github/workflows/") || path.contains("/.github/workflows/")
    }

    /// Whether a file is a schema definition or a migration.
    static func isSchemaChange(_ file: ChangedFile) -> Bool {
        let path = file.path
        if path.contains("Migrations/") || path.contains("migrations/") { return true }
        let name = file.fileName.lowercased()
        return name == "databasemanager.swift" || name == "schema.sql" || name == "schema.rb"
    }

    /// Whether a file is a package manifest whose version and dependency lines matter to others.
    static func isManifest(_ file: ChangedFile) -> Bool {
        let name = file.fileName.lowercased()
        return name == "package.swift" || name == "package.json"
    }

    private static func manifestLine(in patch: String) -> Bool {
        PatchWalker.rows(in: patch)
            .contains { $0.kind != .context && manifestInterest.matches($0.text) }
    }

    private static func matches(needle: String, file: ChangedFile) -> Bool {
        if file.path.lowercased().contains(needle) { return true }
        return file.previousPath?.lowercased().contains(needle) == true
    }

    /// The exported-declaration pattern for a file's language, or `nil` for a language with none.
    static func exportedDeclarationPattern(for file: ChangedFile) -> ClaimPattern? {
        switch file.fileExtension {
        case "swift": return swiftExported
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts": return scriptExported
        case "go": return goExported
        case "py": return pythonExported
        default: return nil
        }
    }

    // MARK: - Patterns

    /// An assertion being removed or weakened.
    private static let removedAssertion = ClaimPattern(
        #"XCTAssert|expect\(|assert |assert\(|assertEquals|assertEqual\(|t\.Fatal|t\.Error"#,
        caseInsensitive: false
    )
    /// A test being skipped.
    private static let addedSkip = ClaimPattern(
        #"XCTSkip|\.skip\(|\bxit\(|\bxdescribe\(|@unittest\.skip|pytest\.mark\.skip|t\.Skip\("#,
        caseInsensitive: false
    )

    /// Swift: an access modifier that makes a declaration somebody else's API.
    ///
    /// A bare `func` is *internal* in Swift and therefore not part of anybody's API, which is why
    /// this asks for the keyword rather than for the shape of a declaration — flagging every
    /// removed private helper as a breaking change would make the line say ✗ on almost every pull
    /// request.
    private static let swiftExported = ClaimPattern(
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open|package)\s"#,
        caseInsensitive: false
    )
    /// TypeScript and JavaScript: an `export` or an ambient declaration.
    private static let scriptExported = ClaimPattern(
        #"^\s*(?:export\b|declare\s)"#,
        caseInsensitive: false
    )
    /// Go: a capitalised top-level identifier is the exported one.
    private static let goExported = ClaimPattern(
        #"^\s*(?:func\s+(?:\([^)]*\)\s*)?[A-Z]\w*\s*[(\[]|(?:type|var|const)\s+[A-Z]\w*)"#,
        caseInsensitive: false
    )
    /// Python: a `def` or `class` whose name does not start with an underscore.
    private static let pythonExported = ClaimPattern(
        #"^\s*(?:(?:async\s+)?def|class)\s+[A-Za-z]\w*"#,
        caseInsensitive: false
    )
    /// A manifest line that names a version or a dependency.
    private static let manifestInterest = ClaimPattern(
        #"\bversions?\b|\bdependenc\w*|\.package\(|\bfrom:\s*""#
    )

    // MARK: - Limits and formatting

    /// How many files one fact list names before it stops.
    private static let namedFileLimit = 4
    /// How many top-level paths the scope fact names.
    private static let namedPathLimit = 6
    /// How many failing checks are named.
    private static let namedCheckLimit = 3
    /// How many drift facts one pull request can produce.
    private static let driftLimit = 8
    /// How many exported-declaration facts one pull request can produce.
    private static let declarationLimit = 6
    /// How much of a diff line a fact quotes.
    private static let snippetLimit = 80

    /// A fact quotes a path, a token or a line of code in typographic quotes.
    ///
    /// The same shape ``FilePrioritizer``'s reasons use, and not backticks: the card renders these
    /// as text, so a backtick would be a backtick on screen.
    private static func quoted(_ text: String) -> String { "“\(text)”" }

    /// "1 check" / "7 checks" — so a fact reads as English at both ends of the range.
    private static func counted(_ checks: Int) -> String {
        checks == 1 ? "1 check" : "\(checks) checks"
    }

    private static func snippet(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > snippetLimit else { return trimmed }
        return String(trimmed.prefix(snippetLimit)) + "…"
    }
}
