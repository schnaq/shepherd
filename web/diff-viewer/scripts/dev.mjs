#!/usr/bin/env node
// `npm run dev` — standalone browser harness.
//
// Serves src/dev/index.html with the real viewer, the real bridge and the real fixtures, but
// with the native side stubbed: outbound messages land in an on-page log instead of
// `window.webkit.messageHandlers.shepherd`. Open the printed URL and click around.
//
// Output goes to .cache/dev (git-ignored); `dist/` is never touched by this script.

import { copyFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';

import esbuild from 'esbuild';

import { buildEditorWorkerSource, projectRoot, viewerBuildOptions } from './build-support.mjs';

const outdir = path.join(projectRoot, '.cache', 'dev');
const host = process.env['SHEPHERD_DEV_HOST'] ?? '127.0.0.1';
const port = Number(process.env['SHEPHERD_DEV_PORT'] ?? 5173);

const copyHTMLPlugin = {
  name: 'shepherd-copy-harness-html',
  setup(build) {
    build.onEnd(async () => {
      await copyFile(path.join(projectRoot, 'src', 'dev', 'index.html'), path.join(outdir, 'index.html'));
    });
  },
};

async function main() {
  await rm(outdir, { recursive: true, force: true });
  await mkdir(outdir, { recursive: true });

  // Unminified worker so stack traces from the diff computation stay readable.
  const workerSource = await buildEditorWorkerSource({ minify: false });

  const options = viewerBuildOptions({
    entry: path.join(projectRoot, 'src', 'dev', 'harness.ts'),
    outdir,
    entryName: 'harness',
    minify: false,
    sourcemap: true,
    workerSource,
  });
  options.plugins = [...(options.plugins ?? []), copyHTMLPlugin];
  options.logLevel = 'info';

  const ctx = await esbuild.context(options);
  await ctx.watch();
  const server = await ctx.serve({ servedir: outdir, host, port });

  const shown = server.hosts.includes(host) ? host : (server.hosts[0] ?? host);
  console.log(`\n  Shepherd diff-viewer harness → http://${shown}:${server.port}/\n`);
  console.log('  Rebuilds on save. Ctrl-C to stop.\n');
}

await main();
