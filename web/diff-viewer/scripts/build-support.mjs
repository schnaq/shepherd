// Shared esbuild configuration for `npm run build` and `npm run dev`.
//
// Two bundles come out of here:
//
//   1. the Monaco *editor worker*, built on its own as a classic IIFE. Its source is inlined
//      into the main bundle as a string (the `virtual:editor-worker-source` module) so the
//      viewer can start it from a `blob:` URL — the only worker flavour that reliably works
//      for a `file://` document inside WKWebView. It is also written to disk as
//      `editor.worker.js` for debugging and as the no-Blob fallback.
//   2. the viewer itself (`src/main.ts` → `viewer.js` + `viewer.css`).
//
// Both are fully offline: no CDN, no dynamic fetch, fonts inlined as data: URIs.

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import esbuild from 'esbuild';

export const projectRoot = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
export const distDir = path.resolve(projectRoot, '..', '..', 'Shepherd', 'Resources', 'DiffViewer', 'dist');

/** WKWebView on macOS 26 — Safari 17-era engine is a safe floor. */
export const TARGET = ['es2022', 'safari17'];

export const VIRTUAL_WORKER_MODULE = 'virtual:editor-worker-source';

export const BANNER = [
  '/*!',
  ' * Shepherd diff viewer — generated bundle, do not edit.',
  ' * Source: web/diff-viewer (MIT). Bundles monaco-editor (MIT, (c) Microsoft Corporation).',
  ' */',
].join('\n');

/** Binary/asset loaders — everything is inlined so `dist/` never reaches out to the network. */
export const ASSET_LOADERS = /** @type {const} */ ({
  '.ttf': 'dataurl',
  '.woff': 'dataurl',
  '.woff2': 'dataurl',
  '.eot': 'dataurl',
  '.svg': 'dataurl',
  '.png': 'dataurl',
  '.gif': 'dataurl',
  '.json': 'json',
});

/**
 * Bundles `monaco-editor/editor/editor.worker` into a single classic script.
 * @param {{ minify: boolean }} options
 * @returns {Promise<string>} the worker's JavaScript source
 */
export async function buildEditorWorkerSource({ minify }) {
  const result = await esbuild.build({
    stdin: {
      contents: "import 'monaco-editor/editor/editor.worker';\n",
      resolveDir: projectRoot,
      sourcefile: 'editor.worker.entry.js',
      loader: 'js',
    },
    bundle: true,
    // Classic (non-module) worker: module workers over file:// are the unreliable case.
    format: 'iife',
    platform: 'browser',
    target: TARGET,
    minify,
    sourcemap: false,
    legalComments: 'none',
    write: false,
    logLevel: 'warning',
  });

  const [file] = result.outputFiles;
  if (file === undefined) throw new Error('editor worker bundle produced no output');
  return file.text;
}

/**
 * Serves `virtual:editor-worker-source` as a text module holding the worker source.
 * @param {string} source
 * @returns {import('esbuild').Plugin}
 */
export function inlineWorkerPlugin(source) {
  return {
    name: 'shepherd-inline-editor-worker',
    setup(build) {
      const filter = /^virtual:editor-worker-source$/;
      build.onResolve({ filter }, (args) => ({ path: args.path, namespace: 'shepherd-virtual' }));
      build.onLoad({ filter, namespace: 'shepherd-virtual' }, () => ({
        contents: source,
        loader: 'text',
      }));
    },
  };
}

/**
 * Common options for the viewer bundle.
 * @param {{ entry: string, outdir: string, entryName: string, minify: boolean, workerSource: string, sourcemap: boolean }} options
 * @returns {import('esbuild').BuildOptions}
 */
export function viewerBuildOptions({ entry, outdir, entryName, minify, workerSource, sourcemap }) {
  return {
    entryPoints: { [entryName]: entry },
    outdir,
    bundle: true,
    format: 'iife',
    platform: 'browser',
    target: TARGET,
    minify,
    sourcemap,
    legalComments: 'none',
    banner: minify ? { js: BANNER, css: BANNER } : {},
    loader: { ...ASSET_LOADERS },
    // Deterministic: no content hashes, stable entry names.
    entryNames: '[name]',
    assetNames: '[name]',
    chunkNames: '[name]',
    metafile: true,
    plugins: [inlineWorkerPlugin(workerSource)],
    logLevel: 'warning',
    absWorkingDir: projectRoot,
  };
}

/** @param {number} bytes */
export function humanBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}
