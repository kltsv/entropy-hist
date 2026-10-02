import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { JSDOM } from 'jsdom';

const sha = (text: string) => createHash('sha256').update(text).digest('hex');
const pluginRoot = resolve(import.meta.dirname, '..');
const compiled = await build({ entryPoints: [join(import.meta.dirname, 'ui-entry.ts')], bundle: true, format: 'esm', platform: 'node', write: false, alias: { obsidian: join(import.meta.dirname, 'mock-obsidian.ts') } });
const runtimeDir = mkdtempSync(join(tmpdir(), 'history-ui-runtime-'));
writeFileSync(join(runtimeDir, 'ui.mjs'), compiled.outputFiles[0].text);
const ui = await import(pathToFileURL(join(runtimeDir, 'ui.mjs')).href);
const dom = new JSDOM('<!doctype html><body></body>');
Object.assign(globalThis, { window: dom.window, document: dom.window.document });
ui.installDomHelpers();

async function until(check: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 200; i++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`Timed out: ${label}\n${document.body.textContent}`);
}
function click(root: HTMLElement, text: string): void {
  const el = [...root.querySelectorAll('button')].find((button) => button.textContent === text);
  assert.ok(el, `Button: ${text}`); el.click();
}
async function fixture(text: string): Promise<any> {
  const root = mkdtempSync(join(tmpdir(), 'history-ui-vault-'));
  const dir = join(root, '.obsidian', 'plugins', 'entropy-hist');
  cpSync(join(pluginRoot, 'bin'), join(dir, 'bin'), { recursive: true });
  writeFileSync(join(root, 'a.md'), text);
  const app = ui.createApp(root); const editor = new ui.MarkdownView('a.md', text);
  app.workspace.leaves.push({ view: editor });
  const plugin = new ui.PluginUnderTest(app, { id: 'entropy-hist', dir: '.obsidian/plugins/entropy-hist' });
  await plugin.onload();
  return { root, app, editor, plugin, async cleanup() {
    plugin.onunload(); plugin.cleanup();
    for (const leaf of app.workspace.getLeavesOfType('entropy-history')) { await leaf.view.onClose(); leaf.view.cleanup(); }
    for (const modal of [...ui.Modal.opened]) modal.close();
    await new Promise((resolve) => setTimeout(resolve, 30));
    rmSync(root, { recursive: true, force: true });
  } };
}

test('history panel uses verified text, diff and blame; restore preserves dirty and racing editors', async () => {
  const html = '<img src=x onerror="alert(1)">\nпервый';
  const f = await fixture(html);
  try {
    await f.plugin.service.record('a.md');
    f.editor.text = 'second\n'; await f.plugin.record('a.md');
    const view = await f.plugin.openHistory('a.md'); await view.refresh();
    click(view.contentEl, 'Различия'); await until(() => !!view.contentEl.querySelector('.eh-split'), 'side by side diff');
    click(view.contentEl, 'Авторство'); await until(() => !!view.contentEl.querySelector('.eh-blame'), 'blame');
    const versions = view.contentEl.querySelectorAll('.eh-version'); versions[1].click();
    click(view.contentEl, 'Текст'); await until(() => view.contentEl.querySelector('.eh-preview-content code')?.textContent === html, 'exact HTML preview');
    assert.equal(view.contentEl.querySelector('img'), null);
    f.editor.text = 'dirty editor\n';
    click(view.contentEl, 'Восстановить'); await until(() => ui.Modal.opened.length === 1, 'restore confirmation');
    assert.match(ui.Modal.opened[0].contentEl.textContent, /dirty editor/);
    click(ui.Modal.opened[0].contentEl, 'Подтвердить');
    await until(() => f.editor.text === html, 'editor refresh after restore');
    assert.equal((await f.plugin.service.show('a.md', sha('dirty editor\n'))).content, 'dirty editor\n');
    // A restored buffer loaded by Obsidian's watcher is not a new user edit.
    const snapshots = new Map([[f.editor, 'dirty editor\n']]);
    await f.plugin.updateEditors('a.md', snapshots);
    assert.equal(readFileSync(join(f.root, 'a.md'), 'utf8'), html);
    // Typing during the native request survives and is recoverable in history.
    f.editor.text = 'newer typing\n';
    await assert.rejects(f.plugin.updateEditors('a.md', new Map([[f.editor, html]])), /новая правка/);
    assert.equal(readFileSync(join(f.root, 'a.md'), 'utf8'), 'newer typing\n');
    assert.equal((await f.plugin.service.show('a.md', sha('newer typing\n'))).content, 'newer typing\n');
  } finally { await f.cleanup(); }
});

