import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const pluginRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const packageRoot = resolve(pluginRoot, 'packages/entropy_hist');
export const asset = `hist-bridge-${process.platform}-${process.arch}${process.platform === 'win32' ? '.exe' : ''}`;
export const binary = join(pluginRoot, 'bin', asset);

export function buildEngine() {
  const dart = process.env.HIST_DART || 'dart';
  const options = { cwd: packageRoot, stdio: 'inherit', env: { ...process.env, CI: 'true' } };
  mkdirSync(dirname(binary), { recursive: true });
  execFileSync(dart, ['pub', 'get'], options);
  execFileSync(dart, ['compile', 'exe', 'bin/hist_bridge.dart', '-o', binary], options);
  const sha256 = createHash('sha256').update(readFileSync(binary)).digest('hex');
  writeFileSync(join(pluginRoot, 'bin', 'engine.json'), `${JSON.stringify({ assets: { [asset]: sha256 } }, null, 2)}\n`);
  return { binary, asset, sha256 };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) buildEngine();
