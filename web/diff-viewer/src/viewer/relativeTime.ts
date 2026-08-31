/** Compact relative timestamps for thread cards ("3h", "2d", "5 Mar 2026"). Pure + testable. */

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const WEEK = 7 * DAY;
const YEAR = 365 * DAY;

/**
 * @param isoTimestamp ISO-8601 string as delivered by the bridge.
 * @param nowMs        Reference instant (injected so tests are deterministic).
 * @returns A short label; the raw string is echoed back when it cannot be parsed.
 */
export function relativeTime(isoTimestamp: string, nowMs: number): string {
  const then = Date.parse(isoTimestamp);
  if (Number.isNaN(then)) return isoTimestamp;

  const delta = nowMs - then;
  if (delta < 0) return 'just now';
  if (delta < MINUTE) return 'just now';
  if (delta < HOUR) return `${Math.floor(delta / MINUTE)}m ago`;
  if (delta < DAY) return `${Math.floor(delta / HOUR)}h ago`;
  if (delta < WEEK) return `${Math.floor(delta / DAY)}d ago`;
  if (delta < YEAR) return `${Math.floor(delta / WEEK)}w ago`;
  const years = Math.floor(delta / YEAR);
  return `${years}y ago`;
}

/** Full timestamp for the card's `title` tooltip. */
export function absoluteTime(isoTimestamp: string): string {
  const then = new Date(isoTimestamp);
  if (Number.isNaN(then.getTime())) return isoTimestamp;
  return then.toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
}
