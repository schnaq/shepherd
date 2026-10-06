/**
 * Gutter “+” hit-testing — pure logic, no Monaco import, so it is unit-testable.
 *
 * The viewer wires `editor.onMouseMove` / `onMouseDown` on both panes of the diff editor and
 * feeds the raw mouse-target type + line number in here. Hovering a line number (or the glyph
 * margin / line-decorations strip next to it) on either side arms the “+”; the original pane
 * arms it too so deletions can be commented on.
 */

import type { Side } from '../bridge/protocol.js';

/** Mirrors `monaco.editor.MouseTargetType`; duplicated so this module stays Monaco-free. */
export const MouseTargetType = {
  UNKNOWN: 0,
  TEXTAREA: 1,
  GUTTER_GLYPH_MARGIN: 2,
  GUTTER_LINE_NUMBERS: 3,
  GUTTER_LINE_DECORATIONS: 4,
  GUTTER_VIEW_ZONE: 5,
  CONTENT_TEXT: 6,
  CONTENT_EMPTY: 7,
  CONTENT_VIEW_ZONE: 8,
} as const;

const GUTTER_TARGETS: ReadonlySet<number> = new Set<number>([
  MouseTargetType.GUTTER_GLYPH_MARGIN,
  MouseTargetType.GUTTER_LINE_NUMBERS,
  MouseTargetType.GUTTER_LINE_DECORATIONS,
]);

export interface GutterProbe {
  /** `monaco.editor.IMouseTarget.type`. */
  readonly targetType: number;
  /** `monaco.editor.IMouseTarget.position?.lineNumber`; `null`/`undefined` when off-content. */
  readonly lineNumber: number | null | undefined;
  /** Which pane the event came from. */
  readonly side: Side;
  /** Line count of that pane's model — guards stale targets past the end of the file. */
  readonly lineCount: number;
  /**
   * The lines of this side that are actually part of the diff, from `loadFile`'s
   * `commentableLines`; `null`/`undefined` means the native side did not say, and every line
   * is armable (the pre-`commentableLines` behaviour).
   *
   * The reconstruction pads the gaps between hunks with blank lines so line numbers match
   * GitHub's. Arming the “+” on one of those produces a comment GitHub refuses, and it
   * refuses the whole review with it — so a padding line must never arm.
   */
  readonly commentable?: ReadonlySet<number> | null | undefined;
}

export interface GutterHit {
  readonly line: number;
  readonly side: Side;
}

/**
 * Everything a gutter probe carries except where the pointer was — which is what a *cursor* has
 * too, and the reason this type exists: a comment reached by the keyboard is subject to exactly
 * the same line rules as one reached by the mouse (in range, and part of the diff rather than
 * one of the blank lines the reconstruction pads the gaps with), and two copies of those rules
 * would be two chances for the keyboard path to offer a comment GitHub refuses.
 */
export type CursorProbe = Omit<GutterProbe, 'targetType'>;

/**
 * @returns the line a comment may be left on, or `null` when this one may not carry one.
 *
 * The line rules, with no opinion about how the line was chosen. ``gutterHit`` adds the mouse's
 * question — is the pointer over the gutter at all — and the keyboard asks this one directly.
 */
export function cursorHit(probe: CursorProbe): GutterHit | null {
  const line = probe.lineNumber;
  if (typeof line !== 'number' || !Number.isInteger(line) || line < 1) return null;
  if (probe.lineCount >= 0 && line > probe.lineCount) return null;
  if (probe.commentable !== undefined && probe.commentable !== null && !probe.commentable.has(line)) {
    return null;
  }
  return { line, side: probe.side };
}

/** @returns the line to arm the “+” on, or `null` when the pointer is not over a gutter line. */
export function gutterHit(probe: GutterProbe): GutterHit | null {
  if (!GUTTER_TARGETS.has(probe.targetType)) return null;
  return cursorHit(probe);
}

/** `true` when the armed line changed and decorations need re-applying. */
export function hitChanged(previous: GutterHit | null, next: GutterHit | null): boolean {
  if (previous === null || next === null) return previous !== next;
  return previous.line !== next.line || previous.side !== next.side;
}

/** Mirrors the line fields of `monaco.Selection`. */
export interface SelectionLines {
  readonly startLineNumber: number;
  readonly endLineNumber: number;
  readonly endColumn: number;
}

/**
 * The lines a selection covers. One ending at column 1 has selected nothing on its last line —
 * clicking a line number selects up to the start of the *next* one — so that line is left out.
 */
export function selectedLines(selection: SelectionLines): { start: number; end: number } {
  const start = selection.startLineNumber;
  const end = selection.endLineNumber;
  return { start, end: selection.endColumn === 1 && end > start ? end - 1 : end };
}

/**
 * Resolves the `addComment` payload for a selection in one pane — a single line when nothing
 * spans lines, a range otherwise — or `null` when any line of it may not carry a comment.
 *
 * Every line is asked, not just the two ends: the padding between hunks is not commentable, so a
 * range that crosses it spans two hunks, and GitHub refuses a range comment like that along with
 * the whole review it came in.
 */
export function rangeTarget(
  probe: Omit<CursorProbe, 'lineNumber'>,
  selection: SelectionLines,
): { line: number; side: Side; startLine?: number } | null {
  const { start, end } = selectedLines(selection);
  for (let line = start; line <= end; line += 1) {
    if (cursorHit({ ...probe, lineNumber: line }) === null) return null;
  }
  return start === end ? { line: end, side: probe.side } : { line: end, side: probe.side, startLine: start };
}

/** Mirrors `monaco.editor.ILineChange`; an end of 0 means that side has no lines in the change. */
export interface LineChange {
  readonly originalStartLineNumber: number;
  readonly originalEndLineNumber: number;
  readonly modifiedStartLineNumber: number;
  readonly modifiedEndLineNumber: number;
}

/**
 * Where a line of the original file is in the modified one: a deleted or changed line lands on
 * the first line that replaced it (or the line the deletion sits after), every other line shifts
 * by what the changes above it added and removed.
 */
export function originalToModifiedLine(line: number, changes: readonly LineChange[]): number {
  // The shift left by the last change wholly above `line`; a change at or below it ends the walk.
  let shift = 0;
  for (const change of changes) {
    const originalEnd = change.originalEndLineNumber === 0 ? change.originalStartLineNumber : change.originalEndLineNumber;
    if (change.originalEndLineNumber !== 0 && line >= change.originalStartLineNumber && line <= originalEnd) {
      return Math.max(1, change.modifiedStartLineNumber);
    }
    if (originalEnd >= line) break;
    const modifiedEnd = change.modifiedEndLineNumber === 0 ? change.modifiedStartLineNumber : change.modifiedEndLineNumber;
    shift = modifiedEnd - originalEnd;
  }
  return Math.max(1, line + shift);
}
