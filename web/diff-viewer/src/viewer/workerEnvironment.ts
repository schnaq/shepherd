/**
 * Monaco web-worker wiring for a `file://` document inside WKWebView.
 *
 * Monaco's diff computation runs in `editor.worker`. Under WKWebView the page is loaded with
 * `loadFileURL(...)`, which gives it an **opaque `file:` origin**: `new Worker('./editor.worker.js')`
 * is rejected there (and module workers over `file:` are worse still). The reliable, widely
 * used escape hatch is to construct the worker from a `blob:` URL, which inherits the page's
 * origin and needs no file-system read permission at all.
 *
 * The build therefore bundles `editor.worker` separately into a classic IIFE and inlines its
 * source into this module as a string (`virtual:editor-worker-source`). At runtime we hand
 * Monaco a worker built from `URL.createObjectURL(new Blob([source]))`. `dist/editor.worker.js`
 * is still emitted next to `index.html` as a debugging aid and as the fallback for hosts where
 * `Blob`/`createObjectURL` is unavailable.
 */

import editorWorkerSource from 'virtual:editor-worker-source';

/** Relative fallback path, resolved against the document URL. */
export const WORKER_FALLBACK_PATH = './editor.worker.js';

let blobURL: string | null = null;

function workerBlobURL(): string | null {
  if (blobURL !== null) return blobURL;
  if (typeof Blob !== 'function' || typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') {
    return null;
  }
  try {
    blobURL = URL.createObjectURL(new Blob([editorWorkerSource], { type: 'text/javascript;charset=utf-8' }));
    return blobURL;
  } catch {
    return null;
  }
}

/** Creates Monaco's editor worker. Classic (non-module) worker on purpose. */
export function createEditorWorker(): Worker {
  const url = workerBlobURL();
  if (url !== null) {
    try {
      return new Worker(url, { name: 'shepherd-monaco-editor-worker' });
    } catch {
      // Fall through to the relative-path fallback below.
    }
  }
  return new Worker(WORKER_FALLBACK_PATH, { name: 'shepherd-monaco-editor-worker' });
}

/**
 * Installs `self.MonacoEnvironment`. Only the *editor* worker exists in this bundle: no
 * language services are registered, so Monaco never asks for a `json`/`css`/`html`/`typescript`
 * worker label.
 */
export function installMonacoEnvironment(): void {
  globalThis.MonacoEnvironment = {
    getWorker: () => createEditorWorker(),
  };
}
