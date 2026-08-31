/**
 * Monarch grammars monaco-editor does not ship as a basic language.
 *
 * - **JSON**: monaco colours JSON through its JSON *language service* (a web worker plus
 *   `jsonc-parser`). Shepherd only displays diffs, so the whole service is disabled and this
 *   small Monarch grammar provides the colours instead.
 * - **TOML**: monaco has no TOML grammar at all, and Shepherd reviews plenty of
 *   `Cargo.toml`/`pyproject.toml` diffs.
 */

import type { languages } from 'monaco-editor';

export interface LanguageDefinition {
  readonly conf: languages.LanguageConfiguration;
  readonly language: languages.IMonarchLanguage;
}

const jsonConf: languages.LanguageConfiguration = {
  comments: { lineComment: '//', blockComment: ['/*', '*/'] },
  brackets: [
    ['{', '}'],
    ['[', ']'],
  ],
  autoClosingPairs: [
    { open: '{', close: '}' },
    { open: '[', close: ']' },
    { open: '"', close: '"', notIn: ['string'] },
  ],
};

const jsonMonarch: languages.IMonarchLanguage = {
  defaultToken: '',
  tokenPostfix: '.json',
  tokenizer: {
    root: [
      // A quoted string immediately followed by a colon is an object key.
      [/"(?:[^"\\]|\\.)*"(?=\s*:)/, 'string.key.json'],
      [/"/, { token: 'string.quote', bracket: '@open', next: '@string' }],
      [/\b(?:true|false|null)\b/, 'keyword.json'],
      [/-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][-+]?\d+)?/, 'number'],
      [/[{}[\]]/, '@brackets'],
      [/[,:]/, 'delimiter'],
      { include: '@whitespace' },
    ],
    string: [
      [/[^\\"]+/, 'string'],
      [/\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4})/, 'string.escape'],
      [/\\./, 'string.escape.invalid'],
      [/"/, { token: 'string.quote', bracket: '@close', next: '@pop' }],
    ],
    whitespace: [
      [/[ \t\r\n]+/, ''],
      [/\/\*/, 'comment', '@comment'],
      [/\/\/.*$/, 'comment'],
    ],
    comment: [
      [/[^/*]+/, 'comment'],
      [/\*\//, 'comment', '@pop'],
      [/[/*]/, 'comment'],
    ],
  },
};

export const jsonLanguage: LanguageDefinition = { conf: jsonConf, language: jsonMonarch };

const tomlConf: languages.LanguageConfiguration = {
  comments: { lineComment: '#' },
  brackets: [
    ['{', '}'],
    ['[', ']'],
  ],
  autoClosingPairs: [
    { open: '{', close: '}' },
    { open: '[', close: ']' },
    { open: '"', close: '"', notIn: ['string'] },
    { open: "'", close: "'", notIn: ['string'] },
  ],
};

const tomlMonarch: languages.IMonarchLanguage = {
  defaultToken: '',
  tokenPostfix: '.toml',
  tokenizer: {
    root: [
      [/#.*$/, 'comment'],
      // [[array.of.tables]] and [table.name]
      [/^\s*\[\[.*?\]\]/, 'type'],
      [/^\s*\[.*?\]/, 'type'],
      // bare / quoted keys before '='
      [/(^\s*)([A-Za-z0-9_.-]+)(\s*)(=)/, ['', 'key', '', 'delimiter']],
      [/(^\s*)("(?:[^"\\]|\\.)*")(\s*)(=)/, ['', 'key', '', 'delimiter']],
      [/'''/, { token: 'string', next: '@literalMultiline' }],
      [/"""/, { token: 'string', next: '@basicMultiline' }],
      [/'/, { token: 'string', next: '@literalString' }],
      [/"/, { token: 'string', next: '@basicString' }],
      [/\b(?:true|false)\b/, 'keyword'],
      // RFC 3339 date / date-time / time
      [/\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[-+]\d{2}:\d{2})?)?/, 'number'],
      [/\d{2}:\d{2}:\d{2}(?:\.\d+)?/, 'number'],
      [/[-+]?(?:inf|nan)\b/, 'number'],
      [/0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+/, 'number'],
      [/[-+]?\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d[\d_]*)?/, 'number'],
      [/[{}[\]]/, '@brackets'],
      [/[,=]/, 'delimiter'],
      [/[ \t\r\n]+/, ''],
    ],
    basicString: [
      [/[^\\"]+/, 'string'],
      [/\\(?:[btnfr"\\]|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})/, 'string.escape'],
      [/\\./, 'string.escape.invalid'],
      [/"/, { token: 'string', next: '@pop' }],
    ],
    literalString: [
      [/[^']+/, 'string'],
      [/'/, { token: 'string', next: '@pop' }],
    ],
    basicMultiline: [
      [/[^\\"]+/, 'string'],
      [/\\(?:[btnfr"\\]|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})/, 'string.escape'],
      [/"""/, { token: 'string', next: '@pop' }],
      [/["\\]/, 'string'],
    ],
    literalMultiline: [
      [/[^']+/, 'string'],
      [/'''/, { token: 'string', next: '@pop' }],
      [/'/, 'string'],
    ],
  },
};

export const tomlLanguage: LanguageDefinition = { conf: tomlConf, language: tomlMonarch };
