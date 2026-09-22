import { describe, expect, it, vi } from 'vitest';

import type { DraftComment, Thread, ThreadComment } from '../src/bridge/protocol.js';
import { makeLocale } from '../src/viewer/locale.js';
import { renderDraftZone, renderThreadZone, sanitizeInPlace } from '../src/viewer/threadCard.js';
import germanFixture from '../fixtures/setLocale.valid.json';

const NOW = Date.parse('2026-08-30T12:00:00Z');

function comment(overrides: Partial<ThreadComment> = {}): ThreadComment {
  return {
    author: 'octocat',
    bodyHTML: '<p>Looks good, but check the <code>nil</code> case.</p>',
    createdAt: '2026-08-30T09:00:00Z',
    isAgent: false,
    ...overrides,
  };
}

function thread(overrides: Partial<Thread> = {}): Thread {
  return {
    id: 'PRRT_1',
    line: 12,
    side: 'right',
    resolved: false,
    outdated: false,
    comments: [comment()],
    ...overrides,
  };
}

function options(onActivate: () => void = () => {}): { doc: Document; nowMs: number; onActivate: () => void } {
  return { doc: document, nowMs: NOW, onActivate };
}

describe('renderThreadZone', () => {
  it('renders author, relative time and the trusted body HTML', () => {
    const node = renderThreadZone(thread(), options());
    expect(node.querySelector('.sh-author')?.textContent).toBe('octocat');
    expect(node.querySelector('.sh-time')?.textContent).toBe('3h ago');
    expect(node.querySelector('.sh-time')?.getAttribute('title')).toBe('2026-08-30 09:00:00 UTC');
    expect(node.querySelector('.sh-comment__body code')?.textContent).toBe('nil');
  });

  it('tags the zone with its identity and side', () => {
    const node = renderThreadZone(thread({ side: 'left' }), options());
    expect(node.dataset['threadId']).toBe('PRRT_1');
    expect(node.getAttribute('data-side')).toBe('left');
  });

  it('adds a 🤖 badge only for agent authors', () => {
    const human = renderThreadZone(thread(), options());
    expect(human.querySelector('.sh-badge--agent')).toBeNull();

    const agent = renderThreadZone(thread({ comments: [comment({ author: 'claude-code', isAgent: true })] }), options());
    const badge = agent.querySelector('.sh-badge--agent');
    expect(badge?.textContent).toBe('🤖');
    expect(badge?.getAttribute('aria-label')).toBe('Agent');
  });

  it('stacks every comment in the thread', () => {
    const node = renderThreadZone(
      thread({ comments: [comment(), comment({ author: 'hubot', createdAt: '2026-08-30T11:59:30Z' })] }),
      options(),
    );
    expect(node.querySelectorAll('.sh-comment')).toHaveLength(2);
    expect([...node.querySelectorAll('.sh-author')].map((n) => n.textContent)).toEqual(['octocat', 'hubot']);
    expect([...node.querySelectorAll('.sh-time')].map((n) => n.textContent)).toEqual(['3h ago', 'just now']);
  });

  it('collapses a resolved thread to a one-line pill', () => {
    const node = renderThreadZone(thread({ resolved: true }), options());
    expect(node.classList.contains('sh-zone--resolved')).toBe(true);
    expect(node.querySelector('.sh-card')).toBeNull();
    expect(node.querySelector('.sh-pill--resolved')?.textContent).toBe('✓');
    expect(node.querySelector('.sh-collapsed__text')?.textContent).toBe('Resolved · octocat · 1 comment · 3h ago');
  });

  it('pluralises the collapsed comment count', () => {
    const node = renderThreadZone(thread({ resolved: true, comments: [comment(), comment()] }), options());
    expect(node.querySelector('.sh-collapsed__text')?.textContent).toContain('2 comments');
  });

  it('flags outdated threads in both the expanded and collapsed shapes', () => {
    const expanded = renderThreadZone(thread({ outdated: true }), options());
    expect(expanded.classList.contains('sh-zone--outdated')).toBe(true);
    expect(expanded.querySelector('.sh-pill--outdated')?.textContent).toBe('Outdated');

    const collapsed = renderThreadZone(thread({ outdated: true, resolved: true }), options());
    expect(collapsed.querySelector('.sh-pill--outdated')).not.toBeNull();
  });

  it('survives a thread with no comments', () => {
    const node = renderThreadZone(thread({ comments: [] }), options());
    expect(node.querySelector('.sh-empty')?.textContent).toBe('No comments.');
  });

  it('posts commentClicked on click and on keyboard activation', () => {
    const onActivate = vi.fn();
    const node = renderThreadZone(thread(), options(onActivate));
    expect(node.getAttribute('role')).toBe('button');
    expect(node.getAttribute('tabindex')).toBe('0');

    node.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    node.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    node.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }));
    node.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }));

    expect(onActivate).toHaveBeenCalledTimes(3);
  });
});

