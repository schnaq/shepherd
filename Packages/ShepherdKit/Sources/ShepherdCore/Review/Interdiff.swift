import Foundation

/// One file that differs between the head a review was written against and the current head.
///
/// The interdiff is computed locally from two sets of ``ChangedFile`` — the snapshot taken when
/// the review was submitted and what the pull request holds now (ADR 0028). No GitHub compare
/// call is involved, so a force-push cannot take the baseline away.
public struct InterdiffFile: Sendable, Codable, Hashable, Identifiable {
    /// What happened to a file between the two rounds.
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        /// The file is part of the pull request's diff now and was not before.
        case added
        /// The file was part of the diff at review time and is not any more.
        case removed
        /// The file was renamed since the review.
        case renamed
        /// The file's head-side content changed between the rounds.
        case changed
    }

    /// The path in the *current* round (for ``Kind/removed`` the path at review time).
    public var path: String
    /// The path in the round that was reviewed, when it differs from ``path``.
    public var previousPath: String?
    /// What happened to the file.
    public var kind: Kind
    /// The hunks that differ between the rounds, in order.
    public var hunks: [InterdiffHunk]
    /// A synthesized unified diff of reviewed-head vs current-head.
    ///
    /// Written in GitHub's own shape so the Monaco viewer can render it through the existing
    /// `loadFile` path with no new bridge message: the viewer is handed a ``ChangedFile`` whose
    /// `patch` is this string (see ``changedFile(isViewed:)``).
    public var unifiedPatch: String

    /// Creates an interdiff file.
    /// - Parameters:
    ///   - path: The current path.
    ///   - previousPath: The path at review time, for a rename.
    ///   - kind: What happened.
    ///   - hunks: The differing hunks.
    ///   - unifiedPatch: The synthesized patch.
    public init(
        path: String,
        previousPath: String? = nil,
        kind: Kind,
        hunks: [InterdiffHunk],
        unifiedPatch: String
    ) {
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.hunks = hunks
        self.unifiedPatch = unifiedPatch
    }

    /// `InterdiffFile` is identified by its ``path``.
    public var id: String { path }

    /// How many lines the current round added relative to the reviewed one.
    public var addedLineCount: Int {
        hunks.reduce(0) { $0 + $1.addedCurrentLines.count }
    }

    /// How many lines the current round removed relative to the reviewed one.
    public var removedLineCount: Int {
        hunks.reduce(0) { $0 + $1.removedReviewedLines.count }
    }

    /// Whether a current-side line is one the new round touched.
    ///
    /// True for a line the round added, and for the line a deletion collapsed onto — the anchor
    /// of a finding whose lines were deleted outright.
    /// - Parameter line: A 1-based line number in the current head.
    public func touchesCurrentLine(_ line: Int) -> Bool {
        hunks.contains {
            $0.addedCurrentLines.contains(line) || $0.removalAnchorsOnCurrentSide.contains(line)
        }
    }

    /// Whether a reviewed-side line is one the new round touched.
    /// - Parameter line: A 1-based line number in the head that was reviewed.
    public func touchesReviewedLine(_ line: Int) -> Bool {
        hunks.contains {
            $0.removedReviewedLines.contains(line)
                || $0.insertionAnchorsOnReviewedSide.contains(line)
        }
    }

    /// The net number of lines the new round inserted above a current-side line.
    ///
    /// Zero when nothing above the line moved; non-zero is what "the hunk shifted" means for a
    /// finding whose own lines were left alone. Hunks entirely above the line contribute their
    /// whole balance, and the hunk the line sits *inside* contributes only the part of itself
    /// that is above it — a change three lines up is a shift even though the reviewer's line is
    /// in the same hunk as context.
    /// - Parameter line: A 1-based line number in the current head.
    public func shift(aboveCurrentLine line: Int) -> Int {
        var delta = 0
        for hunk in hunks {
            if hunk.currentStart + max(0, hunk.currentCount) <= line {
                delta += hunk.currentCount - hunk.reviewedCount
            } else if hunk.currentStart <= line {
                delta += hunk.delta(beforeCurrentLine: line)
                break
            } else {
                break
            }
        }
        return delta
    }

    /// The net number of lines the new round inserted above a reviewed-side line.
    ///
    /// The mirror of ``shift(aboveCurrentLine:)`` for a thread whose only usable anchor is the
    /// line it was written against (an outdated thread).
    /// - Parameter line: A 1-based line number in the head that was reviewed.
    public func shift(aboveReviewedLine line: Int) -> Int {
        var delta = 0
        for hunk in hunks {
            if hunk.reviewedStart + max(0, hunk.reviewedCount) <= line {
                delta += hunk.currentCount - hunk.reviewedCount
            } else if hunk.reviewedStart <= line {
                delta += hunk.delta(beforeReviewedLine: line)
                break
            } else {
                break
            }
        }
        return delta
    }

    /// The file as the diff viewer wants it: a changed file whose patch is the synthesized diff.
    ///
    /// The viewer already takes this shape, which is the whole point of synthesizing a unified
    /// diff rather than inventing a second rendering path.
    /// - Parameter isViewed: Carried through for the file list's tick.
    /// - Returns: A changed file describing the round rather than the pull request.
    public func changedFile(isViewed: Bool = false) -> ChangedFile {
        let status: FileChangeStatus
        switch kind {
        case .added: status = .added
        case .removed: status = .removed
        case .renamed: status = .renamed
        case .changed: status = .modified
        }
        return ChangedFile(
            path: path,
            previousPath: previousPath,
            status: status,
            additions: addedLineCount,
            deletions: removedLineCount,
            patch: unifiedPatch.isEmpty ? nil : unifiedPatch,
            isViewed: isViewed
        )
    }
}

