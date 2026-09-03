#!/usr/bin/env python3
"""Gate the String Catalog against the app's source, without Xcode (ADR 0022).

Why this exists at all
----------------------
Xcode derives the keys of ``Shepherd/Resources/Localizable.xcstrings`` from the source at build
time: every ``String(localized: "…")`` and every SwiftUI ``Text("…")``-shaped literal becomes a
key, and a key the catalog does not carry falls back to the English source string *silently*.
There is no warning, no build failure and nothing in the app that looks wrong — a German user
simply reads an English sentence. That is the failure mode this script exists to make loud, and it
has to be catchable on a Linux runner, because that is where two of the four CI jobs run and it is
where an agent working on this repo has no Xcode at all (``docs/ARCHITECTURE.md`` § Verification
reality check).

So this is a *reimplementation of Xcode's extraction*, in Python 3 with nothing but the standard
library, deliberately conservative:

* It parses Swift string literals properly — single-line and ``\"\"\"`` multi-line, escapes,
  ``\\`` line continuations, nested literals inside interpolations — rather than pattern-matching
  quotes, because a wrong key here is worse than no check: it would demand a catalog entry Xcode
  never asks for.
* It tracks comments and string interiors while scanning, so a ``Text("…")`` written in a doc
  comment or quoted inside another literal is not mistaken for a call site.
* Interpolations become format specifiers by *type*, and the type table below is hand-verified
  against the declarations rather than guessed from the expression's spelling. The heuristics only
  cover the shapes that cannot be anything else (``Int(…)``, ``….count``, integer arithmetic).

What it reports (any finding is a non-zero exit)
------------------------------------------------
1. a key in the source that the catalog does not have — the silent-English case above;
2. a catalog entry with no German value, or an empty one;
3. a German value whose ``%`` specifiers differ from the key's, in count, order or type — at best
   a wrong number in the UI, at worst a crash inside ``String(format:)``;
4. a catalog key no call site produces any more (stale), which is how a catalog rots.

Run it from anywhere: ``python3 Scripts/check-localization.py``.
"""

from __future__ import annotations

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(REPO_ROOT, "Shepherd")
#: The one catalog this script gates, by path rather than by glob. Its sibling
#: ``Shepherd/Resources/AppShortcuts.xcstrings`` (ADR 0022 § Amendment) is deliberately not
#: checked here and must not be: its keys are Siri phrases the App Intents metadata processor
#: extracts from ``ShepherdShortcuts``, not ``String(localized:)`` call sites, so every check
#: below — "the source produces this key", "no call site produces it any more" — would be a
#: check against the wrong source of truth and would fail on a correct file.
CATALOG_PATH = os.path.join(REPO_ROOT, "Shepherd", "Resources", "Localizable.xcstrings")

#: Directories under ``Shepherd/`` that hold no Swift source. ``Resources`` carries the built web
#: bundle (ADR 0003), which is a megabyte of minified JavaScript full of quotes.
SKIPPED_DIRECTORIES = {"Resources", "Assets.xcassets"}

#: The language every entry must carry. One language, because German is the first and only added
#: one (ADR 0022); a second would be another element here and nothing else.
REQUIRED_LANGUAGE = "de"

# ---------------------------------------------------------------------------------------------
# Call sites
# ---------------------------------------------------------------------------------------------

#: The SwiftUI initialisers whose *first* argument is a `LocalizedStringKey` and is looked up in
#: the same catalog. Only the first argument is a key, which is exactly why `systemImage:` labels
#: and `Image(systemName:)` are not a special case here: they are never the literal that follows
#: the opening parenthesis, so the scanner below never offers them.
SWIFTUI_INITIALISERS = ("Text", "Label", "Button", "Toggle", "Section", "Picker", "TextField")

