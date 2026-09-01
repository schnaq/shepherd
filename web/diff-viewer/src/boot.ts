/**
 * Wiring shared by the shipped bundle (`main.ts`) and the dev harness (`dev/harness.ts`):
 * create the viewer, install `window.shepherd`, announce `ready`.
 */

import { makeReady } from './bridge/protocol.js';
import type { OutboundSink } from './bridge/transport.js';
import { installBridge, type Bridge } from './bridge/transport.js';
import { MonacoDiffViewer } from './viewer/monacoViewer.js';
import { routeInboundSafely } from './viewer/router.js';

export const CONTAINER_ID = 'shepherd-diff';
export const ERROR_ID = 'shepherd-error';

export function showError(message: string): void {
  const node = document.getElementById(ERROR_ID);
  if (node === null) return;
  node.textContent = message;
  node.setAttribute('data-visible', 'true');
}

export interface BootOptions {
  /** Overrides the outbound sink (the harness uses this to render a message log). */
  readonly sink?: OutboundSink | undefined;
  readonly now?: (() => number) | undefined;
  readonly containerID?: string | undefined;
}

export interface BootResult {
  readonly viewer: MonacoDiffViewer;
  readonly bridge: Bridge;
}

export function boot(options: BootOptions = {}): BootResult {
  const containerID = options.containerID ?? CONTAINER_ID;
  const container = document.getElementById(containerID);
  if (container === null) throw new Error(`missing #${containerID} container`);

  const target = globalThis as unknown as Record<string, unknown>;

  // `viewer` is captured by the inbound handler before it is assigned: Swift is only told to
  // start sending once `ready` goes out, which happens after construction, but a stray early
  // message must not throw.
  let viewer: MonacoDiffViewer | null = null;
  const bridge = installBridge({
    target,
    sink: options.sink,
    onMessage: (message) => {
      if (viewer === null) return;
      routeInboundSafely(message, viewer, (detail, failed) => {
        console.error('[shepherd] failed to handle message:', detail, failed);
        showError(`Could not handle “${failed.type}”.\n${detail}`);
      });
    },
    onError: (error, raw) => {
      console.error('[shepherd] rejected message:', error, raw);
      showError(`Rejected message: ${error}`);
    },
  });

  viewer = new MonacoDiffViewer({ container, post: bridge.post, ...(options.now ? { now: options.now } : {}) });
  bridge.post(makeReady());

  return { viewer, bridge };
}