/// One hunk of an ``InterdiffFile``.
///
/// Line numbers are absolute on both sides: the two documents being compared are the head-side
/// reconstructions of the two rounds' patches, which ``UnifiedPatch/reconstruct(after:)`` pads
/// so that 1-based indices match GitHub's numbering. That is what lets a review thread's anchor
/// be looked up here without a second mapping step.
public struct InterdiffHunk: Sendable, Codable, Hashable {
    /// First line of the hunk in the head that was reviewed (`0` when that side is empty).
    public var reviewedStart: Int
    /// How many reviewed-side lines the hunk covers.
    public var reviewedCount: Int
    /// First line of the hunk in the current head (`0` when that side is empty).
    public var currentStart: Int
    /// How many current-side lines the hunk covers.
    public var currentCount: Int
    /// The body lines, each with its `" "`, `"-"` or `"+"` marker.
    public var lines: [String]

    /// Creates a hunk.
    /// - Parameters:
    ///   - reviewedStart: First reviewed-side line.
    ///   - reviewedCount: Reviewed-side line count.
    ///   - currentStart: First current-side line.
    ///   - currentCount: Current-side line count.
    ///   - lines: Body lines with markers.
    public init(
        reviewedStart: Int,
        reviewedCount: Int,
        currentStart: Int,
        currentCount: Int,
        lines: [String]
    ) {
        self.reviewedStart = reviewedStart
        self.reviewedCount = reviewedCount
        self.currentStart = currentStart
        self.currentCount = currentCount
        self.lines = lines
    }

    /// The `@@ -a,b +c,d @@` header of this hunk.
    public var header: String {
        UnifiedPatch.writeHeader(
            originalStart: reviewedStart,
            originalCount: reviewedCount,
            modifiedStart: currentStart,
            modifiedCount: currentCount
        )
    }

    /// The current-side lines this hunk adds.
    public var addedCurrentLines: Set<Int> { walk().added }
    /// The reviewed-side lines this hunk removes.
    public var removedReviewedLines: Set<Int> { walk().removed }
    /// The current-side line each removed block collapsed onto.
    public var removalAnchorsOnCurrentSide: Set<Int> { walk().removalAnchors }
    /// The reviewed-side line each added block was inserted at.
    public var insertionAnchorsOnReviewedSide: Set<Int> { walk().insertionAnchors }

