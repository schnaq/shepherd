/**
 * Two custom Monaco themes tuned to sit next to a native macOS review UI (GitHub/Linear-ish):
 * quiet chrome, subtle diff line washes, punchy word-level highlights, high text contrast.
 *
 * Pure data + a selector — no Monaco import at runtime, so this is unit-testable. The viewer
 * registers them once at boot via `monaco.editor.defineTheme`.
 */

import type { editor } from 'monaco-editor';
import type { ThemeName } from '../bridge/protocol.js';

export const THEME_IDS: Readonly<Record<ThemeName, string>> = {
  light: 'shepherd-light',
  dark: 'shepherd-dark',
};

const lightTokens: editor.ITokenThemeRule[] = [
  { token: '', foreground: '1f2328' },
  { token: 'comment', foreground: '6e7781', fontStyle: 'italic' },
  { token: 'keyword', foreground: 'cf222e' },
  { token: 'keyword.json', foreground: '0550ae' },
  { token: 'operator', foreground: 'cf222e' },
  { token: 'string', foreground: '0a3069' },
  { token: 'string.key.json', foreground: '0550ae' },
  { token: 'string.escape', foreground: '0550ae' },
  { token: 'regexp', foreground: '0a3069' },
  { token: 'number', foreground: '0550ae' },
  { token: 'constant', foreground: '0550ae' },
  { token: 'type', foreground: '953800' },
  { token: 'type.identifier', foreground: '953800' },
  { token: 'namespace', foreground: '953800' },
  { token: 'annotation', foreground: '8250df' },
  { token: 'metatag', foreground: '8250df' },
  { token: 'attribute.name', foreground: '0550ae' },
  { token: 'attribute.value', foreground: '0a3069' },
  { token: 'tag', foreground: '116329' },
  { token: 'key', foreground: '0550ae' },
  { token: 'identifier', foreground: '1f2328' },
  { token: 'delimiter', foreground: '57606a' },
  { token: 'invalid', foreground: 'ffffff', background: 'cf222e' },
];

const darkTokens: editor.ITokenThemeRule[] = [
  { token: '', foreground: 'e6edf3' },
  { token: 'comment', foreground: '8b949e', fontStyle: 'italic' },
  { token: 'keyword', foreground: 'ff7b72' },
  { token: 'keyword.json', foreground: '79c0ff' },
  { token: 'operator', foreground: 'ff7b72' },
  { token: 'string', foreground: 'a5d6ff' },
  { token: 'string.key.json', foreground: '79c0ff' },
  { token: 'string.escape', foreground: '79c0ff' },
  { token: 'regexp', foreground: 'a5d6ff' },
  { token: 'number', foreground: '79c0ff' },
  { token: 'constant', foreground: '79c0ff' },
  { token: 'type', foreground: 'ffa657' },
  { token: 'type.identifier', foreground: 'ffa657' },
  { token: 'namespace', foreground: 'ffa657' },
  { token: 'annotation', foreground: 'd2a8ff' },
  { token: 'metatag', foreground: 'd2a8ff' },
  { token: 'attribute.name', foreground: '79c0ff' },
  { token: 'attribute.value', foreground: 'a5d6ff' },
  { token: 'tag', foreground: '7ee787' },
  { token: 'key', foreground: '79c0ff' },
  { token: 'identifier', foreground: 'e6edf3' },
  { token: 'delimiter', foreground: '8b949e' },
  { token: 'invalid', foreground: '0d1117', background: 'ff7b72' },
];

