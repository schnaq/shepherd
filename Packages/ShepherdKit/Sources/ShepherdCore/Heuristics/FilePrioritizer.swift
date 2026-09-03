import Foundation

/// The broad category a changed file falls into.
public enum FileCategory: String, Sendable, Codable, Hashable, CaseIterable {
    /// Hand-written production code.
    case source
    /// Test code.
    case tests
    /// Build, CI and tooling configuration.
    case config
    /// Documentation and prose.
    case docs
    /// Machine-generated or vendored content: lockfiles, bundles, snapshots, `vendor/`.
    case generated

    /// A short human-readable label used as the first review reason.
    public var reasonLabel: String {
        switch self {
        case .source: return "Source file"
        case .tests: return "Test file"
        case .config: return "Configuration"
        case .docs: return "Documentation"
        case .generated: return "Generated or vendored file"
        }
    }
}

/// Where a file lands in the review order.
public enum PriorityBucket: String, Sendable, Codable, Hashable, CaseIterable {
    /// Read this before anything else: risky, large or security-relevant.
    case reviewFirst
    /// Normal review material.
    case standard
    /// Worth a glance, unlikely to hide a bug.
    case skim
    /// Machine-generated; collapse by default.
    case generated

    /// A stable display order for section headers.
    public var sortIndex: Int {
        switch self {
        case .reviewFirst: return 0
        case .standard: return 1
        case .skim: return 2
        case .generated: return 3
        }
    }

    /// A human-readable section title.
    public var title: String {
        switch self {
        case .reviewFirst: return "Review first"
        case .standard: return "Standard"
        case .skim: return "Skim"
        case .generated: return "Generated"
        }
    }
}

/// A changed file together with its computed review priority.
public struct FilePriority: Sendable, Codable, Hashable, Identifiable {
    /// The file this priority describes.
    public var file: ChangedFile
    /// The computed score, clamped to `0...100`.
    public var score: Double
    /// The bucket the score falls into.
    public var bucket: PriorityBucket
    /// The detected category of the file.
    public var category: FileCategory
    /// Human-readable explanations, in the order they were applied. Shown in the UI.
    public var reasons: [String]

    /// Creates a file priority.
    public init(
        file: ChangedFile,
        score: Double,
        bucket: PriorityBucket,
        category: FileCategory,
        reasons: [String]
    ) {
        self.file = file
        self.score = score
        self.bucket = bucket
        self.category = category
        self.reasons = reasons
    }

    /// `FilePriority` is identified by the file path.
    public var id: String { file.path }
}

/// Pull-request-level context that lets the prioritiser reason about relative churn.
public struct PrioritizationContext: Sendable, Hashable {
    /// Total churn of the pull request. When `nil`, it is computed from the input files.
    public var totalChangedLines: Int?
    /// Extra lowercase substrings that mark a path as security-sensitive, from user settings.
    public var extraSecurityPathHints: [String]

    /// Creates a context.
    /// - Parameters:
    ///   - totalChangedLines: Total churn of the pull request, or `nil` to compute it.
    ///   - extraSecurityPathHints: Additional lowercase substrings marking sensitive paths.
    public init(totalChangedLines: Int? = nil, extraSecurityPathHints: [String] = []) {
        self.totalChangedLines = totalChangedLines
        self.extraSecurityPathHints = extraSecurityPathHints
    }

    /// The default context: churn derived from the input, no extra hints.
    public static let `default` = PrioritizationContext()
}

/// Deterministic, LLM-free review-priority ranking for the changed files of a pull request
/// (tier 1 of ADR 0007).
///
/// Scoring is a base score per ``FileCategory`` plus additive boosts, clamped to `0...100`.
/// Every boost contributes a human-readable reason, because the UI shows *why* a file was
/// ranked where it was — the heuristic has to be arguable, not magic.
///
/// | Signal | Effect |
/// | --- | --- |
/// | source / tests / config / docs / generated | base 60 / 40 / 35 / 15 / 3 |
/// | security-sensitive path (auth, crypto, secret, token, password, security) | +30 |
/// | CI workflow under `.github/workflows/` | +45 |
/// | `Dockerfile` / container build files | +25 |
/// | `*.entitlements` | +30 |
/// | deletes a test file | +40 |
/// | deletes a source file | +10 |
/// | churn ≥ 300 lines / ≥ 100 lines | +15 / +8 |
/// | file accounts for more than 40 % of the pull request's churn | +10 |
/// | new source file | +5 |
/// | no diff available (binary or truncated) | −10 |
public enum FilePrioritizer {
    // MARK: - Tunables

    /// Score thresholds separating the buckets.
    public enum Thresholds {
        /// Scores at or above this land in ``PriorityBucket/reviewFirst``.
        public static let reviewFirst: Double = 75
        /// Scores at or above this land in ``PriorityBucket/standard``.
        public static let standard: Double = 35
        /// Scores at or above this land in ``PriorityBucket/skim``.
        public static let skim: Double = 10
    }