    /// The net line balance of the part of this hunk that lies above a current-side line.
    /// - Parameter line: A 1-based current-side line number inside this hunk.
    /// - Returns: Lines added minus lines removed before that line.
    func delta(beforeCurrentLine line: Int) -> Int {
        var currentLine = max(1, currentStart)
        var delta = 0
        for body in lines {
            // An entirely empty body line is an unchanged empty line, the same reading
            // `PatchReconstructor` gives it.
            switch body.first ?? " " {
            case "+":
                if currentLine >= line { return delta }
                delta += 1
                currentLine += 1
            case "-":
                delta -= 1
            default:
                if currentLine >= line { return delta }
                currentLine += 1
            }
        }
        return delta
    }

    /// The net line balance of the part of this hunk that lies above a reviewed-side line.
    /// - Parameter line: A 1-based reviewed-side line number inside this hunk.
    /// - Returns: Lines added minus lines removed before that line.
    func delta(beforeReviewedLine line: Int) -> Int {
        var reviewedLine = max(1, reviewedStart)
        var delta = 0
        for body in lines {
            switch body.first ?? " " {
            case "+":
                delta += 1
            case "-":
                if reviewedLine >= line { return delta }
                delta -= 1
                reviewedLine += 1
            default:
                if reviewedLine >= line { return delta }
                reviewedLine += 1
            }
        }
        return delta
    }

    /// Walks the body once, numbering both sides.
    private func walk() -> (
        added: Set<Int>,
        removed: Set<Int>,
        removalAnchors: Set<Int>,
        insertionAnchors: Set<Int>
    ) {
        var added: Set<Int> = []
        var removed: Set<Int> = []
        var removalAnchors: Set<Int> = []
        var insertionAnchors: Set<Int> = []
        var reviewedLine = max(1, reviewedStart)
        var currentLine = max(1, currentStart)
        for line in lines {
            switch line.first ?? " " {
            case "+":
                added.insert(currentLine)
                insertionAnchors.insert(reviewedLine)
                currentLine += 1
            case "-":
                removed.insert(reviewedLine)
                removalAnchors.insert(currentLine)
                reviewedLine += 1
            default:
                reviewedLine += 1
                currentLine += 1
            }
        }
        return (added, removed, removalAnchors, insertionAnchors)
    }
}

/// Computes what changed between the head a review was written against and the current head.
///
/// Everything here is pure and Linux-testable. The inputs are the two rounds' ``ChangedFile``
/// lists — the snapshot's and the pull request's — and nothing else; in particular there is no
/// GitHub call, because the snapshot is local (ADR 0028).
public enum Interdiff {
    /// How many context lines a synthesized hunk carries. GitHub's own default.
    public static let contextLines = 3

    /// The largest line-count product the line diff runs its LCS table over.
    ///
    /// Beyond it the two versions of the file are reported as one replacing hunk rather than
    /// diffed line by line: the table is quadratic, and a reviewer reading a fix round is
    /// better served by "this whole region changed" than by a stalled window. Reached only by
    /// pathological files — the documents being compared are patch reconstructions, so they are
    /// as long as the file but sparse.
    static let maximumDiffCells = 4_000_000

