import { describe, expect, it } from 'vitest';

import { addCommentTarget, cursorHit, gutterHit, hitChanged, MouseTargetType } from '../src/viewer/gutter.js';

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

describe('addCommentTarget', () => {
  const hit = { line: 9, side: 'right' } as const;

  it('omits startLine for the single-line trigger', () => {
    expect(addCommentTarget(hit)).toEqual({ line: 9, side: 'right' });
    expect(Object.prototype.hasOwnProperty.call(addCommentTarget(hit), 'startLine')).toBe(false);
  });

  it('passes a valid multi-line selection through', () => {
    expect(addCommentTarget(hit, 7)).toEqual({ line: 9, side: 'right', startLine: 7 });
  });

  it('drops a start line that is not strictly above the anchor', () => {
    expect(addCommentTarget(hit, 9)).toEqual({ line: 9, side: 'right' });
    expect(addCommentTarget(hit, 12)).toEqual({ line: 9, side: 'right' });
    expect(addCommentTarget(hit, 0)).toEqual({ line: 9, side: 'right' });
    expect(addCommentTarget(hit, 2.5)).toEqual({ line: 9, side: 'right' });
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
