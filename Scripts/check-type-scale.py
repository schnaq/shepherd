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

# A fixed point size, either spelling: SwiftUI's own or `Theme.mono`'s numeric overload. A
# parameterised size (`.system(size: size)`) is not one — the caller decides, and a caller in a
# migrated file has to pass something from the scale anyway.
FIXED = re.compile(r"\.system\(size:\s*\d|Theme\.mono\(\s*\d")


def main() -> int:
    findings: list[str] = []
    for name in MIGRATED:
        path = ROOT / name
        if not path.is_file():
            findings.append(f"{name}: listed as migrated but not on disk")
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if FIXED.search(line):
                findings.append(f"{name}:{number}: fixed point size — {line.strip()}")

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