    /// Diffs two rounds of a pull request's changed files.
    /// - Parameters:
    ///   - before: The files as they were when the review was submitted.
    ///   - after: The files as they are now.
    /// - Returns: One entry per file that differs, in the current round's order (files only the
    ///   reviewed round had come last). Files identical across the rounds are omitted.
    public static func compute(before: [ChangedFile], after: [ChangedFile]) -> [InterdiffFile] {
        var reviewedByPath: [String: ChangedFile] = [:]
        for file in before { reviewedByPath[file.path] = file }

        var result: [InterdiffFile] = []
        var consumed: Set<String> = []

        for file in after {
            let renamedFrom = file.status == .renamed ? file.previousPath : nil
            let counterpart: ChangedFile?
            let kind: InterdiffFile.Kind
            if let renamedFrom, let previous = reviewedByPath[renamedFrom] {
                counterpart = previous
                kind = .renamed
                consumed.insert(renamedFrom)
            } else if let previous = reviewedByPath[file.path] {
                counterpart = previous
                kind = .changed
                consumed.insert(file.path)
            } else {
                counterpart = nil
                kind = .added
            }

            let reviewedLines = UnifiedPatch.reconstruct(after: counterpart?.patch)
            let currentLines = UnifiedPatch.reconstruct(after: file.patch)
            let hunks = self.hunks(reviewed: reviewedLines, current: currentLines)
            // A rename with no content change is still worth listing — the finding anchored to
            // the old path is "moved", and the reviewer has to be able to see where to.
            guard !hunks.isEmpty || kind == .renamed else { continue }
            result.append(
                InterdiffFile(
                    path: file.path,
                    previousPath: kind == .renamed ? renamedFrom : nil,
                    kind: kind,
                    hunks: hunks,
                    unifiedPatch: patch(from: hunks)
                )
            )
        }

        for file in before where !consumed.contains(file.path) {
            let reviewedLines = UnifiedPatch.reconstruct(after: file.patch)
            let hunks = self.hunks(reviewed: reviewedLines, current: [])
            guard !hunks.isEmpty else { continue }
            result.append(
                InterdiffFile(
                    path: file.path,
                    previousPath: nil,
                    kind: .removed,
                    hunks: hunks,
                    unifiedPatch: patch(from: hunks)
                )
            )
        }

        return result
    }

