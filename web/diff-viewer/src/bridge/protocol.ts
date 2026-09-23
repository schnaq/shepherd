/**
 * Shepherd diff-viewer bridge protocol — the binding Swift ⇄ web contract.
 *
 * This file is normative together with `docs/ARCHITECTURE.md` §"Diff viewer bridge
 * (Swift ⇄ Monaco)" and `Shepherd/Features/DiffViewer/BridgeProtocol.swift`. The three must
 * stay field-for-field identical; the shared decode fixtures in `web/diff-viewer/fixtures/`
 * are the cross-language test corpus.
 *
 * Transport:
 *   Swift → web   `evaluateJavaScript("shepherd.receive({…})")`
 *   web   → Swift `window.webkit.messageHandlers.shepherd.postMessage({…})`
 *
 * Every message carries `v: 1` and a `type` discriminator. Everything here is hand-rolled:
 * no schema library, no `any`, and every validator narrows `unknown` to a concrete type.
 */

export const PROTOCOL_VERSION = 1;
export type ProtocolVersion = typeof PROTOCOL_VERSION;

/** Which side of the diff a line/thread/comment belongs to. Mirrors Swift's `Side`. */
export type Side = 'left' | 'right';

/** Diff editor layout. Mirrors Swift's `DiffMode`. */
export type DiffMode = 'sideBySide' | 'inline';

/** Appearance. Mirrors Swift's `ThemeName`. */
export type ThemeName = 'light' | 'dark';

// ---------------------------------------------------------------------------------------------
// Swift → web
// ---------------------------------------------------------------------------------------------

/**
 * The 1-based lines of each document that came from the patch, and may therefore carry a
 * comment.
 *
 * Swift rebuilds both sides of the diff from GitHub's unified patch and pads the gaps between
 * hunks with blank lines so absolute line numbers still match GitHub's. Those fillers are
 * indistinguishable from real content once they are in the model, and GitHub rejects the
 * *entire* review — summary and every valid inline comment with it — when one comment lands on
 * a line that is not part of the diff. So the native side says which lines are real and the
 * gutter “+” only arms on those.
 */
export interface CommentableLines {
  readonly left: readonly number[];
  readonly right: readonly number[];
}

/**
 * What a screen reader should call each pane of the diff.
 *
 * Monaco's own default is “Editor content;press Alt+F1 for Accessibility Options”, which is
 * true of both panes and therefore says nothing about which one the cursor is in — the single
 * most useful fact at the moment somebody has just handed the keyboard over with `c`. The
 * native side sends the wording because the app is localised and this bundle is not: a German
 * build must not announce its diff in English (ADR 0033's second amendment).
 *
 * Optional and additive, like ``commentableLines``: without it Monaco keeps its own default.
 */
export interface PaneLabels {
  readonly left: string;
  readonly right: string;
}

export interface LoadFileMessage {
  readonly v: ProtocolVersion;
  readonly type: 'loadFile';
  readonly path: string;
  /** Monaco language id (see `src/viewer/languages.ts`), or `'plaintext'`. */
  readonly language: string;
  readonly original: string;
  readonly modified: string;
  readonly mode: DiffMode;
  readonly wrap: boolean;
  /**
   * Optional, and additive — a payload without it means "every line is commentable", which is
   * what this viewer did before the field existed. That is why `v` stays 1.
   */
  readonly commentableLines?: CommentableLines;
  /** What a screen reader calls each pane; see ``PaneLabels``. Optional and additive. */
  readonly paneLabels?: PaneLabels;
}

export interface SetThemeMessage {
  readonly v: ProtocolVersion;
  readonly type: 'setTheme';
  readonly theme: ThemeName;
  readonly fontSize: number;
}

export interface ThreadComment {
  readonly author: string;
  /**
   * TRUSTED HTML. Rendered with `innerHTML`.
   *
   * The native side renders GitHub markdown and sanitizes it *before* handing it to the
   * webview; the webview never receives raw remote markup and never fetches anything itself.
   * The viewer additionally strips inline event handlers and `javascript:` URLs
   * (`src/viewer/threadCard.ts`) as belt-and-braces, but the sanitization contract lives in
   * Swift. Do not widen this to untrusted input without changing that contract.
   */
  readonly bodyHTML: string;
  /** ISO-8601 timestamp. */
  readonly createdAt: string;
  readonly isAgent: boolean;
}

