import { describe, expect, it } from 'vitest';

import {
  INBOUND_MESSAGE_TYPES,
  OUTBOUND_MESSAGE_TYPES,
  PROTOCOL_VERSION,
  isDiffMode,
  isSide,
  isThemeName,
  makeAddComment,
  makeDraftClicked,
  makeReady,
  makeThreadClicked,
  makeViewportChanged,
  parseInbound,
  parseOutbound,
} from '../src/bridge/protocol.js';

function expectFail(result: { ok: boolean; error?: string }, fragment: string): void {
  expect(result.ok).toBe(false);
  expect(result.ok === false ? result.error : '').toContain(fragment);
}

describe('envelope', () => {
  it('pins the protocol version at 1', () => {
    expect(PROTOCOL_VERSION).toBe(1);
  });

  it('rejects non-objects', () => {
    for (const value of [null, undefined, 42, 'loadFile', [], true]) {
      expect(parseInbound(value).ok).toBe(false);
      expect(parseOutbound(value).ok).toBe(false);
    }
  });

  it('rejects a mismatched version', () => {
    expectFail(parseInbound({ v: 2, type: 'revealLine', line: 1, side: 'right' }), 'unsupported protocol version');
    expectFail(parseOutbound({ v: 0, type: 'ready' }), 'unsupported protocol version');
  });

  it('rejects unknown message types', () => {
    expectFail(parseInbound({ v: 1, type: 'setFont' }), 'unknown inbound message type');
    expectFail(parseOutbound({ v: 1, type: 'scrolled' }), 'unknown outbound message type');
  });

  it('enumerates every message type in both directions', () => {
    expect([...INBOUND_MESSAGE_TYPES].sort()).toEqual(
      [
        'focusEditor',
        'loadFile',
        'revealLine',
        'setAccessibility',
        'setDraftComments',
        'setTheme',
        'setThreads',
      ].sort(),
    );
    expect([...OUTBOUND_MESSAGE_TYPES].sort()).toEqual(
      ['addComment', 'commentClicked', 'ready', 'viewportChanged'].sort(),
    );
  });
});

describe('narrow type guards', () => {
  it('accepts only the documented enum values', () => {
    expect(isSide('left')).toBe(true);
    expect(isSide('right')).toBe(true);
    expect(isSide('modified')).toBe(false);
    expect(isDiffMode('sideBySide')).toBe(true);
    expect(isDiffMode('inline')).toBe(true);
    expect(isDiffMode('unified')).toBe(false);
    expect(isThemeName('light')).toBe(true);
    expect(isThemeName('dark')).toBe(true);
    expect(isThemeName('auto')).toBe(false);
  });
});

