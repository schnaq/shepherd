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
import { addCommentTarget, gutterHit, hitChanged, type GutterHit } from './gutter.js';
import { registerLanguages, resolveLanguage } from './languages.js';
import type { ViewerPort } from './router.js';
import { clampFontSize, documentThemeClass, THEME_IDS, THEMES } from './themes.js';
import { renderDraftZone, renderThreadZone } from './threadCard.js';
import { throttle, type Throttled } from './throttle.js';
import { installMonacoEnvironment } from './workerEnvironment.js';
import { toDraftZones, toThreadZones, ZoneStore, zonesForSide, type Zone } from './zoneState.js';

const VIEWPORT_THROTTLE_MS = 120;
const ESTIMATED_ZONE_HEIGHT_PX = 72;

const FONT_FAMILY = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace';

const MODEL_SCHEME = 'shepherd';

interface MountedZone {
  readonly zone: Zone;
  readonly editor: monaco.editor.ICodeEditor;
  readonly viewZone: monaco.editor.IViewZone;
  readonly host: HTMLElement;
  readonly card: HTMLElement;
  readonly observer: ResizeObserver | null;
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
      hideUnchangedRegions: { enabled: false },
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

    const language = resolveLanguage(message.language);
    const previousOriginal = this.originalModel;
    const previousModified = this.modifiedModel;

    this.originalModel = monaco.editor.createModel(message.original, language, this.modelURI('original', message.path));
    this.modifiedModel = monaco.editor.createModel(message.modified, language, this.modelURI('modified', message.path));

    this.mode = message.mode;
    this.diffEditor.updateOptions({
      renderSideBySide: message.mode === 'sideBySide',
      wordWrap: message.wrap ? 'on' : 'off',
      diffWordWrap: message.wrap ? 'on' : 'off',
    });

    this.diffEditor.setModel({ original: this.originalModel, modified: this.modifiedModel });

    previousOriginal?.dispose();
    previousModified?.dispose();
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
      });
      if (hit === null) return;
      const target = addCommentTarget(hit);
      this.post(makeAddComment(target.line, target.side, target.startLine));
    });
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
    const targets = zonesForSide([zone], zone.side, this.mode);
    if (targets.length === 0) return;
    const editor = this.editorFor(zone.side);
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

    const entry: MountedZone = {
      zone,
      editor,
      viewZone,
      host,
      card,
      observer: null,
      id,
    };
    const mountedEntry: MountedZone = {
      ...entry,
      observer: this.observeHeight(entry),
    };
    this.mounted.set(zone.key, mountedEntry);
    this.relayout(mountedEntry);
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