    private static let baseScores: [FileCategory: Double] = [
        .source: 60,
        .tests: 40,
        .config: 35,
        .docs: 15,
        .generated: 3,
    ]

    /// Path substrings that mark a file as security-sensitive.
    public static let securityPathHints: [String] = [
        "auth", "crypto", "secret", "token", "password", "passwd", "security",
        "credential", "keychain", "oauth", "session", "permission", "sanitize",
    ]

    // MARK: - Public API

    /// Ranks the changed files of a pull request.
    ///
    /// The result is sorted by descending score; ties break on path so the order is stable
    /// across runs and across machines.
    /// - Parameters:
    ///   - files: The changed files.
    ///   - context: Pull-request-level context.
    /// - Returns: One ``FilePriority`` per input file, highest priority first.
    public static func prioritize(
        _ files: [ChangedFile],
        context: PrioritizationContext = .default
    ) -> [FilePriority] {
        let totalChurn = context.totalChangedLines
            ?? files.reduce(0) { $0 + $1.churn }
        let priorities = files.map { file in
            score(file, totalChurn: totalChurn, context: context)
        }
        return priorities.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.bucket.sortIndex != rhs.bucket.sortIndex {
                return lhs.bucket.sortIndex < rhs.bucket.sortIndex
            }
            return lhs.file.path < rhs.file.path
        }
    }

    /// Groups ranked files into their buckets, in display order.
    /// - Parameter priorities: The result of ``prioritize(_:context:)``.
    /// - Returns: Buckets in display order, each with its files in priority order. Empty
    ///   buckets are omitted.
    public static func bucketed(_ priorities: [FilePriority]) -> [(bucket: PriorityBucket, files: [FilePriority])] {
        PriorityBucket.allCases
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { bucket in
                let matching = priorities.filter { $0.bucket == bucket }
                return matching.isEmpty ? nil : (bucket, matching)
            }
    }

    /// Whether a file is a dependency lockfile.
    ///
    /// Public because "a lockfile changed" is a fact in its own right on the claims card
    /// (ADR 0026), which needs to name it separately from the generated-and-vendored bucket
    /// ``category(of:)`` folds it into. The set of names is the prioritiser's own, so the two
    /// surfaces cannot come to different conclusions about `Package.resolved`.
    /// - Parameter file: The changed file.
    /// - Returns: `true` for a known lockfile name or any `*.lock` file.
    public static func isLockfile(_ file: ChangedFile) -> Bool {
        let name = file.fileName.lowercased()
        return lockfileNames.contains(name) || name.hasSuffix(".lock")
    }

    /// Classifies a path into a broad category.
    /// - Parameter file: The changed file.
    /// - Returns: The detected category.
    public static func category(of file: ChangedFile) -> FileCategory {
        let lowercased = file.path.lowercased()
        if isGenerated(path: lowercased) { return .generated }
        if isTest(originalPath: file.path) { return .tests }
        if isDocs(path: lowercased) { return .docs }
        if isConfig(path: lowercased) { return .config }
        return .source
    }

    // MARK: - Scoring

    private static func score(
        _ file: ChangedFile,
        totalChurn: Int,
        context: PrioritizationContext
    ) -> FilePriority {
        let path = file.path.lowercased()
        let category = category(of: file)
        var score = baseScores[category] ?? 30
        var reasons: [String] = [category.reasonLabel]

        if category != .generated {
            let hints = securityPathHints + context.extraSecurityPathHints.map { $0.lowercased() }
            if let hit = hints.first(where: { !$0.isEmpty && path.contains($0) }) {
                score += 30
                reasons.append("Touches security-sensitive path (“\(hit)”)")
            }
        }

        if path.hasPrefix(".github/workflows/") || path.contains("/.github/workflows/") {
            score += 45
            reasons.append("Changes a CI workflow — supply-chain relevant")
        }

        if isContainerBuildFile(path: path) {
            score += 40
            reasons.append("Container build definition — supply-chain relevant")
        }

        if path.hasSuffix(".entitlements") {
            score += 30
            reasons.append("Changes app entitlements")
        }

        if file.status == .removed {
            if category == .tests {
                score += 40
                reasons.append("Deletes a test file")
            } else if category == .source {
                score += 10
                reasons.append("Deletes a source file")
            }
        }

        // Churn signals are meaningless for generated content — a regenerated lockfile is
        // always huge and always dominates the diff, and neither fact deserves attention.
        let churn = file.churn
        if category != .generated {
            if churn >= 300 {
                score += 15
                reasons.append("Large change (\(churn) lines)")
            } else if churn >= 100 {
                score += 8
                reasons.append("Sizeable change (\(churn) lines)")
            }

            if totalChurn > 0, churn > 0, Double(churn) / Double(totalChurn) > 0.4 {
                score += 10
                reasons.append("Dominates this pull request's changes")
            }
        }

        if file.status == .added, category == .source {
            score += 5
            reasons.append("New source file")
        }

        if file.status == .renamed, let previous = file.previousPath {
            reasons.append("Renamed from \(previous)")
        }

        if !file.hasPatch {
            score -= 10
            reasons.append("No diff available (binary or truncated)")
        }

        let clamped = min(100, max(0, score))
        return FilePriority(
            file: file,
            score: clamped,
            bucket: bucket(for: clamped),
            category: category,
            reasons: reasons
        )
    }

    private static func bucket(for score: Double) -> PriorityBucket {
        if score >= Thresholds.reviewFirst { return .reviewFirst }
        if score >= Thresholds.standard { return .standard }
        if score >= Thresholds.skim { return .skim }
        return .generated
    }

    // MARK: - Classification helpers

    private static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json",
        "cargo.lock", "go.sum", "gemfile.lock", "poetry.lock", "pipfile.lock",
        "composer.lock", "podfile.lock", "package.resolved", "flake.lock",
        "packages.lock.json", "uv.lock", "bun.lockb",
    ]

    private static let vendoredDirectoryComponents: Set<String> = [
        "vendor", "vendored", "third_party", "thirdparty", "node_modules", "dist", "build",
        "__snapshots__", "__generated__", "generated", ".yarn", "pods", "carthage",
        "externals", "bower_components",
    ]

    private static func isGenerated(path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if lockfileNames.contains(name) { return true }
        if name.hasSuffix(".lock") { return true }
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".min.mjs") {
            return true
        }
        if name.hasSuffix(".pb.go") || name.hasSuffix("_pb2.py") || name.hasSuffix(".pb.cc")
            || name.hasSuffix(".pb.h") {
            return true
        }
        if name.contains(".generated.") || name.hasSuffix(".g.dart") || name.hasSuffix(".gen.go") {
            return true
        }
        if name.hasSuffix(".snap") || name.hasSuffix(".ambr") { return true }
        if name == "xcode.xcworkspace" { return true }

        let components = path.split(separator: "/").map(String.init)
        // The last component is the file name; only directories mark vendored trees.
        for component in components.dropLast() where vendoredDirectoryComponents.contains(component) {
            return true
        }
        return false
    }

    /// Detects test files.
    ///
    /// Takes the **original-case** path on purpose: the file-name heuristics below match
    /// `FooTests.swift` and `TestFoo.cs` case-sensitively, so a source file called
    /// `Latest.swift` is not mistaken for a test.
    private static func isTest(originalPath: String) -> Bool {
        let components = originalPath.split(separator: "/").map(String.init)
        let name = components.last ?? originalPath
        for component in components.dropLast() {
            let lowered = component.lowercased()
            if lowered == "test" || lowered == "tests" || lowered == "__tests__"
                || lowered == "spec" || lowered == "specs" || lowered == "testing" {
                return true
            }
            if lowered.hasSuffix("tests") {
                // e.g. `ShepherdCoreTests/` (SwiftPM convention)
                return true
            }
        }
        let loweredName = name.lowercased()
        if loweredName.contains("_test.") || loweredName.hasPrefix("test_") { return true }
        if loweredName.contains(".spec.") || loweredName.contains(".test.") { return true }
        // `FooTests.swift`, `FooTest.java`, `TestFoo.cs` — case-sensitive on purpose.
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        if stem.hasSuffix("Test") || stem.hasSuffix("Tests") || stem.hasPrefix("Test") {
            return true
        }
        return false
    }

    private static func isDocs(path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? path
        if name.hasSuffix(".md") || name.hasSuffix(".markdown") || name.hasSuffix(".mdx")
            || name.hasSuffix(".rst") || name.hasSuffix(".adoc") || name.hasSuffix(".txt") {
            return true
        }
        for component in components.dropLast() where component == "docs" || component == "doc" {
            return true
        }
        return ["license", "notice", "authors", "changelog", "codeowners"].contains(name)
    }

    private static let configExtensions: Set<String> = [
        "yml", "yaml", "toml", "json", "ini", "cfg", "conf", "properties", "plist",
        "editorconfig", "gitignore", "gitattributes",
    ]

    private static func isConfig(path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? path
        if components.first == ".github" { return true }
        if name.hasPrefix(".") && configExtensions.contains(String(name.dropFirst())) {
            return true
        }
        let ext = name.split(separator: ".").last.map(String.init) ?? ""
        if configExtensions.contains(ext) {
            // Config files are only "config" near the root or in a config-ish directory;
            // a JSON fixture buried in a source tree is source material.
            if components.count == 1 { return true }
            if let first = components.first,
               ["config", "configs", "ci", ".ci", "scripts", "fastlane", "deploy"].contains(first) {
                return true
            }
            return components.count <= 2
        }
        if isContainerBuildFile(path: path) { return true }
        if ["makefile", "justfile", "rakefile", "brewfile", "procfile", "package.swift"]
            .contains(name) {
            return true
        }
        return false
    }

    private static func isContainerBuildFile(path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
            return true
        }
        return name == "docker-compose.yml" || name == "docker-compose.yaml"
            || name == "containerfile"
    }
}