#: The AppIntents shapes whose literal is a `LocalizedStringResource` looked up in the same catalog
#: (ADR 0021, 0022): an intent's `title`, `@Parameter`/`@Property` titles, enum and entity display
#: names, App Shortcut short titles, and the spoken `IntentDialog`. These literals must stay
#: literals — the App Intents metadata processor reads them at build time — so the catalog has to
#: be taught to find them where they are rather than the code being bent towards `String(localized:)`.
APP_INTENTS_TAILS = (
    r"LocalizedStringResource\s*\{\s*",
    r"LocalizedStringResource\(\s*",
    r"IntentDialog\(\s*",
    r"TypeDisplayRepresentation\(\s*name:\s*",
    r"DisplayRepresentation\(\s*title:\s*",
    r"\bsubtitle:\s*",
    r"@(?:Parameter|Property)\(\s*title:\s*",
    r"\bshortTitle:\s*",
    r"\bdialog:\s*",
)

#: Matches the code immediately in front of a string literal when that literal is a catalog key.
#: Anchored at the end, so it is applied to the accumulated *code* text (comments already
#: dropped) right before the quote — which is what makes a call split over several lines work.
CALL_SITE_TAIL = re.compile(
    r"(?:String\(\s*localized:\s*|\b(?:"
    + "|".join(SWIFTUI_INITIALISERS)
    + r")\(\s*|"
    + "|".join(APP_INTENTS_TAILS)
    + r")$"
)

# ---------------------------------------------------------------------------------------------
# Interpolation types
# ---------------------------------------------------------------------------------------------

#: Every interpolated expression in the app whose static type is `Int`, checked one by one against
#: its declaration. `Int` interpolates as `%lld`; everything not listed here is a `String` and
#: interpolates as `%@`. There is no `Double`/`CGFloat` site in the app: the two places that hold a
#: floating-point setting (`diffFontSize`, `sweepIntervalMinutes`) wrap it in `Int(…)` first.
INTEGER_EXPRESSIONS = frozenset(
    {
        "additions",
        "checks.count - 6",
        "configuration.maxChangedLines",
        "configuration.maxFiles",
        "configuration.maxTurns",
        "conflict.number",
        "context.number",
        "count",
        "deletions",
        "diagnosticsReportCount",
        "DiagnosticsStore.retentionLimit",
        "entries.count",
        "entry.checkCount",
        "environment.autoDelegation.dailyCap",
        "environment.autoDelegation.runningCount",
        "environment.autoDelegation.startsToday",
        "environment.trackRecord.storedOutcomeCount",
        "facet.classifiedCount",
        "facets.count - 6",
        "facets.hiddenCount",
        "failedCount",
        "insideCount",
        "iterations",
        "limit",
        "line",
        "list.count",
        "mentionedCount",
        "minimum",
        "minutes",
        "minutes % 60",
        "minutes / 60",
        "model.filteredRows.count",
        "model.markedIDs.count",
        "model.pendingCommentCount",
        "models.count",
        "number",
        "original",
        "outcome.failed.count",
        "outcome.secretsWritten",
        "outcome.skipped",
        "overflow",
        "parked",
        "passedCount",
        "pending.secretCount",
        "pendingReviewCount",
        "plan.eligible.count",
        "plan.skipped.count",
        "presentCount",
        "progress.estimatedTotal",
        "progress.repositoryCount",
        "progress.repositoryIndex",
        "progress.stored",
        "queued",
        "quickInbox.total",
        "record.closedUnmerged",
        "record.merged",
        "record.reverted",
        "reference.number",
        "remainder",
        "remaining",
        "request.line",
        "result.coveredCount",
        "result.revertsLinked",
        "result.stored",
        "result.summary.number",
        "result.totalCount",
        "reviewed",
        "rollup.failureCount",
        "rollup.pendingCount",
        "rollup.successCount",
        "rollup.total",
        "roundCount",
        "row.commentCount",
        "row.labels.count - IssueRowView.visibleLabelCount",
        "row.number",
        "rules.concurrencyCap",
        "rules.dailyCap",
        "running.remaining",
        "running.total",
        "section.count",
        "session.conflictedOutboxCount",
        "session.pendingOutboxCount",
        "session.position",
        "session.remaining",
        "session.total",
        "skipped",
        "status",
        "status.changedPaths.count",
        "status.classifiedCount",
        "status.documentCount",
        "status.embeddedCount",
        "status.issueDocumentCount",
        "status.issueEmbeddedCount",
        "status.itemCount",
        "status.rowCount",
        "summary.changedFiles",
        "tokens",
        "total",
        "unchangedFindingCount",
        "value.wrappedValue",
        "vanished",
        "vanished.count",
        "version",
        "waiting",
    }
)

