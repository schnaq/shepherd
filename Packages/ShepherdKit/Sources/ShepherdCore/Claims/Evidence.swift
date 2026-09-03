import Foundation

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

/// Why the referenced issue could not be read.
///
/// A closed set of four, and a *case* rather than a message: the app's job is to classify its own
/// transport error into one of these — it is the only layer that can, since `ShepherdCore` cannot
/// see `GitHubKit`'s error type — and the case travels as ``EvidenceFact/Kind/issueLookupFailed(_:)``
/// like every other fact. ``sentence`` is the English rendering, on the same terms as
/// ``EvidenceFact/englishSentence``: it is what a test and a GitHub comment read, while the card
/// reads the app's localised sentence for the same case (ADR 0022, ADR 0026).
public enum IssueLookupFailure: String, Sendable, Codable, Hashable, CaseIterable {
    /// GitHub answered `404`: no issue with that number in this repository.
    case notFound
    /// GitHub refused: the token cannot see this issue, or the account is not signed in.
    case noPermission
    /// The request never reached GitHub.
    case offline
    /// Anything else — a rate limit, a malformed body, a server error.
    case failed

    /// The fact this failure contributes, as one English sentence.
    public var sentence: String {
        switch self {
        case .notFound:
            return "The issue could not be read: GitHub has no issue with that number in this repository."
        case .noPermission:
            return "The issue could not be read: this account cannot see it."
        case .offline:
            return "The issue could not be read: GitHub could not be reached."
        case .failed:
            return "The issue could not be read."
        }
    }
}

/// Looks for evidence of one claim in a pull request's diff and CI — pure, deterministic, and
/// testable without a Mac (tier 1 of ADR 0007, ADR 0026).
///
/// Nothing here reads the network, and that is still the rule. The inputs are what
/// ``PullRequestDetail`` already holds after a detail fetch: the changed files with their patches,
/// the check runs, and the pull request's own row. The **one** exception is passed *in* rather
/// than fetched here — the referenced issue and the acceptance bullets matched against it
/// (ADR 0026's amendment) — so this type stays a pure function of values a Linux test can write
/// by hand, and the app decides when the single `GET` behind them is worth making.
public enum EvidenceChecker {
    // MARK: - Entry point

    /// Checks one claim against the diff and CI alone.
    ///
    /// The shape every claim but `fixes #N` needs, and a wrapper over
    /// ``check(_:in:issue:matches:failure:)`` so there is one implementation of each rule. An
    /// issue line checked this way says the criteria were not checked, which is what it said
    /// before there was an issue read at all.
    /// - Parameters:
    ///   - claim: The claim to look for evidence of.
    ///   - detail: Everything Shepherd knows about the pull request.
    /// - Returns: The status and the facts behind it.
    public static func check(_ claim: Claim, in detail: PullRequestDetail) -> EvidenceVerdict {
        check(claim, in: detail, issue: nil, matches: nil)
    }

