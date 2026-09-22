/**
 * The viewer's own words, and the language they are in.
 *
 * The app sends both over the bridge (`setLocale`, ADR 0022's second amendment); until it does,
 * and in every test and the dev harness, the viewer speaks the English below. Pure + testable.
 */

import type { ViewerStrings } from '../bridge/protocol.js';

/** What the viewer says before — or without — a `setLocale`. Also the English the app sends. */
export const ENGLISH_STRINGS: ViewerStrings = {
  resolved: 'Resolved',
  outdated: 'Outdated',
  pending: 'Pending',
  noComments: 'No comments.',
  unknownAuthor: 'unknown',
  agentBadgeTitle: 'Posted by an agent',
  agentBadgeLabel: 'Agent',
  addComment: 'Add a review comment',
  commentCount: { one: '1 comment', other: '{count} comments' },
};

/** The words to draw with, and the language `Intl` formats times and plurals in. */
export interface ViewerLocale {
  /**
   * A BCP 47 tag `Intl` accepted, or `null` for "no locale was sent", which keeps the compact
   * English relative times this viewer has always drawn.
   */
  readonly locale: string | null;
  readonly strings: ViewerStrings;
}

export const DEFAULT_LOCALE: ViewerLocale = { locale: null, strings: ENGLISH_STRINGS };

/**
 * The locale to format with, or `null` when `Intl` will not take the tag.
 *
 * `Locale.current.identifier` on the Swift side is `de_DE`, which `Intl` rejects with a
 * `RangeError`; the app sends a language tag instead, and this is the guard for the day it does
 * not.
 */
export function canonicalLocale(tag: string): string | null {
  try {
    return Intl.getCanonicalLocales(tag)[0] ?? null;
  } catch {
    return null;
  }
}

/** Builds the viewer's locale from what the app sent. */
export function makeLocale(tag: string, strings: ViewerStrings): ViewerLocale {
  return { locale: canonicalLocale(tag), strings };
}

/** "1 comment" / "3 Kommentare": a whole phrase picked by the locale's plural rules. */
export function commentCount(count: number, locale: ViewerLocale): string {
  let category: Intl.LDMLPluralRule = count === 1 ? 'one' : 'other';
  if (locale.locale !== null) {
    try {
      category = new Intl.PluralRules(locale.locale).select(count);
    } catch {
      // Keep the English rule, which is also German's.
    }
  }
  const template = category === 'one' ? locale.strings.commentCount.one : locale.strings.commentCount.other;
  return template.replace(/\{count\}/g, String(count));
}
