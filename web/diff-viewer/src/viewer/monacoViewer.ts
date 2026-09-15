/**
 * The Monaco-backed implementation of `ViewerPort`.
 *
 * Everything that can be reasoned about without a real editor lives in the sibling pure
 * modules (`protocol`, `router`, `zoneState`, `gutter`, `themes`, `threadCard`, `throttle`);
 * this file is the thin imperative shell that talks to Monaco. It is deliberately not unit
 * tested — Monaco cannot boot in jsdom.
 */

import * as monaco from 'monaco-editor/editor/editor.api';

import type {
  DraftComment,
  LoadFileMessage,
  SetThemeMessage,
  Side,
  Thread,
} from '../bridge/protocol.js';
import { makeAddComment, makeDraftClicked, makeThreadClicked, makeViewportChanged } from '../bridge/protocol.js';
import type { OutboundSink } from '../bridge/transport.js';
import { addCommentTarget, cursorHit, gutterHit, hitChanged, type GutterHit } from './gutter.js';
import { registerLanguages, resolveLanguage } from './languages.js';
import type { ViewerPort } from './router.js';
import { clampFontSize, documentThemeClass, THEME_IDS, THEMES } from './themes.js';
import { renderDraftZone, renderThreadZone } from './threadCard.js';
import { throttle, type Throttled } from './throttle.js';
import { installMonacoEnvironment } from './workerEnvironment.js';
import { hostSide, toDraftZones, toThreadZones, ZoneStore, type Zone } from './zoneState.js';

const VIEWPORT_THROTTLE_MS = 120;

/**
 * How many lines Monaco keeps readable in the DOM while a screen reader is running, and what
 * it keeps otherwise (10 is Monaco's own default, restated so switching the flag off puts the
 * editor back rather than leaving it wherever it happened to be).
 */
const SCREEN_READER_PAGE_SIZE = 100;
const MONACO_PAGE_SIZE = 10;
const ESTIMATED_ZONE_HEIGHT_PX = 72;

const FONT_FAMILY = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace';

const MODEL_SCHEME = 'shepherd';

/**
 * Which pane a bracket asks for, or `null` for any other key.
 *
 * `[` is the original side and `]` the modified one, which is where they sit on the keyboard and
 * on the screen.
 */
function bracketSide(keyCode: number): Side | null {
  if (keyCode === monaco.KeyCode.BracketLeft) return 'left';
  if (keyCode === monaco.KeyCode.BracketRight) return 'right';
  return null;
}

/** Takes a key out of circulation — only ever called once it has actually done something. */
function swallow(event: monaco.IKeyboardEvent): void {
  event.preventDefault();
  event.stopPropagation();
}

interface MountedZone {
  readonly zone: Zone;
  readonly editor: monaco.editor.ICodeEditor;
  readonly viewZone: monaco.editor.IViewZone;
  readonly host: HTMLElement;
  readonly card: HTMLElement;
  observer: ResizeObserver | null;
  id: string;
}

export interface ViewerOptions {
  readonly container: HTMLElement;
  readonly post: OutboundSink;
  /** Injected so tests/harness can freeze time; defaults to `Date.now`. */
  readonly now?: () => number;
}

export class MonacoDiffViewer implements ViewerPort {
  private readonly container: HTMLElement;
  private readonly post: OutboundSink;
  private readonly now: () => number;

  private readonly diffEditor: monaco.editor.IStandaloneDiffEditor;
  private originalModel: monaco.editor.ITextModel | null = null;
  private modifiedModel: monaco.editor.ITextModel | null = null;

  private readonly threadStore = new ZoneStore();
  private readonly draftStore = new ZoneStore();
  private readonly mounted = new Map<string, MountedZone>();

  private readonly gutterDecorations: Map<Side, monaco.editor.IEditorDecorationsCollection> = new Map();
  private armed: GutterHit | null = null;

  private readonly viewportThrottled: Throttled<number>;
  private mode: 'sideBySide' | 'inline' = 'sideBySide';
  private fontSize = 13;

  /**
   * Which lines of each side are part of the diff, from the last `loadFile`. `null` means the
   * payload did not say, so every line stays armable.
   */
  private commentable: Record<Side, ReadonlySet<number> | null> = { left: null, right: null };


