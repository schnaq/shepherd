/**
 * `MonacoDiffViewer.loadFile` against a stand-in Monaco.
 *
 * The real editor cannot boot in jsdom, but the bug this covers is pure bookkeeping: model
 * URIs are derived from the file path, so re-loading the *same* path — which Swift does on
 * every wrap / inline toggle — used to hit Monaco's "Cannot add model because it already
 * exists!" because the previous models were disposed only *after* the new ones were created.
 *
 * The fake below reproduces exactly that one rule (a URI registry that throws on a duplicate)
 * and nothing else.
 */

import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { LoadFileMessage, Thread } from '../src/bridge/protocol.js';

// -- the stand-in ------------------------------------------------------------------------------

interface FakeModel {
  readonly uri: string;
  readonly value: string;
  readonly language: string;
  disposed: boolean;
  dispose(): void;
  getLineCount(): number;
}

/** Live model URIs, the one invariant the real ModelService enforces. */
const liveURIs = new Set<string>();
const createdURIs: string[] = [];

interface FakeCodeEditor {
  zones: Set<string>;
  model: FakeModel | null;
  onDidScrollChange(handler: () => void): void;
  onMouseMove(handler: (event: unknown) => void): void;
  onMouseLeave(handler: () => void): void;
  onMouseDown(handler: (event: unknown) => void): void;
  createDecorationsCollection(): { set(): void };
  getModel(): FakeModel | null;
  getVisibleRanges(): { startLineNumber: number }[];
  changeViewZones(callback: (accessor: FakeZoneAccessor) => void): void;
  revealLineInCenterIfOutsideViewport(): void;
  setPosition(): void;
}

interface FakeZoneAccessor {
  addZone(zone: { afterLineNumber: number }): string;
  removeZone(id: string): void;
  layoutZone(id: string): void;
}

function makeCodeEditor(): FakeCodeEditor {
  let nextZone = 0;
  const zones = new Set<string>();
  const editor: FakeCodeEditor = {
    zones,
    model: null,
    onDidScrollChange: () => undefined,
    onMouseMove: () => undefined,
    onMouseLeave: () => undefined,
    onMouseDown: () => undefined,
    createDecorationsCollection: () => ({ set: () => undefined }),
    getModel: () => editor.model,
    getVisibleRanges: () => [{ startLineNumber: 1 }],
    changeViewZones: (callback) => {
      callback({
        addZone: () => {
          nextZone += 1;
          const id = `zone-${nextZone}`;
          zones.add(id);
          return id;
        },
        removeZone: (id) => {
          zones.delete(id);
        },
        layoutZone: () => undefined,
      });
    },
    revealLineInCenterIfOutsideViewport: () => undefined,
    setPosition: () => undefined,
  };
  return editor;
}

const originalEditor = makeCodeEditor();
const modifiedEditor = makeCodeEditor();
const updateOptions = vi.fn<(options: Record<string, unknown>) => void>();

vi.mock('monaco-editor/editor/editor.api', () => {
  const editor = {
    defineTheme: () => undefined,
    setTheme: () => undefined,
    createModel: (value: string, language: string, uri: { toString(): string }) => {
      const key = uri.toString();
      if (liveURIs.has(key)) {
        throw new Error('ModelService: Cannot add model because it already exists!');
      }
      liveURIs.add(key);
      createdURIs.push(key);
      const model: FakeModel = {
        uri: key,
        value,
        language,
        disposed: false,
        dispose: () => {
          model.disposed = true;
          liveURIs.delete(key);
        },
        getLineCount: () => value.split('\n').length,
      };
      return model;
    },
    createDiffEditor: () => ({
      updateOptions,
      getOriginalEditor: () => originalEditor,
      getModifiedEditor: () => modifiedEditor,
      setModel: (models: { original: FakeModel; modified: FakeModel } | null) => {
        originalEditor.model = models === null ? null : models.original;
        modifiedEditor.model = models === null ? null : models.modified;
      },
      dispose: () => undefined,
    }),
    ScrollType: { Smooth: 0 },
    TrackedRangeStickiness: { NeverGrowsWhenTypingAtEdges: 0 },
  };
  return {
    editor,
    Uri: {
      from: (parts: { scheme: string; authority: string; path: string }) => ({
        toString: () => `${parts.scheme}://${parts.authority}${parts.path}`,
      }),
    },
    Range: class {
      constructor(
        readonly startLineNumber: number,
        readonly startColumn: number,
        readonly endLineNumber: number,
        readonly endColumn: number,
      ) {}
    },
  };
});

