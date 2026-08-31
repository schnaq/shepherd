import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // jsdom for the DOM-building modules (thread cards, bridge globals). Monaco itself is
    // never booted in tests — it needs a real layout engine and web workers.
    environment: 'jsdom',
    include: ['tests/**/*.test.ts'],
    globals: false,
    restoreMocks: true,
  },
});