export interface Thread {
  readonly id: string;
  /** 1-based line number in the model identified by `side`. */
  readonly line: number;
  readonly side: Side;
  readonly resolved: boolean;
  readonly outdated: boolean;
  readonly comments: readonly ThreadComment[];
}

export interface SetThreadsMessage {
  readonly v: ProtocolVersion;
  readonly type: 'setThreads';
  readonly threads: readonly Thread[];
}

export interface DraftComment {
  readonly localID: string;
  readonly line: number;
  readonly side: Side;
  /** Plain text (never HTML) — drafts are composed natively and shown verbatim. */
  readonly body: string;
}

export interface SetDraftCommentsMessage {
  readonly v: ProtocolVersion;
  readonly type: 'setDraftComments';
  readonly comments: readonly DraftComment[];
}

export interface RevealLineMessage {
  readonly v: ProtocolVersion;
  readonly type: 'revealLine';
  readonly line: number;
  readonly side: Side;
}

/**
 * Put the keyboard focus in the editor.
 *
 * The reason it exists is the keyboard: everything a reviewer can do to a *file* is a key in the
 * native screen, and everything they can do to a *line* is Monaco's, so somebody driving the app
 * without a mouse needs a way across that boundary. Sending this is that way (ADR 0033's
 * amendment).
 */
export interface FocusEditorMessage {
  readonly v: ProtocolVersion;
  readonly type: 'focusEditor';
  /**
   * Which pane the cursor should land in.
   *
   * Optional, and additive for the same reason `loadFile`'s `paneLabels` is: a message without
   * it means the modified pane, which is what this command meant before there was a way to ask
   * for the other one — and is still the pane a reviewer reads. Asking for `'left'` is how a
   * comment on a *deleted* line is reached without a pointer.
   */
  readonly side?: Side;
}

/**
 * Whether a screen reader is running, as the *app* sees it.
 *
 * Monaco decides for itself when `accessibilitySupport` is `'auto'`, and in a `WKWebView` it
 * decides wrong: the heuristics it uses are browser ones, and nothing in the web view knows
 * that VoiceOver is reading the window it lives in. macOS does know, so the native side is the
 * honest source — SwiftUI's `accessibilityVoiceOverEnabled` straight through to the option
 * (ADR 0033's second amendment).
 */
export interface SetAccessibilityMessage {
  readonly v: ProtocolVersion;
  readonly type: 'setAccessibility';
  readonly screenReader: boolean;
}

/**
 * The words this bundle draws itself, in the app's language.
 *
 * Every other string the reviewer reads in the diff is Monaco's or GitHub's; these are the
 * handful the thread cards and the gutter add. They are sent from Swift for the reason
 * ``PaneLabels`` is: the app is localised through its String Catalog and this bundle is not, so
 * a German Mac must not get English pills (ADR 0022's diff-viewer amendment).
 *
 * `commentCount` is a pair of whole phrases rather than a noun, because a count assembled from
 * a number and a word is a sentence built at runtime — which no catalog can translate. The
 * bundle picks `one` or `other` with `Intl.PluralRules` for `locale` and replaces `{count}`.
 */
export interface ViewerStrings {
  /** First part of a collapsed resolved thread ("Resolved · octocat · 2 comments"). */
  readonly resolved: string;
  /** The pill on a thread whose anchor has moved. */
  readonly outdated: string;
  /** The pill on a local draft comment. */
  readonly pending: string;
  /** A thread that arrived without any comment. */
  readonly noComments: string;
  /** Stands in for the author of a resolved thread with no comment to name one. */
  readonly unknownAuthor: string;
  /** Tooltip of the 🤖 badge. */
  readonly agentBadgeTitle: string;
  /** What a screen reader calls the 🤖 badge. */
  readonly agentBadgeLabel: string;
  /** Hover text of the gutter “+”. */
  readonly addComment: string;
  readonly commentCount: {
    /** Plural category `one`, e.g. "1 comment". May contain `{count}`. */
    readonly one: string;
    /** Every other category, e.g. "{count} comments". */
    readonly other: string;
  };
}

/**
 * The app's language, and the words that go with it (ADR 0022's diff-viewer amendment).
 *
 * Sent once, before the first `loadFile`. Until it arrives the viewer speaks English, which is
 * what the tests and the dev harness see.
 */
