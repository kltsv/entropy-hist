import { build } from 'esbuild';
import { readFileSync, existsSync } from 'node:fs';

const version = JSON.parse(readFileSync('manifest.json', 'utf8')).version;
const metadata = process.env.RELEASE_ASSETS ?? 'bin/engine.json';
const assets = existsSync(metadata) ? JSON.parse(readFileSync(metadata, 'utf8')).assets : {};
if (process.env.RELEASE_ASSETS && !Object.keys(assets).length) throw new Error('Release assets are required.');

await build({
  entryPoints: ['src/main.ts'], bundle: true, format: 'cjs', platform: 'node',
  target: 'es2020', minify: true, outfile: 'main.js',
  external: ['obsidian', 'electron', 'node:*'],
  define: { __HIST_RELEASE__: JSON.stringify({ version, baseUrl: `https://github.com/kltsv/entropy-hist/releases/download/${version}`, assets }) },
});
