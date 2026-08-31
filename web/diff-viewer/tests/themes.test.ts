import { describe, expect, it } from 'vitest';

import { clampFontSize, documentThemeClass, THEME_IDS, THEMES, themeIdFor } from '../src/viewer/themes.js';

describe('theme selection', () => {
  it('maps the bridge theme names onto the registered Monaco ids', () => {
    expect(themeIdFor('light')).toBe(THEME_IDS.light);
    expect(themeIdFor('dark')).toBe(THEME_IDS.dark);
  });

  it('falls back to light for anything else', () => {
    expect(themeIdFor('solarized')).toBe(THEME_IDS.light);
    expect(themeIdFor('')).toBe(THEME_IDS.light);
  });

  it('mirrors the theme onto a document class for the thread cards', () => {
    expect(documentThemeClass('dark')).toBe('shepherd-theme-dark');
    expect(documentThemeClass('light')).toBe('shepherd-theme-light');
    expect(documentThemeClass('nonsense')).toBe('shepherd-theme-light');
  });
});

describe('theme data', () => {
  it('inherits from the right Monaco base', () => {
    expect(THEMES.light.base).toBe('vs');
    expect(THEMES.dark.base).toBe('vs-dark');
    expect(THEMES.light.inherit).toBe(true);
    expect(THEMES.dark.inherit).toBe(true);
  });

  it('defines the diff washes both themes need', () => {
    const required = [
      'editor.background',
      'editor.foreground',
      'diffEditor.insertedLineBackground',
      'diffEditor.insertedTextBackground',
      'diffEditor.removedLineBackground',
      'diffEditor.removedTextBackground',
      'editorLineNumber.foreground',
    ];
    for (const theme of [THEMES.light, THEMES.dark]) {
      for (const key of required) {
        expect(Object.keys(theme.colors)).toContain(key);
        expect(theme.colors[key]).toMatch(/^#[0-9a-f]{6}([0-9a-f]{2})?$/i);
      }
    }
  });

  it('keeps the two palettes distinct', () => {
    expect(THEMES.light.colors['editor.background']).not.toBe(THEMES.dark.colors['editor.background']);
    expect(THEMES.light.colors['diffEditor.insertedLineBackground']).not.toBe(
      THEMES.dark.colors['diffEditor.insertedLineBackground'],
    );
  });

  it('covers the same token scopes in both themes with 6-digit colours', () => {
    const scopes = (rules: readonly { token: string }[]): string[] => rules.map((r) => r.token).sort();
    expect(scopes(THEMES.light.rules)).toEqual(scopes(THEMES.dark.rules));
    for (const theme of [THEMES.light, THEMES.dark]) {
      for (const rule of theme.rules) {
        expect(rule.foreground).toMatch(/^[0-9a-f]{6}$/i);
      }
    }
  });

  it('colours the scopes the Monarch grammars actually emit', () => {
    const scopes = new Set(THEMES.light.rules.map((r) => r.token));
    for (const scope of ['comment', 'keyword', 'string', 'number', 'type', 'tag', 'attribute.name', 'key', 'string.key.json']) {
      expect(scopes).toContain(scope);
    }
  });
});

describe('clampFontSize', () => {
  it('rounds and clamps into a sane range', () => {
    expect(clampFontSize(13)).toBe(13);
    expect(clampFontSize(12.4)).toBe(12);
    expect(clampFontSize(12.6)).toBe(13);
    expect(clampFontSize(2)).toBe(8);
    expect(clampFontSize(120)).toBe(32);
  });

  it('has a defined answer for non-finite input', () => {
    expect(clampFontSize(Number.NaN)).toBe(13);
    expect(clampFontSize(Number.POSITIVE_INFINITY)).toBe(13);
  });
});