  constructor(options: ViewerOptions) {
    this.container = options.container;
    this.post = options.post;
    this.now = options.now ?? (() => Date.now());

    installMonacoEnvironment();
    registerLanguages();
    monaco.editor.defineTheme(THEME_IDS.light, THEMES.light);
    monaco.editor.defineTheme(THEME_IDS.dark, THEMES.dark);
    monaco.editor.setTheme(THEME_IDS.light);

    this.diffEditor = monaco.editor.createDiffEditor(this.container, this.baseOptions());

    this.viewportThrottled = throttle<number>(VIEWPORT_THROTTLE_MS, (line) => {
      this.post(makeViewportChanged(line));
    });

    this.wireEditor(this.diffEditor.getModifiedEditor(), 'right');
    this.wireEditor(this.diffEditor.getOriginalEditor(), 'left');

    this.diffEditor.getModifiedEditor().onDidScrollChange(() => {
      const first = this.firstVisibleLine();
      if (first !== null) this.viewportThrottled(first);
    });
  }

  // -- options -------------------------------------------------------------------------------

  private baseOptions(): monaco.editor.IStandaloneDiffEditorConstructionOptions {
    return {
      automaticLayout: true,
      readOnly: true,
      originalEditable: false,
      renderSideBySide: true,
      renderOverviewRuler: true,
      renderIndicators: true,
      renderMarginRevertIcon: false,
      // Word-level (inner-line) diffs.
      diffAlgorithm: 'advanced',
      ignoreTrimWhitespace: false,
      // Fold the regions GitHub never sent. `/pulls/{n}/files` returns three context lines
      // per hunk and nothing else, so `PatchReconstructor` pads the gaps with empty lines on
      // both sides to keep Monaco's line numbers equal to GitHub's — comments are anchored by
      // absolute line number. Those blanks are what a reviewer scrolls through between hunks,
      // and on a file like `Localizable.xcstrings` there are hundreds of them.
      //
      // Monaco's own defaults are left alone, and `contextLineCount` in particular must stay at
      // 3: the patch only *has* three real context lines at each hunk edge, so a larger value
      // would reveal padding as though it were content.
      //
      // Honest about what it does not fix: the widget says "N hidden lines", and expanding one
      // shows N blank rows rather than the file's real text, because the app never received it.
      // Folding them is the improvement; the app cannot fill them without two extra blob
      // fetches per file, which ADR 0006 rules out for offline review.
      hideUnchangedRegions: { enabled: true },
      diffWordWrap: 'off',
      folding: false,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      glyphMargin: true,
      lineNumbersMinChars: 4,
      lineDecorationsWidth: 8,
      overviewRulerBorder: false,
      fontSize: this.fontSize,
      fontFamily: FONT_FAMILY,
      contextmenu: false,
      smoothScrolling: true,
      renderWhitespace: 'selection',
      occurrencesHighlight: 'off',
      selectionHighlight: false,
      matchBrackets: 'never',
      scrollbar: { alwaysConsumeMouseWheel: false, verticalScrollbarSize: 10, horizontalScrollbarSize: 10 },
      stickyScroll: { enabled: false },
      guides: { indentation: false },
    };
  }

  // -- ViewerPort ----------------------------------------------------------------------------

  loadFile(message: LoadFileMessage): void {
    this.unmountAll();
    this.threadStore.clear();
    this.draftStore.clear();
    this.arm(null);

    const language = resolveLanguage(message.language);

    // Swift re-sends `loadFile` for the *same* path whenever the mode or wrap setting
    // changes. Model URIs are derived from the path, and `createModel` throws
    // "Cannot add model because it already exists!" on a duplicate URI — so the previous
    // models are detached and disposed *first*, freeing the URIs. Creating first and
    // disposing afterwards meant every wrap/inline toggle threw, silently (the exception
    // dies inside `evaluateJavaScript`) and after `unmountAll` had already run.
    const previousOriginal = this.originalModel;
    const previousModified = this.modifiedModel;
    this.originalModel = null;
    this.modifiedModel = null;
    this.diffEditor.setModel(null);
    previousOriginal?.dispose();
    previousModified?.dispose();

    // Applied before the models so that a failure later cannot leave `mode` disagreeing with
    // the editor — zones would then mount on the wrong pane.
    this.mode = message.mode;
    this.commentable = {
      left: message.commentableLines ? new Set(message.commentableLines.left) : null,
      right: message.commentableLines ? new Set(message.commentableLines.right) : null,
    };
    this.diffEditor.updateOptions({
      renderSideBySide: message.mode === 'sideBySide',
      wordWrap: message.wrap ? 'on' : 'off',
      diffWordWrap: message.wrap ? 'on' : 'off',
    });

    this.originalModel = monaco.editor.createModel(message.original, language, this.modelURI('original', message.path));
    this.modifiedModel = monaco.editor.createModel(message.modified, language, this.modelURI('modified', message.path));
    this.diffEditor.setModel({ original: this.originalModel, modified: this.modifiedModel });

    // After the models, because a pane's aria label names the file the pane is showing and the
    // model is what makes that true. Absent, Monaco keeps its own default, which is the same
    // sentence on both panes and therefore cannot say which one you are in.
    const labels = message.paneLabels;
    if (labels !== undefined) {
      this.editorFor('left').updateOptions({ ariaLabel: labels.left });
      this.editorFor('right').updateOptions({ ariaLabel: labels.right });
    }
  }

