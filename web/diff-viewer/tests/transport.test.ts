import { describe, expect, it, vi } from 'vitest';

import type { InboundMessage, OutboundMessage } from '../src/bridge/protocol.js';
import { makeReady } from '../src/bridge/protocol.js';
import { installBridge, type ShepherdGlobal } from '../src/bridge/transport.js';

function makeTarget(): Record<string, unknown> {
  return {};
}

describe('installBridge', () => {
  it('installs window.shepherd with the protocol version', () => {
    const target = makeTarget();
    installBridge({ target, onMessage: () => {}, sink: () => {} });
    const shepherd = target['shepherd'] as ShepherdGlobal;
    expect(typeof shepherd.receive).toBe('function');
    expect(shepherd.protocolVersion).toBe(1);
  });

  it('routes a valid inbound message and reports acceptance', () => {
    const received: InboundMessage[] = [];
    const target = makeTarget();
    installBridge({ target, onMessage: (m) => received.push(m), sink: () => {} });
    const shepherd = target['shepherd'] as ShepherdGlobal;

    const accepted = shepherd.receive({ v: 1, type: 'revealLine', line: 12, side: 'right' });

    expect(accepted).toBe(true);
    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({ v: 1, type: 'revealLine', line: 12, side: 'right' });
  });

  it('rejects an invalid message without calling onMessage', () => {
    const onMessage = vi.fn();
    const onError = vi.fn();
    const target = makeTarget();
    installBridge({ target, onMessage, onError, sink: () => {} });
    const shepherd = target['shepherd'] as ShepherdGlobal;

    const accepted = shepherd.receive({ v: 1, type: 'revealLine', line: 0, side: 'right' });

    expect(accepted).toBe(false);
    expect(onMessage).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledOnce();
    expect(String(onError.mock.calls[0]?.[0])).toContain('revealLine.line');
  });

  it('posts to window.webkit.messageHandlers.shepherd when present', () => {
    const posted: unknown[] = [];
    const target = makeTarget();
    const host = {
      webkit: { messageHandlers: { shepherd: { postMessage: (m: unknown) => posted.push(m) } } },
    };

    const bridge = installBridge({ target, host, onMessage: () => {} });
    bridge.post(makeReady());

    expect(bridge.isNative).toBe(true);
    expect(posted).toEqual([{ v: 1, type: 'ready' }]);
  });

  it('finds the handler on the target itself when no host is given', () => {
    const posted: unknown[] = [];
    const target = makeTarget() as Record<string, unknown> & {
      webkit?: unknown;
    };
    target['webkit'] = { messageHandlers: { shepherd: { postMessage: (m: unknown) => posted.push(m) } } };

    const bridge = installBridge({ target, onMessage: () => {} });
    bridge.post(makeReady());

    expect(bridge.isNative).toBe(true);
    expect(posted).toHaveLength(1);
  });

  it('falls back to a stub sink outside WKWebView', () => {
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});
    const target = makeTarget();

    const bridge = installBridge({ target, host: {}, onMessage: () => {} });
    bridge.post(makeReady());

    expect(bridge.isNative).toBe(false);
    expect(info).toHaveBeenCalledOnce();
  });

  it('ignores a messageHandlers entry that is not callable', () => {
    const target = makeTarget();
    const host = { webkit: { messageHandlers: { shepherd: { postMessage: 'nope' } } } } as unknown as {
      webkit: { messageHandlers: Record<string, { postMessage(m: unknown): void }> };
    };
    const bridge = installBridge({ target, host, onMessage: () => {}, sink: () => {} });
    expect(bridge.isNative).toBe(false);
  });

  it('lets an explicit sink win over the native handler (dev harness)', () => {
    const seen: OutboundMessage[] = [];
    const nativePosted: unknown[] = [];
    const target = makeTarget();
    const host = {
      webkit: { messageHandlers: { shepherd: { postMessage: (m: unknown) => nativePosted.push(m) } } },
    };

    const bridge = installBridge({ target, host, onMessage: () => {}, sink: (m) => seen.push(m) });
    bridge.post(makeReady());

    expect(seen).toHaveLength(1);
    expect(nativePosted).toHaveLength(0);
  });
});
