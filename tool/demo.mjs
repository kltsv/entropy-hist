import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { binary, pluginRoot } from './engine.mjs';

if (!existsSync(binary) || !existsSync(join(pluginRoot, 'main.js'))) throw new Error('Run npm run package before npm run demo.');
const folder = join(pluginRoot, 'demo-vault');
if (existsSync(folder)) throw new Error('demo-vault already exists; keep it or rename it before creating another demo.');
mkdirSync(folder, { recursive: true });
const sha = (s) => createHash('sha256').update(s).digest('hex');
function request(op, args = {}, writer = 'desktop') {
  const response = JSON.parse(execFileSync(binary, { input: JSON.stringify({ folder, writer, stateDir: join(folder, '.hist-state', writer), op, ...args }), encoding: 'utf8' }));
  if (!response.ok) throw new Error(response.error.message);
  return response.data;
}
const write = (path, text) => writeFileSync(join(folder, path), text);
write('Welcome.md', '# Entropy History\n\nОткройте панель истории кнопкой на ленте или через палитру команд.\n\n- «История всего vault» показывает удалённые заметки.\n- Conflict.md содержит расхождение и незавершённый merge.\n- Список.md содержит несколько версий для diff, blame и restore.\n\nТекст версий показывается без исполнения HTML:\n<img src=x onerror="alert(\'must never execute\')">\n');
write('Список.md', '# Список\n\n- Хлеб\n'); request('commit', { path: 'Список.md' });
write('Список.md', '# Список\n\n- Хлеб\n- Молоко\n'); request('commit', { path: 'Список.md' });
const base = '# План\n\nВыбрать маршрут.\n';
const ours = '# План\n\nПоехать на север.\n';
const theirs = '# План\n\nПоехать на юг.\n';
write('Conflict.md', base); request('commit', { path: 'Conflict.md' });
write('Conflict.md', ours); request('commit', { path: 'Conflict.md' });
request('restore', { path: 'Conflict.md', ref: sha(base), expectedLive: sha(ours) }, 'phone');
write('Conflict.md', theirs); request('commit', { path: 'Conflict.md' }, 'phone');
write('Conflict.md', ours);
// Plugin's normal local state directory, so it can resume this real draft.
const draft = JSON.parse(execFileSync(binary, { input: JSON.stringify({ folder, writer: 'desktop', op: 'merge-start', path: 'Conflict.md', branch: sha(theirs), expectedLive: sha(ours) }), encoding: 'utf8' }));
if (!draft.ok) throw new Error(draft.error.message);
write('Removed.md', '# Удалённая заметка\nВосстановите меня из общей истории.\n'); request('commit', { path: 'Removed.md' });
unlinkSync(join(folder, 'Removed.md')); request('commit', { path: 'Removed.md' });
request('commit', { path: 'Welcome.md' });
const config = join(folder, '.obsidian');
mkdirSync(join(config, 'plugins', 'entropy-hist'), { recursive: true });
for (const name of ['manifest.json', 'main.js', 'styles.css', 'bin']) cpSync(join(pluginRoot, name), join(config, 'plugins', 'entropy-hist', name), { recursive: true });
writeFileSync(join(config, 'community-plugins.json'), '["entropy-hist"]\n');
writeFileSync(join(config, 'app.json'), JSON.stringify({ restrictedMode: false, livePreview: false }));
writeFileSync(join(config, 'workspace.json'), JSON.stringify({ main: { id: 'main', type: 'split', children: [{ id: 'welcome', type: 'leaf', state: { type: 'markdown', state: { file: 'Welcome.md', mode: 'source' } } }] }, right: { id: 'right', type: 'split', direction: 'horizontal', children: [{ id: 'history', type: 'leaf', state: { type: 'entropy-history', state: { path: 'Список.md', followActive: false } } }] }, active: 'welcome' }));
console.log(`Demonstration vault: ${folder}`);
console.log(`Open this folder as a vault in Obsidian. History is enabled; no sync or daemon is involved.`);
