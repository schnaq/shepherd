import { readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { relativeTime } from '../src/viewer/relativeTime.js';
import { resolveLanguage, SUPPORTED_LANGUAGES } from '../src/viewer/languageMap.js';

const srcDir = path.resolve(process.cwd(), 'src');

describe('resolveLanguage', () => {
  it('passes through every supported id unchanged', () => {
    for (const id of SUPPORTED_LANGUAGES) expect(resolveLanguage(id)).toBe(id);
  });

  it('covers the languages Shepherd promises to colourize', () => {
    const promised = [
      'swift',
      'typescript',
      'javascript',
      'python',
      'go',
      'rust',
      'ruby',
      'java',
      'kotlin',
      'c',
      'cpp',
      'csharp',
      'php',
      'html',
      'css',
      'json',
      'yaml',
      'toml',
      'markdown',
      'shell',
      'sql',
      'dockerfile',
      'graphql',
      'xml',
    ];
    for (const id of promised) expect(SUPPORTED_LANGUAGES).toContain(id);
  });

  it('normalises case and whitespace', () => {
    expect(resolveLanguage('  Swift ')).toBe('swift');
    expect(resolveLanguage('TypeScript')).toBe('typescript');
  });

  it('maps common aliases and extensions', () => {
    expect(resolveLanguage('ts')).toBe('typescript');
    expect(resolveLanguage('tsx')).toBe('typescript');
    expect(resolveLanguage('js')).toBe('javascript');
    expect(resolveLanguage('py')).toBe('python');
    expect(resolveLanguage('rs')).toBe('rust');
    expect(resolveLanguage('rb')).toBe('ruby');
    expect(resolveLanguage('kt')).toBe('kotlin');
    expect(resolveLanguage('c++')).toBe('cpp');
    expect(resolveLanguage('c#')).toBe('csharp');
    expect(resolveLanguage('yml')).toBe('yaml');
    expect(resolveLanguage('md')).toBe('markdown');
    expect(resolveLanguage('bash')).toBe('shell');
    expect(resolveLanguage('zsh')).toBe('shell');
    expect(resolveLanguage('objc')).toBe('objective-c');
    expect(resolveLanguage('scss')).toBe('css');
  });

  it('degrades to plaintext instead of breaking colourization', () => {
    expect(resolveLanguage('')).toBe('plaintext');
    expect(resolveLanguage('   ')).toBe('plaintext');
    expect(resolveLanguage('brainfuck')).toBe('plaintext');
    expect(resolveLanguage('plaintext')).toBe('plaintext');
    expect(resolveLanguage('txt')).toBe('plaintext');
  });

  it('never resolves to an id the bundle does not register', () => {
    const registered = new Set([...SUPPORTED_LANGUAGES, 'plaintext']);
    const probes = ['ts', 'py', 'c#', 'objc', 'scss', 'nonsense', '', 'GraphQL', 'Dockerfile'];
    for (const probe of probes) expect(registered).toContain(resolveLanguage(probe));
  });
});

describe('bundle hygiene', () => {
  it('imports monaco through editor.api, never editor.main (which drags in the language services)', () => {
    const languages = readFileSync(path.join(srcDir, 'viewer', 'languages.ts'), 'utf8');
    const viewer = readFileSync(path.join(srcDir, 'viewer', 'monacoViewer.ts'), 'utf8');
    for (const source of [languages, viewer]) {
      // Only *import specifiers* matter — the module docblocks name these on purpose.
      expect(source).not.toContain("'monaco-editor/editor/editor.main'");
      expect(source).not.toContain("'monaco-editor/languages/features/");
      expect(source).not.toContain("'monaco-editor'"); // the barrel would pull in everything
    }
    expect(languages).toContain("from 'monaco-editor/editor/editor.api'");
  });

  it('registers a Monarch contribution for every non-custom supported language', () => {
    const languages = readFileSync(path.join(srcDir, 'viewer', 'languages.ts'), 'utf8');
    const customGrammars = new Set(['json', 'toml']);
    // `cpp/register` registers both `c` and `cpp`.
    const viaCpp = new Set(['c', 'cpp']);
    for (const id of SUPPORTED_LANGUAGES) {
      if (customGrammars.has(id)) {
        expect(languages).toContain(`monaco.languages.setMonarchTokensProvider('${id}'`);
        continue;
      }
      const module = viaCpp.has(id) ? 'cpp' : id;
      expect(languages, `${id} has no register import`).toContain(`languages/definitions/${module}/register`);
    }
  });
});

// Kept next to the language tests: both are "small pure helpers the viewer leans on".
describe('relativeTime', () => {
  const now = Date.parse('2026-08-30T12:00:00Z');

  it('formats each bucket', () => {
    expect(relativeTime('2026-08-30T11:59:40Z', now)).toBe('just now');
    expect(relativeTime('2026-08-30T11:45:00Z', now)).toBe('15m ago');
    expect(relativeTime('2026-08-30T09:00:00Z', now)).toBe('3h ago');
    expect(relativeTime('2026-08-28T12:00:00Z', now)).toBe('2d ago');
    expect(relativeTime('2026-08-09T12:00:00Z', now)).toBe('3w ago');
    expect(relativeTime('2024-08-30T12:00:00Z', now)).toBe('2y ago');
  });

  it('treats clock skew from the future as "just now"', () => {
    expect(relativeTime('2026-09-01T12:00:00Z', now)).toBe('just now');
  });

  it('echoes an unparseable timestamp rather than showing NaN', () => {
    expect(relativeTime('not a date', now)).toBe('not a date');
  });
});
