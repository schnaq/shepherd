import { describe, expect, it } from 'vitest';

import type { DraftComment, InboundMessage, LoadFileMessage, SetThemeMessage, Side, Thread } from '../src/bridge/protocol.js';
import { routeInbound, routeInboundSafely, type ViewerPort } from '../src/viewer/router.js';

interface Call {
  readonly name: string;
  readonly payload: unknown;
}

function fakePort(): { port: ViewerPort; calls: Call[] } {
  const calls: Call[] = [];
  const port: ViewerPort = {
    loadFile: (m: LoadFileMessage) => calls.push({ name: 'loadFile', payload: m }),
    setTheme: (m: SetThemeMessage) => calls.push({ name: 'setTheme', payload: m }),
    setThreads: (t: readonly Thread[]) => calls.push({ name: 'setThreads', payload: t }),
    setDraftComments: (c: readonly DraftComment[]) => calls.push({ name: 'setDraftComments', payload: c }),
    revealLine: (line: number, side: Side) => calls.push({ name: 'revealLine', payload: { line, side } }),
    focusEditor: () => calls.push({ name: 'focusEditor', payload: undefined }),
    setAccessibility: (screenReader: boolean) =>
      calls.push({ name: 'setAccessibility', payload: screenReader }),
  };
  return { port, calls };
}

describe('routeInbound', () => {
  it('dispatches each message to its port method exactly once', () => {
    const { port, calls } = fakePort();
    const loadFile: InboundMessage = {
      v: 1,
      type: 'loadFile',
      path: 'a.ts',
      language: 'typescript',
      original: '',
      modified: '',
      mode: 'inline',
      wrap: true,
    };
    const messages: InboundMessage[] = [
      loadFile,
      { v: 1, type: 'setTheme', theme: 'dark', fontSize: 14 },
      { v: 1, type: 'setThreads', threads: [] },
      { v: 1, type: 'setDraftComments', comments: [] },
      { v: 1, type: 'revealLine', line: 5, side: 'left' },
      { v: 1, type: 'focusEditor' },
      { v: 1, type: 'setAccessibility', screenReader: true },
    ];

    for (const message of messages) routeInbound(message, port);

    expect(calls.map((c) => c.name)).toEqual([
      'loadFile',
      'setTheme',
      'setThreads',
      'setDraftComments',
      'revealLine',
      'focusEditor',
      'setAccessibility',
    ]);
    expect(calls[0]?.payload).toBe(loadFile);
    expect(calls[4]?.payload).toEqual({ line: 5, side: 'left' });
    expect(calls[6]?.payload).toBe(true);
  });

  it('unwraps the arrays for setThreads / setDraftComments', () => {
    const { port, calls } = fakePort();
    const threads: Thread[] = [
      { id: 'T1', line: 2, side: 'right', resolved: false, outdated: false, comments: [] },
    ];
    const drafts: DraftComment[] = [{ localID: 'D1', line: 3, side: 'left', body: 'x' }];

    routeInbound({ v: 1, type: 'setThreads', threads }, port);
    routeInbound({ v: 1, type: 'setDraftComments', comments: drafts }, port);

    expect(calls[0]?.payload).toBe(threads);
    expect(calls[1]?.payload).toBe(drafts);
  });

  it('throws on a message type it does not know (defensive, unreachable via parseInbound)', () => {
    const { port } = fakePort();
    const bogus = { v: 1, type: 'nope' } as unknown as InboundMessage;
    expect(() => routeInbound(bogus, port)).toThrow(/unhandled inbound message/);
  });
});

describe('routeInboundSafely', () => {
  const loadFile: InboundMessage = {
    v: 1,
    type: 'loadFile',
    path: 'a.ts',
    language: 'typescript',
    original: '',
    modified: '',
    mode: 'inline',
    wrap: true,
  };

  it('reports a throwing port instead of letting the error escape', () => {
    const { port } = fakePort();
    const failing: ViewerPort = { ...port, loadFile: () => { throw new Error('boom'); } };
    const seen: string[] = [];

    const handled = routeInboundSafely(loadFile, failing, (detail) => seen.push(detail));

    expect(handled).toBe(false);
    expect(seen).toEqual(['Error: boom']);
  });

  it('passes the offending message to the reporter', () => {
    const { port } = fakePort();
    const failing: ViewerPort = { ...port, loadFile: () => { throw new Error('boom'); } };
    let reported: InboundMessage | null = null;

    routeInboundSafely(loadFile, failing, (_detail, message) => { reported = message; });

    expect(reported).toBe(loadFile);
  });

  it('dispatches normally and reports nothing when the port is happy', () => {
    const { port, calls } = fakePort();
    const seen: string[] = [];

    expect(routeInboundSafely(loadFile, port, (detail) => seen.push(detail))).toBe(true);
    expect(calls.map((c) => c.name)).toEqual(['loadFile']);
    expect(seen).toEqual([]);
  });
});
