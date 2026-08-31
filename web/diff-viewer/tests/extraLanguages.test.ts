import { describe, expect, it } from 'vitest';

import { jsonLanguage, tomlLanguage } from '../src/viewer/extraLanguages.js';

type Rule = readonly [RegExp | string, unknown] | readonly [RegExp | string, unknown, string] | { include: string };

function rules(language: typeof jsonLanguage, state: string): Rule[] {
  const tokenizer = language.language.tokenizer as Record<string, Rule[] | undefined>;
  const found = tokenizer[state];
  expect(found, `missing tokenizer state @${state}`).toBeDefined();
  return found ?? [];
}

/** Naive Monarch driver: first matching rule at position 0 wins, like Monaco's. */
function firstToken(language: typeof jsonLanguage, line: string): string | null {
  for (const rule of rules(language, 'root')) {
    if (!Array.isArray(rule)) continue;
    const [pattern, action] = rule as readonly [RegExp | string, unknown];
    const regex = new RegExp(`^(?:${pattern instanceof RegExp ? pattern.source : String(pattern)})`);
    const match = regex.exec(line);
    if (match === null || match[0].length === 0) continue;
    if (typeof action === 'string') return action;
    if (typeof action === 'object' && action !== null && 'token' in action) return String((action as { token: unknown }).token);
    if (Array.isArray(action)) return String(action.find((a) => a !== '') ?? '');
    return null;
  }
  return null;
}

describe('bundled JSON grammar (monaco ships none without the JSON language service)', () => {
  it('declares the states it jumps to', () => {
    for (const state of ['root', 'string', 'whitespace', 'comment']) {
      expect(rules(jsonLanguage, state).length).toBeGreaterThan(0);
    }
  });

  it('tells object keys apart from string values', () => {
    expect(firstToken(jsonLanguage, '"name": "shepherd"')).toBe('string.key.json');
    expect(firstToken(jsonLanguage, '"shepherd"')).toBe('string.quote');
  });

  it('colours literals and numbers', () => {
    expect(firstToken(jsonLanguage, 'true')).toBe('keyword.json');
    expect(firstToken(jsonLanguage, 'null')).toBe('keyword.json');
    expect(firstToken(jsonLanguage, '-12.5e3')).toBe('number');
  });

  it('uses a language configuration with brackets', () => {
    expect(jsonLanguage.conf.brackets).toEqual([
      ['{', '}'],
      ['[', ']'],
    ]);
  });
});

describe('bundled TOML grammar (monaco has none at all)', () => {
  it('colours comments, tables, keys and values', () => {
    expect(firstToken(tomlLanguage, '# a comment')).toBe('comment');
    expect(firstToken(tomlLanguage, '[package]')).toBe('type');
    expect(firstToken(tomlLanguage, '[[bin]]')).toBe('type');
    expect(firstToken(tomlLanguage, 'name = "shepherd"')).toBe('key');
    expect(firstToken(tomlLanguage, 'edition = 2021')).toBe('key');
  });

  it('recognises booleans and dates as values', () => {
    expect(firstToken(tomlLanguage, 'true')).toBe('keyword');
    expect(firstToken(tomlLanguage, '2026-08-30T12:00:00Z')).toBe('number');
    expect(firstToken(tomlLanguage, '0xdead_beef')).toBe('number');
  });

  it('declares its string states', () => {
    for (const state of ['basicString', 'literalString', 'basicMultiline', 'literalMultiline']) {
      expect(rules(tomlLanguage, state).length).toBeGreaterThan(0);
    }
  });

  it('uses "#" for line comments', () => {
    expect(tomlLanguage.conf.comments?.lineComment).toBe('#');
  });
});
