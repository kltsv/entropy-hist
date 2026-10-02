import { createHash, randomUUID } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { bundledEngine, engineName, HistoryError } from './client';
import { downloadBytes } from './download';

export interface EngineRelease { version: string; baseUrl: string; assets: Record<string, string> }
declare const __HIST_RELEASE__: EngineRelease;
export const historyRelease: EngineRelease = typeof __HIST_RELEASE__ === 'undefined'
  ? { version: 'development', baseUrl: '', assets: {} } : __HIST_RELEASE__;

/** One verified, immutable release in a machine-local cache outside any vault. */
export class EngineInstaller {
  private pending?: Promise<string>;
  private controller?: AbortController;
  private closed = false;

  constructor(private readonly pluginDir: string, private readonly release: EngineRelease,
    private readonly cacheRoot = join(homedir(), '.entropy-hist', 'engines'),
    private readonly download = downloadBytes) {}

  executable(): Promise<string> {
    if (this.closed) return Promise.reject(new HistoryError('closed', 'History plugin is closed.'));
    if (!this.pending) this.pending = this.install().finally(() => { this.pending = undefined; });
    return this.pending;
  }

  private async install(): Promise<string> {
    const name = engineName();
    const { version, baseUrl, assets } = this.release;
    const expected = assets[name];
    // A BRAT update can leave an older offline ZIP's bin/ directory behind.
    if (existsSync(join(this.pluginDir, 'bin', 'engine.json'))) {
      const bundled = bundledEngine(this.pluginDir);
      const actual = createHash('sha256').update(readFileSync(bundled)).digest('hex');
      if (version === 'development' || actual === expected) return bundled;
    }
    if (!/^[\w.-]+$/.test(version) || !baseUrl || !/^[a-f0-9]{64}$/.test(expected ?? '')) {
      throw new HistoryError('missing_engine', `This release has no verified history engine for ${process.platform}/${process.arch}.`);
    }
    const directory = join(this.cacheRoot, version);
    const binary = join(directory, name);
    const matches = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex') === expected;
    if (existsSync(binary) && matches(readFileSync(binary))) {
      if (process.platform !== 'win32') chmodSync(binary, 0o755);
      return binary;
    }
    const controller = this.controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 120_000);
    let temporary: string | undefined;
    try {
      const bytes = await this.download(`${baseUrl}/${name}`, controller.signal);
      if (!matches(bytes)) throw new HistoryError('corrupt_engine', 'History engine failed checksum verification. Retry installation.');
      if (this.closed || controller.signal.aborted) throw new HistoryError('closed', 'History engine installation was cancelled.');
      mkdirSync(directory, { recursive: true });
      temporary = `${binary}.${randomUUID()}.tmp`;
      writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o755 });
      renameSync(temporary, binary);
      return binary;
    } catch (error) {
      if (this.closed) throw new HistoryError('closed', 'History plugin is closed.');
      if (error instanceof HistoryError) throw error;
      throw new HistoryError('download_failed', `Could not install the history engine: ${String(error)}`);
    } finally {
      clearTimeout(timeout);
      if (temporary) rmSync(temporary, { force: true });
    }
  }

  cancelDownload(): void { this.controller?.abort(); }
  dispose(): void { this.closed = true; this.cancelDownload(); }
}