#: The one expression whose name collides with an `Int` of the same spelling in the same file.
#: `SettingsSyncError` binds `status` twice: `remoteRejected(status: Int, message: String)` and
#: `keyDerivationFailed(Int32)`. `Int32` is a 32-bit `%d`, not `%lld`, so the two cannot share a
#: row in the table above; the key text disambiguates them, and it is stable in a way a line
#: number is not.
SPECIFIER_OVERRIDES = {
    (
        "Shepherd/SettingsSync/SettingsSyncError.swift",
        "The passphrase could not be turned into a key (status {status}).",
    ): {"status": "%d"},
}

#: `Int(…)` at the top level of the expression. Nothing else in Swift spells a conversion to `Int`.
INT_CONVERSION = re.compile(r"^Int\(.*\)$")

#: `foo.count`, and `foo.count - 6`-style integer arithmetic over it.
COUNT_EXPRESSION = re.compile(r"^[A-Za-z_][\w.]*\.count(?:\s*[-+*/%]\s*\d[\d_]*)?$")


def specifier(expression: str, path: str, raw_key: str) -> str:
    """The format specifier Xcode writes for one interpolation.

    - Parameters:
      - expression: The Swift source of the interpolated expression, verbatim.
      - path: The file's repository-relative path, for the override table.
      - raw_key: The literal with every interpolation rendered as ``{expression}``, so a site can
        be named without depending on a line number.
    """
    override = SPECIFIER_OVERRIDES.get((path, raw_key))
    if override and expression in override:
        return override[expression]
    if expression in INTEGER_EXPRESSIONS:
        return "%lld"
    if INT_CONVERSION.match(expression):
        return "%lld"
    if COUNT_EXPRESSION.match(expression):
        return "%lld"
    return "%@"


# ---------------------------------------------------------------------------------------------
# A very small Swift literal reader
# ---------------------------------------------------------------------------------------------


class ParseError(Exception):
    """A literal this reader does not understand — reported rather than guessed at."""


#: The escapes Swift string literals allow. `\(` is interpolation and handled separately, `\u{…}`
#: has its own branch, and a `\` before a newline in a multi-line literal is a line continuation.
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}

UNICODE_ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]{1,8})\}")


def read_literal(text: str, index: int) -> tuple[list[tuple[str, str]], int]:
    """Reads the string literal that starts at ``index``.

    Returns the literal as a list of ``("text", …)`` and ``("interpolation", …)`` segments plus
    the index just past the closing delimiter.
    """
    if text.startswith('"""', index):
        return _read_multiline(text, index)
    return _read_single_line(text, index)


def _read_interpolation(text: str, index: int) -> tuple[str, int]:
    """Reads an interpolation's expression. ``index`` points just past the ``\\(``.

    Brackets are balanced and nested string literals are read with the full reader, so
    ``\\(a.map { "\\(b)" })`` cannot end the expression early on its inner quote.
    """
    depth = 1
    start = index
    while index < len(text):
        character = text[index]
        if character == '"':
            _, index = read_literal(text, index)
            continue
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
            if depth == 0:
                return text[start:index], index + 1
        index += 1
    raise ParseError("unterminated interpolation")


