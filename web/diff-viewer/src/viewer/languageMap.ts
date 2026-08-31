/**
 * Language id resolution — pure, Monaco-free, unit-tested.
 *
 * The set below is exactly what `src/viewer/languages.ts` registers. Swift is expected to send
 * a Monaco language id already; the aliases are the safety net that keeps a slightly-off id
 * (`"ts"`, `"c++"`, a file extension) from silently killing colourization for a whole file.
 */

/** Every language id the bundle can colourize, besides the always-present `plaintext`. */
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

const LANGUAGE_ALIASES: Readonly<Record<string, string>> = {
  bash: 'shell',
  'c#': 'csharp',
  'c++': 'cpp',
  cc: 'cpp',
  cs: 'csharp',
  docker: 'dockerfile',
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
  objectivec: 'objective-c',
  plain: 'plaintext',
  plaintext: 'plaintext',
  py: 'python',
  rb: 'ruby',
  rs: 'rust',
  scss: 'css',
  sh: 'shell',
  swiftui: 'swift',
  text: 'plaintext',
  ts: 'typescript',
  tsx: 'typescript',
  txt: 'plaintext',
  yml: 'yaml',
  zsh: 'shell',
};

/** Maps whatever Swift sends onto a language id Monaco actually knows. */
export function resolveLanguage(language: string): string {
  const id = language.trim().toLowerCase();
  if (id.length === 0) return 'plaintext';
  if (SUPPORTED_LANGUAGES.includes(id)) return id;
  return LANGUAGE_ALIASES[id] ?? 'plaintext';
}
