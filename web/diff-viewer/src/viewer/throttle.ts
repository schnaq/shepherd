/** Leading+trailing throttle with an injectable clock/timer so it can be unit-tested. */

export interface ThrottleClock {
  now(): number;
  setTimeout(handler: () => void, delayMs: number): number;
  clearTimeout(handle: number): void;
}

export const systemClock: ThrottleClock = {
  now: () => Date.now(),
  setTimeout: (handler, delayMs) => globalThis.setTimeout(handler, delayMs) as unknown as number,
  clearTimeout: (handle) => {
    globalThis.clearTimeout(handle);
  },
};

export interface Throttled<T> {
  (value: T): void;
  /** Emit a pending trailing value immediately (used on dispose). */
  flush(): void;
  cancel(): void;
}

/**
 * Calls `fn` at most once per `intervalMs`. The first call fires immediately; further calls
 * within the window are coalesced into a single trailing call carrying the newest value.
 */
export function throttle<T>(intervalMs: number, fn: (value: T) => void, clock: ThrottleClock = systemClock): Throttled<T> {
  let lastRun = Number.NEGATIVE_INFINITY;
  let timer: number | null = null;
  let pending: { value: T } | null = null;

  const run = (value: T): void => {
    lastRun = clock.now();
    fn(value);
  };

  const onTimer = (): void => {
    timer = null;
    if (pending === null) return;
    const { value } = pending;
    pending = null;
    run(value);
  };

  const throttled = ((value: T): void => {
    const elapsed = clock.now() - lastRun;
    if (elapsed >= intervalMs && timer === null) {
      run(value);
      return;
    }
    pending = { value };
    if (timer === null) {
      timer = clock.setTimeout(onTimer, Math.max(0, intervalMs - elapsed));
    }
  }) as Throttled<T>;

  throttled.flush = (): void => {
    if (timer !== null) {
      clock.clearTimeout(timer);
      timer = null;
    }
    if (pending === null) return;
    const { value } = pending;
    pending = null;
    run(value);
  };

  throttled.cancel = (): void => {
    if (timer !== null) {
      clock.clearTimeout(timer);
      timer = null;
    }
    pending = null;
  };

  return throttled;
}
