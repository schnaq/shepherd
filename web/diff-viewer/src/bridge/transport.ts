/**
 * Bridge transport: the two globals that connect the bundle to the native host.
 *
 *   inbound   `window.shepherd.receive(msg)`  ← called by Swift's `evaluateJavaScript`
 *   outbound  `window.webkit.messageHandlers.shepherd.postMessage(msg)`
 *
 * The `shepherd` global is installed by `installBridge`. When the page runs outside
 * WKWebView (the `npm run dev` harness, or a browser used for debugging) there is no
 * `window.webkit`, so a stub sink is used instead and outbound traffic is logged.
 */

import type { InboundMessage, OutboundMessage } from './protocol.js';
import { parseInbound } from './protocol.js';

/** The native message handler shape WKWebView installs. */
export interface WebKitMessageHandler {
  postMessage(message: unknown): void;
}

export interface WebKitBridge {
  readonly messageHandlers?: Readonly<Record<string, WebKitMessageHandler | undefined>>;
}

/** Global installed on `window` for Swift to call into. */
export interface ShepherdGlobal {
  /** Entry point for Swift → web messages. Returns `true` when the message was accepted. */
  receive(message: unknown): boolean;
  /** Protocol version this bundle speaks — lets Swift assert a match at boot. */
  readonly protocolVersion: number;
}

export interface BridgeHost {
  readonly webkit?: WebKitBridge | undefined;
}

export type OutboundSink = (message: OutboundMessage) => void;

/** Diagnostics for messages that failed validation (surfaced in the dev harness). */
export type BridgeErrorReporter = (error: string, raw: unknown) => void;

export interface InstallBridgeOptions {
  /** Target object the `shepherd` global is attached to (defaults to `globalThis`). */
  readonly target: Record<string, unknown>;
  /** Object searched for `webkit.messageHandlers.shepherd` (defaults to `target`). */
  readonly host?: BridgeHost | undefined;
  /** Called for each valid inbound message. */
  readonly onMessage: (message: InboundMessage) => void;
  readonly onError?: BridgeErrorReporter | undefined;
  /** Overrides the outbound sink entirely (used by tests and the dev harness). */
  readonly sink?: OutboundSink | undefined;
}

export interface Bridge {
  /** Send a message to the native side (or the stub sink). */
  readonly post: OutboundSink;
  /** `true` when a real `window.webkit.messageHandlers.shepherd` was found. */
  readonly isNative: boolean;
}

const HANDLER_NAME = 'shepherd';

function nativeSink(host: BridgeHost | undefined): OutboundSink | null {
  const handler = host?.webkit?.messageHandlers?.[HANDLER_NAME];
  if (!handler || typeof handler.postMessage !== 'function') return null;
  return (message) => {
    handler.postMessage(message);
  };
}

/** Fallback used outside WKWebView so the dev harness stays clickable. */
export function createStubSink(log: (message: OutboundMessage) => void): OutboundSink {
  return (message) => {
    log(message);
  };
}

export function installBridge(options: InstallBridgeOptions): Bridge {
  const host = options.host ?? (options.target as unknown as BridgeHost);
  const native = nativeSink(host);
  const sink: OutboundSink =
    options.sink ??
    native ??
    createStubSink((message) => {
      // eslint-disable-next-line no-console
      console.info('[shepherd:dev] →native', message);
    });

  const api: ShepherdGlobal = {
    protocolVersion: 1,
    receive(message: unknown): boolean {
      const parsed = parseInbound(message);
      if (!parsed.ok) {
        options.onError?.(parsed.error, message);
        return false;
      }
      options.onMessage(parsed.value);
      return true;
    },
  };

  options.target[HANDLER_NAME] = api;

  return { post: sink, isNative: native !== null };
}
