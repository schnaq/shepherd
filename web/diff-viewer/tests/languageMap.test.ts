import { readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { canonicalLocale, commentCount, DEFAULT_LOCALE, ENGLISH_STRINGS, makeLocale } from '../src/viewer/locale.js';
import { absoluteTime, relativeTime } from '../src/viewer/relativeTime.js';
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

  it('keeps the compact English when the app says English', () => {
    expect(relativeTime('2026-08-30T09:00:00Z', now, 'en')).toBe('3h ago');
    expect(relativeTime('2026-08-30T11:59:40Z', now, 'en-GB')).toBe('just now');
  });

  it('formats each bucket in German through Intl', () => {
    expect(relativeTime('2026-08-30T11:59:40Z', now, 'de')).toBe('jetzt');
    expect(relativeTime('2026-08-30T11:45:00Z', now, 'de')).toBe('vor 15 Min.');
    expect(relativeTime('2026-08-30T09:00:00Z', now, 'de')).toBe('vor 3 Std.');
    // Elapsed time, not calendar days: no "gestern", "vorgestern" or "letzte Woche".
    expect(relativeTime('2026-08-29T12:00:00Z', now, 'de')).toBe('vor 1 Tag');
    expect(relativeTime('2026-08-28T12:00:00Z', now, 'de')).toBe('vor 2 Tagen');
    expect(relativeTime('2026-08-23T12:00:00Z', now, 'de')).toBe('vor 1 Woche');
    expect(relativeTime('2026-08-26T12:00:00Z', now, 'de')).toBe('vor 4 Tagen');
    expect(relativeTime('2026-08-09T12:00:00Z', now, 'de')).toBe('vor 3 Wochen');
    expect(relativeTime('2024-08-30T12:00:00Z', now, 'de')).toBe('vor 2 Jahren');
    expect(relativeTime('2026-09-01T12:00:00Z', now, 'de')).toBe('jetzt');
  });
});

describe('absoluteTime', () => {
  it('stays zone-independent UTC without a locale', () => {
    expect(absoluteTime('2026-08-30T09:00:00Z')).toBe('2026-08-30 09:00:00 UTC');
  });

  it('keeps the UTC form when the app says English, whatever the zone', () => {
    expect(absoluteTime('2026-08-30T09:00:00Z', 'en', 'Europe/Berlin')).toBe('2026-08-30 09:00:00 UTC');
    expect(absoluteTime('2026-08-30T09:00:00Z', 'en-GB')).toBe('2026-08-30 09:00:00 UTC');
  });

  it('follows the locale and the zone it is given', () => {
    expect(absoluteTime('2026-08-30T09:00:00Z', 'de', 'UTC')).toBe('30.08.2026, 09:00');
    expect(absoluteTime('2026-08-30T09:00:00Z', 'de', 'Europe/Berlin')).toBe('30.08.2026, 11:00');
  });
});

describe('the viewer locale', () => {
  it('accepts a language tag and refuses what Intl would throw on', () => {
    expect(canonicalLocale('de')).toBe('de');
    expect(canonicalLocale('de-DE')).toBe('de-DE');
    // `Locale.current.identifier` spelling, which `new Intl.RelativeTimeFormat` rejects.
    expect(canonicalLocale('de_DE')).toBeNull();
  });

  it('picks a whole phrase by the plural rules of the language', () => {
    const german = makeLocale('de', {
      ...ENGLISH_STRINGS,
      commentCount: { one: '1 Kommentar', other: '{count} Kommentare' },
    });
    expect(commentCount(1, german)).toBe('1 Kommentar');
    expect(commentCount(0, german)).toBe('0 Kommentare');
    expect(commentCount(12, german)).toBe('12 Kommentare');
    expect(commentCount(1, DEFAULT_LOCALE)).toBe('1 comment');
    expect(commentCount(3, DEFAULT_LOCALE)).toBe('3 comments');
  });

  it('falls back to English plurals and times for a tag Intl refuses', () => {
    const odd = makeLocale('de_DE', ENGLISH_STRINGS);
    expect(odd.locale).toBeNull();
    expect(commentCount(2, odd)).toBe('2 comments');
  });
});
