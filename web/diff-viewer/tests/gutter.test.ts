import { describe, expect, it } from 'vitest';

import { addCommentTarget, gutterHit, hitChanged, MouseTargetType } from '../src/viewer/gutter.js';

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