    /// Checks one claim, with the referenced issue when the app has fetched it.
    ///
    /// The hook ADR 0026's amendment adds. Only ``Claim/Kind/fixesIssue(number:)`` reads the
    /// three extra arguments; the other three claims are answered from `detail` exactly as
    /// before, so a caller with an issue in hand can use this entry point for every line of the
    /// card without branching.
    /// - Parameters:
    ///   - claim: The claim to look for evidence of.
    ///   - detail: Everything Shepherd knows about the pull request.
    ///   - issue: The referenced issue, or `nil` when it was not fetched, could not be fetched, or
    ///     this claim is not about an issue.
    ///   - matches: One match per acceptance bullet, from
    ///     ``AcceptanceMatcher/match(bullets:against:vectors:)``. An empty array means the issue
    ///     was read and holds no checklist — which is a different answer from `nil`, and the card
    ///     says so.
    ///   - failure: Why the issue could not be read, when it could not.
    /// - Returns: The status and the facts behind it.
    public static func check(
        _ claim: Claim,
        in detail: PullRequestDetail,
        issue: IssueSummary?,
        matches: [AcceptanceMatch]?,
        failure: IssueLookupFailure? = nil
    ) -> EvidenceVerdict {
        switch claim.kind {
        case .testsAdded:
            return checkTests(in: detail)
        case .scopeLimited(let module):
            return checkScope(module: module, in: detail)
        case .noBreakingChanges:
            return checkBreakingChanges(in: detail)
        case .fixesIssue(let number):
            return checkIssue(
                number: number,
                in: detail,
                issue: issue,
                matches: matches,
                failure: failure
            )
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
            facts.append(EvidenceFact(kind: .noTestFileChanged))
        } else {
            facts.append(EvidenceFact(kind: .testFilesChanged(count: testFiles.count)))
            for file in testFiles.prefix(namedFileLimit) {
                facts.append(
                    EvidenceFact(
                        kind: .testFile(
                            path: file.path,
                            additions: file.additions,
                            deletions: file.deletions
                        ),
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
                            kind: .assertionRemoved(
                                path: file.path,
                                line: row.headLine,
                                snippet: snippet(row.text)
                            ),
                            path: file.path,
                            line: row.headLine
                        )
                    )
                case .added where addedSkip.matches(row.text):
                    facts.append(
                        EvidenceFact(
                            kind: .skippedTestAdded(
                                path: file.path,
                                line: row.headLine,
                                snippet: snippet(row.text)
                            ),
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
                facts: [EvidenceFact(kind: .noChangedFiles)]
            )
        }

        facts.append(topLevelFact(for: files))

        let token = module.trimmingCharacters(in: .whitespaces)
        let status: EvidenceVerdict.Status
        if token.isEmpty {
            facts.append(EvidenceFact(kind: .claimNamesNoModule))
            status = .unclear
        } else {
            let needle = token.lowercased()
            let inside = files.filter { matches(needle: needle, file: $0) }
            if inside.isEmpty {
                facts.append(EvidenceFact(kind: .noPathContainsToken(token: token)))
                status = .unclear
            } else {
                facts.append(
                    EvidenceFact(
                        kind: .filesUnderToken(
                            inside: inside.count,
                            total: files.count,
                            token: token
                        )
                    )
                )
                let outside = files.filter { !matches(needle: needle, file: $0) }
                for file in outside.prefix(namedFileLimit) {
                    facts.append(
                        EvidenceFact(
                            kind: .fileOutsideToken(path: file.path, token: token),
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
                                kind: .exportedDeclarationChanged(
                                    path: file.path,
                                    line: row.headLine,
                                    snippet: snippet(row.text)
                                ),
                                path: file.path,
                                line: row.headLine
                            )
                        )
                    }
                }
                if isManifest(file), manifestLine(in: patch) {
                    dataOrDependency.append(
                        EvidenceFact(
                            kind: .manifestLineChanged(path: file.path),
                            path: file.path
                        )
                    )
                }
            }
            if isSchemaChange(file) {
                dataOrDependency.append(
                    EvidenceFact(
                        kind: .schemaChanged(path: file.path),
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
                    kind: isWorkflow(file)
                        ? .workflowChanged(path: file.path)
                        : .configurationChanged(path: file.path),
                    path: file.path
                )
            }
        facts.append(contentsOf: configuration)

        if !readAnyPatch {
            facts.append(EvidenceFact(kind: .noReadableDiff))
        } else if declarations.isEmpty {
            facts.append(EvidenceFact(kind: .noExportedDeclarationChanged))
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
    /// The reference itself is always a fact — it exists, and here is where it points. What can be
    /// said beyond that depends on whether the app fetched `#142`, and there are four answers:
    ///
    /// | Input | Facts | Status |
    /// | --- | --- | --- |
    /// | no issue | the reference, "acceptance criteria not checked", and why when there is a why | ? unclear |
    /// | the reference is a pull request | the reference, and that a pull request has no criteria | ? unclear |
    /// | an issue with no checklist | the reference, and that the body holds no list | ? unclear |
    /// | an issue with a checklist | the reference, the issue, the tally, one fact per bullet | ✓ when every bullet is mentioned, ? otherwise |
    ///
    /// **✗ is unreachable here, deliberately.** ``AcceptanceMatcher`` matches *words*: it can say
    /// that a pull request talks about a bullet, and it cannot say that a bullet was not done. A
    /// contradiction Shepherd cannot substantiate is the one thing ADR 0026 forbids, and an
    /// unmentioned bullet is exactly that — so the strongest thing this line does with one is
    /// leave the status at ? and name the bullet, which is the reviewer's cue to open the issue.
    ///
    /// **A ✓ still means less than the other three lines' ✓.** It means every bullet is mentioned
    /// somewhere in the description, the paths or the commit messages — not that the issue is
    /// resolved. The facts say which words matched, which is why the status is never on its own.
    private static func checkIssue(
        number: Int,
        in detail: PullRequestDetail,
        issue: IssueSummary?,
        matches: [AcceptanceMatch]?,
        failure: IssueLookupFailure?
    ) -> EvidenceVerdict {
        let repo = detail.summary.repo
        let url = issue?.url
            ?? URL(string: "https://github.com/\(repo.owner)/\(repo.name)/issues/\(number)")
        var facts: [EvidenceFact] = [
            EvidenceFact(
                kind: .issueReferenced(number: number, repo: repo.fullName),
                url: url
            )
        ]

        guard let issue else {
            facts.append(EvidenceFact(kind: .issueNotFetched))
            if let failure {
                facts.append(EvidenceFact(kind: .issueLookupFailed(failure)))
            }
            return EvidenceVerdict(status: .unclear, facts: facts)
        }

        if issue.isPullRequest {
            facts.append(EvidenceFact(kind: .referenceIsPullRequest(number: number)))
            return EvidenceVerdict(status: .unclear, facts: facts)
        }

        let bullets = matches ?? []
        guard !bullets.isEmpty else {
            facts.append(EvidenceFact(kind: .noAcceptanceChecklist))
            return EvidenceVerdict(status: .unclear, facts: facts)
        }

        facts.append(
            EvidenceFact(
                kind: .issueWithBullets(
                    number: issue.number,
                    title: issue.title,
                    state: issue.state,
                    bulletCount: bullets.count
                )
            )
        )
        let mentioned = bullets.filter(\.mentioned).count
        facts.append(
            EvidenceFact(
                kind: mentioned == bullets.count
                    ? .everyBulletMentioned
                    : .bulletsMentioned(mentioned: mentioned, total: bullets.count)
            )
        )
        for match in bullets {
            let mark: EvidenceFact.Mark = match.mentioned ? .mentioned : .notMentioned
            facts.append(
                EvidenceFact(
                    kind: .acceptanceBullet(text: match.bullet.text, reason: match.reason),
                    mark: mark
                )
            )
        }
        return EvidenceVerdict(
            status: mentioned == bullets.count ? .ok : .unclear,
            facts: facts
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
            return [EvidenceFact(kind: .noChecksConfigured)]
        }
        var facts: [EvidenceFact] = []
        switch rollup.state {
        case .success:
            facts.append(
                EvidenceFact(
                    kind: rollup.total > 0
                        ? .ciGreenCounted(passed: rollup.successCount, total: rollup.total)
                        : .ciGreen
                )
            )
        case .failure:
            facts.append(
                EvidenceFact(
                    kind: rollup.total > 0
                        ? .ciRedCounted(failed: rollup.failureCount, total: rollup.total)
                        : .ciRed
                )
            )
            let failing = checks.filter { $0.rollupContribution == .failure }
            for check in failing.prefix(namedCheckLimit) {
                facts.append(EvidenceFact(kind: .checkFailed(name: check.name)))
            }
        case .pending:
            let running = rollup.pendingCount
            facts.append(
                EvidenceFact(
                    kind: running == 0 ? .ciUnfinished : .ciUnfinishedRunning(count: running)
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
        let named = Array(ordered.sorted().prefix(namedPathLimit))
        return EvidenceFact(kind: .topLevelPaths(count: ordered.count, paths: named))
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
                    EvidenceFact(kind: .workflowChanged(path: file.path), path: file.path)
                )
            } else if FilePrioritizer.isLockfile(file) {
                guard lockfiles < namedFileLimit else { continue }
                lockfiles += 1
                facts.append(
                    EvidenceFact(kind: .lockfile(path: file.path), path: file.path)
                )
            } else if category == .generated {
                guard generated < namedFileLimit else { continue }
                generated += 1
                facts.append(
                    EvidenceFact(kind: .generatedFile(path: file.path), path: file.path)
                )
            } else if category == .config {
                guard configs < namedFileLimit else { continue }
                configs += 1
                facts.append(
                    EvidenceFact(kind: .configurationFile(path: file.path), path: file.path)
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

    private static func snippet(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > snippetLimit else { return trimmed }
        return String(trimmed.prefix(snippetLimit)) + "…"
    }
}