describe('parseInbound: loadFile', () => {
  const valid = {
    v: 1,
    type: 'loadFile',
    path: 'a/b.swift',
    language: 'swift',
    original: 'let a = 1\n',
    modified: 'let a = 2\n',
    mode: 'sideBySide',
    wrap: false,
  };

  it('accepts a complete message and keeps every field', () => {
    const result = parseInbound(valid);
    expect(result.ok).toBe(true);
    expect(result.ok && result.value).toEqual(valid);
  });

  it('accepts empty file contents (new / deleted files)', () => {
    expect(parseInbound({ ...valid, original: '', modified: 'x' }).ok).toBe(true);
  });

  it.each([
    ['path', 1],
    ['language', null],
    ['original', 0],
    ['modified', undefined],
    ['mode', 'unified'],
    ['wrap', 'yes'],
  ])('rejects a bad %s', (field, badValue) => {
    expectFail(parseInbound({ ...valid, [field]: badValue }), `loadFile.${field}`);
  });

  it('omits commentableLines when the payload has none (additive field, v stays 1)', () => {
    const result = parseInbound(valid);
    expect(result.ok && 'commentableLines' in result.value).toBe(false);
    expect(parseInbound({ ...valid, commentableLines: null }).ok).toBe(true);
  });

  it('keeps commentableLines when present', () => {
    const commentableLines = { left: [1, 2], right: [1, 2, 3] };
    const result = parseInbound({ ...valid, commentableLines });
    expect(result.ok && result.value).toEqual({ ...valid, commentableLines });
  });

  it.each([
    ['not an object', 7],
    ['a missing side', { left: [1] }],
    ['a non-array side', { left: [1], right: 3 }],
    ['a zero line', { left: [0], right: [1] }],
    ['a fractional line', { left: [1], right: [2.5] }],
  ])('rejects commentableLines with %s', (_why, commentableLines) => {
    expectFail(parseInbound({ ...valid, commentableLines }), 'loadFile.commentableLines');
  });

  it('omits paneLabels when the payload has none, and keeps both when it has them', () => {
    const bare = parseInbound(valid);
    expect(bare.ok && 'paneLabels' in bare.value).toBe(false);
    const paneLabels = { left: 'Original, a/b.swift', right: 'Changed, a/b.swift' };
    const result = parseInbound({ ...valid, paneLabels });
    expect(result.ok && result.value).toEqual({ ...valid, paneLabels });
  });

  it('keeps both additive fields at once, which is what the app actually sends', () => {
    const commentableLines = { left: [1], right: [1, 2] };
    const paneLabels = { left: 'Original', right: 'Changed' };
    const result = parseInbound({ ...valid, commentableLines, paneLabels });
    expect(result.ok && result.value).toEqual({ ...valid, commentableLines, paneLabels });
  });

  it.each([
    ['not an object', 'Original'],
    ['a missing side', { left: 'Original' }],
    ['a non-string side', { left: 'Original', right: 3 }],
    ['an empty side', { left: '', right: 'Changed' }],
  ])('rejects paneLabels that are %s', (_why, paneLabels) => {
    expectFail(parseInbound({ ...valid, paneLabels }), 'loadFile.paneLabels');
  });
});

describe('parseInbound: setAccessibility', () => {
  it('accepts both states', () => {
    expect(parseInbound({ v: 1, type: 'setAccessibility', screenReader: true }).ok).toBe(true);
    expect(parseInbound({ v: 1, type: 'setAccessibility', screenReader: false }).ok).toBe(true);
  });

  it('rejects a missing or non-boolean flag', () => {
    expectFail(parseInbound({ v: 1, type: 'setAccessibility' }), 'setAccessibility.screenReader');
    expectFail(
      parseInbound({ v: 1, type: 'setAccessibility', screenReader: 'yes' }),
      'setAccessibility.screenReader',
    );
  });
});

describe('parseInbound: setTheme', () => {
  it('accepts both themes', () => {
    expect(parseInbound({ v: 1, type: 'setTheme', theme: 'dark', fontSize: 13 }).ok).toBe(true);
    expect(parseInbound({ v: 1, type: 'setTheme', theme: 'light', fontSize: 11.5 }).ok).toBe(true);
  });

  it('rejects an unknown theme and a non-positive font size', () => {
    expectFail(parseInbound({ v: 1, type: 'setTheme', theme: 'solarized', fontSize: 13 }), 'setTheme.theme');
    expectFail(parseInbound({ v: 1, type: 'setTheme', theme: 'dark', fontSize: 0 }), 'setTheme.fontSize');
    expectFail(parseInbound({ v: 1, type: 'setTheme', theme: 'dark', fontSize: Number.NaN }), 'setTheme.fontSize');
  });
});

describe('parseInbound: setThreads', () => {
  const comment = { author: 'octocat', bodyHTML: '<p>hi</p>', createdAt: '2026-08-30T09:12:44Z', isAgent: false };
  const thread = { id: 'T1', line: 4, side: 'right', resolved: false, outdated: false, comments: [comment] };

  it('accepts an empty list', () => {
    const result = parseInbound({ v: 1, type: 'setThreads', threads: [] });
    expect(result.ok && result.value).toEqual({ v: 1, type: 'setThreads', threads: [] });
  });

  it('accepts a populated thread', () => {
    const result = parseInbound({ v: 1, type: 'setThreads', threads: [thread] });
    expect(result.ok).toBe(true);
    expect(result.ok && result.value.type === 'setThreads' && result.value.threads[0]?.comments[0]?.author).toBe('octocat');
  });

  it('reports the failing index and field', () => {
    expectFail(
      parseInbound({ v: 1, type: 'setThreads', threads: [thread, { ...thread, id: 'T2', line: 0 }] }),
      'setThreads.threads[1].line',
    );
    expectFail(
      parseInbound({ v: 1, type: 'setThreads', threads: [{ ...thread, comments: [{ ...comment, isAgent: 'false' }] }] }),
      'setThreads.threads[0].comments[0].isAgent',
    );
  });

  it('rejects a non-array and an empty id', () => {
    expectFail(parseInbound({ v: 1, type: 'setThreads', threads: {} }), 'setThreads.threads');
    expectFail(parseInbound({ v: 1, type: 'setThreads', threads: [{ ...thread, id: '' }] }), 'threads[0].id');
  });
});