export interface SetLocaleMessage {
  readonly v: ProtocolVersion;
  readonly type: 'setLocale';
  /**
   * A BCP 47 language tag (`"de"`, `"en"`) — the language the app's own strings resolved to, so
   * that `Intl`'s relative times agree with the words around them. The bundle falls back to
   * English for a tag `Intl` does not accept.
   */
  readonly locale: string;
  readonly strings: ViewerStrings;
}

export type InboundMessage =
  | LoadFileMessage
  | SetLocaleMessage
  | SetThemeMessage
  | SetThreadsMessage
  | SetDraftCommentsMessage
  | RevealLineMessage
  | FocusEditorMessage
  | SetAccessibilityMessage;

export type InboundMessageType = InboundMessage['type'];

export const INBOUND_MESSAGE_TYPES: readonly InboundMessageType[] = [
  'loadFile',
  'setTheme',
  'setThreads',
  'setDraftComments',
  'revealLine',
  'focusEditor',
  'setAccessibility',
  'setLocale',
];

// ---------------------------------------------------------------------------------------------
// web → Swift
// ---------------------------------------------------------------------------------------------

/** Bundle booted and the editor exists — safe for Swift to start sending. */
export interface ReadyMessage {
  readonly v: ProtocolVersion;
  readonly type: 'ready';
}

/**
 * User clicked a gutter “+”. Swift opens the *native* comment composer — text entry never
 * happens inside the webview.
 *
 * `startLine` is the protocol passthrough for multi-line selection comments. v1 of the viewer
 * only triggers single-line (`startLine` omitted); the field exists so Swift can decode
 * multi-line requests without a protocol bump when the drag affordance lands.
 */
export interface AddCommentMessage {
  readonly v: ProtocolVersion;
  readonly type: 'addComment';
  readonly line: number;
  readonly side: Side;
  readonly startLine?: number;
}

/** Exactly one of `threadID` / `localID` is present (published thread vs. local draft). */
export type CommentClickedMessage =
  | {
      readonly v: ProtocolVersion;
      readonly type: 'commentClicked';
      readonly threadID: string;
    }
  | {
      readonly v: ProtocolVersion;
      readonly type: 'commentClicked';
      readonly localID: string;
    };

export interface ViewportChangedMessage {
  readonly v: ProtocolVersion;
  readonly type: 'viewportChanged';
  readonly firstVisibleLine: number;
}

export type OutboundMessage =
  | ReadyMessage
  | AddCommentMessage
  | CommentClickedMessage
  | ViewportChangedMessage;

export type OutboundMessageType = OutboundMessage['type'];

export const OUTBOUND_MESSAGE_TYPES: readonly OutboundMessageType[] = [
  'ready',
  'addComment',
  'commentClicked',
  'viewportChanged',
];

// ---------------------------------------------------------------------------------------------
// Constructors (the only supported way to build outbound messages)
// ---------------------------------------------------------------------------------------------

export function makeReady(): ReadyMessage {
  return { v: PROTOCOL_VERSION, type: 'ready' };
}

export function makeAddComment(line: number, side: Side, startLine?: number): AddCommentMessage {
  return startLine === undefined
    ? { v: PROTOCOL_VERSION, type: 'addComment', line, side }
    : { v: PROTOCOL_VERSION, type: 'addComment', line, side, startLine };
}

export function makeThreadClicked(threadID: string): CommentClickedMessage {
  return { v: PROTOCOL_VERSION, type: 'commentClicked', threadID };
}

export function makeDraftClicked(localID: string): CommentClickedMessage {
  return { v: PROTOCOL_VERSION, type: 'commentClicked', localID };
}

export function makeViewportChanged(firstVisibleLine: number): ViewportChangedMessage {
  return { v: PROTOCOL_VERSION, type: 'viewportChanged', firstVisibleLine };
}

// ---------------------------------------------------------------------------------------------
// Runtime validation
// ---------------------------------------------------------------------------------------------

export type ParseResult<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: string };

function ok<T>(value: T): ParseResult<T> {
  return { ok: true, value };
}

function fail<T>(error: string): ParseResult<T> {
  return { ok: false, error };
}

type Rec = Readonly<Record<string, unknown>>;

