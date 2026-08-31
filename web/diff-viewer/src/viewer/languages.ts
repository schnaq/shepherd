/**
 * Language registration.
 *
 * With plain `monaco-editor/editor/editor.api` imports **no language is registered at all** —
 * `editor.api` ships the editor core, the standalone theme service and the Monarch plumbing,
 * but the tokenizers live in `monaco-editor/languages/definitions/<lang>/register.js` and are
 * only pulled in by `editor.main` (which also drags in every language *service*, its four web
 * workers and the LSP client). Shepherd only ever displays diffs, so we import the Monarch
 * `register.js` contributions we care about — and nothing from `languages/features/*`, which
 * is where the typescript/json/css/html workers would come from.
 *
 * Each `register.js` registers the language id plus a *lazy* tokenizer factory; the grammar
 * module is reached through a dynamic `import()` that esbuild inlines into the single IIFE
 * bundle, so there is still exactly one JS file and zero network access at runtime.
 *
 * Monaco 0.56 has no Monarch grammar for JSON (its JSON colouring comes from the JSON language
 * service) and none for TOML at all, so both are defined in `extraLanguages.ts`.
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

export { resolveLanguage, SUPPORTED_LANGUAGES } from './languageMap.js';

let registered = false;

/** Registers the languages monaco-editor does not ship a Monarch grammar for. Idempotent. */
export function registerLanguages(): void {
  if (registered) return;
  registered = true;

  monaco.languages.register({
    id: 'json',
    extensions: ['.json', '.jsonc'],
    aliases: ['JSON', 'json'],
    mimetypes: ['application/json'],
  });
  monaco.languages.setLanguageConfiguration('json', jsonLanguage.conf);
  monaco.languages.setMonarchTokensProvider('json', jsonLanguage.language);

  monaco.languages.register({
    id: 'toml',
    extensions: ['.toml'],
    aliases: ['TOML', 'toml'],
    mimetypes: ['text/x-toml'],
  });
  monaco.languages.setLanguageConfiguration('toml', tomlLanguage.conf);
  monaco.languages.setMonarchTokensProvider('toml', tomlLanguage.language);
}
