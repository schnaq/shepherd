import { describe, expect, it } from 'vitest';

import { throttle, type ThrottleClock } from '../src/viewer/throttle.js';

interface FakeClock extends ThrottleClock {
  advance(ms: number): void;
}

function fakeClock(): FakeClock {
  let current = 1_000;
  let nextHandle = 1;
  const timers = new Map<number, { at: number; handler: () => void }>();

  return {
    now: () => current,
    setTimeout(handler, delayMs) {
      const handle = nextHandle++;
      timers.set(handle, { at: current + delayMs, handler });
      return handle;
    },
    clearTimeout(handle) {
      timers.delete(handle);
    },
    advance(ms) {
      const target = current + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at);
        const next = due[0];
        if (next === undefined) break;
        timers.delete(next[0]);
        current = next[1].at;
        next[1].handler();
      }
      current = target;
    },
  };
}

describe('throttle', () => {
  it('fires the first call immediately', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);
    t(1);
    expect(seen).toEqual([1]);
  });

  it('coalesces a burst into one trailing call with the newest value', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);

    t(1);
    t(2);
    t(3);
    t(4);
    expect(seen).toEqual([1]);

    clock.advance(100);
    expect(seen).toEqual([1, 4]);
  });

  it('fires immediately again once the window has passed', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);

    t(1);
    clock.advance(150);
    t(2);
    expect(seen).toEqual([1, 2]);
  });

  it('does not fire a trailing call when nothing was coalesced', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);

    t(1);
    clock.advance(1000);
    expect(seen).toEqual([1]);
  });

  it('flush() emits the pending value at once', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);

    t(1);
    t(2);
    t.flush();
    expect(seen).toEqual([1, 2]);

    // The timer must not fire a second time.
    clock.advance(500);
    expect(seen).toEqual([1, 2]);
  });

  it('cancel() drops the pending value', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);

    t(1);
    t(2);
    t.cancel();
    clock.advance(500);
    expect(seen).toEqual([1]);

    t.flush();
    expect(seen).toEqual([1]);
  });

  it('keeps at most one call per window over a long scroll', () => {
    const clock = fakeClock();
    const seen: number[] = [];
    const t = throttle<number>(100, (v) => seen.push(v), clock);

    for (let i = 0; i < 50; i += 1) {
      t(i);
      clock.advance(10);
    }
    t.flush();

    expect(seen.length).toBeLessThanOrEqual(7);
    expect(seen[0]).toBe(0);
    expect(seen.at(-1)).toBe(49);
  });
});
