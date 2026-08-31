import { describe, expect, it } from 'vitest';

import type { DraftComment, Thread } from '../src/bridge/protocol.js';
import {
  draftZoneKey,
  hostSide,
  threadZoneKey,
  toDraftZones,
  toThreadZones,
  ZoneStore,
  zoneSignature,
  zonesForSide,
  type Zone,
} from '../src/viewer/zoneState.js';

function thread(overrides: Partial<Thread> = {}): Thread {
  return {
    id: 'T1',
    line: 10,
    side: 'right',
    resolved: false,
    outdated: false,
    comments: [{ author: 'octocat', bodyHTML: '<p>hi</p>', createdAt: '2026-08-30T09:00:00Z', isAgent: false }],
    ...overrides,
  };
}

function draft(overrides: Partial<DraftComment> = {}): DraftComment {
  return { localID: 'D1', line: 4, side: 'right', body: 'nit', ...overrides };
}

describe('zone keys and mapping', () => {
  it('namespaces thread and draft keys so they cannot collide', () => {
    expect(threadZoneKey('X')).toBe('thread:X');
    expect(draftZoneKey('X')).toBe('draft:X');
    expect(threadZoneKey('X')).not.toBe(draftZoneKey('X'));
  });

  it('carries line/side onto the zone', () => {
    const [zone] = toThreadZones([thread({ line: 7, side: 'left' })]);
    expect(zone).toMatchObject({ kind: 'thread', line: 7, side: 'left', key: 'thread:T1' });

    const [draftZone] = toDraftZones([draft({ line: 3, side: 'left' })]);
    expect(draftZone).toMatchObject({ kind: 'draft', line: 3, side: 'left', key: 'draft:D1' });
  });
});

describe('zoneSignature', () => {
  it('is stable for identical content', () => {
    const [a] = toThreadZones([thread()]);
    const [b] = toThreadZones([thread()]);
    expect(zoneSignature(a as Zone)).toBe(zoneSignature(b as Zone));
  });

  it('changes when anything visible changes', () => {
    const base = toThreadZones([thread()])[0] as Zone;
    const variants: Thread[] = [
      thread({ line: 11 }),
      thread({ side: 'left' }),
      thread({ resolved: true }),
      thread({ outdated: true }),
      thread({ comments: [{ author: 'hubot', bodyHTML: '<p>hi</p>', createdAt: '2026-08-30T09:00:00Z', isAgent: false }] }),
      thread({ comments: [{ author: 'octocat', bodyHTML: '<p>ho</p>', createdAt: '2026-08-30T09:00:00Z', isAgent: false }] }),
      thread({ comments: [{ author: 'octocat', bodyHTML: '<p>hi</p>', createdAt: '2026-08-30T09:00:00Z', isAgent: true }] }),
      thread({ comments: [] }),
    ];
    for (const variant of variants) {
      const other = toThreadZones([variant])[0] as Zone;
      expect(zoneSignature(other)).not.toBe(zoneSignature(base));
    }
  });

  it('separates draft body and position changes', () => {
    const base = toDraftZones([draft()])[0] as Zone;
    expect(zoneSignature(toDraftZones([draft({ body: 'other' })])[0] as Zone)).not.toBe(zoneSignature(base));
    expect(zoneSignature(toDraftZones([draft({ line: 9 })])[0] as Zone)).not.toBe(zoneSignature(base));
    expect(zoneSignature(toDraftZones([draft()])[0] as Zone)).toBe(zoneSignature(base));
  });
});