def _read_escapes(body: str, allow_line_continuation: bool) -> list[tuple[str, str]]:
    """Turns literal *content* into segments, resolving escapes and interpolations."""
    segments: list[tuple[str, str]] = []
    buffer: list[str] = []
    index = 0
    while index < len(body):
        character = body[index]
        if character != "\\":
            buffer.append(character)
            index += 1
            continue
        following = body[index + 1] if index + 1 < len(body) else ""
        if following == "(":
            if buffer:
                segments.append(("text", "".join(buffer)))
                buffer = []
            expression, index = _read_interpolation(body, index + 2)
            segments.append(("interpolation", expression.strip()))
            continue
        if following == "\n" and allow_line_continuation:
            index += 2
            continue
        if following == "u":
            match = UNICODE_ESCAPE.match(body, index)
            if match is None:
                raise ParseError("malformed \\u{…} escape")
            buffer.append(chr(int(match.group(1), 16)))
            index = match.end()
            continue
        if following in ESCAPES:
            buffer.append(ESCAPES[following])
            index += 2
            continue
        raise ParseError("unknown escape \\%s" % following)
    if buffer:
        segments.append(("text", "".join(buffer)))
    return segments


def _read_single_line(text: str, index: int) -> tuple[list[tuple[str, str]], int]:
    """Reads a ``"…"`` literal by finding its unescaped closing quote, then decoding the middle."""
    start = index + 1
    scan = start
    while scan < len(text):
        character = text[scan]
        if character == "\\":
            following = text[scan + 1] if scan + 1 < len(text) else ""
            if following == "(":
                _, scan = _read_interpolation(text, scan + 2)
                continue
            scan += 2
            continue
        if character == '"':
            return _read_escapes(text[start:scan], allow_line_continuation=False), scan + 1
        if character == "\n":
            raise ParseError("newline inside a single-line literal")
        scan += 1
    raise ParseError("unterminated literal")


CLOSING_MULTILINE = re.compile(r'^([ \t]*)"""', re.MULTILINE)


def _read_multiline(text: str, index: int) -> tuple[list[tuple[str, str]], int]:
    """Reads a ``\"\"\"…\"\"\"`` literal, including Swift's indentation stripping.

    Swift takes the indentation of the *closing* delimiter off every line, and a trailing ``\\``
    joins a line to the next one without a newline. Both matter for the key: the whole point of
    the multi-line form in this app is a long sentence written over several source lines that is
    *one* line of text at runtime.
    """
    cursor = index + 3
    while cursor < len(text) and text[cursor] in " \t":
        cursor += 1
    if cursor >= len(text) or text[cursor] != "\n":
        raise ParseError('content on the opening """ line')
    body_start = cursor + 1
    match = CLOSING_MULTILINE.search(text, body_start)
    if match is None:
        raise ParseError("unterminated multi-line literal")
    indent = match.group(1)
    lines = text[body_start : match.start()].split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    stripped = []
    for line in lines:
        if line.startswith(indent):
            stripped.append(line[len(indent) :])
        elif line.strip() == "":
            stripped.append("")
        else:
            raise ParseError("line indented less than the closing delimiter")
    return _read_escapes("\n".join(stripped), allow_line_continuation=True), match.end()


def extract_keys(text: str, path: str) -> list[tuple[int, str]]:
    """Every catalog key one Swift file produces, as ``(line number, key)``.

    Walks the file once, tracking whether it is in code, a ``//`` comment, a ``/* */`` comment
    (Swift nests those) or a string literal. Only a literal that starts in *code* and whose
    preceding code matches ``CALL_SITE_TAIL`` is a key.
    """
    keys: list[tuple[int, str]] = []
    code: list[str] = []
    index = 0
    length = len(text)
    block_depth = 0
    while index < length:
        if block_depth:
            if text.startswith("/*", index):
                block_depth += 1
                index += 2
            elif text.startswith("*/", index):
                block_depth -= 1
                index += 2
            else:
                index += 1
            continue
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = length if end == -1 else end
            continue
        if text.startswith("/*", index):
            block_depth = 1
            index += 2
            continue
        if text[index] == '"':
            preceding = "".join(code[-80:])
            is_call_site = CALL_SITE_TAIL.search(preceding) is not None
            line_number = text.count("\n", 0, index) + 1
            try:
                segments, index = read_literal(text, index)
            except ParseError as error:
                raise ParseError("%s:%d: %s" % (path, line_number, error)) from error
            # A literal that is nothing but interpolations — `DisplayRepresentation(title: "\(slug)")`
            # — has no text to translate; its key would be a bare `%@`, which is noise in a catalog.
            has_text = any(kind == "text" and value for kind, value in segments)
            if is_call_site and has_text:
                keys.append((line_number, _render_key(segments, path)))
            # A literal contributes nothing to the code text, but it must not glue the code
            # before it onto the code after it either.
            code.append(" ")
            continue
        code.append(text[index])
        index += 1
    if block_depth:
        raise ParseError("%s: unterminated /* */ comment" % path)
    return keys


