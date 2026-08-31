/**
 * Language registration.
 *
 * With plain `monaco-editor/editor/editor.api` imports **no language is registered at all** —
 * `editor.api` ships the editor core, the standalone theme service and the Monarch plumbing,
 * but the tokenizers live in `monaco-editor/languages/definitions/<lang>/register.js` and are
 * only pulled in by `editor.main` (which also drags in every language *service*, its four web
 * workers and the LSP client). Shepherd only ever displays diffs, so we import the Monarch
 * `register.js` contributions we care about — nothing from `languages/features/*`, which is
 * where the typescript/json/css/html workers would come from.
 *
 * Each `register.js` registers the language id and a *lazy* tokenizer factory; the tokenizer
 * module is loaded through a dynamic `import()` that esbuild inlines into the single IIFE
 * bundle, so there is still exactly one JS file and zero network access at runtime.
 *
 * Monaco 0.56 has no Monarch grammar for JSON (its JSON colouring comes from the JSON language
 * service) and none for TOML at all, so both are defined here.
 */

import * as monaco from 'monaco-editor/editor/editor.api';

// -- Monarch contributions from monaco-editor (Shepherd's supported set) ----------------------
import 'monaco-editor/languages/definitions/cpp/register'; // registers both `c` and `cpp`
import 'monaco-editor/languages/definitions/csharp/register';
import 'monaco-editor/languages/definitions/css/register';
import 'monaco-editor/languages/definitions/dockerfile/register';
import 'monaco-editor/languages/definitions/go/register';
import 'monaco-editor/languages/definitions/graphql/register';
import 'monaco-editor/languages/definitions/html/register';
import 'monaco-editor/languages/definitions/java/register';
import 'monaco-editor/languages/definitions/javascript/register';
import 'monaco-editor/languages/definitions/kotlin/register';
import 'monaco-editor/languages/definitions/markdown/register';
import 'monaco-editor/languages/definitions/objective-c/register';
import 'monaco-editor/languages/definitions/php/register';
import 'monaco-editor/languages/definitions/python/register';
import 'monaco-editor/languages/definitions/ruby/register';
import 'monaco-editor/languages/definitions/rust/register';
import 'monaco-editor/languages/definitions/shell/register';
import 'monaco-editor/languages/definitions/sql/register';
import 'monaco-editor/languages/definitions/swift/register';
import 'monaco-editor/languages/definitions/typescript/register';
import 'monaco-editor/languages/definitions/xml/register';
import 'monaco-editor/languages/definitions/yaml/register';

import { jsonLanguage, tomlLanguage } from './extraLanguages.js';

/** Every language id the bundle can colourize (plus the always-present `plaintext`). */
export const SUPPORTED_LANGUAGES: readonly string[] = [
  'c',
  'cpp',
  'csharp',
  'css',
  'dockerfile',
  'go',
  'graphql',
  'html',
  'java',
  'javascript',
  'json',
  'kotlin',
  'markdown',
  'objective-c',
  'php',
  'python',
  'ruby',
  'rust',
  'shell',
  'sql',
  'swift',
  'toml',
  'typescript',
  'xml',
  'yaml',
];

let registered = false;

export function registerLanguages(): void {
  if (registered) return;
  registered = true;

  monaco.languages.register({ id: 'json', extensions: ['.json', '.jsonc'], aliases: ['JSON', 'json'], mimetypes: ['application/json'] });
  monaco.languages.setLanguageConfiguration('json', jsonLanguage.conf);
  monaco.languages.setMonarchTokensProvider('json', jsonLanguage.language);

  monaco.languages.register({ id: 'toml', extensions: ['.toml'], aliases: ['TOML', 'toml'], mimetypes: ['text/x-toml'] });
  monaco.languages.setLanguageConfiguration('toml', tomlLanguage.conf);
  monaco.languages.setMonarchTokensProvider('toml', tomlLanguage.language);
}

/**
 * Maps whatever Swift sends to a language id Monaco actually knows. Swift is expected to send
 * a Monaco id already; this is the safety net that keeps an unknown id from silently killing
 * colourization for the whole file.
 */
export function resolveLanguage(language: string): string {
  const id = language.trim().toLowerCase();
  if (id.length === 0) return 'plaintext';
  if (SUPPORTED_LANGUAGES.includes(id)) return id;
  const alias = LANGUAGE_ALIASES[id];
  return alias ?? 'plaintext';
}

const LANGUAGE_ALIASES: Readonly<Record<string, string>> = {
  bash: 'shell',
  'c++': 'cpp',
  'c#': 'csharp',
  cc: 'cpp',
  cs: 'csharp',
  'docker': 'dockerfile',
  gql: 'graphql',
  h: 'c',
  hpp: 'cpp',
  htm: 'html',
  js: 'javascript',
  jsonc: 'json',
  jsx: 'javascript',
  kt: 'kotlin',
  md: 'markdown',
  mdown: 'markdown',
  'obj-c': 'objective-c',
  objc: 'objective-c',
  plain: 'plaintext',
  plaintext: 'plaintext',
  py: 'python',
  rb: 'ruby',
  rs: 'rust',
  sh: 'shell',
  swiftui: 'swift',
  text: 'plaintext',
  ts: 'typescript',
  tsx: 'typescript',
  txt: 'plaintext',
  yml: 'yaml',
  zsh: 'shell',
};
