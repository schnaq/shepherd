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

import type { LoadFileMessage, OutboundMessage, Thread } from '../src/bridge/protocol.js';

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
  /** Everything `updateOptions` has been handed, merged — the pane's aria label lands here. */
  options: Record<string, unknown>;
  updateOptions(options: Record<string, unknown>): void;
  onDidScrollChange(handler: () => void): void;
  onMouseMove(handler: (event: unknown) => void): void;
  onMouseLeave(handler: () => void): void;
  onMouseDown(handler: (event: unknown) => void): void;
  /** The handler the viewer registered, so a test can press the key itself. */
  keyHandler: ((event: unknown) => void) | null;
  onKeyDown(handler: (event: unknown) => void): void;
  focused: boolean;
  focus(): void;
  /** Where the cursor is, which is what the keyboard comment path reads. */
  position: { lineNumber: number } | null;
  getPosition(): { lineNumber: number } | null;
  createDecorationsCollection(): { set(): void };
  getModel(): FakeModel | null;
  /** The lines on screen — what `anchorCursor` reads before a pane takes the keyboard. */
  visibleRanges: { startLineNumber: number; endLineNumber: number }[];
  getVisibleRanges(): { startLineNumber: number; endLineNumber: number }[];
  changeViewZones(callback: (accessor: FakeZoneAccessor) => void): void;
  revealLineInCenterIfOutsideViewport(): void;
  setPosition(position: { lineNumber: number }): void;
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
    options: {},
    updateOptions: (options) => {
      Object.assign(editor.options, options);
    },
    onDidScrollChange: () => undefined,
    onMouseMove: () => undefined,
    onMouseLeave: () => undefined,
    onMouseDown: () => undefined,
    keyHandler: null,
    onKeyDown: (handler) => {
      editor.keyHandler = handler;
    },
    focused: false,
    focus: () => {
      editor.focused = true;
    },
    position: null,
    getPosition: () => editor.position,
    createDecorationsCollection: () => ({ set: () => undefined }),
    getModel: () => editor.model,
    visibleRanges: [{ startLineNumber: 1, endLineNumber: 20 }],
    getVisibleRanges: () => editor.visibleRanges,
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
    setPosition: (position) => {
      editor.position = position;
    },
  };
  return editor;
}

