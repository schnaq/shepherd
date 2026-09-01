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

export type InboundMessage =
  | LoadFileMessage
  | SetThemeMessage
  | SetThreadsMessage
  | SetDraftCommentsMessage
  | RevealLineMessage;

export type InboundMessageType = InboundMessage['type'];

export const INBOUND_MESSAGE_TYPES: readonly InboundMessageType[] = [
  'loadFile',
  'setTheme',
  'setThreads',
  'setDraftComments',
  'revealLine',
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
      const rawCommentable = msg['commentableLines'];
      if (rawCommentable === undefined || rawCommentable === null) return ok(base);
      const commentableLines = parseCommentableLines(rawCommentable, 'loadFile.commentableLines');
      if (!commentableLines.ok) return fail(commentableLines.error);
      return ok({ ...base, commentableLines: commentableLines.value });
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