def _render_key(segments: list[tuple[str, str]], path: str) -> str:
    """The key Xcode derives: literal text, with each interpolation as its format specifier."""
    raw = "".join(
        value if kind == "text" else "{%s}" % value for kind, value in segments
    )
    return "".join(
        value if kind == "text" else specifier(value, path, raw) for kind, value in segments
    )


def source_files() -> list[str]:
    """Every Swift file in the app target, repository-relative, sorted."""
    found = []
    for directory, subdirectories, filenames in os.walk(SOURCE_DIR):
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
        for filename in sorted(filenames):
            if filename.endswith(".swift"):
                absolute = os.path.join(directory, filename)
                found.append(os.path.relpath(absolute, REPO_ROOT))
    return sorted(found)


# ---------------------------------------------------------------------------------------------
# Format specifiers
# ---------------------------------------------------------------------------------------------

#: One printf-style specifier: optional positional index, flags, width, precision, length and the
#: conversion. `%%` is matched too so it can be dropped rather than read as a conversion.
FORMAT_SPECIFIER = re.compile(
    r"%(?:(\d+)\$)?([-+ #0]*)(\d+|\*)?(?:\.(\d+|\*))?(hh|h|ll|l|L|q|z|t|j)?([@%aAcCdeEfFgGinopsSuxX])"
)


def specifiers(value: str) -> list[str]:
    """The specifiers of one string, in the order the arguments are consumed.

    Positional (``%1$@``) and non-positional forms both normalise to ``(length, conversion)`` at
    an argument index, so a German translation that reorders two arguments compares equal to the
    English key it came from — which is the whole reason positional specifiers exist.
    """
    ordered: list[tuple[int, str]] = []
    next_index = 1
    for match in FORMAT_SPECIFIER.finditer(value):
        position, _flags, _width, _precision, length, conversion = match.groups()
        if conversion == "%":
            continue
        if position is None:
            index = next_index
            next_index += 1
        else:
            index = int(position)
        ordered.append((index, "%" + (length or "") + conversion))
    ordered.sort(key=lambda pair: pair[0])
    return [token for _, token in ordered]


# ---------------------------------------------------------------------------------------------
# The catalog
# ---------------------------------------------------------------------------------------------


def translated_values(entry: dict, language: str) -> tuple[list[str], list[str]]:
    """The strings a language contributes, plus the reasons it contributes none.

    A localisation is either one ``stringUnit`` or a set of plural ``variations``; both shapes
    have to be checked, because a plural entry with a broken ``other`` is exactly as wrong as a
    plain entry with a broken value.
    """
    localisation = entry.get("localizations", {}).get(language)
    if not isinstance(localisation, dict):
        return [], ["no %s localization" % language]
    if "stringUnit" in localisation:
        unit = localisation["stringUnit"]
        value = unit.get("value") if isinstance(unit, dict) else None
        if not isinstance(value, str) or not value.strip():
            return [], ["empty %s value" % language]
        return [value], []
    plural = localisation.get("variations", {}).get("plural")
    if not isinstance(plural, dict) or not plural:
        return [], ["%s localization has neither a stringUnit nor plural variations" % language]
    values = []
    problems = []
    for category in sorted(plural):
        unit = plural[category].get("stringUnit") if isinstance(plural[category], dict) else None
        value = unit.get("value") if isinstance(unit, dict) else None
        if not isinstance(value, str) or not value.strip():
            problems.append("empty %s plural value for %r" % (language, category))
            continue
        values.append(value)
    if "other" not in plural:
        problems.append("%s plural variations without an 'other' category" % language)
    # German has exactly two categories and needs both: an entry with only `other` would read
    # "1 Pull Requests" and pass every other check here.
    if language == REQUIRED_LANGUAGE and "one" not in plural:
        problems.append("%s plural variations without a 'one' category" % language)
    return values, problems


