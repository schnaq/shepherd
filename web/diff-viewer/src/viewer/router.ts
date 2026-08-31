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
    default: {
      const exhaustive: never = message;
      throw new Error(`unhandled inbound message: ${JSON.stringify(exhaustive)}`);
    }
  }
}
