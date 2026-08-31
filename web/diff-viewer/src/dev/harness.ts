/**
 * Standalone browser harness (`npm run dev`).
 *
 * Loads the real bundle with the real bridge, but stubs the native side: outbound messages are
 * rendered into a log panel instead of `window.webkit.messageHandlers.shepherd`, and the
 * buttons feed the shared `fixtures/*.json` back in through `window.shepherd.receive` — the
 * exact call Swift makes. Nothing here ships in `dist/`.
 */

import '../styles.css';
import './harness.css';

import { boot, showError } from '../boot.js';
import type { OutboundMessage } from '../bridge/protocol.js';

import addCommentFixture from '../../fixtures/addComment.valid.json';
import loadFileFixture from '../../fixtures/loadFile.valid.json';
import loadFileInlineFixture from '../../fixtures/loadFile.valid-inline.json';
import revealLineFixture from '../../fixtures/revealLine.valid.json';
import setDraftCommentsFixture from '../../fixtures/setDraftComments.valid.json';
import setThemeFixture from '../../fixtures/setTheme.valid.json';
import setThreadsFixture from '../../fixtures/setThreads.valid.json';

const LOG_ID = 'harness-log';

function log(kind: 'out' | 'in' | 'note', text: string): void {
  const panel = document.getElementById(LOG_ID);
  if (panel === null) return;
  const row = document.createElement('div');
  row.className = `harness-log__row harness-log__row--${kind}`;
  const time = new Date().toISOString().slice(11, 23);
  row.textContent = `${time}  ${kind === 'out' ? '→ native' : kind === 'in' ? '← native' : '·'}  ${text}`;
  panel.prepend(row);
}

function send(label: string, message: unknown): void {
  log('in', label);
  const shepherd = (globalThis as unknown as { shepherd?: { receive(m: unknown): boolean } }).shepherd;
  const accepted = shepherd?.receive(message) ?? false;
  if (!accepted) log('note', `${label} was REJECTED by the protocol validator`);
}

function button(label: string, onClick: () => void): HTMLButtonElement {
  const el = document.createElement('button');
  el.type = 'button';
  el.className = 'harness-button';
  el.textContent = label;
  el.addEventListener('click', onClick);
  return el;
}

function setup(): void {
  boot({
    sink: (message: OutboundMessage) => {
      log('out', JSON.stringify(message));
    },
  });

  const bar = document.getElementById('harness-bar');
  if (bar === null) return;

  bar.append(
    button('loadFile (side-by-side)', () => {
      send('loadFile sideBySide', loadFileFixture);
    }),
    button('loadFile (inline)', () => {
      send('loadFile inline', loadFileInlineFixture);
    }),
    button('setThreads', () => {
      send('setThreads', setThreadsFixture);
    }),
    button('clear threads', () => {
      send('setThreads []', { v: 1, type: 'setThreads', threads: [] });
    }),
    button('setDraftComments', () => {
      send('setDraftComments', setDraftCommentsFixture);
    }),
    button('clear drafts', () => {
      send('setDraftComments []', { v: 1, type: 'setDraftComments', comments: [] });
    }),
    button('theme: dark', () => {
      send('setTheme dark', setThemeFixture);
    }),
    button('theme: light', () => {
      send('setTheme light', { v: 1, type: 'setTheme', theme: 'light', fontSize: 13 });
    }),
    button('font 16', () => {
      send('setTheme fontSize 16', { v: 1, type: 'setTheme', theme: 'light', fontSize: 16 });
    }),
    button('revealLine 42', () => {
      send('revealLine', revealLineFixture);
    }),
    button('replay addComment fixture', () => {
      // Not an inbound message — shows what the viewer *emits* when a “+” is clicked.
      log('note', `gutter “+” emits: ${JSON.stringify(addCommentFixture)}`);
    }),
    button('send an invalid message', () => {
      send('bogus', { v: 1, type: 'loadFile', mode: 'unified' });
    }),
  );

  log('note', 'Harness ready. Hover a gutter line number to arm the “+”, then click it.');

  // Give the harness something to look at immediately.
  send('loadFile sideBySide', loadFileFixture);
  send('setThreads', setThreadsFixture);
  send('setDraftComments', setDraftCommentsFixture);
}

try {
  setup();
} catch (error) {
  const detail = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  console.error('[shepherd:dev] harness failed', error);
  showError(`Harness failed to start.\n${detail}`);
}
