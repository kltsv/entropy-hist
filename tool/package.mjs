import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { buildEngine, pluginRoot } from './engine.mjs';

const manifest = JSON.parse(readFileSync(join(pluginRoot, 'manifest.json'), 'utf8'));
buildEngine();
const buildOptions = { cwd: pluginRoot, stdio: 'inherit' };
execFileSync(process.execPath, [join(pluginRoot, 'node_modules', 'typescript', 'bin', 'tsc'), '--noEmit'], buildOptions);
execFileSync(process.execPath, [join(pluginRoot, 'esbuild.config.mjs')], buildOptions);
const stageRoot = join(pluginRoot, 'dist', `${process.platform}-${process.arch}`);
const stage = join(stageRoot, manifest.id);
rmSync(stage, { recursive: true, force: true });
mkdirSync(stage, { recursive: true });
for (const name of ['manifest.json', 'main.js', 'styles.css', 'bin']) cpSync(join(pluginRoot, name), join(stage, name), { recursive: true });
writeFileSync(join(stage, 'INSTALL.txt'), `Copy this folder to <vault>/.obsidian/plugins/${manifest.id}/ and enable ${manifest.name} in Community plugins.\nNo daemon, network or Dart installation is needed.\n`);
const zip = join(pluginRoot, 'dist', `${manifest.id}-${manifest.version}-${process.platform}-${process.arch}.zip`);
rmSync(zip, { force: true });
if (process.platform === 'win32') {
  const quote = (s) => `'${s.replaceAll("'", "''")}'`;
  execFileSync('powershell.exe', ['-NoProfile', '-Command', `Compress-Archive -Path ${quote(stage)} -DestinationPath ${quote(zip)} -Force`], { stdio: 'inherit' });
} else if (process.platform === 'darwin') {
  execFileSync('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', stage, zip], { stdio: 'inherit' });
} else {
  execFileSync('zip', ['-r', '-q', zip, manifest.id], { cwd: stageRoot, stdio: 'inherit' });
}
writeFileSync(`${zip}.sha256`, `${createHash('sha256').update(readFileSync(zip)).digest('hex')}  ${basename(zip)}\n`);
const vaultIndex = process.argv.indexOf('--vault');
if (vaultIndex !== -1) {
  const value = process.argv[vaultIndex + 1];
  if (!value || value.startsWith('--')) throw new Error('--vault requires an explicit path.');
  const vault = resolve(value);
  if (!existsSync(vault)) throw new Error('The named vault folder does not exist.');
  let configDir = '.obsidian';
  const configIndex = process.argv.indexOf('--config-dir');
  if (configIndex !== -1) {
    configDir = process.argv[configIndex + 1];
    if (!configDir || configDir.includes('..') || /[\\/]/.test(configDir)) throw new Error('--config-dir must be a folder name within the vault.');
  }
  const target = join(vault, configDir, 'plugins', manifest.id);
  mkdirSync(target, { recursive: true });
  cpSync(stage, target, { recursive: true });
  console.log(`Installed ${manifest.name} into ${target}. Enable it in Community plugins.`);
}
console.log(`Installable plugin: ${zip}`);