test('vault discovery records nothing; saved edits coalesce and plugin events detach on unload', async () => {
  const f = await fixture('base');
  try {
    f.plugin.settings.autoRecord = true; f.plugin.settings.debounceMs = 15;
    f.app.vault.emit('create', new ui.TFile('a.md'));
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal((await f.plugin.service.log('a.md')).total, 0);
    f.app.workspace.ready();
    await f.app.vault.modify(new ui.TFile('a.md'), 'saved 1');
    await f.app.vault.modify(new ui.TFile('a.md'), 'saved 2');
    await until(() => readFileSync(join(f.root, 'a.md'), 'utf8') === 'saved 2', 'save');
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal((await f.plugin.service.log('a.md')).total, 1);
    f.app.vault.emit('modify', new ui.TFile('a.md')); f.plugin.onunload(); f.plugin.cleanup();
    assert.equal(f.app.vault.callbacks.get('modify').size, 0);
    await assert.rejects(f.plugin.service.log('a.md'), { code: 'closed' });
  } finally { await f.cleanup(); }
});

test('merge dialog persists on close/reload, rejects markers, applies text, saves before unload', async () => {
  const f = await fixture('base\n');
  try {
    await f.plugin.service.record('a.md');
    writeFileSync(join(f.root, 'a.md'), 'ours\n'); await f.plugin.service.record('a.md');
    await f.plugin.service.call('restore', { path: 'a.md', ref: sha('base\n'), expectedLive: sha('ours\n'), writer: 'phone', stateDir: join(f.root, '.hist-state', 'phone') });
    writeFileSync(join(f.root, 'a.md'), 'theirs\n'); await f.plugin.service.call('commit', { path: 'a.md', writer: 'phone', stateDir: join(f.root, '.hist-state', 'phone') });
    writeFileSync(join(f.root, 'a.md'), 'ours\n'); f.editor.text = 'ours\n';
    const draft = await f.plugin.service.merge('a.md', sha('theirs\n'), sha('ours\n'));
    const view = await f.plugin.openHistory('a.md'); await view.refresh();
    await view.resume('a.md'); let modal = ui.Modal.opened[0];
    click(modal.contentEl, 'Применить результат');
    await until(() => modal.contentEl.querySelector('.eh-error')?.textContent.includes('conflict markers'), 'unresolved markers blocked');
    assert.equal(readFileSync(join(f.root, 'a.md'), 'utf8'), 'ours\n');
    modal.contentEl.querySelector('textarea').value = 'edited draft\n'; modal.close();
    assert.equal((await f.plugin.service.draft('a.md')).text, 'edited draft\n');
    await view.resume('a.md'); modal = ui.Modal.opened[0];
    assert.equal(modal.contentEl.querySelector('textarea').value, 'edited draft\n');
    modal.contentEl.querySelector('textarea').value = 'resolved\n';
    click(modal.contentEl, 'Применить результат'); await until(() => ui.Modal.opened.length === 0, 'merge applied');
    assert.equal(f.editor.text, 'resolved\n'); assert.equal((await f.plugin.service.status()).divergent.length, 0);
    // Create another unresolved merge and unload immediately after typing.
    await f.plugin.service.call('restore', { path: 'a.md', ref: sha('base\n'), expectedLive: sha('resolved\n'), writer: 'third', stateDir: join(f.root, '.hist-state', 'third') });
    writeFileSync(join(f.root, 'a.md'), 'third\n'); await f.plugin.service.call('commit', { path: 'a.md', writer: 'third', stateDir: join(f.root, '.hist-state', 'third') });
    writeFileSync(join(f.root, 'a.md'), 'resolved\n');
    await f.plugin.service.merge('a.md', sha('third\n'), sha('resolved\n'));
    await view.resume('a.md'); modal = ui.Modal.opened[0]; modal.contentEl.querySelector('textarea').value = 'survives unload\n';
    f.plugin.onunload(); f.plugin.cleanup();
    await until(() => [...ui.Modal.opened].length === 0, 'modal closes on unload');
    // Re-enable plugin over the same vault, as Obsidian would do after reload.
    const next = new ui.PluginUnderTest(f.app, f.plugin.manifest); await next.onload();
    let restored;
    for (let i = 0; i < 100; i++) {
      restored = await next.service.draft('a.md');
      if (restored.text === 'survives unload\n') break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(restored.text, 'survives unload\n'); next.onunload(); next.cleanup();
    assert.ok(draft.exists);
  } finally { await f.cleanup(); }
});

test.after(() => { dom.window.close(); rmSync(runtimeDir, { recursive: true, force: true }); });