vi.mock('../src/viewer/languages.js', () => ({
  registerLanguages: () => undefined,
  resolveLanguage: (id: string) => id,
}));

vi.mock('../src/viewer/workerEnvironment.js', () => ({
  installMonacoEnvironment: () => undefined,
}));

const { MonacoDiffViewer } = await import('../src/viewer/monacoViewer.js');

// -- helpers -----------------------------------------------------------------------------------

function message(overrides: Partial<LoadFileMessage> = {}): LoadFileMessage {
  return {
    v: 1,
    type: 'loadFile',
    path: 'Sources/App/Main.swift',
    language: 'swift',
    original: 'one\ntwo\nthree\n',
    modified: 'one\nTWO\nthree\n',
    mode: 'sideBySide',
    wrap: false,
    ...overrides,
  } as LoadFileMessage;
}

function makeViewer(): InstanceType<typeof MonacoDiffViewer> {
  const container = document.createElement('div');
  document.body.append(container);
  return new MonacoDiffViewer({ container, post: () => undefined });
}

describe('MonacoDiffViewer.loadFile', () => {
  beforeEach(() => {
    liveURIs.clear();
    createdURIs.length = 0;
    updateOptions.mockClear();
    // The fake editors are module singletons (the mock factory is hoisted), so each test
    // starts them empty itself.
    originalEditor.zones.clear();
    modifiedEditor.zones.clear();
    originalEditor.model = null;
    modifiedEditor.model = null;
  });

  it('re-loads the same path without throwing (the wrap / inline toggle)', () => {
    const viewer = makeViewer();

    viewer.loadFile(message());
    expect(() => viewer.loadFile(message({ wrap: true }))).not.toThrow();
    expect(() => viewer.loadFile(message({ mode: 'inline' }))).not.toThrow();

    // Two live models at a time, never a leak and never a duplicate URI.
    expect(liveURIs.size).toBe(2);
    expect(createdURIs).toHaveLength(6);
  });

  it('applies the new mode and wrap on a same-path reload', () => {
    const viewer = makeViewer();
    viewer.loadFile(message());
    updateOptions.mockClear();

    viewer.loadFile(message({ wrap: true, mode: 'inline' }));

    expect(updateOptions).toHaveBeenCalledWith({
      renderSideBySide: false,
      wordWrap: 'on',
      diffWordWrap: 'on',
    });
  });

  it('remounts zones after a same-path reload', () => {
    const viewer = makeViewer();
    const threads: Thread[] = [
      { id: 'T1', line: 2, side: 'right', resolved: false, outdated: false, comments: [] },
    ];

    viewer.loadFile(message());
    viewer.setThreads(threads);
    expect(modifiedEditor.zones.size).toBe(1);

    // A reload clears the zone bookkeeping; the next snapshot must mount it again.
    viewer.loadFile(message({ wrap: true }));
    expect(modifiedEditor.zones.size).toBe(0);

    viewer.setThreads(threads);
    expect(modifiedEditor.zones.size).toBe(1);
  });

  it('mounts zones on the modified pane in inline mode', () => {
    const viewer = makeViewer();
    viewer.loadFile(message({ mode: 'inline' }));
    viewer.setThreads([
      { id: 'T1', line: 2, side: 'left', resolved: false, outdated: false, comments: [] },
    ]);

    expect(modifiedEditor.zones.size).toBe(1);
    expect(originalEditor.zones.size).toBe(0);
  });
});