const originalEditor = makeCodeEditor();
const modifiedEditor = makeCodeEditor();
const updateOptions = vi.fn<(options: Record<string, unknown>) => void>();
/// What `createDiffEditor` was constructed with, so a test can assert on the base options.
let constructionOptions: Record<string, unknown> = {};

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
    createDiffEditor: (_container: unknown, options: Record<string, unknown>) => {
      constructionOptions = options;
      return {
        updateOptions,
        getOriginalEditor: () => originalEditor,
        getModifiedEditor: () => modifiedEditor,
        setModel: (models: { original: FakeModel; modified: FakeModel } | null) => {
          originalEditor.model = models === null ? null : models.original;
          modifiedEditor.model = models === null ? null : models.modified;
        },
        dispose: () => undefined,
      };
    },
    ScrollType: { Smooth: 0 },
    TrackedRangeStickiness: { NeverGrowsWhenTypingAtEdges: 0 },
  };
  return {
    editor,
    KeyCode: { KeyC: 41, BracketLeft: 92, BracketRight: 94 },
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

/** A viewer whose outbound messages a test can read. */
function makeListeningViewer(): {
  viewer: InstanceType<typeof MonacoDiffViewer>;
  posted: OutboundMessage[];
} {
  const container = document.createElement('div');
  document.body.append(container);
  const posted: OutboundMessage[] = [];
  const viewer = new MonacoDiffViewer({
    container,
    post: (message: OutboundMessage) => {
      posted.push(message);
    },
  });
  return { viewer, posted };
}

/** One `c` keypress with no modifiers, as Monaco would report it. */
const pressC = {
  keyCode: 41,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  metaKey: false,
  preventDefault: () => undefined,
  stopPropagation: () => undefined,
};

const pressBracketLeft = { ...pressC, keyCode: 92 };
const pressBracketRight = { ...pressC, keyCode: 94 };

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
    originalEditor.options = {};
    modifiedEditor.options = {};
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

  it('folds the regions GitHub never sent, keeping Monaco three lines of context', () => {
    makeViewer();

    // The padding `PatchReconstructor` writes between hunks is empty on both sides, so Monaco
    // reads it as unchanged and — with this on — collapses it instead of drawing hundreds of
    // blank rows. `contextLineCount` must stay unset (Monaco's 3): the patch carries exactly
    // three real context lines per hunk edge, and a larger value would reveal padding as
    // though it were the file's text.
    const hidden = constructionOptions['hideUnchangedRegions'] as Record<string, unknown>;
    expect(hidden['enabled']).toBe(true);
    expect(hidden['contextLineCount']).toBeUndefined();
  });

  it('labels each pane for a screen reader when the payload says what to call them', () => {
    const viewer = makeViewer();

    viewer.loadFile(
      message({ paneLabels: { left: 'Original, a.swift', right: 'Changed, a.swift' } }),
    );

    // Per pane, not on the diff editor: one label for both panes would be the same sentence
    // twice, which is the Monaco default this replaces.
    expect(originalEditor.options['ariaLabel']).toBe('Original, a.swift');
    expect(modifiedEditor.options['ariaLabel']).toBe('Changed, a.swift');
  });

  it('leaves the default labels alone when the payload names none', () => {
    const viewer = makeViewer();

    viewer.loadFile(message());

    expect('ariaLabel' in originalEditor.options).toBe(false);
    expect('ariaLabel' in modifiedEditor.options).toBe(false);
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

describe('MonacoDiffViewer.setAccessibility', () => {
  beforeEach(() => {
    liveURIs.clear();
    updateOptions.mockClear();
  });

  it('turns Monaco screen-reader mode on, and gives it a page worth reading', () => {
    const viewer = makeViewer();

    viewer.setAccessibility(true);

    expect(updateOptions).toHaveBeenCalledWith({
      accessibilitySupport: 'on',
      accessibilityPageSize: 100,
    });
  });

  it('puts Monaco back where it was when the screen reader stops', () => {
    const viewer = makeViewer();
    viewer.setAccessibility(true);
    updateOptions.mockClear();

    viewer.setAccessibility(false);

    // Restated rather than left as it was: an option that is only ever raised would keep the
    // 100-line page for the rest of the session, which is a cost nobody asked for.
    expect(updateOptions).toHaveBeenCalledWith({
      accessibilitySupport: 'auto',
      accessibilityPageSize: 10,
    });
  });
});

describe('the keyboard path to an inline comment', () => {
  beforeEach(() => {
    liveURIs.clear();
    for (const editor of [originalEditor, modifiedEditor]) {
      editor.position = null;
      editor.focused = false;
      editor.visibleRanges = [{ startLineNumber: 1, endLineNumber: 20 }];
    }
  });

  it('comments on the line the cursor is on', () => {
    const { viewer, posted } = makeListeningViewer();
    viewer.loadFile(message());
    modifiedEditor.position = { lineNumber: 2 };

    modifiedEditor.keyHandler?.(pressC);

    expect(posted).toEqual([{ v: 1, type: 'addComment', line: 2, side: 'right' }]);
  });

  it('comments on a deletion when the cursor is in the original pane', () => {
    const { viewer, posted } = makeListeningViewer();
    viewer.loadFile(message());
    originalEditor.position = { lineNumber: 3 };

    originalEditor.keyHandler?.(pressC);

    expect(posted).toEqual([{ v: 1, type: 'addComment', line: 3, side: 'left' }]);
  });

  it('refuses a line that is not part of the diff, exactly as the pointer does', () => {
    // The blank lines the reconstruction pads the gaps between hunks with. GitHub rejects a
    // comment on one of those and rejects the whole review with it, so the keyboard must not
    // become the way around a guard the mouse respects.
    const { viewer, posted } = makeListeningViewer();
    viewer.loadFile(message({ commentableLines: { left: [1], right: [1] } }));
    modifiedEditor.position = { lineNumber: 3 };

    modifiedEditor.keyHandler?.(pressC);

    expect(posted).toEqual([]);
  });

  it('refuses a cursor past the end of the model', () => {
    const { viewer, posted } = makeListeningViewer();
    viewer.loadFile(message());
    modifiedEditor.position = { lineNumber: 99 };

    modifiedEditor.keyHandler?.(pressC);

    expect(posted).toEqual([]);
  });

  it('ignores the key when it carries a modifier, and every other key', () => {
    const { viewer, posted } = makeListeningViewer();
    viewer.loadFile(message());
    modifiedEditor.position = { lineNumber: 2 };

    // ⌘C is copy and must stay copy; a different letter is not ours at all.
    modifiedEditor.keyHandler?.({ ...pressC, metaKey: true });
    modifiedEditor.keyHandler?.({ ...pressC, shiftKey: true });
    modifiedEditor.keyHandler?.({ ...pressC, keyCode: 42 });

    expect(posted).toEqual([]);
  });

  it('swallows the key only once a line has been found', () => {
    const { viewer } = makeListeningViewer();
    viewer.loadFile(message({ commentableLines: { left: [1], right: [1] } }));

    const onACommentableLine = { ...pressC, prevented: false, stopped: false };
    const handled = {
      ...pressC,
      preventDefault: () => {
        onACommentableLine.prevented = true;
      },
      stopPropagation: () => {
        onACommentableLine.stopped = true;
      },
    };

    // A line no comment can go on: the key must keep travelling, so that a key the native
    // screen owns still reaches it.
    modifiedEditor.position = { lineNumber: 3 };
    modifiedEditor.keyHandler?.(handled);
    expect(onACommentableLine.prevented).toBe(false);
    expect(onACommentableLine.stopped).toBe(false);

    modifiedEditor.position = { lineNumber: 1 };
    modifiedEditor.keyHandler?.(handled);
    expect(onACommentableLine.prevented).toBe(true);
    expect(onACommentableLine.stopped).toBe(true);
  });
});

describe('MonacoDiffViewer.focusEditor', () => {
  it('focuses the pane the reviewer is reading', () => {
    const viewer = makeViewer();
    modifiedEditor.focused = false;

    viewer.focusEditor('right');

    expect(modifiedEditor.focused).toBe(true);
  });

  it('focuses the original pane when the app asks for it', () => {
    // The native screen's own `[`: a reviewer who wants to comment on a deletion should not have
    // to land in the modified pane first and cross over.
    const viewer = makeViewer();
    originalEditor.focused = false;

    viewer.focusEditor('left');

    expect(originalEditor.focused).toBe(true);
  });
});

describe('crossing between the panes with the brackets', () => {
  beforeEach(() => {
    liveURIs.clear();
    for (const editor of [originalEditor, modifiedEditor]) {
      editor.position = null;
      editor.focused = false;
      editor.visibleRanges = [{ startLineNumber: 1, endLineNumber: 20 }];
    }
  });

  it('`[` hands the keyboard to the original pane, `]` hands it back', () => {
    const { viewer } = makeListeningViewer();
    viewer.loadFile(message());

    modifiedEditor.keyHandler?.(pressBracketLeft);
    expect(originalEditor.focused).toBe(true);

    modifiedEditor.focused = false;
    originalEditor.keyHandler?.(pressBracketRight);
    expect(modifiedEditor.focused).toBe(true);
  });

  it('reaches a comment on a deleted line, which is the whole point', () => {
    const { viewer, posted } = makeListeningViewer();
    viewer.loadFile(message());
    modifiedEditor.position = { lineNumber: 2 };

    // `[` to cross, `c` to comment: the deletion is now reachable without a pointer.
    modifiedEditor.keyHandler?.(pressBracketLeft);
    originalEditor.keyHandler?.(pressC);

    expect(posted).toEqual([{ v: 1, type: 'addComment', line: 1, side: 'left' }]);
  });

  it('puts the cursor where the reviewer is looking', () => {
    // A pane nobody has been in has its cursor on line 1. Crossing into it a hundred lines down
    // must not hand the keyboard to a line that is off screen, or the first arrow key drags the
    // whole diff back to the top.
    const { viewer } = makeListeningViewer();
    viewer.loadFile(message());
    originalEditor.visibleRanges = [{ startLineNumber: 100, endLineNumber: 120 }];

    modifiedEditor.keyHandler?.(pressBracketLeft);

    expect(originalEditor.position).toEqual({ lineNumber: 100, column: 1 });
  });

  it('leaves a cursor that is already on screen where it was', () => {
    const { viewer } = makeListeningViewer();
    viewer.loadFile(message());
    originalEditor.visibleRanges = [{ startLineNumber: 100, endLineNumber: 120 }];
    originalEditor.position = { lineNumber: 105 };

    modifiedEditor.keyHandler?.(pressBracketLeft);

    expect(originalEditor.position).toEqual({ lineNumber: 105 });
  });

  it('has no other side to cross to in inline mode, and says so by letting the key travel', () => {
    const { viewer } = makeListeningViewer();
    viewer.loadFile(message({ mode: 'inline' }));
    const travelled = { prevented: false };
    const press = {
      ...pressBracketLeft,
      preventDefault: () => {
        travelled.prevented = true;
      },
    };

    modifiedEditor.keyHandler?.(press);

    expect(originalEditor.focused).toBe(false);
    expect(travelled.prevented).toBe(false);
  });

  it('ignores a bracket that carries a modifier', () => {
    const { viewer } = makeListeningViewer();
    viewer.loadFile(message());

    modifiedEditor.keyHandler?.({ ...pressBracketLeft, metaKey: true });

    expect(originalEditor.focused).toBe(false);
  });
});
