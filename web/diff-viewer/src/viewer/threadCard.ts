/**
 * DOM for the review-thread and draft-comment view zones.
 *
 * ## Trust model for `bodyHTML`
 *
 * `ThreadComment.bodyHTML` is **trusted-from-native**: Swift renders the GitHub markdown and
 * sanitizes the result before it ever reaches the webview, which has no network access of its
 * own (ADR 0003: `file://` origin, no remote loads). We therefore assign it with `innerHTML`.
 *
 * Because trust boundaries drift, `sanitizeInPlace` still runs over the parsed fragment and
 * removes anything that could execute: `<script>`/`<style>`/`<iframe>`/`<object>` elements,
 * every `on*` inline handler, and `javascript:` URLs. No inline event handlers are ever
 * emitted by this module — interaction is wired with `addEventListener`.
 *
 * Draft bodies are plain text and go in via `textContent`, never `innerHTML`.
 */

import type { DraftComment, Thread } from '../bridge/protocol.js';
import { absoluteTime, relativeTime } from './relativeTime.js';

const FORBIDDEN_TAGS: ReadonlySet<string> = new Set([
  'SCRIPT',
  'STYLE',
  'IFRAME',
  'OBJECT',
  'EMBED',
  'LINK',
  'META',
  'BASE',
  'FORM',
  'INPUT',
  'BUTTON',
  'TEXTAREA',
]);

const URL_ATTRIBUTES: readonly string[] = ['href', 'src', 'xlink:href', 'action', 'formaction'];

function isDangerousURL(value: string): boolean {
  // Strip control chars/whitespace the way browsers do before matching the scheme.
  const normalized = value.replace(/[\u0000-\u0020]/g, '').toLowerCase();
  return normalized.startsWith('javascript:') || normalized.startsWith('vbscript:') || normalized.startsWith('data:text/html');
}

/** Belt-and-braces scrub of a parsed fragment. Exported for tests. */
export function sanitizeInPlace(root: ParentNode): void {
  const elements = [...root.querySelectorAll('*')];
  for (const element of elements) {
    if (FORBIDDEN_TAGS.has(element.tagName.toUpperCase())) {
      element.remove();
      continue;
    }
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on')) {
        element.removeAttribute(attribute.name);
        continue;
      }
      if (URL_ATTRIBUTES.includes(name) && isDangerousURL(attribute.value)) {
        element.removeAttribute(attribute.name);
      }
    }
    if (element.tagName.toUpperCase() === 'A') {
      element.setAttribute('rel', 'noopener noreferrer');
    }
  }
}

function el(doc: Document, tag: string, className?: string, text?: string): HTMLElement {
  const node = doc.createElement(tag);
  if (className !== undefined) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function pill(doc: Document, className: string, text: string): HTMLElement {
  return el(doc, 'span', `sh-pill ${className}`, text);
}

export interface CardOptions {
  readonly doc: Document;
  /** Reference instant for relative times (injected for deterministic tests). */
  readonly nowMs: number;
  /** Invoked on click / Enter / Space. */
  readonly onActivate: () => void;
}

function makeInteractive(root: HTMLElement, onActivate: () => void): void {
  root.setAttribute('role', 'button');
  root.setAttribute('tabindex', '0');
  root.addEventListener('click', (event) => {
    event.stopPropagation();
    onActivate();
  });
  root.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    event.stopPropagation();
    onActivate();
  });
}

function commentNode(doc: Document, comment: Thread['comments'][number], nowMs: number): HTMLElement {
  const wrapper = el(doc, 'div', 'sh-comment');

  const head = el(doc, 'div', 'sh-comment__head');
  head.append(el(doc, 'span', 'sh-author', comment.author));
  if (comment.isAgent) {
    const badge = el(doc, 'span', 'sh-badge sh-badge--agent', '🤖');
    badge.setAttribute('title', 'Posted by an agent');
    badge.setAttribute('aria-label', 'Agent');
    head.append(badge);
  }
  const time = el(doc, 'span', 'sh-time', relativeTime(comment.createdAt, nowMs));
  time.setAttribute('title', absoluteTime(comment.createdAt));
  head.append(time);
  wrapper.append(head);

  // Trusted-from-native HTML — see the module docblock.
  const body = el(doc, 'div', 'sh-comment__body');
  body.innerHTML = comment.bodyHTML;
  sanitizeInPlace(body);
  wrapper.append(body);

  return wrapper;
}

/** Full or collapsed card for a published review thread. */
export function renderThreadZone(thread: Thread, options: CardOptions): HTMLElement {
  const { doc, nowMs } = options;
  const root = el(doc, 'div', 'sh-zone sh-zone--thread');
  root.dataset['threadId'] = thread.id;
  root.setAttribute('data-side', thread.side);
  if (thread.outdated) root.classList.add('sh-zone--outdated');

  if (thread.resolved) {
    root.classList.add('sh-zone--resolved');
    const first = thread.comments[0];
    const count = thread.comments.length;
    const parts = [
      'Resolved',
      first?.author ?? 'unknown',
      `${count} ${count === 1 ? 'comment' : 'comments'}`,
    ];
    if (first !== undefined) parts.push(relativeTime(first.createdAt, nowMs));
    const line = el(doc, 'div', 'sh-zone__collapsed');
    line.append(pill(doc, 'sh-pill--resolved', '✓'));
    line.append(el(doc, 'span', 'sh-collapsed__text', parts.join(' · ')));
    if (thread.outdated) line.append(pill(doc, 'sh-pill--outdated', 'Outdated'));
    root.append(line);
    makeInteractive(root, options.onActivate);
    return root;
  }

  const card = el(doc, 'div', 'sh-card');
  if (thread.outdated) {
    const head = el(doc, 'div', 'sh-card__flags');
    head.append(pill(doc, 'sh-pill--outdated', 'Outdated'));
    card.append(head);
  }
  for (const comment of thread.comments) card.append(commentNode(doc, comment, nowMs));
  if (thread.comments.length === 0) {
    card.append(el(doc, 'div', 'sh-comment__body sh-empty', 'No comments.'));
  }
  root.append(card);
  makeInteractive(root, options.onActivate);
  return root;
}

/** Visually distinct "pending" card for a local draft comment. */
export function renderDraftZone(draft: DraftComment, options: CardOptions): HTMLElement {
  const { doc } = options;
  const root = el(doc, 'div', 'sh-zone sh-zone--draft');
  root.dataset['localId'] = draft.localID;
  root.setAttribute('data-side', draft.side);

  const card = el(doc, 'div', 'sh-card sh-card--draft');
  const head = el(doc, 'div', 'sh-card__flags');
  head.append(pill(doc, 'sh-pill--pending', 'Pending'));
  card.append(head);
  // Plain text — never innerHTML.
  card.append(el(doc, 'div', 'sh-comment__body sh-draft__body', draft.body));
  root.append(card);
  makeInteractive(root, options.onActivate);
  return root;
}