  setTheme(message: SetThemeMessage): void {
    monaco.editor.setTheme(message.theme === 'dark' ? THEME_IDS.dark : THEME_IDS.light);
    this.fontSize = clampFontSize(message.fontSize);
    this.diffEditor.updateOptions({ fontSize: this.fontSize });

    const root = this.container.ownerDocument.documentElement;
    root.classList.remove('shepherd-theme-light', 'shepherd-theme-dark');
    root.classList.add(documentThemeClass(message.theme));
  }

  setThreads(threads: readonly Thread[]): void {
    this.applyZones(this.threadStore, toThreadZones(threads));
  }

  setDraftComments(comments: readonly DraftComment[]): void {
    this.applyZones(this.draftStore, toDraftZones(comments));
  }

  revealLine(line: number, side: Side): void {
    const editor = this.editorFor(side);
    const model = editor.getModel();
    if (model === null) return;
    const target = Math.min(Math.max(1, line), model.getLineCount());
    editor.revealLineInCenterIfOutsideViewport(target, monaco.editor.ScrollType.Smooth);
    editor.setPosition({ lineNumber: target, column: 1 });
  }

  /**
   * Puts the keyboard focus in one pane of the diff.
   *
   * From there the arrow keys move the cursor and `c` comments on the line it is on, which is the
   * whole point of handing focus over (ADR 0033's amendment). Which pane matters: the modified
   * side is the one a reviewer reads, and the original side is the only place a *deleted* line
   * exists to be commented on. In inline mode there is one pane holding both, and `editorFor`
   * already says so.
   */
  focusEditor(side: Side): void {
    const editor = this.editorFor(side);
    this.anchorCursor(editor);
    editor.focus();
  }

  /**
   * Turns Monaco's screen-reader mode on or off, because the app knows and Monaco does not.
   *
   * `accessibilitySupport: 'auto'` asks Monaco to detect a screen reader, and its detection is
   * a browser's: it cannot see that VoiceOver is reading the window this web view is embedded
   * in. macOS tells the app, the app tells us, and the option stops being a guess.
   *
   * `accessibilityPageSize` is how many lines Monaco keeps in the DOM for the screen reader to
   * read; the default of 10 is a page too small to walk a hunk through, and the cost of raising
   * it is paid only by the reviewer who needs it — which is the whole reason this is a flag and
   * not a constant.
   */
  setAccessibility(screenReader: boolean): void {
    this.diffEditor.updateOptions({
      accessibilitySupport: screenReader ? 'on' : 'auto',
      accessibilityPageSize: screenReader ? SCREEN_READER_PAGE_SIZE : MONACO_PAGE_SIZE,
    });
  }

  // -- lifecycle -----------------------------------------------------------------------------

  dispose(): void {
    this.viewportThrottled.cancel();
    this.unmountAll();
    this.diffEditor.dispose();
    this.originalModel?.dispose();
    this.modifiedModel?.dispose();
    this.originalModel = null;
    this.modifiedModel = null;
  }

  // -- internals -----------------------------------------------------------------------------

  private modelURI(kind: 'original' | 'modified', path: string): monaco.Uri {
    const clean = path.replace(/^\/+/, '');
    return monaco.Uri.from({ scheme: MODEL_SCHEME, authority: kind, path: `/${clean}` });
  }