function isRecord(value: unknown): value is Rec {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isString(value: unknown): value is string {
  return typeof value === 'string';
}

function isBoolean(value: unknown): value is boolean {
  return typeof value === 'boolean';
}

/** Finite number, no NaN/Infinity — JSON can carry neither, but a hand-built object can. */
function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

/** 1-based line number: a positive integer. */
function isLineNumber(value: unknown): value is number {
  return isFiniteNumber(value) && Number.isInteger(value) && value >= 1;
}

export function isSide(value: unknown): value is Side {
  return value === 'left' || value === 'right';
}

export function isDiffMode(value: unknown): value is DiffMode {
  return value === 'sideBySide' || value === 'inline';
}

export function isThemeName(value: unknown): value is ThemeName {
  return value === 'light' || value === 'dark';
}

function envelope(value: unknown, path: string): ParseResult<Rec> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  if (value['v'] !== PROTOCOL_VERSION) {
    return fail(`${path}: unsupported protocol version ${JSON.stringify(value['v'])}, expected ${PROTOCOL_VERSION}`);
  }
  if (!isString(value['type'])) return fail(`${path}: missing string "type"`);
  return ok(value);
}

function parseLineList(value: unknown, path: string): ParseResult<number[]> {
  if (!Array.isArray(value)) return fail(`${path}: expected array`);
  const lines: number[] = [];
  for (let i = 0; i < value.length; i += 1) {
    const line: unknown = value[i];
    if (!isLineNumber(line)) return fail(`${path}[${i}]: expected a 1-based line number`);
    lines.push(line);
  }
  return ok(lines);
}

function parseCommentableLines(value: unknown, path: string): ParseResult<CommentableLines> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  const left = parseLineList(value['left'], `${path}.left`);
  if (!left.ok) return fail(left.error);
  const right = parseLineList(value['right'], `${path}.right`);
  if (!right.ok) return fail(right.error);
  return ok({ left: left.value, right: right.value });
}

function parsePaneLabels(value: unknown, path: string): ParseResult<PaneLabels> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  if (!isString(value['left']) || value['left'].length === 0) {
    return fail(`${path}.left: expected non-empty string`);
  }
  if (!isString(value['right']) || value['right'].length === 0) {
    return fail(`${path}.right: expected non-empty string`);
  }
  return ok({ left: value['left'], right: value['right'] });
}

const VIEWER_STRING_KEYS = [
  'resolved',
  'outdated',
  'pending',
  'noComments',
  'unknownAuthor',
  'agentBadgeTitle',
  'agentBadgeLabel',
  'addComment',
] as const;

function isNonEmptyString(value: unknown): value is string {
  return isString(value) && value.length > 0;
}

function parseViewerStrings(value: unknown, path: string): ParseResult<ViewerStrings> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  const words: Partial<Record<(typeof VIEWER_STRING_KEYS)[number], string>> = {};
  for (const key of VIEWER_STRING_KEYS) {
    const word = value[key];
    if (!isNonEmptyString(word)) return fail(`${path}.${key}: expected non-empty string`);
    words[key] = word;
  }
  const count = value['commentCount'];
  if (!isRecord(count)) return fail(`${path}.commentCount: expected an object`);
  if (!isNonEmptyString(count['one'])) return fail(`${path}.commentCount.one: expected non-empty string`);
  if (!isNonEmptyString(count['other'])) return fail(`${path}.commentCount.other: expected non-empty string`);
  return ok({
    ...(words as Record<(typeof VIEWER_STRING_KEYS)[number], string>),
    commentCount: { one: count['one'], other: count['other'] },
  });
}

function parseThreadComment(value: unknown, path: string): ParseResult<ThreadComment> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  if (!isString(value['author'])) return fail(`${path}.author: expected string`);
  if (!isString(value['bodyHTML'])) return fail(`${path}.bodyHTML: expected string`);
  if (!isString(value['createdAt'])) return fail(`${path}.createdAt: expected string`);
  if (!isBoolean(value['isAgent'])) return fail(`${path}.isAgent: expected boolean`);
  return ok({
    author: value['author'],
    bodyHTML: value['bodyHTML'],
    createdAt: value['createdAt'],
    isAgent: value['isAgent'],
  });
}

function parseThread(value: unknown, path: string): ParseResult<Thread> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  if (!isString(value['id']) || value['id'].length === 0) return fail(`${path}.id: expected non-empty string`);
  if (!isLineNumber(value['line'])) return fail(`${path}.line: expected a 1-based line number`);
  if (!isSide(value['side'])) return fail(`${path}.side: expected "left" | "right"`);
  if (!isBoolean(value['resolved'])) return fail(`${path}.resolved: expected boolean`);
  if (!isBoolean(value['outdated'])) return fail(`${path}.outdated: expected boolean`);
  const rawComments = value['comments'];
  if (!Array.isArray(rawComments)) return fail(`${path}.comments: expected array`);
  const comments: ThreadComment[] = [];
  for (let i = 0; i < rawComments.length; i += 1) {
    const parsed = parseThreadComment(rawComments[i], `${path}.comments[${i}]`);
    if (!parsed.ok) return fail(parsed.error);
    comments.push(parsed.value);
  }
  return ok({
    id: value['id'],
    line: value['line'],
    side: value['side'],
    resolved: value['resolved'],
    outdated: value['outdated'],
    comments,
  });
}