describe('ZoneStore.apply', () => {
  it('reports everything as added on the first snapshot', () => {
    const store = new ZoneStore();
    const diff = store.apply(toThreadZones([thread(), thread({ id: 'T2', line: 20 })]));
    expect(diff.added.map((z) => z.key)).toEqual(['thread:T1', 'thread:T2']);
    expect(diff.updated).toEqual([]);
    expect(diff.removed).toEqual([]);
    expect(store.size).toBe(2);
  });

  it('is a no-op when the same snapshot is re-sent', () => {
    const store = new ZoneStore();
    store.apply(toThreadZones([thread()]));
    const diff = store.apply(toThreadZones([thread()]));
    expect(diff).toEqual({ added: [], updated: [], removed: [] });
  });

  it('marks a content change as updated, not add+remove', () => {
    const store = new ZoneStore();
    store.apply(toThreadZones([thread()]));
    const diff = store.apply(toThreadZones([thread({ resolved: true })]));
    expect(diff.updated.map((z) => z.key)).toEqual(['thread:T1']);
    expect(diff.added).toEqual([]);
    expect(diff.removed).toEqual([]);
  });

  it('marks a moved zone as updated', () => {
    const store = new ZoneStore();
    store.apply(toThreadZones([thread()]));
    expect(store.apply(toThreadZones([thread({ line: 12 })])).updated.map((z) => z.key)).toEqual(['thread:T1']);
  });

  it('removes zones that disappear from the snapshot', () => {
    const store = new ZoneStore();
    store.apply(toThreadZones([thread(), thread({ id: 'T2', line: 20 })]));
    const diff = store.apply(toThreadZones([thread({ id: 'T2', line: 20 })]));
    expect(diff.removed).toEqual(['thread:T1']);
    expect(store.size).toBe(1);
    expect(store.get('thread:T1')).toBeUndefined();
    expect(store.get('thread:T2')).toBeDefined();
  });

  it('handles a mixed add / update / remove snapshot', () => {
    const store = new ZoneStore();
    store.apply(toThreadZones([thread(), thread({ id: 'T2', line: 20 })]));
    const diff = store.apply(toThreadZones([thread({ line: 11 }), thread({ id: 'T3', line: 30 })]));
    expect(diff.updated.map((z) => z.key)).toEqual(['thread:T1']);
    expect(diff.added.map((z) => z.key)).toEqual(['thread:T3']);
    expect(diff.removed).toEqual(['thread:T2']);
  });

  it('empties out and reports every key as removed', () => {
    const store = new ZoneStore();
    store.apply(toDraftZones([draft(), draft({ localID: 'D2' })]));
    const diff = store.apply([]);
    expect([...diff.removed].sort()).toEqual(['draft:D1', 'draft:D2']);
    expect(store.size).toBe(0);
  });

  it('clear() drops state and returns the mounted keys', () => {
    const store = new ZoneStore();
    store.apply(toDraftZones([draft()]));
    expect(store.clear()).toEqual(['draft:D1']);
    expect(store.size).toBe(0);
    expect(store.apply(toDraftZones([draft()])).added.map((z) => z.key)).toEqual(['draft:D1']);
  });

  it('survives a duplicate key in one snapshot (last one wins)', () => {
    const store = new ZoneStore();
    const diff = store.apply(toThreadZones([thread({ line: 1 }), thread({ line: 2 })]));
    expect(diff.added).toHaveLength(1);
    expect(diff.added[0]?.line).toBe(2);
  });
});

describe('pane assignment', () => {
  it('keeps sides apart when rendering side-by-side', () => {
    expect(hostSide('left', 'sideBySide')).toBe('left');
    expect(hostSide('right', 'sideBySide')).toBe('right');
  });

  it('folds everything onto the modified pane in inline mode', () => {
    expect(hostSide('left', 'inline')).toBe('right');
    expect(hostSide('right', 'inline')).toBe('right');
  });

  it('partitions a zone list per pane', () => {
    const zones = [...toThreadZones([thread({ side: 'left' })]), ...toDraftZones([draft({ side: 'right' })])];
    expect(zonesForSide(zones, 'left', 'sideBySide').map((z) => z.key)).toEqual(['thread:T1']);
    expect(zonesForSide(zones, 'right', 'sideBySide').map((z) => z.key)).toEqual(['draft:D1']);
    expect(zonesForSide(zones, 'right', 'inline').map((z) => z.key)).toEqual(['thread:T1', 'draft:D1']);
    expect(zonesForSide(zones, 'left', 'inline')).toEqual([]);
  });
});