  private editorFor(side: Side): monaco.editor.ICodeEditor {
    if (this.mode === 'inline') return this.diffEditor.getModifiedEditor();
    return side === 'left' ? this.diffEditor.getOriginalEditor() : this.diffEditor.getModifiedEditor();
  }

  private firstVisibleLine(): number | null {
    const ranges = this.diffEditor.getModifiedEditor().getVisibleRanges();
    const first = ranges[0];
    return first === undefined ? null : first.startLineNumber;
  }

  private wireEditor(editor: monaco.editor.ICodeEditor, side: Side): void {
    this.gutterDecorations.set(side, editor.createDecorationsCollection([]));

    editor.onMouseMove((event) => {
      const hit = gutterHit({
        targetType: event.target.type as number,
        lineNumber: event.target.position?.lineNumber ?? null,
        side,
        lineCount: editor.getModel()?.getLineCount() ?? -1,
        commentable: this.commentable[side],
      });
      this.arm(hit);
    });

    editor.onMouseLeave(() => {
      this.arm(null);
    });

    editor.onMouseDown((event) => {
      const hit = gutterHit({
        targetType: event.target.type as number,
        lineNumber: event.target.position?.lineNumber ?? null,
        side,
        lineCount: editor.getModel()?.getLineCount() ?? -1,
        commentable: this.commentable[side],
      });
      if (hit === null) return;
      const target = addCommentTarget(hit);
      this.post(makeAddComment(target.line, target.side, target.startLine));
    });

    // The same comment, reached by the keyboard. Until this existed, leaving an inline comment
    // was the one review action with no key at all — in an app where approving, requesting
    // changes, submitting, merging and walking the files are all keys (ADR 0033's amendment).
    //
    // The editor's own key map — the keys a reviewer aims at a *line*, as opposed to the ones
    // the native screen aims at a file. Each one is swallowed only if it did something, so an
    // unhandled key keeps travelling and still reaches the screen that owns it.
    //
    // `onKeyDown` rather than `addAction`, and that is not a preference: `addAction` and
    // `addCommand` belong to `IStandaloneCodeEditor`, and a diff editor's two panes are plain
    // `ICodeEditor`s. This is the seam both panes actually have.
    editor.onKeyDown((event) => {
      // A modified key belongs to somebody else — ⌘C copies the selection, and nothing here
      // may take that away.
      if (event.ctrlKey || event.shiftKey || event.altKey || event.metaKey) return;
      if (event.keyCode === monaco.KeyCode.KeyC) {
        if (this.commentOnCursor(editor, side)) swallow(event);
        return;
      }
      const target = bracketSide(event.keyCode);
      if (target !== null && this.crossToPane(target)) swallow(event);
    });
  }

  /**
   * `c`: asks for a composer on the line the cursor is on. Answers whether it did.
   *
   * `c` is the letter GitHub's own diff uses, and it is free here because the editor is
   * read-only: a keystroke that would otherwise type a character types nothing. The *cursor's*
   * line is asked the same question the pointer's line is asked — in range, and part of the diff
   * rather than one of the blank lines the reconstruction pads gaps with — through `cursorHit`,
   * so the two paths cannot come to different conclusions about which lines may carry a comment.
   * A line that may not simply does nothing, which is what the pointer does over it too.
   */
  private commentOnCursor(editor: monaco.editor.ICodeEditor, side: Side): boolean {
    const hit = cursorHit({
      lineNumber: editor.getPosition()?.lineNumber ?? null,
      side,
      lineCount: editor.getModel()?.getLineCount() ?? -1,
      commentable: this.commentable[side],
    });
    if (hit === null) return false;
    const target = addCommentTarget(hit);
    this.post(makeAddComment(target.line, target.side, target.startLine));
    return true;
  }

  /**
   * `[` and `]`: move the keyboard to the original or the modified pane. Answers whether it did.
   *
   * This is the whole of commenting on a deleted line without a pointer. `c` already works in
   * either pane — the original one posts `side: "left"` — but nothing moved the cursor *into*
   * that pane, so a deletion stayed mouse-only.
   *
   * Brackets rather than a letter, and not for want of a free letter: a letter can also be the
   * second half of a two-keystroke command over in the native screen (`r c`, `g s`), and the
   * editor cannot see that a prefix is armed over there — so it would swallow the second key and
   * kill the sequence. `[` and `]` are in no sequence at all, and they read as left and right.
   *
   * Inline mode has one pane carrying both sides, so there is no other side to cross to and the
   * key is left for whoever else wants it.
   */
  private crossToPane(side: Side): boolean {
    if (this.mode === 'inline') return false;
    this.focusEditor(side);
    return true;
  }

