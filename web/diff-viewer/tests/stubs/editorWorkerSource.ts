/**
 * Stands in for the `virtual:editor-worker-source` module that `scripts/build-support.mjs`
 * generates. Aliased in `vitest.config.ts` so `src/viewer/workerEnvironment.ts` is testable
 * without running a real esbuild pass.
 */
export default 'self.onmessage=function(){/* stub monaco editor worker */};';
