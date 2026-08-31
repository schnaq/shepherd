/**
 * Bookkeeping for the Monaco view zones that host review threads and pending drafts.
 *
 * Monaco view zones are imperative (`changeViewZones` → `addZone`/`removeZone`), so the viewer
 * needs to know exactly which zones to add, drop, or re-render whenever Swift pushes a new
 * `setThreads` / `setDraftComments` snapshot. All of that reconciliation lives here as pure
 * data so it can be tested without booting Monaco.
 */

import type { DraftComment, Side, Thread } from '../bridge/protocol.js';

export type ZoneKind = 'thread' | 'draft';

export interface ThreadZone {
  readonly key: string;
  readonly kind: 'thread';
  readonly side: Side;
  readonly line: number;
  readonly thread: Thread;
}

export interface DraftZone {
  readonly key: string;
  readonly kind: 'draft';
  readonly side: Side;
  readonly line: number;
  readonly draft: DraftComment;
}

export type Zone = ThreadZone | DraftZone;

export interface ZoneDiff {
  readonly added: readonly Zone[];
  /** Zones whose content or position changed — remove + re-add. */
  readonly updated: readonly Zone[];
  /** Keys of zones that disappeared. */
  readonly removed: readonly string[];
}

export function threadZoneKey(threadID: string): string {
  return `thread:${threadID}`;
}

export function draftZoneKey(localID: string): string {
  return `draft:${localID}`;
}

export function toThreadZones(threads: readonly Thread[]): ThreadZone[] {
  return threads.map((thread) => ({
    key: threadZoneKey(thread.id),
    kind: 'thread',
    side: thread.side,
    line: thread.line,
    thread,
  }));
}

export function toDraftZones(comments: readonly DraftComment[]): DraftZone[] {
  return comments.map((draft) => ({
    key: draftZoneKey(draft.localID),
    kind: 'draft',
    side: draft.side,
    line: draft.line,
    draft,
  }));
}

/**
 * Stable content signature. Two zones with the same signature render identically, so the
 * viewer can leave the existing Monaco zone untouched (avoids scroll jumps on re-sync).
 */
export function zoneSignature(zone: Zone): string {
  if (zone.kind === 'thread') {
    const t = zone.thread;
    const comments = t.comments
      .map((c) => [c.author, c.createdAt, c.isAgent ? '1' : '0', c.bodyHTML].join(''))
      .join('');
    return ['thread', t.side, String(t.line), t.resolved ? '1' : '0', t.outdated ? '1' : '0', comments].join('');
  }
  const d = zone.draft;
  return ['draft', d.side, String(d.line), d.body].join('');
}

interface Entry {
  readonly zone: Zone;
  readonly signature: string;
}

/**
 * Holds the zones currently mounted for one kind (threads or drafts) and computes the minimal
 * mutation needed to reach a new snapshot.
 */
export class ZoneStore {
  private entries = new Map<string, Entry>();

  /** Compute the diff for `next` and record it as the new current state. */
  apply(next: readonly Zone[]): ZoneDiff {
    const added: Zone[] = [];
    const updated: Zone[] = [];
    const removed: string[] = [];
    const nextEntries = new Map<string, Entry>();

    for (const zone of next) {
      const signature = zoneSignature(zone);
      // A duplicate key in one snapshot is a native-side bug; last one wins, deterministically.
      nextEntries.set(zone.key, { zone, signature });
    }

    for (const [key, entry] of nextEntries) {
      const previous = this.entries.get(key);
      if (previous === undefined) added.push(entry.zone);
      else if (previous.signature !== entry.signature) updated.push(entry.zone);
    }

    for (const key of this.entries.keys()) {
      if (!nextEntries.has(key)) removed.push(key);
    }

    this.entries = nextEntries;
    return { added, updated, removed };
  }

  keys(): string[] {
    return [...this.entries.keys()];
  }

  get(key: string): Zone | undefined {
    return this.entries.get(key)?.zone;
  }

  get size(): number {
    return this.entries.size;
  }

  /** Drop everything (used when a new file is loaded). Returns the keys that were mounted. */
  clear(): string[] {
    const keys = this.keys();
    this.entries = new Map();
    return keys;
  }
}

/**
 * Which diff pane hosts a zone.
 *
 * Side-by-side: the pane matching the zone's `side`. Inline: there is only the modified pane,
 * so every zone lands on `'right'` — exact for right-side threads, approximate for left-side
 * ones (their line number refers to the original model). Documented in `README.md`.
 */
export function hostSide(zoneSide: Side, mode: 'sideBySide' | 'inline'): Side {
  return mode === 'inline' ? 'right' : zoneSide;
}

/** Zones belonging to one pane, for a given render mode. */
export function zonesForSide(zones: readonly Zone[], side: Side, mode: 'sideBySide' | 'inline'): Zone[] {
  return zones.filter((zone) => hostSide(zone.side, mode) === side);
}
