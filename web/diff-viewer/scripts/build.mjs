#!/usr/bin/env node
// Production build: emits ../../Shepherd/Resources/DiffViewer/dist (committed — see ADR 0003).
//
//   dist/index.html         page shell + CSP, loads the two siblings by relative path
//   dist/viewer.js          the whole viewer: Monaco core + Monarch grammars + bridge
//   dist/viewer.css         Monaco's CSS + Shepherd's thread-zone chrome, fonts inlined
//   dist/editor.worker.js   Monaco's editor worker (also inlined into viewer.js as a blob)
//
// The "generated, do not edit" note lives one level up, in Resources/DiffViewer/README.md, so
// dist/ holds nothing but build artefacts (everything in it is copied into the .app bundle).
//
// The directory is wiped first so a rename can never leave a stale file behind, and nothing
// is hashed, so rebuilding the same source produces byte-identical output.

import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

import esbuild from 'esbuild';

import { buildEditorWorkerSource, distDir, humanBytes, projectRoot, viewerBuildOptions } from './build-support.mjs';

async function main() {
  await rm(distDir, { recursive: true, force: true });
  await mkdir(distDir, { recursive: true });

  const workerSource = await buildEditorWorkerSource({ minify: true });
  await writeFile(path.join(distDir, 'editor.worker.js'), workerSource, 'utf8');

  const result = await esbuild.build(
    viewerBuildOptions({
      entry: path.join(projectRoot, 'src', 'main.ts'),
      outdir: distDir,
      entryName: 'viewer',
      minify: true,
      sourcemap: false,
      workerSource,
    }),
  );

  if (result.errors.length > 0) process.exitCode = 1;

  const html = await readFile(path.join(projectRoot, 'src', 'index.html'), 'utf8');
  await writeFile(path.join(distDir, 'index.html'), html, 'utf8');

  await report();
}

async function report() {
  const names = (await readdir(distDir)).sort();
  let total = 0;
  const rows = [];
  for (const name of names) {
    const info = await stat(path.join(distDir, name));
    total += info.size;
    rows.push(`  ${name.padEnd(20)} ${humanBytes(info.size).padStart(10)}`);
  }
  console.log(`diff viewer → ${path.relative(path.join(projectRoot, '..', '..'), distDir)}`);
  console.log(rows.join('\n'));
  console.log(`  ${'total'.padEnd(20)} ${humanBytes(total).padStart(10)}`);
}

await main();
