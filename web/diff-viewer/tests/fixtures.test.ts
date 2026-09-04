/**
 * The cross-language contract test.
 *
 * Every file in `fixtures/` is decoded here with the TypeScript validators. The Swift side
 * decodes the *same files* with `BridgeProtocol.swift`, so this suite failing (or the Swift one
 * failing) is the signal that the two implementations have drifted apart.
 */

import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  INBOUND_MESSAGE_TYPES,
  OUTBOUND_MESSAGE_TYPES,
  parseInbound,
  parseOutbound,
  type InboundMessageType,
  type OutboundMessageType,
} from '../src/bridge/protocol.js';

// Resolved from the project root: vitest sets cwd to the directory holding vitest.config.ts.
const fixturesDir = path.resolve(process.cwd(), 'fixtures');

interface Fixture {
  readonly file: string;
  readonly messageType: string;
  readonly expectValid: boolean;
  readonly json: unknown;
}

function loadFixtures(): Fixture[] {
  return readdirSync(fixturesDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((file) => {
      const [messageType = '', kind = ''] = file.replace(/\.json$/, '').split('.');
      return {
        file,
        messageType,
        expectValid: kind.startsWith('valid'),
        json: JSON.parse(readFileSync(path.join(fixturesDir, file), 'utf8')) as unknown,
      };
    });
}

const fixtures = loadFixtures();

function parseFor(messageType: string, value: unknown): { ok: boolean; error?: string } {
  return (INBOUND_MESSAGE_TYPES as readonly string[]).includes(messageType) ? parseInbound(value) : parseOutbound(value);
}

describe('shared bridge fixtures', () => {
  it('finds fixtures on disk', () => {
    expect(fixtures.length).toBeGreaterThan(0);
  });

  it('uses only the documented <type>.valid[-variant]|invalid.json naming', () => {
    const known = new Set<string>([...INBOUND_MESSAGE_TYPES, ...OUTBOUND_MESSAGE_TYPES]);
    for (const fixture of fixtures) {
      expect(known, `${fixture.file} names an unknown message type`).toContain(fixture.messageType);
      expect(/\.(valid(-[a-z]+)?|invalid)\.json$/.test(fixture.file), `${fixture.file} is misnamed`).toBe(true);
    }
  });

  it.each(fixtures.filter((f) => f.expectValid).map((f) => [f.file, f] as const))('%s decodes', (_file, fixture) => {
    const result = parseFor(fixture.messageType, fixture.json);
    expect(result.ok ? null : result.error).toBeNull();
  });

  it.each(fixtures.filter((f) => !f.expectValid).map((f) => [f.file, f] as const))('%s is rejected', (_file, fixture) => {
    expect(parseFor(fixture.messageType, fixture.json).ok).toBe(false);
  });

  it('carries v:1 on every fixture except the deliberate version-mismatch ones', () => {
    // Two messages require nothing but their envelope — `ready` on the way out and
    // `focusEditor` on the way in, whose only field is optional — so a version mismatch is the
    // rejection their invalid fixture is for. On purpose, and it is the envelope's own rule.
    const versionMismatch = new Set(['ready.invalid.json', 'focusEditor.invalid.json']);
    for (const fixture of fixtures) {
      const envelope = fixture.json as { v?: unknown; type?: unknown };
      expect(envelope.type).toBe(fixture.messageType);
      if (!versionMismatch.has(fixture.file)) expect(envelope.v).toBe(1);
    }
  });

  it('covers every message type in both directions with a valid and an invalid case', () => {
    const all: readonly (InboundMessageType | OutboundMessageType)[] = [
      ...INBOUND_MESSAGE_TYPES,
      ...OUTBOUND_MESSAGE_TYPES,
    ];
    for (const messageType of all) {
      const own = fixtures.filter((f) => f.messageType === messageType);
      expect(own.some((f) => f.expectValid), `${messageType} has no valid fixture`).toBe(true);
      expect(own.some((f) => !f.expectValid), `${messageType} has no invalid fixture`).toBe(true);
    }
  });
});
