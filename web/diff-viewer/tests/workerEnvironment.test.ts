/**
 * The worker-loading contract.
 *
 * WKWebView loads `index.html` from a `file://` URL, which gives the page an opaque origin
 * where `new Worker('./editor.worker.js')` is refused. The viewer therefore builds the worker
 * from a `blob:` URL whose script text is inlined into the bundle. These tests pin that
 * behaviour (blob first, classic worker, relative-path fallback) — the parts that can be
 * verified without a real WebKit process.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import workerSource from './stubs/editorWorkerSource.js';

interface WorkerCall {
  readonly url: string;
  readonly options: WorkerOptions | undefined;
}

const created: WorkerCall[] = [];
const blobParts: string[] = [];

let objectURLCalls = 0;
let createObjectURLImpl: () => string;
let workerGuard: (url: string) => void;
let originalBlob: unknown;
let originalWorker: unknown;
let originalCreateObjectURL: unknown;

const globals = globalThis as unknown as Record<string, unknown>;

beforeEach(() => {
  created.length = 0;
  blobParts.length = 0;
  objectURLCalls = 0;
  createObjectURLImpl = () => 'blob:shepherd/worker-1';
  workerGuard = () => {};

  originalBlob = globals['Blob'];
  originalWorker = globals['Worker'];
  originalCreateObjectURL = (globals['URL'] as { createObjectURL?: unknown }).createObjectURL;

  class FakeBlob {
    constructor(
      readonly parts: readonly string[],
      readonly options?: BlobPropertyBag,
    ) {
      blobParts.push(parts.join(''));
    }
  }

  class FakeWorker {
    constructor(url: string | URL, options?: WorkerOptions) {
      workerGuard(String(url));
      created.push({ url: String(url), options });
    }
  }

  globals['Blob'] = FakeBlob;
  globals['Worker'] = FakeWorker;
  // Only the one method is patched — clobbering the whole URL global breaks the module loader.
  (globals['URL'] as { createObjectURL: () => string }).createObjectURL = () => {
    objectURLCalls += 1;
    return createObjectURLImpl();
  };
});

afterEach(() => {
  globals['Blob'] = originalBlob;
  globals['Worker'] = originalWorker;
  (globals['URL'] as Record<string, unknown>)['createObjectURL'] = originalCreateObjectURL;
});

/** Fresh module instance each time — the blob URL is cached at module scope. */
async function load(): Promise<typeof import('../src/viewer/workerEnvironment.js')> {
  vi.resetModules();
  return import('../src/viewer/workerEnvironment.js');
}

describe('createEditorWorker', () => {
  it('builds the worker from a blob: URL carrying the inlined worker source', async () => {
    const { createEditorWorker } = await load();
    createEditorWorker();

    expect(blobParts).toEqual([workerSource]);
    expect(created).toHaveLength(1);
    expect(created[0]?.url).toBe('blob:shepherd/worker-1');
  });

  it('creates a classic worker, not a module worker (module workers over file: are the unreliable case)', async () => {
    const { createEditorWorker } = await load();
    createEditorWorker();
    expect(created[0]?.options?.type).toBeUndefined();
    expect(created[0]?.options?.name).toBe('shepherd-monaco-editor-worker');
  });

  it('reuses one object URL across workers', async () => {
    const { createEditorWorker } = await load();
    createEditorWorker();
    createEditorWorker();
    expect(objectURLCalls).toBe(1);
    expect(created).toHaveLength(2);
  });

  it('falls back to the relative script when createObjectURL throws', async () => {
    createObjectURLImpl = () => {
      throw new Error('blocked');
    };
    const { createEditorWorker, WORKER_FALLBACK_PATH } = await load();
    createEditorWorker();
    expect(created[0]?.url).toBe(WORKER_FALLBACK_PATH);
    expect(WORKER_FALLBACK_PATH).toBe('./editor.worker.js');
  });

  it('falls back when the blob worker itself is rejected by the host', async () => {
    workerGuard = (url) => {
      if (url.startsWith('blob:')) throw new Error('SecurityError');
    };
    const { createEditorWorker, WORKER_FALLBACK_PATH } = await load();
    createEditorWorker();
    expect(created.map((c) => c.url)).toEqual([WORKER_FALLBACK_PATH]);
  });
});

describe('installMonacoEnvironment', () => {
  it('exposes exactly one getWorker hook (no language-service workers exist in this bundle)', async () => {
    const { installMonacoEnvironment } = await load();
    installMonacoEnvironment();

    const env = (globalThis as unknown as { MonacoEnvironment?: Record<string, unknown> }).MonacoEnvironment;
    expect(env).toBeDefined();
    expect(Object.keys(env ?? {})).toEqual(['getWorker']);
    expect(typeof env?.['getWorker']).toBe('function');
  });

  it('hands Monaco a worker regardless of the requested label', async () => {
    const { installMonacoEnvironment } = await load();
    installMonacoEnvironment();
    const env = (globalThis as unknown as { MonacoEnvironment: { getWorker(id: string, label: string): Worker } })
      .MonacoEnvironment;

    env.getWorker('workerMain.js', '');
    expect(created).toHaveLength(1);
    expect(created[0]?.url).toBe('blob:shepherd/worker-1');
  });
});