function parseDraftComment(value: unknown, path: string): ParseResult<DraftComment> {
  if (!isRecord(value)) return fail(`${path}: expected an object`);
  if (!isString(value['localID']) || value['localID'].length === 0) {
    return fail(`${path}.localID: expected non-empty string`);
  }
  if (!isLineNumber(value['line'])) return fail(`${path}.line: expected a 1-based line number`);
  if (!isSide(value['side'])) return fail(`${path}.side: expected "left" | "right"`);
  if (!isString(value['body'])) return fail(`${path}.body: expected string`);
  return ok({
    localID: value['localID'],
    line: value['line'],
    side: value['side'],
    body: value['body'],
  });
}

/** Narrow an untrusted value coming from `shepherd.receive` to a Swift → web message. */
export function parseInbound(value: unknown): ParseResult<InboundMessage> {
  const head = envelope(value, 'message');
  if (!head.ok) return fail(head.error);
  const msg = head.value;
  const type = msg['type'] as string;

  switch (type) {
    case 'loadFile': {
      if (!isString(msg['path'])) return fail('loadFile.path: expected string');
      if (!isString(msg['language'])) return fail('loadFile.language: expected string');
      if (!isString(msg['original'])) return fail('loadFile.original: expected string');
      if (!isString(msg['modified'])) return fail('loadFile.modified: expected string');
      if (!isDiffMode(msg['mode'])) return fail('loadFile.mode: expected "sideBySide" | "inline"');
      if (!isBoolean(msg['wrap'])) return fail('loadFile.wrap: expected boolean');
      const base = {
        v: PROTOCOL_VERSION,
        type: 'loadFile',
        path: msg['path'],
        language: msg['language'],
        original: msg['original'],
        modified: msg['modified'],
        mode: msg['mode'],
        wrap: msg['wrap'],
      } as const;
      // Two optional fields, so the message is built up rather than returned early: both are
      // additive, and a payload carrying neither is still the valid v1 message it always was.
      let message: LoadFileMessage = base;
      const rawCommentable = msg['commentableLines'];
      if (rawCommentable !== undefined && rawCommentable !== null) {
        const commentableLines = parseCommentableLines(rawCommentable, 'loadFile.commentableLines');
        if (!commentableLines.ok) return fail(commentableLines.error);
        message = { ...message, commentableLines: commentableLines.value };
      }
      const rawLabels = msg['paneLabels'];
      if (rawLabels !== undefined && rawLabels !== null) {
        const paneLabels = parsePaneLabels(rawLabels, 'loadFile.paneLabels');
        if (!paneLabels.ok) return fail(paneLabels.error);
        message = { ...message, paneLabels: paneLabels.value };
      }
      return ok(message);
    }
    case 'setTheme': {
      if (!isThemeName(msg['theme'])) return fail('setTheme.theme: expected "light" | "dark"');
      if (!isFiniteNumber(msg['fontSize']) || msg['fontSize'] <= 0) {
        return fail('setTheme.fontSize: expected a positive number');
      }
      return ok({ v: PROTOCOL_VERSION, type: 'setTheme', theme: msg['theme'], fontSize: msg['fontSize'] });
    }
    case 'setThreads': {
      const raw = msg['threads'];
      if (!Array.isArray(raw)) return fail('setThreads.threads: expected array');
      const threads: Thread[] = [];
      for (let i = 0; i < raw.length; i += 1) {
        const parsed = parseThread(raw[i], `setThreads.threads[${i}]`);
        if (!parsed.ok) return fail(parsed.error);
        threads.push(parsed.value);
      }
      return ok({ v: PROTOCOL_VERSION, type: 'setThreads', threads });
    }
    case 'setDraftComments': {
      const raw = msg['comments'];
      if (!Array.isArray(raw)) return fail('setDraftComments.comments: expected array');
      const comments: DraftComment[] = [];
      for (let i = 0; i < raw.length; i += 1) {
        const parsed = parseDraftComment(raw[i], `setDraftComments.comments[${i}]`);
        if (!parsed.ok) return fail(parsed.error);
        comments.push(parsed.value);
      }
      return ok({ v: PROTOCOL_VERSION, type: 'setDraftComments', comments });
    }
    case 'revealLine': {
      if (!isLineNumber(msg['line'])) return fail('revealLine.line: expected a 1-based line number');
      if (!isSide(msg['side'])) return fail('revealLine.side: expected "left" | "right"');
      return ok({ v: PROTOCOL_VERSION, type: 'revealLine', line: msg['line'], side: msg['side'] });
    }
    case 'setAccessibility': {
      const screenReader = msg['screenReader'];
      if (typeof screenReader !== 'boolean') {
        return fail('setAccessibility.screenReader: expected boolean');
      }
      return ok({ v: PROTOCOL_VERSION, type: 'setAccessibility', screenReader });
    }
    case 'setLocale': {
      if (!isNonEmptyString(msg['locale'])) return fail('setLocale.locale: expected non-empty string');
      const strings = parseViewerStrings(msg['strings'], 'setLocale.strings');
      if (!strings.ok) return fail(strings.error);
      return ok({ v: PROTOCOL_VERSION, type: 'setLocale', locale: msg['locale'], strings: strings.value });
    }
    case 'focusEditor': {
      // The command is almost the whole message: `side` is optional, and absent means the
      // modified pane. An unknown extra key is ignored here as it is for every other type —
      // the envelope's version is what a breaking change would move.
      const base: FocusEditorMessage = { v: PROTOCOL_VERSION, type: 'focusEditor' };
      const side = msg['side'];
      if (side === undefined || side === null) return ok(base);
      if (!isSide(side)) return fail('focusEditor.side: expected "left" | "right"');
      return ok({ ...base, side });
    }
    default:
      return fail(`message.type: unknown inbound message type ${JSON.stringify(type)}`);
  }
}

