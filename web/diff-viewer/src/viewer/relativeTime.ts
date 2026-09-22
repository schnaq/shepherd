/** Compact relative timestamps for thread cards ("3h ago", "vor 3 Std."). Pure + testable. */

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const WEEK = 7 * DAY;
const YEAR = 365 * DAY;

type Unit = 'second' | 'minute' | 'hour' | 'day' | 'week' | 'year';

/** The elapsed time as one whole unit — the same buckets in every language. */
function bucket(delta: number): { readonly value: number; readonly unit: Unit } {
  if (delta < MINUTE) return { value: 0, unit: 'second' };
  if (delta < HOUR) return { value: Math.floor(delta / MINUTE), unit: 'minute' };
  if (delta < DAY) return { value: Math.floor(delta / HOUR), unit: 'hour' };
  if (delta < WEEK) return { value: Math.floor(delta / DAY), unit: 'day' };
  if (delta < YEAR) return { value: Math.floor(delta / WEEK), unit: 'week' };
  return { value: Math.floor(delta / YEAR), unit: 'year' };
}

const ENGLISH_SUFFIX: Readonly<Record<Unit, string>> = {
  second: '',
  minute: 'm',
  hour: 'h',
  day: 'd',
  week: 'w',
  year: 'y',
};

function english(value: number, unit: Unit): string {
  if (unit === 'second') return 'just now';
  return `${value}${ENGLISH_SUFFIX[unit]} ago`;
}

function isEnglish(locale: string): boolean {
  return locale === 'en' || locale.startsWith('en-');
}

/**
 * @param isoTimestamp ISO-8601 string as delivered by the bridge.
 * @param nowMs        Reference instant (injected so tests are deterministic).
 * @param locale       The app's language (`setLocale`), or `null` for the compact English the
 *                     viewer drew before it had one. English stays hand-written even when it is
 *                     sent — `Intl`'s short English ("3 hr. ago") is longer than the card wants —
 *                     and every other language goes through `Intl.RelativeTimeFormat`, whose
 *                     `short` style is the one that reads naturally in German ("vor 5 Min.",
 *                     where `narrow` gives "vor 5 m").
 * @returns A short label; the raw string is echoed back when it cannot be parsed.
 */
export function relativeTime(isoTimestamp: string, nowMs: number, locale: string | null = null): string {
  const then = Date.parse(isoTimestamp);
  if (Number.isNaN(then)) return isoTimestamp;

  // A clock a little behind GitHub's is "just now", not "in 2 minutes".
  const { value, unit } = bucket(Math.max(0, nowMs - then));
  if (locale === null || isEnglish(locale)) return english(value, unit);
  try {
    // `numeric: 'auto'` so zero seconds is the language's own "now" ("jetzt") and one day its
    // "yesterday" ("gestern"), rather than "vor 0 Sekunden".
    return new Intl.RelativeTimeFormat(locale, { numeric: 'auto', style: 'short' }).format(-value, unit);
  } catch {
    return english(value, unit);
  }
}

/**
 * Full timestamp for the card's `title` tooltip.
 *
 * In the app's language when there is one, in the Mac's own time zone (or `timeZone`, which is
 * how the tests pin it); without a locale, the zone-independent UTC form it always was.
 */
export function absoluteTime(isoTimestamp: string, locale: string | null = null, timeZone?: string): string {
  const then = new Date(isoTimestamp);
  if (Number.isNaN(then.getTime())) return isoTimestamp;
  if (locale !== null) {
    try {
      return new Intl.DateTimeFormat(locale, {
        dateStyle: 'medium',
        timeStyle: 'short',
        ...(timeZone === undefined ? {} : { timeZone }),
      }).format(then);
    } catch {
      // Fall through to the form that needs no locale.
    }
  }
  return then.toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
}
