#!/usr/bin/env node
// Production build: emits ../../Shepherd/Resources/DiffViewer/dist (committed — see ADR 0003).
//
//   dist/index.html         page shell + CSP, loads the two siblings by relative path
//   dist/viewer.js          the whole viewer: Monaco core + Monarch grammars + bridge
//   dist/viewer.css         Monaco's CSS + Shepherd's thread-zone chrome, fonts inlined
//   dist/editor.worker.js   Monaco's editor worker (also inlined into viewer.js as a blob)
//   dist/nls/de.js          Monaco's German UI strings, injected by the app on a German Mac
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

  await copyMonacoMessages();

  await report();
}

/**
 * Monaco's own UI strings in the languages the app ships besides English (ADR 0022's second
 * amendment).
 *
 * Each file is Monaco's message table for *this* Monaco version — a classic script that sets
 * `globalThis._VSCODE_NLS_MESSAGES`, indexed exactly as the numeric `localize(…)` calls in the
 * ESM build the viewer bundles, which is why it is copied from `esm/` and never from `min/`.
 * Nothing in the page loads it: Monaco reads the table while its modules evaluate, before the
 * bridge exists, so the app injects the file as a document-start user script when it is German
 * (`DiffViewerView.monacoMessages(for:)`).
 */
const MONACO_MESSAGE_LANGUAGES = ['de'];

async function copyMonacoMessages() {
  const target = path.join(distDir, 'nls');
  await mkdir(target, { recursive: true });
  for (const language of MONACO_MESSAGE_LANGUAGES) {
    const source = path.join(projectRoot, 'node_modules', 'monaco-editor', 'esm', 'vs', 'nls', 'lang', `${language}.js`);
    await writeFile(path.join(target, `${language}.js`), await readFile(source, 'utf8'), 'utf8');
  }
}

async function report() {
  const names = [
    ...(await readdir(distDir)).filter((name) => name !== 'nls'),
    ...MONACO_MESSAGE_LANGUAGES.map((language) => path.join('nls', `${language}.js`)),
  ].sort();
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
