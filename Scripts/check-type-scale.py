#!/usr/bin/env python3
"""Gate the surfaces that have adopted the type scale against fixed point sizes (ADR 0033).

Why this exists
---------------
`Font.system(size:)` is a fixed measurement and does not take part in macOS's Larger Text
setting, so a low-vision user's system preference has no effect on text spelled that way. The
remedy is `Theme.type(_:weight:)` / `Theme.mono(_:weight:)`, which name a *text style* and grow
when the user asks them to.

The migration is deliberately partial: a surface moves only when every size in it maps exactly
onto a macOS text style, so the change is the identity at the default size, and a surface that
pins a row height around `lineLimit(1)` is left alone on purpose (`docs/plans/accessibility.md`
§3). What that means is a boundary — and a boundary nobody checks erodes, because a new
`.font(.system(size: 12))` in a migrated file looks exactly like the code around it and compiles
without complaint. Then that surface grows unevenly under Larger Text, which is worse than not
growing at all.

So this lists the surfaces that have moved and fails if a fixed size reappears in one. Adding a
surface to the list is the second half of migrating it. Python 3 standard library only; it runs on
the Linux job, because that is where an agent working on this repo has no Xcode at all
(`docs/ARCHITECTURE.md` § Verification reality check).

Two things it has to get right, and the first one is why it does not just grep lines. A call that
outgrows the line length gets wrapped — `.font(\n    .system(\n        size: 12\n    )\n)` is an
ordinary thing for a formatter or a contributor to produce — and a per-line pattern walks straight
past it, which would make this gate a comfort rather than a check. So the search runs over the
whole file with a pattern that tolerates newlines. The second is that a fixed size *written about*
is not a fixed size used: the rule gets documented in comments, including in these very files, so
comments and string literals are blanked before the search rather than matched.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Surfaces on the type scale. Every one of these was migrated whole: no size in it was rounded,
# so it looks identical at the default text size and grows uniformly above it.
MIGRATED = (
    "Shepherd/Features/Settings/AutomationSettingsTab.swift",
    "Shepherd/Features/Settings/RepliesSettingsTab.swift",
    "Shepherd/Features/PullRequest/MergeSheet.swift",
    "Shepherd/Features/PullRequest/ClosingIssuesCard.swift",
    "Shepherd/Features/Inbox/BulkTriageSheet.swift",
    "Shepherd/Features/Inbox/IssueCommentSheet.swift",
)

# A fixed point size, either spelling: SwiftUI's own or `Theme.mono`'s numeric overload. `\s*`
# rather than a space at every join, so a wrapped call is caught as readily as a one-liner. A
# *parameterised* size (`.system(size: size)`) is deliberately not matched — the caller decides,
# and a caller in a migrated file has to pass something from the scale anyway.
FIXED = re.compile(r"\.\s*system\s*\(\s*size:\s*\d|Theme\s*\.\s*mono\s*\(\s*\d")


def without_comments_and_strings(source: str) -> str:
    """Blank out comments and string literals, keeping every newline so line numbers survive.

    Deliberately a small scanner rather than a regex: Swift block comments nest, and a `//`
    inside a string is not a comment. It does not know raw strings (`#"…"#`), which none of the
    listed surfaces uses; the cost of that gap is a false positive, which fails loudly rather
    than quietly, and quietly is the direction that matters here.
    """
    out: list[str] = []
    index, length, depth = 0, len(source), 0
    while index < length:
        character = source[index]
        pair = source[index:index + 2]
        if depth > 0:                                  # inside /* … */, which nests
            if pair == "/*":
                depth += 1
                out.append("  ")
                index += 2
            elif pair == "*/":
                depth -= 1
                out.append("  ")
                index += 2
            else:
                out.append("\n" if character == "\n" else " ")
                index += 1
        elif pair == "/*":
            depth = 1
            out.append("  ")
            index += 2
        elif pair == "//":
            while index < length and source[index] != "\n":
                out.append(" ")
                index += 1
        elif source[index:index + 3] == '"""':
            out.append("   ")
            index += 3
            while index < length and source[index:index + 3] != '"""':
                out.append("\n" if source[index] == "\n" else " ")
                index += 1
            out.append("   ")
            index += 3
        elif character == '"':
            out.append(" ")
            index += 1
            while index < length and source[index] != '"':
                if source[index] == "\\" and index + 1 < length:
                    out.append("  ")
                    index += 2
                    continue
                out.append("\n" if source[index] == "\n" else " ")
                index += 1
            out.append(" ")
            index += 1
        else:
            out.append(character)
            index += 1
    return "".join(out)


def main() -> int:
    findings: list[str] = []
    for name in MIGRATED:
        path = ROOT / name
        if not path.is_file():
            findings.append(f"{name}: listed as migrated but not on disk")
            continue
        source = path.read_text(encoding="utf-8")
        scanned = without_comments_and_strings(source)
        lines = source.splitlines()
        for match in FIXED.finditer(scanned):
            number = scanned.count("\n", 0, match.start()) + 1
            quoted = lines[number - 1].strip() if number <= len(lines) else ""
            findings.append(f"{name}:{number}: fixed point size — {quoted}")

    if findings:
        print("Fixed font sizes in surfaces that are on the type scale:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        print(
            "\nUse Theme.type(_:weight:) or Theme.mono(_:weight:) so the text grows with macOS's"
            "\nLarger Text setting. If the size has no exact text style behind it, that is a"
            "\nvisual decision rather than a mechanical one — see docs/plans/accessibility.md §3.",
            file=sys.stderr,
        )
        return 1

    print(f"Type scale OK: {len(MIGRATED)} surfaces carry no fixed font size.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
