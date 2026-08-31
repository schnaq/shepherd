/**
 * Bundle entry point — the file WKWebView loads through `index.html`.
 *
 * Boots the Monaco diff viewer, installs `window.shepherd`, and tells the native side it is
 * safe to start sending (`ready`). Nothing here touches the network; see ADR 0003.
 */

import './styles.css';

import { boot, showError } from './boot.js';

try {
  boot();
} catch (error) {
  const detail = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  console.error('[shepherd] boot failed', error);
  showError(`Diff viewer failed to start.\n${detail}`);
}
