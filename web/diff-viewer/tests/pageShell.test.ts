/**
 * Guards the two hard promises of ADR 0003 for the page shell that WKWebView loads:
 * everything resolves relatively (so `loadFileURL` works from any bundle path) and nothing can
 * reach the network at runtime.
 */

import { readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

const html = readFileSync(path.resolve(process.cwd(), 'src', 'index.html'), 'utf8');

function cspDirectives(): Map<string, string[]> {
  const policy = [...html.matchAll(/content="([^"]*)"/g)].map((m) => m[1] ?? '').find((v) => v.includes('default-src'));
  expect(policy, 'no Content-Security-Policy meta tag').toBeDefined();
  const directives = new Map<string, string[]>();
  for (const part of (policy ?? '').split(';')) {
    const [name, ...values] = part.trim().split(/\s+/);
    if (name !== undefined && name.length > 0) directives.set(name, values);
  }
  return directives;
}

describe('dist/index.html shell', () => {
  it('references its siblings by relative path only', () => {
    const references = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1] ?? '');
    expect(references.length).toBeGreaterThan(0);
    for (const reference of references) {
      expect(reference.startsWith('./'), `${reference} is not relative`).toBe(true);
      expect(reference).not.toContain('//');
    }
    expect(references).toContain('./viewer.js');
    expect(references).toContain('./viewer.css');
  });

  it('mounts the container and the error surface the bundle expects', () => {
    expect(html).toContain('id="shepherd-diff"');
    expect(html).toContain('id="shepherd-error"');
  });

  it('forbids every network fetch through CSP', () => {
    const csp = cspDirectives();
    expect(csp.get('default-src')).toEqual(["'none'"]);
    expect(csp.get('connect-src')).toEqual(["'none'"]);
    expect(csp.get('form-action')).toEqual(["'none'"]);
    expect(csp.get('base-uri')).toEqual(["'none'"]);
  });

  it('allows only local and blob: sources', () => {
    const csp = cspDirectives();
    const allowed = new Set(["'self'", "'unsafe-inline'", "'unsafe-eval'", "'none'", 'blob:', 'data:']);
    for (const [directive, values] of csp) {
      for (const value of values) {
        expect(allowed, `${directive} allows ${value}`).toContain(value);
      }
    }
  });

  it('permits the blob: worker the viewer depends on', () => {
    const csp = cspDirectives();
    expect(csp.get('worker-src')).toContain('blob:');
    expect(csp.get('script-src')).toContain('blob:');
  });
});