    /// Renders hunks as one unified patch, in GitHub's `files[].patch` shape.
    /// - Parameter hunks: The hunks to write.
    /// - Returns: The patch text, or `""` when there are no hunks.
    public static func patch(from hunks: [InterdiffHunk]) -> String {
        guard !hunks.isEmpty else { return "" }
        var lines: [String] = []
        for hunk in hunks {
            lines.append(hunk.header)
            lines.append(contentsOf: hunk.lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - The line diff

    /// One step of the edit script between the two documents.
    struct Step: Sendable, Hashable {
        /// What the step does.
        enum Kind: Sendable, Hashable {
            /// The line is in both documents.
            case equal
            /// The line was in the reviewed round only.
            case remove
            /// The line is in the current round only.
            case insert
        }

        var kind: Kind
        /// 0-based index into the reviewed document, for `equal` and `remove`.
        var reviewedIndex: Int?
        /// 0-based index into the current document, for `equal` and `insert`.
        var currentIndex: Int?
    }

    /// Diffs two documents into hunks with ``contextLines`` lines of context.
    /// - Parameters:
    ///   - reviewed: The head-side lines of the reviewed round.
    ///   - current: The head-side lines of the current round.
    /// - Returns: The hunks, in order. Empty when the documents are identical.
    static func hunks(reviewed: [String], current: [String]) -> [InterdiffHunk] {
        let steps = script(reviewed: reviewed, current: current)
        return group(steps, reviewed: reviewed, current: current)
    }

    /// The edit script: common prefix and suffix by scanning, the middle by LCS.
    static func script(reviewed: [String], current: [String]) -> [Step] {
        var prefix = 0
        while prefix < reviewed.count, prefix < current.count,
              reviewed[prefix] == current[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < reviewed.count - prefix, suffix < current.count - prefix,
              reviewed[reviewed.count - 1 - suffix] == current[current.count - 1 - suffix] {
            suffix += 1
        }

        var steps: [Step] = []
        steps.reserveCapacity(max(reviewed.count, current.count))
        for index in 0..<prefix {
            steps.append(Step(kind: .equal, reviewedIndex: index, currentIndex: index))
        }

        let left = Array(reviewed[prefix..<(reviewed.count - suffix)])
        let right = Array(current[prefix..<(current.count - suffix)])
        for step in middle(left, right) {
            steps.append(
                Step(
                    kind: step.kind,
                    reviewedIndex: step.reviewedIndex.map { $0 + prefix },
                    currentIndex: step.currentIndex.map { $0 + prefix }
                )
            )
        }

        for offset in 0..<suffix {
            steps.append(
                Step(
                    kind: .equal,
                    reviewedIndex: reviewed.count - suffix + offset,
                    currentIndex: current.count - suffix + offset
                )
            )
        }
        return steps
    }

    /// The edit script of the differing middle, by longest common subsequence.
    private static func middle(_ left: [String], _ right: [String]) -> [Step] {
        if left.isEmpty || right.isEmpty
            || left.count * right.count > maximumDiffCells {
            // Nothing in common to find, or too large to be worth a table: one replacement.
            return left.indices.map { Step(kind: .remove, reviewedIndex: $0, currentIndex: nil) }
                + right.indices.map { Step(kind: .insert, reviewedIndex: nil, currentIndex: $0) }
        }

        let width = right.count + 1
        var table = [Int](repeating: 0, count: (left.count + 1) * width)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                table[i * width + j] = left[i] == right[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }

        var steps: [Step] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                steps.append(Step(kind: .equal, reviewedIndex: i, currentIndex: j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                steps.append(Step(kind: .remove, reviewedIndex: i, currentIndex: nil))
                i += 1
            } else {
                steps.append(Step(kind: .insert, reviewedIndex: nil, currentIndex: j))
                j += 1
            }
        }
        while i < left.count {
            steps.append(Step(kind: .remove, reviewedIndex: i, currentIndex: nil))
            i += 1
        }
        while j < right.count {
            steps.append(Step(kind: .insert, reviewedIndex: nil, currentIndex: j))
            j += 1
        }
        return steps
    }

    /// Groups an edit script into hunks, padding each with context lines.
    private static func group(
        _ steps: [Step],
        reviewed: [String],
        current: [String]
    ) -> [InterdiffHunk] {
        let changes = steps.indices.filter { steps[$0].kind != .equal }
        guard !changes.isEmpty else { return [] }

        var ranges: [(start: Int, end: Int)] = []
        var start = changes[0]
        var end = changes[0]
        for index in changes.dropFirst() {
            // Two changes closer together than twice the context share a hunk, which is what
            // keeps the synthesized patch readable rather than a run of one-line hunks.
            if index - end <= contextLines * 2 {
                end = index
            } else {
                ranges.append((start: start, end: end))
                start = index
                end = index
            }
        }
        ranges.append((start: start, end: end))

        return ranges.map { range in
            let lower = max(0, range.start - contextLines)
            let upper = min(steps.count - 1, range.end + contextLines)
            var lines: [String] = []
            var reviewedStart = 0
            var reviewedCount = 0
            var currentStart = 0
            var currentCount = 0
            for step in steps[lower...upper] {
                switch step.kind {
                case .equal:
                    if let index = step.reviewedIndex {
                        if reviewedCount == 0 { reviewedStart = index + 1 }
                        reviewedCount += 1
                        lines.append(" " + reviewed[index])
                    }
                    if let index = step.currentIndex {
                        if currentCount == 0 { currentStart = index + 1 }
                        currentCount += 1
                    }
                case .remove:
                    if let index = step.reviewedIndex {
                        if reviewedCount == 0 { reviewedStart = index + 1 }
                        reviewedCount += 1
                        lines.append("-" + reviewed[index])
                    }
                case .insert:
                    if let index = step.currentIndex {
                        if currentCount == 0 { currentStart = index + 1 }
                        currentCount += 1
                        lines.append("+" + current[index])
                    }
                }
            }
            return InterdiffHunk(
                reviewedStart: reviewedStart,
                reviewedCount: reviewedCount,
                currentStart: currentStart,
                currentCount: currentCount,
                lines: lines
            )
        }
    }
}