def main() -> int:
    problems: list[str] = []

    try:
        with open(CATALOG_PATH, encoding="utf-8") as handle:
            catalog = json.load(handle)
    except FileNotFoundError:
        print("error: %s does not exist" % os.path.relpath(CATALOG_PATH, REPO_ROOT))
        return 1
    except json.JSONDecodeError as error:
        print("error: %s is not valid JSON: %s" % (os.path.relpath(CATALOG_PATH, REPO_ROOT), error))
        return 1

    if catalog.get("sourceLanguage") != "en":
        problems.append('catalog sourceLanguage is %r, expected "en"' % catalog.get("sourceLanguage"))
    entries = catalog.get("strings")
    if not isinstance(entries, dict):
        print('error: catalog has no "strings" object')
        return 1

    # 1 — every key the source produces has to be in the catalog.
    sites: dict[str, list[str]] = {}
    for path in source_files():
        with open(os.path.join(REPO_ROOT, path), encoding="utf-8") as handle:
            text = handle.read()
        try:
            keys = extract_keys(text, path)
        except ParseError as error:
            print("error: could not read %s" % error)
            return 1
        for line_number, key in keys:
            sites.setdefault(key, []).append("%s:%d" % (path, line_number))

    for key in sorted(sites):
        if key not in entries:
            problems.append(
                "missing from the catalog: %r (%s)" % (key, ", ".join(sites[key][:3]))
            )

    # 2 + 3 — every entry needs a usable German value with the key's own specifiers.
    for key in sorted(entries):
        entry = entries[key]
        if not isinstance(entry, dict):
            problems.append("entry %r is not an object" % key)
            continue
        values, reasons = translated_values(entry, REQUIRED_LANGUAGE)
        for reason in reasons:
            problems.append("%s: %s" % (reason, key))
        expected = specifiers(key)
        for value in values:
            if specifiers(value) != expected:
                problems.append(
                    "specifier mismatch for %r: key has %s, %s has %s"
                    % (key, expected or "none", REQUIRED_LANGUAGE, specifiers(value) or "none")
                )
        # An English localisation is only ever written to spell out a plural the key cannot: the
        # key *is* the English string for every other entry, so a plain `en` unit would be a
        # second copy of it that can drift.
        english = entry.get("localizations", {}).get("en")
        if isinstance(english, dict):
            if "stringUnit" in english:
                problems.append(
                    "entry %r has a plain en stringUnit; the key is the English string" % key
                )
            else:
                english_values, english_reasons = translated_values(entry, "en")
                for reason in english_reasons:
                    problems.append("%s: %s" % (reason, key))
                for value in english_values:
                    if specifiers(value) != expected:
                        problems.append(
                            "specifier mismatch for %r: key has %s, en has %s"
                            % (key, expected or "none", specifiers(value) or "none")
                        )

    # 4 — a catalog key nothing produces any more.
    for key in sorted(entries):
        if key not in sites:
            problems.append("stale catalog entry, no call site produces it: %r" % key)

    if problems:
        print("Localization check failed with %d problem(s):" % len(problems))
        for problem in problems:
            print("  - %s" % problem)
        print(
            "\nEvery user-visible string needs a German row in "
            "Shepherd/Resources/Localizable.xcstrings (CONTRIBUTING.md, ADR 0022)."
        )
        return 1

    print(
        "Localization OK: %d catalog entries cover %d keys from %d source files."
        % (len(entries), len(sites), len(source_files()))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