  /**
   * Puts the cursor somewhere visible before a pane takes the keyboard.
   *
   * A pane nobody has been in yet has its cursor on line 1, and the two panes scroll together —
   * so crossing into the original pane a hundred lines down would hand the keyboard to a line
   * nowhere near what is on screen, and the first arrow key would drag the whole diff back to
   * the top. Only when the cursor is *not* already on screen, so that crossing back returns to
   * the line it was left on rather than to the top of the viewport.
   */
  private anchorCursor(editor: monaco.editor.ICodeEditor): void {
    const ranges = editor.getVisibleRanges();
    const first = ranges[0];
    const last = ranges[ranges.length - 1];
    if (first === undefined || last === undefined) return;
    const line = editor.getPosition()?.lineNumber;
    if (line !== undefined && line >= first.startLineNumber && line <= last.endLineNumber) return;
    editor.setPosition({ lineNumber: first.startLineNumber, column: 1 });
  }

  private arm(hit: GutterHit | null): void {
    if (!hitChanged(this.armed, hit)) return;
    this.armed = hit;
    for (const [side, collection] of this.gutterDecorations) {
      if (hit === null || hit.side !== side) {
        collection.set([]);
        continue;
      }
      collection.set([
        {
          range: new monaco.Range(hit.line, 1, hit.line, 1),
          options: {
            glyphMarginClassName: 'sh-add-comment',
            glyphMarginHoverMessage: { value: 'Add a review comment' },
            stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
          },
        },
      ]);
    }
  }

  private applyZones(store: ZoneStore, next: readonly Zone[]): void {
    const diff = store.apply(next);
    for (const key of diff.removed) this.unmount(key);
    for (const zone of diff.updated) {
      this.unmount(zone.key);
      this.mount(zone);
    }
    for (const zone of diff.added) this.mount(zone);
  }

  private mount(zone: Zone): void {
    const editor = this.editorFor(hostSide(zone.side, this.mode));
    const doc = this.container.ownerDocument;

    const activate = (): void => {
      this.post(zone.kind === 'thread' ? makeThreadClicked(zone.thread.id) : makeDraftClicked(zone.draft.localID));
    };
    const card =
      zone.kind === 'thread'
        ? renderThreadZone(zone.thread, { doc, nowMs: this.now(), onActivate: activate })
        : renderDraftZone(zone.draft, { doc, nowMs: this.now(), onActivate: activate });

    const host = doc.createElement('div');
    host.className = 'sh-zone-host';
    host.append(card);

    const viewZone: monaco.editor.IViewZone = {
      afterLineNumber: zone.line,
      domNode: host,
      heightInPx: ESTIMATED_ZONE_HEIGHT_PX,
      suppressMouseDown: true,
    };

    let id = '';
    editor.changeViewZones((accessor) => {
      id = accessor.addZone(viewZone);
    });

    const entry: MountedZone = { zone, editor, viewZone, host, card, observer: null, id };
    entry.observer = this.observeHeight(entry);
    this.mounted.set(zone.key, entry);
    this.relayout(entry);
  }

  private observeHeight(entry: MountedZone): ResizeObserver | null {
    if (typeof ResizeObserver !== 'function') return null;
    const observer = new ResizeObserver(() => {
      this.relayout(entry);
    });
    observer.observe(entry.card);
    return observer;
  }

  private relayout(entry: MountedZone): void {
    const height = entry.card.offsetHeight;
    if (height <= 0) return;
    if (entry.viewZone.heightInPx === height) return;
    entry.viewZone.heightInPx = height;
    entry.editor.changeViewZones((accessor) => {
      accessor.layoutZone(entry.id);
    });
  }

  private unmount(key: string): void {
    const entry = this.mounted.get(key);
    if (entry === undefined) return;
    entry.observer?.disconnect();
    entry.editor.changeViewZones((accessor) => {
      accessor.removeZone(entry.id);
    });
    entry.host.remove();
    this.mounted.delete(key);
  }

  private unmountAll(): void {
    for (const key of [...this.mounted.keys()]) this.unmount(key);
  }
}
