/**
 * Virtual modules provided by the esbuild build (`scripts/build-support.mjs`).
 *
 * `virtual:editor-worker-source` resolves to the minified IIFE source of Monaco's
 * `editor.worker`, loaded with esbuild's `text` loader so it can be turned into a `blob:`
 * worker at runtime (see `src/viewer/workerEnvironment.ts`).
 */
declare module 'virtual:editor-worker-source' {
  const source: string;
  export default source;
}
