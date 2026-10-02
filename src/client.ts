import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { HistoryTransport } from './types';

export class HistoryError extends Error {
  constructor(readonly code: string, message: string) { super(message); this.name = 'HistoryError'; }
}

export function engineName(platform = process.platform, arch = process.arch): string {
  if (!['darwin', 'linux', 'win32'].includes(platform) || !['arm64', 'x64'].includes(arch)) {
    throw new HistoryError('unsupported_platform', `Entropy History has no engine for ${platform}/${arch}.`);
  }
  return `hist-bridge-${platform}-${arch}${platform === 'win32' ? '.exe' : ''}`;
}

export function bundledEngine(pluginDir: string): string {
  const name = engineName();
  const binary = join(pluginDir, 'bin', name);
  try {
    const metadata = JSON.parse(readFileSync(join(pluginDir, 'bin', 'engine.json'), 'utf8'));
    const expected = metadata.assets?.[name];
    if (typeof expected !== 'string' || !/^[a-f0-9]{64}$/.test(expected)) {
      throw new HistoryError('missing_engine', `Install the ${process.platform}/${process.arch} Entropy History ZIP.`);
    }
    const bytes = readFileSync(binary);
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (actual !== expected) throw new HistoryError('corrupt_engine', 'The bundled history engine failed checksum verification. Reinstall the plugin ZIP.');
    if (process.platform !== 'win32' && (statSync(binary).mode & 0o111) === 0) chmodSync(binary, 0o755);
    return binary;
  } catch (e) {
    if (e instanceof HistoryError) throw e;
    throw new HistoryError('missing_engine', `The bundled history engine is missing. Install the complete platform ZIP. ${String(e)}`);
  }
}

/** Literal argv/stdin, one owned process per request, serialized per vault. */
export class BridgeClient implements HistoryTransport {
  private tail: Promise<unknown> = Promise.resolve();
  private disposed = false;
  private readonly children = new Set<ChildProcessWithoutNullStreams>();

  constructor(private readonly executable: () => string | Promise<string>, private readonly timeoutMs = 60_000,
    private readonly prefixArgs: readonly string[] = []) {}

  request<T>(payload: Record<string, unknown>): Promise<T> {
    const run = this.tail.then(() => this.execute<T>(payload));
    this.tail = run.catch(() => undefined);
    return run;
  }

  private async execute<T>(payload: Record<string, unknown>): Promise<T> {
    if (this.disposed) return Promise.reject(new HistoryError('closed', 'History plugin is closed.'));
    const binary = await this.executable();
    if (this.disposed) throw new HistoryError('closed', 'History plugin is closed.');
    return new Promise<T>((resolve, reject) => {
      const child = spawn(binary, [...this.prefixArgs], { windowsHide: true, stdio: 'pipe' });
      this.children.add(child);
      let settled = false;
      let size = 0;
      const output: Buffer[] = [];
      let errors = '';
      const finish = (error?: Error, value?: T) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.children.delete(child);
        if (error) reject(error); else resolve(value as T);
      };
      const timer = setTimeout(() => {
        child.kill();
        finish(new HistoryError('timeout', 'History request timed out. Try a smaller history filter.'));
      }, this.timeoutMs);
      child.on('error', (error) => finish(new HistoryError('engine_error', error.message)));
      child.stdin.on('error', (error: Error) => finish(new HistoryError('engine_error', error.message)));
      child.stdout.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > 64 * 1024 * 1024) {
          child.kill(); finish(new HistoryError('too_large', 'History output exceeds 64 MiB. Narrow the selection.'));
        } else { output.push(chunk); }
      });
      child.stderr.on('data', (chunk: Buffer) => { if (errors.length < 8192) errors += chunk.toString('utf8'); });
      child.on('close', (code) => {
        if (this.disposed) { finish(new HistoryError('closed', 'History plugin is closed.')); return; }
        try {
          const result = JSON.parse(Buffer.concat(output).toString('utf8'));
          if (result.ok === false && result.error?.message) {
            finish(new HistoryError(result.error.code ?? 'history_error', result.error.message));
          } else if (result.ok === true && code === 0 && result.data != null) {
            finish(undefined, result.data as T);
          } else {
            finish(new HistoryError('engine_error', `History engine exited ${code}. ${errors}`));
          }
        } catch {
          finish(new HistoryError('engine_error', `Invalid history response (exit ${code}). ${errors}`));
        }
      });
      child.stdin.end(JSON.stringify(payload));
    });
  }

  dispose(): void {
    this.disposed = true;
    for (const child of this.children) child.kill();
    this.children.clear();
  }
}
