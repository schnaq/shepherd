import { describe, expect, it } from 'vitest';

import {
  cursorHit,
  gutterHit,
  hitChanged,
  MouseTargetType,
  originalToModifiedLine,
  rangeTarget,
  selectedLines,
} from '../src/viewer/gutter.js';

describe('gutterHit', () => {
  const base = { lineNumber: 5, side: 'right', lineCount: 40 } as const;

  it('arms on every gutter target type', () => {
    for (const targetType of [
      MouseTargetType.GUTTER_GLYPH_MARGIN,
      MouseTargetType.GUTTER_LINE_NUMBERS,
      MouseTargetType.GUTTER_LINE_DECORATIONS,
    ]) {
      expect(gutterHit({ ...base, targetType })).toEqual({ line: 5, side: 'right' });
    }
  });

  it('ignores content and non-gutter targets', () => {
    for (const targetType of [
      MouseTargetType.UNKNOWN,
      MouseTargetType.TEXTAREA,
      MouseTargetType.GUTTER_VIEW_ZONE,
      MouseTargetType.CONTENT_TEXT,
      MouseTargetType.CONTENT_EMPTY,
      MouseTargetType.CONTENT_VIEW_ZONE,
    ]) {
      expect(gutterHit({ ...base, targetType })).toBeNull();
    }
  });

  it('arms the original pane too, so deletions can be commented on', () => {
    expect(gutterHit({ ...base, side: 'left', targetType: MouseTargetType.GUTTER_LINE_NUMBERS })).toEqual({
      line: 5,
      side: 'left',
    });
  });

  it('rejects missing, non-integer and out-of-range line numbers', () => {
    const targetType = MouseTargetType.GUTTER_LINE_NUMBERS;
    expect(gutterHit({ ...base, targetType, lineNumber: null })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: undefined })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: 0 })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: -3 })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: 2.5 })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: 41 })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: 40 })).toEqual({ line: 40, side: 'right' });
  });

  it('refuses lines that are not part of the diff', () => {
    const targetType = MouseTargetType.GUTTER_LINE_NUMBERS;
    // Lines 5 and 9 came from a hunk; 6-8 are the blank padding between hunks, which GitHub
    // would reject — and it rejects the whole review along with them.
    const commentable = new Set([5, 9]);
    expect(gutterHit({ ...base, targetType, commentable })).toEqual({ line: 5, side: 'right' });
    expect(gutterHit({ ...base, targetType, lineNumber: 9, commentable })).toEqual({ line: 9, side: 'right' });
    expect(gutterHit({ ...base, targetType, lineNumber: 6, commentable })).toBeNull();
    expect(gutterHit({ ...base, targetType, lineNumber: 8, commentable })).toBeNull();
  });

  it('arms every line when the payload named no commentable set', () => {
    const targetType = MouseTargetType.GUTTER_LINE_NUMBERS;
    expect(gutterHit({ ...base, targetType, commentable: null })).toEqual({ line: 5, side: 'right' });
    expect(gutterHit({ ...base, targetType, commentable: undefined })).toEqual({ line: 5, side: 'right' });
  });

  it('applies the commentable set of the probed side only', () => {
    const targetType = MouseTargetType.GUTTER_LINE_NUMBERS;
    expect(gutterHit({ ...base, targetType, side: 'left', commentable: new Set([5]) })).toEqual({
      line: 5,
      side: 'left',
    });
    expect(gutterHit({ ...base, targetType, side: 'left', commentable: new Set([4]) })).toBeNull();
  });

  it('skips the range check when the line count is unknown (-1)', () => {
    expect(gutterHit({ targetType: MouseTargetType.GUTTER_LINE_NUMBERS, lineNumber: 9999, side: 'right', lineCount: -1 })).toEqual({
      line: 9999,
      side: 'right',
    });
  });
});

describe('hitChanged', () => {
  it('is false only for the identical armed line', () => {
    expect(hitChanged(null, null)).toBe(false);
    expect(hitChanged({ line: 3, side: 'right' }, { line: 3, side: 'right' })).toBe(false);
    expect(hitChanged({ line: 3, side: 'right' }, { line: 4, side: 'right' })).toBe(true);
    expect(hitChanged({ line: 3, side: 'right' }, { line: 3, side: 'left' })).toBe(true);
    expect(hitChanged(null, { line: 3, side: 'left' })).toBe(true);
    expect(hitChanged({ line: 3, side: 'left' }, null)).toBe(true);
  });
});

