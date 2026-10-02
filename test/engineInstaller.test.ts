import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { BridgeClient, engineName } from '../src/client';
import { EngineInstaller } from '../src/engineInstaller';

const sha = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');
test('BRAT first use downloads exact release once; offline cache and corruption are verified', async () => {
  const root = mkdtempSync(join(tmpdir(), 'hist-brat-'));
  const bytes = Buffer.from('verified engine');
  let requests = 0; const paths: string[] = [];
  const server = createServer((req, res) => { requests++; paths.push(req.url!); setTimeout(() => res.end(bytes), 15); });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as { port: number }).port;
  const release = { version: '0.1.0', baseUrl: `http://127.0.0.1:${port}/releases/download/0.1.0`, assets: { [engineName()]: sha(bytes) } };
  try {
    const installer = new EngineInstaller(join(root, 'empty-plugin'), release, join(root, 'cache'));
    const [a, b] = await Promise.all([installer.executable(), installer.executable()]);
    assert.equal(a, b); assert.equal(requests, 1);
    assert.deepEqual(paths, [`/releases/download/0.1.0/${engineName()}`]);
    assert.deepEqual(readFileSync(a), bytes);
    const offline = new EngineInstaller(root, release, join(root, 'cache'), async () => { throw new Error('offline'); });
    assert.equal(await offline.executable(), a);
    writeFileSync(a, 'corrupted');
    await assert.rejects(offline.executable(), { code: 'download_failed' });
    assert.equal(await installer.executable(), a); assert.equal(requests, 2);
    assert.deepEqual(readFileSync(a), bytes);
    installer.dispose(); offline.dispose();
  } finally { server.closeAllConnections(); await new Promise<void>(r => server.close(() => r())); rmSync(root, { recursive: true }); }
});

test('invalid metadata, wrong bytes and cancelled download never launch a bridge or leave partial installs', async () => {
  const root = mkdtempSync(join(tmpdir(), 'hist-brat-failure-'));
  const cache = join(root, 'cache');
  const release = { version: '0.1.0', baseUrl: 'https://example.com/0.1.0', assets: { [engineName()]: sha(Buffer.from('engine')) } };
  try {
    let downloads = 0;
    const invalid = new EngineInstaller(root, { ...release, assets: {} }, cache, async () => { downloads++; return Buffer.from(''); });
    await assert.rejects(invalid.executable(), { code: 'missing_engine' }); assert.equal(downloads, 0);
    const corrupt = new EngineInstaller(root, release, cache, async () => Buffer.from('wrong'));
    await assert.rejects(corrupt.executable(), { code: 'corrupt_engine' }); assert.equal(existsSync(cache), false);
    let started!: () => void; const starting = new Promise<void>(r => started = r);
    const cancelled = new EngineInstaller(root, release, cache, async (_url, signal) => {
      started(); return await new Promise<Buffer>((_r, reject) => signal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true }));
    });
    const client = new BridgeClient(() => cancelled.executable());
    const request = client.request({}); const rejected = assert.rejects(request);
    await starting; cancelled.dispose(); client.dispose(); await rejected;
    assert.equal(existsSync(cache), false);
    assert.deepEqual(readdirSync(root), []);
    // Even a downloader ignoring cancellation must not lead to execution.
    let finish!: (bytes: Buffer) => void;
    const late = new EngineInstaller(root, release, cache, async () => new Promise<Buffer>(r => finish = r));
    const pending = late.executable(); const failure = assert.rejects(pending, { code: 'closed' });
    late.dispose(); finish(Buffer.from('engine')); await failure;
    assert.equal(existsSync(cache), false);
  } finally { rmSync(root, { recursive: true }); }
});