const lightColors: Readonly<Record<string, string>> = {
  'editor.background': '#ffffff',
  'editor.foreground': '#1f2328',
  'editor.lineHighlightBackground': '#f6f8fa',
  'editor.lineHighlightBorder': '#00000000',
  'editor.selectionBackground': '#0969da26',
  'editor.inactiveSelectionBackground': '#0969da14',
  'editorCursor.foreground': '#0969da',
  'editorLineNumber.foreground': '#8c959f',
  'editorLineNumber.activeForeground': '#1f2328',
  'editorGutter.background': '#ffffff',
  'editorIndentGuide.background1': '#eaeef2',
  'editorIndentGuide.activeBackground1': '#d0d7de',
  'editorWhitespace.foreground': '#d8dee4',
  'editorWidget.background': '#ffffff',
  'editorWidget.border': '#d0d7de',
  'scrollbarSlider.background': '#8c959f33',
  'scrollbarSlider.hoverBackground': '#8c959f55',
  'scrollbarSlider.activeBackground': '#8c959f77',
  'diffEditor.insertedLineBackground': '#e6ffec',
  'diffEditor.insertedTextBackground': '#abf2bc80',
  'diffEditor.removedLineBackground': '#ffebe9',
  'diffEditor.removedTextBackground': '#ff818266',
  'diffEditor.border': '#d8dee4',
  'diffEditorGutter.insertedLineBackground': '#ccffd8',
  'diffEditorGutter.removedLineBackground': '#ffd7d5',
  'diffEditorOverview.insertedForeground': '#2da44e80',
  'diffEditorOverview.removedForeground': '#cf222e80',
  // The folded-region bar (`hideUnchangedRegions`), quieter than a diff wash: it is chrome
  // between hunks, not a change.
  'diffEditor.unchangedRegionBackground': '#f6f8fa',
  'diffEditor.unchangedRegionForeground': '#57606a',
  'diffEditor.unchangedRegionShadow': '#1f232814',
  'diffEditor.unchangedCodeBackground': '#ffffff',
  'editorOverviewRuler.border': '#00000000',
  'editorOverviewRuler.background': '#ffffff',
};

const darkColors: Readonly<Record<string, string>> = {
  'editor.background': '#0d1117',
  'editor.foreground': '#e6edf3',
  'editor.lineHighlightBackground': '#161b22',
  'editor.lineHighlightBorder': '#00000000',
  'editor.selectionBackground': '#388bfd44',
  'editor.inactiveSelectionBackground': '#388bfd26',
  'editorCursor.foreground': '#58a6ff',
  'editorLineNumber.foreground': '#6e7681',
  'editorLineNumber.activeForeground': '#e6edf3',
  'editorGutter.background': '#0d1117',
  'editorIndentGuide.background1': '#21262d',
  'editorIndentGuide.activeBackground1': '#30363d',
  'editorWhitespace.foreground': '#484f58',
  'editorWidget.background': '#161b22',
  'editorWidget.border': '#30363d',
  'scrollbarSlider.background': '#6e768133',
  'scrollbarSlider.hoverBackground': '#6e768155',
  'scrollbarSlider.activeBackground': '#6e768177',
  'diffEditor.insertedLineBackground': '#2ea04326',
  'diffEditor.insertedTextBackground': '#2ea04366',
  'diffEditor.removedLineBackground': '#f8514926',
  'diffEditor.removedTextBackground': '#f8514966',
  'diffEditor.border': '#30363d',
  'diffEditorGutter.insertedLineBackground': '#2ea04340',
  'diffEditorGutter.removedLineBackground': '#f8514940',
  'diffEditorOverview.insertedForeground': '#3fb95080',
  'diffEditorOverview.removedForeground': '#f8514980',
  // The folded-region bar (`hideUnchangedRegions`), quieter than a diff wash: it is chrome
  // between hunks, not a change.
  'diffEditor.unchangedRegionBackground': '#161b22',
  'diffEditor.unchangedRegionForeground': '#8b949e',
  'diffEditor.unchangedRegionShadow': '#01040933',
  'diffEditor.unchangedCodeBackground': '#0d1117',
  'editorOverviewRuler.border': '#00000000',
  'editorOverviewRuler.background': '#0d1117',
};

export const THEMES: Readonly<Record<ThemeName, editor.IStandaloneThemeData>> = {
  light: { base: 'vs', inherit: true, rules: lightTokens, colors: { ...lightColors } },
  dark: { base: 'vs-dark', inherit: true, rules: darkTokens, colors: { ...darkColors } },
};

/** Monaco theme id for a bridge theme name. Unknown values fall back to light. */
export function themeIdFor(theme: ThemeName | string): string {
  return theme === 'dark' ? THEME_IDS.dark : THEME_IDS.light;
}

/** CSS class put on `<html>` so the thread cards follow the editor theme. */
export function documentThemeClass(theme: ThemeName | string): string {
  return theme === 'dark' ? 'shepherd-theme-dark' : 'shepherd-theme-light';
}

/** Clamped font size — Swift sends the user's preference, we keep Monaco in a sane range. */
export function clampFontSize(fontSize: number): number {
  if (!Number.isFinite(fontSize)) return 13;
  return Math.min(32, Math.max(8, Math.round(fontSize)));
}
