import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { BridgeClient, bundledEngine, engineName } from '../src/client';
import { SaveRecorder } from '../src/service';

function script(folder: string, code: string): string {
  const path = join(folder, 'engine with spaces.cjs');
  writeFileSync(path, code);
  return path;
}

test('literal JSON paths and serialized requests never pass through a shell', async () => {
  const temp = mkdtempSync(join(tmpdir(), 'hist-client-'));
  const order = join(temp, 'order');
  const binary = script(temp, `let data='';process.stdin.on('data',c=>data+=c);process.stdin.on('end',()=>{const r=JSON.parse(data);require('fs').appendFileSync(${JSON.stringify(order)},r.path+'\\n');setTimeout(()=>console.log(JSON.stringify({ok:true,data:r})),30)});`);
  const client = new BridgeClient(() => process.execPath, 60000, [binary]);
  try {
    const odd = 'заметка $(touch hacked); &.md';
    const result = await Promise.all([client.request<{ path: string }>({ path: odd }), client.request({ path: 'second' })]);
    assert.equal(result[0].path, odd);
    assert.equal(readFileSync(order, 'utf8'), `${odd}\nsecond\n`);
  } finally { client.dispose(); rmSync(temp, { recursive: true }); }
});

test('structured errors, timeout, and disposal leave no queued execution', async () => {
  const temp = mkdtempSync(join(tmpdir(), 'hist-client-'));
  try {
    let binary = script(temp, `process.stdin.resume();process.stdin.on('end',()=>{console.log(JSON.stringify({ok:false,error:{code:'broken_version',message:'corrupt snapshot'}}));process.exitCode=1});`);
    const failed = new BridgeClient(() => process.execPath, 60000, [binary]);
    await assert.rejects(failed.request({}), { code: 'broken_version', message: 'corrupt snapshot' }); failed.dispose();
    binary = script(temp, `process.stdin.resume();setTimeout(()=>{},10000);`);
    const hanging = new BridgeClient(() => process.execPath, 20, [binary]);
    await assert.rejects(hanging.request({}), { code: 'timeout' }); hanging.dispose();
    const closed = new BridgeClient(() => process.execPath, 60000, [binary]);
    const running = closed.request({}); const queued = closed.request({});
    await new Promise((resolve) => setTimeout(resolve, 10)); closed.dispose();
    await assert.rejects(running, { code: 'closed' }); await assert.rejects(queued, { code: 'closed' });
  } finally { rmSync(temp, { recursive: true }); }
});

test('bundled engine requires the native platform and matching digest', () => {
  const temp = mkdtempSync(join(tmpdir(), 'hist-engine-'));
  try {
    mkdirSync(join(temp, 'bin'));
    const name = engineName(); const bytes = Buffer.from('engine');
    writeFileSync(join(temp, 'bin', name), bytes);
    writeFileSync(join(temp, 'bin', 'engine.json'), JSON.stringify({ assets: { [name]: createHash('sha256').update(bytes).digest('hex') } }));
    assert.equal(bundledEngine(temp), join(temp, 'bin', name));
    writeFileSync(join(temp, 'bin', name), 'changed');
    assert.throws(() => bundledEngine(temp), { code: 'corrupt_engine' });
    assert.throws(() => engineName('aix'), { code: 'unsupported_platform' });
  } finally { rmSync(temp, { recursive: true }); }
});

test('saved edits coalesce, rename/delete cancel timers, disposal records nothing else', async () => {
  const calls: string[] = [];
  const recorder = new SaveRecorder({ record: async (path) => { calls.push(`record:${path}`); return { message: '' }; }, rename: async (a, b) => { calls.push(`rename:${a}:${b}`); } }, () => 25, (error) => { throw error; });
  recorder.changed('a.md'); recorder.changed('a.md');
  await new Promise((resolve) => setTimeout(resolve, 45));
  recorder.changed('old.md'); recorder.renamed('old.md', 'new.md');
  recorder.changed('gone.md'); recorder.deleted('gone.md');
  recorder.changed('pending.md'); recorder.dispose();
  await new Promise((resolve) => setTimeout(resolve, 45));
  assert.deepEqual(calls, ['record:a.md', 'rename:old.md:new.md', 'record:gone.md']);
});