describe('selectedLines', () => {
  it('leaves out a last line selected only up to its start', () => {
    // What a click on a line number selects: line 4 from column 1 to line 5, column 1.
    expect(selectedLines({ startLineNumber: 4, endLineNumber: 5, endColumn: 1 })).toEqual({ start: 4, end: 4 });
    expect(selectedLines({ startLineNumber: 4, endLineNumber: 7, endColumn: 3 })).toEqual({ start: 4, end: 7 });
  });

  it('keeps an empty selection on its line', () => {
    expect(selectedLines({ startLineNumber: 6, endLineNumber: 6, endColumn: 1 })).toEqual({ start: 6, end: 6 });
  });
});

describe('rangeTarget', () => {
  const probe = { side: 'right', lineCount: 40, commentable: new Set([3, 4, 5, 6, 20, 21]) } as const;

  it('omits startLine for a single line', () => {
    const target = rangeTarget(probe, { startLineNumber: 4, endLineNumber: 4, endColumn: 9 });
    expect(target).toEqual({ line: 4, side: 'right' });
    expect(Object.prototype.hasOwnProperty.call(target, 'startLine')).toBe(false);
  });

  it('anchors a range on its last line, from its first', () => {
    expect(rangeTarget(probe, { startLineNumber: 3, endLineNumber: 7, endColumn: 1 })).toEqual({
      line: 6,
      side: 'right',
      startLine: 3,
    });
  });

  it('refuses a range that crosses the padding between hunks', () => {
    expect(rangeTarget(probe, { startLineNumber: 5, endLineNumber: 20, endColumn: 4 })).toBeNull();
  });

  it('refuses a range past the end of the file', () => {
    expect(rangeTarget({ ...probe, commentable: null }, { startLineNumber: 38, endLineNumber: 41, endColumn: 2 })).toBeNull();
  });
});

describe('originalToModifiedLine', () => {
  it('keeps lines above every change', () => {
    expect(originalToModifiedLine(3, [{ originalStartLineNumber: 3, originalEndLineNumber: 0, modifiedStartLineNumber: 4, modifiedEndLineNumber: 5 }])).toBe(3);
  });

  it('shifts lines below an insertion by its size', () => {
    expect(originalToModifiedLine(4, [{ originalStartLineNumber: 3, originalEndLineNumber: 0, modifiedStartLineNumber: 4, modifiedEndLineNumber: 5 }])).toBe(6);
  });

  it('puts a deleted line where the deletion sits, and shifts what follows back', () => {
    const deletion = { originalStartLineNumber: 4, originalEndLineNumber: 5, modifiedStartLineNumber: 3, modifiedEndLineNumber: 0 };
    expect(originalToModifiedLine(5, [deletion])).toBe(3);
    expect(originalToModifiedLine(6, [deletion])).toBe(4);
  });

  it('puts a changed line on the first line that replaced it', () => {
    const change = { originalStartLineNumber: 4, originalEndLineNumber: 5, modifiedStartLineNumber: 4, modifiedEndLineNumber: 6 };
    expect(originalToModifiedLine(5, [change])).toBe(4);
    expect(originalToModifiedLine(7, [change])).toBe(8);
  });
});

describe('cursorHit', () => {
  const base = { lineNumber: 5, side: 'right', lineCount: 40 } as const;

  it('asks nothing about the pointer, because the keyboard has none', () => {
    // The whole difference between the two entry points: `gutterHit` refuses a line the pointer
    // is not over the gutter of, and the cursor is never over a gutter at all.
    expect(cursorHit(base)).toEqual({ line: 5, side: 'right' });
    expect(gutterHit({ ...base, targetType: MouseTargetType.CONTENT_TEXT })).toBeNull();
  });

  it('applies the same line rules the pointer path applies', () => {
    expect(cursorHit({ ...base, lineNumber: null })).toBeNull();
    expect(cursorHit({ ...base, lineNumber: undefined })).toBeNull();
    expect(cursorHit({ ...base, lineNumber: 0 })).toBeNull();
    expect(cursorHit({ ...base, lineNumber: 2.5 })).toBeNull();
    expect(cursorHit({ ...base, lineNumber: 41 })).toBeNull();
    expect(cursorHit({ ...base, lineNumber: 40 })).toEqual({ line: 40, side: 'right' });
  });

  it('refuses a line that is not part of the diff', () => {
    // A comment on one of the blank lines the reconstruction pads the gaps with is a comment
    // GitHub refuses — and it refuses the whole review with it. The keyboard must not be the
    // way around that guard.
    const commentable = new Set([5, 9]);
    expect(cursorHit({ ...base, commentable })).toEqual({ line: 5, side: 'right' });
    expect(cursorHit({ ...base, lineNumber: 6, commentable })).toBeNull();
  });

  it('arms the original pane too, so a deletion can be commented on by keyboard', () => {
    expect(cursorHit({ ...base, side: 'left' })).toEqual({ line: 5, side: 'left' });
  });
});