describe('parseInbound: setDraftComments', () => {
  const draft = { localID: 'D1', line: 8, side: 'right', body: 'nit' };

  it('accepts drafts on both sides, including an empty body', () => {
    const result = parseInbound({
      v: 1,
      type: 'setDraftComments',
      comments: [draft, { ...draft, localID: 'D2', side: 'left', body: '' }],
    });
    expect(result.ok).toBe(true);
  });

  it('rejects 1-based violations and a missing id', () => {
    expectFail(parseInbound({ v: 1, type: 'setDraftComments', comments: [{ ...draft, line: 0 }] }), 'comments[0].line');
    expectFail(parseInbound({ v: 1, type: 'setDraftComments', comments: [{ ...draft, line: 2.5 }] }), 'comments[0].line');
    expectFail(parseInbound({ v: 1, type: 'setDraftComments', comments: [{ ...draft, localID: '' }] }), 'comments[0].localID');
  });
});

describe('parseInbound: revealLine', () => {
  it('accepts a 1-based line on either side', () => {
    expect(parseInbound({ v: 1, type: 'revealLine', line: 1, side: 'left' }).ok).toBe(true);
    expect(parseInbound({ v: 1, type: 'revealLine', line: 9999, side: 'right' }).ok).toBe(true);
  });

  it('rejects line 0 and an unknown side', () => {
    expectFail(parseInbound({ v: 1, type: 'revealLine', line: 0, side: 'right' }), 'revealLine.line');
    expectFail(parseInbound({ v: 1, type: 'revealLine', line: 3, side: 'modified' }), 'revealLine.side');
  });
});

describe('parseOutbound', () => {
  it('round-trips every constructor', () => {
    expect(parseOutbound(makeReady()).ok).toBe(true);
    expect(parseOutbound(makeAddComment(7, 'right')).ok).toBe(true);
    expect(parseOutbound(makeAddComment(9, 'left', 7)).ok).toBe(true);
    expect(parseOutbound(makeThreadClicked('T1')).ok).toBe(true);
    expect(parseOutbound(makeDraftClicked('D1')).ok).toBe(true);
    expect(parseOutbound(makeViewportChanged(120)).ok).toBe(true);
  });

  it('omits startLine entirely when single-line', () => {
    const message = makeAddComment(7, 'right');
    expect(Object.prototype.hasOwnProperty.call(message, 'startLine')).toBe(false);
    expect(JSON.parse(JSON.stringify(message))).toEqual({ v: 1, type: 'addComment', line: 7, side: 'right' });
  });

  it('carries startLine through for the multi-line passthrough', () => {
    expect(makeAddComment(9, 'right', 7)).toEqual({ v: 1, type: 'addComment', line: 9, side: 'right', startLine: 7 });
  });

  it('rejects a startLine after line', () => {
    expectFail(parseOutbound({ v: 1, type: 'addComment', line: 7, side: 'right', startLine: 9 }), 'addComment.startLine');
  });

  it('requires exactly one identifier on commentClicked', () => {
    expectFail(parseOutbound({ v: 1, type: 'commentClicked' }), 'exactly one');
    expectFail(parseOutbound({ v: 1, type: 'commentClicked', threadID: 'T1', localID: 'D1' }), 'exactly one');
    expectFail(parseOutbound({ v: 1, type: 'commentClicked', threadID: '' }), 'commentClicked.threadID');
  });

  it('requires an integer firstVisibleLine', () => {
    expectFail(parseOutbound({ v: 1, type: 'viewportChanged', firstVisibleLine: 12.5 }), 'firstVisibleLine');
    expectFail(parseOutbound({ v: 1, type: 'viewportChanged', firstVisibleLine: 0 }), 'firstVisibleLine');
  });
});