describe('in the language the app sends (setLocale)', () => {
  // The German the app actually sends, straight from the shared fixture.
  const german = makeLocale(germanFixture.locale, germanFixture.strings);
  const inGerman = (onActivate: () => void = () => {}) => ({
    ...options(onActivate),
    locale: german,
    timeZone: 'UTC',
  });

  it('draws every pill and label in German', () => {
    const outdated = renderThreadZone(thread({ outdated: true }), inGerman());
    expect(outdated.querySelector('.sh-pill--outdated')?.textContent).toBe('Veraltet');
    expect(renderThreadZone(thread({ comments: [] }), inGerman()).querySelector('.sh-empty')?.textContent).toBe(
      'Keine Kommentare.',
    );
    const draft = renderDraftZone({ localID: 'D', line: 1, side: 'right', body: 'x' }, inGerman());
    expect(draft.querySelector('.sh-pill--pending')?.textContent).toBe('Offen');
  });

  it('names the agent badge in German, for the pointer and for VoiceOver', () => {
    const node = renderThreadZone(thread({ comments: [comment({ isAgent: true })] }), inGerman());
    const badge = node.querySelector('.sh-badge--agent');
    expect(badge?.getAttribute('title')).toBe('Von einem Agenten gepostet');
    expect(badge?.getAttribute('aria-label')).toBe('Agent');
  });

  it('collapses a resolved thread with a German plural and a German relative time', () => {
    const one = renderThreadZone(thread({ resolved: true }), inGerman());
    expect(one.querySelector('.sh-collapsed__text')?.textContent).toBe('Aufgelöst · octocat · 1 Kommentar · vor 3 Std.');
    const two = renderThreadZone(thread({ resolved: true, comments: [comment(), comment()] }), inGerman());
    expect(two.querySelector('.sh-collapsed__text')?.textContent).toContain('2 Kommentare');
    const none = renderThreadZone(thread({ resolved: true, comments: [] }), inGerman());
    expect(none.querySelector('.sh-collapsed__text')?.textContent).toBe('Aufgelöst · unbekannt · 0 Kommentare');
  });

  it('formats the tooltip in the language and the zone it is given', () => {
    const node = renderThreadZone(thread(), inGerman());
    expect(node.querySelector('.sh-time')?.getAttribute('title')).toBe('30.08.2026, 09:00');
  });
});

describe('renderDraftZone', () => {
  const draft: DraftComment = { localID: 'D-1', line: 4, side: 'right', body: 'Hoist this out of the loop.' };

  it('renders a dashed pending card with the body as plain text', () => {
    const node = renderDraftZone(draft, options());
    expect(node.classList.contains('sh-zone--draft')).toBe(true);
    expect(node.dataset['localId']).toBe('D-1');
    expect(node.querySelector('.sh-card--draft')).not.toBeNull();
    expect(node.querySelector('.sh-pill--pending')?.textContent).toBe('Pending');
    expect(node.querySelector('.sh-draft__body')?.textContent).toBe('Hoist this out of the loop.');
  });

  it('never interprets a draft body as HTML', () => {
    const node = renderDraftZone({ ...draft, body: '<img src=x onerror=alert(1)>' }, options());
    const body = node.querySelector('.sh-draft__body');
    expect(body?.querySelector('img')).toBeNull();
    expect(body?.textContent).toBe('<img src=x onerror=alert(1)>');
  });

  it('is clickable', () => {
    const onActivate = vi.fn();
    const node = renderDraftZone(draft, options(onActivate));
    node.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    expect(onActivate).toHaveBeenCalledOnce();
  });
});

describe('sanitizeInPlace (belt-and-braces over trusted-from-native HTML)', () => {
  function scrub(html: string): HTMLElement {
    const host = document.createElement('div');
    host.innerHTML = html;
    sanitizeInPlace(host);
    return host;
  }

  it('drops executable elements', () => {
    const host = scrub('<p>ok</p><script>alert(1)</script><iframe src="x"></iframe><style>p{}</style>');
    expect(host.querySelector('script')).toBeNull();
    expect(host.querySelector('iframe')).toBeNull();
    expect(host.querySelector('style')).toBeNull();
    expect(host.querySelector('p')?.textContent).toBe('ok');
  });

  it('strips every inline event handler', () => {
    const host = scrub('<div onclick="x()" ONMOUSEOVER="y()" data-keep="1">hi</div>');
    const div = host.querySelector('div');
    expect(div?.getAttribute('onclick')).toBeNull();
    expect(div?.getAttribute('onmouseover')).toBeNull();
    expect(div?.getAttribute('data-keep')).toBe('1');
  });

  it('neutralises javascript: URLs, including obfuscated ones', () => {
    const host = scrub('<a href="javascript:alert(1)">a</a><a href="JaVaScRiPt:alert(1)">b</a><a href="jav\tascript:alert(1)">c</a>');
    for (const anchor of host.querySelectorAll('a')) expect(anchor.getAttribute('href')).toBeNull();
  });

  it('keeps safe links but hardens them', () => {
    const host = scrub('<a href="https://github.com/x/y/pull/1">PR</a>');
    const anchor = host.querySelector('a');
    expect(anchor?.getAttribute('href')).toBe('https://github.com/x/y/pull/1');
    expect(anchor?.getAttribute('rel')).toBe('noopener noreferrer');
  });

  it('blocks data:text/html but allows inline images', () => {
    const host = scrub('<a href="data:text/html;base64,PHNjcmlwdD4="></a><img src="data:image/png;base64,iVBOR">');
    expect(host.querySelector('a')?.getAttribute('href')).toBeNull();
    expect(host.querySelector('img')?.getAttribute('src')).toContain('data:image/png');
  });

  it('runs on the rendered thread body, not only in isolation', () => {
    const node = renderThreadZone(
      thread({ comments: [comment({ bodyHTML: '<p onclick="boom()">x</p><script>boom()</script>' })] }),
      options(),
    );
    const body = node.querySelector('.sh-comment__body');
    expect(body?.querySelector('script')).toBeNull();
    expect(body?.querySelector('p')?.getAttribute('onclick')).toBeNull();
  });
});
