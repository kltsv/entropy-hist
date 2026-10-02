import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { BridgeClient, bundledEngine } from '../src/client';
import { HistoryService } from '../src/service';

const sha = (s: string) => createHash('sha256').update(s).digest('hex');
test('standalone packaged engine: record/read/diff/blame/restore/delete and guarded merge', async () => {
  const folder = mkdtempSync(join(tmpdir(), 'vault with пробелы '));
  const plugin = resolve(import.meta.dirname, '..');
  const client = new BridgeClient(() => bundledEngine(plugin));
  const service = new HistoryService(client, folder, () => ({ writer: 'laptop', autoRecord: false, debounceMs: 1000, extensions: '.md' }));
  const path = 'Заметка $(echo literal).md';
  const write = (s: string) => writeFileSync(join(folder, path), s);
  try {
    write('base\n'); await service.record(path);
    write('ours\n'); await service.record(path);
    assert.equal((await service.show(path, 'HEAD~1')).content, 'base\n');
    assert.match((await service.diff(path, 'HEAD~1', 'HEAD')).unified, /\+ours/);
    assert.equal((await service.blame(path, 'HEAD')).lines[0].writers[0], 'laptop');
    await service.call('restore', { path, ref: sha('base\n'), expectedLive: sha('ours\n'), writer: 'phone', stateDir: join(folder, '.hist-state', 'phone') });
    write('theirs\n'); await service.call('commit', { path, writer: 'phone', stateDir: join(folder, '.hist-state', 'phone') });
    write('ours\n');
    assert.equal((await service.status()).divergent.length, 1);
    const draft = await service.merge(path, sha('theirs\n'), sha('ours\n'));
    assert.ok('text' in draft && draft.text.includes('<<<<<<<'));
    await service.saveDraft(path, 'both\n');
    assert.equal((await service.draft(path)).text, 'both\n');
    await service.finish(path, 'both\n', sha('ours\n'));
    assert.equal(readFileSync(join(folder, path), 'utf8'), 'both\n');
    assert.equal((await service.status()).divergent.length, 0);
    write('unrecorded\n'); await service.restore(path, sha('base\n'), sha('unrecorded\n'));
    assert.equal((await service.show(path, sha('unrecorded\n'))).content, 'unrecorded\n');
    await assert.rejects(service.restore(path, sha('ours\n'), sha('unrecorded\n')), { code: 'live_changed' });
    unlinkSync(join(folder, path)); await service.record(path);
    assert.equal((await service.log(path)).exists, false);
    await service.restore(path, sha('base\n'), null);
    assert.equal(existsSync(join(folder, path)), true);
    assert.equal(readFileSync(join(folder, path), 'utf8'), 'base\n');
  } finally { client.dispose(); rmSync(folder, { recursive: true }); }
});
