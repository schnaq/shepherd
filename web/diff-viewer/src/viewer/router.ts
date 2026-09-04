/**
 * Inbound message routing. Keeping this separate from the Monaco implementation means the
 * dispatch table is testable against a fake `ViewerPort`.
 */

import type { DraftComment, InboundMessage, LoadFileMessage, SetThemeMessage, Side, Thread } from '../bridge/protocol.js';

export interface ViewerPort {
  loadFile(message: LoadFileMessage): void;
  setTheme(message: SetThemeMessage): void;
  setThreads(threads: readonly Thread[]): void;
  setDraftComments(comments: readonly DraftComment[]): void;
  revealLine(line: number, side: Side): void;
  focusEditor(): void;
}

/** Dispatches one validated inbound message. Exhaustive over `InboundMessage`. */
export function routeInbound(message: InboundMessage, port: ViewerPort): void {
  switch (message.type) {
    case 'loadFile':
      port.loadFile(message);
      return;
    case 'setTheme':
      port.setTheme(message);
      return;
    case 'setThreads':
      port.setThreads(message.threads);
      return;
    case 'setDraftComments':
      port.setDraftComments(message.comments);
      return;
    case 'revealLine':
      port.revealLine(message.line, message.side);
      return;
    case 'focusEditor':
      port.focusEditor();
      return;
    default: {
      const exhaustive: never = message;
      throw new Error(`unhandled inbound message: ${JSON.stringify(exhaustive)}`);
    }
  }
}

/**
 * Dispatches a message and reports anything it throws instead of letting it escape.
 *
 * Inbound messages arrive through `evaluateJavaScript`, which swallows exceptions whole: a
 * throw inside `loadFile` used to leave the viewer half-torn-down (zones unmounted, models
 * gone) with the native side none the wiser and no way to tell the user. Failures are surfaced
 * through the page's error banner instead.
 *
 * @returns `true` when the message was handled, `false` when `onError` was called.
 */
export function routeInboundSafely(
  message: InboundMessage,
  port: ViewerPort,
  onError: (detail: string, message: InboundMessage) => void,
): boolean {
  try {
    routeInbound(message, port);
    return true;
  } catch (error) {
    const detail = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    onError(detail, message);
    return false;
  }
}