/**
 * Narrow a value to a web → Swift message. The viewer only ever *builds* these, but the
 * fixtures are validated with this so both directions of the contract are covered by tests
 * (and by the Swift decode tests over the same files).
 */
export function parseOutbound(value: unknown): ParseResult<OutboundMessage> {
  const head = envelope(value, 'message');
  if (!head.ok) return fail(head.error);
  const msg = head.value;
  const type = msg['type'] as string;

  switch (type) {
    case 'ready':
      return ok({ v: PROTOCOL_VERSION, type: 'ready' });
    case 'addComment': {
      if (!isLineNumber(msg['line'])) return fail('addComment.line: expected a 1-based line number');
      if (!isSide(msg['side'])) return fail('addComment.side: expected "left" | "right"');
      const startLine = msg['startLine'];
      if (startLine === undefined || startLine === null) {
        return ok({ v: PROTOCOL_VERSION, type: 'addComment', line: msg['line'], side: msg['side'] });
      }
      if (!isLineNumber(startLine)) return fail('addComment.startLine: expected a 1-based line number');
      if (startLine > msg['line']) return fail('addComment.startLine: must not be greater than line');
      return ok({ v: PROTOCOL_VERSION, type: 'addComment', line: msg['line'], side: msg['side'], startLine });
    }
    case 'commentClicked': {
      const threadID = msg['threadID'];
      const localID = msg['localID'];
      const hasThread = threadID !== undefined && threadID !== null;
      const hasLocal = localID !== undefined && localID !== null;
      if (hasThread === hasLocal) {
        return fail('commentClicked: exactly one of "threadID" / "localID" must be present');
      }
      if (hasThread) {
        if (!isString(threadID) || threadID.length === 0) return fail('commentClicked.threadID: expected non-empty string');
        return ok({ v: PROTOCOL_VERSION, type: 'commentClicked', threadID });
      }
      if (!isString(localID) || localID.length === 0) return fail('commentClicked.localID: expected non-empty string');
      return ok({ v: PROTOCOL_VERSION, type: 'commentClicked', localID });
    }
    case 'viewportChanged': {
      if (!isLineNumber(msg['firstVisibleLine'])) {
        return fail('viewportChanged.firstVisibleLine: expected a 1-based line number');
      }
      return ok({ v: PROTOCOL_VERSION, type: 'viewportChanged', firstVisibleLine: msg['firstVisibleLine'] });
    }
    default:
      return fail(`message.type: unknown outbound message type ${JSON.stringify(type)}`);
  }
}
